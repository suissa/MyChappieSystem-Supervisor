const std = @import("std");
const protocol_mod = @import("protocol.zig");
const event_bus_mod = @import("event_bus.zig");
const actor_mod = @import("actor_supervisor.zig");
const command_mod = @import("command_registry.zig");
const stdio_mod = @import("stdio_bridge.zig");
const telemetry_mod = @import("telemetry.zig");

pub const protocol = protocol_mod;
pub const event_bus = event_bus_mod;
pub const actors = actor_mod;
pub const commands = command_mod;
pub const stdio_bridge = stdio_mod;
pub const telemetry = telemetry_mod;

pub const RuntimeEvent = protocol_mod.RuntimeEvent;
pub const RuntimeCommand = protocol_mod.RuntimeCommand;
pub const RuntimeSnapshot = protocol_mod.RuntimeSnapshot;
pub const EntityRef = protocol_mod.EntityRef;
pub const EntityKind = protocol_mod.EntityKind;
pub const EventKind = protocol_mod.EventKind;
pub const Severity = protocol_mod.Severity;
pub const ActorState = actor_mod.ActorState;
pub const RestartPolicy = actor_mod.RestartPolicy;
pub const ActionFn = actor_mod.ActionFn;

pub const DefaultEventBus = event_bus_mod.EventBus(4, 32);
pub const DefaultActionSupervisor = actor_mod.ActionSupervisor(16, 64 * 1024, 4);
pub const DefaultCommandRegistry = command_mod.CommandRegistry(64);

/// Foundation runtime used by the TUI and transports. All collections are
/// fixed-capacity. Runtime-critical operations do not grow the heap.
pub const DevelopmentSupervisor = struct {
    bus: DefaultEventBus = .{},
    action_supervisor: DefaultActionSupervisor = DefaultActionSupervisor.init(),
    command_registry: DefaultCommandRegistry = .{},
    project_id: protocol_mod.Id = .{},
    runtime_id: protocol_mod.Id = .{},

    const Self = @This();

    pub fn init(project_id: []const u8, runtime_id: []const u8) !Self {
        return .{
            .project_id = try protocol_mod.Id.init(project_id),
            .runtime_id = try protocol_mod.Id.init(runtime_id),
        };
    }

    pub fn subscribe(self: *Self) !DefaultEventBus.SubscriberId {
        return self.bus.subscribe();
    }

    pub fn nextEvent(self: *Self, subscriber: DefaultEventBus.SubscriberId) ?RuntimeEvent {
        return self.bus.pop(subscriber);
    }

    pub fn spawnAction(
        self: *Self,
        canonical_name: []const u8,
        action: ActionFn,
        memory_quota: usize,
        restart_policy: RestartPolicy,
        timestamp_ns: u64,
    ) !actor_mod.ActorId {
        const id = try self.action_supervisor.spawn(canonical_name, action, memory_quota, restart_policy);
        try self.emitActor(id, canonical_name, .created, .info, timestamp_ns);
        return id;
    }

    /// Run one ActionActor attempt. On memory exhaustion a fresh Actor is
    /// created immediately and its ID is returned. Higher layers restore the
    /// durable checkpoint before scheduling the replacement Actor.
    pub fn runAction(self: *Self, actor_id: actor_mod.ActorId, timestamp_ns: u64) !actor_mod.ActorId {
        const slot = self.action_supervisor.get(actor_id) orelse return error.ActorNotFound;
        const name = slot.canonical_name;
        try self.emitActor(actor_id, name.slice(), .started, .info, timestamp_ns);

        self.action_supervisor.run(actor_id) catch |err| switch (err) {
            error.ActorMemoryExhausted => {
                try self.emitActor(actor_id, name.slice(), .memory_exhausted, .err, timestamp_ns);
                const replacement_id = try self.action_supervisor.replace(actor_id);
                try self.emitActor(replacement_id, name.slice(), .replaced, .warn, timestamp_ns);
                return replacement_id;
            },
            else => {
                try self.emitActor(actor_id, name.slice(), .failed, .err, timestamp_ns);
                return err;
            },
        };

        try self.emitActor(actor_id, name.slice(), .completed, .info, timestamp_ns);
        return actor_id;
    }

    pub fn emit(
        self: *Self,
        entity: EntityRef,
        kind: EventKind,
        severity: Severity,
        timestamp_ns: u64,
        payload: []const u8,
    ) !void {
        var event = RuntimeEvent{
            .sequence = self.bus.reserveSequence(),
            .timestamp_ns = timestamp_ns,
            .entity = entity,
            .kind = kind,
            .severity = severity,
        };
        event.project_id = self.project_id;
        event.runtime_id = self.runtime_id;
        try event.payload.set(payload);
        try self.bus.publish(event);
    }

    pub fn snapshot(self: *const Self) RuntimeSnapshot {
        var out = RuntimeSnapshot{
            .sequence = self.bus.next_sequence -| 1,
            .events_emitted = self.bus.emitted,
            .events_dropped = self.bus.coalesced_or_dropped,
        };

        for (&self.action_supervisor.slots) |slot| {
            if (!slot.active) continue;
            switch (slot.state) {
                .running => out.actors_running += 1,
                .waiting, .queued, .paused, .restarting => out.actors_waiting += 1,
                .failed, .memory_exhausted => {
                    out.actors_failed += 1;
                    out.actions_failed += 1;
                },
                .completed => out.actions_completed += 1,
                else => {},
            }
        }
        return out;
    }

    fn emitActor(
        self: *Self,
        actor_id: actor_mod.ActorId,
        canonical_name: []const u8,
        kind: EventKind,
        severity: Severity,
        timestamp_ns: u64,
    ) !void {
        var id_buf: [32]u8 = undefined;
        const actor_id_text = formatActorId(&id_buf, actor_id);
        const entity = try EntityRef.init(.actor, actor_id_text, canonical_name);
        try self.emit(entity, kind, severity, timestamp_ns, "");
    }
};

fn formatActorId(buf: []u8, value: actor_mod.ActorId) []const u8 {
    var index = buf.len;
    var n = value;
    if (n == 0) {
        index -= 1;
        buf[index] = '0';
        return buf[index..];
    }
    while (n > 0) {
        index -= 1;
        const digit: u8 = @intCast(n % 10);
        buf[index] = '0' + digit;
        n /= 10;
    }
    return buf[index..];
}

test "DevelopmentSupervisor emits ActionActor lifecycle" {
    var supervisor = try DevelopmentSupervisor.init("project-1", "runtime-1");
    const subscriber = try supervisor.subscribe();
    const action = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const bytes = try allocator.alloc(u8, 16);
            @memset(bytes, 1);
        }
    }.run;

    const actor_id = try supervisor.spawnAction("Test.action", action, 1024, .transient, 1);
    _ = try supervisor.runAction(actor_id, 2);

    var seen_created = false;
    var seen_started = false;
    var seen_completed = false;
    while (supervisor.nextEvent(subscriber)) |event| {
        switch (event.kind) {
            .created => seen_created = true,
            .started => seen_started = true,
            .completed => seen_completed = true,
            else => {},
        }
    }
    try std.testing.expect(seen_created and seen_started and seen_completed);
}

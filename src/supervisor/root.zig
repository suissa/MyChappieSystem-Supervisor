const std = @import("std");
const protocol_mod = @import("protocol.zig");
const event_bus_mod = @import("event_bus.zig");
const actor_mod = @import("actor_supervisor.zig");
const command_mod = @import("command_registry.zig");
const queue_mod = @import("bounded_queue.zig");
const stdio_mod = @import("stdio_bridge.zig");
const telemetry_mod = @import("telemetry.zig");

pub const protocol = protocol_mod;
pub const event_bus = event_bus_mod;
pub const actors = actor_mod;
pub const commands = command_mod;
pub const bounded_queue = queue_mod;
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

// Same total event slots as the original 4×32 shape, but twice as many
// concurrent subscribers for TUI + SSE/WS observers.
pub const DefaultEventBus = event_bus_mod.EventBus(8, 16);
pub const DefaultActionSupervisor = actor_mod.ActionSupervisor(16, 64 * 1024, 4);
pub const DefaultCommandRegistry = command_mod.CommandRegistry(64);
pub const DefaultCommandQueue = queue_mod.CommandQueue(32);

/// Runtime shared by TUI and remote transports. Runtime-critical collections
/// have fixed capacity; transport threads submit commands through `command_queue`
/// and only the owner loop mutates Actor/Supervisor state.
pub const DevelopmentSupervisor = struct {
    bus: DefaultEventBus = .{},
    action_supervisor: DefaultActionSupervisor = DefaultActionSupervisor.init(),
    command_registry: DefaultCommandRegistry = .{},
    command_queue: DefaultCommandQueue = .{},
    snapshot_mutex: std.Thread.Mutex = .{},
    published_snapshot: RuntimeSnapshot = .{},
    project_id: protocol_mod.Id = .{},
    runtime_id: protocol_mod.Id = .{},
    shutdown_requested: bool = false,

    const Self = @This();

    pub fn init(project_id: []const u8, runtime_id: []const u8) !Self {
        var self = Self{
            .project_id = try protocol_mod.Id.init(project_id),
            .runtime_id = try protocol_mod.Id.init(runtime_id),
        };
        try self.registerBuiltins();
        _ = self.refreshPublishedSnapshot();
        return self;
    }

    fn registerBuiltins(self: *Self) !void {
        try self.command_registry.registerSimple("actor.pause", "actor.control", .mutating, commandActorPause);
        try self.command_registry.registerSimple("actor.resume", "actor.control", .mutating, commandActorResume);
        try self.command_registry.registerSimple("actor.cancel", "actor.control", .mutating, commandActorCancel);
        try self.command_registry.registerSimple("runtime.shutdown", "runtime.admin", .destructive, commandRuntimeShutdown);
        try self.command_registry.registerSimple("runtime.refresh", "runtime.observe", .observe, commandRuntimeRefresh);
    }

    pub fn subscribe(self: *Self) !DefaultEventBus.SubscriberId {
        return self.bus.subscribe();
    }

    pub fn unsubscribe(self: *Self, subscriber: DefaultEventBus.SubscriberId) void {
        self.bus.unsubscribe(subscriber);
    }

    pub fn nextEvent(self: *Self, subscriber: DefaultEventBus.SubscriberId) ?RuntimeEvent {
        return self.bus.pop(subscriber);
    }

    /// Safe entrypoint for REST/WebSocket/stdio/automation producer threads.
    /// It only touches the mutex-protected bounded queue.
    pub fn submitCommand(self: *Self, command: RuntimeCommand) !void {
        try self.command_queue.push(command);
    }

    /// Called by the owning event loop. Commands are always serialized here,
    /// so no transport thread mutates Actor or Supervisor state directly.
    pub fn drainCommands(self: *Self, timestamp_ns: u64, max_commands: usize) usize {
        var processed: usize = 0;
        while (processed < max_commands) : (processed += 1) {
            const command = self.command_queue.pop() orelse break;
            self.executeCommand(command, timestamp_ns) catch {};
        }
        if (processed > 0) _ = self.refreshPublishedSnapshot();
        return processed;
    }

    pub fn executeCommand(self: *Self, command: RuntimeCommand, timestamp_ns: u64) !void {
        try self.emit(command.target, .command_accepted, .info, timestamp_ns, command.canonical_name.slice());
        self.command_registry.execute(self, command) catch |err| {
            try self.emit(command.target, .command_failed, .err, timestamp_ns, @errorName(err));
            _ = self.refreshPublishedSnapshot();
            return err;
        };
        try self.emit(command.target, .command_completed, .info, timestamp_ns, command.canonical_name.slice());
        _ = self.refreshPublishedSnapshot();
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
        try self.emitActor(id, canonical_name, .created, .info, timestamp_ns, "");
        _ = self.refreshPublishedSnapshot();
        return id;
    }

    /// Run one ActionActor attempt. On hard memory exhaustion a fresh Actor is
    /// created immediately. Durable/checkpoint restoration belongs to the
    /// persistence layer and happens before scheduling the replacement.
    pub fn runAction(self: *Self, actor_id: actor_mod.ActorId, timestamp_ns: u64) !actor_mod.ActorId {
        const slot = self.action_supervisor.get(actor_id) orelse return error.ActorNotFound;
        const name = slot.canonical_name;
        try self.emitActor(actor_id, name.slice(), .started, .info, timestamp_ns, "");

        self.action_supervisor.run(actor_id) catch |err| switch (err) {
            error.ActorMemoryExhausted => {
                const exhausted_slot = self.action_supervisor.get(actor_id).?;
                var payload_buf: [160]u8 = undefined;
                const payload = std.fmt.bufPrint(&payload_buf,
                    "used={d} quota={d} peak={d}",
                    .{ exhausted_slot.last_memory_used, exhausted_slot.memory_quota, exhausted_slot.peak_memory_used },
                ) catch "";
                try self.emitActor(actor_id, name.slice(), .memory_exhausted, .err, timestamp_ns, payload);
                const replacement_id = try self.action_supervisor.replace(actor_id);
                try self.emitActor(replacement_id, name.slice(), .replaced, .warn, timestamp_ns, "fresh bounded memory region");
                _ = self.refreshPublishedSnapshot();
                return replacement_id;
            },
            else => {
                try self.emitActor(actor_id, name.slice(), .failed, .err, timestamp_ns, @errorName(err));
                _ = self.refreshPublishedSnapshot();
                return err;
            },
        };

        const completed_slot = self.action_supervisor.get(actor_id).?;
        if (completed_slot.underMemoryPressure()) {
            var payload_buf: [160]u8 = undefined;
            const payload = std.fmt.bufPrint(&payload_buf,
                "used={d} quota={d} percent={d:.2} soft_limit={d}",
                .{
                    completed_slot.last_memory_used,
                    completed_slot.memory_quota,
                    completed_slot.memoryPercent(),
                    completed_slot.soft_limit_percent,
                },
            ) catch "";
            try self.emitActor(actor_id, name.slice(), .memory_pressure, .warn, timestamp_ns, payload);
        }

        try self.emitActor(actor_id, name.slice(), .completed, .info, timestamp_ns, "");
        _ = self.refreshPublishedSnapshot();
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

    /// Owner-thread snapshot. Actor state is read only here; network threads
    /// must use `readPublishedSnapshot()` instead.
    pub fn snapshot(self: *Self) RuntimeSnapshot {
        const bus_stats = self.bus.stats();
        var out = RuntimeSnapshot{
            .sequence = bus_stats.last_sequence,
            .events_emitted = bus_stats.emitted,
            .events_dropped = bus_stats.coalesced_or_dropped,
        };

        for (self.action_supervisor.slots) |slot| {
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

    pub fn refreshPublishedSnapshot(self: *Self) RuntimeSnapshot {
        const current = self.snapshot();
        self.snapshot_mutex.lock();
        self.published_snapshot = current;
        self.snapshot_mutex.unlock();
        return current;
    }

    pub fn readPublishedSnapshot(self: *Self) RuntimeSnapshot {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        return self.published_snapshot;
    }

    fn emitActor(
        self: *Self,
        actor_id: actor_mod.ActorId,
        canonical_name: []const u8,
        kind: EventKind,
        severity: Severity,
        timestamp_ns: u64,
        payload: []const u8,
    ) !void {
        var id_buf: [32]u8 = undefined;
        const actor_id_text = formatActorId(&id_buf, actor_id);
        const entity = try EntityRef.init(.actor, actor_id_text, canonical_name);
        try self.emit(entity, kind, severity, timestamp_ns, payload);
    }

    fn actorIdFromCommand(command: RuntimeCommand) !actor_mod.ActorId {
        if (command.target.kind != .actor) return error.InvalidTarget;
        return std.fmt.parseInt(actor_mod.ActorId, command.target.id.slice(), 10);
    }

    fn commandActorPause(ctx: *anyopaque, command: RuntimeCommand) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.action_supervisor.pause(try actorIdFromCommand(command));
    }

    fn commandActorResume(ctx: *anyopaque, command: RuntimeCommand) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.action_supervisor.resume(try actorIdFromCommand(command));
    }

    fn commandActorCancel(ctx: *anyopaque, command: RuntimeCommand) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.action_supervisor.cancel(try actorIdFromCommand(command));
    }

    fn commandRuntimeShutdown(ctx: *anyopaque, _: RuntimeCommand) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.shutdown_requested = true;
    }

    fn commandRuntimeRefresh(_: *anyopaque, _: RuntimeCommand) !void {}
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

test "DevelopmentSupervisor emits memory pressure before completion" {
    var supervisor = try DevelopmentSupervisor.init("project-1", "runtime-1");
    const subscriber = try supervisor.subscribe();
    const action = struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = try allocator.alloc(u8, 900);
        }
    }.run;

    const actor_id = try supervisor.spawnAction("Test.pressure", action, 1024, .transient, 1);
    _ = try supervisor.runAction(actor_id, 2);

    var seen_pressure = false;
    while (supervisor.nextEvent(subscriber)) |event| {
        if (event.kind == .memory_pressure) seen_pressure = true;
    }
    try std.testing.expect(seen_pressure);
}

test "external commands are serialized through bounded queue" {
    var supervisor = try DevelopmentSupervisor.init("project-1", "runtime-1");
    const target = try EntityRef.init(.runtime, "runtime-1", "Runtime");
    var command = try RuntimeCommand.init("cmd-1", target, "runtime.shutdown", .websocket);
    command.safety = .destructive;
    try supervisor.submitCommand(command);
    try std.testing.expect(!supervisor.shutdown_requested);
    try std.testing.expectEqual(@as(usize, 1), supervisor.drainCommands(10, 8));
    try std.testing.expect(supervisor.shutdown_requested);
}

test "published snapshot is safe copy for remote readers" {
    var supervisor = try DevelopmentSupervisor.init("project-1", "runtime-1");
    const a = supervisor.refreshPublishedSnapshot();
    const b = supervisor.readPublishedSnapshot();
    try std.testing.expectEqual(a.sequence, b.sequence);
    try std.testing.expectEqual(a.events_emitted, b.events_emitted);
}

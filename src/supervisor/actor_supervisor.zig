const std = @import("std");
const protocol = @import("protocol.zig");

pub const ActorId = u64;
pub const ActionFn = *const fn (std.mem.Allocator) anyerror!void;

pub const ActorState = enum {
    empty,
    created,
    queued,
    running,
    waiting,
    paused,
    completed,
    failed,
    memory_exhausted,
    cancelled,
    restarting,
    replaced,
};

pub const RestartPolicy = enum {
    temporary,
    transient,
    permanent,
};

pub const Strategy = enum {
    one_for_one,
    one_for_all,
    rest_for_one,
};

pub const RunError = error{
    ActorNotFound,
    InvalidState,
    ActorMemoryExhausted,
    ActionFailed,
};

/// A fixed-capacity ActionActor supervisor. Actor storage and mailboxes live
/// inside the supervisor itself: spawning an Actor never grows the process heap.
pub fn ActionSupervisor(
    comptime max_actors: usize,
    comptime max_actor_memory_bytes: usize,
    comptime mailbox_capacity: usize,
) type {
    if (max_actors == 0) @compileError("ActionSupervisor requires at least one Actor slot");
    if (max_actor_memory_bytes == 0) @compileError("Actor memory capacity must be greater than zero");
    if (mailbox_capacity == 0) @compileError("Actor mailbox capacity must be greater than zero");

    return struct {
        slots: [max_actors]ActorSlot = undefined,
        next_actor_id: ActorId = 1,
        strategy: Strategy = .one_for_one,
        restart_limit: u16 = 3,

        const Self = @This();

        pub const ActorSlot = struct {
            active: bool = false,
            id: ActorId = 0,
            canonical_name: protocol.Name = .{},
            state: ActorState = .empty,
            restart_policy: RestartPolicy = .transient,
            restarts: u16 = 0,
            memory_quota: usize = 0,
            soft_limit_percent: u8 = 80,
            storage: [max_actor_memory_bytes]u8 = undefined,
            fba: std.heap.FixedBufferAllocator = undefined,
            action: ?ActionFn = null,
            mailbox: [mailbox_capacity]?protocol.RuntimeCommand = [_]?protocol.RuntimeCommand{null} ** mailbox_capacity,
            mailbox_head: usize = 0,
            mailbox_len: usize = 0,

            fn prepare(self: *ActorSlot, quota: usize) void {
                self.memory_quota = quota;
                self.fba = std.heap.FixedBufferAllocator.init(self.storage[0..quota]);
            }

            pub fn allocator(self: *ActorSlot) std.mem.Allocator {
                return self.fba.allocator();
            }

            pub fn mailboxLag(self: *const ActorSlot) usize {
                return self.mailbox_len;
            }
        };

        pub fn init() Self {
            var self: Self = undefined;
            self.next_actor_id = 1;
            self.strategy = .one_for_one;
            self.restart_limit = 3;
            for (&self.slots) |*slot| slot.* = .{};
            return self;
        }

        pub fn spawn(
            self: *Self,
            canonical_name: []const u8,
            action: ActionFn,
            memory_quota: usize,
            restart_policy: RestartPolicy,
        ) !ActorId {
            if (memory_quota == 0 or memory_quota > max_actor_memory_bytes) {
                return error.InvalidMemoryQuota;
            }

            for (&self.slots) |*slot| {
                if (!slot.active) {
                    const id = self.next_actor_id;
                    self.next_actor_id +%= 1;
                    if (self.next_actor_id == 0) self.next_actor_id = 1;

                    slot.* = .{
                        .active = true,
                        .id = id,
                        .canonical_name = try protocol.Name.init(canonical_name),
                        .state = .created,
                        .restart_policy = restart_policy,
                        .memory_quota = memory_quota,
                        .action = action,
                    };
                    slot.prepare(memory_quota);
                    return id;
                }
            }
            return error.NoActorSlot;
        }

        pub fn enqueue(self: *Self, actor_id: ActorId, command: protocol.RuntimeCommand) !void {
            const slot = self.find(actor_id) orelse return error.ActorNotFound;
            if (slot.mailbox_len == mailbox_capacity) return error.MailboxFull;
            const tail = (slot.mailbox_head + slot.mailbox_len) % mailbox_capacity;
            slot.mailbox[tail] = command;
            slot.mailbox_len += 1;
            if (slot.state == .created or slot.state == .waiting) slot.state = .queued;
        }

        pub fn popCommand(self: *Self, actor_id: ActorId) ?protocol.RuntimeCommand {
            const slot = self.find(actor_id) orelse return null;
            if (slot.mailbox_len == 0) return null;
            const command = slot.mailbox[slot.mailbox_head] orelse return null;
            slot.mailbox[slot.mailbox_head] = null;
            slot.mailbox_head = (slot.mailbox_head + 1) % mailbox_capacity;
            slot.mailbox_len -= 1;
            return command;
        }

        pub fn run(self: *Self, actor_id: ActorId) RunError!void {
            const slot = self.find(actor_id) orelse return error.ActorNotFound;
            switch (slot.state) {
                .created, .queued, .waiting, .restarting => {},
                else => return error.InvalidState,
            }

            const action = slot.action orelse return error.InvalidState;
            // A fresh arena is reconstructed for every execution/attempt.
            // The Action only receives this bounded allocator through the
            // trusted-native contract.
            slot.prepare(slot.memory_quota);
            slot.state = .running;

            action(slot.allocator()) catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        slot.state = .memory_exhausted;
                        return error.ActorMemoryExhausted;
                    },
                    else => {
                        slot.state = .failed;
                        return error.ActionFailed;
                    },
                }
            };
            slot.state = .completed;
        }

        /// Creates a new Actor instance with fresh bounded memory and marks the
        /// old Actor as replaced. Durable/checkpoint state intentionally lives
        /// outside Actor memory and is supplied by higher runtime layers.
        pub fn replace(self: *Self, actor_id: ActorId) !ActorId {
            const old = self.find(actor_id) orelse return error.ActorNotFound;
            const action = old.action orelse return error.InvalidState;
            const quota = old.memory_quota;
            const policy = old.restart_policy;
            const name = old.canonical_name;
            const previous_restarts = old.restarts;

            if (previous_restarts >= self.restart_limit) return error.RestartIntensityExceeded;

            const new_id = try self.spawn(name.slice(), action, quota, policy);
            const replacement = self.find(new_id).?;
            replacement.restarts = previous_restarts + 1;
            replacement.state = .restarting;
            old.state = .replaced;
            return new_id;
        }

        pub fn release(self: *Self, actor_id: ActorId) void {
            const slot = self.find(actor_id) orelse return;
            // Zero runtime-owned memory before returning the slot to the pool.
            @memset(slot.storage[0..slot.memory_quota], 0);
            slot.* = .{};
        }

        pub fn pause(self: *Self, actor_id: ActorId) !void {
            const slot = self.find(actor_id) orelse return error.ActorNotFound;
            if (slot.state != .running and slot.state != .queued and slot.state != .waiting) return error.InvalidState;
            slot.state = .paused;
        }

        pub fn resume(self: *Self, actor_id: ActorId) !void {
            const slot = self.find(actor_id) orelse return error.ActorNotFound;
            if (slot.state != .paused) return error.InvalidState;
            slot.state = if (slot.mailbox_len > 0) .queued else .waiting;
        }

        pub fn cancel(self: *Self, actor_id: ActorId) !void {
            const slot = self.find(actor_id) orelse return error.ActorNotFound;
            slot.state = .cancelled;
        }

        pub fn get(self: *Self, actor_id: ActorId) ?*ActorSlot {
            return self.find(actor_id);
        }

        fn find(self: *Self, actor_id: ActorId) ?*ActorSlot {
            for (&self.slots) |*slot| {
                if (slot.active and slot.id == actor_id) return slot;
            }
            return null;
        }
    };
}

test "actor memory is strictly bounded by FixedBufferAllocator" {
    const Supervisor = ActionSupervisor(2, 128, 2);
    var supervisor = Supervisor.init();

    const action = struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = try allocator.alloc(u8, 256);
        }
    }.run;

    const id = try supervisor.spawn("Test.memoryBound", action, 64, .transient);
    try std.testing.expectError(error.ActorMemoryExhausted, supervisor.run(id));
    try std.testing.expectEqual(ActorState.memory_exhausted, supervisor.get(id).?.state);
}

test "mailbox is bounded" {
    const Supervisor = ActionSupervisor(1, 128, 1);
    var supervisor = Supervisor.init();
    const action = struct {
        fn run(_: std.mem.Allocator) !void {}
    }.run;
    const id = try supervisor.spawn("Test.mailbox", action, 64, .transient);
    const target = try protocol.EntityRef.init(.actor, "actor-1", "Test.mailbox");
    const cmd = try protocol.RuntimeCommand.init("cmd-1", target, "actor.resume", .test);
    try supervisor.enqueue(id, cmd);
    try std.testing.expectError(error.MailboxFull, supervisor.enqueue(id, cmd));
}

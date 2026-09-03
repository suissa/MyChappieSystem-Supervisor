const std = @import("std");
const protocol = @import("protocol.zig");

pub const PublishError = error{CriticalSubscriberFull};

/// Fixed-capacity, thread-safe fan-out bus. Each subscriber owns an
/// independent bounded ring. Transport threads may subscribe/pop concurrently
/// while the supervisor owner thread publishes RuntimeEvents.
pub fn EventBus(comptime max_subscribers: usize, comptime queue_capacity: usize) type {
    if (max_subscribers == 0) @compileError("EventBus requires at least one subscriber");
    if (queue_capacity == 0) @compileError("EventBus queue capacity must be greater than zero");

    return struct {
        mutex: std.Thread.Mutex = .{},
        subscribers: [max_subscribers]Subscriber = [_]Subscriber{.{}} ** max_subscribers,
        next_sequence: u64 = 1,
        emitted: u64 = 0,
        coalesced_or_dropped: u64 = 0,

        const Self = @This();

        pub const SubscriberId = usize;
        pub const Stats = struct {
            last_sequence: u64,
            emitted: u64,
            coalesced_or_dropped: u64,
            active_subscribers: usize,
        };

        pub const Subscriber = struct {
            active: bool = false,
            events: [queue_capacity]?protocol.RuntimeEvent = [_]?protocol.RuntimeEvent{null} ** queue_capacity,
            head: usize = 0,
            len: usize = 0,
            dropped: u64 = 0,
        };

        pub fn subscribe(self: *Self) !SubscriberId {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (&self.subscribers, 0..) |*sub, index| {
                if (!sub.active) {
                    sub.* = .{ .active = true };
                    return index;
                }
            }
            return error.NoSubscriberSlot;
        }

        pub fn unsubscribe(self: *Self, id: SubscriberId) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (id >= max_subscribers) return;
            self.subscribers[id] = .{};
        }

        pub fn reserveSequence(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const seq = self.next_sequence;
            self.next_sequence +%= 1;
            if (self.next_sequence == 0) self.next_sequence = 1;
            return seq;
        }

        pub fn publish(self: *Self, event: protocol.RuntimeEvent) PublishError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (event.isCritical()) {
                for (&self.subscribers) |*sub| {
                    if (sub.active and sub.len == queue_capacity) {
                        return error.CriticalSubscriberFull;
                    }
                }
            }

            for (&self.subscribers) |*sub| {
                if (!sub.active) continue;
                if (sub.len == queue_capacity) {
                    // Only non-critical traffic reaches this branch. Prefer
                    // freshness for telemetry by overwriting the oldest item.
                    sub.events[sub.head] = event;
                    sub.head = (sub.head + 1) % queue_capacity;
                    sub.dropped += 1;
                    self.coalesced_or_dropped += 1;
                    continue;
                }

                const tail = (sub.head + sub.len) % queue_capacity;
                sub.events[tail] = event;
                sub.len += 1;
            }
            self.emitted += 1;
        }

        pub fn pop(self: *Self, id: SubscriberId) ?protocol.RuntimeEvent {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (id >= max_subscribers) return null;
            const sub = &self.subscribers[id];
            if (!sub.active or sub.len == 0) return null;

            const event = sub.events[sub.head] orelse return null;
            sub.events[sub.head] = null;
            sub.head = (sub.head + 1) % queue_capacity;
            sub.len -= 1;
            return event;
        }

        pub fn lag(self: *Self, id: SubscriberId) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (id >= max_subscribers) return 0;
            const sub = &self.subscribers[id];
            return if (sub.active) sub.len else 0;
        }

        pub fn stats(self: *Self) Stats {
            self.mutex.lock();
            defer self.mutex.unlock();
            var active: usize = 0;
            for (self.subscribers) |sub| {
                if (sub.active) active += 1;
            }
            return .{
                .last_sequence = self.next_sequence -| 1,
                .emitted = self.emitted,
                .coalesced_or_dropped = self.coalesced_or_dropped,
                .active_subscribers = active,
            };
        }
    };
}

test "event bus fans out without dynamic allocation" {
    const Bus = EventBus(2, 4);
    var bus = Bus{};
    const a = try bus.subscribe();
    const b = try bus.subscribe();

    const entity = try protocol.EntityRef.init(.runtime, "runtime-1", "Runtime");
    const ev = protocol.RuntimeEvent{
        .sequence = bus.reserveSequence(),
        .timestamp_ns = 1,
        .entity = entity,
        .kind = .metric_sampled,
    };
    try bus.publish(ev);

    try std.testing.expect(bus.pop(a) != null);
    try std.testing.expect(bus.pop(b) != null);
}

test "critical events are not silently dropped" {
    const Bus = EventBus(1, 1);
    var bus = Bus{};
    _ = try bus.subscribe();
    const entity = try protocol.EntityRef.init(.action, "action-1", "Action");

    try bus.publish(.{
        .sequence = bus.reserveSequence(),
        .timestamp_ns = 1,
        .entity = entity,
        .kind = .progress,
    });

    try std.testing.expectError(error.CriticalSubscriberFull, bus.publish(.{
        .sequence = bus.reserveSequence(),
        .timestamp_ns = 2,
        .entity = entity,
        .kind = .failed,
        .severity = .err,
    }));
}

const std = @import("std");
const protocol = @import("protocol.zig");

/// Thread-safe fixed-capacity MPSC queue used by transport threads to submit
/// RuntimeCommands to the single-threaded supervisor loop. It never allocates.
pub fn CommandQueue(comptime capacity: usize) type {
    if (capacity == 0) @compileError("CommandQueue capacity must be greater than zero");

    return struct {
        mutex: std.Thread.Mutex = .{},
        items: [capacity]?protocol.RuntimeCommand = [_]?protocol.RuntimeCommand{null} ** capacity,
        head: usize = 0,
        len: usize = 0,
        pushed: u64 = 0,
        rejected_full: u64 = 0,

        const Self = @This();

        pub fn push(self: *Self, command: protocol.RuntimeCommand) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == capacity) {
                self.rejected_full += 1;
                return error.QueueFull;
            }
            const tail = (self.head + self.len) % capacity;
            self.items[tail] = command;
            self.len += 1;
            self.pushed += 1;
        }

        pub fn pop(self: *Self) ?protocol.RuntimeCommand {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0) return null;
            const command = self.items[self.head] orelse return null;
            self.items[self.head] = null;
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return command;
        }

        pub fn depth(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }
    };
}

test "bounded command queue preserves FIFO and refuses overflow" {
    const Queue = CommandQueue(2);
    var queue = Queue{};
    const target = try protocol.EntityRef.init(.runtime, "runtime-1", "Runtime");
    const first = try protocol.RuntimeCommand.init("1", target, "runtime.pause", .test);
    const second = try protocol.RuntimeCommand.init("2", target, "runtime.resume", .test);
    const third = try protocol.RuntimeCommand.init("3", target, "runtime.stop", .test);

    try queue.push(first);
    try queue.push(second);
    try std.testing.expectError(error.QueueFull, queue.push(third));
    try std.testing.expectEqualStrings("1", queue.pop().?.command_id.slice());
    try std.testing.expectEqualStrings("2", queue.pop().?.command_id.slice());
    try std.testing.expect(queue.pop() == null);
}

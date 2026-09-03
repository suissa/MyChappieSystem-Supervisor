const std = @import("std");
const protocol = @import("protocol.zig");

pub const Handler = *const fn (protocol.RuntimeCommand) anyerror!void;

pub const CommandDescriptor = struct {
    canonical_name: protocol.Name,
    required_capability: protocol.Name = .{},
    safety: protocol.SafetyClass = .safe,
    supports_dry_run: bool = false,
    supports_rollback: bool = false,
    handler: Handler,
};

pub fn CommandRegistry(comptime capacity: usize) type {
    if (capacity == 0) @compileError("CommandRegistry capacity must be greater than zero");

    return struct {
        entries: [capacity]?CommandDescriptor = [_]?CommandDescriptor{null} ** capacity,
        len: usize = 0,

        const Self = @This();

        pub fn register(self: *Self, descriptor: CommandDescriptor) !void {
            if (self.len == capacity) return error.RegistryFull;
            if (self.find(descriptor.canonical_name.slice()) != null) return error.DuplicateCommand;
            self.entries[self.len] = descriptor;
            self.len += 1;
        }

        pub fn registerSimple(
            self: *Self,
            canonical_name: []const u8,
            capability: []const u8,
            safety: protocol.SafetyClass,
            handler: Handler,
        ) !void {
            try self.register(.{
                .canonical_name = try protocol.Name.init(canonical_name),
                .required_capability = try protocol.Name.init(capability),
                .safety = safety,
                .handler = handler,
            });
        }

        pub fn execute(self: *const Self, command: protocol.RuntimeCommand) !void {
            const descriptor = self.find(command.canonical_name.slice()) orelse return error.UnknownCommand;
            if (descriptor.safety != command.safety) return error.SafetyClassMismatch;
            try descriptor.handler(command);
        }

        pub fn find(self: *const Self, canonical_name: []const u8) ?CommandDescriptor {
            for (self.entries[0..self.len]) |maybe_entry| {
                const entry = maybe_entry orelse continue;
                if (std.mem.eql(u8, entry.canonical_name.slice(), canonical_name)) return entry;
            }
            return null;
        }
    };
}

test "command registry is fixed capacity and dispatches by canonical name" {
    const Registry = CommandRegistry(1);
    var registry = Registry{};
    const handler = struct {
        fn run(_: protocol.RuntimeCommand) !void {}
    }.run;

    try registry.registerSimple("config.reload", "config.write", .mutating, handler);
    try std.testing.expectError(error.RegistryFull, registry.registerSimple("runtime.stop", "runtime.admin", .destructive, handler));

    const target = try protocol.EntityRef.init(.runtime, "runtime-1", "Runtime");
    var command = try protocol.RuntimeCommand.init("cmd-1", target, "config.reload", .test);
    command.safety = .mutating;
    try registry.execute(command);
}

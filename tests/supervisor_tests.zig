const std = @import("std");
const ds = @import("development_supervisor");

test "foundation snapshot stays bounded and observable" {
    var supervisor = try ds.DevelopmentSupervisor.init("test-project", "test-runtime");
    const subscriber = try supervisor.subscribe();

    const action = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const bytes = try allocator.alloc(u8, 32);
            @memset(bytes, 0xA5);
        }
    }.run;

    const actor_id = try supervisor.spawnAction("Tests.foundation", action, 4096, .transient, 10);
    _ = try supervisor.runAction(actor_id, 20);

    const snapshot = supervisor.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.actions_completed);
    try std.testing.expect(snapshot.events_emitted >= 3);

    var event_count: usize = 0;
    while (supervisor.nextEvent(subscriber)) |_| event_count += 1;
    try std.testing.expect(event_count >= 3);
}

test "memory exhaustion creates a fresh replacement Actor" {
    var supervisor = try ds.DevelopmentSupervisor.init("test-project", "test-runtime");

    const action = struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = try allocator.alloc(u8, 8192);
        }
    }.run;

    const original = try supervisor.spawnAction("Tests.memoryPressure", action, 1024, .transient, 1);
    const replacement = try supervisor.runAction(original, 2);
    try std.testing.expect(replacement != original);
    try std.testing.expectEqual(ds.ActorState.replaced, supervisor.action_supervisor.get(original).?.state);
    try std.testing.expectEqual(ds.ActorState.restarting, supervisor.action_supervisor.get(replacement).?.state);
}

const std = @import("std");

pub const protocol_version: u16 = 1;

pub fn BoundedString(comptime capacity: usize) type {
    return struct {
        len: usize = 0,
        bytes: [capacity]u8 = [_]u8{0} ** capacity,

        const Self = @This();

        pub const Error = error{TooLong};

        pub fn init(value: []const u8) Error!Self {
            if (value.len > capacity) return error.TooLong;
            var out: Self = .{};
            @memcpy(out.bytes[0..value.len], value);
            out.len = value.len;
            return out;
        }

        pub fn set(self: *Self, value: []const u8) Error!void {
            if (value.len > capacity) return error.TooLong;
            @memset(self.bytes[0..], 0);
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const TinyText = BoundedString(32);
pub const Name = BoundedString(96);
pub const Id = BoundedString(128);
pub const Payload = BoundedString(4096);

pub const EntityKind = enum {
    project,
    flow,
    intent,
    agent,
    actor,
    action,
    attempt,
    function,
    event,
    process,
    thread,
    server,
    database,
    queue,
    workflow,
    test,
    supervisor,
    runtime,
};

pub const Severity = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    critical = 5,
};

pub const EventKind = enum {
    created,
    queued,
    started,
    progress,
    waiting,
    paused,
    resumed,
    completed,
    failed,
    cancelled,
    retrying,
    restarting,
    replaced,
    memory_pressure,
    memory_exhausted,
    mailbox_pressure,
    state_changed,
    metric_sampled,
    log_emitted,
    command_accepted,
    command_rejected,
    command_completed,
    command_failed,
    config_changed,
    connected,
    disconnected,
};

pub const CommandSource = enum {
    tui,
    rest,
    websocket,
    automation,
    ci,
    supervisor,
    test,
    stdio,
};

pub const SafetyClass = enum {
    observe,
    safe,
    mutating,
    destructive,
};

pub const EntityRef = struct {
    kind: EntityKind,
    id: Id,
    canonical_name: Name,

    pub fn init(kind: EntityKind, id: []const u8, canonical_name: []const u8) !EntityRef {
        return .{
            .kind = kind,
            .id = try Id.init(id),
            .canonical_name = try Name.init(canonical_name),
        };
    }
};

pub const TraceContext = struct {
    trace_id: Id = .{},
    span_id: Id = .{},
    parent_span_id: Id = .{},
};

pub const RuntimeEvent = struct {
    version: u16 = protocol_version,
    sequence: u64,
    timestamp_ns: u64,
    project_id: Id = .{},
    runtime_id: Id = .{},
    server_id: Id = .{},
    correlation_id: Id = .{},
    causation_id: Id = .{},
    trace: TraceContext = .{},
    entity: EntityRef,
    kind: EventKind,
    severity: Severity = .info,
    payload: Payload = .{},

    pub fn isCritical(self: *const RuntimeEvent) bool {
        return self.severity == .critical or
            self.severity == .err or
            self.kind == .failed or
            self.kind == .memory_exhausted or
            self.kind == .command_failed;
    }
};

pub const RuntimeCommand = struct {
    version: u16 = protocol_version,
    command_id: Id,
    target: EntityRef,
    canonical_name: Name,
    parameters: Payload = .{},
    source: CommandSource,
    required_capability: Name = .{},
    safety: SafetyClass = .safe,
    timeout_ns: u64 = 0,
    idempotency_key: Id = .{},
    expected_version: ?u64 = null,

    pub fn init(
        command_id: []const u8,
        target: EntityRef,
        canonical_name: []const u8,
        source: CommandSource,
    ) !RuntimeCommand {
        return .{
            .command_id = try Id.init(command_id),
            .target = target,
            .canonical_name = try Name.init(canonical_name),
            .source = source,
        };
    }
};

pub const RuntimeSnapshot = struct {
    version: u16 = protocol_version,
    sequence: u64 = 0,
    active_flows: u32 = 0,
    actors_running: u32 = 0,
    actors_waiting: u32 = 0,
    actors_failed: u32 = 0,
    actions_completed: u64 = 0,
    actions_failed: u64 = 0,
    events_emitted: u64 = 0,
    events_dropped: u64 = 0,
};

test "bounded string rejects oversized values" {
    const Small = BoundedString(4);
    try std.testing.expectError(error.TooLong, Small.init("12345"));
    const value = try Small.init("1234");
    try std.testing.expectEqualStrings("1234", value.slice());
}

test "critical runtime event classification" {
    const entity = try EntityRef.init(.action, "a-1", "Inventory.removeProduct");
    const ev = RuntimeEvent{
        .sequence = 1,
        .timestamp_ns = 1,
        .entity = entity,
        .kind = .failed,
    };
    try std.testing.expect(ev.isCritical());
}

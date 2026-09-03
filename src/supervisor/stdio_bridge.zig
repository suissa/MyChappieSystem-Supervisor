const std = @import("std");
const protocol = @import("protocol.zig");

pub const max_ndjson_line_bytes = 16 * 1024;

const WireEntity = struct {
    kind: protocol.EntityKind,
    id: []const u8,
    canonical_name: []const u8,
};

const WireTrace = struct {
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: []const u8,
};

const WireEvent = struct {
    version: u16,
    sequence: u64,
    timestamp_ns: u64,
    project_id: []const u8,
    runtime_id: []const u8,
    server_id: []const u8,
    correlation_id: []const u8,
    causation_id: []const u8,
    trace: WireTrace,
    entity: WireEntity,
    kind: protocol.EventKind,
    severity: protocol.Severity,
    payload: []const u8,
};

const WireCommand = struct {
    version: u16 = protocol.protocol_version,
    command_id: []const u8,
    target: WireEntity,
    canonical_name: []const u8,
    parameters: []const u8 = "",
    source: protocol.CommandSource,
    required_capability: []const u8 = "",
    safety: protocol.SafetyClass = .safe,
    timeout_ns: u64 = 0,
    idempotency_key: []const u8 = "",
    expected_version: ?u64 = null,
};

pub fn writeEvent(writer: *std.Io.Writer, event: *const protocol.RuntimeEvent) !void {
    const wire = WireEvent{
        .version = event.version,
        .sequence = event.sequence,
        .timestamp_ns = event.timestamp_ns,
        .project_id = event.project_id.slice(),
        .runtime_id = event.runtime_id.slice(),
        .server_id = event.server_id.slice(),
        .correlation_id = event.correlation_id.slice(),
        .causation_id = event.causation_id.slice(),
        .trace = .{
            .trace_id = event.trace.trace_id.slice(),
            .span_id = event.trace.span_id.slice(),
            .parent_span_id = event.trace.parent_span_id.slice(),
        },
        .entity = .{
            .kind = event.entity.kind,
            .id = event.entity.id.slice(),
            .canonical_name = event.entity.canonical_name.slice(),
        },
        .kind = event.kind,
        .severity = event.severity,
        .payload = event.payload.slice(),
    };
    try std.json.Stringify.value(wire, .{}, writer);
    try writer.writeByte('\n');
}

pub fn writeCommand(writer: *std.Io.Writer, command: *const protocol.RuntimeCommand) !void {
    const wire = WireCommand{
        .version = command.version,
        .command_id = command.command_id.slice(),
        .target = .{
            .kind = command.target.kind,
            .id = command.target.id.slice(),
            .canonical_name = command.target.canonical_name.slice(),
        },
        .canonical_name = command.canonical_name.slice(),
        .parameters = command.parameters.slice(),
        .source = command.source,
        .required_capability = command.required_capability.slice(),
        .safety = command.safety,
        .timeout_ns = command.timeout_ns,
        .idempotency_key = command.idempotency_key.slice(),
        .expected_version = command.expected_version,
    };
    try std.json.Stringify.value(wire, .{}, writer);
    try writer.writeByte('\n');
}

/// Decode one NDJSON command line using a fixed parse arena. No parse memory
/// survives this function: every string is copied into bounded protocol fields.
pub fn decodeCommand(line_with_newline: []const u8) !protocol.RuntimeCommand {
    const line = std.mem.trimRight(u8, line_with_newline, "\r\n");
    if (line.len == 0) return error.EmptyLine;
    if (line.len > max_ndjson_line_bytes) return error.LineTooLong;

    var parse_memory: [max_ndjson_line_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_memory);
    var parsed = try std.json.parseFromSlice(WireCommand, fba.allocator(), line, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const wire = parsed.value;
    if (wire.version != protocol.protocol_version) return error.UnsupportedProtocolVersion;

    const target = try protocol.EntityRef.init(
        wire.target.kind,
        wire.target.id,
        wire.target.canonical_name,
    );
    var command = try protocol.RuntimeCommand.init(
        wire.command_id,
        target,
        wire.canonical_name,
        wire.source,
    );
    try command.parameters.set(wire.parameters);
    try command.required_capability.set(wire.required_capability);
    command.safety = wire.safety;
    command.timeout_ns = wire.timeout_ns;
    try command.idempotency_key.set(wire.idempotency_key);
    command.expected_version = wire.expected_version;
    return command;
}

test "NDJSON command decoding copies into bounded protocol" {
    const json =
        \\{"version":1,"command_id":"cmd-1","target":{"kind":"runtime","id":"runtime-1","canonical_name":"Runtime"},"canonical_name":"config.reload","parameters":"{}","source":"stdio","required_capability":"config.write","safety":"mutating","timeout_ns":1000,"idempotency_key":"idem-1"}
    ;
    const command = try decodeCommand(json);
    try std.testing.expectEqualStrings("config.reload", command.canonical_name.slice());
    try std.testing.expectEqual(protocol.CommandSource.stdio, command.source);
    try std.testing.expectEqual(protocol.SafetyClass.mutating, command.safety);
}

test "NDJSON event encoding is newline terminated" {
    const entity = try protocol.EntityRef.init(.runtime, "runtime-1", "Runtime");
    const event = protocol.RuntimeEvent{
        .sequence = 1,
        .timestamp_ns = 2,
        .entity = entity,
        .kind = .started,
    };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeEvent(&writer, &event);
    const encoded = writer.buffered();
    try std.testing.expect(encoded.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), encoded[encoded.len - 1]);
}

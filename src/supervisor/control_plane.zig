const std = @import("std");
const protocol = @import("protocol.zig");
const ndjson = @import("stdio_bridge.zig");

pub const default_port: u16 = 8787;
pub const max_connections: usize = 6;
pub const max_command_body_bytes: usize = ndjson.max_ndjson_line_bytes;

/// Bounded HTTP control plane. Runtime is generic to keep this module free of
/// circular imports; it expects the DevelopmentSupervisor public surface:
/// subscribe/unsubscribe/nextEvent, submitCommand and readPublishedSnapshot.
pub fn ControlPlane(comptime Runtime: type) type {
    return struct {
        io: std.Io,
        address: std.Io.net.IpAddress,
        runtime: ?*Runtime = null,
        server: ?std.Io.net.Server = null,
        accept_thread: ?std.Thread = null,
        stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        connection_mutex: std.Thread.Mutex = .{},
        connections: [max_connections]ConnectionSlot = [_]ConnectionSlot{.{}} ** max_connections,

        const Self = @This();
        const http = std.http;

        const ConnectionSlot = struct {
            active: bool = false,
            closed_by_supervisor: bool = false,
            stream: std.Io.net.Stream = undefined,
        };

        pub fn init(io: std.Io, host: []const u8, port: u16) !Self {
            return .{
                .io = io,
                .address = try std.Io.net.IpAddress.parse(host, port),
            };
        }

        /// Must be called after this ControlPlane has reached its final memory
        /// location because the accept thread retains `self`.
        pub fn start(self: *Self, runtime: *Runtime) !void {
            if (self.accept_thread != null) return error.AlreadyStarted;
            self.runtime = runtime;
            self.stopping.store(false, .release);
            self.server = try self.address.listen(self.io, .{ .reuse_address = true });
            errdefer {
                self.server.?.deinit(self.io);
                self.server = null;
                self.runtime = null;
            }
            self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        }

        pub fn stop(self: *Self) void {
            if (self.accept_thread == null) return;
            self.stopping.store(true, .release);

            // Wake accept() so the accept thread can observe `stopping`.
            if (self.address.connect(self.io, .{ .mode = .stream })) |stream| {
                var wake = stream;
                wake.close(self.io);
            } else |_| {}

            self.accept_thread.?.join();
            self.accept_thread = null;

            if (self.server) |*server| server.deinit(self.io);
            self.server = null;

            // Interrupt long-lived SSE/WS reads/writes. Close a copy of the
            // Stream handle so the connection thread's struct memory remains
            // valid; `closed_by_supervisor` prevents a second OS close.
            self.connection_mutex.lock();
            for (&self.connections) |*slot| {
                if (!slot.active or slot.closed_by_supervisor) continue;
                slot.closed_by_supervisor = true;
                var copy = slot.stream;
                copy.close(self.io);
            }
            self.connection_mutex.unlock();

            // Correctness is more important than a timed shutdown here: the
            // runtime pointer must stay valid until every detached connection
            // thread has stopped using it. Closing the sockets above unblocks
            // HTTP, SSE and WebSocket reads/writes.
            while (self.activeConnections() != 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            self.runtime = null;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
        }

        pub fn isRunning(self: *const Self) bool {
            return self.accept_thread != null and !self.stopping.load(.acquire);
        }

        pub fn activeConnections(self: *Self) usize {
            self.connection_mutex.lock();
            defer self.connection_mutex.unlock();
            var count: usize = 0;
            for (self.connections) |slot| {
                if (slot.active) count += 1;
            }
            return count;
        }

        fn acceptLoop(self: *Self) void {
            while (!self.stopping.load(.acquire)) {
                const stream = self.server.?.accept(self.io) catch break;
                if (self.stopping.load(.acquire)) {
                    var closing = stream;
                    closing.close(self.io);
                    break;
                }

                const slot_index = self.claimConnection(stream) orelse {
                    var rejected = stream;
                    rejected.close(self.io);
                    continue;
                };

                const thread = std.Thread.spawn(.{}, connectionMain, .{ self, slot_index }) catch {
                    self.finishConnection(slot_index);
                    continue;
                };
                thread.detach();
            }
        }

        fn claimConnection(self: *Self, stream: std.Io.net.Stream) ?usize {
            self.connection_mutex.lock();
            defer self.connection_mutex.unlock();
            for (&self.connections, 0..) |*slot, index| {
                if (slot.active) continue;
                slot.* = .{
                    .active = true,
                    .closed_by_supervisor = false,
                    .stream = stream,
                };
                return index;
            }
            return null;
        }

        fn finishConnection(self: *Self, index: usize) void {
            self.connection_mutex.lock();
            defer self.connection_mutex.unlock();
            const slot = &self.connections[index];
            if (!slot.active) return;
            if (!slot.closed_by_supervisor) slot.stream.close(self.io);
            slot.active = false;
        }

        fn connectionMain(self: *Self, index: usize) void {
            defer self.finishConnection(index);
            const stream = &self.connections[index].stream;

            var send_buffer: [8192]u8 = undefined;
            var recv_buffer: [8192]u8 = undefined;
            var connection_reader = stream.reader(self.io, &recv_buffer);
            var connection_writer = stream.writer(self.io, &send_buffer);
            var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

            while (!self.stopping.load(.acquire)) {
                var request = server.receiveHead() catch return;
                switch (request.upgradeRequested()) {
                    .websocket => |maybe_key| {
                        if (!std.mem.eql(u8, request.head.target, "/ws")) {
                            request.respond("websocket endpoint is /ws", .{ .status = .not_found }) catch {};
                            return;
                        }
                        const key = maybe_key orelse {
                            request.respond("missing websocket key", .{ .status = .bad_request }) catch {};
                            return;
                        };
                        var ws = request.respondWebSocket(.{ .key = key }) catch return;
                        self.serveWebSocket(&ws);
                        return;
                    },
                    .other => return,
                    .none => {
                        if (!self.serveRequest(&request)) return;
                    },
                }
            }
        }

        /// Returns whether this HTTP connection can continue receiving normal
        /// HTTP requests. Long-lived SSE returns false when its stream ends.
        fn serveRequest(self: *Self, request: *http.Server.Request) bool {
            const target = request.head.target;

            if (request.head.method == .GET and std.mem.eql(u8, target, "/health")) {
                request.respond("{\"status\":\"ok\"}", .{
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                }) catch return false;
                return true;
            }

            if (request.head.method == .GET and std.mem.eql(u8, target, "/snapshot")) {
                self.respondSnapshot(request) catch return false;
                return true;
            }

            if (request.head.method == .GET and std.mem.eql(u8, target, "/capabilities")) {
                request.respond(capabilities_json, .{
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                }) catch return false;
                return true;
            }

            if (request.head.method == .GET and std.mem.eql(u8, target, "/events")) {
                self.serveSse(request) catch {};
                return false;
            }

            if (request.head.method == .POST and std.mem.eql(u8, target, "/commands")) {
                self.acceptRestCommand(request) catch |err| {
                    var error_buf: [192]u8 = undefined;
                    const body = std.fmt.bufPrint(&error_buf, "{{\"accepted\":false,\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"accepted\":false}";
                    request.respond(body, .{
                        .status = .bad_request,
                        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
                    }) catch {};
                };
                return true;
            }

            request.respond("not found", .{ .status = .not_found }) catch return false;
            return true;
        }

        fn respondSnapshot(self: *Self, request: *http.Server.Request) !void {
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            const snapshot = runtime.readPublishedSnapshot();
            var body_buf: [768]u8 = undefined;
            const body = try snapshotJson(&body_buf, snapshot);
            try request.respond(body, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        }

        fn acceptRestCommand(self: *Self, request: *http.Server.Request) !void {
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            const content_length_u64 = request.head.content_length orelse return error.ContentLengthRequired;
            if (content_length_u64 == 0 or content_length_u64 > max_command_body_bytes) return error.InvalidContentLength;
            const content_length: usize = @intCast(content_length_u64);

            var body: [max_command_body_bytes]u8 = undefined;
            var reader = try request.readerExpectContinue(&.{});
            try reader.readSliceAll(body[0..content_length]);

            var command = try ndjson.decodeCommand(body[0..content_length]);
            command.source = .rest;
            try runtime.submitCommand(command);

            var response_buf: [256]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buf,
                "{{\"accepted\":true,\"command_id\":\"{s}\"}}",
                .{command.command_id.slice()},
            );
            try request.respond(response, .{
                .status = .accepted,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        }

        fn serveSse(self: *Self, request: *http.Server.Request) !void {
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            const subscriber = try runtime.subscribe();
            defer runtime.unsubscribe(subscriber);

            var send_buffer: [8192]u8 = undefined;
            var response = try request.respondStreaming(&send_buffer, .{
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/event-stream" },
                        .{ .name = "Cache-Control", .value = "no-cache" },
                        .{ .name = "X-Accel-Buffering", .value = "no" },
                    },
                },
            });

            try response.writer.writeAll("retry: 1000\n\n");
            try response.flush();

            while (!self.stopping.load(.acquire)) {
                if (runtime.nextEvent(subscriber)) |event| {
                    try response.writer.print("id: {d}\nevent: {s}\ndata: ", .{ event.sequence, @tagName(event.kind) });
                    try ndjson.writeEvent(&response.writer, &event);
                    try response.writer.writeByte('\n');
                    try response.flush();
                } else {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                }
            }
            response.end() catch {};
        }

        fn serveWebSocket(self: *Self, ws: *http.Server.WebSocket) void {
            const runtime = self.runtime orelse return;
            const subscriber = runtime.subscribe() catch return;
            defer runtime.unsubscribe(subscriber);

            var sender_stop = std.atomic.Value(bool).init(false);
            var sender_ctx = WsSenderContext{
                .control = self,
                .runtime = runtime,
                .ws = ws,
                .subscriber = subscriber,
                .stop = &sender_stop,
            };
            const sender_thread = std.Thread.spawn(.{}, wsSender, .{&sender_ctx}) catch return;
            defer {
                sender_stop.store(true, .release);
                sender_thread.join();
            }

            while (!self.stopping.load(.acquire)) {
                const message = ws.readSmallMessage() catch return;
                switch (message.opcode) {
                    .text, .binary => {
                        if (std.mem.eql(u8, message.data, "ping")) continue;
                        var command = ndjson.decodeCommand(message.data) catch continue;
                        command.source = .websocket;
                        runtime.submitCommand(command) catch continue;
                    },
                    .ping, .pong => {},
                    else => {},
                }
            }
        }

        const WsSenderContext = struct {
            control: *Self,
            runtime: *Runtime,
            ws: *http.Server.WebSocket,
            subscriber: usize,
            stop: *std.atomic.Value(bool),
        };

        fn wsSender(ctx: *WsSenderContext) void {
            var snapshot_buf: [768]u8 = undefined;
            const snapshot = ctx.runtime.readPublishedSnapshot();
            const snapshot_json = snapshotJson(&snapshot_buf, snapshot) catch return;

            var initial_buf: [896]u8 = undefined;
            const initial = std.fmt.bufPrint(&initial_buf, "{{\"type\":\"snapshot\",\"data\":{s}}}", .{snapshot_json}) catch return;
            ctx.ws.writeMessage(initial, .text) catch return;

            while (!ctx.stop.load(.acquire) and !ctx.control.stopping.load(.acquire)) {
                if (ctx.runtime.nextEvent(ctx.subscriber)) |event| {
                    var event_buf: [ndjson.max_ndjson_line_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&event_buf);
                    ndjson.writeEvent(&writer, &event) catch return;
                    ctx.ws.writeMessage(writer.buffered(), .text) catch return;
                } else {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                }
            }
        }

        fn snapshotJson(buffer: []u8, snapshot: protocol.RuntimeSnapshot) ![]const u8 {
            return std.fmt.bufPrint(buffer,
                "{{\"version\":{d},\"sequence\":{d},\"active_flows\":{d},\"actors_running\":{d},\"actors_waiting\":{d},\"actors_failed\":{d},\"actions_completed\":{d},\"actions_failed\":{d},\"events_emitted\":{d},\"events_dropped\":{d}}}",
                .{
                    snapshot.version,
                    snapshot.sequence,
                    snapshot.active_flows,
                    snapshot.actors_running,
                    snapshot.actors_waiting,
                    snapshot.actors_failed,
                    snapshot.actions_completed,
                    snapshot.actions_failed,
                    snapshot.events_emitted,
                    snapshot.events_dropped,
                },
            );
        }

        const capabilities_json =
            "{\"commands\":[\"runtime.refresh\",\"runtime.shutdown\",\"actor.pause\",\"actor.resume\",\"actor.cancel\"]," ++
            "\"events\":[\"websocket\",\"sse\"],\"protocol_version\":1}";
    };
}

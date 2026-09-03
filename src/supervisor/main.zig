const std = @import("std");
const zz = @import("zigzag");
const ds = @import("development_supervisor");

const Model = struct {
    supervisor: ds.DevelopmentSupervisor,
    subscriber: ds.DefaultEventBus.SubscriberId,
    snapshot: ds.RuntimeSnapshot = .{},
    recent_events: [10]?ds.RuntimeEvent = [_]?ds.RuntimeEvent{null} ** 10,
    recent_len: usize = 0,
    ticks: u64 = 0,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, _: *zz.Context) !zz.Cmd(Msg) {
        self.supervisor = try ds.DevelopmentSupervisor.init("allascode-project", "development-supervisor");
        self.subscriber = try self.supervisor.subscribe();
        self.snapshot = self.supervisor.snapshot();
        self.recent_events = [_]?ds.RuntimeEvent{null} ** 10;
        self.recent_len = 0;
        self.ticks = 0;

        const boot_action = struct {
            fn run(allocator: std.mem.Allocator) !void {
                const boot_marker = try allocator.alloc(u8, 64);
                @memset(boot_marker, 0);
            }
        }.run;

        const actor_id = try self.supervisor.spawnAction(
            "DevelopmentSupervisor.boot",
            boot_action,
            1024,
            .temporary,
            0,
        );
        _ = try self.supervisor.runAction(actor_id, 1);
        self.drainEvents();
        self.snapshot = self.supervisor.snapshot();
        return zz.Cmd(Msg).tickMs(250);
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .tick => {
                self.ticks += 1;
                self.drainEvents();
                self.snapshot = self.supervisor.snapshot();
                return zz.Cmd(Msg).tickMs(250);
            },
            .key => |key| switch (key.key) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    'r' => {
                        self.snapshot = self.supervisor.snapshot();
                        self.drainEvents();
                    },
                    else => {},
                },
                .escape => return .quit,
                else => {},
            },
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const header = try self.renderHeader(ctx);
        const runtime = try self.renderRuntime(ctx);
        const actors = try self.renderActors(ctx);
        const events = try self.renderEvents(ctx);
        const top = try zz.joinHorizontal(ctx.allocator, &.{ runtime, "  ", actors });
        const body = try zz.joinVertical(ctx.allocator, &.{ header, "", top, "", events });

        var help_style = zz.Style{};
        help_style = help_style.fg(zz.Color.gray(12)).inline_style(true);
        const help = try help_style.render(ctx.allocator, "q: quit   r: refresh   |   zig build supervise");
        const all = try zz.joinVertical(ctx.allocator, &.{ body, "", help });

        return zz.place.place(ctx.allocator, ctx.width, ctx.height, .center, .middle, all);
    }

    fn drainEvents(self: *Model) void {
        while (self.supervisor.nextEvent(self.subscriber)) |event| {
            if (self.recent_len < self.recent_events.len) {
                self.recent_events[self.recent_len] = event;
                self.recent_len += 1;
            } else {
                var i: usize = 1;
                while (i < self.recent_events.len) : (i += 1) {
                    self.recent_events[i - 1] = self.recent_events[i];
                }
                self.recent_events[self.recent_events.len - 1] = event;
            }
        }
    }

    fn renderHeader(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        var title_style = zz.Style{};
        title_style = title_style.bold(true).fg(zz.Color.hex("#66F7FF")).inline_style(true);
        var live_style = zz.Style{};
        live_style = live_style.bold(true).fg(zz.Color.hex("#9B5CFF")).inline_style(true);
        var meta_style = zz.Style{};
        meta_style = meta_style.fg(zz.Color.hex("#52A7FF")).inline_style(true);

        const title = try title_style.render(ctx.allocator, "ALLASCODE DEVELOPMENT SUPERVISOR");
        const live = try live_style.render(ctx.allocator, "● LIVE");
        const meta_raw = try std.fmt.allocPrint(ctx.allocator,
            "Actors {d} running / {d} waiting / {d} failed   Events {d}   Dropped {d}   UI {d:.0} fps",
            .{
                self.snapshot.actors_running,
                self.snapshot.actors_waiting,
                self.snapshot.actors_failed,
                self.snapshot.events_emitted,
                self.snapshot.events_dropped,
                ctx.fps(),
            },
        );
        const meta = try meta_style.render(ctx.allocator, meta_raw);
        const first = try zz.joinHorizontal(ctx.allocator, &.{ title, "    ", live });
        return zz.joinVertical(ctx.allocator, &.{ first, meta });
    }

    fn renderRuntime(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        var box = zz.Style{};
        box = box.borderAll(zz.Border.rounded).borderForeground(zz.Color.hex("#42DDF5")).paddingAll(1).width(40);
        var heading = zz.Style{};
        heading = heading.bold(true).fg(zz.Color.hex("#42DDF5")).inline_style(true);
        const h = try heading.render(ctx.allocator, "Runtime");
        const body = try std.fmt.allocPrint(ctx.allocator,
            "{s}\n\nActions completed  {d}\nActions failed     {d}\nEvent sequence     {d}\nRefresh ticks      {d}",
            .{ h, self.snapshot.actions_completed, self.snapshot.actions_failed, self.snapshot.sequence, self.ticks },
        );
        return box.render(ctx.allocator, body);
    }

    fn renderActors(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        var box = zz.Style{};
        box = box.borderAll(zz.Border.rounded).borderForeground(zz.Color.hex("#985DFF")).paddingAll(1).width(40);
        var heading = zz.Style{};
        heading = heading.bold(true).fg(zz.Color.hex("#985DFF")).inline_style(true);
        const h = try heading.render(ctx.allocator, "Bounded Actor Runtime");
        const body = try std.fmt.allocPrint(ctx.allocator,
            "{s}\n\nSlots              16\nMax memory / Actor 64 KiB\nMailbox / Actor    4 commands\nHeap growth         disabled by contract",
            .{h},
        );
        return box.render(ctx.allocator, body);
    }

    fn renderEvents(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        var box = zz.Style{};
        box = box.borderAll(zz.Border.rounded).borderForeground(zz.Color.hex("#666BFF")).paddingAll(1).width(82);
        var heading = zz.Style{};
        heading = heading.bold(true).fg(zz.Color.hex("#666BFF")).inline_style(true);
        const h = try heading.render(ctx.allocator, "Recent RuntimeEvents");

        var lines: []const u8 = h;
        var index: usize = 0;
        while (index < self.recent_len) : (index += 1) {
            const event = self.recent_events[index] orelse continue;
            const line = try std.fmt.allocPrint(ctx.allocator,
                "#{d:<4} {s:<18} {s}",
                .{ event.sequence, @tagName(event.kind), event.entity.canonical_name.slice() },
            );
            lines = try zz.joinVertical(ctx.allocator, &.{ lines, line });
        }
        if (self.recent_len == 0) lines = try zz.joinVertical(ctx.allocator, &.{ lines, "No events yet" });
        return box.render(ctx.allocator, lines);
    }
};

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(Model).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .title = "AllasCode DevelopmentSupervisor",
        .fps = 30,
        .mouse = true,
        .render_mode = .diff,
    });
    defer program.deinit();
    try program.run();
}

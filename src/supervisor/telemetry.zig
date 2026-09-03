const std = @import("std");
const builtin = @import("builtin");

pub const HardwareSample = struct {
    supported: bool = false,
    cpu_percent: f64 = 0,
    memory_used_bytes: u64 = 0,
    memory_total_bytes: u64 = 0,
    memory_percent: f64 = 0,
    load_1m: f64 = 0,
    process_count: u32 = 0,
};

pub const Sampler = struct {
    previous_cpu_total: u64 = 0,
    previous_cpu_idle: u64 = 0,
    has_cpu_baseline: bool = false,

    pub fn sample(self: *Sampler, io: std.Io) HardwareSample {
        return switch (builtin.os.tag) {
            .linux => self.sampleLinux(io),
            else => .{},
        };
    }

    fn sampleLinux(self: *Sampler, io: std.Io) HardwareSample {
        var out = HardwareSample{ .supported = true };
        self.sampleLinuxCpu(io, &out) catch out.supported = false;
        self.sampleLinuxMemory(io, &out) catch out.supported = false;
        self.sampleLinuxLoad(io, &out) catch {};
        return out;
    }

    fn sampleLinuxCpu(self: *Sampler, io: std.Io, out: *HardwareSample) !void {
        var buffer: [4096]u8 = undefined;
        const contents = try std.Io.Dir.cwd().readFile(io, "/proc/stat", &buffer);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        const cpu_line = lines.next() orelse return error.InvalidProcStat;
        var tokens = std.mem.tokenizeAny(u8, cpu_line, " \t");
        const label = tokens.next() orelse return error.InvalidProcStat;
        if (!std.mem.eql(u8, label, "cpu")) return error.InvalidProcStat;

        var values: [8]u64 = [_]u64{0} ** 8;
        var index: usize = 0;
        while (index < values.len) : (index += 1) {
            const token = tokens.next() orelse break;
            values[index] = try std.fmt.parseInt(u64, token, 10);
        }

        var total: u64 = 0;
        for (values) |value| total +%= value;
        const idle = values[3] +% values[4];

        if (self.has_cpu_baseline and total >= self.previous_cpu_total and idle >= self.previous_cpu_idle) {
            const total_delta = total - self.previous_cpu_total;
            const idle_delta = idle - self.previous_cpu_idle;
            if (total_delta > 0) {
                const busy_delta = total_delta -| idle_delta;
                out.cpu_percent = @as(f64, @floatFromInt(busy_delta)) * 100.0 /
                    @as(f64, @floatFromInt(total_delta));
            }
        }

        self.previous_cpu_total = total;
        self.previous_cpu_idle = idle;
        self.has_cpu_baseline = true;
    }

    fn sampleLinuxMemory(_: *Sampler, io: std.Io, out: *HardwareSample) !void {
        var buffer: [8192]u8 = undefined;
        const contents = try std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer);
        var total_kib: u64 = 0;
        var available_kib: u64 = 0;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var tokens = std.mem.tokenizeAny(u8, line, " :\t");
            const key = tokens.next() orelse continue;
            const value_text = tokens.next() orelse continue;
            if (std.mem.eql(u8, key, "MemTotal")) {
                total_kib = std.fmt.parseInt(u64, value_text, 10) catch 0;
            } else if (std.mem.eql(u8, key, "MemAvailable")) {
                available_kib = std.fmt.parseInt(u64, value_text, 10) catch 0;
            }
        }

        if (total_kib == 0) return error.InvalidMemInfo;
        const used_kib = total_kib -| available_kib;
        out.memory_total_bytes = total_kib * 1024;
        out.memory_used_bytes = used_kib * 1024;
        out.memory_percent = @as(f64, @floatFromInt(used_kib)) * 100.0 /
            @as(f64, @floatFromInt(total_kib));
    }

    fn sampleLinuxLoad(_: *Sampler, io: std.Io, out: *HardwareSample) !void {
        var buffer: [256]u8 = undefined;
        const contents = try std.Io.Dir.cwd().readFile(io, "/proc/loadavg", &buffer);
        var tokens = std.mem.tokenizeAny(u8, contents, " \t\n");
        const load = tokens.next() orelse return error.InvalidLoadAvg;
        out.load_1m = try std.fmt.parseFloat(f64, load);

        _ = tokens.next();
        _ = tokens.next();
        const processes = tokens.next() orelse return;
        var proc_tokens = std.mem.splitScalar(u8, processes, '/');
        _ = proc_tokens.next();
        const total_processes = proc_tokens.next() orelse return;
        out.process_count = std.fmt.parseInt(u32, total_processes, 10) catch 0;
    }
};

test "unsupported platforms return a safe zero sample" {
    if (builtin.os.tag == .linux) return;
    var sampler = Sampler{};
    const sample = sampler.sample(std.testing.io);
    try std.testing.expect(!sample.supported);
}

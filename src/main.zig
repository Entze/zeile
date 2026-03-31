const std = @import("std");
const zeile = @import("zeile");

/// Maximum assumed length of any string value in the JSON input.
const json_string_len_max = 256;

/// Comptime upper bound on the JSON byte size for a given type,
/// assuming string values are at most `json_string_len_max` bytes.
fn jsonSizeMax(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            var size: comptime_int = 2; // {}
            for (s.fields) |f| {
                size += f.name.len + 2 + 2 + 2; // "name": ,\n
                size += jsonSizeMax(f.type);
            }
            break :blk size;
        },
        .optional => |o| @max(4, jsonSizeMax(o.child)), // "null" or inner
        .pointer => |p| if (p.size == .slice and p.child == u8) json_string_len_max + 2 else 0,
        .float => 24,
        .int => 20,
        .bool => 5,
        .@"enum" => |e| blk: {
            var max_len: comptime_int = 0;
            for (e.fields) |f| {
                if (f.name.len > max_len) max_len = f.name.len;
            }
            break :blk max_len + 2; // quotes
        },
        else => 0,
    };
}

/// Maximum expected size of the JSON input from stdin.
const input_bytes_max = jsonSizeMax(zeile.SessionData);

/// Size of the I/O streaming buffer.
const io_buf_size = 4096;

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io_buf = allocator.create([io_buf_size]u8) catch
        std.debug.panic("error: failed to allocate {Bi} for the io buffer", .{io_buf_size});
    defer allocator.destroy(io_buf);
    const input_buf = allocator.alloc(u8, input_bytes_max) catch
        std.debug.panic("error: failed to allocate {Bi} for the input buffer", .{input_bytes_max});
    defer allocator.free(input_buf);

    const input_len = std.fs.File.stdin().readAll(input_buf) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stderr().writerStreaming(&buf);
        w.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
    const input = input_buf[0..input_len];

    var w = std.fs.File.stdout().writerStreaming(io_buf);
    run(allocator, input, &w.interface) catch |err| {
        var buf: [256]u8 = undefined;
        var ew = std.fs.File.stderr().writerStreaming(&buf);
        ew.interface.print("error: failed to process session data ({s})\n", .{@errorName(err)}) catch {};
        ew.interface.flush() catch {};
        std.process.exit(1);
    };
    w.interface.flush() catch {};
}

fn run(allocator: std.mem.Allocator, input: []const u8, writer: *std.io.Writer) !void {
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, input, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const red = "\x1B[31m";
    const yellow = "\x1B[33m";
    const green = "\x1B[32m";
    const reset = "\x1B[0m";
    const five_hour_used_percentage = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.five_hour != null) parsed.value.rate_limits.?.five_hour.?.used_percentage else 0.0;
    const five_hour_resets_at: i64 = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.five_hour != null) @intCast(parsed.value.rate_limits.?.five_hour.?.resets_at) else 0;
    const five_hour_resets_in_ns: i64 = @min(@max(0, five_hour_resets_at - std.time.timestamp()) * std.time.ns_per_s, 5 * std.time.ns_per_hour);
    const five_hour_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "+", "x", "#" }, "]", five_hour_used_percentage);
    var five_hour_bar_color = green;
    if (five_hour_used_percentage >= 88.8) {
        five_hour_bar_color = red;
    } else if (five_hour_used_percentage >= 66.6) {
        five_hour_bar_color = yellow;
    }
    const seven_day_resets_at: i64 = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.seven_day != null) @intCast(parsed.value.rate_limits.?.seven_day.?.resets_at) else 0;
    const seven_day_resets_in_ns: i64 = @min(@max(0, seven_day_resets_at - std.time.timestamp()) * std.time.ns_per_s, 7 * std.time.ns_per_week);
    const seven_day_used_percentage = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.seven_day != null) parsed.value.rate_limits.?.seven_day.?.used_percentage else 0.0;
    const seven_day_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "+", "x", "#" }, "]", seven_day_used_percentage);

    var seven_day_bar_color = green;
    if (seven_day_used_percentage >= 90.0) {
        seven_day_bar_color = red;
    } else if (seven_day_used_percentage >= 75.0) {
        seven_day_bar_color = yellow;
    }
    const ctx_percentage = parsed.value.context_window.used_percentage orelse 0;
    const ctx_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "^", "<", "v", "+", "x", "#" }, "]", @floatFromInt(ctx_percentage));

    var ctx_bar_color = green;
    if (ctx_percentage >= 65.0) {
        ctx_bar_color = red;
    } else if (ctx_percentage >= 50.0) {
        ctx_bar_color = yellow;
    }
    const args = .{ parsed.value.model.display_name, parsed.value.cost.total_cost_usd, green, parsed.value.cost.total_lines_added, red, parsed.value.cost.total_lines_removed, reset, five_hour_bar_color, five_hour_bar, reset, five_hour_used_percentage, five_hour_resets_in_ns, seven_day_bar_color, seven_day_bar, reset, seven_day_used_percentage, seven_day_resets_in_ns, ctx_bar_color, ctx_bar, reset, ctx_percentage };
    try writer.print("Claude {s} [${d:.2}] [{s}+{d}{s}-{d}{s}]\n[5D: {s}{s}{s} {d: >5.1}% {D}] [7D: {s}{s}{s} {d: >5.1}% {D}] [CTX: {s}{s}{s} {d: >3}%]", args);
    try writer.writeByte('\n');
}

const testing = std.testing;

test "run: complete input succeeds" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/complete.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
}

test "run: explicit null optional fields succeed" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/minimal.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
}

test "run: omitted optional fields succeed" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/missing_optional_fields.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
}

test "run: empty stdin produces parse error" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/bad/empty.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, run(allocator, input, &aw.writer));
}

test "run: invalid JSON produces parse error" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/bad/invalid.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.SyntaxError, run(allocator, input, &aw.writer));
}

test "run: truncated JSON produces parse error" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/bad/truncated.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.SyntaxError, run(allocator, input, &aw.writer));
}

test "run: unknown fields succeed" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/extra_field.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
}

test "run: wrong JSON shape produces parse error" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/bad/wrong_shape.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedToken, run(allocator, input, &aw.writer));
}

test "run: null non-nullable field produces parse error" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/bad/null_required.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedToken, run(allocator, input, &aw.writer));
}

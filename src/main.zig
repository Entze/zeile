const std = @import("std");
const zeile = @import("zeile");

/// Maximum assumed length of any string value in the JSON input.
const json_string_len_max = 256;

/// Comptime upper bound on the JSON byte size for a given type,
/// assuming string values are at most `max_string_len` bytes.
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
    run() catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stderr().writerStreaming(&buf);
        w.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Allocate all buffers on the heap at startup.
    const io_buf = try allocator.create([io_buf_size]u8);
    defer allocator.destroy(io_buf);
    const input_buf = try allocator.alloc(u8, input_bytes_max);
    defer allocator.free(input_buf);

    // Read session data from stdin into the pre-allocated buffer.
    const input_len = try std.fs.File.stdin().readAll(input_buf);
    const input = input_buf[0..input_len];

    const parsed = std.json.parseFromSlice(zeile.SessionData, allocator, input, .{}) catch |err| {
        var w = std.fs.File.stderr().writerStreaming(io_buf);
        w.interface.print("error: failed to parse session data: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
    defer parsed.deinit();

    var w = std.fs.File.stdout().writerStreaming(io_buf);
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

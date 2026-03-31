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
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

const testing = std.testing;

test "run: valid complete JSON is pretty-printed to stdout" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/complete.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
    const output = try aw.toOwnedSlice();
    defer allocator.free(output);
    // Output must be valid JSON that parses into SessionData.
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, output, .{});
    defer parsed.deinit();
    // Verify representative fields survived the round-trip.
    try testing.expectEqualStrings("abc123...", parsed.value.session_id);
    try testing.expectEqualStrings("claude-opus-4-6", parsed.value.model.id);
    try testing.expectEqual(@as(u64, 45000), parsed.value.cost.total_duration_ms);
    try testing.expectEqualStrings("security-reviewer", parsed.value.agent.?.name);
    // Output ends with a newline.
    try testing.expect(output.len > 0 and output[output.len - 1] == '\n');
}

test "run: optional fields set to null produce valid output" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/minimal.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
    const output = try aw.toOwnedSlice();
    defer allocator.free(output);
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, output, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(?zeile.RateLimits, null), parsed.value.rate_limits);
    try testing.expectEqual(@as(?zeile.Vim, null), parsed.value.vim);
    try testing.expectEqual(@as(?zeile.Agent, null), parsed.value.agent);
    try testing.expectEqual(@as(?zeile.Worktree, null), parsed.value.worktree);
}

test "run: omitted optional fields default to null" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/missing_optional_fields.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
    const output = try aw.toOwnedSlice();
    defer allocator.free(output);
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, output, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(?zeile.RateLimits, null), parsed.value.rate_limits);
    try testing.expectEqual(@as(?zeile.Vim, null), parsed.value.vim);
    try testing.expectEqual(@as(?zeile.Agent, null), parsed.value.agent);
    try testing.expectEqual(@as(?zeile.Worktree, null), parsed.value.worktree);
    try testing.expectEqual(@as(?u8, null), parsed.value.context_window.used_percentage);
    try testing.expectEqual(@as(?u8, null), parsed.value.context_window.remaining_percentage);
    try testing.expectEqual(@as(?zeile.TokenUsage, null), parsed.value.context_window.current_usage);
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

test "run: unknown fields are ignored" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/extra_field.json", 1024 * 1024);
    defer allocator.free(input);
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, input, &aw.writer);
    const output = try aw.toOwnedSlice();
    defer allocator.free(output);
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, output, .{});
    defer parsed.deinit();
    // The unknown field should not appear in the output.
    try testing.expect(std.mem.indexOf(u8, output, "unknown_extra_field") == null);
}

test "run: round-trip preserves all data" {
    const allocator = testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(allocator, "tests/resources/good/complete.json", 1024 * 1024);
    defer allocator.free(input);
    // First pass.
    var aw1: std.io.Writer.Allocating = .init(allocator);
    defer aw1.deinit();
    try run(allocator, input, &aw1.writer);
    const first = try aw1.toOwnedSlice();
    defer allocator.free(first);
    // Second pass: feed first output back in.
    var aw2: std.io.Writer.Allocating = .init(allocator);
    defer aw2.deinit();
    try run(allocator, first, &aw2.writer);
    const second = try aw2.toOwnedSlice();
    defer allocator.free(second);
    // Both outputs must be byte-identical (idempotent).
    try testing.expectEqualStrings(first, second);
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

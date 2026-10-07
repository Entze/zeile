//! Tee-like pass-through of the parsed input to a file, as JSON Lines.

const std = @import("std");
const PassMode = @import("config.zig").PassMode;

pub const Error = std.json.ParseError(std.json.Scanner) || std.Io.File.OpenError ||
    std.Io.File.LengthError || std.Io.File.Writer.SeekError || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Write `input` compactly on a single line to the file at `path` in `dir`,
/// according to `mode`. Unknown fields are kept. `input` is parsed before the
/// file is opened, so invalid input never modifies the file. Returns
/// `error.PathAlreadyExists` for `.create` if the file exists.
pub fn write(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, mode: PassMode, path: []const u8, input: []const u8) Error!void {
    if (mode == .off) return;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), input, .{});

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try std.json.Stringify.value(parsed, .{}, &line.writer);
    try line.writer.writeByte('\n');

    const file = try dir.createFile(io, path, .{
        .exclusive = mode == .create,
        .truncate = mode != .append,
    });
    defer file.close(io);

    var buffer: [1]u8 = undefined;
    var writer = file.writer(io, &buffer);
    if (mode == .append) try writer.seekTo(try file.length(io));
    try writer.interface.writeAll(line.written());
    try writer.interface.flush();
}

const testing = std.testing;

fn expectContent(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test write {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.allocator, testing.io, tmp.dir, .create, "status.jsonl", "{ \"a\": 1,\n \"b\": [1, 2] }\n");
    try expectContent(tmp.dir, "status.jsonl", "{\"a\":1,\"b\":[1,2]}\n");
}

test "write: off leaves the file alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.allocator, testing.io, tmp.dir, .off, "status.jsonl", "{}");
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "status.jsonl", .{}));
}

test "write: create fails if the file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "status.jsonl", .data = "keep\n" });

    try testing.expectError(error.PathAlreadyExists, write(testing.allocator, testing.io, tmp.dir, .create, "status.jsonl", "{}"));
    try expectContent(tmp.dir, "status.jsonl", "keep\n");
}

test "write: truncate replaces the content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "status.jsonl", .data = "old old old old\n" });

    try write(testing.allocator, testing.io, tmp.dir, .truncate, "status.jsonl", "{\"n\": 1}");
    try expectContent(tmp.dir, "status.jsonl", "{\"n\":1}\n");
}

test "write: truncate creates a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.allocator, testing.io, tmp.dir, .truncate, "status.jsonl", "{}");
    try expectContent(tmp.dir, "status.jsonl", "{}\n");
}

test "write: append adds lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.allocator, testing.io, tmp.dir, .append, "status.jsonl", "{\"n\": 1}");
    try write(testing.allocator, testing.io, tmp.dir, .append, "status.jsonl", "{\"n\": 2}\n");
    try expectContent(tmp.dir, "status.jsonl", "{\"n\":1}\n{\"n\":2}\n");
}

test "write: unknown fields are kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.allocator, testing.io, tmp.dir, .create, "status.jsonl", "{\"extra\": {\"deep\": null}}");
    try expectContent(tmp.dir, "status.jsonl", "{\"extra\":{\"deep\":null}}\n");
}

test "write: invalid input does not touch the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "status.jsonl", .data = "keep\n" });

    try testing.expectError(error.UnexpectedEndOfInput, write(testing.allocator, testing.io, tmp.dir, .truncate, "status.jsonl", "{"));
    try expectContent(tmp.dir, "status.jsonl", "keep\n");
}

test "write: /dev/null accepts every mode" {
    for ([_]PassMode{ .truncate, .append }) |mode| {
        try write(testing.allocator, testing.io, std.Io.Dir.cwd(), mode, "/dev/null", "{}");
    }
}

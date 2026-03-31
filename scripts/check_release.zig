const std = @import("std");

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const contents = std.fs.cwd().readFileAlloc(allocator, "RELEASE.txt", 1024 * 1024) catch {
        fatal("RELEASE.txt does not exist or could not be read");
    };
    defer allocator.free(contents);

    const first_line = if (std.mem.indexOfScalar(u8, contents, '\n')) |idx|
        contents[0..idx]
    else
        contents;

    const trimmed = std.mem.trim(u8, first_line, &std.ascii.whitespace);

    if (trimmed.len == 0) {
        fatal("RELEASE.txt is empty");
    }

    if (!isValidLevel(trimmed)) {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stderr().writerStreaming(&buf);
        w.interface.print("error: first line of RELEASE.txt must be PATCH, MINOR, or MAJOR, got: '{s}'\n", .{trimmed}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    }

    var buf: [64]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.print("RELEASE.txt is valid\n", .{}) catch {};
    w.interface.flush() catch {};
}

fn isValidLevel(s: []const u8) bool {
    return std.mem.eql(u8, s, "PATCH") or
        std.mem.eql(u8, s, "MINOR") or
        std.mem.eql(u8, s, "MAJOR");
}

fn fatal(msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print("error: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

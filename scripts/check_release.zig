const std = @import("std");

pub fn main() void {
    const file = std.fs.cwd().openFile("RELEASE.txt", .{}) catch |err| {
        fatalErr("could not open RELEASE.txt", err);
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    const r = &reader.interface;

    const first_line = r.takeDelimiter('\n') catch {
        fatal("could not read RELEASE.txt");
    } orelse fatal("RELEASE.txt is empty");

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

    var found_notes = false;
    while (r.takeDelimiter('\n') catch {
        fatal("could not read RELEASE.txt");
    }) |line| {
        const line_trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (line_trimmed.len > 0) {
            found_notes = true;
            break;
        }
    }

    if (!found_notes) {
        fatal("RELEASE.txt has no release notes after the bump level");
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

const testing = std.testing;

test "isValidLevel: accepts PATCH" {
    try testing.expect(isValidLevel("PATCH"));
}

test "isValidLevel: accepts MINOR" {
    try testing.expect(isValidLevel("MINOR"));
}

test "isValidLevel: accepts MAJOR" {
    try testing.expect(isValidLevel("MAJOR"));
}

test "isValidLevel: rejects lowercase" {
    try testing.expect(!isValidLevel("patch"));
    try testing.expect(!isValidLevel("minor"));
    try testing.expect(!isValidLevel("major"));
}

test "isValidLevel: rejects empty string" {
    try testing.expect(!isValidLevel(""));
}

test "isValidLevel: rejects unrelated strings" {
    try testing.expect(!isValidLevel("CRITICAL"));
    try testing.expect(!isValidLevel("HOTFIX"));
    try testing.expect(!isValidLevel("INVALID"));
}

test "isValidLevel: rejects partial and padded matches" {
    try testing.expect(!isValidLevel("PATC"));
    try testing.expect(!isValidLevel("MINO"));
    try testing.expect(!isValidLevel("PATCH "));
    try testing.expect(!isValidLevel(" PATCH"));
    try testing.expect(!isValidLevel("MAJORS"));
}

fn fatal(msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print("error: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn fatalErr(msg: []const u8, err: anyerror) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print("error: {s}: {s}\n", .{ msg, @errorName(err) }) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

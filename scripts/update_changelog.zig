const std = @import("std");

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        fatal("could not allocate args");
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        fatal("usage: update-changelog <version>");
    }
    const version = args[1];

    const release_contents = std.fs.cwd().readFileAlloc(allocator, "RELEASE.txt", 1024 * 1024) catch |err| {
        fatalErr("could not read RELEASE.txt", err);
    };
    defer allocator.free(release_contents);

    const summary = extractSummary(release_contents) orelse {
        fatal("RELEASE.txt has no summary (need at least 2 lines)");
    };

    const changelog = std.fs.cwd().readFileAlloc(allocator, "CHANGELOG.md", 10 * 1024 * 1024) catch |err| {
        fatalErr("could not read CHANGELOG.md", err);
    };
    defer allocator.free(changelog);

    const insert_pos = findFirstH2(changelog) orelse changelog.len;

    const new_section = std.fmt.allocPrint(allocator, "## {s}\n\n{s}\n\n", .{ version, summary }) catch {
        fatal("out of memory");
    };
    defer allocator.free(new_section);

    const result = std.mem.concat(allocator, u8, &.{
        changelog[0..insert_pos],
        new_section,
        changelog[insert_pos..],
    }) catch {
        fatal("out of memory");
    };
    defer allocator.free(result);

    const file = std.fs.cwd().createFile("CHANGELOG.md", .{}) catch |err| {
        fatalErr("could not create CHANGELOG.md", err);
    };
    defer file.close();
    file.writeAll(result) catch |err| {
        fatalErr("could not write CHANGELOG.md", err);
    };

    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.print("Updated CHANGELOG.md with version {s}\n", .{version}) catch {};
    w.interface.flush() catch {};
}

/// Extracts everything after the first line of RELEASE.txt content.
fn extractSummary(contents: []const u8) ?[]const u8 {
    const after_first_line = if (std.mem.indexOfScalar(u8, contents, '\n')) |idx|
        contents[idx + 1 ..]
    else
        return null;

    const trimmed = std.mem.trim(u8, after_first_line, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Finds the byte offset of the first `## ` heading in the changelog.
/// Searches for `## ` at the start of the file or after a newline.
fn findFirstH2(changelog: []const u8) ?usize {
    if (std.mem.startsWith(u8, changelog, "## ")) return 0;

    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, changelog, pos, '\n')) |newline| {
        const line_start = newline + 1;
        if (line_start + 3 <= changelog.len and std.mem.eql(u8, changelog[line_start..][0..3], "## ")) {
            return line_start;
        }
        pos = line_start;
    }
    return null;
}

const testing = std.testing;

test "extractSummary: multi-line content" {
    const result = extractSummary("PATCH\nFix a small bug\nMore details").?;
    try testing.expectEqualStrings("Fix a small bug\nMore details", result);
}

test "extractSummary: single line returns null" {
    try testing.expect(extractSummary("PATCH") == null);
}

test "extractSummary: empty after first line returns null" {
    try testing.expect(extractSummary("PATCH\n") == null);
}

test "extractSummary: whitespace-only after first line returns null" {
    try testing.expect(extractSummary("PATCH\n   \n  \n") == null);
}

test "extractSummary: trims leading and trailing whitespace" {
    const result = extractSummary("MINOR\n  Fix something  \n").?;
    try testing.expectEqualStrings("Fix something", result);
}

test "extractSummary: handles CRLF" {
    const result = extractSummary("PATCH\r\nFix something\r\n").?;
    try testing.expectEqualStrings("Fix something", result);
}

test "findFirstH2: at start of file" {
    try testing.expectEqual(@as(?usize, 0), findFirstH2("## 1.0.0\n\nNotes."));
}

test "findFirstH2: after preamble" {
    const input = "# Changelog\n\nPreamble text.\n## 1.0.0\n";
    try testing.expectEqual(@as(?usize, 28), findFirstH2(input));
}

test "findFirstH2: no H2 returns null" {
    try testing.expect(findFirstH2("# Changelog\n\nJust text.") == null);
}

test "findFirstH2: H3 not matched" {
    try testing.expect(findFirstH2("### Not an H2\n") == null);
}

test "findFirstH2: multiple H2s returns first" {
    const input = "Preamble\n## 1.0.0\n\n## 0.9.0\n";
    try testing.expectEqual(@as(?usize, 9), findFirstH2(input));
}

test "findFirstH2: empty string returns null" {
    try testing.expect(findFirstH2("") == null);
}

test "findFirstH2: no space after hashes not matched" {
    try testing.expect(findFirstH2("##noSpace\n") == null);
}

test "findFirstH2: hashes mid-line not matched" {
    try testing.expect(findFirstH2("some text ## heading\n") == null);
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

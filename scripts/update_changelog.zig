const std = @import("std");

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = init.io;

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        fatal(io, "could not allocate args");
    };

    if (args.len < 2) {
        fatal(io, "usage: update-changelog <version>");
    }
    const version = args[1];

    // Stream RELEASE.txt: skip first line, collect remaining as summary.
    const release_file = std.Io.Dir.cwd().openFile(io, "RELEASE.txt", .{}) catch |err| {
        fatalErr(io, "could not open RELEASE.txt", err);
    };
    defer release_file.close(io);

    var release_read_buf: [4096]u8 = undefined;
    var release_reader = release_file.reader(io, &release_read_buf);
    const rr = &release_reader.interface;

    // Skip the first line (bump level).
    _ = rr.takeDelimiter('\n') catch {
        fatal(io, "could not read RELEASE.txt");
    } orelse fatal(io, "RELEASE.txt is empty");

    // Collect remaining lines into a buffer.
    var summary_buf: std.ArrayList(u8) = .empty;
    defer summary_buf.deinit(allocator);
    while (rr.takeDelimiter('\n') catch {
        fatal(io, "could not read RELEASE.txt");
    }) |line| {
        if (summary_buf.items.len > 0) summary_buf.append(allocator, '\n') catch fatal(io, "out of memory");
        summary_buf.appendSlice(allocator, std.mem.trimEnd(u8, line, "\r")) catch fatal(io, "out of memory");
    }
    const summary = std.mem.trim(u8, summary_buf.items, &std.ascii.whitespace);
    if (summary.len == 0) {
        fatal(io, "RELEASE.txt has no summary (need at least 2 lines)");
    }

    // Stream CHANGELOG.md line-by-line, inserting new section before first H2.
    const cwd: std.Io.Dir = .cwd();
    const changelog_in = cwd.openFile(io, "CHANGELOG.md", .{}) catch |err| {
        fatalErr(io, "could not open CHANGELOG.md", err);
    };

    const tmp_path = "CHANGELOG.md.tmp";
    const changelog_out = cwd.createFile(io, tmp_path, .{}) catch |err| {
        fatalErr(io, "could not create temp file", err);
    };
    errdefer cwd.deleteFile(io, tmp_path) catch {};

    {
        defer changelog_in.close(io);

        var ch_read_buf: [8192]u8 = undefined;
        var ch_reader = changelog_in.reader(io, &ch_read_buf);
        const cr = &ch_reader.interface;

        var ch_write_buf: [8192]u8 = undefined;
        var ch_writer = changelog_out.writerStreaming(io, &ch_write_buf);
        const cw = &ch_writer.interface;
        defer {
            cw.flush() catch {};
            changelog_out.close(io);
        }

        var inserted = false;

        while (cr.takeDelimiter('\n') catch {
            fatal(io, "could not read CHANGELOG.md");
        }) |line| {
            const trimmed_line = std.mem.trimEnd(u8, line, "\r");
            if (!inserted and std.mem.startsWith(u8, trimmed_line, "## ")) {
                cw.print("## {s}\n\n{s}\n\n", .{ version, summary }) catch |err| {
                    fatalErr(io, "could not write temp file", err);
                };
                inserted = true;
            }
            cw.writeAll(trimmed_line) catch |err| {
                fatalErr(io, "could not write temp file", err);
            };
            cw.writeByte('\n') catch |err| {
                fatalErr(io, "could not write temp file", err);
            };
        }

        if (!inserted) {
            cw.print("## {s}\n\n{s}\n\n", .{ version, summary }) catch |err| {
                fatalErr(io, "could not write temp file", err);
            };
        }
    }

    cwd.rename(tmp_path, cwd, "CHANGELOG.md", io) catch |err| {
        fatalErr(io, "could not rename temp file", err);
    };

    var out_buf: [128]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
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

fn fatal(io: std.Io, msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("error: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn fatalErr(io: std.Io, msg: []const u8, err: anyerror) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("error: {s}: {s}\n", .{ msg, @errorName(err) }) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

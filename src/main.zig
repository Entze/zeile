const std = @import("std");
const zeile = @import("zeile");
const build_options = @import("build_options");

/// Maximum assumed length of any string value in the JSON input.
const json_string_len_max = 256;

/// Comptime upper bound on the JSON byte size for a given type,
/// assuming string values are at most `json_string_len_max` bytes.
fn jsonSizeMax(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            var size: comptime_int = 2; // {}
            for (s.field_names, s.field_types) |name, FieldType| {
                size += name.len + 2 + 2 + 2; // "name": ,\n
                size += jsonSizeMax(FieldType);
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
            for (e.field_names) |name| {
                if (name.len > max_len) max_len = name.len;
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

/// Length of the short rate limit window, in hours.
const five_hour_window_h = 5;

/// Length of the long rate limit window, in hours.
const seven_day_window_h = 7 * 24;

/// Convert a whole number of seconds to hours.
fn hours(seconds: i64) f64 {
    return @as(f64, @floatFromInt(seconds)) / std.time.s_per_hour;
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = init.io;

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        std.debug.panic("error: failed to read the command line arguments", .{});
    const command = parse(args[1..]) catch |err| {
        fail(io, 2, "{s}; try `zeile --help`", .{switch (err) {
            error.UnknownCommand => "unknown command",
            error.UnknownOption => "unknown option",
            error.TooManyArguments => "too many arguments",
        }});
    };

    const io_buf = allocator.create([io_buf_size]u8) catch
        std.debug.panic("error: failed to allocate {Bi} for the io buffer", .{io_buf_size});
    defer allocator.destroy(io_buf);
    var w = std.Io.File.stdout().writerStreaming(io, io_buf);

    if (text(command)) |message| {
        w.interface.writeAll(message) catch {};
        w.interface.flush() catch {};
        return;
    }

    const path = command.display;
    const input_buf = allocator.alloc(u8, input_bytes_max) catch
        std.debug.panic("error: failed to allocate {Bi} for the input buffer", .{input_bytes_max});
    defer allocator.free(input_buf);
    const input = readInput(io, path, input_buf) catch |err|
        fail(io, 1, "failed to read {s} ({s})", .{ if (std.mem.eql(u8, path, "-")) "stdin" else path, @errorName(err) });

    run(allocator, io, input, &w.interface) catch |err|
        fail(io, 1, "failed to process session data ({s})", .{@errorName(err)});
    w.interface.flush() catch {};
}

fn fail(io: std.Io, status: u8, comptime format: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("error: " ++ format ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(status);
}

fn run(allocator: std.mem.Allocator, io: std.Io, input: []const u8, writer: *std.Io.Writer) !void {
    const parsed = try std.json.parseFromSlice(zeile.SessionData, allocator, input, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const color = zeile.color;
    const now_s = std.Io.Timestamp.now(io, .real).toSeconds();

    const five_hour_used_percentage = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.five_hour != null) parsed.value.rate_limits.?.five_hour.?.used_percentage else 0.0;
    const five_hour_resets_at: i64 = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.five_hour != null) @intCast(parsed.value.rate_limits.?.five_hour.?.resets_at) else 0;
    const five_hour_resets_in_s: i64 = @min(@max(0, five_hour_resets_at - now_s), five_hour_window_h * std.time.s_per_hour);
    const five_hour_resets_in: zeile.duration.Coarse = .{ .seconds = @intCast(five_hour_resets_in_s) };
    const five_hour_rate = zeile.usage.scale(zeile.usage.rate(
        five_hour_used_percentage,
        five_hour_window_h - hours(five_hour_resets_in_s),
    ));
    const five_hour_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "+", "x", "#" }, "]", five_hour_used_percentage);
    const five_hour_bar_color = zeile.usage.paceColor(
        five_hour_used_percentage,
        five_hour_window_h,
        hours(five_hour_resets_in_s),
    );

    const seven_day_used_percentage = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.seven_day != null) parsed.value.rate_limits.?.seven_day.?.used_percentage else 0.0;
    const seven_day_resets_at: i64 = if (parsed.value.rate_limits != null and parsed.value.rate_limits.?.seven_day != null) @intCast(parsed.value.rate_limits.?.seven_day.?.resets_at) else 0;
    const seven_day_resets_in_s: i64 = @min(@max(0, seven_day_resets_at - now_s), seven_day_window_h * std.time.s_per_hour);
    const seven_day_resets_in: zeile.duration.Coarse = .{ .seconds = @intCast(seven_day_resets_in_s) };
    const seven_day_rate = zeile.usage.scale(zeile.usage.rate(
        seven_day_used_percentage,
        seven_day_window_h - hours(seven_day_resets_in_s),
    ));
    const seven_day_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "+", "x", "#" }, "]", seven_day_used_percentage);
    const seven_day_bar_color = zeile.usage.paceColor(
        seven_day_used_percentage,
        seven_day_window_h,
        hours(seven_day_resets_in_s),
    );

    const ctx_percentage = parsed.value.context_window.used_percentage orelse 0;
    const ctx_bar = zeile.progressbar.format(10, "[", ' ', &.{ ".", "-", "/", "|", "\\", "=", ">", "^", "<", "v", "+", "x", "#" }, "]", @floatFromInt(ctx_percentage));
    const ctx_bar_color = zeile.usage.fillColor(@floatFromInt(ctx_percentage));

    const green = color.green;
    const red = color.red;
    const reset = color.reset;
    const args = .{ parsed.value.model.display_name, parsed.value.cost.total_cost_usd, green, parsed.value.cost.total_lines_added, red, parsed.value.cost.total_lines_removed, reset, five_hour_bar_color, five_hour_bar, reset, five_hour_used_percentage, five_hour_rate, five_hour_resets_in, seven_day_bar_color, seven_day_bar, reset, seven_day_used_percentage, seven_day_rate, seven_day_resets_in, ctx_bar_color, ctx_bar, reset, ctx_percentage };
    try writer.print("Claude {s} [${d:.2}] [{s}+{d}{s}-{d}{s}]\n[5h: {s}{s}{s} {d: >5.1}% {f} {f}] [7d: {s}{s}{s} {d: >5.1}% {f} {f}] [CTX: {s}{s}{s} {d: >3}%]", args);
    try writer.writeByte('\n');
}

const testing = std.testing;

test "run: complete input succeeds" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/good/complete.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, std.testing.io, input, &aw.writer);
}

test "run: explicit null optional fields succeed" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/good/minimal.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, std.testing.io, input, &aw.writer);
}

test "run: omitted optional fields succeed" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/good/missing_optional_fields.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, std.testing.io, input, &aw.writer);
}

test "run: empty stdin produces parse error" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/bad/empty.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, run(allocator, std.testing.io, input, &aw.writer));
}

test "run: invalid JSON produces parse error" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/bad/invalid.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.SyntaxError, run(allocator, std.testing.io, input, &aw.writer));
}

test "run: truncated JSON produces parse error" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/bad/truncated.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.SyntaxError, run(allocator, std.testing.io, input, &aw.writer));
}

test "run: unknown fields succeed" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/good/extra_field.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try run(allocator, std.testing.io, input, &aw.writer);
}

test "run: wrong JSON shape produces parse error" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/bad/wrong_shape.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedToken, run(allocator, std.testing.io, input, &aw.writer));
}

test "run: null non-nullable field produces parse error" {
    const allocator = testing.allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/resources/session_data/bad/null_required.json", allocator, .limited(1024 * 1024));
    defer allocator.free(input);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.UnexpectedToken, run(allocator, std.testing.io, input, &aw.writer));
}

/// What the command line asks zeile to do.
const Command = union(enum) {
    help,
    version,
    display_help,
    /// Read the session data from this path, `-` being stdin.
    display: []const u8,
};

const ParseError = error{ UnknownCommand, UnknownOption, TooManyArguments };

/// Interpret the arguments following the program name.
fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .{ .display = "-" };
    const first = args[0];
    if (isAny(first, &.{ "-h", "--help" })) return if (args.len == 1) .help else error.TooManyArguments;
    if (isAny(first, &.{ "-V", "--version" })) return if (args.len == 1) .version else error.TooManyArguments;
    if (!std.mem.eql(u8, first, "display")) {
        return if (std.mem.startsWith(u8, first, "-")) error.UnknownOption else error.UnknownCommand;
    }

    const rest = args[1..];
    if (rest.len == 0) return .{ .display = "-" };
    if (rest.len > 1) return error.TooManyArguments;
    if (isAny(rest[0], &.{ "-h", "--help" })) return .display_help;
    if (rest[0].len > 1 and rest[0][0] == '-') return error.UnknownOption;
    return .{ .display = rest[0] };
}

fn isAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, arg, candidate)) return true;
    }
    return false;
}

test parse {
    try testing.expectEqualDeep(Command{ .display = "-" }, try parse(&.{}));
    try testing.expectEqualDeep(Command.help, try parse(&.{"-h"}));
    try testing.expectEqualDeep(Command.help, try parse(&.{"--help"}));
    try testing.expectEqualDeep(Command.version, try parse(&.{"-V"}));
    try testing.expectEqualDeep(Command.version, try parse(&.{"--version"}));
    try testing.expectEqualDeep(Command.display_help, try parse(&.{ "display", "--help" }));
    try testing.expectEqualDeep(Command.display_help, try parse(&.{ "display", "-h" }));
    try testing.expectEqualDeep(Command{ .display = "-" }, try parse(&.{"display"}));
    try testing.expectEqualDeep(Command{ .display = "-" }, try parse(&.{ "display", "-" }));
    try testing.expectEqualDeep(Command{ .display = "status.json" }, try parse(&.{ "display", "status.json" }));
}

test "parse: unknown command is rejected" {
    try testing.expectError(error.UnknownCommand, parse(&.{"bogus"}));
    try testing.expectError(error.UnknownCommand, parse(&.{"status.json"}));
}

test "parse: unknown option is rejected" {
    try testing.expectError(error.UnknownOption, parse(&.{"--bogus"}));
    try testing.expectError(error.UnknownOption, parse(&.{ "display", "--bogus" }));
}

test "parse: surplus arguments are rejected" {
    try testing.expectError(error.TooManyArguments, parse(&.{ "-h", "display" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "-V", "x" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "display", "a.json", "b.json" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "display", "--help", "x" }));
}

/// Fill `buffer` from the file at `path`, or from stdin if `path` is `-`.
/// Returns the filled prefix.
fn readInput(io: std.Io, path: []const u8, buffer: []u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var stdin = std.Io.File.stdin().readerStreaming(io, &.{});
        const len = try stdin.interface.readSliceShort(buffer);
        return buffer[0..len];
    }
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    const len = try reader.interface.readSliceShort(buffer);
    return buffer[0..len];
}

test readInput {
    var buffer: [input_bytes_max]u8 = undefined;
    const input = try readInput(testing.io, "tests/resources/session_data/good/minimal.json", &buffer);
    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/resources/session_data/good/minimal.json", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, input);
}

test "readInput: missing file is an error" {
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.FileNotFound, readInput(testing.io, "tests/resources/session_data/missing.json", &buffer));
}

/// The text printed for commands that only print text, or null for those
/// that do more.
fn text(command: Command) ?[]const u8 {
    return switch (command) {
        .help => help_text,
        .version => version_text,
        .display_help => display_help_text,
        .display => null,
    };
}

test text {
    try testing.expectEqualStrings(help_text, text(.help).?);
    try testing.expectEqualStrings(display_help_text, text(.display_help).?);
    try testing.expectEqual(null, text(.{ .display = "-" }));

    const version = text(.version).?;
    try testing.expect(std.mem.startsWith(u8, version, "zeile "));
    try testing.expect(std.mem.endsWith(u8, version, "\n"));
    _ = try std.SemanticVersion.parse(std.mem.trimEnd(u8, version["zeile ".len..], "\n"));
}

test "text: help names every command and option" {
    for ([_][]const u8{ "-h", "--help", "-V", "--version", "display", "STATUS" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, help_text, needle) != null);
    }
    for ([_][]const u8{ "-h", "--help", "STATUS", "stdin" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, display_help_text, needle) != null);
    }
}

const version_text = "zeile " ++ build_options.version ++ "\n";

const help_text =
    \\Usage: zeile [CMD]
    \\
    \\Render a compact status line from Claude Code session data.
    \\
    \\Commands:
    \\  display [STATUS]  Render the status line (default)
    \\
    \\Options:
    \\  -h, --help        Print help
    \\  -V, --version     Print version
    \\
    \\Without CMD, `zeile display` is assumed.
    \\
;

const display_help_text =
    \\Usage: zeile display [STATUS]
    \\
    \\Render the status line from the session data in STATUS.
    \\
    \\Arguments:
    \\  STATUS      JSON file as described in
    \\              https://code.claude.com/docs/en/statusline#full-json-schema
    \\              Defaults to `-`, which reads from stdin.
    \\
    \\Options:
    \\  -h, --help  Print help
    \\
;

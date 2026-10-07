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
    const parsed = parse(args[1..]) catch |err| {
        fail(io, 2, "{s}; try `zeile --help`", .{switch (err) {
            error.UnknownCommand => "unknown command",
            error.UnknownOption => "unknown option",
            error.TooManyArguments => "too many arguments",
            error.MissingValue => "missing option value",
            error.InvalidValue => "invalid option value",
        }});
    };

    const io_buf = allocator.create([io_buf_size]u8) catch
        std.debug.panic("error: failed to allocate {Bi} for the io buffer", .{io_buf_size});
    defer allocator.destroy(io_buf);
    var w = std.Io.File.stdout().writerStreaming(io, io_buf);

    if (text(parsed.command)) |message| {
        w.interface.writeAll(message) catch {};
        w.interface.flush() catch {};
        return;
    }

    const config = zeile.Config.load(init.arena.allocator(), io, parsed.config, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |err|
        fail(io, 1, "failed to load the configuration ({s})", .{@errorName(err)});
    const display = parsed.command.display;
    const pass = resolve(display, config);

    const path = display.status;
    const input_buf = allocator.alloc(u8, input_bytes_max) catch
        std.debug.panic("error: failed to allocate {Bi} for the input buffer", .{input_bytes_max});
    defer allocator.free(input_buf);
    const input = readInput(io, path, input_buf) catch |err|
        fail(io, 1, "failed to read {s} ({s})", .{ if (std.mem.eql(u8, path, "-")) "stdin" else path, @errorName(err) });

    zeile.pass.write(allocator, io, std.Io.Dir.cwd(), pass.pass_mode, pass.pass_file, input) catch |err| switch (err) {
        error.PathAlreadyExists => fail(io, exit_pass_file_exists, "{s} already exists", .{pass.pass_file}),
        else => fail(io, 1, "failed to write {s} ({s})", .{ pass.pass_file, @errorName(err) }),
    };

    run(allocator, io, input, &w.interface) catch |err|
        fail(io, 1, "failed to process session data ({s})", .{@errorName(err)});
    w.interface.flush() catch {};
}

/// Exit status if `--pass-mode=create` finds the pass file.
const exit_pass_file_exists = 3;

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
    display: Display,
};

/// Options of the display command. Null means the command line did not
/// give the option, so the configuration decides.
const Display = struct {
    /// Read the session data from this path, `-` being stdin.
    status: []const u8 = "-",
    pass_mode: ?zeile.Config.PassMode = null,
    pass_file: ?[]const u8 = null,
};

const Parsed = struct {
    config: ?[]const u8 = null,
    command: Command,
};

const ParseError = error{ UnknownCommand, UnknownOption, TooManyArguments, MissingValue, InvalidValue };

/// Interpret the arguments following the program name.
fn parse(args: []const []const u8) ParseError!Parsed {
    var parsed: Parsed = .{ .command = .{ .display = .{} } };
    var rest = args;
    while (rest.len > 0) {
        if (try option(rest, "-c", "--config")) |found| {
            parsed.config = found.value;
            rest = found.rest;
        } else break;
    }
    if (rest.len == 0) return parsed;

    const first = rest[0];
    if (isAny(first, &.{ "-h", "--help" })) {
        parsed.command = .help;
        return if (rest.len == 1) parsed else error.TooManyArguments;
    }
    if (isAny(first, &.{ "-V", "--version" })) {
        parsed.command = .version;
        return if (rest.len == 1) parsed else error.TooManyArguments;
    }
    if (!std.mem.eql(u8, first, "display")) {
        return if (std.mem.startsWith(u8, first, "-")) error.UnknownOption else error.UnknownCommand;
    }

    rest = rest[1..];
    const arguments_len = rest.len;
    var display: Display = .{};
    var status_given = false;
    while (rest.len > 0) {
        if (isAny(rest[0], &.{ "-h", "--help" })) {
            parsed.command = .display_help;
            return if (arguments_len == 1) parsed else error.TooManyArguments;
        }
        if (try option(rest, "-m", "--pass-mode")) |found| {
            display.pass_mode = std.meta.stringToEnum(zeile.Config.PassMode, found.value) orelse return error.InvalidValue;
            rest = found.rest;
        } else if (try option(rest, "-s", "--pass-file")) |found| {
            display.pass_file = found.value;
            rest = found.rest;
        } else if (rest[0].len > 1 and rest[0][0] == '-') {
            return error.UnknownOption;
        } else {
            if (status_given) return error.TooManyArguments;
            status_given = true;
            display.status = rest[0];
            rest = rest[1..];
        }
    }
    parsed.command = .{ .display = display };
    return parsed;
}

/// The pass options in effect: the command line overrides the configuration.
fn resolve(display: Display, config: zeile.Config) zeile.Config.Display {
    return .{
        .pass_mode = display.pass_mode orelse config.display.pass_mode,
        .pass_file = display.pass_file orelse config.display.pass_file,
    };
}

const Option = struct { value: []const u8, rest: []const []const u8 };

/// Match the option spelled `short` or `long` at the start of `args`, as
/// `short VALUE`, `long VALUE` or `long=VALUE`. Returns null if `args` starts
/// with another option or argument.
fn option(args: []const []const u8, short: []const u8, long: []const u8) error{MissingValue}!?Option {
    const arg = args[0];
    if (std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long)) {
        if (args.len < 2) return error.MissingValue;
        return .{ .value = args[1], .rest = args[2..] };
    }
    if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=') {
        return .{ .value = arg[long.len + 1 ..], .rest = args[1..] };
    }
    return null;
}

fn isAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, arg, candidate)) return true;
    }
    return false;
}

test parse {
    try testing.expectEqualDeep(Parsed{ .command = .{ .display = .{} } }, try parse(&.{}));
    try testing.expectEqualDeep(Parsed{ .command = .help }, try parse(&.{"-h"}));
    try testing.expectEqualDeep(Parsed{ .command = .help }, try parse(&.{"--help"}));
    try testing.expectEqualDeep(Parsed{ .command = .version }, try parse(&.{"-V"}));
    try testing.expectEqualDeep(Parsed{ .command = .version }, try parse(&.{"--version"}));
    try testing.expectEqualDeep(Parsed{ .command = .display_help }, try parse(&.{ "display", "--help" }));
    try testing.expectEqualDeep(Parsed{ .command = .display_help }, try parse(&.{ "display", "-h" }));
    try testing.expectEqualDeep(Parsed{ .command = .{ .display = .{} } }, try parse(&.{"display"}));
    try testing.expectEqualDeep(Parsed{ .command = .{ .display = .{} } }, try parse(&.{ "display", "-" }));
    try testing.expectEqualDeep(Parsed{ .command = .{ .display = .{ .status = "status.json" } } }, try parse(&.{ "display", "status.json" }));
}

test "parse: config is a root option" {
    const expected = Parsed{ .config = "zeile.json", .command = .{ .display = .{} } };
    try testing.expectEqualDeep(expected, try parse(&.{ "-c", "zeile.json" }));
    try testing.expectEqualDeep(expected, try parse(&.{"--config=zeile.json"}));
    try testing.expectEqualDeep(expected, try parse(&.{ "--config", "zeile.json", "display" }));
    try testing.expectEqualDeep(
        Parsed{ .config = "zeile.json", .command = .{ .display = .{ .status = "s.json" } } },
        try parse(&.{ "-c", "zeile.json", "display", "s.json" }),
    );
    try testing.expectEqualDeep(Parsed{ .config = "zeile.json", .command = .help }, try parse(&.{ "-c", "zeile.json", "--help" }));
    try testing.expectEqualDeep(Parsed{ .config = "later.json", .command = .{ .display = .{} } }, try parse(&.{ "-c", "first.json", "-c", "later.json" }));
}

test "parse: display takes pass options" {
    const expected = Parsed{ .command = .{ .display = .{ .pass_mode = .append, .pass_file = "log.jsonl" } } };
    try testing.expectEqualDeep(expected, try parse(&.{ "display", "-m", "append", "-s", "log.jsonl" }));
    try testing.expectEqualDeep(expected, try parse(&.{ "display", "--pass-mode=append", "--pass-file=log.jsonl" }));
    try testing.expectEqualDeep(expected, try parse(&.{ "display", "--pass-mode", "append", "--pass-file", "log.jsonl" }));
    try testing.expectEqualDeep(expected, try parse(&.{ "display", "-s", "log.jsonl", "-m", "append" }));
    try testing.expectEqualDeep(
        Parsed{ .command = .{ .display = .{ .status = "s.json", .pass_mode = .truncate } } },
        try parse(&.{ "display", "-m", "truncate", "s.json" }),
    );
    try testing.expectEqualDeep(
        Parsed{ .command = .{ .display = .{ .status = "s.json", .pass_mode = .create } } },
        try parse(&.{ "display", "s.json", "--pass-mode=create" }),
    );
    try testing.expectEqualDeep(
        Parsed{ .command = .{ .display = .{ .pass_mode = .off } } },
        try parse(&.{ "display", "-m", "off" }),
    );
}

test "parse: pass options are not root options" {
    try testing.expectError(error.UnknownOption, parse(&.{ "-m", "append" }));
    try testing.expectError(error.UnknownOption, parse(&.{"--pass-mode=append"}));
    try testing.expectError(error.UnknownOption, parse(&.{ "-s", "log.jsonl" }));
    try testing.expectError(error.UnknownOption, parse(&.{"--pass-file=log.jsonl"}));
}

test "parse: config is not a display option" {
    try testing.expectError(error.UnknownOption, parse(&.{ "display", "-c", "zeile.json" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "display", "--config=zeile.json" }));
}

test "parse: missing option value is rejected" {
    try testing.expectError(error.MissingValue, parse(&.{"-c"}));
    try testing.expectError(error.MissingValue, parse(&.{ "display", "-m" }));
    try testing.expectError(error.MissingValue, parse(&.{ "display", "--pass-file" }));
}

test "parse: invalid pass mode is rejected" {
    try testing.expectError(error.InvalidValue, parse(&.{ "display", "-m", "overwrite" }));
    try testing.expectError(error.InvalidValue, parse(&.{ "display", "--pass-mode=" }));
}

test "parse: unknown command is rejected" {
    try testing.expectError(error.UnknownCommand, parse(&.{"bogus"}));
    try testing.expectError(error.UnknownCommand, parse(&.{"status.json"}));
    try testing.expectError(error.UnknownCommand, parse(&.{ "-c", "zeile.json", "bogus" }));
}

test "parse: unknown option is rejected" {
    try testing.expectError(error.UnknownOption, parse(&.{"--bogus"}));
    try testing.expectError(error.UnknownOption, parse(&.{ "display", "--bogus" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "-c", "zeile.json", "--bogus" }));
}

test "parse: surplus arguments are rejected" {
    try testing.expectError(error.TooManyArguments, parse(&.{ "-h", "display" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "-V", "x" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "display", "a.json", "b.json" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "display", "--help", "x" }));
    try testing.expectError(error.TooManyArguments, parse(&.{ "display", "-m", "off", "--help" }));
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
    try testing.expectEqual(null, text(.{ .display = .{} }));

    const version = text(.version).?;
    try testing.expect(std.mem.startsWith(u8, version, "zeile "));
    try testing.expect(std.mem.endsWith(u8, version, "\n"));
    _ = try std.SemanticVersion.parse(std.mem.trimEnd(u8, version["zeile ".len..], "\n"));
}

test resolve {
    const config: zeile.Config = .{ .display = .{ .pass_mode = .append, .pass_file = "config.jsonl" } };

    const from_config = resolve(.{}, config);
    try testing.expectEqual(zeile.Config.PassMode.append, from_config.pass_mode);
    try testing.expectEqualStrings("config.jsonl", from_config.pass_file);

    const from_flags = resolve(.{ .pass_mode = .truncate, .pass_file = "flag.jsonl" }, config);
    try testing.expectEqual(zeile.Config.PassMode.truncate, from_flags.pass_mode);
    try testing.expectEqualStrings("flag.jsonl", from_flags.pass_file);

    const mixed = resolve(.{ .pass_mode = .off }, config);
    try testing.expectEqual(zeile.Config.PassMode.off, mixed.pass_mode);
    try testing.expectEqualStrings("config.jsonl", mixed.pass_file);

    const defaults = resolve(.{}, .{});
    try testing.expectEqual(zeile.Config.PassMode.off, defaults.pass_mode);
    try testing.expectEqualStrings("/dev/null", defaults.pass_file);
}

test "text: help names every command and option" {
    for ([_][]const u8{ "-h", "--help", "-V", "--version", "-c", "--config", "display", "STATUS" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, help_text, needle) != null);
    }
    for ([_][]const u8{ "-h", "--help", "STATUS", "stdin", "-m", "--pass-mode", "off", "create", "truncate", "append", "-s", "--pass-file", "/dev/null" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, display_help_text, needle) != null);
    }
}

const version_text = "zeile " ++ build_options.version ++ "\n";

const help_text =
    \\Usage: zeile [OPTIONS] [CMD]
    \\
    \\Render a compact status line from Claude Code session data.
    \\
    \\Commands:
    \\  display [STATUS]  Render the status line (default)
    \\
    \\Options:
    \\  -c, --config=CONFIG  JSON file with defaults for the options of commands.
    \\                       Defaults to $XDG_CONFIG_HOME/zeile/config.json, then
    \\                       $HOME/.config/zeile/config.json; neither is required.
    \\  -h, --help           Print help
    \\  -V, --version        Print version
    \\
    \\Without CMD, `zeile display` is assumed.
    \\
;

const display_help_text =
    \\Usage: zeile display [OPTIONS] [STATUS]
    \\
    \\Render the status line from the session data in STATUS.
    \\
    \\Arguments:
    \\  STATUS      JSON file as described in
    \\              https://code.claude.com/docs/en/statusline#full-json-schema
    \\              Defaults to `-`, which reads from stdin.
    \\
    \\Options:
    \\  -m, --pass-mode={off,create,truncate,append}
    \\              Write the parsed JSON compactly to the pass file, one line
    \\              per run. `create` fails with status 3 if the file exists,
    \\              `truncate` works like `>`, `append` like `>>`.
    \\              Defaults to `off`.
    \\  -s, --pass-file=SINK
    \\              File to write to. Defaults to `/dev/null`.
    \\  -h, --help  Print help
    \\
    \\In the configuration file, the options are keyed by command, e.g.
    \\{"display": {"pass-mode": "append", "pass-file": "log.jsonl"}}.
    \\The command line overrides the configuration.
    \\
;

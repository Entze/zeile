//! Settings read from the configuration file. Flags are namespaced by the
//! command they belong to, e.g.
//! `{"display": {"pass-mode": "append", "pass-file": "log.jsonl"}}`.

const std = @import("std");
const Config = @This();

display: Display = .{},

/// How the pass file is opened, mirroring the shell redirections.
pub const PassMode = enum {
    /// Do not write the pass file.
    off,
    /// Write to a new file, failing if it already exists.
    create,
    /// Replace the content of the file, like `>`.
    truncate,
    /// Add to the end of the file, like `>>`.
    append,
};

pub const Display = struct {
    pass_mode: PassMode = .off,
    pass_file: []const u8 = "/dev/null",
};

pub const ParseError = std.json.ParseError(std.json.Scanner) || error{InvalidConfig};

/// Interpret `bytes` as configuration. Strings in the result are allocated
/// with `arena`, which is never freed individually.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Config {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    var config: Config = .{};
    const root_object = switch (root) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };
    const display = root_object.get("display") orelse return config;
    const display_object = switch (display) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };
    if (display_object.get("pass-mode")) |mode| {
        const name = switch (mode) {
            .string => |string| string,
            else => return error.InvalidConfig,
        };
        config.display.pass_mode = std.meta.stringToEnum(PassMode, name) orelse return error.InvalidConfig;
    }
    if (display_object.get("pass-file")) |file| {
        config.display.pass_file = switch (file) {
            .string => |string| string,
            else => return error.InvalidConfig,
        };
    }
    return config;
}

/// Candidate locations of the configuration file, most preferred first.
/// `xdg_config_home` and `home` are the values of the like-named environment
/// variables; unset or empty ones are skipped.
pub fn paths(arena: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (xdg_config_home) |dir| {
        if (dir.len > 0) try list.append(arena, try std.fs.path.join(arena, &.{ dir, "zeile", "config.json" }));
    }
    if (home) |dir| {
        if (dir.len > 0) try list.append(arena, try std.fs.path.join(arena, &.{ dir, ".config", "zeile", "config.json" }));
    }
    return list.items;
}

pub const LoadError = ParseError || std.Io.Dir.ReadFileAllocError;

/// Read the configuration from `explicit`, which has to exist. Without it,
/// the first existing file of `paths` is read. If there is none, the
/// defaults are returned.
pub fn load(arena: std.mem.Allocator, io: std.Io, explicit: ?[]const u8, xdg_config_home: ?[]const u8, home: ?[]const u8) (LoadError || std.mem.Allocator.Error)!Config {
    const cwd = std.Io.Dir.cwd();
    if (explicit) |path| {
        return parse(arena, try cwd.readFileAlloc(io, path, arena, .limited(input_bytes_max)));
    }
    for (try paths(arena, xdg_config_home, home)) |path| {
        const bytes = cwd.readFileAlloc(io, path, arena, .limited(input_bytes_max)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
        return parse(arena, bytes);
    }
    return .{};
}

const input_bytes_max = 1024 * 1024;

const testing = std.testing;

fn readFixture(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
}

fn parseFixture(arena: std.mem.Allocator, path: []const u8) !Config {
    const bytes = try readFixture(path);
    defer testing.allocator.free(bytes);
    return parse(arena, bytes);
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const config = try parse(arena.allocator(), "{\"display\": {\"pass-mode\": \"append\", \"pass-file\": \"log.jsonl\"}}");
    try testing.expectEqual(PassMode.append, config.display.pass_mode);
    try testing.expectEqualStrings("log.jsonl", config.display.pass_file);
}

test "parse: empty object yields the defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try parseFixture(arena.allocator(), "tests/resources/config/good/empty.json");
    try testing.expectEqual(PassMode.off, config.display.pass_mode);
    try testing.expectEqualStrings("/dev/null", config.display.pass_file);
}

test "parse: full display namespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try parseFixture(arena.allocator(), "tests/resources/config/good/full.json");
    try testing.expectEqual(PassMode.append, config.display.pass_mode);
    try testing.expectEqualStrings("log.jsonl", config.display.pass_file);
}

test "parse: omitted flags keep their default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try parseFixture(arena.allocator(), "tests/resources/config/good/partial.json");
    try testing.expectEqual(PassMode.truncate, config.display.pass_mode);
    try testing.expectEqualStrings("/dev/null", config.display.pass_file);
}

test "parse: unknown keys and namespaces are ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try parseFixture(arena.allocator(), "tests/resources/config/good/unknown.json");
    try testing.expectEqual(PassMode.create, config.display.pass_mode);
}

test "parse: invalid pass mode is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidConfig, parseFixture(arena.allocator(), "tests/resources/config/bad/invalid_mode.json"));
}

test "parse: wrong types are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidConfig, parseFixture(arena.allocator(), "tests/resources/config/bad/wrong_type.json"));
    try testing.expectError(error.InvalidConfig, parseFixture(arena.allocator(), "tests/resources/config/bad/wrong_shape.json"));
    try testing.expectError(error.InvalidConfig, parseFixture(arena.allocator(), "tests/resources/config/bad/not_object.json"));
}

test "parse: malformed JSON is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, parseFixture(arena.allocator(), "tests/resources/config/bad/malformed.json"));
}

test paths {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const both = try paths(arena.allocator(), "/xdg", "/home/me");
    try testing.expectEqual(2, both.len);
    try testing.expectEqualStrings("/xdg/zeile/config.json", both[0]);
    try testing.expectEqualStrings("/home/me/.config/zeile/config.json", both[1]);
}

test "paths: unset or empty variables are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const home_only = try paths(arena.allocator(), null, "/home/me");
    try testing.expectEqual(1, home_only.len);
    try testing.expectEqualStrings("/home/me/.config/zeile/config.json", home_only[0]);

    const empty_xdg = try paths(arena.allocator(), "", "/home/me");
    try testing.expectEqual(1, empty_xdg.len);

    try testing.expectEqual(0, (try paths(arena.allocator(), null, null)).len);
}

test load {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const explicit = try load(allocator, testing.io, "tests/resources/config/good/full.json", "tests/resources/config/xdg", "tests/resources/config/home");
    try testing.expectEqualStrings("log.jsonl", explicit.display.pass_file);
}

test "load: xdg takes precedence over home" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try load(arena.allocator(), testing.io, null, "tests/resources/config/xdg", "tests/resources/config/home");
    try testing.expectEqualStrings("xdg.jsonl", config.display.pass_file);
}

test "load: falls back to home when xdg has no file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try load(arena.allocator(), testing.io, null, "tests/resources/config/missing", "tests/resources/config/home");
    try testing.expectEqual(PassMode.truncate, config.display.pass_mode);
    try testing.expectEqualStrings("home.jsonl", config.display.pass_file);
}

test "load: no file at all yields the defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try load(arena.allocator(), testing.io, null, "tests/resources/config/missing", null);
    try testing.expectEqual(PassMode.off, config.display.pass_mode);
}

test "load: explicit file must exist" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.FileNotFound, load(arena.allocator(), testing.io, "tests/resources/config/missing.json", null, null));
}

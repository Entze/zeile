const std = @import("std");
const testing = std.testing;

/// Turn off every attribute set so far.
pub const reset = "\x1B[0m";

/// Foreground green, from the basic eight-color palette.
pub const green = "\x1B[32m";

/// Foreground red, from the basic eight-color palette.
pub const red = "\x1B[31m";

/// Foreground escape sequences walking the edges of the 6x6x6 cube of the
/// 256-color palette from blue through cyan, green and yellow to red.
const ramp = [_][]const u8{
    "\x1B[38;5;21m",
    "\x1B[38;5;27m",
    "\x1B[38;5;33m",
    "\x1B[38;5;39m",
    "\x1B[38;5;45m",
    "\x1B[38;5;51m",
    "\x1B[38;5;50m",
    "\x1B[38;5;49m",
    "\x1B[38;5;48m",
    "\x1B[38;5;47m",
    "\x1B[38;5;46m",
    "\x1B[38;5;82m",
    "\x1B[38;5;118m",
    "\x1B[38;5;154m",
    "\x1B[38;5;190m",
    "\x1B[38;5;226m",
    "\x1B[38;5;220m",
    "\x1B[38;5;214m",
    "\x1B[38;5;208m",
    "\x1B[38;5;202m",
    "\x1B[38;5;196m",
};

/// Anchor colors, each valued by its position on the ramp.
pub const Hue = enum(u8) {
    blue = 0,
    green = 10,
    yellow = 15,
    red = ramp.len - 1,
};

/// A position on some scale that is pinned to a color.
pub const Stop = struct {
    at: f64,
    hue: Hue,
};

/// Pick a foreground escape sequence for `at` by walking the cube between the
/// neighbouring `stops`.
///
/// Positions before the first stop take its color and positions after the last
/// stop take its color. NaN takes the color of the first stop. Asserts `stops`
/// is not empty and `at` is strictly increasing along it.
pub fn gradient(stops: []const Stop, at: f64) []const u8 {
    std.debug.assert(stops.len > 0);
    for (stops[1..], stops[0 .. stops.len - 1]) |next, previous| std.debug.assert(previous.at < next.at);

    const first = stops[0];
    const last = stops[stops.len - 1];
    if (!(at > first.at)) return ramp[@intFromEnum(first.hue)];
    if (!(at < last.at)) return ramp[@intFromEnum(last.hue)];

    const upper = for (stops[1..], 1..) |stop, index| {
        if (at < stop.at) break index;
    } else unreachable;
    const from = stops[upper - 1];
    const to = stops[upper];
    const from_step: f64 = @floatFromInt(@intFromEnum(from.hue));
    const to_step: f64 = @floatFromInt(@intFromEnum(to.hue));
    const share = (at - from.at) / (to.at - from.at);
    const step: usize = @intFromFloat(@round(from_step + share * (to_step - from_step)));
    std.debug.assert(step < ramp.len);
    return ramp[step];
}

test gradient {
    const stops = [_]Stop{
        .{ .at = 0.0, .hue = .blue },
        .{ .at = 1.0, .hue = .green },
    };
    try testing.expectEqualStrings("\x1B[38;5;21m", gradient(&stops, 0.0));
    try testing.expectEqualStrings("\x1B[38;5;51m", gradient(&stops, 0.5));
    try testing.expectEqualStrings("\x1B[38;5;46m", gradient(&stops, 1.0));
}

const test_stops = [_]Stop{
    .{ .at = 0.0, .hue = .blue },
    .{ .at = 1.0, .hue = .green },
    .{ .at = 2.0, .hue = .green },
    .{ .at = 3.0, .hue = .yellow },
    .{ .at = 4.0, .hue = .red },
};

fn stepOf(sequence: []const u8) usize {
    return for (ramp, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, sequence)) break index;
    } else unreachable;
}

test "gradient: stops take their own hue" {
    for (test_stops) |stop| {
        try testing.expectEqualStrings(ramp[@intFromEnum(stop.hue)], gradient(&test_stops, stop.at));
    }
}

test "gradient: between equal hues stays put" {
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.green)], gradient(&test_stops, 1.5));
}

test "gradient: out of range positions are clamped" {
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.blue)], gradient(&test_stops, -1.0));
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.blue)], gradient(&test_stops, -std.math.inf(f64)));
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.red)], gradient(&test_stops, 9.0));
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.red)], gradient(&test_stops, std.math.inf(f64)));
    try testing.expectEqualStrings(ramp[@intFromEnum(Hue.blue)], gradient(&test_stops, std.math.nan(f64)));
}

test "gradient: crossing the stops walks the whole ramp in order" {
    var previous: usize = 0;
    for (0..401) |i| {
        const step = stepOf(gradient(&test_stops, @as(f64, @floatFromInt(i)) / 100.0));
        try testing.expect(step >= previous);
        previous = step;
    }
    try testing.expectEqual(ramp.len - 1, previous);
}

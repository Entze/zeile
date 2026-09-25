const std = @import("std");
const color = @import("color.zig");
const testing = std.testing;

/// Colors of a rate limit bar by the multiple of the affordable rate that the
/// current rate amounts to, on a base 2 logarithmic scale.
///
/// Blue below half the affordable rate, green from 0.8 to 1.15 times it,
/// yellow at 1.7 times and red at 2.5 times and beyond.
const multiple_stops = [_]color.Stop{
    .{ .at = @log2(0.5), .hue = .blue },
    .{ .at = @log2(0.8), .hue = .green },
    .{ .at = @log2(1.15), .hue = .green },
    .{ .at = @log2(1.7), .hue = .yellow },
    .{ .at = @log2(2.5), .hue = .red },
};

/// Colors of a context window bar by the percentage filled.
const fill_stops = [_]color.Stop{
    .{ .at = 0.0, .hue = .blue },
    .{ .at = 15.0, .hue = .green },
    .{ .at = 60.0, .hue = .yellow },
    .{ .at = 100.0, .hue = .red },
};

/// Average rate, in percent of the window per hour, at which the window has
/// been consumed so far.
///
/// `used_pct` is the share of the window already spent, in [0, 100].
/// `elapsed_h` is the time since the window opened, in hours.
///
/// Nothing spent is a rate of zero regardless of `elapsed_h`. Anything spent
/// with no time elapsed is an infinite rate. A NaN argument is treated as
/// nothing spent.
pub fn rate(used_pct: f64, elapsed_h: f64) f64 {
    if (!(used_pct > 0.0)) return 0.0;
    if (!(elapsed_h > 0.0)) return std.math.inf(f64);
    return used_pct / elapsed_h;
}

test rate {
    // Half the window spent over the first two hours.
    try testing.expectEqual(@as(f64, 25.0), rate(50.0, 2.0));
}

/// Average rate, in percent of the window per hour, that the unspent share
/// affords from now until the window resets.
///
/// `used_pct` is the share of the window already spent, in [0, 100].
/// `remaining_h` is the time left until the reset, in hours.
///
/// An exhausted window affords a rate of zero. A window that is already due
/// to reset affords an infinite rate. A NaN argument is treated as an
/// exhausted window.
pub fn budget(used_pct: f64, remaining_h: f64) f64 {
    const unspent_pct = 100.0 - used_pct;
    if (!(unspent_pct > 0.0)) return 0.0;
    if (!(remaining_h > 0.0)) return std.math.inf(f64);
    return unspent_pct / remaining_h;
}

test budget {
    // A fifth of the window left with three days to go.
    try testing.expectApproxEqRel(@as(f64, 0.2777), budget(80.0, 72.0), 1e-3);
}

/// How many times the current burn rate amounts to the rate the unspent share
/// affords.
///
/// Zero means nothing is spent, one means spending in lockstep with the clock
/// and infinity means the window is exhausted or was spent in no time.
///
/// `window_h` is the full length of the window in hours and `remaining_h` the
/// time left until it resets; the time elapsed is derived from the two and
/// clamped to the window. Asserts `window_h` is positive.
pub fn multiple(used_pct: f64, window_h: f64, remaining_h: f64) f64 {
    std.debug.assert(window_h > 0.0);
    const elapsed_h = std.math.clamp(window_h - remaining_h, 0.0, window_h);

    const current = rate(used_pct, elapsed_h);
    if (current == 0.0) return 0.0;

    const affordable = budget(used_pct, remaining_h);
    if (affordable == 0.0) return std.math.inf(f64);
    if (std.math.isInf(affordable)) return 0.0;
    return current / affordable;
}

test multiple {
    // Two hours into a five hour window with half of it spent: the current
    // rate of 25 %/h is 1.5 times the 16.7 %/h the rest of the window affords.
    try testing.expectApproxEqRel(@as(f64, 1.5), multiple(50.0, 5.0, 3.0), 1e-9);
}

test "multiple: an untouched window is zero" {
    try testing.expectEqual(@as(f64, 0.0), multiple(0.0, 5.0, 5.0));
    try testing.expectEqual(@as(f64, 0.0), multiple(0.0, 5.0, 1.0));
    try testing.expectEqual(@as(f64, 0.0), multiple(0.0, 168.0, 0.0));
}

test "multiple: spending exactly in step is one" {
    // Linear consumption keeps the current rate equal to the affordable rate.
    try testing.expectApproxEqRel(@as(f64, 1.0), multiple(20.0, 5.0, 4.0), 1e-9);
    try testing.expectApproxEqRel(@as(f64, 1.0), multiple(60.0, 5.0, 2.0), 1e-9);
    try testing.expectApproxEqRel(@as(f64, 1.0), multiple(50.0, 168.0, 84.0), 1e-9);
}

test "multiple: an exhausted window is infinite" {
    try testing.expect(std.math.isInf(multiple(100.0, 5.0, 2.0)));
    try testing.expect(std.math.isInf(multiple(100.0, 5.0, 0.0)));
}

test "multiple: spending with no time elapsed is infinite" {
    try testing.expect(std.math.isInf(multiple(1.0, 5.0, 5.0)));
}

test "multiple: nan is treated as an untouched window" {
    try testing.expectEqual(@as(f64, 0.0), multiple(std.math.nan(f64), 5.0, 2.0));
}

/// Pick a foreground escape sequence for a rate limit bar by how the current
/// burn rate compares to the affordable one.
///
/// Blue below 0.5 times the affordable rate, green from 0.8 to 1.15 times it,
/// yellow at 1.7 times and red at 2.5 times and beyond. The colors in between
/// are blended. Arguments are as in `multiple`.
pub fn paceColor(used_pct: f64, window_h: f64, remaining_h: f64) []const u8 {
    return color.gradient(&multiple_stops, @log2(multiple(used_pct, window_h, remaining_h)));
}

test paceColor {
    // On pace is green, far behind is blue and far ahead is red.
    try testing.expectEqualStrings("\x1B[38;5;46m", paceColor(20.0, 5.0, 4.0));
    try testing.expectEqualStrings("\x1B[38;5;21m", paceColor(0.0, 5.0, 4.0));
    try testing.expectEqualStrings("\x1B[38;5;196m", paceColor(100.0, 5.0, 2.0));
}

test "paceColor: below half the affordable rate is blue" {
    // 8 % spent in one hour against the 23 %/h the remaining four afford.
    try testing.expectEqualStrings("\x1B[38;5;21m", paceColor(8.0, 5.0, 4.0));
}

test "paceColor: from 0.8 to 1.15 times the affordable rate is green" {
    // 0.8 times: 4u / (100 - u) = 0.8; 1.15 times: 4u / (100 - u) = 1.15.
    try testing.expectEqualStrings("\x1B[38;5;46m", paceColor(100.0 * 0.8 / 4.8, 5.0, 4.0));
    try testing.expectEqualStrings("\x1B[38;5;46m", paceColor(100.0 * 1.15 / 5.15, 5.0, 4.0));
}

test "paceColor: between half and 0.8 blends from blue to green" {
    const sequence = paceColor(100.0 * 0.63 / 4.63, 5.0, 4.0);
    try testing.expect(!std.mem.eql(u8, "\x1B[38;5;21m", sequence));
    try testing.expect(!std.mem.eql(u8, "\x1B[38;5;46m", sequence));
}

test "paceColor: 1.7 times the affordable rate is yellow" {
    try testing.expectEqualStrings("\x1B[38;5;226m", paceColor(100.0 * 1.7 / 5.7, 5.0, 4.0));
}

test "paceColor: 2.5 times the affordable rate is red" {
    try testing.expectEqualStrings("\x1B[38;5;196m", paceColor(100.0 * 2.5 / 6.5, 5.0, 4.0));
}

/// Pick a foreground escape sequence for a context window bar by the
/// percentage filled.
///
/// Blue when empty, green at 15 %, yellow at 60 % and red when full. The
/// colors in between are blended. A NaN `used_pct` is blue.
pub fn fillColor(used_pct: f64) []const u8 {
    return color.gradient(&fill_stops, used_pct);
}

test fillColor {
    try testing.expectEqualStrings("\x1B[38;5;21m", fillColor(0.0));
    try testing.expectEqualStrings("\x1B[38;5;46m", fillColor(15.0));
    try testing.expectEqualStrings("\x1B[38;5;226m", fillColor(60.0));
    try testing.expectEqualStrings("\x1B[38;5;196m", fillColor(100.0));
}

test "fillColor: nan is blue" {
    try testing.expectEqualStrings("\x1B[38;5;21m", fillColor(std.math.nan(f64)));
}

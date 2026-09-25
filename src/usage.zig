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

/// Time unit a rate is expressed per.
pub const Unit = enum {
    d,
    h,
    min,
    s,
    ms,

    /// How many of the unit make up one hour.
    fn perHour(self: Unit) f64 {
        return switch (self) {
            .d => 1.0 / 24.0,
            .h => 1.0,
            .min => 60.0,
            .s => 3600.0,
            .ms => 3_600_000.0,
        };
    }
};

/// A rate in percent of the window per `unit`, scaled by `scale` to be easy to
/// read.
pub const Scaled = struct {
    pct: f64,
    unit: Unit,

    pub fn format(self: Scaled, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:.2}%/{s}", .{ self.pct, @tagName(self.unit) });
    }
};

/// Express a rate per hour in the time unit that keeps the number small.
///
/// From one percent per hour on, the largest of hours, minutes, seconds and
/// milliseconds that keeps the number at or below 60 is used. Below one percent
/// per hour the rate is given per day, which is at most 24 there. The slowest
/// unit that is still readable is preferred, so 36 %/h is not 0.6 %/min.
///
/// `rate_h` is the rate in percent of the window per hour. A NaN or negative
/// `rate_h` is treated as zero and an infinite one is given per millisecond.
pub fn scale(rate_h: f64) Scaled {
    if (!(rate_h > 0.0)) return .{ .pct = 0.0, .unit = .d };
    if (rate_h < 1.0) return .{ .pct = rate_h / Unit.d.perHour(), .unit = .d };
    inline for (.{ Unit.h, Unit.min, Unit.s }) |unit| {
        const pct = rate_h / unit.perHour();
        if (pct <= 60.0) return .{ .pct = pct, .unit = unit };
    }
    return .{ .pct = rate_h / Unit.ms.perHour(), .unit = .ms };
}

test scale {
    // 0.01 %/s is 0.6 %/min is 36 %/h.
    const s = scale(36.0);
    try testing.expectApproxEqRel(@as(f64, 36.0), s.pct, 1e-9);
    try testing.expectEqual(Unit.h, s.unit);
    // 61 %/h is 1.02 %/min.
    const min = scale(61.0);
    try testing.expectApproxEqRel(@as(f64, 61.0 / 60.0), min.pct, 1e-9);
    try testing.expectEqual(Unit.min, min.unit);
}

test "scale: below one percent per hour is per day" {
    const s = scale(0.5);
    try testing.expectApproxEqRel(@as(f64, 12.0), s.pct, 1e-9);
    try testing.expectEqual(Unit.d, s.unit);
}

test "scale: the boundaries stay in the slower unit" {
    try testing.expectEqual(Unit.h, scale(1.0).unit);
    try testing.expectEqual(Unit.h, scale(60.0).unit);
    try testing.expectEqual(Unit.min, scale(3600.0).unit);
    try testing.expectEqual(Unit.s, scale(216_000.0).unit);
    try testing.expectEqual(Unit.ms, scale(216_000.1).unit);
}

test "scale: zero, nan and negative are zero per day" {
    for ([_]f64{ 0.0, std.math.nan(f64), -1.0 }) |rate_h| {
        const s = scale(rate_h);
        try testing.expectEqual(@as(f64, 0.0), s.pct);
        try testing.expectEqual(Unit.d, s.unit);
    }
}

test "scale: infinite is infinite per millisecond" {
    const s = scale(std.math.inf(f64));
    try testing.expect(std.math.isInf(s.pct));
    try testing.expectEqual(Unit.ms, s.unit);
}

test "Scaled: is written with two digits" {
    try testing.expectFmt("36.00%/h", "{f}", .{Scaled{ .pct = 36.0, .unit = .h }});
    try testing.expectFmt("1.02%/min", "{f}", .{Scaled{ .pct = 1.0166, .unit = .min }});
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

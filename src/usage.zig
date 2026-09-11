const std = @import("std");
const testing = std.testing;

/// Burn-rate multiple of the affordable rate that still counts as on pace.
const multiple_green = 1.15;

/// Burn-rate multiple of the affordable rate that counts as fully over budget.
const multiple_red = 2.5;

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

/// How far the current burn rate overshoots the rate the unspent share
/// affords, as a value in [0, 1] suitable for driving a color ramp.
///
/// Zero means on pace or better, one means burning through the window at
/// `multiple_red` times the affordable rate or worse. The scale is linear in
/// the logarithm of that multiple, so it tracks how many times over budget
/// the session is rather than the absolute difference between two rates.
///
/// `window_h` is the full length of the window in hours and `remaining_h` the
/// time left until it resets; the time elapsed is derived from the two and
/// clamped to the window. Asserts `window_h` is positive.
pub fn pressure(used_pct: f64, window_h: f64, remaining_h: f64) f64 {
    std.debug.assert(window_h > 0.0);
    const elapsed_h = std.math.clamp(window_h - remaining_h, 0.0, window_h);

    const current = rate(used_pct, elapsed_h);
    if (current == 0.0) return 0.0;

    const affordable = budget(used_pct, remaining_h);
    if (affordable == 0.0) return 1.0;
    if (std.math.isInf(affordable)) return 0.0;
    if (std.math.isInf(current)) return 1.0;

    const green_at = comptime @log2(@as(f64, multiple_green));
    const red_at = comptime @log2(@as(f64, multiple_red));
    const overshoot = @log2(current / affordable);
    return std.math.clamp((overshoot - green_at) / (red_at - green_at), 0.0, 1.0);
}

test pressure {
    // Two hours into a five hour window with half of it spent: the current
    // rate of 25 %/h is well over the 16.7 %/h the rest of the window affords.
    try testing.expect(pressure(50.0, 5.0, 3.0) > 0.5);
}

test "pressure: an untouched window is on pace" {
    try testing.expectEqual(@as(f64, 0.0), pressure(0.0, 5.0, 5.0));
    try testing.expectEqual(@as(f64, 0.0), pressure(0.0, 5.0, 1.0));
    try testing.expectEqual(@as(f64, 0.0), pressure(0.0, 168.0, 0.0));
}

test "pressure: spending exactly in step is on pace" {
    // Linear consumption keeps the current rate equal to the affordable rate.
    try testing.expectEqual(@as(f64, 0.0), pressure(20.0, 5.0, 4.0));
    try testing.expectEqual(@as(f64, 0.0), pressure(60.0, 5.0, 2.0));
    try testing.expectEqual(@as(f64, 0.0), pressure(50.0, 168.0, 84.0));
}

test "pressure: spending below pace is on pace" {
    try testing.expectEqual(@as(f64, 0.0), pressure(10.0, 5.0, 4.0));
    try testing.expectEqual(@as(f64, 0.0), pressure(5.0, 168.0, 84.0));
}

test "pressure: the tolerated overshoot is still on pace" {
    // 22.5 % spent in one hour against the 19.375 %/h the remaining four
    // hours afford is a multiple of 1.16, just past the green band.
    try testing.expect(pressure(22.5, 5.0, 4.0) > 0.0);
    try testing.expect(pressure(22.0, 5.0, 4.0) == 0.0);
}

test "pressure: an exhausted window is fully over budget" {
    try testing.expectEqual(@as(f64, 1.0), pressure(100.0, 5.0, 2.0));
    try testing.expectEqual(@as(f64, 1.0), pressure(100.0, 5.0, 0.0));
}

test "pressure: spending with no time elapsed is fully over budget" {
    try testing.expectEqual(@as(f64, 1.0), pressure(1.0, 5.0, 5.0));
}

test "pressure: grows with the multiple of the affordable rate" {
    const on_pace = pressure(20.0, 5.0, 4.0);
    const mild = pressure(30.0, 5.0, 4.0);
    const heavy = pressure(38.0, 5.0, 4.0);
    try testing.expect(on_pace < mild);
    try testing.expect(mild < heavy);
    try testing.expectEqual(@as(f64, 1.0), pressure(55.0, 5.0, 4.0));
}

test "pressure: reaches the midpoint at the geometric mean of the multiples" {
    // One hour into a five hour window the ratio of the current rate to the
    // affordable one is 4u / (100 - u); solve that for the geometric mean of
    // the two multiples, which is the midpoint in logarithmic space.
    const mean = @sqrt(@as(f64, multiple_green * multiple_red));
    const used_pct = 100.0 * mean / (4.0 + mean);
    try testing.expectApproxEqAbs(@as(f64, 0.5), pressure(used_pct, 5.0, 4.0), 1e-9);
}

test "pressure: nan is treated as an untouched window" {
    try testing.expectEqual(@as(f64, 0.0), pressure(std.math.nan(f64), 5.0, 2.0));
}

/// Map a fill percentage onto the same [0, 1] scale as `pressure`, for a
/// window that has no reset to pace against.
///
/// `pct_yellow` maps to the midpoint of the scale and `pct_red` to its end.
/// A NaN `used_pct` maps to the start. Asserts `pct_yellow` is below
/// `pct_red`.
pub fn fill(used_pct: f64, pct_yellow: f64, pct_red: f64) f64 {
    std.debug.assert(pct_yellow < pct_red);
    if (used_pct != used_pct) return 0.0;
    const half_span = pct_red - pct_yellow;
    return std.math.clamp(0.5 + 0.5 * (used_pct - pct_yellow) / half_span, 0.0, 1.0);
}

test fill {
    try testing.expectEqual(@as(f64, 0.5), fill(50.0, 50.0, 65.0));
    try testing.expectEqual(@as(f64, 1.0), fill(65.0, 50.0, 65.0));
    try testing.expectEqual(@as(f64, 0.0), fill(35.0, 50.0, 65.0));
    try testing.expectEqual(@as(f64, 0.0), fill(0.0, 50.0, 65.0));
}

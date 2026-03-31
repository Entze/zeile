const std = @import("std");
const testing = std.testing;

/// Render a text-based progress bar as a fixed-size byte array.
///
/// The bar has `bar_width` character positions. Each position transitions
/// through `segments.len + 1` visual states: `blank`, then `segments[0]`,
/// `segments[1]`, ..., `segments[segments.len - 1]`. Positions fill left
/// to right — a position completes all segment states before the next
/// position begins.
///
/// All segments must be exactly one byte. The returned array has a
/// comptime-known length of `prefix.len + bar_width + postfix.len`.
///
/// `progress_pct` is clamped to [0, 100]. NaN is treated as 0.
pub fn format(
    comptime bar_width: comptime_int,
    comptime prefix: []const u8,
    comptime blank: u8,
    comptime segments: []const []const u8,
    comptime postfix: []const u8,
    progress_pct: f64,
) [prefix.len + bar_width + postfix.len]u8 {
    comptime {
        if (bar_width <= 0) @compileError("bar_width must be positive");
        if (segments.len == 0) @compileError("segments must not be empty");
        for (segments) |seg| {
            if (seg.len != 1) @compileError("each segment must be exactly one byte");
        }
    }

    const total_steps: comptime_int = bar_width * segments.len;
    const result_len = prefix.len + bar_width + postfix.len;

    const clamped = if (progress_pct != progress_pct)
        0.0 // NaN
    else
        @min(@max(progress_pct, 0.0), 100.0);
    std.debug.assert(0.0 <= clamped);
    std.debug.assert(clamped <= 100.0);

    const step: usize = @min(
        @divFloor(@as(usize, @intFromFloat(clamped * @as(f64, total_steps))), 100),
        total_steps,
    );
    std.debug.assert(step <= total_steps);

    const filled: usize = step / segments.len;
    const partial: usize = step % segments.len;

    var buf: [result_len]u8 = undefined;
    var pos: usize = 0;

    // prefix
    for (prefix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    // filled positions
    for (0..filled) |_| {
        buf[pos] = segments[segments.len - 1][0];
        pos += 1;
    }

    // partial position
    if (partial > 0 and filled < bar_width) {
        buf[pos] = segments[partial - 1][0];
        pos += 1;
    }

    // blank positions
    while (pos < prefix.len + bar_width) {
        buf[pos] = blank;
        pos += 1;
    }

    // postfix
    for (postfix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    return buf;
}

test format {
    const bar = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 48.0);
    try testing.expectEqualStrings("[#- ]", &bar);
}

test "all blank at zero percent" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 0.0);
    try testing.expectEqualStrings("[   ]", &result);
}

test "first segment state" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 12.0);
    try testing.expectEqualStrings("[-  ]", &result);
}

test "second segment state" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 24.0);
    try testing.expectEqualStrings("[=  ]", &result);
}

test "first position complete" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 36.0);
    try testing.expectEqualStrings("[#  ]", &result);
}

test "partial second position" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 48.0);
    try testing.expectEqualStrings("[#- ]", &result);
}

test "fully complete at 100 percent" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 100.0);
    try testing.expectEqualStrings("[###]", &result);
}

test "negative clamped to zero" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", -5.0);
    try testing.expectEqualStrings("[   ]", &result);
}

test "over 100 clamped to full" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", 150.0);
    try testing.expectEqualStrings("[###]", &result);
}

test "nan treated as zero" {
    const result = format(3, "[", ' ', &.{ "-", "=", "#" }, "]", std.math.nan(f64));
    try testing.expectEqualStrings("[   ]", &result);
}

test "single segment" {
    const result = format(4, "[", ' ', &.{"#"}, "]", 50.0);
    try testing.expectEqualStrings("[##  ]", &result);
}

test "custom prefix and postfix" {
    const result = format(3, "<<", '.', &.{"#"}, ">>", 100.0);
    try testing.expectEqualStrings("<<###>>", &result);
}

test "different blank char" {
    const result = format(3, "|", '.', &.{"#"}, "|", 0.0);
    try testing.expectEqualStrings("|...|", &result);
}

test "single position bar" {
    const result = format(1, "[", ' ', &.{ "-", "#" }, "]", 50.0);
    try testing.expectEqualStrings("[-]", &result);
}

test "segment boundary transitions" {
    // bar_width=4, segments=4 → 16 total steps, each step = 6.25% (exact in f64)
    // Boundary at 6.25%: test just below and just above
    const below_first = format(4, "[", ' ', &.{ "-", "=", "#", "X" }, "]", 6.0);
    try testing.expectEqualStrings("[    ]", &below_first);

    const above_first = format(4, "[", ' ', &.{ "-", "=", "#", "X" }, "]", 6.5);
    try testing.expectEqualStrings("[-   ]", &above_first);

    // Boundary at 25.0%: first position complete, test just below and just above
    const below_complete = format(4, "[", ' ', &.{ "-", "=", "#", "X" }, "]", 24.5);
    try testing.expectEqualStrings("[#   ]", &below_complete);

    const above_complete = format(4, "[", ' ', &.{ "-", "=", "#", "X" }, "]", 25.5);
    try testing.expectEqualStrings("[X   ]", &above_complete);
}

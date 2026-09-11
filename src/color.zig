const std = @import("std");
const testing = std.testing;

/// Turn off every attribute set so far.
pub const reset = "\x1B[0m";

/// Foreground green, from the basic eight-color palette.
pub const green = "\x1B[32m";

/// Foreground red, from the basic eight-color palette.
pub const red = "\x1B[31m";

/// Foreground escape sequences stepping from green through yellow to red
/// along the edges of the 6x6x6 cube of the 256-color palette.
const ramp = [_][]const u8{
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

/// Pick a foreground escape sequence from a green through yellow to red ramp.
///
/// `severity` is clamped to [0, 1]: zero picks green, one half picks yellow
/// and one picks red. NaN picks green.
pub fn gradient(severity: f64) []const u8 {
    const clamped = if (severity != severity) 0.0 else std.math.clamp(severity, 0.0, 1.0);
    const step: usize = @intFromFloat(@round(clamped * @as(f64, ramp.len - 1)));
    std.debug.assert(step < ramp.len);
    return ramp[step];
}

test gradient {
    try testing.expectEqualStrings("\x1B[38;5;226m", gradient(0.5));
}

test "gradient: ends of the ramp" {
    try testing.expectEqualStrings(ramp[0], gradient(0.0));
    try testing.expectEqualStrings(ramp[ramp.len - 1], gradient(1.0));
}

test "gradient: out of range severity is clamped" {
    try testing.expectEqualStrings(ramp[0], gradient(-1.0));
    try testing.expectEqualStrings(ramp[ramp.len - 1], gradient(2.0));
    try testing.expectEqualStrings(ramp[0], gradient(std.math.nan(f64)));
}

test "gradient: severity never decreases the step" {
    var previous: usize = 0;
    for (0..101) |i| {
        const severity = @as(f64, @floatFromInt(i)) / 100.0;
        const sequence = gradient(severity);
        const step = for (ramp, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, sequence)) break index;
        } else unreachable;
        try testing.expect(step >= previous);
        previous = step;
    }
    try testing.expectEqual(ramp.len - 1, previous);
}

const std = @import("std");
const testing = std.testing;

/// Whole seconds written with a precision that follows their magnitude.
///
/// Days and hours from one day on, hours and minutes from one hour on, and
/// minutes and seconds below that. Smaller units are truncated, not rounded,
/// and units that are zero are left out, so 90 000 seconds is `1d1h` and
/// 86 400 seconds is `1d`. Zero seconds is `0s`.
pub const Coarse = struct {
    seconds: u64,

    pub fn format(self: Coarse, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const days = self.seconds / std.time.s_per_day;
        const hours = self.seconds % std.time.s_per_day / std.time.s_per_hour;
        const minutes = self.seconds % std.time.s_per_hour / std.time.s_per_min;
        const seconds = self.seconds % std.time.s_per_min;

        if (days > 0) {
            try writeUnit(w, days, 'd');
            try writeUnit(w, hours, 'h');
        } else if (hours > 0) {
            try writeUnit(w, hours, 'h');
            try writeUnit(w, minutes, 'm');
        } else {
            try writeUnit(w, minutes, 'm');
            try writeUnit(w, seconds, 's');
        }
        if (self.seconds == 0) try w.writeAll("0s");
    }
};

fn writeUnit(w: *std.Io.Writer, count: u64, suffix: u8) std.Io.Writer.Error!void {
    if (count == 0) return;
    try w.print("{d}{c}", .{ count, suffix });
}

test Coarse {
    try testing.expectFmt("1h23m", "{f}", .{Coarse{ .seconds = 1 * 3600 + 23 * 60 + 45 }});
}

test "Coarse: seconds are shown below one hour" {
    try testing.expectFmt("0s", "{f}", .{Coarse{ .seconds = 0 }});
    try testing.expectFmt("59s", "{f}", .{Coarse{ .seconds = 59 }});
    try testing.expectFmt("1m", "{f}", .{Coarse{ .seconds = 60 }});
    try testing.expectFmt("59m59s", "{f}", .{Coarse{ .seconds = 3599 }});
}

test "Coarse: seconds are dropped from one hour on" {
    try testing.expectFmt("1h", "{f}", .{Coarse{ .seconds = 3600 }});
    try testing.expectFmt("1h", "{f}", .{Coarse{ .seconds = 3659 }});
    try testing.expectFmt("1h1m", "{f}", .{Coarse{ .seconds = 3660 }});
    try testing.expectFmt("23h59m", "{f}", .{Coarse{ .seconds = 86399 }});
}

test "Coarse: minutes are dropped from one day on" {
    try testing.expectFmt("1d", "{f}", .{Coarse{ .seconds = 86400 }});
    try testing.expectFmt("1d", "{f}", .{Coarse{ .seconds = 86400 + 3599 }});
    try testing.expectFmt("1d1h", "{f}", .{Coarse{ .seconds = 86400 + 3600 }});
    try testing.expectFmt("6d23h", "{f}", .{Coarse{ .seconds = 7 * 86400 - 1 }});
    try testing.expectFmt("7d", "{f}", .{Coarse{ .seconds = 7 * 86400 }});
}

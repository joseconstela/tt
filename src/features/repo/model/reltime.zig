//! How long ago something happened, in a few words: "now", "5 min ago",
//! "2 h ago", "yesterday", "3 days ago", "2 weeks ago", "4 months ago",
//! "2 years ago". Both times are seconds since the epoch; a time in the
//! future (a clock that is off) reads "now".
const std = @import("std");

const minute: i64 = 60;
const hour: i64 = 60 * minute;
const day: i64 = 24 * hour;

/// Writes into `buf` (32 bytes is plenty) and returns what it wrote.
pub fn ago(buf: []u8, now: i64, then: i64) []const u8 {
    const d = now - then;
    if (d < minute) return "now";
    if (d < hour) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(d, minute)}) catch "";
    if (d < day) return std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(d, hour)}) catch "";
    const days = @divTrunc(d, day);
    if (days == 1) return "yesterday";
    if (days < 14) return std.fmt.bufPrint(buf, "{d} days ago", .{days}) catch "";
    if (days < 60) return std.fmt.bufPrint(buf, "{d} weeks ago", .{@divTrunc(days, 7)}) catch "";
    if (days < 365) return std.fmt.bufPrint(buf, "{d} months ago", .{@divTrunc(days, 30)}) catch "";
    const years = @divTrunc(days, 365);
    if (years == 1) return "1 year ago";
    return std.fmt.bufPrint(buf, "{d} years ago", .{years}) catch "";
}

test "ago" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_795_290_900;
    try std.testing.expectEqualStrings("now", ago(&buf, now, now - 20));
    try std.testing.expectEqualStrings("now", ago(&buf, now, now + 500));
    try std.testing.expectEqualStrings("5 min ago", ago(&buf, now, now - 5 * minute - 3));
    try std.testing.expectEqualStrings("2 h ago", ago(&buf, now, now - 2 * hour - 10));
    try std.testing.expectEqualStrings("yesterday", ago(&buf, now, now - 30 * hour));
    try std.testing.expectEqualStrings("3 days ago", ago(&buf, now, now - 3 * day));
    try std.testing.expectEqualStrings("2 weeks ago", ago(&buf, now, now - 15 * day));
    try std.testing.expectEqualStrings("4 months ago", ago(&buf, now, now - 125 * day));
    try std.testing.expectEqualStrings("1 year ago", ago(&buf, now, now - 400 * day));
    try std.testing.expectEqualStrings("3 years ago", ago(&buf, now, now - 1100 * day));
}

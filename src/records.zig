//! Tab-separated records with backslash-escaped fields: the on-disk shape of
//! the workspace file and of a tab's saved blocks. One record per line, its
//! tag first. Inside a field a tab, newline, carriage return, escape byte or
//! backslash is written as \t \n \r \e \\, so a record never spans lines and
//! terminal output (SGR sequences included) survives a round trip.
const std = @import("std");

pub fn escape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            0x1b => try out.appendSlice(gpa, "\\e"),
            else => try out.append(gpa, ch),
        }
    }
}

/// Undoes `escape` into `out` (emptied first) and returns its contents.
pub fn unescape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 == s.len) {
            try out.append(gpa, s[i]);
            continue;
        }
        i += 1;
        try out.append(gpa, switch (s[i]) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            'e' => 0x1b,
            else => s[i],
        });
    }
    return out.items;
}

test "records: escaping round-trips every special byte" {
    const gpa = std.testing.allocator;
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(gpa);
    var back: std.ArrayList(u8) = .empty;
    defer back.deinit(gpa);
    const original = "a\tb\nc\rd\x1b[1me\\f \\t";
    try escape(&esc, gpa, original);
    try std.testing.expectEqualStrings("a\\tb\\nc\\rd\\e[1me\\\\f \\\\t", esc.items);
    try std.testing.expect(std.mem.indexOfAny(u8, esc.items, "\t\n\r\x1b") == null);
    try std.testing.expectEqualStrings(original, try unescape(&back, gpa, esc.items));
    // A stray trailing backslash is kept rather than dropped.
    try std.testing.expectEqualStrings("x\\", try unescape(&back, gpa, "x\\"));
}

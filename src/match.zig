//! The matchers behind the palette's rows and the quick-open file list:
//! a case-insensitive subsequence match that scores runs and word starts,
//! and a contiguous one for long shell commands. Both report which code
//! points matched, so the rows can draw them in bold.
const std = @import("std");
const gfx_text = @import("gfx/text.zig");

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Case-insensitive subsequence match of `q` in `hay`. Sets the bits of the
/// matched code point indices (first 64) and returns a score, higher is
/// better: runs and word starts score, a late first hit costs.
pub fn fuzzy(q: []const u8, hay: []const u8, mask: *u64) ?i32 {
    mask.* = 0;
    if (q.len == 0) return 0;
    var score: i32 = 0;
    var qi: usize = 0;
    var prev_matched = false;
    var prev_byte: u8 = ' ';
    var first: ?usize = null;
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = hay };
    while (true) : (idx += 1) {
        const at = it.index;
        _ = it.next() orelse break;
        const hb = hay[at..it.index];
        const qlen = std.unicode.utf8ByteSequenceLength(q[qi]) catch 1;
        const qb = q[qi..@min(q.len, qi + qlen)];
        var eq = hb.len == qb.len;
        if (eq) for (hb, qb) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                eq = false;
                break;
            }
        };
        if (eq) {
            const word_start = idx == 0 or !isWordByte(prev_byte);
            score += if (prev_matched) 4 else if (word_start) 3 else 1;
            if (first == null) first = idx;
            if (idx < 64) mask.* |= @as(u64, 1) << @intCast(idx);
            qi += qb.len;
            prev_matched = true;
            if (qi >= q.len) break;
        } else prev_matched = false;
        prev_byte = hb[0];
    }
    if (qi < q.len) return null;
    return score - @as(i32, @intCast(@min(first.?, 20)));
}

/// Case-insensitive contiguous match, for long shell commands where a
/// subsequence match would hit almost anything. Earlier hits score higher.
pub fn substring(q: []const u8, hay: []const u8, mask: *u64) ?i32 {
    mask.* = 0;
    if (q.len == 0) return 0;
    const at = std.ascii.indexOfIgnoreCase(hay, q) orelse return null;
    // Byte offsets → code point indices for the highlight mask.
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = hay };
    while (it.index < at) : (idx += 1) _ = it.next() orelse break;
    const first = idx;
    while (it.index < at + q.len) : (idx += 1) {
        if (idx < 64) mask.* |= @as(u64, 1) << @intCast(idx);
        _ = it.next() orelse break;
    }
    return 50 - @as(i32, @intCast(@min(first, 40)));
}

// ── tests ────────────────────────────────────────────────────────────────
test "substring match is contiguous and case-insensitive" {
    var m: u64 = 0;
    try std.testing.expect(substring("STAT", "git status -sb", &m) != null);
    try std.testing.expectEqual(@as(u64, 0b1111 << 4), m);
    try std.testing.expect(substring("gs", "git status", &m) == null);
    try std.testing.expect(substring("ndú", "echo ñandú", &m) != null);
    try std.testing.expectEqual(@as(u64, 0b111 << 7), m);
}

test "fuzzy prefers word starts and runs, ignores case" {
    var m: u64 = 0;
    const a = fuzzy("nt", "New terminal tab", &m).?;
    try std.testing.expectEqual(@as(u64, 0b10001), m); // "N" and the "t" of "terminal"
    const b = fuzzy("nt", "Untangle", &m).?;
    try std.testing.expect(a > b);
    try std.testing.expect(fuzzy("xyz", "New terminal tab", &m) == null);
    try std.testing.expect(fuzzy("close tab", "Close tab", &m) != null);
    try std.testing.expect(fuzzy("ñ", "ñandú", &m) != null);
}

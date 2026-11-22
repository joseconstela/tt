//! Line diff for the side-by-side comparison (`entry/tab.zig`): two
//! texts in, *rows* out. A row is one line of the comparison: the same line
//! on both sides, a line that changed (old on the left, new on the right),
//! or a line only one side has, facing a blank on the other.
//!
//! The lines are compared with Myers' O(ND) algorithm after the common
//! start and end are set aside. A pair of texts further apart than
//! `max_distance` edits is not searched to the end: everything between
//! the common start and end is then shown as replaced, which is what such
//! a pair looks like anyway.
const std = @import("std");

pub const Kind = enum(u8) { same, changed, removed, added };

pub const Row = struct {
    /// 1-based line numbers; 0 where the side has no line (a blank).
    left: u32,
    right: u32,
    kind: Kind,
};

/// Edits (lines removed + lines added) the search goes up to.
const max_distance: usize = 2000;

/// `text` as lines, without their terminators ("\n" or "\r\n"). A final
/// newline ends the last line rather than starting an empty one; an empty
/// text has no lines. The slices point into `text`.
pub fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        var end = nl;
        if (end > pos and text[end - 1] == '\r') end -= 1;
        try out.append(gpa, text[pos..end]);
        pos = nl + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The comparison of `a` (old) and `b` (new), top to bottom. Caller frees.
pub fn rows(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]Row {
    // Lines become numbers, so comparing two is comparing two integers.
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    defer ids.deinit(gpa);
    const ai = try gpa.alloc(u32, a.len);
    defer gpa.free(ai);
    const bi = try gpa.alloc(u32, b.len);
    defer gpa.free(bi);
    for ([_]struct { lines: []const []const u8, out: []u32 }{ .{ .lines = a, .out = ai }, .{ .lines = b, .out = bi } }) |side| {
        for (side.lines, side.out) |line, *id| {
            const gop = try ids.getOrPut(gpa, line);
            if (!gop.found_existing) gop.value_ptr.* = ids.count();
            id.* = gop.value_ptr.*;
        }
    }

    var head: usize = 0;
    while (head < ai.len and head < bi.len and ai[head] == bi[head]) head += 1;
    var tail: usize = 0;
    while (tail < ai.len - head and tail < bi.len - head and ai[ai.len - 1 - tail] == bi[bi.len - 1 - tail]) tail += 1;
    const ma = ai[head .. ai.len - tail];
    const mb = bi[head .. bi.len - tail];

    // Which lines of the middle part go (`gone`) and which arrive (`new`).
    const gone = try gpa.alloc(bool, ma.len);
    defer gpa.free(gone);
    const new = try gpa.alloc(bool, mb.len);
    defer gpa.free(new);
    if (!try myers(gpa, ma, mb, gone, new)) {
        @memset(gone, true);
        @memset(new, true);
    }

    var out: std.ArrayList(Row) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, @max(a.len, b.len));
    for (0..head) |k| try out.append(gpa, .{ .left = @intCast(k + 1), .right = @intCast(k + 1), .kind = .same });
    var i: usize = 0;
    var j: usize = 0;
    while (i < ma.len or j < mb.len) {
        var da: usize = 0;
        while (i + da < ma.len and gone[i + da]) da += 1;
        var db: usize = 0;
        while (j + db < mb.len and new[j + db]) db += 1;
        if (da == 0 and db == 0) {
            try out.append(gpa, .{ .left = @intCast(head + i + 1), .right = @intCast(head + j + 1), .kind = .same });
            i += 1;
            j += 1;
            continue;
        }
        // A run of removals next to a run of additions: line k of one
        // faces line k of the other, what is left over faces blanks.
        const both = @min(da, db);
        for (0..@max(da, db)) |k| {
            const l: u32 = if (k < da) @intCast(head + i + k + 1) else 0;
            const r: u32 = if (k < db) @intCast(head + j + k + 1) else 0;
            try out.append(gpa, .{ .left = l, .right = r, .kind = if (k < both) .changed else if (k < da) .removed else .added });
        }
        i += da;
        j += db;
    }
    for (0..tail) |k| {
        try out.append(gpa, .{ .left = @intCast(ai.len - tail + k + 1), .right = @intCast(bi.len - tail + k + 1), .kind = .same });
    }
    return out.toOwnedSlice(gpa);
}

/// Myers' shortest edit script between `a` and `b`, marked into `gone`
/// (lines of `a` to remove) and `new` (lines of `b` to add). False when
/// the two are more than `max_distance` edits apart: nothing is marked.
fn myers(gpa: std.mem.Allocator, a: []const u32, b: []const u32, gone: []bool, new: []bool) !bool {
    @memset(gone, false);
    @memset(new, false);
    const n: i32 = @intCast(a.len);
    const m: i32 = @intCast(b.len);
    if (n == 0 or m == 0) {
        @memset(gone, true);
        @memset(new, true);
        return true;
    }
    const d_max: i32 = @intCast(@min(a.len + b.len, max_distance));
    // v[k] is how far along `a` the best path on diagonal k (x - y) got;
    // `trace` keeps v as it was before each round, to walk the path back.
    const width: usize = @intCast(2 * d_max + 3);
    const off: i32 = d_max + 1;
    const v = try gpa.alloc(i32, width);
    defer gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList([]i32) = .empty;
    defer {
        for (trace.items) |t| gpa.free(t);
        trace.deinit(gpa);
    }

    var found: ?i32 = null;
    var d: i32 = 0;
    search: while (d <= d_max) : (d += 1) {
        // Only diagonals -d-1 … d+1 matter to round d.
        const lo: usize = @intCast(off - d - 1);
        const hi: usize = @intCast(off + d + 2);
        const copy = try gpa.dupe(i32, v[lo..hi]);
        trace.append(gpa, copy) catch |err| {
            gpa.free(copy);
            return err;
        };
        var k: i32 = -d;
        while (k <= d) : (k += 2) {
            const down = k == -d or (k != d and v[@intCast(off + k - 1)] < v[@intCast(off + k + 1)]);
            var x: i32 = if (down) v[@intCast(off + k + 1)] else v[@intCast(off + k - 1)] + 1;
            var y: i32 = x - k;
            while (x < n and y < m and a[@intCast(x)] == b[@intCast(y)]) {
                x += 1;
                y += 1;
            }
            v[@intCast(off + k)] = x;
            if (x >= n and y >= m) {
                found = d;
                break :search;
            }
        }
    }
    var dd = found orelse return false;

    var x: i32 = n;
    var y: i32 = m;
    while (dd > 0) : (dd -= 1) {
        const t = trace.items[@intCast(dd)];
        // t[0] is diagonal -dd-1.
        const base: i32 = dd + 1;
        const k = x - y;
        const down = k == -dd or (k != dd and t[@intCast(base + k - 1)] < t[@intCast(base + k + 1)]);
        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = t[@intCast(base + prev_k)];
        const prev_y = prev_x - prev_k;
        if (down) new[@intCast(prev_y)] = true else gone[@intCast(prev_x)] = true;
        x = prev_x;
        y = prev_y;
    }
    return true;
}

/// Where two versions of a line differ: the bytes of each between what
/// they share at the start and at the end.
pub const Span = struct { a_from: u32, a_to: u32, b_from: u32, b_to: u32 };

/// The changed middle of a changed line, cut on character boundaries.
/// Null when the two share nothing worth pointing out (the whole line is
/// the change) or are the same.
pub fn changedSpan(a: []const u8, b: []const u8) ?Span {
    const shortest = @min(a.len, b.len);
    var head: usize = 0;
    while (head < shortest and a[head] == b[head]) head += 1;
    while (head > 0 and head < a.len and (a[head] & 0xC0) == 0x80) head -= 1;
    while (head > 0 and head < b.len and (b[head] & 0xC0) == 0x80) head -= 1;
    var tail: usize = 0;
    while (tail < shortest - head and a[a.len - 1 - tail] == b[b.len - 1 - tail]) tail += 1;
    while (tail > 0 and (a[a.len - tail] & 0xC0) == 0x80) tail -= 1;
    if (a.len == b.len and head == a.len) return null;
    // Indentation alone is not common ground.
    if (std.mem.trim(u8, a[0..head], " \t").len == 0 and std.mem.trim(u8, a[a.len - tail ..], " \t").len == 0) return null;
    return .{ .a_from = @intCast(head), .a_to = @intCast(a.len - tail), .b_from = @intCast(head), .b_to = @intCast(b.len - tail) };
}

// ── tests ───────────────────────────────────────────────────────────────
fn expectRows(a_text: []const u8, b_text: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const a = try splitLines(gpa, a_text);
    defer gpa.free(a);
    const b = try splitLines(gpa, b_text);
    defer gpa.free(b);
    const got = try rows(gpa, a, b);
    defer gpa.free(got);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var seen_left: u32 = 0;
    var seen_right: u32 = 0;
    for (got) |r| {
        // Every line of both sides shows once, in order.
        if (r.left != 0) {
            try std.testing.expectEqual(seen_left + 1, r.left);
            seen_left = r.left;
        }
        if (r.right != 0) {
            try std.testing.expectEqual(seen_right + 1, r.right);
            seen_right = r.right;
        }
        try out.append(gpa, switch (r.kind) {
            .same => '=',
            .changed => '~',
            .removed => '-',
            .added => '+',
        });
        switch (r.kind) {
            .same => try std.testing.expectEqualStrings(a[r.left - 1], b[r.right - 1]),
            .changed => try std.testing.expect(r.left != 0 and r.right != 0),
            .removed => try std.testing.expect(r.left != 0 and r.right == 0),
            .added => try std.testing.expect(r.left == 0 and r.right != 0),
        }
    }
    try std.testing.expectEqual(a.len, seen_left);
    try std.testing.expectEqual(b.len, seen_right);
    try std.testing.expectEqualStrings(want, out.items);
}

test "diff: lines split with either terminator, no phantom last line" {
    const gpa = std.testing.allocator;
    const l = try splitLines(gpa, "a\r\nb\n\nc");
    defer gpa.free(l);
    try std.testing.expectEqual(@as(usize, 4), l.len);
    try std.testing.expectEqualStrings("a", l[0]);
    try std.testing.expectEqualStrings("", l[2]);
    try std.testing.expectEqualStrings("c", l[3]);
    const none = try splitLines(gpa, "");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const one = try splitLines(gpa, "x\n");
    defer gpa.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
}

test "diff: rows pair changes and leave blanks for one-sided lines" {
    try expectRows("a\nb\nc\n", "a\nb\nc\n", "===");
    try expectRows("", "a\nb\n", "++");
    try expectRows("a\nb\n", "", "--");
    try expectRows("a\nb\nc\n", "a\nB\nc\n", "=~=");
    try expectRows("a\nb\nc\n", "a\nc\n", "=-=");
    try expectRows("a\nc\n", "a\nb\nc\n", "=+=");
    // Two lines become three: two pairs and one addition.
    try expectRows("a\nx\ny\nz\n", "a\n1\n2\n3\nz\n", "=~~+=");
    // Changes apart from each other, in the middle of common text.
    try expectRows("1\n2\n3\n4\n5\n6\n", "1\ntwo\n3\n4\n6\n7\n", "=~==-=+");
    try expectRows("a\nb\na\nb\n", "b\na\nb\na\n", "-===+");
}

test "diff: texts too far apart are shown as replaced" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try a.appendSlice(gpa, "start\n");
    try b.appendSlice(gpa, "start\n");
    for (0..max_distance) |k| {
        var buf: [32]u8 = undefined;
        try a.appendSlice(gpa, try std.fmt.bufPrint(&buf, "old {d}\n", .{k}));
        try b.appendSlice(gpa, try std.fmt.bufPrint(&buf, "new {d}\n", .{k}));
    }
    try a.appendSlice(gpa, "end\n");
    try b.appendSlice(gpa, "end\n");
    const al = try splitLines(gpa, a.items);
    defer gpa.free(al);
    const bl = try splitLines(gpa, b.items);
    defer gpa.free(bl);
    const got = try rows(gpa, al, bl);
    defer gpa.free(got);
    try std.testing.expectEqual(max_distance + 2, got.len);
    try std.testing.expectEqual(Kind.same, got[0].kind);
    try std.testing.expectEqual(Kind.changed, got[1].kind);
    try std.testing.expectEqual(Kind.changed, got[max_distance].kind);
    try std.testing.expectEqual(Kind.same, got[max_distance + 1].kind);
}

test "diff: the changed middle of a line" {
    const s = changedSpan("    const a = 1;", "    const a = 22;").?;
    try std.testing.expectEqualStrings("1", "    const a = 1;"[s.a_from..s.a_to]);
    try std.testing.expectEqualStrings("22", "    const a = 22;"[s.b_from..s.b_to]);
    // An insertion: nothing goes on the old side.
    const ins = changedSpan("foo(a)", "foo(a, b)").?;
    try std.testing.expectEqual(ins.a_from, ins.a_to);
    try std.testing.expectEqualStrings(", b", "foo(a, b)"[ins.b_from..ins.b_to]);
    // Nothing in common but the indentation, or nothing different.
    try std.testing.expect(changedSpan("  abc", "  xyz") == null);
    try std.testing.expect(changedSpan("same", "same") == null);
    // Cut between characters, not inside one.
    const u = changedSpan("say é!", "say è!").?;
    try std.testing.expectEqualStrings("é", "say é!"[u.a_from..u.a_to]);
    try std.testing.expectEqualStrings("è", "say è!"[u.b_from..u.b_to]);
}

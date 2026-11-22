//! The commit graph: which column each commit sits in and which strokes
//! cross its row. Commits come newest first, as `git log --topo-order`
//! lists them (a child always before its parents), one `push` each; the
//! state carries over, so a second page of the log carries the graph on.
//!
//! A *lane* is a column waiting for one commit: the parent a commit above
//! pointed at. A commit takes the first lane waiting for it (or a free
//! one, when nothing above points at it: a branch tip). Other lanes
//! waiting for the same commit end in it; its first parent carries its
//! lane on, and every other parent takes the lane already waiting for it
//! or opens a new one. When the first parent is already waited for by a
//! lane further right, that lane moves over into the commit's own, so the
//! line of first parents keeps to the left.
const std = @import("std");

/// Columns beyond this share the last one: a drawing limit, not a git one.
pub const max_lanes = 64;
const Mask = u64;

/// What to draw in one commit's row. Columns count from 0 at the left.
pub const Row = struct {
    /// The commit's own column.
    col: u8,
    /// A stroke comes down into the node from the row above.
    from_top: bool,
    /// A stroke leaves the node straight down, to its first parent.
    to_bottom: bool,
    /// Columns whose stroke crosses the row untouched.
    through: Mask = 0,
    /// Columns whose stroke comes from above and bends into the node:
    /// branches that started from this commit.
    join: Mask = 0,
    /// Columns a stroke leaves the node for, bending down into them: a
    /// merged parent, or a first parent a lane to the left already waits for.
    fork: Mask = 0,
    /// Columns whose stroke comes from above and moves over into the
    /// commit's column by the bottom of the row: they waited for the
    /// commit's first parent, which its own lane now carries.
    shift: Mask = 0,
    /// How many columns the row spans.
    width: u8,

    pub fn has(mask: Mask, col: usize) bool {
        return col < max_lanes and (mask >> @intCast(col)) & 1 == 1;
    }
};

fn bit(col: usize) Mask {
    return @as(Mask, 1) << @intCast(@min(col, max_lanes - 1));
}

pub const Lanes = struct {
    gpa: std.mem.Allocator,
    /// The commit each column waits for; null when the column is free.
    /// The hashes are the caller's and must outlive the next `push`.
    waiting: std.ArrayList(?[]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Lanes {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Lanes) void {
        self.waiting.deinit(self.gpa);
    }

    pub fn clear(self: *Lanes) void {
        self.waiting.clearRetainingCapacity();
    }

    fn find(self: *const Lanes, hash: []const u8) ?usize {
        for (self.waiting.items, 0..) |w, i| {
            if (w) |h| if (sameCommit(h, hash)) return i;
        }
        return null;
    }

    /// A free column, the leftmost that `taken` does not rule out.
    fn free(self: *Lanes, taken: Mask) !usize {
        for (self.waiting.items, 0..) |w, i| {
            if (w == null and !Row.has(taken, i)) return i;
        }
        if (self.waiting.items.len >= max_lanes) return max_lanes - 1;
        try self.waiting.append(self.gpa, null);
        return self.waiting.items.len - 1;
    }

    /// Places the next commit and returns its row.
    pub fn push(self: *Lanes, hash: []const u8, parents: []const []const u8) !Row {
        var row: Row = .{ .col = 0, .from_top = false, .to_bottom = false, .width = 0 };
        const before = self.waiting.items.len;

        const own = self.find(hash);
        row.from_top = own != null;
        const col = own orelse try self.free(0);
        row.col = @intCast(col);

        // Every other lane waiting for this commit ends here.
        for (self.waiting.items, 0..) |w, i| {
            if (i == col) continue;
            const h = w orelse continue;
            if (sameCommit(h, hash)) {
                row.join |= bit(i);
                self.waiting.items[i] = null;
            } else {
                row.through |= bit(i);
            }
        }

        self.waiting.items[col] = null;
        for (parents, 0..) |p, n| {
            if (self.find(p)) |k| {
                if (n == 0 and k > col and k < max_lanes) {
                    // The lane to the right gives way: this one carries the parent.
                    self.waiting.items[k] = null;
                    self.waiting.items[col] = p;
                    row.through &= ~bit(k);
                    row.shift |= bit(k);
                    row.to_bottom = true;
                } else {
                    // Already waited for: bend into that lane.
                    row.fork |= bit(k);
                }
            } else if (n == 0) {
                self.waiting.items[col] = p;
                row.to_bottom = true;
            } else {
                // A lane that just ended here is not reused in the same
                // row: its stroke would look like it carried on.
                const k = try self.free(row.join | bit(col));
                self.waiting.items[k] = p;
                row.fork |= bit(k);
            }
        }

        // Free columns at the right end are given back.
        while (self.waiting.items.len > 0 and self.waiting.items[self.waiting.items.len - 1] == null) {
            self.waiting.items.len -= 1;
        }
        row.width = @intCast(@min(max_lanes, @max(before, @max(self.waiting.items.len, col + 1))));
        return row;
    }
};

/// Hashes are compared by prefix: a parent may come abbreviated.
fn sameCommit(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    return n > 0 and std.mem.eql(u8, a[0..n], b[0..n]);
}

// ── tests ───────────────────────────────────────────────────────────────
test "a branch merged back: the design's graph" {
    const gpa = std.testing.allocator;
    var lanes = Lanes.init(gpa);
    defer lanes.deinit();

    // The merge: its own lane carries on, the merged branch opens lane 1.
    var r = try lanes.push("a1f", &.{ "9b0", "7e9" });
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expect(!r.from_top and r.to_bottom);
    try std.testing.expectEqual(@as(Mask, 0b10), r.fork);
    try std.testing.expectEqual(@as(u8, 2), r.width);

    // Two commits on the branch, the main lane passing by.
    r = try lanes.push("7e9", &.{"4c8"});
    try std.testing.expectEqual(@as(u8, 1), r.col);
    try std.testing.expect(r.from_top and r.to_bottom);
    try std.testing.expectEqual(@as(Mask, 0b01), r.through);
    r = try lanes.push("4c8", &.{"2d5"});
    try std.testing.expectEqual(@as(u8, 1), r.col);

    // One on main, the branch passing by.
    r = try lanes.push("9b0", &.{"c7b"});
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expectEqual(@as(Mask, 0b10), r.through);

    // The branch's first commit: its parent is the one main waits for, so
    // it bends down into lane 0 and its own lane ends.
    r = try lanes.push("2d5", &.{"c7b"});
    try std.testing.expectEqual(@as(u8, 1), r.col);
    try std.testing.expect(r.from_top and !r.to_bottom);
    try std.testing.expectEqual(@as(Mask, 0b01), r.fork);
    try std.testing.expectEqual(@as(Mask, 0b01), r.through);

    // Back to one lane.
    r = try lanes.push("c7b", &.{"f0e"});
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expectEqual(@as(Mask, 0), r.through | r.join | r.fork);
    try std.testing.expectEqual(@as(u8, 1), r.width);
    r = try lanes.push("f0e", &.{});
    try std.testing.expect(r.from_top and !r.to_bottom);
    try std.testing.expectEqual(@as(u8, 1), r.width);
    try std.testing.expectEqual(@as(usize, 0), lanes.waiting.items.len);
}

test "the first-parent line keeps to the left" {
    const gpa = std.testing.allocator;
    var lanes = Lanes.init(gpa);
    defer lanes.deinit();
    // git may list a merged branch's commits before the mainline's.
    _ = try lanes.push("merge", &.{ "main1", "topic2" });
    _ = try lanes.push("topic2", &.{"topic1"});
    var r = try lanes.push("topic1", &.{"base"});
    try std.testing.expectEqual(@as(u8, 1), r.col);
    try std.testing.expect(r.to_bottom);
    // The mainline's commit takes `base` over from the branch's lane.
    r = try lanes.push("main1", &.{"base"});
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expect(r.to_bottom);
    try std.testing.expectEqual(@as(Mask, 0b10), r.shift);
    try std.testing.expectEqual(@as(Mask, 0), r.through | r.fork);
    r = try lanes.push("base", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expect(r.from_top);
    try std.testing.expectEqual(@as(u8, 1), r.width);
}

test "two tips over one commit, and a tip nothing points at" {
    const gpa = std.testing.allocator;
    var lanes = Lanes.init(gpa);
    defer lanes.deinit();
    _ = try lanes.push("t1", &.{"base"});
    // A second tip: nothing above waits for it, so it takes a free lane,
    // and the parent it shares is already waited for.
    var r = try lanes.push("t2", &.{"base"});
    try std.testing.expectEqual(@as(u8, 1), r.col);
    try std.testing.expect(!r.from_top and !r.to_bottom);
    try std.testing.expectEqual(@as(Mask, 0b01), r.fork);
    r = try lanes.push("base", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.col);
    try std.testing.expectEqual(@as(Mask, 0), r.join);
}

test "abbreviated parents match full hashes" {
    const gpa = std.testing.allocator;
    var lanes = Lanes.init(gpa);
    defer lanes.deinit();
    _ = try lanes.push("aaaaaaaaaaaa", &.{"bbbbbbb"});
    const r = try lanes.push("bbbbbbbbbbbb", &.{});
    try std.testing.expect(r.from_top);
    try std.testing.expectEqual(@as(u8, 0), r.col);
}

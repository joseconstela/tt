//! The pane tree of a tab group: how its tabs are split across the content
//! area, VS Code style. A *pane* holds an ordered list of tabs and shows one
//! of them; a *split* lays its children side by side (horizontal) or one
//! above the other (vertical) by weight. Splitting a pane on a side either
//! adds a sibling to a split running that way or wraps the pane in a new
//! one; removing a pane collapses single-child splits and merges nested
//! splits that run the same way, so the tree never holds a useless level.
//!
//! Panes are owned individually (`owned`) and the tree's leaves refer to
//! them by id, so a `*Pane` stays valid through any reshuffle until that
//! pane is removed. Nothing here draws: `geometry` turns the tree into
//! rectangles and the UI does the rest.
const std = @import("std");
const Tab = @import("tab.zig").Tab;
pub const Rect = @import("../gfx/draw.zig").Rect;

pub const Dir = enum { horizontal, vertical };

/// Where a new pane goes, relative to an existing one.
pub const Side = enum {
    left,
    right,
    top,
    bottom,

    pub fn dir(s: Side) Dir {
        return switch (s) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
        };
    }

    /// True when the new pane comes after the existing one in reading order.
    pub fn after(s: Side) bool {
        return s == .right or s == .bottom;
    }
};

/// More would be unusable; it also bounds the per-frame scratch arrays.
pub const max_panes = 16;

pub const Pane = struct {
    id: u32,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,

    pub fn current(self: *const Pane) ?Tab {
        if (self.active >= self.tabs.items.len) return null;
        return self.tabs.items[self.active];
    }

    pub fn indexOf(self: *const Pane, uid: u32) ?usize {
        for (self.tabs.items, 0..) |t, i| {
            if (t.uid == uid) return i;
        }
        return null;
    }
};

pub const Split = struct {
    dir: Dir,
    children: std.ArrayList(*Node) = .empty,
    /// One per child, any positive scale; normalised when laid out.
    weights: std.ArrayList(f32) = .empty,

    fn indexOf(self: *const Split, child: *const Node) usize {
        for (self.children.items, 0..) |c, i| {
            if (c == child) return i;
        }
        unreachable;
    }

    fn sum(self: *const Split) f32 {
        var s: f32 = 0;
        for (self.weights.items) |w| s += w;
        return if (s > 0) s else 1;
    }
};

pub const Node = union(enum) {
    leaf: u32,
    split: Split,
};

/// Leaves in reading order (left to right, top to bottom).
pub const PaneList = struct {
    items: [max_panes]*Pane = undefined,
    len: usize = 0,

    pub fn slice(self: *const PaneList) []const *Pane {
        return self.items[0..self.len];
    }
};

pub const PaneRect = struct { pane: *Pane, rect: Rect };

/// The gap between two children of a split, where the user can resize them.
pub const Divider = struct {
    split: *Split,
    /// The divider sits after child `index`.
    index: usize,
    rect: Rect,
    dir: Dir,
    /// Size of the split along its axis, minus the gaps: what the weights share.
    span: f32,
};

pub const Geometry = struct {
    panes: [max_panes]PaneRect = undefined,
    n: usize = 0,
    dividers: [max_panes]Divider = undefined,
    nd: usize = 0,
};

pub const Layout = struct {
    gpa: std.mem.Allocator,
    root: *Node,
    owned: std.ArrayList(*Pane) = .empty,
    /// The pane keyboard input goes to; always one of `owned`.
    focused: u32,

    pub fn init(gpa: std.mem.Allocator, first_id: u32) !Layout {
        const root = try gpa.create(Node);
        errdefer gpa.destroy(root);
        var self: Layout = .{ .gpa = gpa, .root = root, .focused = first_id };
        const p = try self.newPane(first_id);
        root.* = .{ .leaf = p.id };
        return self;
    }

    /// Frees the tree and the panes. The tabs must have been destroyed or
    /// moved out first: a pane does not own what its tabs point at.
    pub fn deinit(self: *Layout) void {
        self.freeNode(self.root);
        for (self.owned.items) |p| {
            p.tabs.deinit(self.gpa);
            self.gpa.destroy(p);
        }
        self.owned.deinit(self.gpa);
    }

    fn newPane(self: *Layout, id: u32) !*Pane {
        const p = try self.gpa.create(Pane);
        errdefer self.gpa.destroy(p);
        p.* = .{ .id = id };
        try self.owned.append(self.gpa, p);
        return p;
    }

    fn freeNode(self: *Layout, n: *Node) void {
        switch (n.*) {
            .leaf => {},
            .split => |*s| {
                for (s.children.items) |c| self.freeNode(c);
                s.children.deinit(self.gpa);
                s.weights.deinit(self.gpa);
            },
        }
        self.gpa.destroy(n);
    }

    // ── lookups ─────────────────────────────────────────────────────────
    pub fn find(self: *const Layout, id: u32) ?*Pane {
        for (self.owned.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    pub fn count(self: *const Layout) usize {
        return self.owned.items.len;
    }

    /// The focused pane; falls back to the first one so there always is one.
    pub fn focusedPane(self: *Layout) *Pane {
        if (self.find(self.focused)) |p| return p;
        const first = self.panes().items[0];
        self.focused = first.id;
        return first;
    }

    pub fn focus(self: *Layout, id: u32) bool {
        if (self.find(id) == null) return false;
        self.focused = id;
        return true;
    }

    /// The pane holding a tab.
    pub fn paneOf(self: *const Layout, uid: u32) ?*Pane {
        for (self.owned.items) |p| {
            if (p.indexOf(uid) != null) return p;
        }
        return null;
    }

    pub fn tabCount(self: *const Layout) usize {
        var n: usize = 0;
        for (self.owned.items) |p| n += p.tabs.items.len;
        return n;
    }

    pub fn panes(self: *const Layout) PaneList {
        var out: PaneList = .{};
        self.collect(self.root, &out);
        return out;
    }

    fn collect(self: *const Layout, n: *const Node, out: *PaneList) void {
        switch (n.*) {
            .leaf => |id| if (self.find(id)) |p| {
                if (out.len < max_panes) {
                    out.items[out.len] = p;
                    out.len += 1;
                }
            },
            .split => |*s| for (s.children.items) |c| self.collect(c, out),
        }
    }

    /// The pane `delta` steps from the focused one in reading order, wrapping.
    pub fn neighbour(self: *Layout, delta: isize) *Pane {
        const list = self.panes();
        const cur = self.focusedPane();
        var i: usize = 0;
        while (i < list.len and list.items[i] != cur) i += 1;
        const n: isize = @intCast(list.len);
        return list.items[@intCast(@mod(@as(isize, @intCast(i)) + delta, n))];
    }

    fn findLeaf(n: *Node, id: u32) ?*Node {
        switch (n.*) {
            .leaf => |lid| return if (lid == id) n else null,
            .split => |*s| {
                for (s.children.items) |c| {
                    if (findLeaf(c, id)) |found| return found;
                }
                return null;
            },
        }
    }

    fn parentOf(n: *Node, child: *const Node) ?*Node {
        switch (n.*) {
            .leaf => return null,
            .split => |*s| {
                for (s.children.items) |c| {
                    if (c == child) return n;
                    if (parentOf(c, child)) |found| return found;
                }
                return null;
            },
        }
    }

    fn firstLeaf(n: *const Node) u32 {
        return switch (n.*) {
            .leaf => |id| id,
            .split => |*s| firstLeaf(s.children.items[0]),
        };
    }

    // ── structure ───────────────────────────────────────────────────────
    /// A new, empty pane on `side` of pane `id`, which becomes the focused
    /// one. Fails when the tree is full or the pane does not exist.
    pub fn split(self: *Layout, id: u32, side: Side, new_id: u32) !*Pane {
        const leaf = findLeaf(self.root, id) orelse return error.NoSuchPane;
        if (self.owned.items.len >= max_panes) return error.TooManyPanes;
        const dir = side.dir();
        const fresh = try self.gpa.create(Node);
        errdefer self.gpa.destroy(fresh);
        fresh.* = .{ .leaf = new_id };

        if (parentOf(self.root, leaf)) |parent| {
            if (parent.split.dir == dir) {
                // A sibling in the split already running this way; the two
                // share what the old pane had.
                const s = &parent.split;
                const i = s.indexOf(leaf);
                const at = if (side.after()) i + 1 else i;
                try s.children.ensureUnusedCapacity(self.gpa, 1);
                try s.weights.ensureUnusedCapacity(self.gpa, 1);
                const p = try self.newPane(new_id);
                const half = s.weights.items[i] / 2;
                s.children.insertAssumeCapacity(at, fresh);
                s.weights.insertAssumeCapacity(at, half);
                s.weights.items[if (side.after()) i else i + 1] = half;
                self.focused = p.id;
                return p;
            }
        }
        // Wrap the leaf: it moves down into a fresh node and its own node
        // becomes the split, so whoever points at that node is unaffected.
        const moved = try self.gpa.create(Node);
        errdefer self.gpa.destroy(moved);
        var s: Split = .{ .dir = dir };
        errdefer s.children.deinit(self.gpa);
        errdefer s.weights.deinit(self.gpa);
        try s.children.ensureTotalCapacity(self.gpa, 2);
        try s.weights.ensureTotalCapacity(self.gpa, 2);
        const p = try self.newPane(new_id);
        moved.* = leaf.*;
        if (side.after()) {
            s.children.appendAssumeCapacity(moved);
            s.children.appendAssumeCapacity(fresh);
        } else {
            s.children.appendAssumeCapacity(fresh);
            s.children.appendAssumeCapacity(moved);
        }
        s.weights.appendAssumeCapacity(0.5);
        s.weights.appendAssumeCapacity(0.5);
        leaf.* = .{ .split = s };
        self.focused = p.id;
        return p;
    }

    /// Drops a pane (whose tabs must be gone) and gives its space to a
    /// neighbour, which takes the focus if the pane had it. The last pane
    /// stays: false.
    pub fn remove(self: *Layout, id: u32) bool {
        const leaf = findLeaf(self.root, id) orelse return false;
        const parent = parentOf(self.root, leaf) orelse return false;
        const s = &parent.split;
        const i = s.indexOf(leaf);
        _ = s.children.orderedRemove(i);
        const w = s.weights.orderedRemove(i);
        const j = if (i < s.children.items.len) i else i - 1;
        s.weights.items[j] += w;
        const heir = firstLeaf(s.children.items[j]);
        self.gpa.destroy(leaf);

        if (s.children.items.len == 1) {
            // A split of one is just its child: pull it up a level.
            const only = s.children.items[0];
            s.children.deinit(self.gpa);
            s.weights.deinit(self.gpa);
            parent.* = only.*;
            self.gpa.destroy(only);
            self.mergeUp(parent);
        }

        var k: usize = 0;
        while (k < self.owned.items.len and self.owned.items[k].id != id) k += 1;
        if (k < self.owned.items.len) {
            const p = self.owned.orderedRemove(k);
            p.tabs.deinit(self.gpa);
            self.gpa.destroy(p);
        }
        if (self.focused == id) self.focused = heir;
        return true;
    }

    /// A split nested in another running the same way is flattened into it,
    /// keeping the space it had. Best effort: leaves the nesting if memory is short.
    fn mergeUp(self: *Layout, node: *Node) void {
        if (node.* != .split) return;
        const gp = parentOf(self.root, node) orelse return;
        if (gp.split.dir != node.split.dir) return;
        const gs = &gp.split;
        const ns = &node.split;
        const extra = ns.children.items.len;
        gs.children.ensureUnusedCapacity(self.gpa, extra) catch return;
        gs.weights.ensureUnusedCapacity(self.gpa, extra) catch return;
        const i = gs.indexOf(node);
        const w = gs.weights.items[i];
        const inner_sum = ns.sum();
        _ = gs.children.orderedRemove(i);
        _ = gs.weights.orderedRemove(i);
        for (ns.children.items, ns.weights.items, 0..) |c, cw, k| {
            gs.children.insertAssumeCapacity(i + k, c);
            gs.weights.insertAssumeCapacity(i + k, w * cw / inner_sum);
        }
        ns.children.deinit(self.gpa);
        ns.weights.deinit(self.gpa);
        self.gpa.destroy(node);
    }

    /// Moves the divider after child `index` by `delta` (a fraction of the
    /// split's span); neither neighbour goes under `min` (also a fraction).
    pub fn resize(s: *Split, index: usize, delta: f32, min: f32) void {
        if (index + 1 >= s.weights.items.len) return;
        const total = s.sum();
        const a = s.weights.items[index] / total;
        const b = s.weights.items[index + 1] / total;
        const pair = a + b;
        if (pair <= 2 * min) return;
        const na = std.math.clamp(a + delta, min, pair - min);
        s.weights.items[index] = na * total;
        s.weights.items[index + 1] = (pair - na) * total;
    }

    // ── persistence ─────────────────────────────────────────────────────
    /// The tree as text, leaves in reading order: `_` is a pane, a split is
    /// its direction and each child's share and subtree, so a pane beside a
    /// stacked pair is `h(0.3000:_,0.7000:v(0.5000:_,0.5000:_))`. `decode`
    /// rebuilds it; the workspace file keeps one per group.
    pub fn encode(self: *const Layout, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try encodeNode(self.root, gpa, out);
    }

    fn encodeNode(n: *const Node, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (n.*) {
            .leaf => try out.append(gpa, '_'),
            .split => |*s| {
                try out.append(gpa, if (s.dir == .horizontal) 'h' else 'v');
                try out.append(gpa, '(');
                const total = s.sum();
                for (s.children.items, s.weights.items, 0..) |c, w, i| {
                    if (i > 0) try out.append(gpa, ',');
                    try out.print(gpa, "{d:.4}:", .{w / total});
                    try encodeNode(c, gpa, out);
                }
                try out.append(gpa, ')');
            },
        }
    }

    /// Rebuilds the tree `encode` wrote in a layout that still has its
    /// first, single pane (a fresh group). That pane becomes the first leaf
    /// and keeps its tabs; the others are new, with ids taken from
    /// `next_id`. Malformed text stops the rebuild where it is, leaving a
    /// valid tree (whatever was built so far) — the caller places tabs by
    /// pane index and clamps.
    pub fn decode(self: *Layout, text: []const u8, next_id: *u32) !void {
        if (self.root.* != .leaf) return error.NotASinglePane;
        var pos: usize = 0;
        try self.build(text, &pos, self.root.leaf, next_id);
        if (pos != text.len) return error.Malformed;
    }

    fn build(self: *Layout, text: []const u8, pos: *usize, leaf_id: u32, next_id: *u32) !void {
        if (pos.* >= text.len) return error.Malformed;
        switch (text[pos.*]) {
            '_' => {
                pos.* += 1;
                return;
            },
            'h', 'v' => {},
            else => return error.Malformed,
        }
        const dir: Dir = if (text[pos.*] == 'h') .horizontal else .vertical;
        pos.* += 1;
        if (pos.* >= text.len or text[pos.*] != '(') return error.Malformed;
        pos.* += 1;
        // First every child as a leaf beside the previous one — they are
        // siblings while their subtrees are still single leaves — then the
        // shares, then each subtree in its own leaf.
        var leaf_ids: [max_panes]u32 = undefined;
        var weights: [max_panes]f32 = undefined;
        var starts: [max_panes]usize = undefined;
        var n: usize = 0;
        while (true) {
            const colon = std.mem.indexOfScalarPos(u8, text, pos.*, ':') orelse return error.Malformed;
            const w = std.fmt.parseFloat(f32, text[pos.*..colon]) catch return error.Malformed;
            if (n >= max_panes) return error.TooManyPanes;
            weights[n] = if (w > 0 and w < 1e9) w else 0.01;
            pos.* = colon + 1;
            starts[n] = pos.*;
            try skipTree(text, pos);
            if (n == 0) {
                leaf_ids[0] = leaf_id;
            } else {
                const p = try self.split(leaf_ids[n - 1], if (dir == .horizontal) .right else .bottom, next_id.*);
                next_id.* += 1;
                leaf_ids[n] = p.id;
            }
            n += 1;
            if (pos.* >= text.len) return error.Malformed;
            if (text[pos.*] == ',') {
                pos.* += 1;
                continue;
            }
            if (text[pos.*] == ')') {
                pos.* += 1;
                break;
            }
            return error.Malformed;
        }
        if (n > 1) self.setWeights(leaf_ids[0], weights[0..n]);
        for (0..n) |k| {
            var sub = starts[k];
            try self.build(text, &sub, leaf_ids[k], next_id);
        }
    }

    /// Moves past one subtree of the text.
    fn skipTree(text: []const u8, pos: *usize) !void {
        if (pos.* >= text.len) return error.Malformed;
        if (text[pos.*] == '_') {
            pos.* += 1;
            return;
        }
        var depth: usize = 0;
        while (pos.* < text.len) : (pos.* += 1) {
            switch (text[pos.*]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        pos.* += 1;
                        return;
                    }
                },
                ',', ':' => if (depth == 0) return error.Malformed,
                else => {},
            }
        }
        return error.Malformed;
    }

    /// The shares of the split holding pane `id`, when the count matches.
    fn setWeights(self: *Layout, id: u32, weights: []const f32) void {
        const leaf = findLeaf(self.root, id) orelse return;
        const parent = parentOf(self.root, leaf) orelse return;
        if (parent.split.weights.items.len != weights.len) return;
        @memcpy(parent.split.weights.items, weights);
    }

    /// Feeds the tree's shape, shares and pane ids to a hash, so a change
    /// to the layout shows up as a change of the workspace.
    pub fn hash(self: *const Layout, h: *std.hash.Wyhash) void {
        hashNode(self.root, h);
    }

    fn hashNode(n: *const Node, h: *std.hash.Wyhash) void {
        switch (n.*) {
            .leaf => |id| h.update(std.mem.asBytes(&id)),
            .split => |*s| {
                h.update(&[_]u8{ '(', @intFromEnum(s.dir) });
                for (s.children.items, s.weights.items) |c, w| {
                    h.update(std.mem.asBytes(&w));
                    hashNode(c, h);
                }
                h.update(")");
            },
        }
    }

    // ── geometry ────────────────────────────────────────────────────────
    /// Rectangles for every pane and divider, `gap` points between siblings.
    pub fn geometry(self: *const Layout, rect: Rect, gap: f32) Geometry {
        var out: Geometry = .{};
        self.place(self.root, rect, gap, &out);
        return out;
    }

    fn place(self: *const Layout, n: *Node, rect: Rect, gap: f32, out: *Geometry) void {
        switch (n.*) {
            .leaf => |id| if (self.find(id)) |p| {
                if (out.n < max_panes) {
                    out.panes[out.n] = .{ .pane = p, .rect = rect };
                    out.n += 1;
                }
            },
            .split => |*s| {
                const count_f: f32 = @floatFromInt(s.children.items.len);
                const horizontal = s.dir == .horizontal;
                const span = @max(0, (if (horizontal) rect.w else rect.h) - gap * (count_f - 1));
                const total = s.sum();
                var pos: f32 = if (horizontal) rect.x else rect.y;
                for (s.children.items, s.weights.items, 0..) |c, w, i| {
                    const size = span * w / total;
                    const child: Rect = if (horizontal)
                        .{ .x = pos, .y = rect.y, .w = size, .h = rect.h }
                    else
                        .{ .x = rect.x, .y = pos, .w = rect.w, .h = size };
                    self.place(c, child, gap, out);
                    pos += size;
                    if (i + 1 < s.children.items.len and out.nd < max_panes) {
                        out.dividers[out.nd] = .{
                            .split = s,
                            .index = i,
                            .dir = s.dir,
                            .span = span,
                            .rect = if (horizontal)
                                .{ .x = pos, .y = rect.y, .w = gap, .h = rect.h }
                            else
                                .{ .x = rect.x, .y = pos, .w = rect.w, .h = gap },
                        };
                        out.nd += 1;
                    }
                    pos += gap;
                }
            },
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
fn ids(list: PaneList) [max_panes]u32 {
    var out: [max_panes]u32 = [_]u32{0} ** max_panes;
    for (list.slice(), 0..) |p, i| out[i] = p.id;
    return out;
}

test "layout: splitting, geometry, removal collapses and merges" {
    const gpa = std.testing.allocator;
    var l = try Layout.init(gpa, 1);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.count());
    try std.testing.expect(!l.remove(1)); // the last pane stays

    // 1 | 2, then 2 over 3: H[1, V[2, 3]].
    const p2 = try l.split(1, .right, 2);
    try std.testing.expectEqual(@as(u32, 2), l.focused);
    _ = try l.split(p2.id, .bottom, 3);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, ids(l.panes())[0..3]);
    var geo = l.geometry(.{ .x = 0, .y = 0, .w = 801, .h = 601 }, 1);
    try std.testing.expectEqual(@as(usize, 3), geo.n);
    try std.testing.expectEqual(@as(usize, 2), geo.nd);
    try std.testing.expectApproxEqAbs(@as(f32, 400), geo.panes[0].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 401), geo.panes[1].rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), geo.panes[1].rect.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 301), geo.panes[2].rect.y, 0.01);
    try std.testing.expectEqual(Dir.horizontal, geo.dividers[0].dir);
    try std.testing.expectEqual(Dir.vertical, geo.dividers[1].dir);

    // A pane left of 1 joins the horizontal split as a sibling: H[4, 1, V[2, 3]].
    _ = try l.split(1, .left, 4);
    try std.testing.expectEqualSlices(u32, &.{ 4, 1, 2, 3 }, ids(l.panes())[0..4]);
    try std.testing.expectEqual(@as(usize, 3), l.root.split.children.items.len);
    geo = l.geometry(.{ .x = 0, .y = 0, .w = 802, .h = 600 }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 200), geo.panes[0].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), geo.panes[1].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), geo.panes[2].rect.w, 0.01);

    // Dragging the first divider: 4 grows, 1 shrinks, the rest is untouched.
    Layout.resize(geo.dividers[0].split, 0, 0.1, 0.05);
    geo = l.geometry(.{ .x = 0, .y = 0, .w = 802, .h = 600 }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 280), geo.panes[0].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), geo.panes[1].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), geo.panes[2].rect.w, 0.01);

    // Splitting 3 to the right wraps it: H[4, 1, V[2, H[3, 5]]]. Removing 2
    // collapses V to H[3, 5], which merges into the root: H[4, 1, 3, 5].
    _ = try l.split(3, .right, 5);
    try std.testing.expectEqualSlices(u32, &.{ 4, 1, 2, 3, 5 }, ids(l.panes())[0..5]);
    l.focused = 2;
    try std.testing.expect(l.remove(2));
    try std.testing.expectEqualSlices(u32, &.{ 4, 1, 3, 5 }, ids(l.panes())[0..4]);
    try std.testing.expectEqual(@as(usize, 4), l.root.split.children.items.len);
    try std.testing.expectEqual(@as(u32, 3), l.focused); // the heir of 2's space
    try std.testing.expect(l.find(2) == null);
    geo = l.geometry(.{ .x = 0, .y = 0, .w = 803, .h = 600 }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 200), geo.panes[2].rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), geo.panes[3].rect.w, 0.01);

    // Down to one pane again: the root is a leaf.
    try std.testing.expect(l.remove(4));
    try std.testing.expect(l.remove(5));
    try std.testing.expect(l.remove(1));
    try std.testing.expect(l.root.* == .leaf);
    try std.testing.expectEqual(@as(u32, 3), l.focused);
    try std.testing.expectEqual(@as(usize, 1), l.count());
    try std.testing.expect(!l.remove(3));

    // Neighbours wrap in reading order.
    _ = try l.split(3, .bottom, 6);
    _ = try l.split(3, .right, 7);
    try std.testing.expectEqualSlices(u32, &.{ 3, 7, 6 }, ids(l.panes())[0..3]);
    l.focused = 6;
    try std.testing.expectEqual(@as(u32, 3), l.neighbour(1).id);
    try std.testing.expectEqual(@as(u32, 7), l.neighbour(-1).id);
}

test "layout: encode and decode round-trip the tree, shares and reading order" {
    const gpa = std.testing.allocator;
    var l = try Layout.init(gpa, 1);
    defer l.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);

    try l.encode(gpa, &text);
    try std.testing.expectEqualStrings("_", text.items);

    // H[1, V[H[2, 5], H[3, 4]]] — splitting 2 to the right wraps it, since
    // its parent runs the other way — with the root divider moved.
    _ = try l.split(1, .right, 2);
    _ = try l.split(2, .bottom, 3);
    _ = try l.split(3, .right, 4);
    _ = try l.split(2, .right, 5);
    var geo = l.geometry(.{ .x = 0, .y = 0, .w = 1000, .h = 1000 }, 0);
    Layout.resize(geo.dividers[0].split, 0, 0.1, 0.05);
    text.clearRetainingCapacity();
    try l.encode(gpa, &text);
    try std.testing.expectEqualStrings("h(0.6000:_,0.4000:v(0.5000:h(0.5000:_,0.5000:_),0.5000:h(0.5000:_,0.5000:_)))", text.items);
    var h1 = std.hash.Wyhash.init(0);
    l.hash(&h1);

    // A fresh single-pane layout rebuilds it: same text, same rectangles,
    // five panes in reading order with the first one kept.
    var l2 = try Layout.init(gpa, 10);
    defer l2.deinit();
    var next: u32 = 11;
    try l2.decode(text.items, &next);
    try std.testing.expectEqual(@as(u32, 15), next);
    try std.testing.expectEqual(@as(usize, 5), l2.count());
    try std.testing.expectEqual(@as(u32, 10), l2.panes().items[0].id);
    var text2: std.ArrayList(u8) = .empty;
    defer text2.deinit(gpa);
    try l2.encode(gpa, &text2);
    try std.testing.expectEqualStrings(text.items, text2.items);
    geo = l.geometry(.{ .x = 0, .y = 0, .w = 1000, .h = 800 }, 1);
    const geo2 = l2.geometry(.{ .x = 0, .y = 0, .w = 1000, .h = 800 }, 1);
    try std.testing.expectEqual(geo.n, geo2.n);
    for (geo.panes[0..geo.n], geo2.panes[0..geo2.n]) |a, b| {
        try std.testing.expectApproxEqAbs(a.rect.x, b.rect.x, 0.01);
        try std.testing.expectApproxEqAbs(a.rect.y, b.rect.y, 0.01);
        try std.testing.expectApproxEqAbs(a.rect.w, b.rect.w, 0.01);
        try std.testing.expectApproxEqAbs(a.rect.h, b.rect.h, 0.01);
    }
    // Different pane ids hash differently, the same shape and ids the same.
    var h2 = std.hash.Wyhash.init(0);
    l2.hash(&h2);
    try std.testing.expect(h1.final() != h2.final());

    // Only a single pane can be rebuilt into; malformed text fails but
    // leaves a usable tree.
    try std.testing.expectError(error.NotASinglePane, l2.decode("_", &next));
    var l3 = try Layout.init(gpa, 20);
    defer l3.deinit();
    try std.testing.expectError(error.Malformed, l3.decode("h(0.5:_,0.5:v(0.5:_", &next));
    try std.testing.expect(l3.count() >= 1);
    try std.testing.expectEqual(l3.count(), l3.panes().len);
    var l4 = try Layout.init(gpa, 30);
    defer l4.deinit();
    try std.testing.expectError(error.Malformed, l4.decode("x", &next));
    try std.testing.expectEqual(@as(usize, 1), l4.count());
}

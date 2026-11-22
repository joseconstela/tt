//! The files tree as data: a folder's entries (`Node`), each folder
//! holding its own once it was unfolded. Everything here is pure: the
//! order rows show in, finding a node, and what a fresh listing of a
//! folder keeps of the one it replaces (`adopt`). Listing itself is
//! `client/listing.zig`'s job.
const std = @import("std");

pub const Node = struct {
    name: []u8,
    is_dir: bool,
    /// A folder showing its entries.
    expanded: bool = false,
    /// A folder whose entries were listed at least once.
    loaded: bool = false,
    children: std.ArrayList(Node) = .empty,
};

/// Folders first, then case-insensitive by name (so dotfiles lead).
pub fn lessThan(_: void, a: Node, b: Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const n = @min(a.name.len, b.name.len);
    for (a.name[0..n], b.name[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.name.len < b.name.len;
}

pub fn sort(nodes: []Node) void {
    std.mem.sort(Node, nodes, {}, lessThan);
}

pub fn find(nodes: *std.ArrayList(Node), name: []const u8) ?*Node {
    for (nodes.items) |*n| {
        if (std.mem.eql(u8, n.name, name)) return n;
    }
    return null;
}

/// The node `rel` names, a path relative to the folder `nodes` lists
/// ("src/ui/files.zig"); null when a part is missing or not yet listed.
pub fn at(nodes: *std.ArrayList(Node), rel: []const u8) ?*Node {
    var level = nodes;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |part| {
        const n = find(level, part) orelse return null;
        if (it.peek() == null) return n;
        level = &n.children;
    }
    return null;
}

/// Frees the nodes and leaves the list empty.
pub fn free(gpa: std.mem.Allocator, list: *std.ArrayList(Node)) void {
    for (list.items) |*n| {
        free(gpa, &n.children);
        gpa.free(n.name);
    }
    list.deinit(gpa);
    list.* = .empty;
}

/// `fresh` (a new listing, sorted) takes the place of `old`: a folder
/// that is still there keeps whether it was unfolded and the entries it
/// held, everything else of `old` is freed. True when the two listings
/// differ. `fresh` is left empty.
pub fn adopt(gpa: std.mem.Allocator, old: *std.ArrayList(Node), fresh: *std.ArrayList(Node)) bool {
    var changed = fresh.items.len != old.items.len;
    for (fresh.items, 0..) |*n, i| {
        if (!changed and (old.items[i].is_dir != n.is_dir or !std.mem.eql(u8, old.items[i].name, n.name))) changed = true;
        if (!n.is_dir) continue;
        for (old.items) |*was| {
            if (!was.is_dir or !std.mem.eql(u8, was.name, n.name)) continue;
            n.expanded = was.expanded;
            n.loaded = was.loaded;
            n.children = was.children;
            was.children = .empty;
            break;
        }
    }
    free(gpa, old);
    old.* = fresh.*;
    fresh.* = .empty;
    return changed;
}

/// The folder holding `path` ("/" for a top-level path, "." for a bare name).
pub fn parentPath(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    return if (slash == 0) "/" else trimmed[0..slash];
}

// ── tests ───────────────────────────────────────────────────────────────
const testing = std.testing;

fn add(list: *std.ArrayList(Node), name: []const u8, is_dir: bool) !*Node {
    const owned = try testing.allocator.dupe(u8, name);
    errdefer testing.allocator.free(owned);
    try list.append(testing.allocator, .{ .name = owned, .is_dir = is_dir });
    return &list.items[list.items.len - 1];
}

test "tree: folders lead, then names without regard to case" {
    var list: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &list);
    _ = try add(&list, "zeta.txt", false);
    _ = try add(&list, "Build.zig", false);
    _ = try add(&list, "src", true);
    _ = try add(&list, ".git", true);
    _ = try add(&list, "apple", false);
    sort(list.items);
    const want = [_][]const u8{ ".git", "src", "apple", "Build.zig", "zeta.txt" };
    for (want, list.items) |w, n| try testing.expectEqualStrings(w, n.name);
}

test "tree: at walks the unfolded folders" {
    var list: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &list);
    const src = try add(&list, "src", true);
    const ui = try add(&src.children, "ui", true);
    _ = try add(&ui.children, "files.zig", false);
    try testing.expectEqualStrings("files.zig", at(&list, "src/ui/files.zig").?.name);
    try testing.expectEqualStrings("ui", at(&list, "src/ui").?.name);
    try testing.expect(at(&list, "src/gfx") == null);
    try testing.expect(at(&list, "") == null);
}

test "tree: a fresh listing keeps what was unfolded" {
    var old: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &old);
    const src = try add(&old, "src", true);
    src.expanded = true;
    src.loaded = true;
    _ = try add(&src.children, "main.zig", false);
    _ = try add(&old, "gone.txt", false);

    var fresh: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &fresh);
    _ = try add(&fresh, "src", true);
    _ = try add(&fresh, "new.txt", false);

    try testing.expect(adopt(testing.allocator, &old, &fresh));
    try testing.expectEqual(@as(usize, 0), fresh.items.len);
    try testing.expectEqual(@as(usize, 2), old.items.len);
    try testing.expect(old.items[0].expanded and old.items[0].loaded);
    try testing.expectEqualStrings("main.zig", old.items[0].children.items[0].name);
    try testing.expectEqualStrings("new.txt", old.items[1].name);

    // The same listing again changes nothing.
    var again: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &again);
    _ = try add(&again, "src", true);
    _ = try add(&again, "new.txt", false);
    try testing.expect(!adopt(testing.allocator, &old, &again));
    try testing.expect(old.items[0].expanded);
}

test "tree: a file that became a folder starts folded" {
    var old: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &old);
    _ = try add(&old, "docs", false);
    var fresh: std.ArrayList(Node) = .empty;
    defer free(testing.allocator, &fresh);
    _ = try add(&fresh, "docs", true);
    try testing.expect(adopt(testing.allocator, &old, &fresh));
    try testing.expect(old.items[0].is_dir and !old.items[0].expanded);
}

test "tree: parentPath" {
    try testing.expectEqualStrings("/a/b", parentPath("/a/b/c.txt"));
    try testing.expectEqualStrings("/a", parentPath("/a/b/"));
    try testing.expectEqualStrings("/", parentPath("/a"));
    try testing.expectEqualStrings(".", parentPath("name"));
}

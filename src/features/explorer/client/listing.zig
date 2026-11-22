//! Reads folders into the tree, through the `Dirs` it is handed: `load`
//! lists one folder, `reload` lists it again and every folder unfolded
//! below it, keeping what was unfolded (`model/tree.zig`'s `adopt`).
const std = @import("std");
const hosts = @import("../hosts.zig");
const tree = @import("../model/tree.zig");

const Node = tree.Node;

const Collector = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Node),

    fn add(ptr: *anyopaque, e: hosts.Entry) void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        const name = self.gpa.dupe(u8, e.name) catch return;
        self.out.append(self.gpa, .{ .name = name, .is_dir = e.is_dir }) catch self.gpa.free(name);
    }
};

/// Appends the entries of `dir` to `out`, in the order rows show in.
pub fn load(gpa: std.mem.Allocator, dirs: hosts.Dirs, dir: []const u8, out: *std.ArrayList(Node)) void {
    var collector: Collector = .{ .gpa = gpa, .out = out };
    dirs.list(gpa, dir, .{ .ptr = &collector, .addFn = Collector.add });
    tree.sort(out.items);
}

/// Lists `dir` again into `children`, and the folders unfolded below it.
/// True when anything on show changed.
pub fn reload(gpa: std.mem.Allocator, dirs: hosts.Dirs, dir: []const u8, children: *std.ArrayList(Node)) bool {
    var fresh: std.ArrayList(Node) = .empty;
    load(gpa, dirs, dir, &fresh);
    var changed = tree.adopt(gpa, children, &fresh);
    for (children.items) |*n| {
        if (!n.is_dir or !n.expanded) continue;
        const sub = std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), n.name }) catch continue;
        defer gpa.free(sub);
        if (reload(gpa, dirs, sub, &n.children)) changed = true;
    }
    return changed;
}

// ── tests ───────────────────────────────────────────────────────────────
const testing = std.testing;

/// A disk that answers from a table: "dir" → its entries, a trailing
/// slash marking a folder.
const FakeDirs = struct {
    folders: []const Folder,
    /// Every folder asked for, in order, separated by spaces.
    asked: std.ArrayList(u8) = .empty,

    const Folder = struct { dir: []const u8, entries: []const []const u8 };

    fn list(ptr: *anyopaque, gpa: std.mem.Allocator, dir: []const u8, sink: hosts.Sink) void {
        const self: *FakeDirs = @ptrCast(@alignCast(ptr));
        if (self.asked.items.len > 0) self.asked.append(gpa, ' ') catch {};
        self.asked.appendSlice(gpa, dir) catch {};
        for (self.folders) |f| {
            if (!std.mem.eql(u8, f.dir, dir)) continue;
            for (f.entries) |e| {
                const is_dir = std.mem.endsWith(u8, e, "/");
                sink.add(.{ .name = std.mem.trimEnd(u8, e, "/"), .is_dir = is_dir });
            }
        }
    }

    fn dirs(self: *FakeDirs) hosts.Dirs {
        return .{ .ptr = self, .listFn = list };
    }
};

test "listing: a folder comes back sorted" {
    var fake: FakeDirs = .{ .folders = &.{.{ .dir = "/p", .entries = &.{ "b.txt", "src/", "A.md" } }} };
    defer fake.asked.deinit(testing.allocator);
    var nodes: std.ArrayList(Node) = .empty;
    defer tree.free(testing.allocator, &nodes);
    load(testing.allocator, fake.dirs(), "/p", &nodes);
    try testing.expectEqual(@as(usize, 3), nodes.items.len);
    try testing.expectEqualStrings("src", nodes.items[0].name);
    try testing.expect(nodes.items[0].is_dir);
    try testing.expectEqualStrings("A.md", nodes.items[1].name);
    try testing.expectEqualStrings("b.txt", nodes.items[2].name);
}

test "listing: reload reads only what is unfolded, and keeps it unfolded" {
    var before: FakeDirs = .{ .folders = &.{
        .{ .dir = "/p", .entries = &.{ "src/", "docs/", "a.txt" } },
        .{ .dir = "/p/src", .entries = &.{"main.zig"} },
    } };
    defer before.asked.deinit(testing.allocator);
    var nodes: std.ArrayList(Node) = .empty;
    defer tree.free(testing.allocator, &nodes);
    load(testing.allocator, before.dirs(), "/p", &nodes);
    const src = tree.find(&nodes, "src").?;
    src.expanded = true;
    src.loaded = true;
    load(testing.allocator, before.dirs(), "/p/src", &src.children);

    // Nothing moved on disk: nothing changed, and the folded `docs` was not read.
    before.asked.clearRetainingCapacity();
    try testing.expect(!reload(testing.allocator, before.dirs(), "/p", &nodes));
    try testing.expectEqualStrings("/p /p/src", before.asked.items);

    // A file appears inside the unfolded folder.
    var after: FakeDirs = .{ .folders = &.{
        .{ .dir = "/p", .entries = &.{ "src/", "docs/", "a.txt" } },
        .{ .dir = "/p/src", .entries = &.{ "main.zig", "app.zig" } },
    } };
    defer after.asked.deinit(testing.allocator);
    try testing.expect(reload(testing.allocator, after.dirs(), "/p", &nodes));
    const again = tree.find(&nodes, "src").?;
    try testing.expect(again.expanded);
    try testing.expectEqual(@as(usize, 2), again.children.items.len);
    try testing.expectEqualStrings("app.zig", again.children.items[0].name);
}

test "listing: a folder that went away takes its rows with it" {
    var fake: FakeDirs = .{ .folders = &.{.{ .dir = "/p", .entries = &.{ "src/", "a.txt" } }} };
    defer fake.asked.deinit(testing.allocator);
    var nodes: std.ArrayList(Node) = .empty;
    defer tree.free(testing.allocator, &nodes);
    load(testing.allocator, fake.dirs(), "/p", &nodes);
    var empty: FakeDirs = .{ .folders = &.{} };
    defer empty.asked.deinit(testing.allocator);
    try testing.expect(reload(testing.allocator, empty.dirs(), "/p", &nodes));
    try testing.expectEqual(@as(usize, 0), nodes.items.len);
}

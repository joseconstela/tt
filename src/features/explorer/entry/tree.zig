//! The files tree as the files panel mounts it: the folder on show and
//! what is unfolded under it (`model/tree.zig`), read from disk
//! (`client/listing.zig`) and drawn (`view/tree.zig`). Each frame the
//! view is shown the tree; what it asked for is then served here — a
//! folder is folded or unfolded and, the first time, listed — or handed
//! to the app as a `Result` (open a file, pin it, its menu, a drag, a
//! drop). The folders on show are read again every couple of seconds
//! (`tick`), so `touch`, `git checkout` … show up.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const sys = @import("../../../sys.zig");
const paths = @import("../../../paths.zig");
const repo = @import("../../repo/repo.zig");
const FileKind = @import("../../../ui/overlay.zig").FileKind;
const hosts = @import("../hosts.zig");
const listing = @import("../client/listing.zig");
const model = @import("../model/tree.zig");
const view = @import("../view/tree.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const refresh_every: f64 = 2.0;

/// A secondary click: what the row is and where the menu should open;
/// the path is `menuPath()`.
pub const FileMenu = struct { kind: FileKind, x: f32, y: f32 };

/// What a draw hands the app. Paths are absolute and valid this frame.
pub const Result = struct {
    open_file: ?[]const u8 = null,
    pin_file: ?[]const u8 = null,
    /// A right-click on a row, the header or the blank space: the app
    /// opens the files menu for `menuPath()`.
    file_menu: ?FileMenu = null,
    /// A press on a row travelled: the app starts dragging this path.
    drag_file: ?[]const u8 = null,
    /// The dragged path was let go over a folder of the tree: the folder
    /// it moves into.
    drop_into: ?[]const u8 = null,
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    dirs: hosts.Dirs,
    root: std.ArrayList(u8) = .empty,
    children: std.ArrayList(model.Node) = .empty,
    /// Path of the highlighted file.
    selected: std.ArrayList(u8) = .empty,
    /// The path the open menu (or the box it led to) is about.
    menu_path: std.ArrayList(u8) = .empty,
    view: view.View,
    last_refresh: f64 = 0,

    pub fn init(gpa: std.mem.Allocator) Tree {
        return initWith(gpa, hosts.system());
    }

    pub fn initWith(gpa: std.mem.Allocator, dirs: hosts.Dirs) Tree {
        return .{ .gpa = gpa, .dirs = dirs, .view = view.View.init(gpa) };
    }

    pub fn deinit(self: *Tree) void {
        model.free(self.gpa, &self.children);
        self.root.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        self.menu_path.deinit(self.gpa);
        self.view.deinit();
    }

    /// The folder the tree shows ("" before the first `setRoot`).
    pub fn rootPath(self: *const Tree) []const u8 {
        return self.root.items;
    }

    /// The path the last menu was asked for (a file, a folder, or the
    /// folder on show).
    pub fn menuPath(self: *const Tree) []const u8 {
        return self.menu_path.items;
    }

    /// Points the tree at `dir` (no-op if it already is).
    pub fn setRoot(self: *Tree, dir: []const u8, now: f64) void {
        if (std.mem.eql(u8, self.root.items, dir)) return;
        self.root.clearRetainingCapacity();
        self.root.appendSlice(self.gpa, dir) catch return;
        model.free(self.gpa, &self.children);
        self.view.reset();
        listing.load(self.gpa, self.dirs, dir, &self.children);
        self.last_refresh = now;
    }

    /// Lists the folders on show again, right now (after a rename, a
    /// move, a new file …).
    pub fn refresh(self: *Tree, now: f64) void {
        if (self.root.items.len == 0) return;
        _ = listing.reload(self.gpa, self.dirs, self.root.items, &self.children);
        self.last_refresh = now;
    }

    /// Re-reads the folders on show now and then. True if anything changed.
    pub fn tick(self: *Tree, now: f64) bool {
        if (self.root.items.len == 0 or now - self.last_refresh < refresh_every) return false;
        self.last_refresh = now;
        return listing.reload(self.gpa, self.dirs, self.root.items, &self.children);
    }

    /// Unfolds the folders down to `path` and, for a file, highlights it.
    pub fn reveal(self: *Tree, path: []const u8) void {
        const root = self.root.items;
        if (root.len == 0 or !paths.isUnder(root, path)) return;
        const rel = paths.relativeTo(root, path);
        if (rel.len == 0) return;
        var dir: std.ArrayList(u8) = .empty;
        defer dir.deinit(self.gpa);
        dir.appendSlice(self.gpa, std.mem.trimEnd(u8, root, "/")) catch return;
        var nodes = &self.children;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |part| {
            const n = model.find(nodes, part) orelse return;
            if (it.peek() == null) {
                if (!n.is_dir) self.select(path);
                return;
            }
            if (!n.is_dir) return;
            dir.append(self.gpa, '/') catch return;
            dir.appendSlice(self.gpa, part) catch return;
            n.expanded = true;
            n.loaded = true;
            _ = listing.reload(self.gpa, self.dirs, dir.items, &n.children);
            nodes = &n.children;
        }
    }

    /// `drag` is the path being dragged from here, if any: folders under
    /// the pointer offer to take it, and rows do not click meanwhile.
    pub fn draw(self: *Tree, ui: *Ui, rect: Rect, git: *const repo.Panel, can_pin: bool, drag: ?[]const u8) Result {
        var title_buf: [512]u8 = undefined;
        const intent = self.view.draw(ui, rect, .{
            .root = self.root.items,
            .title = sys.abbreviateHome(self.root.items, &title_buf),
            .nodes = self.children.items,
            .selected = self.selected.items,
            .git = git,
            .can_pin = can_pin,
            .drag = drag,
        });
        var res: Result = .{};
        switch (intent) {
            .none => {},
            .open => |path| {
                self.select(path);
                res.open_file = path;
            },
            .pin => |path| res.pin_file = path,
            .toggle => |path| {
                self.toggle(path);
                // The frame just drawn shows the folder as it was.
                ui.wants_frame = true;
            },
            .drag => |path| res.drag_file = path,
            .drop => |path| res.drop_into = path,
            .menu => |m| {
                self.menu_path.clearRetainingCapacity();
                self.menu_path.appendSlice(self.gpa, m.path) catch return res;
                res.file_menu = .{ .kind = m.kind, .x = m.x, .y = m.y };
            },
        }
        return res;
    }

    fn select(self: *Tree, path: []const u8) void {
        self.selected.clearRetainingCapacity();
        self.selected.appendSlice(self.gpa, path) catch {};
    }

    /// Folds or unfolds the folder at `path`, listing it the first time.
    fn toggle(self: *Tree, path: []const u8) void {
        const n = model.at(&self.children, paths.relativeTo(self.root.items, path)) orelse return;
        if (!n.is_dir) return;
        n.expanded = !n.expanded;
        if (n.expanded and !n.loaded) {
            n.loaded = true;
            listing.load(self.gpa, self.dirs, path, &n.children);
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
const testing = std.testing;

/// A disk with one project in it: /p holds src/ (main.zig, ui/ with
/// files.zig) and a.txt.
const FakeDisk = struct {
    lists: u32 = 0,

    fn list(ptr: *anyopaque, _: std.mem.Allocator, dir: []const u8, sink: hosts.Sink) void {
        const self: *FakeDisk = @ptrCast(@alignCast(ptr));
        self.lists += 1;
        if (std.mem.eql(u8, dir, "/p")) {
            sink.add(.{ .name = "a.txt", .is_dir = false });
            sink.add(.{ .name = "src", .is_dir = true });
        } else if (std.mem.eql(u8, dir, "/p/src")) {
            sink.add(.{ .name = "main.zig", .is_dir = false });
            sink.add(.{ .name = "ui", .is_dir = true });
        } else if (std.mem.eql(u8, dir, "/p/src/ui")) {
            sink.add(.{ .name = "files.zig", .is_dir = false });
        }
    }

    fn dirs(self: *FakeDisk) hosts.Dirs {
        return .{ .ptr = self, .listFn = list };
    }
};

test "explorer: unfolding lists a folder once, folding keeps what it held" {
    var disk: FakeDisk = .{};
    var tree = Tree.initWith(testing.allocator, disk.dirs());
    defer tree.deinit();
    tree.setRoot("/p", 0);
    try testing.expectEqual(@as(usize, 2), tree.children.items.len);
    try testing.expectEqualStrings("src", tree.children.items[0].name);
    try testing.expectEqual(@as(u32, 1), disk.lists);

    tree.toggle("/p/src");
    const src = &tree.children.items[0];
    try testing.expect(src.expanded);
    try testing.expectEqual(@as(usize, 2), src.children.items.len);
    try testing.expectEqualStrings("ui", src.children.items[0].name);
    try testing.expectEqual(@as(u32, 2), disk.lists);

    tree.toggle("/p/src");
    try testing.expect(!src.expanded);
    tree.toggle("/p/src");
    try testing.expect(src.expanded);
    try testing.expectEqual(@as(u32, 2), disk.lists);

    // A file does not fold.
    tree.toggle("/p/a.txt");
    try testing.expectEqual(@as(u32, 2), disk.lists);
}

test "explorer: reveal unfolds down to a file and highlights it" {
    var disk: FakeDisk = .{};
    var tree = Tree.initWith(testing.allocator, disk.dirs());
    defer tree.deinit();
    tree.setRoot("/p", 0);
    tree.reveal("/p/src/ui/files.zig");
    const src = &tree.children.items[0];
    try testing.expect(src.expanded);
    const ui = model.find(&src.children, "ui").?;
    try testing.expect(ui.expanded);
    try testing.expectEqualStrings("files.zig", ui.children.items[0].name);
    try testing.expectEqualStrings("/p/src/ui/files.zig", tree.selected.items);

    // Outside the folder on show: nothing happens.
    tree.reveal("/elsewhere/x");
    try testing.expectEqualStrings("/p/src/ui/files.zig", tree.selected.items);
}

test "explorer: the folders on show are read again every couple of seconds" {
    var disk: FakeDisk = .{};
    var tree = Tree.initWith(testing.allocator, disk.dirs());
    defer tree.deinit();
    tree.setRoot("/p", 10);
    try testing.expect(!tree.tick(11));
    try testing.expectEqual(@as(u32, 1), disk.lists);
    try testing.expect(!tree.tick(12.5));
    try testing.expectEqual(@as(u32, 2), disk.lists);
}

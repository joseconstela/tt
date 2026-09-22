//! Projects: folders the user works in, each with *resources* — files worth
//! keeping at hand and groups of shells that start inside the project — and
//! the *default project*, the one for what belongs to no folder, which has
//! resources of its own too. The sidebar shows them; this file owns the
//! model and its persistence (tab-separated lines in ~/.conch_projects).
//! Every project and every resource owns a set of tabs, kept by the tab
//! manager under its id (the default project's under id 0). Ids are handed
//! out afresh on every load, so nothing on disk refers to them.
const std = @import("std");
const sys = @import("sys.zig");

pub const Kind = enum { file, shells };

pub const Resource = struct {
    id: u32,
    kind: Kind,
    /// Display name: a file's path relative to the project, a group's title.
    name: []u8,
    /// File: absolute path. Shells: the directory the group's shells start in.
    path: []u8,
    /// The user's icon (a name for `ui/icon_spec.zig`); null for the kind's own.
    icon: ?[]u8 = null,

    /// Where a new shell opened from this resource starts.
    pub fn dir(self: *const Resource) []const u8 {
        return if (self.kind == .file) sys.dirname(self.path) else self.path;
    }
};

pub const Project = struct {
    id: u32,
    name: []u8,
    /// Absolute directory, no trailing slash.
    root: []u8,
    /// The user's icon (a name for `ui/icon_spec.zig`), null for none.
    icon: ?[]u8 = null,
    open: bool = true,
    resources: std.ArrayList(Resource) = .empty,

    /// True if `path` is the root or lives below it.
    pub fn contains(self: *const Project, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, self.root)) return false;
        return path.len == self.root.len or path[self.root.len] == '/' or std.mem.eql(u8, self.root, "/");
    }
};

/// A resource and the project it belongs to (null: the default project's).
pub const Found = struct { project: ?*Project, resource: *Resource };

pub const Projects = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Project) = .empty,
    /// Shared by projects and resources, so any id names one thing. Ids
    /// start at 1: 0 is the tab manager's default group, the default
    /// project's own tabs.
    next_id: u32 = 1,
    file_path: ?[]u8 = null,
    /// The default project's icon and resources.
    default_icon: ?[]u8 = null,
    default_resources: std.ArrayList(Resource) = .empty,

    pub fn init(gpa: std.mem.Allocator) Projects {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Projects) void {
        for (self.items.items) |*p| self.freeProject(p);
        self.items.deinit(self.gpa);
        for (self.default_resources.items) |*r| self.freeResource(r);
        self.default_resources.deinit(self.gpa);
        if (self.file_path) |p| self.gpa.free(p);
        if (self.default_icon) |i| self.gpa.free(i);
    }

    fn freeProject(self: *Projects, p: *Project) void {
        for (p.resources.items) |*r| self.freeResource(r);
        p.resources.deinit(self.gpa);
        self.gpa.free(p.name);
        self.gpa.free(p.root);
        if (p.icon) |i| self.gpa.free(i);
    }

    fn freeResource(self: *Projects, r: *Resource) void {
        self.gpa.free(r.name);
        self.gpa.free(r.path);
        if (r.icon) |i| self.gpa.free(i);
    }

    /// Sets (or with null clears) one of the icon slots: a project's, a
    /// resource's or `default_icon`.
    pub fn setIcon(self: *Projects, slot: *?[]u8, name: ?[]const u8) !void {
        const copy: ?[]u8 = if (name) |n| try self.gpa.dupe(u8, n) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }

    // ── persistence ─────────────────────────────────────────────────────
    pub fn load(self: *Projects) void {
        self.file_path = std.fmt.allocPrint(self.gpa, "{s}/.conch_projects", .{sys.home()}) catch null;
        const path = self.file_path orelse return;
        const data = sys.readFileTail(self.gpa, path, 1 << 20) catch return;
        defer self.gpa.free(data);
        self.parse(data);
    }

    pub fn save(self: *Projects) void {
        const path = self.file_path orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.serialize(&out) catch return;
        sys.writeFile(self.gpa, path, out.items, false) catch {};
    }

    /// Format, one entry per line; resources belong to the project above
    /// them, or to the default project before any project:
    ///   project <tab> 0|1 (open) <tab> name <tab> root
    ///   file    <tab> name <tab> path
    ///   shells  <tab> name <tab> directory
    ///   icon    <tab> name          the icon of the entry above (of the
    ///                               default project at the very top)
    pub fn parse(self: *Projects, data: []const u8) void {
        // null: the default project.
        var current: ?usize = null;
        // Which entry an `icon` line belongs to: the last resource listed
        // under the current project, else the project itself.
        var last_resource: ?usize = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            var f = std.mem.splitScalar(u8, line, '\t');
            const tag = f.next() orelse continue;
            if (std.mem.eql(u8, tag, "project")) {
                const open = f.next() orelse continue;
                const name = f.next() orelse continue;
                const root = f.rest();
                if (root.len == 0) continue;
                const p = self.addNamed(name, root) catch continue;
                p.open = !std.mem.eql(u8, open, "0");
                current = self.indexOf(p.id);
                last_resource = null;
            } else if (std.mem.eql(u8, tag, "file") or std.mem.eql(u8, tag, "shells")) {
                const name = f.next() orelse continue;
                const path = f.rest();
                if (path.len == 0) continue;
                const kind: Kind = if (std.mem.eql(u8, tag, "file")) .file else .shells;
                const list = self.resourcesOf(self.projectAt(current));
                _ = self.addResource(list, kind, name, path) catch continue;
                last_resource = list.items.len - 1;
            } else if (std.mem.eql(u8, tag, "icon")) {
                const name = f.rest();
                if (name.len == 0) continue;
                const p = self.projectAt(current);
                const slot: *?[]u8 = if (last_resource) |ri|
                    &self.resourcesOf(p).items[ri].icon
                else if (p) |proj| &proj.icon else &self.default_icon;
                self.setIcon(slot, name) catch continue;
            }
        }
    }

    fn projectAt(self: *Projects, index: ?usize) ?*Project {
        const i = index orelse return null;
        return &self.items.items[i];
    }

    pub fn serialize(self: *const Projects, out: *std.ArrayList(u8)) !void {
        try self.writeIcon(out, self.default_icon);
        try self.writeResources(out, self.default_resources.items);
        for (self.items.items) |p| {
            try out.appendSlice(self.gpa, "project\t");
            try out.appendSlice(self.gpa, if (p.open) "1\t" else "0\t");
            try out.appendSlice(self.gpa, p.name);
            try out.append(self.gpa, '\t');
            try out.appendSlice(self.gpa, p.root);
            try out.append(self.gpa, '\n');
            try self.writeIcon(out, p.icon);
            try self.writeResources(out, p.resources.items);
        }
    }

    fn writeResources(self: *const Projects, out: *std.ArrayList(u8), list: []const Resource) !void {
        for (list) |r| {
            try out.appendSlice(self.gpa, if (r.kind == .file) "file\t" else "shells\t");
            try out.appendSlice(self.gpa, r.name);
            try out.append(self.gpa, '\t');
            try out.appendSlice(self.gpa, r.path);
            try out.append(self.gpa, '\n');
            try self.writeIcon(out, r.icon);
        }
    }

    fn writeIcon(self: *const Projects, out: *std.ArrayList(u8), icon: ?[]const u8) !void {
        const name = icon orelse return;
        try out.appendSlice(self.gpa, "icon\t");
        try out.appendSlice(self.gpa, name);
        try out.append(self.gpa, '\n');
    }

    // ── projects ────────────────────────────────────────────────────────
    /// Adds a folder as a project (named after it). Returns the existing
    /// project if the folder is already one.
    pub fn add(self: *Projects, root: []const u8) !*Project {
        return self.addNamed(sys.basename(root), root);
    }

    fn addNamed(self: *Projects, name: []const u8, root_in: []const u8) !*Project {
        const root = if (root_in.len > 1) std.mem.trimEnd(u8, root_in, "/") else root_in;
        if (self.byRoot(root)) |p| return p;
        const name_copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(name_copy);
        const root_copy = try self.gpa.dupe(u8, root);
        errdefer self.gpa.free(root_copy);
        try self.items.append(self.gpa, .{ .id = self.next_id, .name = name_copy, .root = root_copy });
        self.next_id += 1;
        return &self.items.items[self.items.items.len - 1];
    }

    pub fn byRoot(self: *Projects, root: []const u8) ?*Project {
        for (self.items.items) |*p| {
            if (std.mem.eql(u8, p.root, root)) return p;
        }
        return null;
    }

    pub fn find(self: *Projects, id: u32) ?*Project {
        const i = self.indexOf(id) orelse return null;
        return &self.items.items[i];
    }

    pub fn indexOf(self: *const Projects, id: u32) ?usize {
        for (self.items.items, 0..) |p, i| {
            if (p.id == id) return i;
        }
        return null;
    }

    pub fn remove(self: *Projects, id: u32) void {
        const i = self.indexOf(id) orelse return;
        self.freeProject(&self.items.items[i]);
        _ = self.items.orderedRemove(i);
    }

    /// Gives a project a name of the user's choosing; a blank name goes
    /// back to the folder's own name (as a tab's blank name restores its
    /// automatic title).
    pub fn renameProject(self: *Projects, p: *Project, name: []const u8) !void {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        const copy = try self.gpa.dupe(u8, if (trimmed.len == 0) sys.basename(p.root) else trimmed);
        self.gpa.free(p.name);
        p.name = copy;
    }

    /// The project whose root is the closest ancestor of `path`.
    pub fn containing(self: *Projects, path: []const u8) ?*Project {
        var best: ?*Project = null;
        for (self.items.items) |*p| {
            if (!p.contains(path)) continue;
            if (best == null or p.root.len > best.?.root.len) best = p;
        }
        return best;
    }

    // ── resources ───────────────────────────────────────────────────────
    /// The resources of `p`, or the default project's for null.
    pub fn resourcesOf(self: *Projects, p: ?*Project) *std.ArrayList(Resource) {
        return if (p) |proj| &proj.resources else &self.default_resources;
    }

    /// Adds a file to `p` (null: the default project), or returns the
    /// resource that already shows it.
    pub fn addFile(self: *Projects, p: ?*Project, path: []const u8) !*Resource {
        const list = self.resourcesOf(p);
        for (list.items) |*r| {
            if (r.kind == .file and std.mem.eql(u8, r.path, path)) return r;
        }
        // Named by its path inside the project, or just the file name.
        var name: []const u8 = sys.basename(path);
        if (p) |proj| {
            if (proj.contains(path) and path.len > proj.root.len + 1) name = path[proj.root.len + 1 ..];
        }
        return self.addResource(list, .file, name, path);
    }

    /// A new group of shells starting in `dir` under `p` (null: the default
    /// project): "Shells" for the project root, the folder's relative path
    /// otherwise (its name, for the default project), numbered when taken.
    pub fn addShells(self: *Projects, p: ?*Project, dir: []const u8) !*Resource {
        const list = self.resourcesOf(p);
        var base: []const u8 = sys.basename(dir);
        if (p) |proj| {
            if (std.mem.eql(u8, dir, proj.root)) {
                base = "Shells";
            } else if (proj.contains(dir) and dir.len > proj.root.len + 1) base = dir[proj.root.len + 1 ..];
        }
        if (base.len == 0 or std.mem.eql(u8, base, "/")) base = "Shells";
        var buf: [300]u8 = undefined;
        var name: []const u8 = base;
        var n: u32 = 2;
        while (resourceNamed(list, name) != null) : (n += 1) {
            name = std.fmt.bufPrint(&buf, "{s} {d}", .{ base, n }) catch base;
        }
        return self.addResource(list, .shells, name, dir);
    }

    fn resourceNamed(list: *std.ArrayList(Resource), name: []const u8) ?*Resource {
        for (list.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    fn addResource(self: *Projects, list: *std.ArrayList(Resource), kind: Kind, name: []const u8, path: []const u8) !*Resource {
        const name_copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(name_copy);
        const path_copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(path_copy);
        try list.append(self.gpa, .{ .id = self.next_id, .kind = kind, .name = name_copy, .path = path_copy });
        self.next_id += 1;
        return &list.items[list.items.len - 1];
    }

    pub fn removeResource(self: *Projects, p: ?*Project, id: u32) void {
        const list = self.resourcesOf(p);
        for (list.items, 0..) |*r, i| {
            if (r.id != id) continue;
            self.freeResource(r);
            _ = list.orderedRemove(i);
            return;
        }
    }

    /// A resource of any project (or the default project's) by id.
    pub fn findResource(self: *Projects, id: u32) ?Found {
        for (self.default_resources.items) |*r| {
            if (r.id == id) return .{ .project = null, .resource = r };
        }
        for (self.items.items) |*p| {
            for (p.resources.items) |*r| {
                if (r.id == id) return .{ .project = p, .resource = r };
            }
        }
        return null;
    }

    /// Gives a resource a name of the user's choosing: the sidebar label
    /// only, the file or folder keeps its name. A blank name is ignored.
    pub fn renameResource(self: *Projects, r: *Resource, name: []const u8) !void {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return;
        const copy = try self.gpa.dupe(u8, trimmed);
        self.gpa.free(r.name);
        r.name = copy;
    }
};

test "projects: add, dedupe, rename, resources" {
    var ps = Projects.init(std.testing.allocator);
    defer ps.deinit();
    const p = try ps.add("/Users/x/git/tt/");
    try std.testing.expectEqualStrings("tt", p.name);
    try std.testing.expectEqualStrings("/Users/x/git/tt", p.root);
    const again = try ps.add("/Users/x/git/tt");
    try std.testing.expectEqual(p.id, again.id);
    try std.testing.expectEqual(@as(usize, 1), ps.items.items.len);

    // Renaming a project: blank goes back to the folder's name.
    try ps.renameProject(p, " Terminal app ");
    try std.testing.expectEqualStrings("Terminal app", p.name);
    try ps.renameProject(p, "");
    try std.testing.expectEqualStrings("tt", p.name);

    const f1 = try ps.addFile(p, "/Users/x/git/tt/src/app.zig");
    try std.testing.expectEqualStrings("src/app.zig", f1.name);
    const f2 = try ps.addFile(p, "/etc/hosts");
    try std.testing.expectEqualStrings("hosts", f2.name);
    _ = try ps.addFile(p, "/etc/hosts");
    try std.testing.expectEqual(@as(usize, 2), p.resources.items.len);

    const g1 = try ps.addShells(p, "/Users/x/git/tt");
    try std.testing.expectEqualStrings("Shells", g1.name);
    const g2 = try ps.addShells(p, "/Users/x/git/tt");
    try std.testing.expectEqualStrings("Shells 2", g2.name);
    const g3 = try ps.addShells(p, "/Users/x/git/tt/frontend");
    try std.testing.expectEqualStrings("frontend", g3.name);
    try std.testing.expectEqualStrings("/Users/x/git/tt/frontend", g3.dir());
    // (f1 may have moved when the list grew: look it up again.)
    try std.testing.expectEqualStrings("/Users/x/git/tt/src", p.resources.items[0].dir());
    try std.testing.expect(ps.findResource(g3.id).?.resource.id == g3.id);
    try std.testing.expect(ps.findResource(g3.id).?.project.?.id == p.id);

    // Renaming a resource changes the label only; blanks are ignored.
    try ps.renameResource(&p.resources.items[2], "  Backend ");
    try std.testing.expectEqualStrings("Backend", p.resources.items[2].name);
    try ps.renameResource(&p.resources.items[2], "   ");
    try std.testing.expectEqualStrings("Backend", p.resources.items[2].name);
    try std.testing.expectEqualStrings("/Users/x/git/tt", p.resources.items[2].path);

    // The default project has resources of its own, named by the folder.
    // (Ids are taken right away: the list may move when it grows.)
    const d1 = (try ps.addShells(null, "/Users/x/notes")).id;
    try std.testing.expectEqualStrings("notes", ps.findResource(d1).?.resource.name);
    const d2 = (try ps.addShells(null, "/")).id;
    try std.testing.expectEqualStrings("Shells", ps.findResource(d2).?.resource.name);
    const d3 = (try ps.addFile(null, "/Users/x/todo.md")).id;
    try std.testing.expectEqualStrings("todo.md", ps.findResource(d3).?.resource.name);
    try std.testing.expect(ps.findResource(d1).?.project == null);
    ps.removeResource(null, d2);
    try std.testing.expectEqual(@as(usize, 2), ps.default_resources.items.len);
    try std.testing.expect(ps.findResource(d2) == null);
    try std.testing.expect(ps.findResource(d3) != null);

    try std.testing.expect(ps.containing("/Users/x/git/tt/src").?.id == p.id);
    try std.testing.expect(ps.containing("/Users/x/git/ttx") == null);
    const inner = try ps.add("/Users/x/git/tt/src");
    try std.testing.expect(ps.containing("/Users/x/git/tt/src/ui").?.id == inner.id);
}

test "projects: round trip through the file format, icons included" {
    var ps = Projects.init(std.testing.allocator);
    defer ps.deinit();
    try ps.setIcon(&ps.default_icon, "#E5484D");
    const d = try ps.addShells(null, "/Users/x/notes");
    try ps.setIcon(&d.icon, "notebook");
    const p = try ps.add("/tmp/demo");
    p.open = false;
    try ps.setIcon(&p.icon, "sparkle");
    try ps.setIcon(&p.icon, "cloud"); // replaces, no leak
    const f = try ps.addFile(p, "/tmp/demo/README.md");
    try ps.setIcon(&f.icon, "document");
    _ = try ps.addShells(p, "/tmp/demo");
    _ = try ps.add("/");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try ps.serialize(&out);
    try std.testing.expectEqualStrings(
        "icon\t#E5484D\n" ++
            "shells\tnotes\t/Users/x/notes\nicon\tnotebook\n" ++
            "project\t0\tdemo\t/tmp/demo\nicon\tcloud\n" ++
            "file\tREADME.md\t/tmp/demo/README.md\nicon\tdocument\n" ++
            "shells\tShells\t/tmp/demo\n" ++
            "project\t1\t/\t/\n",
        out.items,
    );

    var back = Projects.init(std.testing.allocator);
    defer back.deinit();
    back.parse(out.items);
    try std.testing.expectEqualStrings("#E5484D", back.default_icon.?);
    try std.testing.expectEqual(@as(usize, 1), back.default_resources.items.len);
    try std.testing.expectEqualStrings("notebook", back.default_resources.items[0].icon.?);
    try std.testing.expectEqual(@as(usize, 2), back.items.items.len);
    const bp = back.items.items[0];
    try std.testing.expect(!bp.open);
    try std.testing.expectEqualStrings("cloud", bp.icon.?);
    try std.testing.expectEqual(@as(usize, 2), bp.resources.items.len);
    try std.testing.expectEqualStrings("document", bp.resources.items[0].icon.?);
    try std.testing.expectEqual(Kind.shells, bp.resources.items[1].kind);
    try std.testing.expect(bp.resources.items[1].icon == null);
    try std.testing.expect(back.items.items[1].icon == null);
    try std.testing.expectEqualStrings("/", back.items.items[1].root);

    // Clearing frees and writes nothing.
    try back.setIcon(&back.items.items[0].icon, null);
    try std.testing.expect(back.items.items[0].icon == null);
}

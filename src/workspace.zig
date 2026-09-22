//! The workspace: which tabs were open, under which sidebar row, and what
//! they showed, kept in ~/.conch_workspace so a relaunch brings them back.
//! A kind takes part by implementing `save` (see tabs/tab.zig); the terminal
//! does, so a shell tab comes back with its blocks — commands, output,
//! colours, exit codes — and starts its shell again the first time it is
//! used. The file is rewritten when something changed (a command finished,
//! a tab opened, closed or was renamed, a shell changed directory …), at
//! most every couple of seconds, and once more on quit.
//!
//! Format, one record per line, fields escaped as in records.zig:
//!   conch-workspace <tab> 2
//!   shown <tab> group…                         the row whose tabs are on show
//!   layout <tab> tree <tab> focused <tab> group…   how a group's panes are split
//!   tab <tab> 1|0 (in front of its pane) <tab> kind <tab> title <tab> cwd <tab> pane <tab> group…
//!   <tab> line                                 the tab's own lines, from its `save`
//! `group…` is `default <tab> <tab> <tab>` for the default project's own
//! tabs, `project <tab> root <tab> <tab>` for a project's own tabs, or
//! `file|shells <tab> root <tab> name <tab> path` for a sidebar resource's
//! (root empty: a resource of the default project) — named rather than
//! numbered, because ids are handed out afresh on every launch; a resource
//! that is gone sends its tabs to its project's own. A group's tabs are
//! written pane by pane in
//! reading order; `pane` is the pane's place in that order and `layout`
//! (only for a group with more than one pane; the text is `Layout.encode`'s,
//! `focused` the focused pane's place) is how the panes are arranged, so a
//! relaunch shows the same splits with the same tabs in them. Version 1
//! files — no `layout` records, no `pane` field — still read: one pane.
const std = @import("std");
const records = @import("records.zig");
const sys = @import("sys.zig");
const tab_mod = @import("tabs/tab.zig");
const layout_mod = @import("tabs/layout.zig");
const projects_mod = @import("projects.zig");

const TabManager = tab_mod.TabManager;
const Projects = projects_mod.Projects;
const Fields = std.mem.SplitIterator(u8, .scalar);

/// Seconds between looks for something new to save.
const check_interval: f64 = 2;
const max_file: usize = 1 << 26;

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    /// Null = not kept: tests and the headless runner, unless CONCH_WORKSPACE names a file.
    path: ?[]u8 = null,
    saved_version: u64 = 0,
    last_check: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, enabled: bool) Workspace {
        var self: Workspace = .{ .gpa = gpa };
        if (sys.getenv("CONCH_WORKSPACE")) |p| {
            self.path = gpa.dupe(u8, p) catch null;
        } else if (enabled) {
            self.path = std.fmt.allocPrint(gpa, "{s}/.conch_workspace", .{sys.home()}) catch null;
        }
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.path) |p| self.gpa.free(p);
    }

    /// Brings back the tabs of the last run; returns how many.
    pub fn restore(self: *Workspace, tabs: *TabManager, projects: *Projects) usize {
        const path = self.path orelse return 0;
        const data = sys.readFileTail(self.gpa, path, max_file) catch return 0;
        defer self.gpa.free(data);
        const n = parse(self.gpa, data, tabs, projects);
        self.saved_version = version(tabs, projects);
        return n;
    }

    /// Writes the file when something changed since the last write; looks
    /// every couple of seconds.
    pub fn saveIfChanged(self: *Workspace, tabs: *TabManager, projects: *Projects, now: f64) void {
        if (self.path == null or now - self.last_check < check_interval) return;
        self.last_check = now;
        if (version(tabs, projects) != self.saved_version) self.save(tabs, projects);
    }

    pub fn save(self: *Workspace, tabs: *TabManager, projects: *Projects) void {
        const path = self.path orelse return;
        const v = version(tabs, projects);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        serialize(self.gpa, tabs, projects, &out) catch return;
        sys.writeFileAtomic(self.gpa, path, out.items) catch |err| {
            std.log.err("could not save the workspace: {s}", .{@errorName(err)});
            return;
        };
        self.saved_version = v;
    }
};

/// Changes whenever `serialize` would write something different.
pub fn version(tabs: *TabManager, projects: *Projects) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&tabs.shown));
    for (tabs.groups.items) |*g| {
        h.update(std.mem.asBytes(&g.id));
        // A group is named on file by its resource (root, kind, name, path)
        // or its project's folder: renaming or moving either changes what
        // would be written.
        if (g.id != TabManager.default_group) {
            if (projects.findResource(g.id)) |f| {
                h.update(if (f.project) |p| p.root else "");
                h.update(@tagName(f.resource.kind));
                h.update(f.resource.name);
                h.update(f.resource.path);
            } else if (projects.find(g.id)) |p| h.update(p.root);
        }
        h.update(std.mem.asBytes(&g.layout.focused));
        g.layout.hash(&h);
        for (g.layout.owned.items) |p| {
            h.update(std.mem.asBytes(&p.active));
            for (p.tabs.items) |t| {
                h.update(std.mem.asBytes(&t.uid));
                h.update(t.kind);
                h.update(t.custom_title orelse "");
                h.update(t.vtable.cwd(t.ptr));
                const v = t.vtable.saveVersion(t.ptr);
                h.update(std.mem.asBytes(&v));
            }
        }
    }
    return h.final();
}

pub fn serialize(gpa: std.mem.Allocator, tabs: *TabManager, projects: *Projects, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, "conch-workspace\t2\nshown\t");
    try writeGroup(gpa, projects, tabs.shown, out);
    try out.append(gpa, '\n');
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (tabs.groups.items) |*g| {
        const panes = g.layout.panes();
        if (panes.len > 1) {
            try out.appendSlice(gpa, "layout\t");
            try g.layout.encode(gpa, out);
            var focused_at: usize = 0;
            for (panes.slice(), 0..) |p, i| {
                if (p.id == g.layout.focused) focused_at = i;
            }
            try out.print(gpa, "\t{d}\t", .{focused_at});
            try writeGroup(gpa, projects, g.id, out);
            try out.append(gpa, '\n');
        }
        for (panes.slice(), 0..) |p, pane_at| {
            for (p.tabs.items, 0..) |t, i| {
                body.clearRetainingCapacity();
                if (!t.vtable.save(t.ptr, &body)) continue;
                try out.appendSlice(gpa, if (i == p.active) "tab\t1\t" else "tab\t0\t");
                try out.appendSlice(gpa, t.kind);
                try out.append(gpa, '\t');
                try records.escape(out, gpa, t.custom_title orelse "");
                try out.append(gpa, '\t');
                try records.escape(out, gpa, t.vtable.cwd(t.ptr));
                try out.print(gpa, "\t{d}\t", .{pane_at});
                try writeGroup(gpa, projects, g.id, out);
                try out.append(gpa, '\n');
                var lines = std.mem.splitScalar(u8, body.items, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    try out.append(gpa, '\t');
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
            }
        }
    }
}

fn writeGroup(gpa: std.mem.Allocator, projects: *Projects, id: u32, out: *std.ArrayList(u8)) !void {
    if (id != TabManager.default_group) {
        // A resource's tabs: its project's folder (none for the default
        // project's), kind, name and path.
        if (projects.findResource(id)) |f| {
            try out.appendSlice(gpa, if (f.resource.kind == .file) "file\t" else "shells\t");
            try records.escape(out, gpa, if (f.project) |p| p.root else "");
            try out.append(gpa, '\t');
            try records.escape(out, gpa, f.resource.name);
            try out.append(gpa, '\t');
            try records.escape(out, gpa, f.resource.path);
            return;
        }
        // A project's own tabs: named by its folder.
        if (projects.find(id)) |p| {
            try out.appendSlice(gpa, "project\t");
            try records.escape(out, gpa, p.root);
            try out.appendSlice(gpa, "\t\t");
            return;
        }
    }
    try out.appendSlice(gpa, "default\t\t\t");
}

/// A `tab` record and the lines under it, until the next one opens it.
const Pending = struct {
    active: bool = false,
    group: u32 = TabManager.default_group,
    /// The pane, by its place in the group's reading order.
    pane: usize = 0,
    kind: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    cwd: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,

    fn deinit(self: *Pending, gpa: std.mem.Allocator) void {
        self.kind.deinit(gpa);
        self.title.deinit(gpa);
        self.cwd.deinit(gpa);
        self.body.deinit(gpa);
    }
};

const Active = struct { group: u32, uid: u32 };
/// A `layout` record: which pane of the group had the focus.
const Focus = struct { group: u32, pane: usize };

/// Opens the tabs `serialize` wrote, each in its group; returns how many.
pub fn parse(gpa: std.mem.Allocator, data: []const u8, tabs: *TabManager, projects: *Projects) usize {
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(gpa);
    var actives: std.ArrayList(Active) = .empty;
    defer actives.deinit(gpa);
    var focuses: std.ArrayList(Focus) = .empty;
    defer focuses.deinit(gpa);
    var pending: ?Pending = null;
    var shown: u32 = TabManager.default_group;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            if (pending) |*p| {
                p.body.appendSlice(gpa, line[1..]) catch {};
                p.body.append(gpa, '\n') catch {};
            }
            continue;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        const tag = f.next() orelse continue;
        if (std.mem.eql(u8, tag, "shown")) {
            shown = readGroup(gpa, &field, projects, &f);
        } else if (std.mem.eql(u8, tag, "layout")) {
            // Before the group's tabs: the panes they go into. A group whose
            // resource is gone shares the default group, which may already be
            // split — then its tabs land there by clamped index.
            const tree = f.next() orelse continue;
            const focused = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch 0;
            const group = readGroup(gpa, &field, projects, &f);
            tabs.show(group) catch continue;
            tabs.decodeLayout(group, tree) catch |err| {
                std.log.debug("workspace: pane layout not restored: {s}", .{@errorName(err)});
                continue;
            };
            focuses.append(gpa, .{ .group = group, .pane = focused }) catch {};
        } else if (std.mem.eql(u8, tag, "tab")) {
            if (pending) |*p| {
                count += open(gpa, tabs, p, shown, &actives);
                p.deinit(gpa);
                pending = null;
            }
            const active = f.next() orelse continue;
            const kind = f.next() orelse continue;
            const title = f.next() orelse continue;
            const cwd = f.next() orelse continue;
            var p: Pending = .{ .active = std.mem.eql(u8, active, "1") };
            p.kind.appendSlice(gpa, kind) catch {};
            p.title.appendSlice(gpa, records.unescape(&field, gpa, title) catch "") catch {};
            p.cwd.appendSlice(gpa, records.unescape(&field, gpa, cwd) catch "") catch {};
            // The pane field is a number; a version 1 record goes straight to the group.
            var group_kind = f.next() orelse continue;
            if (std.fmt.parseInt(usize, group_kind, 10)) |pane| {
                p.pane = pane;
                group_kind = f.next() orelse continue;
            } else |_| {}
            p.group = readGroupFrom(gpa, &field, projects, group_kind, &f);
            pending = p;
        }
    }
    if (pending) |*p| {
        count += open(gpa, tabs, p, shown, &actives);
        p.deinit(gpa);
    }
    // What was on show comes back on show; every pane shows the tab it had
    // in front, the focused pane of each group is focused again, and a pane
    // that got no tab back (its kinds keep nothing) goes away.
    tabs.show(shown) catch {};
    for (actives.items) |a| {
        const g = tabs.findGroup(a.group) orelse continue;
        for (g.layout.owned.items) |p| {
            const i = p.indexOf(a.uid) orelse continue;
            p.active = i;
            g.layout.focused = p.id;
        }
    }
    for (focuses.items) |fo| {
        const g = tabs.findGroup(fo.group) orelse continue;
        const panes = g.layout.panes();
        if (panes.len > 0) g.layout.focused = panes.items[@min(fo.pane, panes.len - 1)].id;
    }
    for (tabs.groups.items) |*g| {
        var empty: [layout_mod.max_panes]u32 = undefined;
        var n: usize = 0;
        for (g.layout.owned.items) |p| {
            if (p.tabs.items.len == 0 and n < empty.len) {
                empty[n] = p.id;
                n += 1;
            }
        }
        for (empty[0..n]) |id| {
            if (g.layout.count() > 1) _ = g.layout.remove(id);
        }
    }
    return count;
}

fn open(gpa: std.mem.Allocator, tabs: *TabManager, p: *Pending, shown: u32, actives: *std.ArrayList(Active)) usize {
    tabs.show(p.group) catch return 0;
    // Into the pane it was in (by place in reading order; the last one if the layout came back smaller).
    const panes = tabs.group().layout.panes();
    if (panes.len > 0) tabs.group().layout.focused = panes.items[@min(p.pane, panes.len - 1)].id;
    // A directory that is gone means the kind's default (where the app started).
    const dir: ?[]const u8 = if (p.cwd.items.len > 0 and dirExists(gpa, p.cwd.items)) p.cwd.items else null;
    // The tab the user sees first gets its shell right away; the others wait to be used.
    const index = tabs.openWith(p.kind.items, .{
        .cwd = dir,
        .start_shell = p.active and p.group == shown,
        .saved = p.body.items,
    }) catch |err| {
        std.log.err("could not restore a {s} tab: {s}", .{ p.kind.items, @errorName(err) });
        return 0;
    };
    const uid = tabs.items()[index].uid;
    if (p.title.items.len > 0) tabs.rename(uid, p.title.items);
    if (p.active) actives.append(gpa, .{ .group = p.group, .uid = uid }) catch {};
    return 1;
}

/// The group a record names: the resource's id today, or the default group
/// when the resource is gone.
fn readGroup(gpa: std.mem.Allocator, field: *std.ArrayList(u8), projects: *Projects, f: *Fields) u32 {
    return readGroupFrom(gpa, field, projects, f.next() orelse return TabManager.default_group, f);
}

/// `readGroup` with the kind field already taken from `f`.
fn readGroupFrom(gpa: std.mem.Allocator, field: *std.ArrayList(u8), projects: *Projects, kind: []const u8, f: *Fields) u32 {
    const default = TabManager.default_group;
    if (std.mem.eql(u8, kind, "project")) {
        const root = f.next() orelse return default;
        const p = projects.byRoot(records.unescape(field, gpa, root) catch return default) orelse return default;
        return p.id;
    }
    const want: projects_mod.Kind = if (std.mem.eql(u8, kind, "file")) .file else if (std.mem.eql(u8, kind, "shells")) .shells else return default;
    const root = f.next() orelse return default;
    const name = f.next() orelse return default;
    const path = f.rest();
    // An empty root is the default project's own resource.
    const project: ?*projects_mod.Project = blk: {
        const r = records.unescape(field, gpa, root) catch return default;
        if (r.len == 0) break :blk null;
        break :blk projects.byRoot(r) orelse return default;
    };
    for (projects.resourcesOf(project).items) |r| {
        if (r.kind != want) continue;
        if (!std.mem.eql(u8, r.name, records.unescape(field, gpa, name) catch continue)) continue;
        if (!std.mem.eql(u8, r.path, records.unescape(field, gpa, path) catch continue)) continue;
        return r.id;
    }
    // The resource is gone: its tabs join its project's own.
    return if (project) |p| p.id else default;
}

fn dirExists(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    const dir = std.c.opendir(path_z.ptr) orelse return false;
    _ = std.c.closedir(dir);
    return true;
}

// ── tests ────────────────────────────────────────────────────────────────
const History = @import("input/history.zig").History;

/// A kind that keeps a few lines and comes back with them.
const KeptTab = struct {
    pub const kind_label = "Kept";
    gpa: std.mem.Allocator,
    dir: []u8,
    body: []u8,
    started: bool,

    fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(KeptTab);
        errdefer env.gpa.destroy(self);
        const dir = try env.gpa.dupe(u8, args.cwd orelse "-");
        errdefer env.gpa.free(dir);
        self.* = .{
            .gpa = env.gpa,
            .dir = dir,
            .body = try env.gpa.dupe(u8, args.saved orelse "one\ntwo\t2\n"),
            .started = args.start_shell,
        };
        return tab_mod.Tab.from(KeptTab, self);
    }
    pub fn deinit(self: *KeptTab) void {
        self.gpa.free(self.dir);
        self.gpa.free(self.body);
        self.gpa.destroy(self);
    }
    pub fn draw(_: *KeptTab, _: *tab_mod.Ui, _: tab_mod.Rect, _: bool) void {}
    pub fn cwd(self: *KeptTab) []const u8 {
        return self.dir;
    }
    pub fn save(self: *KeptTab, out: *std.ArrayList(u8)) bool {
        out.appendSlice(self.gpa, self.body) catch return false;
        return true;
    }
    pub fn saveVersion(self: *KeptTab) u64 {
        return self.body.len;
    }
};

/// A kind with nothing to keep.
const PlainTab = struct {
    pub const kind_label = "Plain";
    gpa: std.mem.Allocator,

    fn create(env: *tab_mod.Env, _: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(PlainTab);
        self.* = .{ .gpa = env.gpa };
        return tab_mod.Tab.from(PlainTab, self);
    }
    pub fn deinit(self: *PlainTab) void {
        self.gpa.destroy(self);
    }
    pub fn draw(_: *PlainTab, _: *tab_mod.Ui, _: tab_mod.Rect, _: bool) void {}
};

fn testManager(env: *tab_mod.Env) !TabManager {
    var tm = try TabManager.init(std.testing.allocator, env);
    tm.register(.{ .name = "kept", .label = "Kept", .create = KeptTab.create });
    tm.register(.{ .name = "plain", .label = "Plain", .create = PlainTab.create });
    return tm;
}

test "workspace: a resource that is gone sends its tabs to its project; the default project's resources round trip" {
    const gpa = std.testing.allocator;
    var history = History.init(gpa);
    defer history.deinit();
    var env: tab_mod.Env = .{
        .gpa = gpa,
        .history = &history,
        .integration_dir = "",
        .user_zdotdir = "",
        .launch_cwd = "/",
        .setClipboard = struct {
            fn f(_: []const u8) void {}
        }.f,
    };
    var projects = Projects.init(gpa);
    defer projects.deinit();
    const project = try projects.add("/tmp/demo");
    const old =
        "conch-workspace\t2\n" ++
        "shown\tshells\t/tmp/demo\tShells\t/tmp/demo\n" ++
        "tab\t1\tkept\t\t/tmp/demo\t0\tshells\t/tmp/demo\tShells\t/tmp/demo\n\tone\n\ttwo\t2\n" ++
        "tab\t0\tkept\t\t/tmp\t0\tfile\t/tmp/demo\tREADME.md\t/tmp/demo/README.md\n\tone\n";
    var tm = try testManager(&env);
    defer tm.deinit();
    try std.testing.expectEqual(@as(usize, 2), parse(gpa, old, &tm, &projects));
    try std.testing.expectEqual(project.id, tm.groupId());
    try std.testing.expectEqual(@as(usize, 2), tm.items().len);

    // A resource of the default project is named with an empty root.
    const notes = try projects.addShells(null, "/tmp/notes");
    try tm.show(notes.id);
    _ = try tm.openWith("kept", .{ .cwd = "/tmp/notes" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try serialize(gpa, &tm, &projects, &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "conch-workspace\t2\nshown\tshells\t\tnotes\t/tmp/notes\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\t0\tproject\t/tmp/demo\t\t\n") != null);

    var tm2 = try testManager(&env);
    defer tm2.deinit();
    try std.testing.expectEqual(@as(usize, 3), parse(gpa, out.items, &tm2, &projects));
    try std.testing.expectEqual(notes.id, tm2.groupId());
    try std.testing.expectEqual(@as(usize, 1), tm2.items().len);
    try std.testing.expectEqual(@as(usize, 2), tm2.findGroup(project.id).?.count());
}

test "workspace: tabs come back in their groups with their names, directories and contents" {
    const gpa = std.testing.allocator;
    var history = History.init(gpa);
    defer history.deinit();
    var env: tab_mod.Env = .{
        .gpa = gpa,
        .history = &history,
        .integration_dir = "",
        .user_zdotdir = "",
        .launch_cwd = "/",
        .setClipboard = struct {
            fn f(_: []const u8) void {}
        }.f,
    };
    var projects = Projects.init(gpa);
    defer projects.deinit();
    const project = try projects.add("/tmp/demo");
    const shells = try projects.addShells(project, "/tmp/demo");

    var tm = try testManager(&env);
    defer tm.deinit();
    _ = try tm.open("kept");
    const named = try tm.open("kept");
    tm.rename(tm.items()[named].uid, "Named");
    try tm.show(shells.id);
    _ = try tm.openWith("kept", .{ .cwd = "/tmp" });
    _ = try tm.open("plain"); // nothing to keep: left out, so on file its group has no active tab

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try serialize(gpa, &tm, &projects, &out);
    try std.testing.expectEqualStrings(
        "conch-workspace\t2\n" ++
            "shown\tshells\t/tmp/demo\tShells\t/tmp/demo\n" ++
            "tab\t0\tkept\t\t-\t0\tdefault\t\t\t\n\tone\n\ttwo\t2\n" ++
            "tab\t1\tkept\tNamed\t-\t0\tdefault\t\t\t\n\tone\n\ttwo\t2\n" ++
            "tab\t0\tkept\t\t/tmp\t0\tshells\t/tmp/demo\tShells\t/tmp/demo\n\tone\n\ttwo\t2\n",
        out.items,
    );
    const v = version(&tm, &projects);
    tm.rename(tm.items()[0].uid, "Other");
    try std.testing.expect(version(&tm, &projects) != v);

    // The next launch: projects come back from their own file first, then the tabs.
    var projects2 = Projects.init(gpa);
    defer projects2.deinit();
    var pout: std.ArrayList(u8) = .empty;
    defer pout.deinit(gpa);
    try projects.serialize(&pout);
    projects2.parse(pout.items);
    var tm2 = try testManager(&env);
    defer tm2.deinit();
    try std.testing.expectEqual(@as(usize, 3), parse(gpa, out.items, &tm2, &projects2));
    const shells2 = projects2.items.items[0].resources.items[0].id;
    try std.testing.expectEqual(shells2, tm2.groupId());
    try std.testing.expectEqual(@as(usize, 1), tm2.items().len);
    const restored: *KeptTab = @ptrCast(@alignCast(tm2.items()[0].ptr));
    try std.testing.expectEqualStrings("/tmp", restored.dir);
    try std.testing.expectEqualStrings("one\ntwo\t2\n", restored.body);
    try std.testing.expect(!restored.started); // not the tab in front of the shown group
    const home = tm2.findGroup(TabManager.default_group).?.pane();
    try std.testing.expectEqual(@as(usize, 2), home.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), home.active);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Kept", home.tabs.items[0].title(&buf));
    try std.testing.expectEqualStrings("Named", home.tabs.items[1].title(&buf));
    const first: *KeptTab = @ptrCast(@alignCast(home.tabs.items[0].ptr));
    try std.testing.expectEqualStrings("-", first.dir); // "-" is no directory: the kind's default

    // Without the resource (nor its project) its tabs land in the default
    // group, and the tab in front of the shown group starts right away.
    var none = Projects.init(gpa);
    defer none.deinit();
    var tm3 = try testManager(&env);
    defer tm3.deinit();
    try std.testing.expectEqual(@as(usize, 3), parse(gpa, out.items, &tm3, &none));
    try std.testing.expectEqual(TabManager.default_group, tm3.groupId());
    try std.testing.expectEqual(@as(usize, 3), tm3.items().len);
    try std.testing.expectEqual(@as(usize, 1), tm3.activeIndex());
    const eager: *KeptTab = @ptrCast(@alignCast(tm3.items()[1].ptr));
    try std.testing.expect(eager.started);
    const later: *KeptTab = @ptrCast(@alignCast(tm3.items()[2].ptr));
    try std.testing.expect(!later.started);
}

test "workspace: split panes come back as they were, version 1 files still read" {
    const gpa = std.testing.allocator;
    var history = History.init(gpa);
    defer history.deinit();
    var env: tab_mod.Env = .{
        .gpa = gpa,
        .history = &history,
        .integration_dir = "",
        .user_zdotdir = "",
        .launch_cwd = "/",
        .setClipboard = struct {
            fn f(_: []const u8) void {}
        }.f,
    };
    var none = Projects.init(gpa);
    defer none.deinit();

    // [a, b] | [c] over [d, e]: the middle pane focused, the root divider
    // moved, e a kind that keeps nothing.
    var tm = try testManager(&env);
    defer tm.deinit();
    _ = try tm.open("kept");
    _ = try tm.open("kept");
    const middle = (try tm.splitPane(.right)).id;
    _ = try tm.openWith("kept", .{ .cwd = "/tmp" });
    _ = try tm.splitPane(.bottom);
    _ = try tm.open("kept");
    _ = try tm.open("plain");
    tm.activate(0);
    var geo = tm.group().layout.geometry(.{ .x = 0, .y = 0, .w = 1000, .h = 1000 }, 0);
    tab_mod.Layout.resize(geo.dividers[0].split, 0, 0.1, 0.05);
    try std.testing.expect(tm.focusPane(middle));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try serialize(gpa, &tm, &none, &out);
    try std.testing.expectEqualStrings(
        "conch-workspace\t2\n" ++
            "shown\tdefault\t\t\t\n" ++
            "layout\th(0.6000:_,0.4000:v(0.5000:_,0.5000:_))\t1\tdefault\t\t\t\n" ++
            "tab\t0\tkept\t\t-\t0\tdefault\t\t\t\n\tone\n\ttwo\t2\n" ++
            "tab\t1\tkept\t\t-\t0\tdefault\t\t\t\n\tone\n\ttwo\t2\n" ++
            "tab\t1\tkept\t\t/tmp\t1\tdefault\t\t\t\n\tone\n\ttwo\t2\n" ++
            "tab\t1\tkept\t\t-\t2\tdefault\t\t\t\n\tone\n\ttwo\t2\n",
        out.items,
    );
    // Moving a divider or splitting is a change worth saving.
    const v = version(&tm, &none);
    geo = tm.group().layout.geometry(.{ .x = 0, .y = 0, .w = 1000, .h = 1000 }, 0);
    tab_mod.Layout.resize(geo.dividers[0].split, 0, 0.05, 0.05);
    try std.testing.expect(version(&tm, &none) != v);

    // Next launch: three panes in the same arrangement, tabs where they
    // were, the middle pane focused with its tab in front and started.
    var tm2 = try testManager(&env);
    defer tm2.deinit();
    try std.testing.expectEqual(@as(usize, 4), parse(gpa, out.items, &tm2, &none));
    const l = &tm2.group().layout;
    try std.testing.expectEqual(@as(usize, 3), l.count());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try l.encode(gpa, &text);
    try std.testing.expectEqualStrings("h(0.6000:_,0.4000:v(0.5000:_,0.5000:_))", text.items);
    const panes = l.panes();
    try std.testing.expectEqual(@as(usize, 2), panes.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), panes.items[0].active);
    try std.testing.expectEqual(@as(usize, 1), panes.items[1].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), panes.items[2].tabs.items.len);
    try std.testing.expectEqual(panes.items[1].id, l.focused);
    const front: *KeptTab = @ptrCast(@alignCast(tm2.current().?.ptr));
    try std.testing.expectEqualStrings("/tmp", front.dir);
    try std.testing.expect(front.started);
    const behind: *KeptTab = @ptrCast(@alignCast(panes.items[0].tabs.items[0].ptr));
    try std.testing.expect(!behind.started);
    const below: *KeptTab = @ptrCast(@alignCast(panes.items[2].tabs.items[0].ptr));
    try std.testing.expect(below.started); // in front of a visible pane

    // A version 1 file has no pane field and no layout: one pane. A pane
    // whose tabs kept nothing is dropped rather than left empty.
    var tm3 = try testManager(&env);
    defer tm3.deinit();
    const old =
        "conch-workspace\t1\n" ++
        "shown\tdefault\t\t\t\n" ++
        "tab\t1\tkept\tOld\t-\tdefault\t\t\t\n\tx\n";
    try std.testing.expectEqual(@as(usize, 1), parse(gpa, old, &tm3, &none));
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Old", tm3.current().?.title(&buf));
    try std.testing.expectEqual(@as(usize, 1), tm3.group().layout.count());
    var tm4 = try testManager(&env);
    defer tm4.deinit();
    const sparse =
        "conch-workspace\t2\n" ++
        "shown\tdefault\t\t\t\n" ++
        "layout\th(0.5000:_,0.5000:_)\t1\tdefault\t\t\t\n" ++
        "tab\t1\tkept\t\t-\t0\tdefault\t\t\t\n\tx\n";
    try std.testing.expectEqual(@as(usize, 1), parse(gpa, sparse, &tm4, &none));
    try std.testing.expectEqual(@as(usize, 1), tm4.group().layout.count());
    try std.testing.expectEqual(@as(usize, 1), tm4.items().len);
}

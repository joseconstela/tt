//! The commits of a repository as the History view reads them: the log a
//! page at a time with the graph laid out as it comes in (`History`), and
//! one commit's message and files (`Detail`). Both ask git through
//! `git.Query`, on a thread of its own, and are polled with `tick`; what
//! is on show stays until the fresh answer has arrived, so a reload does
//! not blank the list.
const std = @import("std");
const hosts = @import("../hosts.zig");
const git = @import("git.zig");
const log_mod = @import("../model/log.zig");
const lanes_mod = @import("../model/lanes.zig");

/// How many commits one page asks for.
pub const page_size: usize = 300;
/// How many tags the sidebar lists (the newest).
const max_tags = "40";

pub const History = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    root: std.ArrayList(u8) = .empty,
    log: log_mod.Log,
    /// One per commit of `log`, in the same order.
    rows: std.ArrayList(lanes_mod.Row) = .empty,
    lanes: lanes_mod.Lanes,
    /// The widest row so far, in columns.
    width: u8 = 1,
    query: ?*git.Query = null,
    /// The query under way replaces what is on show (a reload) rather
    /// than adding a page to it.
    replacing: bool = false,
    /// A reload asked for while a query was under way.
    reload_pending: bool = false,
    /// The last page came back short: there is nothing older.
    complete: bool = false,
    /// A first answer has arrived (an empty repository has one too).
    loaded: bool = false,
    /// Tag names, newest first, and the stash list; slices into the raws.
    tags_raw: []u8 = &.{},
    tags: std.ArrayList([]const u8) = .empty,
    stash_raw: []u8 = &.{},
    stashes: []log_mod.Stash = &.{},
    /// Bumped whenever what is on show changed.
    generation: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, runner: hosts.Runner) History {
        return .{ .gpa = gpa, .runner = runner, .log = log_mod.Log.init(gpa), .lanes = lanes_mod.Lanes.init(gpa) };
    }

    pub fn deinit(self: *History) void {
        if (self.query) |q| q.destroy();
        self.log.deinit();
        self.rows.deinit(self.gpa);
        self.lanes.deinit();
        self.tags.deinit(self.gpa);
        self.gpa.free(self.tags_raw);
        self.gpa.free(self.stashes);
        self.gpa.free(self.stash_raw);
        self.root.deinit(self.gpa);
    }

    pub fn loading(self: *const History) bool {
        return self.query != null;
    }

    /// Reads the log of `root` again from the top, as many commits as are
    /// on show now (a page at least), with the tags and the stash list.
    pub fn reload(self: *History, root: []const u8) void {
        if (root.len == 0) return;
        if (!std.mem.eql(u8, self.root.items, root)) {
            self.root.clearRetainingCapacity();
            self.root.appendSlice(self.gpa, root) catch return;
        }
        if (self.query != null) {
            self.reload_pending = true;
            return;
        }
        var n_buf: [24]u8 = undefined;
        const n = std.fmt.bufPrint(&n_buf, "{d}", .{@max(page_size, self.log.commits.items.len)}) catch return;
        self.query = git.Query.start(self.gpa, self.runner, self.root.items, &.{
            &.{ "git", "log", "-z", "--topo-order", "--decorate=full", log_mod.format, "--exclude=refs/stash", "--all", "-n", n },
            &.{ "git", "for-each-ref", "--sort=-creatordate", "--count=" ++ max_tags, "--format=%(refname:short)", "refs/tags" },
            &.{ "git", "stash", "list", "--format=%gd%x1f%s" },
        }) catch return;
        self.replacing = true;
    }

    /// Asks for the next page, unless one is on its way or there is none.
    pub fn more(self: *History) void {
        if (self.query != null or self.complete or !self.loaded or self.root.items.len == 0) return;
        var n_buf: [24]u8 = undefined;
        var skip_buf: [40]u8 = undefined;
        const n = std.fmt.bufPrint(&n_buf, "{d}", .{page_size}) catch return;
        const skip = std.fmt.bufPrint(&skip_buf, "--skip={d}", .{self.log.commits.items.len}) catch return;
        self.query = git.Query.start(self.gpa, self.runner, self.root.items, &.{
            &.{ "git", "log", "-z", "--topo-order", "--decorate=full", log_mod.format, "--exclude=refs/stash", "--all", "-n", n, skip },
        }) catch return;
        self.replacing = false;
    }

    /// Takes an answer in when one has arrived. True when what is on show changed.
    pub fn tick(self: *History) bool {
        const q = self.query orelse return false;
        if (!q.finished()) return false;
        self.query = null;
        defer q.destroy();
        const wanted: usize = if (self.replacing) @max(page_size, self.log.commits.items.len) else page_size;
        if (self.replacing) {
            self.log.clear();
            self.lanes.clear();
            self.rows.clearRetainingCapacity();
            self.width = 1;
            self.takeExtras(q);
        }
        const added = self.take(q.output(0) orelse "");
        self.complete = added < wanted;
        self.loaded = true;
        self.generation +%= 1;
        if (self.reload_pending) {
            self.reload_pending = false;
            self.reload(self.root.items);
        }
        return true;
    }

    /// Adds a page of `git log` output and lays its commits out; returns how many.
    fn take(self: *History, raw: []const u8) usize {
        const first = self.log.commits.items.len;
        const added = self.log.append(raw) catch 0;
        for (self.log.commits.items[first..]) |c| {
            const row = self.lanes.push(c.hash, c.parents) catch lanes_mod.Row{ .col = 0, .from_top = false, .to_bottom = false, .width = 1 };
            self.rows.append(self.gpa, row) catch break;
            self.width = @max(self.width, row.width);
        }
        // A row for every commit, even when memory ran out half-way.
        self.log.commits.items.len = @min(self.log.commits.items.len, self.rows.items.len);
        return added;
    }

    fn takeExtras(self: *History, q: *const git.Query) void {
        const gpa = self.gpa;
        self.tags.clearRetainingCapacity();
        gpa.free(self.tags_raw);
        self.tags_raw = gpa.dupe(u8, q.output(1) orelse "") catch &.{};
        var lines = std.mem.tokenizeAny(u8, self.tags_raw, "\r\n");
        while (lines.next()) |line| self.tags.append(gpa, line) catch break;

        gpa.free(self.stashes);
        self.stashes = &.{};
        gpa.free(self.stash_raw);
        self.stash_raw = gpa.dupe(u8, q.output(2) orelse "") catch &.{};
        self.stashes = log_mod.parsePairs(gpa, self.stash_raw) catch &.{};
    }

    /// Where the commit with `hash` is in the log, if it is loaded.
    pub fn indexOf(self: *const History, hash: []const u8) ?usize {
        for (self.log.commits.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.hash, hash)) return i;
        }
        return null;
    }

    /// Waits for the query under way and takes it in (a test's way).
    fn settle(self: *History) void {
        while (self.query) |q| {
            while (!q.finished()) std.Thread.yield() catch {};
            _ = self.tick();
        }
    }
};

/// One commit looked at closely: the rest of its message, when it was
/// made as git prints it in the user's time zone, and the files it
/// touched (a merge: against its first parent).
pub const Detail = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    /// The commit wanted, and the one the query under way is for.
    hash: std.ArrayList(u8) = .empty,
    first_parent: std.ArrayList(u8) = .empty,
    root: std.ArrayList(u8) = .empty,
    asked: std.ArrayList(u8) = .empty,
    query: ?*git.Query = null,
    /// What is loaded, and for which commit.
    loaded: std.ArrayList(u8) = .empty,
    body: []u8 = &.{},
    date: []u8 = &.{},
    changes: ?log_mod.Changes = null,

    pub fn init(gpa: std.mem.Allocator, runner: hosts.Runner) Detail {
        return .{ .gpa = gpa, .runner = runner };
    }

    pub fn deinit(self: *Detail) void {
        if (self.query) |q| q.destroy();
        self.clear();
        self.hash.deinit(self.gpa);
        self.first_parent.deinit(self.gpa);
        self.root.deinit(self.gpa);
        self.asked.deinit(self.gpa);
        self.loaded.deinit(self.gpa);
    }

    fn clear(self: *Detail) void {
        self.gpa.free(self.body);
        self.body = &.{};
        self.gpa.free(self.date);
        self.date = &.{};
        if (self.changes) |*c| c.deinit();
        self.changes = null;
    }

    /// True when what is loaded is the commit wanted.
    pub fn ready(self: *const Detail) bool {
        return self.hash.items.len > 0 and std.mem.eql(u8, self.loaded.items, self.hash.items);
    }

    /// Says which commit to show; it is read unless it already is.
    pub fn want(self: *Detail, root: []const u8, hash: []const u8, first_parent: ?[]const u8) void {
        if (std.mem.eql(u8, self.hash.items, hash) and std.mem.eql(u8, self.root.items, root)) return;
        self.hash.clearRetainingCapacity();
        self.hash.appendSlice(self.gpa, hash) catch return;
        self.first_parent.clearRetainingCapacity();
        self.first_parent.appendSlice(self.gpa, first_parent orelse "") catch {};
        self.root.clearRetainingCapacity();
        self.root.appendSlice(self.gpa, root) catch {};
        self.ask();
    }

    fn ask(self: *Detail) void {
        if (self.query != null or self.hash.items.len == 0 or self.ready()) return;
        const hash = self.hash.items;
        const show: []const []const u8 = &.{ "git", "show", "-s", "--format=%ad%x1f%b", "--date=format:%d %b %Y, %H:%M", hash };
        const files: []const []const u8 = if (self.first_parent.items.len > 0)
            &.{ "git", "diff", "--raw", "--numstat", "-z", "-M", self.first_parent.items, hash }
        else
            &.{ "git", "diff-tree", "--root", "-r", "--no-commit-id", "--raw", "--numstat", "-z", "-M", hash };
        self.query = git.Query.start(self.gpa, self.runner, self.root.items, &.{ show, files }) catch return;
        self.asked.clearRetainingCapacity();
        self.asked.appendSlice(self.gpa, hash) catch {};
    }

    /// Takes an answer in when one has arrived. True when what is on show changed.
    pub fn tick(self: *Detail) bool {
        const q = self.query orelse return false;
        if (!q.finished()) return false;
        self.query = null;
        defer q.destroy();
        // An answer for a commit no longer wanted is dropped, and the one wanted asked for.
        if (!std.mem.eql(u8, self.asked.items, self.hash.items)) {
            self.ask();
            return false;
        }
        self.clear();
        const shown = q.output(0) orelse "";
        const at = std.mem.indexOfScalar(u8, shown, 0x1f) orelse shown.len;
        self.date = self.gpa.dupe(u8, std.mem.trim(u8, shown[0..at], " \r\n")) catch &.{};
        self.body = self.gpa.dupe(u8, std.mem.trim(u8, shown[@min(at + 1, shown.len)..], " \r\n")) catch &.{};
        self.changes = log_mod.parseChanges(self.gpa, q.output(1) orelse "") catch null;
        self.loaded.clearRetainingCapacity();
        self.loaded.appendSlice(self.gpa, self.asked.items) catch {};
        return true;
    }

    fn settle(self: *Detail) void {
        while (self.query) |q| {
            while (!q.finished()) std.Thread.yield() catch {};
            _ = self.tick();
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
/// Answers `git log` with pages of a made-up history and remembers the last question.
const FakeLog = struct {
    asked: std.ArrayList(u8) = .empty,
    total: usize = 5,

    fn runner(self: *FakeLog) hosts.Runner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8) anyerror!hosts.Output {
        const self: *FakeLog = @ptrCast(@alignCast(ptr));
        const t = std.testing.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(t);
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "log")) {
            self.asked.clearRetainingCapacity();
            var skip: usize = 0;
            var n: usize = 0;
            for (argv, 0..) |a, i| {
                try self.asked.appendSlice(t, a);
                try self.asked.append(t, ' ');
                if (std.mem.startsWith(u8, a, "--skip=")) skip = try std.fmt.parseInt(usize, a["--skip=".len..], 10);
                if (std.mem.eql(u8, a, "-n")) n = try std.fmt.parseInt(usize, argv[i + 1], 10);
            }
            // Commit i has commit i+1 as its parent; the last has none.
            var i = skip;
            while (i < self.total and i < skip + n) : (i += 1) {
                var line: [200]u8 = undefined;
                const parent: []const u8 = if (i + 1 < self.total) try std.fmt.allocPrint(t, "{d:0>40}", .{i + 1}) else try t.dupe(u8, "");
                defer t.free(parent);
                try out.appendSlice(t, try std.fmt.bufPrint(&line, "{d:0>40}\x1f{s}\x1fA\x1fa@example.invalid\x1f{d}\x1f\x1fcommit {d}\x00", .{ i, parent, 1000 - i, i }));
            }
        } else if (std.mem.eql(u8, sub, "for-each-ref")) {
            try out.appendSlice(t, "v2\nv1\n");
        } else if (std.mem.eql(u8, sub, "stash")) {
            try out.appendSlice(t, "stash@{0}\x1fWIP on main\n");
        } else if (std.mem.eql(u8, sub, "show")) {
            try out.appendSlice(t, "21 Nov 2026, 18:42\x1fThe body.\n\nCloses #1.\n");
        } else if (std.mem.eql(u8, sub, "diff") or std.mem.eql(u8, sub, "diff-tree")) {
            try self.asked.appendSlice(t, sub);
            try out.appendSlice(t, ":100644 100644 a b M\x00src/a.zig\x003\t1\tsrc/a.zig\x00");
        }
        return .{ .gpa = gpa, .stdout = try gpa.dupe(u8, out.items), .stderr = try gpa.dupe(u8, ""), .status = 0 };
    }
};

test "the log comes a page at a time and the graph carries on" {
    const gpa = std.testing.allocator;
    var fake: FakeLog = .{ .total = page_size + 2 };
    defer fake.asked.deinit(gpa);
    var h = History.init(gpa, fake.runner());
    defer h.deinit();

    h.more();
    try std.testing.expect(!h.loading());
    h.reload("/r");
    try std.testing.expect(h.loading());
    h.settle();
    try std.testing.expect(h.loaded and !h.complete);
    try std.testing.expectEqual(page_size, h.log.commits.items.len);
    try std.testing.expectEqual(page_size, h.rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), h.tags.items.len);
    try std.testing.expectEqualStrings("v2", h.tags.items[0]);
    try std.testing.expectEqual(@as(usize, 1), h.stashes.len);

    h.more();
    h.settle();
    try std.testing.expect(std.mem.indexOf(u8, fake.asked.items, "--skip=300 ") != null);
    try std.testing.expect(h.complete);
    try std.testing.expectEqual(page_size + 2, h.rows.items.len);
    // One line of history: a single lane all the way, the last commit ending it.
    const last = h.rows.items[h.rows.items.len - 1];
    try std.testing.expectEqual(@as(u8, 0), last.col);
    try std.testing.expect(last.from_top and !last.to_bottom);
    try std.testing.expectEqual(@as(u8, 1), h.width);
    try std.testing.expectEqual(@as(?usize, 3), h.indexOf("0000000000000000000000000000000000000003"));

    // A reload asks for everything that was on show, in one go.
    h.reload("/r");
    h.settle();
    try std.testing.expect(std.mem.indexOf(u8, fake.asked.items, "-n 302 ") != null);
    try std.testing.expectEqual(page_size + 2, h.log.commits.items.len);
}

test "a commit's detail, and a root commit's files" {
    const gpa = std.testing.allocator;
    var fake: FakeLog = .{};
    defer fake.asked.deinit(gpa);
    var d = Detail.init(gpa, fake.runner());
    defer d.deinit();
    try std.testing.expect(!d.ready());

    d.want("/r", "abc", "def");
    d.settle();
    try std.testing.expect(d.ready());
    try std.testing.expectEqualStrings("21 Nov 2026, 18:42", d.date);
    try std.testing.expectEqualStrings("The body.\n\nCloses #1.", d.body);
    try std.testing.expectEqual(@as(usize, 1), d.changes.?.files.len);
    try std.testing.expectEqual(@as(u32, 3), d.changes.?.added);
    try std.testing.expectEqualStrings("diff", fake.asked.items);

    // No parent: the files come from diff-tree --root.
    fake.asked.clearRetainingCapacity();
    d.want("/r", "root", null);
    try std.testing.expect(!d.ready());
    d.settle();
    try std.testing.expect(d.ready());
    try std.testing.expectEqualStrings("diff-tree", fake.asked.items);
}

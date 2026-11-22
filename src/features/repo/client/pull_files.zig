//! A pull request's files and diffs, read with git on this Mac rather
//! than asked of the host: its head is fetched from the remote (and its
//! base branch with it), then the changed files, how many commits it has
//! and each file's diff come from `git diff base...head`, the same for
//! every kind of host. Asked through `git.Query`, on a thread of its own,
//! and polled with `tick`.
const std = @import("std");
const hosts = @import("../hosts.zig");
const git = @import("git.zig");
const log_mod = @import("../model/log.zig");
const patch_mod = @import("../model/patch.zig");

pub const State = enum { idle, fetching, ready, failed };

pub const PullFiles = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    root: std.ArrayList(u8) = .empty,
    /// The two ends of the pull request on show: `<base>...<head>`.
    range: std.ArrayList(u8) = .empty,
    /// What `range` was asked for (a pull request and its head), to tell a new one.
    key: std.ArrayList(u8) = .empty,
    state: State = .idle,
    query: ?*git.Query = null,
    changes: ?log_mod.Changes = null,
    commits: ?u32 = null,

    /// The file whose diff is wanted, and the diff once read.
    path: std.ArrayList(u8) = .empty,
    file_query: ?*git.Query = null,
    file_for: std.ArrayList(u8) = .empty,
    patch: ?patch_mod.Patch = null,
    patch_path: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, runner: hosts.Runner) PullFiles {
        return .{ .gpa = gpa, .runner = runner };
    }

    pub fn deinit(self: *PullFiles) void {
        if (self.query) |q| q.destroy();
        if (self.file_query) |q| q.destroy();
        self.clear();
        self.root.deinit(self.gpa);
        self.range.deinit(self.gpa);
        self.key.deinit(self.gpa);
        self.path.deinit(self.gpa);
        self.file_for.deinit(self.gpa);
        self.patch_path.deinit(self.gpa);
    }

    fn clear(self: *PullFiles) void {
        if (self.changes) |*c| c.deinit();
        self.changes = null;
        self.commits = null;
        if (self.patch) |*p| p.deinit();
        self.patch = null;
        self.patch_path.clearRetainingCapacity();
        self.path.clearRetainingCapacity();
    }

    /// Says which pull request to show: `head_ref` is fetched from
    /// `remote` (with `base_branch`), then `base_sha...head_sha` is read.
    /// Nothing happens when it is the one already asked for.
    pub fn want(self: *PullFiles, root: []const u8, remote: []const u8, head_ref: []const u8, base_branch: []const u8, base_sha: []const u8, head_sha: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x1f{s}\x1f{s}\x1f{s}", .{ root, head_ref, base_sha, head_sha }) catch return;
        if (std.mem.eql(u8, self.key.items, key)) return;
        if (self.query != null) return;
        self.key.clearRetainingCapacity();
        self.key.appendSlice(self.gpa, key) catch return;
        self.root.clearRetainingCapacity();
        self.root.appendSlice(self.gpa, root) catch return;
        self.range.clearRetainingCapacity();
        self.range.print(self.gpa, "{s}...{s}", .{ base_sha, head_sha }) catch return;
        self.clear();
        var dots_buf: [200]u8 = undefined;
        const two_dots = std.fmt.bufPrint(&dots_buf, "{s}..{s}", .{ base_sha, head_sha }) catch return;
        self.query = git.Query.start(self.gpa, self.runner, root, &.{
            &.{ "git", "fetch", "--no-tags", remote, head_ref, base_branch },
            &.{ "git", "diff", "--raw", "--numstat", "-z", "-M", self.range.items },
            &.{ "git", "rev-list", "--count", two_dots },
        }) catch null;
        self.state = if (self.query != null) .fetching else .failed;
    }

    /// Says whose diff to show among the pull request's files.
    pub fn select(self: *PullFiles, path: []const u8) void {
        if (std.mem.eql(u8, self.path.items, path)) return;
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, path) catch return;
        self.ask();
    }

    fn ask(self: *PullFiles) void {
        if (self.state != .ready or self.file_query != null or self.path.items.len == 0) return;
        if (std.mem.eql(u8, self.patch_path.items, self.path.items)) return;
        self.file_query = git.Query.start(self.gpa, self.runner, self.root.items, &.{
            &.{ "git", "diff", "-M", self.range.items, "--", self.path.items },
        }) catch return;
        self.file_for.clearRetainingCapacity();
        self.file_for.appendSlice(self.gpa, self.path.items) catch {};
    }

    /// The selected file's diff, once it is the one read.
    pub fn shown(self: *const PullFiles) ?*const patch_mod.Patch {
        if (!std.mem.eql(u8, self.patch_path.items, self.path.items)) return null;
        return if (self.patch) |*p| p else null;
    }

    /// Takes answers in. True when what is on show changed.
    pub fn tick(self: *PullFiles) bool {
        var changed = false;
        if (self.query) |q| {
            if (q.finished()) {
                self.query = null;
                defer q.destroy();
                // The fetch may fail (no network, a fork's branch) and the
                // commits be there all the same: the diff is what tells.
                if (q.output(1)) |raw| {
                    self.changes = log_mod.parseChanges(self.gpa, raw) catch null;
                    self.commits = if (q.output(2)) |n| std.fmt.parseInt(u32, std.mem.trim(u8, n, " \r\n"), 10) catch null else null;
                    self.state = .ready;
                } else self.state = .failed;
                changed = true;
            }
        }
        if (self.file_query) |q| {
            if (q.finished()) {
                self.file_query = null;
                defer q.destroy();
                if (std.mem.eql(u8, self.file_for.items, self.path.items)) {
                    if (self.patch) |*p| p.deinit();
                    self.patch = patch_mod.parse(self.gpa, q.output(0) orelse "") catch null;
                    self.patch_path.clearRetainingCapacity();
                    self.patch_path.appendSlice(self.gpa, self.file_for.items) catch {};
                    changed = true;
                }
            }
        }
        self.ask();
        return changed;
    }

    fn settle(self: *PullFiles) void {
        while (self.query != null or self.file_query != null) {
            if (self.query) |q| while (!q.finished()) std.Thread.yield() catch {};
            if (self.file_query) |q| while (!q.finished()) std.Thread.yield() catch {};
            _ = self.tick();
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
const FakePull = struct {
    asked: std.ArrayList(u8) = .empty,
    /// The commits are not there: the diff fails.
    missing: bool = false,

    fn runner(self: *FakePull) hosts.Runner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8) anyerror!hosts.Output {
        const self: *FakePull = @ptrCast(@alignCast(ptr));
        const t = std.testing.allocator;
        for (argv) |a| {
            try self.asked.appendSlice(t, a);
            try self.asked.append(t, ' ');
        }
        try self.asked.append(t, '\n');
        const sub = argv[1];
        var status: i32 = 0;
        var out: []const u8 = "";
        if (std.mem.eql(u8, sub, "fetch")) {
            status = 1;
        } else if (std.mem.eql(u8, sub, "rev-list")) {
            out = "3\n";
        } else if (std.mem.eql(u8, sub, "diff")) {
            if (self.missing) {
                status = 128;
            } else if (std.mem.eql(u8, argv[2], "--raw")) {
                out = ":000000 100644 0 a A\x00src/sign.js\x007\t0\tsrc/sign.js\x00";
            } else out = "@@ -0,0 +1,2 @@\n+a\n+b\n";
        }
        return .{ .gpa = gpa, .stdout = try gpa.dupe(u8, out), .stderr = try gpa.dupe(u8, ""), .status = status };
    }
};

test "a pull request's files come from git, fetched or already there" {
    const gpa = std.testing.allocator;
    var fake: FakePull = .{};
    defer fake.asked.deinit(gpa);
    var files = PullFiles.init(gpa, fake.runner());
    defer files.deinit();

    files.want("/r", "origin", "refs/pull/142/head", "main", "aaa", "bbb");
    try std.testing.expectEqual(State.fetching, files.state);
    files.settle();
    // The fetch failed, but the commits were there.
    try std.testing.expectEqual(State.ready, files.state);
    try std.testing.expectEqualStrings("git fetch --no-tags origin refs/pull/142/head main \ngit diff --raw --numstat -z -M aaa...bbb \ngit rev-list --count aaa..bbb \n", fake.asked.items);
    try std.testing.expectEqual(@as(usize, 1), files.changes.?.files.len);
    try std.testing.expectEqual(@as(?u32, 3), files.commits);
    try std.testing.expect(files.shown() == null);

    fake.asked.clearRetainingCapacity();
    files.select("src/sign.js");
    files.settle();
    try std.testing.expectEqualStrings("git diff -M aaa...bbb -- src/sign.js \n", fake.asked.items);
    try std.testing.expectEqual(@as(u32, 2), files.shown().?.added);

    // The same pull request again asks nothing; another one starts over.
    fake.asked.clearRetainingCapacity();
    files.want("/r", "origin", "refs/pull/142/head", "main", "aaa", "bbb");
    try std.testing.expectEqual(@as(usize, 0), fake.asked.items.len);
    fake.missing = true;
    files.want("/r", "origin", "refs/pull/143/head", "main", "ccc", "ddd");
    files.settle();
    try std.testing.expectEqual(State.failed, files.state);
    try std.testing.expect(files.changes == null);
}

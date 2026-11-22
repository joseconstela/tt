//! The working tree as the Changes view reads it, beyond what `git status`
//! says: how many lines each file adds and removes (staged, and not), and
//! the selected file's change as a diff. Asked through `git.Query`, on a
//! thread of its own, and polled with `tick`; `refresh` asks again after
//! the repository changed, and what is on show stays until the answer.
const std = @import("std");
const hosts = @import("../hosts.zig");
const git = @import("git.zig");
const patch_mod = @import("../model/patch.zig");

pub const Working = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    root: std.ArrayList(u8) = .empty,

    counts_query: ?*git.Query = null,
    counts_stale: bool = false,
    unstaged_raw: []u8 = &.{},
    unstaged: []patch_mod.Count = &.{},
    staged_raw: []u8 = &.{},
    staged: []patch_mod.Count = &.{},

    /// The file whose change is wanted ("" for none).
    path: std.ArrayList(u8) = .empty,
    staged_side: bool = false,
    untracked: bool = false,
    /// Bumped whenever the wanted change may differ from the one loaded.
    wanted: u64 = 0,
    asked: u64 = 0,
    loaded: u64 = 0,
    file_query: ?*git.Query = null,
    patch: ?patch_mod.Patch = null,

    pub fn init(gpa: std.mem.Allocator, runner: hosts.Runner) Working {
        return .{ .gpa = gpa, .runner = runner };
    }

    pub fn deinit(self: *Working) void {
        if (self.counts_query) |q| q.destroy();
        if (self.file_query) |q| q.destroy();
        if (self.patch) |*p| p.deinit();
        self.gpa.free(self.unstaged);
        self.gpa.free(self.unstaged_raw);
        self.gpa.free(self.staged);
        self.gpa.free(self.staged_raw);
        self.path.deinit(self.gpa);
        self.root.deinit(self.gpa);
    }

    /// The repository changed: counts and the selected file's change are read again.
    pub fn refresh(self: *Working, root: []const u8) void {
        if (!std.mem.eql(u8, self.root.items, root)) {
            self.root.clearRetainingCapacity();
            self.root.appendSlice(self.gpa, root) catch return;
        }
        self.counts_stale = true;
        self.wanted +%= 1;
        self.ask();
    }

    /// Says whose change to show: `staged` picks the index's side of the file.
    pub fn select(self: *Working, path: []const u8, staged: bool, untracked: bool) void {
        if (std.mem.eql(u8, self.path.items, path) and self.staged_side == staged and self.untracked == untracked) return;
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, path) catch return;
        self.staged_side = staged;
        self.untracked = untracked;
        self.wanted +%= 1;
        // The old file's lines are not the new one's.
        if (self.patch) |*p| p.deinit();
        self.patch = null;
        self.ask();
    }

    pub fn deselect(self: *Working) void {
        self.path.clearRetainingCapacity();
        if (self.patch) |*p| p.deinit();
        self.patch = null;
    }

    fn ask(self: *Working) void {
        if (self.root.items.len == 0) return;
        if (self.counts_stale and self.counts_query == null) {
            self.counts_query = git.Query.start(self.gpa, self.runner, self.root.items, &.{
                &.{ "git", "diff", "--numstat", "-z", "-M" },
                &.{ "git", "diff", "--cached", "--numstat", "-z", "-M" },
            }) catch null;
            if (self.counts_query != null) self.counts_stale = false;
        }
        if (self.path.items.len > 0 and self.loaded != self.wanted and self.file_query == null) {
            const path = self.path.items;
            const argv: []const []const u8 = if (self.staged_side)
                &.{ "git", "diff", "--cached", "-M", "--", path }
            else if (self.untracked)
                &.{ "git", "diff", "--no-index", "--", "/dev/null", path }
            else
                &.{ "git", "diff", "--", path };
            self.file_query = git.Query.start(self.gpa, self.runner, self.root.items, &.{argv}) catch null;
            if (self.file_query != null) self.asked = self.wanted;
        }
    }

    /// Takes answers in. True when what is on show changed.
    pub fn tick(self: *Working) bool {
        var changed = false;
        if (self.counts_query) |q| {
            if (q.finished()) {
                self.counts_query = null;
                defer q.destroy();
                const gpa = self.gpa;
                gpa.free(self.unstaged);
                self.unstaged = &.{};
                gpa.free(self.unstaged_raw);
                self.unstaged_raw = gpa.dupe(u8, q.output(0) orelse "") catch &.{};
                self.unstaged = patch_mod.numstat(gpa, self.unstaged_raw) catch &.{};
                gpa.free(self.staged);
                self.staged = &.{};
                gpa.free(self.staged_raw);
                self.staged_raw = gpa.dupe(u8, q.output(1) orelse "") catch &.{};
                self.staged = patch_mod.numstat(gpa, self.staged_raw) catch &.{};
                changed = true;
            }
        }
        if (self.file_query) |q| {
            if (q.finished()) {
                self.file_query = null;
                defer q.destroy();
                // An answer for a change no longer wanted is dropped.
                if (self.asked == self.wanted and self.path.items.len > 0) {
                    // `--no-index` exits with 1 when there is a difference: read what it printed anyway.
                    const fresh = patch_mod.parse(self.gpa, q.printed(0) orelse "") catch null;
                    if (fresh) |f| {
                        if (self.patch) |*p| p.deinit();
                        self.patch = f;
                    }
                    self.loaded = self.asked;
                    changed = true;
                }
            }
        }
        self.ask();
        return changed;
    }

    fn settle(self: *Working) void {
        while (self.counts_query != null or self.file_query != null) {
            if (self.counts_query) |q| while (!q.finished()) std.Thread.yield() catch {};
            if (self.file_query) |q| while (!q.finished()) std.Thread.yield() catch {};
            _ = self.tick();
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
const FakeDiff = struct {
    asked: std.ArrayList(u8) = .empty,

    fn runner(self: *FakeDiff) hosts.Runner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8) anyerror!hosts.Output {
        const self: *FakeDiff = @ptrCast(@alignCast(ptr));
        const t = std.testing.allocator;
        var numstat = false;
        var cached = false;
        var no_index = false;
        for (argv) |a| {
            if (std.mem.eql(u8, a, "--numstat")) numstat = true;
            if (std.mem.eql(u8, a, "--cached")) cached = true;
            if (std.mem.eql(u8, a, "--no-index")) no_index = true;
        }
        if (!numstat) {
            self.asked.clearRetainingCapacity();
            for (argv) |a| {
                try self.asked.appendSlice(t, a);
                try self.asked.append(t, ' ');
            }
        }
        const out: []const u8 = if (numstat)
            (if (cached) "5\t0\tsrc/new.zig\x00" else "2\t1\tnotes.txt\x00")
        else if (no_index)
            "@@ -0,0 +1 @@\n+fresh\n"
        else
            "@@ -1,2 +1,2 @@\n one\n-two\n+2\n";
        return .{ .gpa = gpa, .stdout = try gpa.dupe(u8, out), .stderr = try gpa.dupe(u8, ""), .status = if (no_index) 1 else 0 };
    }
};

test "counts and the selected file's change" {
    const gpa = std.testing.allocator;
    var fake: FakeDiff = .{};
    defer fake.asked.deinit(gpa);
    var w = Working.init(gpa, fake.runner());
    defer w.deinit();

    w.refresh("/r");
    w.settle();
    try std.testing.expectEqual(@as(usize, 1), w.unstaged.len);
    try std.testing.expectEqualStrings("notes.txt", w.unstaged[0].path);
    try std.testing.expectEqual(@as(u32, 5), w.staged[0].added);
    try std.testing.expect(w.patch == null);

    w.select("notes.txt", false, false);
    try std.testing.expect(w.patch == null);
    w.settle();
    try std.testing.expectEqualStrings("git diff -- notes.txt ", fake.asked.items);
    try std.testing.expectEqual(@as(u32, 1), w.patch.?.removed);

    // The staged side of a file, then a file git does not know yet (its diff exits with 1).
    w.select("src/new.zig", true, false);
    w.settle();
    try std.testing.expectEqualStrings("git diff --cached -M -- src/new.zig ", fake.asked.items);
    w.select("fresh.txt", false, true);
    w.settle();
    try std.testing.expectEqualStrings("git diff --no-index -- /dev/null fresh.txt ", fake.asked.items);
    try std.testing.expectEqual(@as(u32, 1), w.patch.?.added);
    try std.testing.expectEqualStrings("fresh", w.patch.?.lines[1].text);

    // After a change the same file is read again, and stays on show meanwhile.
    fake.asked.clearRetainingCapacity();
    w.refresh("/r");
    try std.testing.expect(w.patch != null);
    w.settle();
    try std.testing.expect(fake.asked.items.len > 0);
}

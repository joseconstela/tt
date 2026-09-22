//! Git for the files panel: what `git status` says about the folder on
//! show, kept fresh on a thread of its own, and the handful of commands the
//! Git view runs (stage, unstage, commit, discard). The parsing is pure and
//! tested; the commands go through `sys.run`.
const std = @import("std");
const sys = @import("sys.zig");

/// How a path shows in the tree: the colour it gets.
pub const Kind = enum(u8) {
    none,
    ignored,
    untracked,
    added,
    deleted,
    modified,
    conflict,

    /// What a folder shows when its files differ: the one that matters most.
    fn rank(k: Kind) u8 {
        return @intFromEnum(k);
    }
};

/// One line of `git status --porcelain=v1`.
pub const Entry = struct {
    /// Root-relative, without a trailing slash.
    path: []u8,
    /// Where a renamed or copied file came from.
    orig: ?[]u8 = null,
    /// The index and worktree codes (`XY`); `??` untracked, `!!` ignored.
    x: u8,
    y: u8,
    /// A whole untracked or ignored folder, listed collapsed.
    is_dir: bool = false,

    pub fn untracked(self: Entry) bool {
        return self.x == '?';
    }

    pub fn ignored(self: Entry) bool {
        return self.x == '!';
    }

    pub fn conflict(self: Entry) bool {
        if (self.x == 'U' or self.y == 'U') return true;
        return (self.x == 'A' and self.y == 'A') or (self.x == 'D' and self.y == 'D');
    }

    /// In the index: something to commit.
    pub fn staged(self: Entry) bool {
        return !self.conflict() and !self.untracked() and !self.ignored() and self.x != ' ';
    }

    /// In the worktree: something to stage (or throw away).
    pub fn unstaged(self: Entry) bool {
        if (self.conflict() or self.ignored()) return false;
        return self.untracked() or self.y != ' ';
    }

    /// The badge letter of the staged half (`A`, `M`, `D`, `R` …).
    pub fn stagedLetter(self: Entry) u8 {
        return self.x;
    }

    /// The badge letter of the worktree half: `U` for a new file.
    pub fn unstagedLetter(self: Entry) u8 {
        return if (self.untracked()) 'U' else self.y;
    }

    /// The colour the path gets in the tree.
    pub fn kind(self: Entry) Kind {
        if (self.ignored()) return .ignored;
        if (self.untracked()) return .untracked;
        if (self.conflict()) return .conflict;
        if (self.x == 'D' or self.y == 'D') return .deleted;
        if (self.x == 'A') return .added;
        return .modified;
    }
};

/// One reading of the repository, as the panel and the tree see it.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    /// The folder the status was taken for.
    dir: []u8 = &.{},
    /// The repository's top folder; empty when `dir` is not in one.
    root: []u8 = &.{},
    branch: []u8 = &.{},
    upstream: []u8 = &.{},
    ahead: u32 = 0,
    behind: u32 = 0,
    /// No commit yet on the branch.
    unborn: bool = false,
    detached: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    /// Exact paths (files, and collapsed folders) → colour.
    files: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Every folder above a changed file → the colour that matters most below it.
    dirs: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Collapsed folders: everything under one is this.
    recursive: std.StringHashMapUnmanaged(Kind) = .empty,
    staged_count: u32 = 0,
    unstaged_count: u32 = 0,
    conflict_count: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Snapshot {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Snapshot) void {
        const gpa = self.gpa;
        for (self.entries.items) |e| {
            gpa.free(e.path);
            if (e.orig) |o| gpa.free(o);
        }
        self.entries.deinit(gpa);
        self.files.deinit(gpa);
        self.dirs.deinit(gpa);
        self.recursive.deinit(gpa);
        gpa.free(self.dir);
        gpa.free(self.root);
        gpa.free(self.branch);
        gpa.free(self.upstream);
        self.* = init(gpa);
    }

    pub fn isRepo(self: *const Snapshot) bool {
        return self.root.len > 0;
    }

    /// True when `path` (absolute) is inside the repository.
    pub fn contains(self: *const Snapshot, path: []const u8) bool {
        if (!self.isRepo()) return false;
        return std.mem.startsWith(u8, path, self.root) and (path.len == self.root.len or path[self.root.len] == '/');
    }

    /// `path` (absolute) relative to the root, or null when outside.
    pub fn relative(self: *const Snapshot, path: []const u8) ?[]const u8 {
        if (!self.contains(path)) return null;
        if (path.len == self.root.len) return "";
        return path[self.root.len + 1 ..];
    }

    /// The colour of a root-relative path.
    pub fn kindOf(self: *const Snapshot, rel: []const u8, is_dir: bool) Kind {
        if (rel.len == 0) return .none;
        if (std.mem.eql(u8, rel, ".git") or std.mem.startsWith(u8, rel, ".git/")) return .ignored;
        if (self.files.get(rel)) |k| return k;
        if (is_dir) if (self.dirs.get(rel)) |k| return k;
        // Under a collapsed folder?
        var i = rel.len;
        while (i > 0) : (i -= 1) {
            if (rel[i - 1] != '/') continue;
            if (self.recursive.get(rel[0 .. i - 1])) |k| return k;
        }
        return .none;
    }

    /// The colour of an absolute path (none when outside the repository).
    pub fn kindOfPath(self: *const Snapshot, path: []const u8, is_dir: bool) Kind {
        const rel = self.relative(path) orelse return .none;
        return self.kindOf(rel, is_dir);
    }

    fn note(self: *Snapshot, map: *std.StringHashMapUnmanaged(Kind), key: []const u8, k: Kind) void {
        const gop = map.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing or Kind.rank(k) > Kind.rank(gop.value_ptr.*)) gop.value_ptr.* = k;
    }

    fn index(self: *Snapshot) void {
        for (self.entries.items) |e| {
            const k = e.kind();
            self.note(&self.files, e.path, k);
            if (e.is_dir) self.note(&self.recursive, e.path, k);
            if (k == .ignored) continue;
            var i: usize = 0;
            while (i < e.path.len) : (i += 1) {
                if (e.path[i] == '/') self.note(&self.dirs, e.path[0..i], k);
            }
            if (e.conflict()) {
                self.conflict_count += 1;
            } else {
                if (e.staged()) self.staged_count += 1;
                if (e.unstaged()) self.unstaged_count += 1;
            }
        }
    }
};

/// `git status --porcelain=v1 -z --branch` → a snapshot for `dir` in `root`.
pub fn parse(gpa: std.mem.Allocator, dir: []const u8, root: []const u8, raw: []const u8) !Snapshot {
    var s = Snapshot.init(gpa);
    errdefer s.deinit();
    s.dir = try gpa.dupe(u8, dir);
    s.root = try gpa.dupe(u8, root);
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |rec| {
        if (rec.len == 0) continue;
        if (std.mem.startsWith(u8, rec, "## ")) {
            try parseBranch(&s, rec[3..]);
            continue;
        }
        if (rec.len < 4 or rec[2] != ' ') continue;
        const x = rec[0];
        const y = rec[1];
        var path = rec[3..];
        var is_dir = false;
        if (path.len > 1 and path[path.len - 1] == '/') {
            path = path[0 .. path.len - 1];
            is_dir = true;
        }
        var orig: ?[]u8 = null;
        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
            if (records.next()) |from| orig = try gpa.dupe(u8, from);
        }
        errdefer if (orig) |o| gpa.free(o);
        try s.entries.append(gpa, .{ .path = try gpa.dupe(u8, path), .orig = orig, .x = x, .y = y, .is_dir = is_dir });
    }
    s.index();
    return s;
}

/// The `## …` header: `main...origin/main [ahead 1, behind 2]`,
/// `HEAD (no branch)`, `No commits yet on main`.
fn parseBranch(s: *Snapshot, header: []const u8) !void {
    const gpa = s.gpa;
    if (std.mem.startsWith(u8, header, "No commits yet on ")) {
        s.unborn = true;
        s.branch = try gpa.dupe(u8, header["No commits yet on ".len..]);
        return;
    }
    if (std.mem.startsWith(u8, header, "Initial commit on ")) {
        s.unborn = true;
        s.branch = try gpa.dupe(u8, header["Initial commit on ".len..]);
        return;
    }
    if (std.mem.eql(u8, header, "HEAD (no branch)")) {
        s.detached = true;
        s.branch = try gpa.dupe(u8, "HEAD");
        return;
    }
    var rest = header;
    var bracket: []const u8 = "";
    if (std.mem.indexOf(u8, rest, " [")) |b| {
        bracket = rest[b + 2 ..];
        rest = rest[0..b];
    }
    if (std.mem.indexOf(u8, rest, "...")) |dots| {
        s.branch = try gpa.dupe(u8, rest[0..dots]);
        s.upstream = try gpa.dupe(u8, rest[dots + 3 ..]);
    } else {
        s.branch = try gpa.dupe(u8, rest);
    }
    var parts = std.mem.tokenizeAny(u8, bracket, " ,]");
    while (parts.next()) |word| {
        const n = parts.next() orelse break;
        const v = std.fmt.parseInt(u32, n, 10) catch 0;
        if (std.mem.eql(u8, word, "ahead")) s.ahead = v;
        if (std.mem.eql(u8, word, "behind")) s.behind = v;
    }
}

// ── the live repository ─────────────────────────────────────────────────
const refresh_every: f64 = 2.0;
const status_env = [_][]const u8{ "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };
const action_env = [_][]const u8{ "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };

/// One `git status` run on its own thread.
const Job = struct {
    gpa: std.mem.Allocator,
    dir: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    root: []u8 = &.{},
    status: []u8 = &.{},

    fn run(job: *Job) void {
        defer job.done.store(true, .release);
        var top = sys.run(job.gpa, job.dir, &.{ "git", "rev-parse", "--show-toplevel" }, &status_env) catch return;
        defer top.deinit();
        if (!top.ok()) return;
        const root = std.mem.trim(u8, top.stdout, " \r\n");
        if (root.len == 0) return;
        var st = sys.run(job.gpa, root, &.{ "git", "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=normal", "--ignored" }, &status_env) catch return;
        defer st.deinit();
        if (!st.ok()) return;
        job.root = job.gpa.dupe(u8, root) catch return;
        job.status = job.gpa.dupe(u8, st.stdout) catch return;
    }

    fn destroy(job: *Job) void {
        job.gpa.free(job.dir);
        job.gpa.free(job.root);
        job.gpa.free(job.status);
        job.gpa.destroy(job);
    }
};

pub const Repo = struct {
    gpa: std.mem.Allocator,
    /// The folder the status is wanted for.
    dir: std.ArrayList(u8) = .empty,
    snapshot: Snapshot,
    /// What the snapshot was parsed from, to skip readings that say the same.
    raw_seen: std.ArrayList(u8) = .empty,
    /// What the last failed command said (the panel shows it).
    last_error: std.ArrayList(u8) = .empty,
    thread: ?std.Thread = null,
    job: ?*Job = null,
    last_run: f64 = -1e9,
    want_refresh: bool = true,
    /// Set whenever a reading of the repository has come in.
    generation: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Repo {
        return .{ .gpa = gpa, .snapshot = Snapshot.init(gpa) };
    }

    pub fn deinit(self: *Repo) void {
        if (self.thread) |t| t.join();
        if (self.job) |j| j.destroy();
        self.snapshot.deinit();
        self.dir.deinit(self.gpa);
        self.raw_seen.deinit(self.gpa);
        self.last_error.deinit(self.gpa);
    }

    /// Points the repository at `dir` (a fresh reading follows at once).
    pub fn setDir(self: *Repo, dir: []const u8) void {
        if (std.mem.eql(u8, self.dir.items, dir)) return;
        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(self.gpa, dir) catch return;
        self.want_refresh = true;
    }

    pub fn refreshSoon(self: *Repo) void {
        self.want_refresh = true;
    }

    /// True while a reading is on its way.
    pub fn busy(self: *const Repo) bool {
        return self.job != null;
    }

    /// Whether `dir` is inside the repository last read.
    pub fn isRepoFor(self: *const Repo, dir: []const u8) bool {
        return self.snapshot.contains(dir);
    }

    /// Starts and collects readings. True when the snapshot changed.
    pub fn tick(self: *Repo, now: f64) bool {
        var changed = false;
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return false;
            if (self.thread) |t| t.join();
            self.thread = null;
            self.job = null;
            defer job.destroy();
            changed = self.adopt(job);
        }
        if (self.dir.items.len > 0 and (self.want_refresh or now - self.last_run >= refresh_every)) self.start(now);
        return changed;
    }

    fn start(self: *Repo, now: f64) void {
        const job = self.gpa.create(Job) catch return;
        job.* = .{ .gpa = self.gpa, .dir = self.gpa.dupe(u8, self.dir.items) catch {
            self.gpa.destroy(job);
            return;
        } };
        self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            job.destroy();
            return;
        };
        self.job = job;
        self.want_refresh = false;
        self.last_run = now;
    }

    fn adopt(self: *Repo, job: *Job) bool {
        const same_root = std.mem.eql(u8, self.snapshot.root, job.root);
        const same_dir = std.mem.eql(u8, self.snapshot.dir, job.dir);
        if (same_root and same_dir and std.mem.eql(u8, self.raw_seen.items, job.status)) return false;
        var fresh = parse(self.gpa, job.dir, job.root, job.status) catch return false;
        self.snapshot.deinit();
        self.snapshot = fresh;
        fresh = undefined;
        self.raw_seen.clearRetainingCapacity();
        self.raw_seen.appendSlice(self.gpa, job.status) catch {};
        self.generation +%= 1;
        return true;
    }

    // ── commands ────────────────────────────────────────────────────────
    /// Runs `argv` in the repository's root; false (with `last_error`
    /// set) when it failed. A fresh reading follows either way.
    fn git(self: *Repo, argv: []const []const u8) bool {
        defer self.want_refresh = true;
        if (!self.snapshot.isRepo()) return false;
        var res = sys.run(self.gpa, self.snapshot.root, argv, &action_env) catch |err| {
            self.setError(@errorName(err));
            return false;
        };
        defer res.deinit();
        if (!res.ok()) {
            const line = res.firstErrorLine();
            self.setError(if (line.len > 0) line else "git failed");
            return false;
        }
        self.last_error.clearRetainingCapacity();
        return true;
    }

    fn setError(self: *Repo, msg: []const u8) void {
        self.last_error.clearRetainingCapacity();
        // git prefixes with "fatal: " / "error: "; the panel has little room.
        var m = msg;
        for ([_][]const u8{ "fatal: ", "error: " }) |p| {
            if (std.mem.startsWith(u8, m, p)) m = m[p.len..];
        }
        self.last_error.appendSlice(self.gpa, m) catch {};
    }

    pub fn stage(self: *Repo, rel: []const u8) bool {
        return self.git(&.{ "git", "add", "-A", "--", rel });
    }

    pub fn stageAll(self: *Repo) bool {
        return self.git(&.{ "git", "add", "-A" });
    }

    pub fn unstage(self: *Repo, rel: []const u8) bool {
        return self.git(&.{ "git", "reset", "-q", "--", rel });
    }

    pub fn unstageAll(self: *Repo) bool {
        return self.git(&.{ "git", "reset", "-q" });
    }

    /// Throws the worktree changes of `rel` away: a new file is deleted, a
    /// tracked one goes back to what the index has.
    pub fn discard(self: *Repo, rel: []const u8, untracked: bool) bool {
        if (untracked) return self.git(&.{ "git", "clean", "-f", "-d", "-q", "--", rel });
        return self.git(&.{ "git", "restore", "--worktree", "--", rel });
    }

    /// Throws every worktree change away, new files included.
    pub fn discardAll(self: *Repo) bool {
        const restored = self.git(&.{ "git", "restore", "--worktree", "--", "." });
        const cleaned = self.git(&.{ "git", "clean", "-f", "-d", "-q" });
        return restored and cleaned;
    }

    /// Commits what is staged with `message`; with `all`, everything is
    /// staged first.
    pub fn commit(self: *Repo, message: []const u8, all: bool) bool {
        if (all and !self.stageAll()) return false;
        return self.git(&.{ "git", "commit", "-q", "-m", message });
    }
};

// ── tests ───────────────────────────────────────────────────────────────
test "porcelain: kinds, sections and folders" {
    const gpa = std.testing.allocator;
    const raw = "## main...origin/main [ahead 1, behind 2]\x00" ++
        "A  docs/new.md\x00" ++
        " M README.md\x00" ++
        "MM src/app.zig\x00" ++
        "R  src/b.zig\x00src/a.zig\x00" ++
        "?? sdxasd\x00" ++
        "?? newdir/\x00" ++
        "!! zig-out/\x00" ++
        "UU merge.txt\x00" ++
        " D gone.txt\x00";
    var s = try parse(gpa, "/r/src", "/r", raw);
    defer s.deinit();
    try std.testing.expectEqualStrings("main", s.branch);
    try std.testing.expectEqualStrings("origin/main", s.upstream);
    try std.testing.expectEqual(@as(u32, 1), s.ahead);
    try std.testing.expectEqual(@as(u32, 2), s.behind);
    try std.testing.expectEqual(@as(usize, 9), s.entries.items.len);
    try std.testing.expectEqualStrings("src/a.zig", s.entries.items[3].orig.?);
    // Sections: A, M(index of MM), R staged; M, M(worktree of MM), ??, ??dir, D unstaged; UU conflict.
    try std.testing.expectEqual(@as(u32, 3), s.staged_count);
    try std.testing.expectEqual(@as(u32, 5), s.unstaged_count);
    try std.testing.expectEqual(@as(u32, 1), s.conflict_count);
    // Files.
    try std.testing.expectEqual(Kind.added, s.kindOf("docs/new.md", false));
    try std.testing.expectEqual(Kind.modified, s.kindOf("README.md", false));
    try std.testing.expectEqual(Kind.modified, s.kindOf("src/app.zig", false));
    try std.testing.expectEqual(Kind.untracked, s.kindOf("sdxasd", false));
    try std.testing.expectEqual(Kind.conflict, s.kindOf("merge.txt", false));
    try std.testing.expectEqual(Kind.none, s.kindOf("build.zig", false));
    // Folders: the colour that matters most below them.
    try std.testing.expectEqual(Kind.added, s.kindOf("docs", true));
    try std.testing.expectEqual(Kind.modified, s.kindOf("src", true));
    // Collapsed folders colour everything under them.
    try std.testing.expectEqual(Kind.untracked, s.kindOf("newdir", true));
    try std.testing.expectEqual(Kind.untracked, s.kindOf("newdir/deep/file.txt", false));
    try std.testing.expectEqual(Kind.ignored, s.kindOf("zig-out", true));
    try std.testing.expectEqual(Kind.ignored, s.kindOf("zig-out/bin/conch", false));
    try std.testing.expectEqual(Kind.ignored, s.kindOf(".git/HEAD", false));
    // Absolute paths map through the root.
    try std.testing.expectEqual(Kind.modified, s.kindOfPath("/r/README.md", false));
    try std.testing.expectEqual(Kind.none, s.kindOfPath("/elsewhere/README.md", false));
    try std.testing.expect(s.contains("/r/src"));
    try std.testing.expect(!s.contains("/rr"));
}

test "porcelain: unborn and detached heads" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "/r", "/r", "## No commits yet on main\x00?? x\x00");
    defer a.deinit();
    try std.testing.expect(a.unborn);
    try std.testing.expectEqualStrings("main", a.branch);
    var b = try parse(gpa, "/r", "/r", "## HEAD (no branch)\x00");
    defer b.deinit();
    try std.testing.expect(b.detached);
    var c = try parse(gpa, "/r", "/r", "## feature\x00");
    defer c.deinit();
    try std.testing.expectEqualStrings("feature", c.branch);
    try std.testing.expectEqual(@as(usize, 0), c.upstream.len);
}

test "entry letters" {
    const mm: Entry = .{ .path = @constCast("a"), .x = 'M', .y = 'M' };
    try std.testing.expect(mm.staged() and mm.unstaged());
    try std.testing.expectEqual(@as(u8, 'M'), mm.stagedLetter());
    const new: Entry = .{ .path = @constCast("b"), .x = '?', .y = '?' };
    try std.testing.expect(!new.staged() and new.unstaged());
    try std.testing.expectEqual(@as(u8, 'U'), new.unstagedLetter());
    const del: Entry = .{ .path = @constCast("c"), .x = 'D', .y = ' ' };
    try std.testing.expectEqual(Kind.deleted, del.kind());
}

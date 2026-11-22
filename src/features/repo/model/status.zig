//! What `git status` says about a folder, as data: the entries of
//! `git status --porcelain=v1 -z --branch`, the branch and how far it is
//! ahead of and behind its upstream, the colour each path gets in the tree,
//! and the local and remote-tracking branches. Pure: nothing here runs git
//! (`client/git.zig` does) or draws (`view/panel.zig` does).
const std = @import("std");

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
        return @backingInt(k);
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
    /// Local branches, and remote-tracking ones as `origin/x` (no HEAD).
    branches: std.ArrayList([]u8) = .empty,
    remotes: std.ArrayList([]u8) = .empty,
    /// The remotes themselves, by name, and where each one points (the
    /// address as written in the repository's config).
    remote_names: std.ArrayList([]u8) = .empty,
    remote_urls: std.ArrayList([]u8) = .empty,
    /// The commit HEAD points at; empty before the first commit.
    head: []u8 = &.{},

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
        for (self.branches.items) |b| gpa.free(b);
        self.branches.deinit(gpa);
        for (self.remotes.items) |b| gpa.free(b);
        self.remotes.deinit(gpa);
        for (self.remote_names.items) |b| gpa.free(b);
        self.remote_names.deinit(gpa);
        for (self.remote_urls.items) |b| gpa.free(b);
        self.remote_urls.deinit(gpa);
        gpa.free(self.head);
        gpa.free(self.dir);
        gpa.free(self.root);
        gpa.free(self.branch);
        gpa.free(self.upstream);
        self.* = init(gpa);
    }

    pub fn isRepo(self: *const Snapshot) bool {
        return self.root.len > 0;
    }

    /// `git for-each-ref refs/heads refs/remotes`, one ref a line, into
    /// `branches` and `remotes` (HEAD pointers skipped). Anything after
    /// the ref's name on its line (the commit it points at) is not read.
    pub fn parseRefs(self: *Snapshot, raw: []const u8) !void {
        const gpa = self.gpa;
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line_raw| {
            const whole = std.mem.trim(u8, line_raw, " \r\t");
            const line = whole[0 .. std.mem.indexOfScalar(u8, whole, ' ') orelse whole.len];
            if (std.mem.startsWith(u8, line, "refs/heads/")) {
                try self.branches.append(gpa, try gpa.dupe(u8, line["refs/heads/".len..]));
            } else if (std.mem.startsWith(u8, line, "refs/remotes/")) {
                const short = line["refs/remotes/".len..];
                if (std.mem.endsWith(u8, short, "/HEAD")) continue;
                try self.remotes.append(gpa, try gpa.dupe(u8, short));
            }
        }
    }

    /// `git config --get-regexp ^remote\..*\.url$`: a line per remote,
    /// `remote.<name>.url <address>`.
    pub fn parseRemotes(self: *Snapshot, raw: []const u8) !void {
        const gpa = self.gpa;
        var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[0..space];
            if (!std.mem.startsWith(u8, key, "remote.") or !std.mem.endsWith(u8, key, ".url")) continue;
            const name = key["remote.".len .. key.len - ".url".len];
            if (name.len == 0) continue;
            const name_copy = try gpa.dupe(u8, name);
            errdefer gpa.free(name_copy);
            const url_copy = try gpa.dupe(u8, std.mem.trim(u8, line[space + 1 ..], " \t"));
            errdefer gpa.free(url_copy);
            try self.remote_names.append(gpa, name_copy);
            self.remote_urls.append(gpa, url_copy) catch |err| {
                _ = self.remote_names.pop();
                return err;
            };
        }
    }

    /// Where the remote called `name` points; null when there is none.
    pub fn remoteUrl(self: *const Snapshot, name: []const u8) ?[]const u8 {
        for (self.remote_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.remote_urls.items[i];
        }
        return null;
    }

    /// Where a branch with no upstream is published: `origin` when there
    /// is a remote by that name, else the first one; null without any.
    pub fn pushRemote(self: *const Snapshot) ?[]const u8 {
        for (self.remote_names.items) |r| if (std.mem.eql(u8, r, "origin")) return r;
        return if (self.remote_names.items.len > 0) self.remote_names.items[0] else null;
    }

    /// True when a local branch named `name` exists.
    pub fn hasBranch(self: *const Snapshot, name: []const u8) bool {
        for (self.branches.items) |b| if (std.mem.eql(u8, b, name)) return true;
        return false;
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

/// Last path component ("/" for the root).
pub fn baseName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

/// Everything above the last path component ("." when there is none).
pub fn dirName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    return if (slash == 0) "/" else trimmed[0..slash];
}

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
    try std.testing.expectEqual(Kind.ignored, s.kindOf("zig-out/bin/tt", false));
    try std.testing.expectEqual(Kind.ignored, s.kindOf(".git/HEAD", false));
    // Absolute paths map through the root.
    try std.testing.expectEqual(Kind.modified, s.kindOfPath("/r/README.md", false));
    try std.testing.expectEqual(Kind.none, s.kindOfPath("/elsewhere/README.md", false));
    try std.testing.expect(s.contains("/r/src"));
    try std.testing.expect(!s.contains("/rr"));
}

test "refs: local and remote branches" {
    const gpa = std.testing.allocator;
    var s = try parse(gpa, "/r", "/r", "## main...origin/main\x00");
    defer s.deinit();
    try s.parseRefs("refs/heads/feature\nrefs/heads/main abc123\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/remotes/origin/topic def456\n");
    try std.testing.expectEqual(@as(usize, 2), s.branches.items.len);
    try std.testing.expectEqualStrings("feature", s.branches.items[0]);
    try std.testing.expectEqualStrings("main", s.branches.items[1]);
    try std.testing.expectEqual(@as(usize, 2), s.remotes.items.len);
    try std.testing.expectEqualStrings("origin/topic", s.remotes.items[1]);
    try std.testing.expect(s.hasBranch("main"));
    try std.testing.expect(!s.hasBranch("topic"));
    // Where to publish: origin when it is there, else the first remote.
    try std.testing.expect(s.pushRemote() == null);
    try s.parseRemotes("remote.fork.url git@github.com:me/repo.git\nremote.origin.url https://github.com/acme/repo.git\nremote.origin.fetch +refs/heads/*:refs/remotes/origin/*\n");
    try std.testing.expectEqualStrings("origin", s.pushRemote().?);
    try std.testing.expectEqual(@as(usize, 2), s.remote_names.items.len);
    try std.testing.expectEqualStrings("https://github.com/acme/repo.git", s.remoteUrl("origin").?);
    try std.testing.expect(s.remoteUrl("upstream") == null);
    var other = try parse(gpa, "/r", "/r", "## main\x00");
    defer other.deinit();
    try other.parseRemotes("remote.fork.url a:b/c\nremote.upstream.url d:e/f\n");
    try std.testing.expectEqualStrings("fork", other.pushRemote().?);
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

test "path parts" {
    try std.testing.expectEqualStrings("b.zig", baseName("a/b.zig"));
    try std.testing.expectEqualStrings("a", dirName("a/b.zig"));
    try std.testing.expectEqualStrings(".", dirName("b.zig"));
}

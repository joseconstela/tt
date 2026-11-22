//! Commits as `git log` lists them, as data. `client/git.zig` runs
//!
//!   git log -z --topo-order --decorate=full <format> …
//!
//! and `Log.append` reads what it printed: one record per commit, ended by
//! a NUL, its fields parted by the unit separator (0x1f) in the order of
//! `format`: hash, parents, author, e-mail, author time (seconds since the
//! epoch), the refs that point at it, subject. The refs come spelled in
//! full (`refs/heads/main`, `tag: refs/tags/v1`), which is what tells a
//! branch from a tag from a remote-tracking branch.
//!
//! `parseChanges` reads the files a commit touched, from
//! `git diff --raw --numstat -z`: the status letter of each from the raw
//! half, the lines added and removed from the numstat half.
const std = @import("std");

/// The `--format=` argument `Log.append` expects.
pub const format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s";
const field_sep: u8 = 0x1f;

pub const RefKind = enum { head, local, remote, tag };

/// A name pointing at a commit: a branch (`main`), a remote-tracking
/// branch (`origin/main`), a tag, or a bare `HEAD` when it is detached.
pub const Ref = struct {
    name: []const u8,
    kind: RefKind,
    /// The branch that is checked out.
    current: bool = false,
};

pub const Commit = struct {
    /// The full hash; `short()` for the seven characters shown.
    hash: []const u8,
    parents: []const []const u8,
    author: []const u8,
    email: []const u8,
    /// When it was authored, in seconds since the epoch.
    time: i64,
    refs: []const Ref,
    subject: []const u8,

    pub fn short(self: Commit) []const u8 {
        return self.hash[0..@min(7, self.hash.len)];
    }
};

/// The commits read so far, newest first. Everything a commit points at
/// lives in the log's arena and stays put until `deinit` or `clear`.
pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    commits: std.ArrayList(Commit) = .empty,

    pub fn init(gpa: std.mem.Allocator) Log {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Log) void {
        self.commits.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn clear(self: *Log) void {
        self.commits.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Adds the commits of one `git log -z` output (a page); returns how
    /// many. A record that does not parse is skipped.
    pub fn append(self: *Log, raw: []const u8) !usize {
        const gpa = self.arena.child_allocator;
        var added: usize = 0;
        var records = std.mem.splitScalar(u8, raw, 0);
        while (records.next()) |rec_raw| {
            const rec = std.mem.trim(u8, rec_raw, "\n\r");
            if (rec.len == 0) continue;
            const commit = self.parseOne(rec) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Malformed => continue,
            };
            try self.commits.append(gpa, commit);
            added += 1;
        }
        return added;
    }

    fn parseOne(self: *Log, rec: []const u8) error{ OutOfMemory, Malformed }!Commit {
        const a = self.arena.allocator();
        var fields: [7][]const u8 = undefined;
        var rest = rec;
        for (fields[0..6]) |*f| {
            const at = std.mem.indexOfScalar(u8, rest, field_sep) orelse return error.Malformed;
            f.* = rest[0..at];
            rest = rest[at + 1 ..];
        }
        // The subject is whatever is left, separators and all.
        fields[6] = rest;
        if (fields[0].len < 7) return error.Malformed;

        var parents: std.ArrayList([]const u8) = .empty;
        var ps = std.mem.tokenizeScalar(u8, fields[1], ' ');
        while (ps.next()) |p| try parents.append(a, try a.dupe(u8, p));

        return .{
            .hash = try a.dupe(u8, fields[0]),
            .parents = parents.items,
            .author = try a.dupe(u8, fields[2]),
            .email = try a.dupe(u8, fields[3]),
            .time = std.fmt.parseInt(i64, fields[4], 10) catch 0,
            .refs = try parseRefs(a, fields[5]),
            .subject = try a.dupe(u8, fields[6]),
        };
    }
};

/// `%D` with `--decorate=full`: `HEAD -> refs/heads/main,
/// refs/remotes/origin/main, tag: refs/tags/v1`. A remote's own `HEAD`
/// pointer is left out.
pub fn parseRefs(a: std.mem.Allocator, decoration: []const u8) error{OutOfMemory}![]const Ref {
    var out: std.ArrayList(Ref) = .empty;
    var parts = std.mem.splitSequence(u8, decoration, ", ");
    while (parts.next()) |part_raw| {
        var part = std.mem.trim(u8, part_raw, " ");
        if (part.len == 0) continue;
        var current = false;
        if (std.mem.startsWith(u8, part, "HEAD -> ")) {
            current = true;
            part = part["HEAD -> ".len..];
        }
        var ref: Ref = undefined;
        if (std.mem.eql(u8, part, "HEAD")) {
            ref = .{ .name = "HEAD", .kind = .head };
        } else if (std.mem.startsWith(u8, part, "tag: ")) {
            const full = part["tag: ".len..];
            const name = if (std.mem.startsWith(u8, full, "refs/tags/")) full["refs/tags/".len..] else full;
            ref = .{ .name = name, .kind = .tag };
        } else if (std.mem.startsWith(u8, part, "refs/heads/")) {
            ref = .{ .name = part["refs/heads/".len..], .kind = .local, .current = current };
        } else if (std.mem.startsWith(u8, part, "refs/remotes/")) {
            const name = part["refs/remotes/".len..];
            if (std.mem.endsWith(u8, name, "/HEAD")) continue;
            ref = .{ .name = name, .kind = .remote };
        } else if (std.mem.startsWith(u8, part, "refs/tags/")) {
            ref = .{ .name = part["refs/tags/".len..], .kind = .tag };
        } else {
            // Anything else under refs/ (notes, a stash) is not shown.
            continue;
        }
        ref.name = try a.dupe(u8, ref.name);
        try out.append(a, ref);
    }
    return out.items;
}

/// One file a commit (or a comparison of two commits) touched.
pub const Change = struct {
    /// `A`, `M`, `D`, `R` (renamed), `C` (copied), `T` (type changed).
    letter: u8,
    path: []const u8,
    /// Where a renamed or copied file came from.
    orig: ?[]const u8 = null,
    added: u32 = 0,
    removed: u32 = 0,
    /// A binary file has no line counts.
    binary: bool = false,
};

pub const Changes = struct {
    arena: std.heap.ArenaAllocator,
    files: []Change = &.{},
    added: u32 = 0,
    removed: u32 = 0,

    pub fn deinit(self: *Changes) void {
        self.arena.deinit();
    }
};

/// `git diff --raw --numstat -z`: first a record per file with its status
/// (`:100644 100644 abc def M`, then the path, or two paths for a rename),
/// then a record per file with its counts (`3<tab>1<tab>path`, or for a
/// rename `3<tab>1<tab>` followed by the two paths).
pub fn parseChanges(gpa: std.mem.Allocator, raw: []const u8) !Changes {
    var out: Changes = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer out.deinit();
    const a = out.arena.allocator();
    var files: std.ArrayList(Change) = .empty;

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |rec| {
        if (rec.len == 0) continue;
        if (rec[0] == ':') {
            const space = std.mem.lastIndexOfScalar(u8, rec, ' ') orelse continue;
            if (space + 1 >= rec.len) continue;
            const letter = rec[space + 1];
            const first = records.next() orelse break;
            var change: Change = .{ .letter = letter, .path = "" };
            if (letter == 'R' or letter == 'C') {
                const second = records.next() orelse break;
                change.orig = try a.dupe(u8, first);
                change.path = try a.dupe(u8, second);
            } else {
                change.path = try a.dupe(u8, first);
            }
            try files.append(a, change);
            continue;
        }
        // A numstat record.
        var cols = std.mem.splitScalar(u8, rec, '\t');
        const added_s = cols.next() orelse continue;
        const removed_s = cols.next() orelse continue;
        var path = cols.rest();
        if (path.len == 0) {
            // A rename: the old and the new path follow as records of their own.
            _ = records.next() orelse break;
            path = records.next() orelse break;
        }
        for (files.items) |*f| {
            if (!std.mem.eql(u8, f.path, path)) continue;
            if (std.mem.eql(u8, added_s, "-")) {
                f.binary = true;
            } else {
                f.added = std.fmt.parseInt(u32, added_s, 10) catch 0;
                f.removed = std.fmt.parseInt(u32, removed_s, 10) catch 0;
            }
            break;
        }
    }
    for (files.items) |f| {
        out.added += f.added;
        out.removed += f.removed;
    }
    out.files = files.items;
    return out;
}

/// One entry of `git stash list --format=%gd%x1f%s`, a line each.
pub const Stash = struct { name: []const u8, subject: []const u8 };

/// Lines of `<a><0x1f><b>`: used for the stash list (`stash@{0}`, subject)
/// and the remotes (`origin`, url). Slices point into `raw`.
pub fn parsePairs(gpa: std.mem.Allocator, raw: []const u8) ![]Stash {
    var out: std.ArrayList(Stash) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r");
        if (line.len == 0) continue;
        const at = std.mem.indexOfScalar(u8, line, field_sep) orelse continue;
        try out.append(gpa, .{ .name = line[0..at], .subject = line[at + 1 ..] });
    }
    return out.toOwnedSlice(gpa);
}

// ── tests ───────────────────────────────────────────────────────────────
test "a page of git log" {
    const gpa = std.testing.allocator;
    var log = Log.init(gpa);
    defer log.deinit();
    const raw = "a1f3c2d000000000000000000000000000000000\x1f9b02e71 7e94d10\x1fJose\x1fj@example.invalid\x1f1795290900\x1fHEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD\x1ffeat: retries\x00" ++
        "7e94d10000000000000000000000000000000000\x1f4c81f9b\x1fMaría Lado\x1fm@example.invalid\x1f1795287300\x1frefs/heads/feat/webhooks, tag: refs/tags/v1.8.0\x1ftest: a \x1f in the subject\x00" ++
        "broken record\x00" ++
        "e3b905c000000000000000000000000000000000\x1f\x1fRoot\x1fr@example.invalid\x1f1795000000\x1f\x1frelease: v1.8.0\x00";
    try std.testing.expectEqual(@as(usize, 3), try log.append(raw));
    const c = log.commits.items;
    try std.testing.expectEqualStrings("a1f3c2d", c[0].short());
    try std.testing.expectEqual(@as(usize, 2), c[0].parents.len);
    try std.testing.expectEqualStrings("7e94d10", c[0].parents[1]);
    try std.testing.expectEqual(@as(i64, 1795290900), c[0].time);
    try std.testing.expectEqual(@as(usize, 2), c[0].refs.len);
    try std.testing.expectEqualStrings("main", c[0].refs[0].name);
    try std.testing.expect(c[0].refs[0].current);
    try std.testing.expectEqual(RefKind.remote, c[0].refs[1].kind);
    try std.testing.expectEqualStrings("origin/main", c[0].refs[1].name);
    try std.testing.expectEqualStrings("María Lado", c[1].author);
    try std.testing.expectEqualStrings("feat/webhooks", c[1].refs[0].name);
    try std.testing.expect(!c[1].refs[0].current);
    try std.testing.expectEqual(RefKind.tag, c[1].refs[1].kind);
    try std.testing.expectEqualStrings("v1.8.0", c[1].refs[1].name);
    try std.testing.expectEqualStrings("test: a \x1f in the subject", c[1].subject);
    try std.testing.expectEqual(@as(usize, 0), c[2].parents.len);
    try std.testing.expectEqual(@as(usize, 0), c[2].refs.len);
    // A second page goes after the first.
    try std.testing.expectEqual(@as(usize, 1), try log.append("5a7742e000000000000000000000000000000000\x1f\x1fS\x1fs@example.invalid\x1f1\x1f\x1fdocs\x00"));
    try std.testing.expectEqual(@as(usize, 4), log.commits.items.len);
}

test "a detached head and refs that are not shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const refs = try parseRefs(arena.allocator(), "HEAD, refs/stash, refs/heads/topic");
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqual(RefKind.head, refs[0].kind);
    try std.testing.expectEqualStrings("topic", refs[1].name);
}

test "the files of a commit" {
    const gpa = std.testing.allocator;
    const raw = ":100644 100644 aaa bbb M\x00src/worker.js\x00" ++
        ":000000 100644 000 ccc A\x00src/sign.js\x00" ++
        ":100644 100644 ddd eee R087\x00old name.md\x00docs/new name.md\x00" ++
        ":100644 100644 fff 111 M\x00logo.png\x00" ++
        "84\t12\tsrc/worker.js\x00" ++
        "56\t0\tsrc/sign.js\x00" ++
        "18\t2\t\x00old name.md\x00docs/new name.md\x00" ++
        "-\t-\tlogo.png\x00";
    var changes = try parseChanges(gpa, raw);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 4), changes.files.len);
    try std.testing.expectEqual(@as(u8, 'M'), changes.files[0].letter);
    try std.testing.expectEqual(@as(u32, 84), changes.files[0].added);
    try std.testing.expectEqual(@as(u32, 12), changes.files[0].removed);
    try std.testing.expectEqual(@as(u8, 'A'), changes.files[1].letter);
    try std.testing.expectEqual(@as(u8, 'R'), changes.files[2].letter);
    try std.testing.expectEqualStrings("docs/new name.md", changes.files[2].path);
    try std.testing.expectEqualStrings("old name.md", changes.files[2].orig.?);
    try std.testing.expectEqual(@as(u32, 18), changes.files[2].added);
    try std.testing.expect(changes.files[3].binary);
    try std.testing.expectEqual(@as(u32, 158), changes.added);
    try std.testing.expectEqual(@as(u32, 14), changes.removed);
}

test "stash list lines" {
    const gpa = std.testing.allocator;
    const pairs = try parsePairs(gpa, "stash@{0}\x1fWIP on main: abc feat\nstash@{1}\x1fOn topic: try\n\n");
    defer gpa.free(pairs);
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("stash@{1}", pairs[1].name);
    try std.testing.expectEqualStrings("On topic: try", pairs[1].subject);
}

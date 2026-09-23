//! The files a quick-open query (⌘P, "Go to File…") searches: everything
//! under the workspace roots — the project the current tab works in (or
//! its git repository, or just its folder) and the other projects — listed
//! once, on a thread of its own, when the palette opens. A git repository
//! lists what git tracks or would track (`git ls-files`, so ignored files
//! and `.git` stay out, as in VS Code); any other folder is walked, hidden
//! entries and `node_modules` skipped, up to a cap.
//!
//! Also the parser of VS Code's `path:line:col` suffix, shared with the
//! palette's go-to-line scope.
const std = @import("std");
const sys = @import("sys.zig");
const match = @import("match.zig");

pub const max_files = 50_000;
const max_depth = 12;
const git_env = [_][]const u8{ "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };

pub const Root = struct {
    /// Absolute directory, no trailing slash.
    path: []const u8,
    /// The project's name (its folder name otherwise), shown next to a
    /// file's folder when there is more than one root.
    name: []const u8,
    /// A plain folder: when it is inside a git repository, list the whole
    /// repository instead (the listing thread finds out).
    widen_to_repo: bool = false,
};

pub const File = struct {
    /// Path relative to its root.
    rel: []const u8,
    root: u16,
    /// Folders above the file (the count of '/').
    depth: u8,
};

/// A match of a query: the file, how well it matched and which code
/// points of its name did (for the bold highlights; 0 when the path
/// matched but the name did not).
pub const Hit = struct { index: u32, score: i32, mask: u64 };

/// A `:line:col` suffix; 0 = not given.
pub const Goto = struct { line: u32 = 0, col: u32 = 0 };

pub const Split = struct {
    /// The query without the suffix.
    text: []const u8,
    /// Null when there was no suffix at all; a suffix with no digits yet
    /// (`name:`) gives `.{}`.
    goto: ?Goto,
};

/// Splits "src/app.zig:12:5" into "src/app.zig" and line 12, column 5. The
/// suffix is the first ':' whose rest is digits, optionally followed by
/// ':' or ',' and more digits — so a query of ":40" is all suffix, and
/// "a:b" is just a name.
pub fn splitGoto(q: []const u8) Split {
    var i: usize = 0;
    while (i < q.len) : (i += 1) {
        if (q[i] != ':') continue;
        const rest = q[i + 1 ..];
        if (parseGoto(rest)) |g| return .{ .text = std.mem.trim(u8, q[0..i], " "), .goto = g };
    }
    return .{ .text = std.mem.trim(u8, q, " "), .goto = null };
}

/// The part after the ":" of a suffix: "12", "12:5", "12,5", "".
pub fn parseGoto(rest: []const u8) ?Goto {
    var g: Goto = .{};
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) g.line = g.line *| 10 +| (rest[i] - '0');
    if (i == rest.len) return g;
    if (rest[i] != ':' and rest[i] != ',') return null;
    i += 1;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) g.col = g.col *| 10 +| (rest[i] - '0');
    if (i != rest.len) return null;
    return g;
}

/// The listing. Shared between the palette and the listing thread: both
/// hold a reference, the last one to `release` frees it, so the palette
/// can close while a big repository is still being listed.
pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    roots: std.ArrayList(Root) = .empty,
    files: std.ArrayList(File) = .empty,
    /// True when the cap cut a listing short.
    truncated: bool = false,
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn create(gpa: std.mem.Allocator) !*Index {
        const self = try gpa.create(Index);
        self.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        return self;
    }

    fn destroy(self: *Index) void {
        self.roots.deinit(self.gpa);
        self.files.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Drops one holder's reference; the last one frees the index.
    pub fn release(self: *Index) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    /// Adds a root, before `start`. The same folder twice is one root.
    pub fn addRoot(self: *Index, path: []const u8, name: []const u8) !void {
        const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
        for (self.roots.items) |r| if (std.mem.eql(u8, r.path, trimmed)) return;
        const a = self.arena.allocator();
        const own_name = if (name.len > 0) name else sys.basename(trimmed);
        try self.roots.append(self.gpa, .{ .path = try a.dupe(u8, trimmed), .name = try a.dupe(u8, own_name) });
    }

    /// Lists the roots on a thread (inline when one cannot be started).
    /// `ready` says when the files can be read.
    pub fn start(self: *Index) void {
        self.refs.store(2, .release);
        const t = std.Thread.spawn(.{}, build, .{self}) catch {
            build(self);
            return;
        };
        t.detach();
    }

    pub fn ready(self: *const Index) bool {
        return self.done.load(.acquire);
    }

    fn build(self: *Index) void {
        defer self.release();
        for (self.roots.items) |*r| {
            if (r.widen_to_repo) self.widen(r);
        }
        for (self.roots.items, 0..) |r, i| {
            if (self.files.items.len >= max_files) break;
            if (!self.listGit(@intCast(i), r.path)) self.walk(@intCast(i), r.path, "", 0);
        }
        // Shallow files first within a root, then by name: what an empty
        // query shows, and the order equal scores keep.
        std.mem.sort(File, self.files.items, {}, fileLessThan);
        self.done.store(true, .release);
    }

    /// Replaces a folder inside a git repository by the repository's top.
    fn widen(self: *Index, r: *Root) void {
        var res = sys.run(self.gpa, r.path, &.{ "git", "rev-parse", "--show-toplevel" }, &git_env) catch return;
        defer res.deinit();
        if (!res.ok()) return;
        const top = std.mem.trim(u8, res.stdout, " \r\n\t");
        if (top.len == 0 or std.mem.eql(u8, top, r.path)) return;
        const a = self.arena.allocator();
        r.path = a.dupe(u8, top) catch return;
        r.name = a.dupe(u8, sys.basename(top)) catch return;
    }

    /// `git ls-files`: tracked and untracked files that are not ignored,
    /// relative to `root` (a folder inside a repository lists only what is
    /// under it). False when `root` is not in a repository.
    fn listGit(self: *Index, root_i: u16, root: []const u8) bool {
        var res = sys.run(self.gpa, root, &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" }, &git_env) catch return false;
        defer res.deinit();
        if (!res.ok()) return false;
        const a = self.arena.allocator();
        var it = std.mem.splitScalar(u8, res.stdout, 0);
        while (it.next()) |rel| {
            if (rel.len == 0) continue;
            if (self.files.items.len >= max_files) {
                self.truncated = true;
                break;
            }
            const own = a.dupe(u8, rel) catch return true;
            self.files.append(self.gpa, .{ .rel = own, .root = root_i, .depth = depthOf(own) }) catch return true;
        }
        return true;
    }

    const Named = struct { name: []u8, is_dir: bool };

    fn walk(self: *Index, root_i: u16, root: []const u8, rel_dir: []const u8, depth: u8) void {
        if (self.files.items.len >= max_files or depth > max_depth) return;
        var path_buf: [1024]u8 = undefined;
        const dir = if (rel_dir.len == 0) root else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel_dir }) catch return;

        const Collector = struct {
            gpa: std.mem.Allocator,
            out: std.ArrayList(Named) = .empty,
            fn visit(c: *@This(), e: sys.DirEntry) void {
                if (e.name.len == 0 or e.name[0] == '.') return;
                if (e.is_dir and std.mem.eql(u8, e.name, "node_modules")) return;
                const name = c.gpa.dupe(u8, e.name) catch return;
                c.out.append(c.gpa, .{ .name = name, .is_dir = e.is_dir }) catch c.gpa.free(name);
            }
        };
        var col = Collector{ .gpa = self.gpa };
        defer {
            for (col.out.items) |n| self.gpa.free(n.name);
            col.out.deinit(self.gpa);
        }
        sys.listDir(self.gpa, dir, &col, Collector.visit);
        std.mem.sort(Named, col.out.items, {}, namedLessThan);

        const a = self.arena.allocator();
        for (col.out.items) |n| {
            if (self.files.items.len >= max_files) {
                self.truncated = true;
                return;
            }
            const rel = if (rel_dir.len == 0) a.dupe(u8, n.name) catch return else std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, n.name }) catch return;
            if (n.is_dir) {
                self.walk(root_i, root, rel, depth + 1);
            } else {
                self.files.append(self.gpa, .{ .rel = rel, .root = root_i, .depth = depth }) catch return;
            }
        }
    }

    /// The absolute path of a file, in `buf`.
    pub fn absPath(self: *const Index, index: usize, buf: []u8) ?[]const u8 {
        if (index >= self.files.items.len) return null;
        const f = self.files.items[index];
        const root = self.roots.items[f.root].path;
        if (std.mem.eql(u8, root, "/")) return std.fmt.bufPrint(buf, "/{s}", .{f.rel}) catch null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, f.rel }) catch null;
    }

    /// The folder part of a file's relative path ("" at the root).
    pub fn folderOf(f: File) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, f.rel, '/') orelse return "";
        return f.rel[0..slash];
    }

    /// The best matches of `q`, best first, at most `out.len` of them. An
    /// empty query lists the first files in index order.
    pub fn search(self: *const Index, q: []const u8, out: []Hit) usize {
        const files = self.files.items;
        if (q.len == 0) {
            const n = @min(out.len, files.len);
            for (0..n) |i| out[i] = .{ .index = @intCast(i), .score = 0, .mask = 0 };
            return n;
        }
        const in_path = std.mem.indexOfScalar(u8, q, '/') != null;
        var n: usize = 0;
        for (files, 0..) |f, i| {
            var mask: u64 = 0;
            const s = scoreFile(q, f, in_path, &mask) orelse continue;
            if (n == out.len and s <= out[n - 1].score) continue;
            var j = if (n < out.len) n else n - 1;
            if (n < out.len) n += 1;
            while (j > 0 and out[j - 1].score < s) : (j -= 1) out[j] = out[j - 1];
            out[j] = .{ .index = @intCast(i), .score = s, .mask = mask };
        }
        return n;
    }
};

/// A query without '/' is matched against the name first (with a bonus,
/// more when the name starts with or is the query), then against the whole
/// relative path; deeper files lose a little either way.
fn scoreFile(q: []const u8, f: File, in_path: bool, mask: *u64) ?i32 {
    const name = sys.basename(f.rel);
    const depth_pen: i32 = @intCast(@min(f.depth, 8));
    if (!in_path) {
        if (match.fuzzy(q, name, mask)) |s| {
            var bonus: i32 = 24;
            if (std.ascii.eqlIgnoreCase(name, q)) {
                bonus += 16;
            } else if (name.len > q.len and std.ascii.eqlIgnoreCase(name[0..q.len], q)) {
                bonus += 8;
            }
            return s + bonus - depth_pen;
        }
    }
    var m: u64 = 0;
    if (match.fuzzy(q, f.rel, &m)) |s| {
        mask.* = 0;
        return s - depth_pen - 4;
    }
    return null;
}

fn depthOf(rel: []const u8) u8 {
    var d: usize = 0;
    for (rel) |c| d += @intFromBool(c == '/');
    return @intCast(@min(d, 255));
}

fn lessIgnoreCase(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.len < b.len;
}

fn fileLessThan(_: void, a: File, b: File) bool {
    if (a.root != b.root) return a.root < b.root;
    if (a.depth != b.depth) return a.depth < b.depth;
    return lessIgnoreCase(a.rel, b.rel);
}

fn namedLessThan(_: void, a: Index.Named, b: Index.Named) bool {
    return lessIgnoreCase(a.name, b.name);
}

// ── tests ────────────────────────────────────────────────────────────────
test "splitGoto takes a :line:col suffix and leaves other colons alone" {
    var s = splitGoto("src/app.zig:12:5");
    try std.testing.expectEqualStrings("src/app.zig", s.text);
    try std.testing.expectEqual(@as(u32, 12), s.goto.?.line);
    try std.testing.expectEqual(@as(u32, 5), s.goto.?.col);

    s = splitGoto("app:40");
    try std.testing.expectEqualStrings("app", s.text);
    try std.testing.expectEqual(@as(u32, 40), s.goto.?.line);
    try std.testing.expectEqual(@as(u32, 0), s.goto.?.col);

    s = splitGoto("app:40,3");
    try std.testing.expectEqual(@as(u32, 3), s.goto.?.col);

    s = splitGoto(":7");
    try std.testing.expectEqualStrings("", s.text);
    try std.testing.expectEqual(@as(u32, 7), s.goto.?.line);

    s = splitGoto("name:");
    try std.testing.expectEqualStrings("name", s.text);
    try std.testing.expectEqual(@as(u32, 0), s.goto.?.line);

    s = splitGoto("a:b");
    try std.testing.expectEqualStrings("a:b", s.text);
    try std.testing.expect(s.goto == null);

    s = splitGoto("a:b:12");
    try std.testing.expectEqualStrings("a:b", s.text);
    try std.testing.expectEqual(@as(u32, 12), s.goto.?.line);

    s = splitGoto("readme");
    try std.testing.expect(s.goto == null);
}

test "search ranks name hits over path hits and prefixes over scattered" {
    const gpa = std.testing.allocator;
    const ix = try Index.create(gpa);
    defer ix.release();
    try ix.addRoot("/repo", "repo");
    const a = ix.arena.allocator();
    const rels = [_][]const u8{ "README.md", "src/app.zig", "src/ui/palette.zig", "src/paths.zig", "src/ui/panes.zig", "docs/plan/notes.txt" };
    for (rels) |r| try ix.files.append(gpa, .{ .rel = try a.dupe(u8, r), .root = 0, .depth = depthOf(r) });
    std.mem.sort(File, ix.files.items, {}, fileLessThan);
    ix.done.store(true, .release);

    var hits: [8]Hit = undefined;
    var n = ix.search("pal", &hits);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqualStrings("src/ui/palette.zig", ix.files.items[hits[0].index].rel);
    try std.testing.expectEqual(@as(u64, 0b111), hits[0].mask);

    // A slash in the query matches the path only, no highlights on the name.
    n = ix.search("ui/pan", &hits);
    try std.testing.expectEqualStrings("src/ui/panes.zig", ix.files.items[hits[0].index].rel);
    try std.testing.expectEqual(@as(u64, 0), hits[0].mask);

    // Shallow files come first for an empty query.
    n = ix.search("", &hits);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("README.md", ix.files.items[hits[0].index].rel);

    // The top-N window keeps the best when there are more hits than room.
    var two: [2]Hit = undefined;
    n = ix.search("s", &two);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(two[0].score >= two[1].score);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/repo/README.md", ix.absPath(hits[0].index, &buf).?);
    try std.testing.expectEqualStrings("src/ui", Index.folderOf(ix.files.items[hits[5].index]));
}

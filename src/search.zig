//! Find in files, for the files panel's Search view: the matcher (plain
//! text or a POSIX extended regex through libc, with VS Code's match-case
//! / whole-word switches), the include / exclude globs, the walk over a
//! folder on a thread of its own, and the replace that rewrites files.
//! Inside a git repository the files come from `git ls-files` so ignored
//! folders (build output, node_modules …) are left alone, as VS Code's
//! "use ignore files" does; elsewhere the folder is walked, skipping the
//! usual VCS folders. The matching, globs and previews are pure and tested.
const std = @import("std");
const c = std.c;
const sys = @import("sys.zig");

/// VS Code's `search.maxResults`: the view stops here and says so.
pub const max_matches: u32 = 20_000;
/// Files bigger than this are not opened.
pub const max_file_bytes: usize = 8 * 1024 * 1024;
/// A NUL in the first bytes makes a file binary: skipped.
const sniff_bytes: usize = 8192;
/// A match further into its line than this gets a preview that starts
/// shortly before it, with an ellipsis.
const preview_lead: usize = 24;
const preview_before: usize = 16;
const preview_max: usize = 200;

pub const Options = struct {
    match_case: bool = false,
    whole_word: bool = false,
    regex: bool = false,
};

/// What a search is asked with. `include` / `exclude` are comma-separated
/// glob lists ("*.zig, src/**", "node_modules").
pub const Query = struct {
    text: []const u8,
    include: []const u8 = "",
    exclude: []const u8 = "",
    opts: Options = .{},
};

// ── the matcher ─────────────────────────────────────────────────────────
const regex_t = extern struct { re_magic: c_int, re_nsub: usize, re_endp: ?[*]const u8, re_g: ?*anyopaque };
const regmatch_t = extern struct { rm_so: i64, rm_eo: i64 };
extern "c" fn regcomp(preg: *regex_t, pattern: [*:0]const u8, cflags: c_int) c_int;
extern "c" fn regnexec(preg: *const regex_t, str: [*]const u8, len: usize, nmatch: usize, pmatch: [*]regmatch_t, eflags: c_int) c_int;
extern "c" fn regerror(code: c_int, preg: *const regex_t, buf: [*]u8, size: usize) usize;
extern "c" fn regfree(preg: *regex_t) void;
const REG_EXTENDED: c_int = 1;
const REG_ICASE: c_int = 2;
const REG_NOTBOL: c_int = 1;

pub const max_groups = 10;

/// One match in a line: byte offsets, and the regex groups (`$1` …).
pub const Span = struct {
    start: usize,
    end: usize,
    groups: [max_groups]?[2]usize = [_]?[2]usize{null} ** max_groups,
};

pub const Matcher = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    /// The text looked for; lowercased when case does not matter.
    needle: []u8,
    re: regex_t = undefined,
    has_re: bool = false,

    pub const Error = error{ EmptyPattern, BadPattern, OutOfMemory };

    pub fn init(gpa: std.mem.Allocator, text: []const u8, opts: Options) Error!Matcher {
        if (text.len == 0) return error.EmptyPattern;
        var self: Matcher = .{ .gpa = gpa, .opts = opts, .needle = try gpa.dupe(u8, text) };
        errdefer gpa.free(self.needle);
        if (opts.regex) {
            const pat = try gpa.dupeZ(u8, text);
            defer gpa.free(pat);
            const flags = REG_EXTENDED | (if (opts.match_case) 0 else REG_ICASE);
            if (regcomp(&self.re, pat.ptr, flags) != 0) return error.BadPattern;
            self.has_re = true;
        } else if (!opts.match_case) {
            for (self.needle) |*ch| ch.* = std.ascii.toLower(ch.*);
        }
        return self;
    }

    pub fn deinit(self: *Matcher) void {
        if (self.has_re) regfree(&self.re);
        self.gpa.free(self.needle);
    }

    /// What is wrong with `text` as a regex, into `buf` (empty when it compiles).
    pub fn regexProblem(gpa: std.mem.Allocator, text: []const u8, buf: []u8) []const u8 {
        if (text.len == 0) return "";
        const pat = gpa.dupeZ(u8, text) catch return "";
        defer gpa.free(pat);
        var re: regex_t = undefined;
        const code = regcomp(&re, pat.ptr, REG_EXTENDED);
        if (code == 0) {
            regfree(&re);
            return "";
        }
        const n = regerror(code, &re, buf.ptr, buf.len);
        // regerror counts the NUL; the message may also have been cut.
        return buf[0..@min(n -| 1, buf.len)];
    }

    /// The first match in `line` at or after `from` (whole-word and
    /// empty matches filtered), or null.
    pub fn find(self: *const Matcher, line: []const u8, from_in: usize) ?Span {
        var from = from_in;
        while (from <= line.len) {
            const sp = self.findRaw(line, from) orelse return null;
            if (sp.end <= sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (!self.opts.whole_word or wordBounded(line, sp.start, sp.end)) return sp;
            from = sp.start + 1;
        }
        return null;
    }

    fn findRaw(self: *const Matcher, line: []const u8, from: usize) ?Span {
        if (!self.has_re) {
            const at = if (self.opts.match_case)
                std.mem.indexOfPos(u8, line, from, self.needle)
            else
                indexOfIgnoreCasePos(line, from, self.needle);
            const s = at orelse return null;
            return .{ .start = s, .end = s + self.needle.len };
        }
        var m: [max_groups]regmatch_t = undefined;
        const rest = line[from..];
        const flags: c_int = if (from > 0) REG_NOTBOL else 0;
        if (regnexec(&self.re, rest.ptr, rest.len, max_groups, &m, flags) != 0) return null;
        if (m[0].rm_so < 0) return null;
        var sp: Span = .{ .start = from + @as(usize, @intCast(m[0].rm_so)), .end = from + @as(usize, @intCast(m[0].rm_eo)) };
        for (m, 0..) |g, i| {
            if (g.rm_so < 0 or g.rm_eo < g.rm_so) continue;
            sp.groups[i] = .{ from + @as(usize, @intCast(g.rm_so)), from + @as(usize, @intCast(g.rm_eo)) };
        }
        return sp;
    }
};

fn indexOfIgnoreCasePos(hay: []const u8, from: usize, needle_lower: []const u8) ?usize {
    if (needle_lower.len == 0) return from;
    if (hay.len < needle_lower.len) return null;
    var i = from;
    const last = hay.len - needle_lower.len;
    while (i <= last) : (i += 1) {
        var k: usize = 0;
        while (k < needle_lower.len and std.ascii.toLower(hay[i + k]) == needle_lower[k]) k += 1;
        if (k == needle_lower.len) return i;
    }
    return null;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// VS Code's whole-word rule: no word character continues the match on
/// either side (a match that itself ends in punctuation is fine there).
fn wordBounded(line: []const u8, s: usize, e: usize) bool {
    const left_ok = s == 0 or !isWord(line[s - 1]) or !isWord(line[s]);
    const right_ok = e >= line.len or !isWord(line[e]) or !isWord(line[e - 1]);
    return left_ok and right_ok;
}

// ── globs ───────────────────────────────────────────────────────────────
/// True when `rel` (a root-relative path) is covered by any pattern of the
/// comma-separated list: a pattern without `/` is tried against every
/// path segment ("*.zig", "node_modules"); one with `/` against the path
/// and each of its folders ("src/**/*.zig", "docs" + everything in it).
/// `*` and `?` stay within a segment, `**` spans folders.
pub fn matchesAny(patterns: []const u8, rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, patterns, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (globMatch(p, rel)) return true;
    }
    return false;
}

pub fn globMatch(pattern_in: []const u8, rel: []const u8) bool {
    var pattern = pattern_in;
    if (std.mem.startsWith(u8, pattern, "./")) pattern = pattern[2..];
    pattern = std.mem.trim(u8, pattern, "/");
    if (pattern.len == 0) return false;
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        var segs = std.mem.splitScalar(u8, rel, '/');
        while (segs.next()) |s| if (segMatch(pattern, s)) return true;
        return false;
    }
    var ps: [64][]const u8 = undefined;
    var ss: [64][]const u8 = undefined;
    const np = splitSegs(pattern, &ps) orelse return false;
    const ns = splitSegs(rel, &ss) orelse return false;
    // The path itself, or any folder above it.
    var k: usize = 1;
    while (k <= ns) : (k += 1) {
        if (pathMatch(ps[0..np], ss[0..k])) return true;
    }
    return false;
}

fn splitSegs(s: []const u8, out: *[64][]const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n == out.len) return null;
        out[n] = seg;
        n += 1;
    }
    return n;
}

fn pathMatch(p: []const []const u8, s: []const []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.eql(u8, p[0], "**")) {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (pathMatch(p[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    return segMatch(p[0], s[0]) and pathMatch(p[1..], s[1..]);
}

/// `*` and `?` within one path segment.
fn segMatch(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < p.len and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            star_s = si;
            pi += 1;
        } else if (star) |st| {
            pi = st + 1;
            star_s += 1;
            si = star_s;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

/// Whether the query's include / exclude lists let `rel` through.
pub fn wanted(q: Query, rel: []const u8) bool {
    if (q.include.len > 0 and !matchesAny(q.include, rel)) return false;
    if (q.exclude.len > 0 and matchesAny(q.exclude, rel)) return false;
    return true;
}

// ── results ─────────────────────────────────────────────────────────────
/// One match: where it is in the file, and its preview (a slice of
/// `Results.text`, the match highlighted at `hl`).
pub const Match = struct {
    /// 0-based line, byte column and length.
    line: u32,
    col: u32,
    len: u32,
    preview: u32,
    preview_len: u32,
    hl: u32,
    hl_len: u32,
};

pub const FileHit = struct {
    /// Relative to the folder searched.
    rel: []u8,
    matches: std.ArrayList(Match) = .empty,
    /// Unfolded in the view.
    open: bool = true,
};

pub const Results = struct {
    gpa: std.mem.Allocator,
    files: std.ArrayList(FileHit) = .empty,
    /// The previews, back to back.
    text: std.ArrayList(u8) = .empty,
    match_count: u32 = 0,
    /// The cap was hit: there is more than this.
    truncated: bool = false,
    /// How many files were read.
    scanned: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Results {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Results) void {
        for (self.files.items) |*f| {
            self.gpa.free(f.rel);
            f.matches.deinit(self.gpa);
        }
        self.files.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.* = init(self.gpa);
    }

    pub fn preview(self: *const Results, m: Match) []const u8 {
        return self.text.items[m.preview..][0..m.preview_len];
    }

    /// Takes a file out of the view (the results only, nothing on disk).
    pub fn removeFile(self: *Results, i: usize) void {
        if (i >= self.files.items.len) return;
        var f = self.files.orderedRemove(i);
        self.match_count -= @intCast(f.matches.items.len);
        self.gpa.free(f.rel);
        f.matches.deinit(self.gpa);
    }

    pub fn removeMatch(self: *Results, fi: usize, mi: usize) void {
        if (fi >= self.files.items.len) return;
        const f = &self.files.items[fi];
        if (mi >= f.matches.items.len) return;
        _ = f.matches.orderedRemove(mi);
        self.match_count -= 1;
        if (f.matches.items.len == 0) self.removeFile(fi);
    }

    /// Appends a file's matches over `data`; false once the cap is hit.
    /// The hit is only kept when something matched.
    pub fn scan(self: *Results, rel: []const u8, matcher: *const Matcher, data: []const u8) bool {
        var hit: FileHit = .{ .rel = self.gpa.dupe(u8, rel) catch return false };
        var more = true;
        var line_no: u32 = 0;
        var pos: usize = 0;
        outer: while (true) : (line_no += 1) {
            const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
            var line = data[pos..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            var from: usize = 0;
            while (matcher.find(line, from)) |sp| {
                if (self.match_count >= max_matches) {
                    self.truncated = true;
                    more = false;
                    break :outer;
                }
                self.addMatch(&hit, line_no, line, sp);
                from = sp.end;
            }
            if (nl == data.len) break;
            pos = nl + 1;
        }
        if (hit.matches.items.len == 0) {
            self.gpa.free(hit.rel);
            hit.matches.deinit(self.gpa);
        } else {
            self.files.append(self.gpa, hit) catch {
                self.gpa.free(hit.rel);
                hit.matches.deinit(self.gpa);
            };
        }
        return more;
    }

    fn addMatch(self: *Results, hit: *FileHit, line_no: u32, line: []const u8, sp: Span) void {
        var start: usize = 0;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
        var dots = false;
        if (sp.start > start + preview_lead) {
            start = utf8Back(line, sp.start - preview_before);
            dots = true;
        }
        var end = @min(line.len, start + preview_max);
        if (end < line.len) end = utf8Back(line, end);
        if (end < sp.start) end = @min(line.len, sp.start);
        const off = self.text.items.len;
        if (dots) self.text.appendSlice(self.gpa, "…") catch return;
        const hl_at = self.text.items.len - off + (sp.start - start);
        for (line[start..end]) |ch| self.text.append(self.gpa, if (ch < 0x20) ' ' else ch) catch return;
        const hl_end = @min(sp.end, end);
        hit.matches.append(self.gpa, .{
            .line = line_no,
            .col = @intCast(sp.start),
            .len = @intCast(sp.end - sp.start),
            .preview = @intCast(off),
            .preview_len = @intCast(self.text.items.len - off),
            .hl = @intCast(hl_at),
            .hl_len = @intCast(hl_end -| sp.start),
        }) catch return;
        self.match_count += 1;
    }
};

fn utf8Back(s: []const u8, pos_in: usize) usize {
    var pos = @min(pos_in, s.len);
    while (pos > 0 and pos < s.len and (s[pos] & 0xC0) == 0x80) pos -= 1;
    return pos;
}

// ── the job: one search over a folder, on its own thread ────────────────
pub const Job = struct {
    gpa: std.mem.Allocator,
    dir: []u8,
    text: []u8,
    include: []u8,
    exclude: []u8,
    opts: Options,
    /// Ask git for the files (the folder is inside a repository).
    use_git: bool,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    results: Results,
    /// What went wrong with the pattern, if anything.
    err_buf: [128]u8 = undefined,
    err_len: usize = 0,
    /// Scratch for the walk (relative path of the entry on hand).
    rel: std.ArrayList(u8) = .empty,
    full: std.ArrayList(u8) = .empty,

    pub fn create(gpa: std.mem.Allocator, dir: []const u8, q: Query, use_git: bool) !*Job {
        const self = try gpa.create(Job);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .dir = try gpa.dupe(u8, dir),
            .text = try gpa.dupe(u8, q.text),
            .include = try gpa.dupe(u8, q.include),
            .exclude = try gpa.dupe(u8, q.exclude),
            .opts = q.opts,
            .use_git = use_git,
            .results = Results.init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Job) void {
        const gpa = self.gpa;
        self.results.deinit();
        self.rel.deinit(gpa);
        self.full.deinit(gpa);
        gpa.free(self.dir);
        gpa.free(self.text);
        gpa.free(self.include);
        gpa.free(self.exclude);
        gpa.destroy(self);
    }

    pub fn err(self: *const Job) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn query(self: *const Job) Query {
        return .{ .text = self.text, .include = self.include, .exclude = self.exclude, .opts = self.opts };
    }

    pub fn run(self: *Job) void {
        defer self.done.store(true, .release);
        var matcher = Matcher.init(self.gpa, self.text, self.opts) catch |e| {
            const msg: []const u8 = switch (e) {
                error.BadPattern => blk: {
                    var buf: [96]u8 = undefined;
                    const why = Matcher.regexProblem(self.gpa, self.text, &buf);
                    break :blk std.fmt.bufPrint(&self.err_buf, "Invalid regex: {s}", .{why}) catch "Invalid regex";
                },
                else => "",
            };
            if (msg.ptr != &self.err_buf) _ = std.fmt.bufPrint(&self.err_buf, "{s}", .{msg}) catch {};
            self.err_len = msg.len;
            return;
        };
        defer matcher.deinit();
        if (self.use_git and self.viaGit(&matcher)) return;
        self.walk(&matcher);
    }

    /// The files git knows or does not ignore, relative to the folder.
    /// False when git could not say (then the folder is walked).
    fn viaGit(self: *Job, matcher: *const Matcher) bool {
        var res = sys.run(self.gpa, self.dir, &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" }, &.{}) catch return false;
        defer res.deinit();
        if (!res.ok()) return false;
        var it = std.mem.splitScalar(u8, res.stdout, 0);
        while (it.next()) |rel| {
            if (rel.len == 0 or skippedPath(rel)) continue;
            if (self.cancel.load(.acquire)) return true;
            if (!self.scanFile(matcher, rel)) return true;
        }
        return true;
    }

    const Entry = struct { name: []u8, is_dir: bool };

    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        const n = @min(a.name.len, b.name.len);
        for (a.name[0..n], b.name[0..n]) |x, y| {
            const lx = std.ascii.toLower(x);
            const ly = std.ascii.toLower(y);
            if (lx != ly) return lx < ly;
        }
        return a.name.len < b.name.len;
    }

    /// VS Code's default excludes: left alone even when git tracks them.
    fn skipped(name: []const u8) bool {
        const names = [_][]const u8{ ".git", ".svn", ".hg", "node_modules", "bower_components", ".DS_Store" };
        for (names) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }

    fn skippedPath(rel: []const u8) bool {
        var segs = std.mem.splitScalar(u8, rel, '/');
        while (segs.next()) |seg| if (skipped(seg)) return true;
        return false;
    }

    /// Walks the folder, symlinks and VCS folders left alone.
    fn walk(self: *Job, matcher: *const Matcher) void {
        self.rel.clearRetainingCapacity();
        _ = self.walkDir(matcher, 0);
    }

    /// False once the search is over (cancelled or capped).
    fn walkDir(self: *Job, matcher: *const Matcher, depth: u32) bool {
        if (depth > 48) return true;
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |e| self.gpa.free(e.name);
            entries.deinit(self.gpa);
        }
        {
            const path = self.fullPath(self.rel.items) orelse return true;
            const dir = c.opendir(path) orelse return true;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const name = ent.name[0..ent.namlen];
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (ent.type == 10 or skipped(name)) continue; // DT_LNK
                const owned = self.gpa.dupe(u8, name) catch continue;
                entries.append(self.gpa, .{ .name = owned, .is_dir = ent.type == 4 }) catch self.gpa.free(owned);
            }
        }
        std.mem.sort(Entry, entries.items, {}, entryLessThan);
        for (entries.items) |e| {
            if (self.cancel.load(.acquire)) return false;
            const parent_len = self.rel.items.len;
            if (parent_len > 0) self.rel.append(self.gpa, '/') catch return false;
            self.rel.appendSlice(self.gpa, e.name) catch return false;
            defer self.rel.items.len = parent_len;
            if (e.is_dir) {
                if (!self.walkDir(matcher, depth + 1)) return false;
            } else if (!self.scanFile(matcher, self.rel.items)) return false;
        }
        return true;
    }

    fn fullPath(self: *Job, rel: []const u8) ?[*:0]const u8 {
        self.full.clearRetainingCapacity();
        self.full.appendSlice(self.gpa, self.dir) catch return null;
        if (rel.len > 0) {
            if (!std.mem.endsWith(u8, self.dir, "/")) self.full.append(self.gpa, '/') catch return null;
            self.full.appendSlice(self.gpa, rel) catch return null;
        }
        self.full.append(self.gpa, 0) catch return null;
        return @ptrCast(self.full.items.ptr);
    }

    /// Reads one file and collects its matches; false once the cap is hit.
    fn scanFile(self: *Job, matcher: *const Matcher, rel: []const u8) bool {
        if (!wanted(self.query(), rel)) return true;
        _ = self.fullPath(rel) orelse return true;
        const path = self.full.items[0 .. self.full.items.len - 1];
        const st = sys.statFile(self.gpa, path) orelse return true;
        if (st.size > max_file_bytes) return true;
        const head = sys.readFileHead(self.gpa, path, max_file_bytes) catch return true;
        defer if (head.data.len > 0) self.gpa.free(head.data);
        if (std.mem.indexOfScalar(u8, head.data[0..@min(head.data.len, sniff_bytes)], 0) != null) return true;
        self.results.scanned += 1;
        return self.results.scan(rel, matcher, head.data);
    }
};

/// Runs searches one at a time on a thread and hands the results over
/// when they are in; a new search cancels the one under way.
pub const Searcher = struct {
    gpa: std.mem.Allocator,
    job: ?*Job = null,
    thread: ?std.Thread = null,
    /// Cancelled jobs whose threads have not finished yet.
    stale: std.ArrayList(*Job) = .empty,
    stale_threads: std.ArrayList(std.Thread) = .empty,
    results: Results,
    /// The pattern problem of the last search, if any.
    err_buf: [128]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Searcher {
        return .{ .gpa = gpa, .results = Results.init(gpa) };
    }

    pub fn deinit(self: *Searcher) void {
        self.cancel();
        for (self.stale.items, self.stale_threads.items) |job, t| {
            t.join();
            job.destroy();
        }
        self.stale.deinit(self.gpa);
        self.stale_threads.deinit(self.gpa);
        self.results.deinit();
    }

    pub fn busy(self: *const Searcher) bool {
        return self.job != null;
    }

    pub fn err(self: *const Searcher) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// Starts a search of `dir`; whatever was running is dropped.
    pub fn start(self: *Searcher, dir: []const u8, q: Query, use_git: bool) void {
        self.cancel();
        const job = Job.create(self.gpa, dir, q, use_git) catch return;
        self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            job.destroy();
            return;
        };
        self.job = job;
    }

    /// Stops the search under way (the results on show stay).
    pub fn cancel(self: *Searcher) void {
        const job = self.job orelse return;
        job.cancel.store(true, .release);
        self.stale.append(self.gpa, job) catch {};
        self.stale_threads.append(self.gpa, self.thread.?) catch {};
        self.job = null;
        self.thread = null;
    }

    /// Stops and forgets everything.
    pub fn clear(self: *Searcher) void {
        self.cancel();
        self.results.deinit();
        self.err_len = 0;
    }

    /// Collects a finished search. True when the results changed.
    pub fn tick(self: *Searcher) bool {
        var i: usize = 0;
        while (i < self.stale.items.len) {
            const job = self.stale.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            self.stale_threads.items[i].join();
            job.destroy();
            _ = self.stale.swapRemove(i);
            _ = self.stale_threads.swapRemove(i);
        }
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        self.thread.?.join();
        self.thread = null;
        self.job = null;
        defer job.destroy();
        self.results.deinit();
        self.results = job.results;
        job.results = Results.init(self.gpa);
        self.err_len = job.err_len;
        @memcpy(self.err_buf[0..job.err_len], job.err_buf[0..job.err_len]);
        return true;
    }
};

// ── replacing ───────────────────────────────────────────────────────────
/// Appends what replaces a match: `with` as is, or with `$1` … `$9` /
/// `$0` filled from the regex groups and `$$` for a `$`.
pub fn expand(out: *std.ArrayList(u8), gpa: std.mem.Allocator, with: []const u8, line: []const u8, sp: Span, regex: bool) !void {
    if (!regex) return out.appendSlice(gpa, with);
    var i: usize = 0;
    while (i < with.len) : (i += 1) {
        const ch = with[i];
        if (ch != '$' or i + 1 >= with.len) {
            try out.append(gpa, ch);
            continue;
        }
        const nx = with[i + 1];
        if (nx == '$') {
            try out.append(gpa, '$');
            i += 1;
        } else if (nx >= '0' and nx <= '9') {
            const g: usize = nx - '0';
            if (g == 0) {
                try out.appendSlice(gpa, line[sp.start..sp.end]);
            } else if (sp.groups[g]) |r| {
                try out.appendSlice(gpa, line[r[0]..r[1]]);
            }
            i += 1;
        } else try out.append(gpa, ch);
    }
}

/// Rewrites `data` with the matches replaced: all of them, or only those
/// `only` lists (by line and column; matches that moved are skipped).
/// Returns how many were replaced.
pub fn replaceInText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8, matcher: *const Matcher, with: []const u8, only: ?[]const Match) !u32 {
    var count: u32 = 0;
    var line_no: u32 = 0;
    var pos: usize = 0;
    while (true) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        var line = data[pos..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var from: usize = 0;
        while (matcher.find(line, from)) |sp| {
            try out.appendSlice(gpa, line[from..sp.start]);
            if (only == null or listed(only.?, line_no, sp.start)) {
                try expand(out, gpa, with, line, sp, matcher.opts.regex);
                count += 1;
            } else try out.appendSlice(gpa, line[sp.start..sp.end]);
            from = sp.end;
        }
        try out.appendSlice(gpa, line[from..]);
        try out.appendSlice(gpa, data[pos + line.len .. nl]);
        if (nl == data.len) break;
        try out.append(gpa, '\n');
        pos = nl + 1;
    }
    return count;
}

fn listed(only: []const Match, line: u32, col: usize) bool {
    for (only) |m| if (m.line == line and m.col == col) return true;
    return false;
}

/// Replaces in the file at `path` and writes it back (atomically) when
/// anything changed. Returns how many matches were replaced.
pub fn replaceInFile(gpa: std.mem.Allocator, path: []const u8, matcher: *const Matcher, with: []const u8, only: ?[]const Match) !u32 {
    const head = try sys.readFileHead(gpa, path, max_file_bytes);
    defer if (head.data.len > 0) gpa.free(head.data);
    if (head.total > max_file_bytes) return error.FileTooBig;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n = try replaceInText(gpa, &out, head.data, matcher, with, only);
    if (n > 0) try sys.writeFileAtomic(gpa, path, out.items);
    return n;
}

// ── tests ───────────────────────────────────────────────────────────────
const testing = std.testing;

test "globs: segment patterns match anywhere in the path" {
    try testing.expect(globMatch("*.zig", "src/ui/files.zig"));
    try testing.expect(!globMatch("*.zig", "src/ui/files.zig.bak"));
    try testing.expect(globMatch("node_modules", "web/node_modules/x/index.js"));
    try testing.expect(globMatch("?ain.zig", "main.zig"));
    try testing.expect(!globMatch("ain.zig", "main.zig"));
}

test "globs: path patterns, ** and folder prefixes" {
    try testing.expect(globMatch("src/**/*.zig", "src/ui/files.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/main.zig"));
    try testing.expect(!globMatch("src/**/*.zig", "docs/main.zig"));
    try testing.expect(globMatch("src/ui", "src/ui/files.zig"));
    try testing.expect(globMatch("./src/ui/", "src/ui/files.zig"));
    try testing.expect(!globMatch("src/ui", "src/uix/files.zig"));
    try testing.expect(globMatch("**/test/*.txt", "a/b/test/x.txt"));
    try testing.expect(globMatch("**/test/*.txt", "test/x.txt"));
    try testing.expect(matchesAny("*.md, src/**", "src/a.zig"));
    try testing.expect(!matchesAny("*.md, docs/**", "src/a.zig"));
    try testing.expect(!matchesAny(" , ", "src/a.zig"));
}

test "wanted: include and exclude lists" {
    try testing.expect(wanted(.{ .text = "x" }, "a/b.c"));
    try testing.expect(wanted(.{ .text = "x", .include = "*.c" }, "a/b.c"));
    try testing.expect(!wanted(.{ .text = "x", .include = "*.h" }, "a/b.c"));
    try testing.expect(!wanted(.{ .text = "x", .include = "*.c", .exclude = "a" }, "a/b.c"));
}

test "matcher: plain text, case and whole words" {
    var m = try Matcher.init(testing.allocator, "Foo", .{});
    defer m.deinit();
    try testing.expectEqual(@as(usize, 4), m.find("bar foo Foo", 0).?.start);
    try testing.expectEqual(@as(usize, 8), m.find("bar foo Foo", 5).?.start);
    try testing.expect(m.find("bar", 0) == null);

    var cs = try Matcher.init(testing.allocator, "Foo", .{ .match_case = true });
    defer cs.deinit();
    try testing.expectEqual(@as(usize, 8), cs.find("bar foo Foo", 0).?.start);

    var ww = try Matcher.init(testing.allocator, "foo", .{ .whole_word = true });
    defer ww.deinit();
    try testing.expectEqual(@as(usize, 7), ww.find("foobar foo(1) foo_x", 0).?.start);
    try testing.expect(ww.find("foobar foo_x xfoo", 0) == null);
    try testing.expect(Matcher.init(testing.allocator, "", .{}) == error.EmptyPattern);
}

test "matcher: regex with groups, case, and empty matches skipped" {
    var re = try Matcher.init(testing.allocator, "f(o+)", .{ .regex = true });
    defer re.deinit();
    const sp = re.find("xx FOOO f", 0).?;
    try testing.expectEqual(@as(usize, 3), sp.start);
    try testing.expectEqual(@as(usize, 7), sp.end);
    try testing.expectEqualSlices(usize, &.{ 4, 7 }, &sp.groups[1].?);
    try testing.expect(re.find("xx FOOO f", 4) == null);

    var star = try Matcher.init(testing.allocator, "o*", .{ .regex = true });
    defer star.deinit();
    try testing.expectEqual(@as(usize, 1), star.find("foo", 0).?.start);

    var anchored = try Matcher.init(testing.allocator, "^b", .{ .regex = true });
    defer anchored.deinit();
    try testing.expect(anchored.find("ab", 1) == null);
    try testing.expect(Matcher.init(testing.allocator, "(", .{ .regex = true }) == error.BadPattern);
    var buf: [96]u8 = undefined;
    try testing.expect(Matcher.regexProblem(testing.allocator, "(", &buf).len > 0);
    try testing.expectEqual(@as(usize, 0), Matcher.regexProblem(testing.allocator, "a(b)", &buf).len);
}

test "results: lines, columns and previews" {
    var m = try Matcher.init(testing.allocator, "needle", .{});
    defer m.deinit();
    var res = Results.init(testing.allocator);
    defer res.deinit();
    const data = "first\r\n    needle here\nplain\n" ++ "x" ** 40 ++ " needle needle\n";
    try testing.expect(res.scan("a/b.txt", &m, data));
    try testing.expectEqual(@as(usize, 1), res.files.items.len);
    const f = res.files.items[0];
    try testing.expectEqualStrings("a/b.txt", f.rel);
    try testing.expectEqual(@as(u32, 3), res.match_count);
    const m0 = f.matches.items[0];
    try testing.expectEqual(@as(u32, 1), m0.line);
    try testing.expectEqual(@as(u32, 4), m0.col);
    try testing.expectEqualStrings("needle here", res.preview(m0));
    try testing.expectEqual(@as(u32, 0), m0.hl);
    try testing.expectEqual(@as(u32, 6), m0.hl_len);
    const m1 = f.matches.items[1];
    try testing.expectEqual(@as(u32, 3), m1.line);
    try testing.expectEqual(@as(u32, 41), m1.col);
    const p1 = res.preview(m1);
    try testing.expect(std.mem.startsWith(u8, p1, "…"));
    try testing.expectEqualStrings("needle", p1[m1.hl..][0..m1.hl_len]);
    // Nothing matching: no file kept.
    try testing.expect(res.scan("c.txt", &m, "nothing here"));
    try testing.expectEqual(@as(usize, 1), res.files.items.len);
    res.removeMatch(0, 0);
    try testing.expectEqual(@as(u32, 2), res.match_count);
    res.removeFile(0);
    try testing.expectEqual(@as(u32, 0), res.match_count);
}

test "replace: literal, groups and a chosen match" {
    const gpa = testing.allocator;
    var re = try Matcher.init(gpa, "(a)(b)", .{ .regex = true });
    defer re.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n = try replaceInText(gpa, &out, "ab-ab\r\nxab", &re, "$2$1$$", null);
    try testing.expectEqual(@as(u32, 3), n);
    try testing.expectEqualStrings("ba$-ba$\r\nxba$", out.items);

    var plain = try Matcher.init(gpa, "ab", .{});
    defer plain.deinit();
    out.clearRetainingCapacity();
    const only = [_]Match{.{ .line = 0, .col = 3, .len = 2, .preview = 0, .preview_len = 0, .hl = 0, .hl_len = 0 }};
    const k = try replaceInText(gpa, &out, "ab-ab\nab", &plain, "$1", &only);
    try testing.expectEqual(@as(u32, 1), k);
    try testing.expectEqualStrings("ab-$1\nab", out.items);
}

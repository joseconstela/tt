//! The comparison tab: two versions of a file side by side, the old one on
//! the left and the new one on the right, as the Git view opens a change.
//! A row of "Changes" compares the index with the file on disk (a file git
//! does not know yet faces an empty left side, a conflicted one faces the
//! last commit); a row of "Staged Changes" compares the last commit with
//! the index.
//!
//! Each side is a read-only `TextEditor` over that version's lines, with a
//! blank row wherever only the other side has a line, so the two always
//! have the same number of rows and scroll as one. Lines that went are
//! tinted red on the left, lines that came green on the right, and within
//! a changed line the part that differs is picked out (`diff.zig` does the
//! comparing). Either side takes the caret, a selection and ⌘C; nothing is
//! edited here: "Open File" in the strip opens the file itself.
//!
//! The versions come from `git show` (`:path` is the index, `HEAD:path`
//! the last commit) and from disk, and are read again when the file or the
//! index changes, so staging, committing or saving shows up on its own.
//!
//! Across relaunches the tab keeps one record, `diff <path> <w|s> <orig>`:
//! the file, whether it is the worktree or the staged comparison, and
//! where a staged rename came from.
const std = @import("std");
const tab_mod = @import("tab.zig");
const viewer = @import("viewer.zig");
const file_tab = @import("file_tab.zig");
const text_editor = @import("text_editor.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const filetype = @import("../filetype.zig");
const records = @import("../records.zig");
const diff = @import("../diff.zig");
const sys = @import("../sys.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const TextEditor = text_editor.TextEditor;
const RowMark = text_editor.RowMark;

/// How often an active tab checks whether the file or the index changed.
const check_every: f64 = 1.0;
const git_env = [_][]const u8{ "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };
const button_h: f32 = 22;
const button_pad_x: f32 = 10;
const button_label = "Open File";

const Side = enum { left, right };

/// What `git show` (or another quick git command) printed; null when it failed.
fn gitOut(gpa: std.mem.Allocator, dir: []const u8, argv: []const []const u8) ?[]u8 {
    var res = sys.run(gpa, dir, argv, &git_env) catch return null;
    defer res.deinit();
    if (!res.ok()) return null;
    return gpa.dupe(u8, res.stdout) catch null;
}

/// The two versions as last read, and what each is called.
const Sources = struct {
    left: []u8,
    right: []u8,
    left_label: []const u8,
    right_label: []const u8,
    too_big: bool = false,

    fn deinit(self: *Sources, gpa: std.mem.Allocator) void {
        gpa.free(self.left);
        gpa.free(self.right);
    }
};

/// What tells a change of either version: the file on disk and the index.
const Stamp = struct {
    file_mtime: i128 = 0,
    file_size: usize = 0,
    file_there: bool = false,
    index_mtime: i128 = 0,

    fn eql(a: Stamp, b: Stamp) bool {
        return a.file_mtime == b.file_mtime and a.file_size == b.file_size and a.file_there == b.file_there and a.index_mtime == b.index_mtime;
    }
};

pub const DiffTab = struct {
    pub const kind_label = "Diff";

    gpa: std.mem.Allocator,
    env: *tab_mod.Env,
    file_path: []u8,
    /// A staged rename's old place, relative to the repository's root.
    orig: ?[]u8 = null,
    staged: bool,
    /// The repository's index file ("" outside a repository).
    index_path: []u8 = &.{},
    src: Sources,
    stamp: Stamp = .{},
    last_check: f64 = 0,
    state: enum { ok, binary, too_big } = .ok,

    left: TextEditor,
    right: TextEditor,
    left_numbers: std.ArrayList(u32) = .empty,
    right_numbers: std.ArrayList(u32) = .empty,
    left_marks: std.ArrayList(RowMark) = .empty,
    right_marks: std.ArrayList(RowMark) = .empty,
    added: u32 = 0,
    removed: u32 = 0,
    /// The side the keyboard goes to: the one last pressed.
    side: Side = .right,
    /// Both sides scroll as one.
    scroll: f32 = 0,
    scroll_x: f32 = 0,

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const gpa = env.gpa;
        var kept = try Kept.parse(gpa, args.saved);
        defer kept.deinit(gpa);
        const path = args.path orelse kept.path orelse return error.MissingPath;
        const staged = if (args.diff) |d| d.staged else kept.staged;
        const orig: ?[]const u8 = if (args.diff) |d| d.orig else kept.orig;

        const self = try gpa.create(DiffTab);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .env = env,
            .file_path = try gpa.dupe(u8, path),
            .staged = staged,
            .src = .{ .left = &.{}, .right = &.{}, .left_label = "", .right_label = "" },
            .left = TextEditor.init(gpa, file_tab.newSalt()),
            .right = TextEditor.init(gpa, file_tab.newSalt()),
        };
        errdefer self.free();
        if (orig) |o| self.orig = try gpa.dupe(u8, o);
        self.left.read_only = true;
        self.right.read_only = true;

        // No index: not a repository (any more), so nothing to compare with.
        var dir_buf: [4096]u8 = undefined;
        const located = self.locate(&dir_buf);
        const index = gitOut(gpa, located.dir, &.{ "git", "rev-parse", "--path-format=absolute", "--git-path", "index" }) orelse return error.NotARepository;
        defer gpa.free(index);
        self.index_path = try gpa.dupe(u8, std.mem.trim(u8, index, " \r\n"));

        self.stamp = self.readStamp();
        self.src = try self.fetch();
        try self.rebuild();
        // Open on the first change rather than on the file's first line.
        for (self.left_marks.items, 0..) |m, i| {
            if (m.tint == .none) continue;
            // A change near the top is in view anyway.
            if (i >= 12) self.scroll = (@as(f32, @floatFromInt(i)) - 3) * text_editor.line_h + self.left.pad_top;
            break;
        }
        return tab_mod.Tab.from(DiffTab, self);
    }

    fn free(self: *DiffTab) void {
        const gpa = self.gpa;
        self.left.deinit();
        self.right.deinit();
        self.left_numbers.deinit(gpa);
        self.right_numbers.deinit(gpa);
        self.left_marks.deinit(gpa);
        self.right_marks.deinit(gpa);
        self.src.deinit(gpa);
        gpa.free(self.index_path);
        if (self.orig) |o| gpa.free(o);
        gpa.free(self.file_path);
    }

    pub fn deinit(self: *DiffTab) void {
        self.free();
        self.gpa.destroy(self);
    }

    /// True when this tab is the comparison the Git view asks for.
    pub fn shows(self: *const DiffTab, path: []const u8, staged: bool) bool {
        return self.staged == staged and std.mem.eql(u8, self.file_path, path);
    }

    // ── reading the two versions ────────────────────────────────────────
    /// Where to run git for the file: the nearest folder above it that
    /// still exists (a deleted file may have taken its folder along), and
    /// the file's path from there as git wants it (`./a/b`).
    fn locate(self: *const DiffTab, buf: []u8) struct { dir: []const u8, rel: []const u8 } {
        var dir = sys.dirname(self.file_path);
        while (dir.len > 1 and !sys.isDirectory(self.gpa, dir)) dir = sys.dirname(dir);
        const rest = std.mem.trimStart(u8, self.file_path[@min(dir.len, self.file_path.len)..], "/");
        const rel = std.fmt.bufPrint(buf, "./{s}", .{rest}) catch "./";
        return .{ .dir = dir, .rel = rel };
    }

    fn readStamp(self: *const DiffTab) Stamp {
        var s: Stamp = .{};
        if (sys.statFile(self.gpa, self.file_path)) |st| {
            s.file_there = true;
            s.file_mtime = st.mtime_ns;
            s.file_size = st.size;
        }
        if (sys.statFile(self.gpa, self.index_path)) |st| s.index_mtime = st.mtime_ns;
        return s;
    }

    fn show(self: *const DiffTab, dir: []const u8, rev: []const u8, rel: []const u8) ?[]u8 {
        const spec = std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ rev, rel }) catch return null;
        defer self.gpa.free(spec);
        return gitOut(self.gpa, dir, &.{ "git", "show", spec });
    }

    fn fetch(self: *const DiffTab) !Sources {
        const gpa = self.gpa;
        var buf: [4096]u8 = undefined;
        const at = self.locate(&buf);
        var out: Sources = .{ .left = &.{}, .right = &.{}, .left_label = "HEAD", .right_label = "Index" };
        errdefer out.deinit(gpa);
        if (self.staged) {
            // A version that is not there (a new file, a deleted one) is empty.
            out.left = self.show(at.dir, "HEAD", self.orig orelse at.rel) orelse try gpa.dupe(u8, "");
            out.right = self.show(at.dir, "", at.rel) orelse try gpa.dupe(u8, "");
        } else {
            out.right_label = "Working Tree";
            if (self.show(at.dir, "", at.rel)) |index| {
                out.left = index;
                out.left_label = "Index";
            } else if (self.show(at.dir, "HEAD", at.rel)) |head| {
                // A conflicted file has no single version in the index.
                out.left = head;
            } else {
                out.left = try gpa.dupe(u8, "");
                out.left_label = "Index";
            }
            if (sys.readFileHead(gpa, self.file_path, file_tab.max_bytes)) |head| {
                defer if (head.data.len > 0) gpa.free(head.data);
                out.right = try gpa.dupe(u8, head.data);
                out.too_big = head.total > file_tab.max_bytes;
            } else |_| {
                out.right = try gpa.dupe(u8, "");
            }
        }
        if (out.left.len > file_tab.max_bytes or out.right.len > file_tab.max_bytes) out.too_big = true;
        return out;
    }

    /// Reads both versions again; true when either is different now.
    fn reload(self: *DiffTab) bool {
        var fresh = self.fetch() catch return false;
        if (std.mem.eql(u8, fresh.left, self.src.left) and std.mem.eql(u8, fresh.right, self.src.right) and
            std.mem.eql(u8, fresh.left_label, self.src.left_label))
        {
            fresh.deinit(self.gpa);
            return false;
        }
        self.src.deinit(self.gpa);
        self.src = fresh;
        self.rebuild() catch {};
        return true;
    }

    /// Compares the versions in `src` and lays the rows out in the editors.
    fn rebuild(self: *DiffTab) !void {
        const gpa = self.gpa;
        self.left.numbers = null;
        self.left.marks = null;
        self.right.numbers = null;
        self.right.marks = null;
        self.left_numbers.clearRetainingCapacity();
        self.right_numbers.clearRetainingCapacity();
        self.left_marks.clearRetainingCapacity();
        self.right_marks.clearRetainingCapacity();
        self.added = 0;
        self.removed = 0;
        const is_binary = std.mem.indexOfScalar(u8, self.src.left, 0) != null or std.mem.indexOfScalar(u8, self.src.right, 0) != null;
        self.state = if (is_binary) .binary else if (self.src.too_big) .too_big else .ok;
        if (self.state != .ok) return;

        const a = try diff.splitLines(gpa, self.src.left);
        defer gpa.free(a);
        const b = try diff.splitLines(gpa, self.src.right);
        defer gpa.free(b);
        const rows = try diff.rows(gpa, a, b);
        defer gpa.free(rows);

        var lt: std.ArrayList(u8) = .empty;
        defer lt.deinit(gpa);
        var rt: std.ArrayList(u8) = .empty;
        defer rt.deinit(gpa);
        try lt.ensureTotalCapacity(gpa, self.src.left.len + rows.len);
        try rt.ensureTotalCapacity(gpa, self.src.right.len + rows.len);
        for (rows, 0..) |row, i| {
            if (i > 0) {
                try lt.append(gpa, '\n');
                try rt.append(gpa, '\n');
            }
            const l: []const u8 = if (row.left != 0) a[row.left - 1] else "";
            const r: []const u8 = if (row.right != 0) b[row.right - 1] else "";
            try lt.appendSlice(gpa, l);
            try rt.appendSlice(gpa, r);
            var lm: RowMark = .{};
            var rm: RowMark = .{};
            switch (row.kind) {
                .same => {},
                .changed => {
                    lm.tint = .removed;
                    rm.tint = .added;
                    if (diff.changedSpan(l, r)) |s| {
                        lm.from = s.a_from;
                        lm.to = s.a_to;
                        rm.from = s.b_from;
                        rm.to = s.b_to;
                    }
                },
                .removed => {
                    lm.tint = .removed;
                    rm.tint = .blank;
                },
                .added => {
                    lm.tint = .blank;
                    rm.tint = .added;
                },
            }
            if (row.kind != .same and row.left != 0) self.removed += 1;
            if (row.kind != .same and row.right != 0) self.added += 1;
            try self.left_numbers.append(gpa, row.left);
            try self.right_numbers.append(gpa, row.right);
            try self.left_marks.append(gpa, lm);
            try self.right_marks.append(gpa, rm);
        }

        const lang = filetype.language(self.file_path, if (self.src.right.len > 0) self.src.right else self.src.left);
        try self.left.load(lt.items, lang);
        try self.right.load(rt.items, lang);
        self.left.numbers = self.left_numbers.items;
        self.left.marks = self.left_marks.items;
        self.right.numbers = self.right_numbers.items;
        self.right.marks = self.right_marks.items;
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *DiffTab, buf: []u8) []const u8 {
        const name = sys.basename(self.file_path);
        return std.fmt.bufPrint(buf, "{s} ({s})", .{ name, if (self.staged) "Index" else "Working Tree" }) catch name;
    }

    /// "HEAD ↔ Index  ·  +3 −1": what is compared and how much differs.
    pub fn info(self: *DiffTab, buf: []u8) []const u8 {
        const l = self.src.left_label;
        const r = self.src.right_label;
        if (self.state != .ok) return std.fmt.bufPrint(buf, "{s} ↔ {s}", .{ l, r }) catch "";
        if (self.added == 0 and self.removed == 0) return std.fmt.bufPrint(buf, "{s} ↔ {s}  ·  No changes", .{ l, r }) catch "";
        return std.fmt.bufPrint(buf, "{s} ↔ {s}  ·  +{d} −{d}", .{ l, r, self.added, self.removed }) catch "";
    }

    fn focusedEditor(self: *DiffTab) *TextEditor {
        return if (self.side == .left) &self.left else &self.right;
    }

    pub fn tick(self: *DiffTab, now: f64, active: bool) bool {
        var dirty = self.left.tick(now, active and self.side == .left);
        if (self.right.tick(now, active and self.side == .right)) dirty = true;
        if (active and now - self.last_check > check_every) {
            self.last_check = now;
            const stamp = self.readStamp();
            if (!stamp.eql(self.stamp)) {
                self.stamp = stamp;
                if (self.reload()) dirty = true;
            }
        }
        return dirty;
    }

    pub fn onEdit(self: *DiffTab, cmd: EditCommand) void {
        self.focusedEditor().onEdit(cmd);
    }

    pub fn copy(self: *DiffTab, out: *std.ArrayList(u8), _: bool) bool {
        return self.focusedEditor().copy(out, false);
    }

    pub fn caretRect(self: *DiffTab) Rect {
        return self.focusedEditor().caret;
    }

    // ── across relaunches ───────────────────────────────────────────────
    const Kept = struct {
        path: ?[]u8 = null,
        orig: ?[]u8 = null,
        staged: bool = false,

        fn parse(gpa: std.mem.Allocator, saved: ?[]const u8) !Kept {
            var out: Kept = .{};
            errdefer out.deinit(gpa);
            var lines = std.mem.splitScalar(u8, saved orelse return out, '\n');
            while (lines.next()) |line| {
                var f = std.mem.splitScalar(u8, line, '\t');
                if (!std.mem.eql(u8, f.next() orelse continue, "diff")) continue;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                out.path = try gpa.dupe(u8, try records.unescape(&buf, gpa, f.next() orelse continue));
                out.staged = std.mem.eql(u8, f.next() orelse "", "s");
                const orig = try records.unescape(&buf, gpa, f.next() orelse "");
                if (orig.len > 0) out.orig = try gpa.dupe(u8, orig);
                break;
            }
            return out;
        }

        fn deinit(self: *Kept, gpa: std.mem.Allocator) void {
            if (self.path) |p| gpa.free(p);
            if (self.orig) |o| gpa.free(o);
        }
    };

    pub fn save(self: *DiffTab, out: *std.ArrayList(u8)) bool {
        const gpa = self.gpa;
        out.appendSlice(gpa, "diff\t") catch return false;
        records.escape(out, gpa, self.file_path) catch return false;
        out.appendSlice(gpa, if (self.staged) "\ts\t" else "\tw\t") catch return false;
        records.escape(out, gpa, self.orig orelse "") catch return false;
        out.append(gpa, '\n') catch return false;
        return true;
    }

    pub fn saveVersion(self: *DiffTab) u64 {
        return viewer.keptVersion(self.file_path, if (self.staged) "s" else "w");
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// "Open File": the file itself, in its own viewer. Not for a file
    /// that is no longer on disk.
    pub fn strip(self: *DiffTab, ui: *Ui, room: Rect) f32 {
        if (!self.stamp.file_there) return 0;
        const w = ui.text.measure(theme.font_chip, button_label) + 2 * button_pad_x;
        if (w > room.w) return 0;
        const r: Rect = .{ .x = room.right() - w, .y = room.y + (room.h - button_h) / 2, .w = w, .h = button_h };
        const st = ui.button(Ui.id("diff.open", self.left.salt), r);
        ui.dl.rrect(r, r.h / 2, theme.bg_inset);
        ui.feedback(r, r.h / 2, st);
        _ = ui.dl.textCentered(theme.font_chip, r.x + button_pad_x, r.centerY(), button_label, if (st.hover) theme.text else theme.text_2);
        if (st.clicked) self.env.openFile(self.file_path);
        return w;
    }

    pub fn draw(self: *DiffTab, ui: *Ui, rect: Rect, focused: bool) void {
        const body = viewer.frame(ui, rect);
        switch (self.state) {
            .ok => {},
            .binary => return viewer.notice(ui, body, "This is a binary file; there is nothing to compare as text."),
            .too_big => return viewer.notice(ui, body, "The file is too large to compare."),
        }

        // Two halves of the same width (so both clamp their scrolling
        // alike) with a hairline between them.
        const half = @floor(@max(0, body.w - 1) / 2);
        const lr: Rect = .{ .x = body.x, .y = body.y, .w = half, .h = body.h };
        const rr: Rect = .{ .x = body.x + half + 1, .y = body.y, .w = half, .h = body.h };

        // The wheel moves both, so it is taken here rather than by the
        // side under the pointer.
        self.scroll -= ui.takeScroll(body);
        if (ui.scroll_x != 0 and ui.mouseIn(body)) {
            self.scroll_x = @max(0, self.scroll_x - ui.scroll_x);
            ui.scroll_x = 0;
        }
        if (ui.pressed) {
            if (ui.mouseIn(lr)) self.side = .left else if (ui.mouseIn(rr)) self.side = .right;
        }

        const cols = @max(self.left.max_cols, self.right.max_cols);
        self.left.max_cols = cols;
        self.right.max_cols = cols;
        self.left.scroll = self.scroll;
        self.right.scroll = self.scroll;
        self.left.scroll_x = self.scroll_x;
        self.right.scroll_x = self.scroll_x;
        self.left.draw(ui, lr, focused and self.side == .left);
        self.right.draw(ui, rr, focused and self.side == .right);
        ui.dl.rect(.{ .x = body.x + half, .y = body.y, .w = 1, .h = body.h }, theme.line);

        // Whichever side moved on its own (a scrollbar, the caret, a
        // selection dragged past an edge) takes the other along.
        const moved: *const TextEditor = if (self.left.scroll != self.scroll or self.left.scroll_x != self.scroll_x) &self.left else &self.right;
        const other: *const TextEditor = if (moved == &self.left) &self.right else &self.left;
        if (other.scroll != moved.scroll or other.scroll_x != moved.scroll_x) ui.wants_frame = true;
        self.scroll = moved.scroll;
        self.scroll_x = moved.scroll_x;
    }
};

test "diff tab: what it keeps comes back" {
    const gpa = std.testing.allocator;
    var k = try DiffTab.Kept.parse(gpa, "diff\t/r/a\\tb.zig\ts\tsrc/old.zig\n");
    defer k.deinit(gpa);
    try std.testing.expectEqualStrings("/r/a\tb.zig", k.path.?);
    try std.testing.expect(k.staged);
    try std.testing.expectEqualStrings("src/old.zig", k.orig.?);
    var w = try DiffTab.Kept.parse(gpa, "diff\t/r/x\tw\t\n");
    defer w.deinit(gpa);
    try std.testing.expect(!w.staged);
    try std.testing.expect(w.orig == null);
    var none = try DiffTab.Kept.parse(gpa, null);
    defer none.deinit(gpa);
    try std.testing.expect(none.path == null);
}

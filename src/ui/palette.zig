//! Floating palette, from the "Command palette" artboard: a query row with
//! a caret, scope chips, grouped fuzzy-matched rows and a keyboard footer,
//! drawn over a dimmed window. It opens two ways, as in VS Code:
//!
//!   ⌘K  the command palette — app commands, the open tabs, the shell
//!       history and the accent setting; a leading `>` `@` `!` `:` narrows it.
//!   ⌘P  quick open ("Go to File…") — the files of the workspace, matched by
//!       name or path (see file_index.zig), the open documents first;
//!       `name:12:5` opens at a line and column, `:12` alone goes to a line
//!       of the current editor and previews it as the number is typed;
//!       `@` lists the tabs, `>` turns it into the command palette and ⌫ on
//!       an empty query turns it back; ⌘P again steps down the list.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const gfx_text = @import("../gfx/text.zig");
const tab_mod = @import("../tabs/tab.zig");
const match = @import("../match.zig");
const file_index = @import("../file_index.zig");
const projects_mod = @import("../projects.zig");
const sys = @import("../sys.zig");
const Editor = @import("../input/editor.zig").Editor;
const History = @import("../input/history.zig").History;
const EditCommand = @import("../events.zig").EditCommand;
const Action = @import("../app.zig").Action;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

pub const Goto = file_index.Goto;

/// A file or tab to bring forward, and where to put the caret in it.
pub const Target = struct { id: u32, goto: Goto = .{} };

/// What the user picked; the app carries it out.
pub const Pick = union(enum) {
    /// An informational row: nothing to do.
    none,
    action: Action,
    select_tab: usize,
    /// Index into `History.entries`; run in the active terminal.
    run_history: usize,
    /// Index into `theme.accent_options`.
    set_accent: usize,
    /// A file of the quick-open listing (`Palette.filePath` gives its path
    /// — before the palette closes, the listing dies with it).
    open_file: Target,
    /// A tab by uid, brought forward.
    focus_tab: Target,
    /// The caret of the current editor.
    goto_line: Goto,
};

/// Where the rows come from. Held while the palette is open.
pub const Sources = struct {
    tabs: *tab_mod.TabManager,
    history: *const History,
    projects: *projects_mod.Projects,
    /// The folder the current tab works in: the first root of the file
    /// listing (read when the palette opens).
    cwd: []const u8 = "",
};

/// How the palette was opened, which decides the chips and the prefixes.
pub const Mode = enum(u8) {
    /// ⌘K.
    commands,
    /// ⌘P.
    files,

    fn chips(m: Mode) []const Scope {
        return switch (m) {
            .commands => &commands_chips,
            .files => &files_chips,
        };
    }
};

const commands_chips = [_]Scope{ .everything, .commands, .tabs, .history, .settings };
const files_chips = [_]Scope{ .files, .tabs, .line, .commands };

pub const Scope = enum(u8) {
    everything,
    commands,
    tabs,
    history,
    settings,
    files,
    line,

    /// Typing this character first narrows the query to the scope.
    fn prefix(s: Scope) u8 {
        return switch (s) {
            .everything, .files => 0,
            .commands => '>',
            .tabs => '@',
            .history => '!',
            .settings, .line => ':',
        };
    }

    fn label(s: Scope) []const u8 {
        return switch (s) {
            .everything => "Everything",
            .commands => "Commands",
            .tabs => "Tabs",
            .history => "History",
            .settings => "Settings",
            .files => "Files",
            .line => "Go to line",
        };
    }

    /// The scope a leading character names in `mode` (`:` is settings in
    /// the command palette and go-to-line in quick open).
    fn fromPrefix(c: u8, mode: Mode) ?Scope {
        for (mode.chips()) |s| {
            if (s.prefix() != 0 and s.prefix() == c) return s;
        }
        return null;
    }
};

const Group = enum { commands, tabs, history, settings, open, files, line };

fn groupTitle(g: Group) []const u8 {
    return switch (g) {
        .commands => "COMMANDS",
        .tabs => "TABS",
        .history => "HISTORY",
        .settings => "SETTINGS",
        .open => "OPEN",
        .files => "FILES",
        .line => "GO TO LINE",
    };
}

const Entry = struct {
    group: Group,
    /// Dimmed lead-in ("Shell:", "Go to").
    prefix: []const u8 = "",
    /// The matched text.
    label: []const u8,
    /// Right-aligned note; a keyboard shortcut when `kbd`, else a folder
    /// or a word, shortened from the left when long.
    detail: []const u8 = "",
    kbd: bool = true,
    mono: bool = false,
    /// A notice rather than something to pick: drawn dimmed.
    dim: bool = false,
    dot: ?Color = null,
    pick: Pick,
    score: i32 = 0,
    /// Code point indices of `label` that matched the query (first 64).
    mask: u64 = 0,
};

const Command = struct { prefix: []const u8, label: []const u8, kbd: []const u8, action: Action };

const commands = [_]Command{
    .{ .prefix = "Shell:", .label = "New terminal tab", .kbd = "⌘T", .action = .new_tab },
    .{ .prefix = "Shell:", .label = "New website tab", .kbd = "⌘⇧N", .action = .new_web_tab },
    .{ .prefix = "Shell:", .label = "Close tab", .kbd = "⌘W", .action = .close_tab },
    .{ .prefix = "Shell:", .label = "Clear blocks", .kbd = "⌃L", .action = .clear },
    .{ .prefix = "File:", .label = "Go to file…", .kbd = "⌘P", .action = .quick_open },
    .{ .prefix = "File:", .label = "Go to line…", .kbd = "", .action = .go_to_line },
    .{ .prefix = "View:", .label = "Toggle sidebar", .kbd = "⌘B", .action = .toggle_sidebar },
    .{ .prefix = "View:", .label = "Next tab", .kbd = "⌘⇧]", .action = .next_tab },
    .{ .prefix = "View:", .label = "Previous tab", .kbd = "⌘⇧[", .action = .prev_tab },
    .{ .prefix = "View:", .label = "Split right", .kbd = "⌘D", .action = .split_right },
    .{ .prefix = "View:", .label = "Split down", .kbd = "⌘⇧D", .action = .split_down },
    .{ .prefix = "View:", .label = "Focus next pane", .kbd = "⌘]", .action = .next_pane },
    .{ .prefix = "View:", .label = "Focus previous pane", .kbd = "⌘[", .action = .prev_pane },
    .{ .prefix = "File:", .label = "Save", .kbd = "⌘S", .action = .save },
    .{ .prefix = "Edit:", .label = "Undo", .kbd = "⌘Z", .action = .undo },
    .{ .prefix = "Edit:", .label = "Redo", .kbd = "⌘⇧Z", .action = .redo },
    .{ .prefix = "View:", .label = "Markdown: switch preview / source", .kbd = "⌘E", .action = .toggle_view },
    .{ .prefix = "Settings:", .label = "Open settings", .kbd = "⌘,", .action = .open_settings },
    .{ .prefix = "Page:", .label = "Open location", .kbd = "⌘L", .action = .open_location },
    .{ .prefix = "Page:", .label = "Reload page", .kbd = "⌘R", .action = .web_reload },
    .{ .prefix = "Page:", .label = "Back", .kbd = "⌘⌥←", .action = .web_back },
    .{ .prefix = "Page:", .label = "Forward", .kbd = "⌘⌥→", .action = .web_forward },
};

const max_entries = 64;
const max_tabs = 16;
/// File rows for a query; fewer for an empty one, which is a browse.
const max_hits = 40;
const empty_hits = 24;
const detail_len = 160;

const header_h: f32 = 52;
const chips_h: f32 = 44;
const footer_h: f32 = 34;
const row_h: f32 = 36;
const group_h_first: f32 = 28;
const group_h: f32 = 32;
const list_pad_top: f32 = 6;
const list_pad_bottom: f32 = 8;
const list_pad_x: f32 = 8;

pub const Palette = struct {
    gpa: std.mem.Allocator,
    open: bool = false,
    mode: Mode = .commands,
    editor: Editor,
    scope: Scope = .everything,
    selected: usize = 0,
    /// Vertical scroll of the row list, in points.
    scroll: f32 = 0,
    src: ?Sources = null,
    /// The command palette reached from quick open with `>`: ⌫ on an
    /// empty query goes back, as in VS Code.
    from_files: bool = false,

    /// The files of the workspace while quick open is up.
    index: ?*file_index.Index = null,
    /// The rows were built after the listing finished.
    index_seen: bool = false,
    /// Where the current editor's caret was before a go-to-line preview
    /// moved it; put back when the query leaves the line scope or the
    /// palette is dismissed.
    preview_from: ?tab_mod.Position = null,

    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    title_bufs: [max_tabs][96]u8 = undefined,
    detail_bufs: [max_entries][detail_len]u8 = undefined,
    /// Paths of the OPEN rows of this build, so FILES does not repeat them.
    open_paths: [max_tabs][]const u8 = undefined,
    open_count: usize = 0,

    seen_version: u64 = 0,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    caret: Rect = .{},
    panel: Rect = .{},

    pub fn init(gpa: std.mem.Allocator) Palette {
        return .{ .gpa = gpa, .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Palette) void {
        self.dropIndex();
        self.editor.deinit();
    }

    pub fn show(self: *Palette, mode: Mode, src: Sources) void {
        self.open = true;
        self.src = src;
        self.mode = mode;
        self.from_files = false;
        self.preview_from = null;
        self.editor.clear();
        self.scope = mode.chips()[0];
        self.selected = 0;
        self.scroll = 0;
        self.dropIndex();
        if (mode == .files) self.startIndex();
        self.rebuild();
    }

    /// Quick open with `:` typed: go to a line of the current editor.
    pub fn showLine(self: *Palette, src: Sources) void {
        self.show(.files, src);
        self.editor.setText(":");
        self.rebuild();
    }

    /// Dismisses the palette: a go-to-line preview is undone.
    pub fn close(self: *Palette) void {
        self.restorePreview();
        self.open = false;
        self.src = null;
        self.count = 0;
        self.dropIndex();
    }

    /// Closes after a pick: what a preview moved stays where it is.
    pub fn accept(self: *Palette) void {
        self.preview_from = null;
        self.close();
    }

    /// ⌘K / ⌘P: opens in `mode`; switches an open palette to the other
    /// mode; closes the command palette; steps down quick open's list.
    pub fn toggle(self: *Palette, mode: Mode, src: Sources) void {
        if (!self.open) {
            self.show(mode, src);
            return;
        }
        if (self.mode != mode) {
            self.switchMode(mode, mode.chips()[0]);
            return;
        }
        if (mode == .files) {
            self.moveSelection(1);
            return;
        }
        self.close();
    }

    /// The same panel, the other set of chips; the query starts over.
    fn switchMode(self: *Palette, mode: Mode, scope: Scope) void {
        self.restorePreview();
        self.from_files = self.mode == .files and mode == .commands;
        self.mode = mode;
        self.scope = scope;
        self.editor.clear();
        self.selected = 0;
        self.scroll = 0;
        if (mode == .files and self.index == null) self.startIndex();
        self.rebuild();
    }

    // ── the file listing ────────────────────────────────────────────────
    /// Starts listing the roots: the project the current folder belongs
    /// to — else that folder, widened to its git repository — then the
    /// other projects.
    fn startIndex(self: *Palette) void {
        const src = self.src orelse return;
        const ix = file_index.Index.create(self.gpa) catch return;
        const cwd = src.cwd;
        if (src.projects.containing(cwd)) |p| {
            ix.addRoot(p.root, p.name) catch {};
        } else if (cwd.len > 0) {
            ix.addRoot(cwd, "") catch {};
            ix.roots.items[0].widen_to_repo = true;
        }
        for (src.projects.items.items) |p| ix.addRoot(p.root, p.name) catch {};
        ix.start();
        self.index = ix;
        self.index_seen = false;
    }

    fn dropIndex(self: *Palette) void {
        if (self.index) |ix| {
            ix.release();
            self.index = null;
        }
        self.index_seen = false;
    }

    /// The absolute path of an `open_file` pick, while the palette is open.
    pub fn filePath(self: *const Palette, id: u32, buf: []u8) ?[]const u8 {
        const ix = self.index orelse return null;
        if (!ix.ready()) return null;
        return ix.absPath(id, buf);
    }

    // ── per-tick ────────────────────────────────────────────────────────
    /// Caret blink and the file listing finishing; true when a redraw is needed.
    pub fn tick(self: *Palette, now: f64) bool {
        if (!self.open) return false;
        if (self.index) |ix| if (!self.index_seen and ix.ready()) {
            self.index_seen = true;
            self.rebuild();
            return true;
        };
        if (self.editor.version != self.seen_version) {
            self.seen_version = self.editor.version;
            self.blink_t0 = now;
        }
        const on = @mod(now - self.blink_t0, 1.06) < 0.53;
        if (on != self.blink_on) {
            self.blink_on = on;
            return true;
        }
        return false;
    }

    // ── query / scope ───────────────────────────────────────────────────
    /// The scope the rows follow: a typed prefix wins over the chip.
    fn effectiveScope(self: *const Palette) Scope {
        const t = self.editor.bytes();
        if (t.len > 0) {
            if (Scope.fromPrefix(t[0], self.mode)) |s| return s;
        }
        return self.scope;
    }

    /// The query text without its scope prefix.
    fn query(self: *const Palette) []const u8 {
        var t = self.editor.bytes();
        if (t.len > 0 and Scope.fromPrefix(t[0], self.mode) != null) t = t[1..];
        return std.mem.trim(u8, t, " ");
    }

    fn setScope(self: *Palette, s: Scope) void {
        if (self.mode == .files and s == .commands) {
            self.switchMode(.commands, .commands);
            return;
        }
        // A typed prefix would override the chip: drop it.
        const t = self.editor.bytes();
        if (t.len > 0 and Scope.fromPrefix(t[0], self.mode) != null) {
            var buf: [512]u8 = undefined;
            const n = @min(buf.len, t.len - 1);
            @memcpy(buf[0..n], t[1 .. 1 + n]);
            self.editor.setText(buf[0..n]);
        }
        self.scope = s;
        self.selected = 0;
        self.scroll = 0;
        self.rebuild();
    }

    fn cycleScope(self: *Palette, delta: i32) void {
        const chips = self.mode.chips();
        const cur = self.effectiveScope();
        var at: i32 = 0;
        for (chips, 0..) |s, i| if (s == cur) {
            at = @intCast(i);
        };
        const n: i32 = @intCast(chips.len);
        self.setScope(chips[@intCast(@mod(at + delta, n))]);
    }

    /// In quick open a leading `>` is the command palette (VS Code): the
    /// character goes and the mode switches.
    fn normalize(self: *Palette) void {
        const t = self.editor.bytes();
        if (self.mode != .files or t.len == 0 or t[0] != '>') return;
        var buf: [512]u8 = undefined;
        const n = @min(buf.len, t.len - 1);
        @memcpy(buf[0..n], t[1 .. 1 + n]);
        self.switchMode(.commands, .commands);
        self.editor.setText(buf[0..n]);
        self.rebuild();
    }

    // ── input ───────────────────────────────────────────────────────────
    pub fn onText(self: *Palette, utf8: []const u8) void {
        self.editor.insert(utf8);
        self.selected = 0;
        self.scroll = 0;
        self.normalize();
        self.rebuild();
    }

    pub fn onMarkedText(self: *Palette, utf8: []const u8) void {
        self.editor.setMarked(utf8);
    }

    pub fn onPaste(self: *Palette, utf8: []const u8) void {
        // One line only.
        const end = std.mem.indexOfAny(u8, utf8, "\r\n") orelse utf8.len;
        self.onText(utf8[0..end]);
    }

    /// Returns a pick to carry out, if any. `Escape` closes the palette.
    pub fn onEdit(self: *Palette, cmd: EditCommand) ?Pick {
        // ⌫ on the empty command palette that `>` made: back to the files.
        if (cmd == .delete_backward and self.mode == .commands and self.from_files and self.editor.isEmpty()) {
            self.switchMode(.files, .files);
            return null;
        }
        switch (cmd) {
            .cancel => self.close(),
            .insert_newline, .insert_line_break => {
                self.rebuild();
                if (self.selected < self.count) {
                    const pick = self.entries[self.selected].pick;
                    if (pick != .none) return pick;
                }
            },
            .insert_tab => self.cycleScope(1),
            .insert_backtab => self.cycleScope(-1),
            .move_up, .select_up => self.moveSelection(-1),
            .move_down, .select_down => self.moveSelection(1),
            .page_up, .scroll_to_top, .move_doc_start => self.selected = 0,
            .page_down, .scroll_to_bottom, .move_doc_end => self.selected = if (self.count > 0) self.count - 1 else 0,
            else => {
                const before = self.editor.version;
                _ = self.editor.apply(cmd);
                if (self.editor.version != before) {
                    self.selected = 0;
                    self.scroll = 0;
                    self.normalize();
                    self.rebuild();
                }
            },
        }
        return null;
    }

    pub fn onCtrl(self: *Palette, key: u8) ?Pick {
        return switch (key) {
            'n' => self.onEdit(.move_down),
            'p' => self.onEdit(.move_up),
            'a' => self.onEdit(.move_line_start),
            'e' => self.onEdit(.move_line_end),
            'u' => self.onEdit(.delete_to_line_start),
            'k' => self.onEdit(.delete_to_line_end),
            'w' => self.onEdit(.delete_word_backward),
            'c', 'g' => self.onEdit(.cancel),
            else => null,
        };
    }

    fn moveSelection(self: *Palette, delta: i32) void {
        if (self.count == 0) return;
        const n: i32 = @intCast(self.count);
        const cur: i32 = @intCast(@min(self.selected, self.count - 1));
        self.selected = @intCast(@mod(cur + delta, n));
    }

    // ── rows ────────────────────────────────────────────────────────────
    fn rebuild(self: *Palette) void {
        self.count = 0;
        self.open_count = 0;
        const src = self.src orelse return;
        const q = self.query();
        const scope = self.effectiveScope();
        if (scope != .line) self.restorePreview();

        switch (self.mode) {
            .commands => {
                if (scope == .everything or scope == .commands) self.pushCommands(q);
                if (scope == .everything or scope == .tabs) self.pushTabs(src, q);
                if (scope == .everything or scope == .history) self.pushHistory(src, q, scope);
                if (scope == .everything or scope == .settings) self.pushSettings(q);
            },
            .files => switch (scope) {
                .tabs => self.pushTabs(src, q),
                .line => self.pushLine(src, q),
                else => self.pushFiles(src, q),
            },
        }

        // Best matches first within each group (stable, so ties keep their order).
        if (q.len > 0) {
            var i: usize = 1;
            while (i < self.count) : (i += 1) {
                var j = i;
                while (j > 0 and self.entries[j - 1].group == self.entries[j].group and self.entries[j - 1].score < self.entries[j].score) : (j -= 1) {
                    std.mem.swap(Entry, &self.entries[j - 1], &self.entries[j]);
                }
            }
        }
        if (self.count == 0) self.selected = 0 else self.selected = @min(self.selected, self.count - 1);
    }

    fn pushCommands(self: *Palette, q: []const u8) void {
        for (commands) |c| self.push(q, .{
            .group = .commands,
            .prefix = c.prefix,
            .label = c.label,
            .detail = c.kbd,
            .pick = .{ .action = c.action },
        });
    }

    /// The tabs in the strip (the group on show), so the ⌘n hints hold.
    fn pushTabs(self: *Palette, src: Sources, q: []const u8) void {
        const n = @min(src.tabs.items().len, max_tabs);
        for (0..n) |i| {
            const t = src.tabs.items()[i];
            const kbd = [_][]const u8{ "⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8" };
            const dot: ?Color = switch (t.vtable.status(t.ptr)) {
                .none => null,
                .running => theme.teal,
                .attention => theme.accent,
                .failed => theme.red,
            };
            self.push(q, .{
                .group = .tabs,
                .prefix = "Go to",
                .label = t.title(&self.title_bufs[i]),
                .detail = if (i < kbd.len) kbd[i] else if (i == n - 1) "⌘9" else "",
                .dot = dot,
                .pick = .{ .select_tab = i },
            });
        }
    }

    fn pushHistory(self: *Palette, src: Sources, q: []const u8, scope: Scope) void {
        const limit: usize = if (scope == .history) 14 else if (q.len == 0) 4 else 6;
        const before = self.count;
        var i = src.history.entries.items.len;
        while (i > 0 and self.count - before < limit) {
            i -= 1;
            self.pushWith(q, .substring, .{
                .group = .history,
                .label = src.history.entries.items[i],
                .detail = "↵ run",
                .mono = true,
                .pick = .{ .run_history = i },
            });
        }
    }

    fn pushSettings(self: *Palette, q: []const u8) void {
        for (theme.accent_options, 0..) |c, i| {
            const current = std.meta.eql(c, theme.accent);
            self.push(q, .{
                .group = .settings,
                .prefix = "Accent colour ›",
                .label = theme.accent_labels[i],
                .detail = if (current) "current" else "",
                .kbd = false,
                .dot = c,
                .pick = .{ .set_accent = i },
            });
        }
    }

    /// Quick open: the documents open in the group on show (the one on
    /// show excluded, so ↵ on an empty query goes to another), then the
    /// workspace files that match — a `:line:col` suffix rides along.
    fn pushFiles(self: *Palette, src: Sources, q: []const u8) void {
        const sp = file_index.splitGoto(q);
        const fq = sp.text;
        const goto = sp.goto orelse Goto{};

        const cur = src.tabs.current();
        var slot: usize = 0;
        const grp = src.tabs.group();
        outer: for (grp.layout.owned.items) |p| {
            for (p.tabs.items) |t| {
                if (slot >= max_tabs) break :outer;
                const path = t.vtable.path(t.ptr);
                if (path.len == 0) continue;
                if (cur != null and cur.?.uid == t.uid) continue;
                const before = self.count;
                self.pushWith(fq, .fuzzy, .{
                    .group = .open,
                    .label = t.title(&self.title_bufs[slot]),
                    .detail = self.folderDetail(path, slot),
                    .kbd = false,
                    .pick = .{ .focus_tab = .{ .id = t.uid, .goto = goto } },
                });
                if (self.count > before) {
                    self.open_paths[self.open_count] = path;
                    self.open_count += 1;
                }
                slot += 1;
            }
        }

        const ix = self.index orelse return;
        if (!ix.ready()) {
            self.pushScored(.{ .group = .files, .label = "Listing files…", .kbd = false, .dim = true, .pick = .none });
            return;
        }
        var hits: [max_hits]file_index.Hit = undefined;
        const limit: usize = if (fq.len == 0) empty_hits else max_hits;
        const n = ix.search(fq, hits[0..limit]);
        var buf: [1024]u8 = undefined;
        for (hits[0..n], 0..) |h, k| {
            const f = ix.files.items[h.index];
            if (self.open_count > 0) {
                const abs = ix.absPath(h.index, &buf) orelse continue;
                if (self.listedOpen(abs)) continue;
            }
            self.pushScored(.{
                .group = .files,
                .label = sys.basename(f.rel),
                .detail = self.fileDetail(ix, f, max_tabs + k),
                .kbd = false,
                .pick = .{ .open_file = .{ .id = h.index, .goto = goto } },
                .score = h.score,
                .mask = h.mask,
            });
        }
    }

    fn listedOpen(self: *const Palette, path: []const u8) bool {
        for (self.open_paths[0..self.open_count]) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    /// A file's folder, led by its root's name when there are several roots.
    fn fileDetail(self: *Palette, ix: *const file_index.Index, f: file_index.File, slot: usize) []const u8 {
        const folder = file_index.Index.folderOf(f);
        if (ix.roots.items.len < 2) return folder;
        const root = ix.roots.items[f.root].name;
        if (folder.len == 0) return root;
        return std.fmt.bufPrint(&self.detail_bufs[slot], "{s}/{s}", .{ root, folder }) catch folder;
    }

    /// An open document's folder the way `fileDetail` spells it when the
    /// document is under a root, "~/…" otherwise.
    fn folderDetail(self: *Palette, path: []const u8, slot: usize) []const u8 {
        const dir = sys.dirname(path);
        if (self.index) |ix| {
            for (ix.roots.items) |r| {
                if (!std.mem.startsWith(u8, dir, r.path)) continue;
                if (dir.len > r.path.len and dir[r.path.len] != '/') continue;
                const rel = if (dir.len > r.path.len) dir[r.path.len + 1 ..] else "";
                if (ix.roots.items.len < 2) return rel;
                if (rel.len == 0) return r.name;
                return std.fmt.bufPrint(&self.detail_bufs[slot], "{s}/{s}", .{ r.name, rel }) catch rel;
            }
        }
        return sys.abbreviateHome(dir, &self.detail_bufs[slot]);
    }

    /// `:12:5` — a row that names the target, previewed in the editor as
    /// it is typed; a hint about the current position until a number is.
    fn pushLine(self: *Palette, src: Sources, q: []const u8) void {
        const goto = file_index.parseGoto(q);
        const tab = src.tabs.current();
        const pos: ?tab_mod.Position = if (tab) |t| t.vtable.position(t.ptr) else null;
        const p = pos orelse {
            self.restorePreview();
            self.pushScored(.{ .group = .line, .label = "Open a text file first to go to a line", .kbd = false, .dim = true, .pick = .none });
            return;
        };
        if (goto == null or goto.?.line == 0) {
            self.restorePreview();
            const label = std.fmt.bufPrint(&self.detail_bufs[0], "Current line {d}, column {d}. Type a line number between 1 and {d}", .{ p.line, p.col, p.lines }) catch "";
            self.pushScored(.{ .group = .line, .label = label, .kbd = false, .dim = true, .pick = .none });
            return;
        }
        const g = goto.?;
        const line: u32 = @intCast(@min(g.line, p.lines));
        const label = if (g.col > 0)
            std.fmt.bufPrint(&self.detail_bufs[0], "Go to line {d}, column {d}", .{ line, g.col }) catch ""
        else
            std.fmt.bufPrint(&self.detail_bufs[0], "Go to line {d}", .{line}) catch "";
        self.pushScored(.{ .group = .line, .label = label, .detail = "↵ go", .pick = .{ .goto_line = .{ .line = line, .col = g.col } } });
        self.previewLine(src, line, g.col);
    }

    fn previewLine(self: *Palette, src: Sources, line: u32, col: u32) void {
        const t = src.tabs.current() orelse return;
        if (self.preview_from == null) self.preview_from = t.vtable.position(t.ptr) orelse return;
        _ = t.vtable.goTo(t.ptr, line, col);
    }

    fn restorePreview(self: *Palette) void {
        const p = self.preview_from orelse return;
        self.preview_from = null;
        const src = self.src orelse return;
        const t = src.tabs.current() orelse return;
        _ = t.vtable.goTo(t.ptr, p.line, p.col);
    }

    const Match = enum { fuzzy, substring };

    fn push(self: *Palette, q: []const u8, entry: Entry) void {
        self.pushWith(q, .fuzzy, entry);
    }

    fn pushWith(self: *Palette, q: []const u8, mode: Match, entry: Entry) void {
        if (self.count >= max_entries) return;
        var e = entry;
        if (q.len > 0) {
            const matched: ?i32 = switch (mode) {
                .fuzzy => match.fuzzy(q, e.label, &e.mask),
                .substring => match.substring(q, e.label, &e.mask),
            };
            if (matched) |s| {
                e.score = s;
            } else if (e.prefix.len > 0 and match.fuzzy(q, e.prefix, &e.mask) != null) {
                e.mask = 0;
                e.score = -8;
            } else return;
        }
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// A row already matched (or one that never is).
    fn pushScored(self: *Palette, entry: Entry) void {
        if (self.count >= max_entries) return;
        self.entries[self.count] = entry;
        self.count += 1;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws the scrim and the panel over the whole window. Returns a pick
    /// when a row was clicked.
    pub fn draw(self: *Palette, ui: *Ui, width: f32, height: f32) ?Pick {
        if (!self.open) return null;
        const dl = ui.dl;
        var pick: ?Pick = null;
        const window: Rect = .{ .x = 0, .y = 0, .w = width, .h = height };

        // Everything under the palette is inert; a click outside closes it.
        ui.interactive.append(ui.gpa, window) catch {};
        dl.rect(window, theme.scrim);

        const pw = @min(theme.palette_w, width - 40);
        const top = @min(theme.palette_top, @max(24, height * 0.12));
        const px = @round((width - pw) / 2);

        // Layout of the row list.
        var list_h: f32 = list_pad_top + list_pad_bottom;
        var ys: [max_entries]f32 = undefined;
        {
            var y: f32 = list_pad_top;
            var last: ?Group = null;
            for (0..self.count) |i| {
                const e = &self.entries[i];
                if (last == null or last.? != e.group) {
                    y += if (last == null) group_h_first else group_h;
                    last = e.group;
                }
                ys[i] = y;
                y += row_h;
            }
            if (self.count == 0) y += row_h;
            list_h = y + list_pad_bottom;
        }
        const max_list = @max(row_h + list_pad_top + list_pad_bottom, height - top - 40 - header_h - chips_h - footer_h);
        const visible_list = @min(list_h, max_list);
        const panel: Rect = .{ .x = px, .y = top, .w = pw, .h = header_h + chips_h + visible_list + footer_h };
        self.panel = panel;

        // Keep the selection in view.
        if (self.count > 0) {
            const sel = @min(self.selected, self.count - 1);
            const sel_top = ys[sel] - list_pad_top;
            const sel_bottom = ys[sel] + row_h + list_pad_bottom;
            if (sel_top < self.scroll) self.scroll = sel_top;
            if (sel_bottom > self.scroll + visible_list) self.scroll = sel_bottom - visible_list;
        }
        self.scroll = std.math.clamp(self.scroll, 0, @max(0, list_h - visible_list));

        if (ui.pressed and !panel.contains(ui.mx, ui.my)) {
            self.close();
            return null;
        }

        // Shadow (0 24px 80px rgba(0,0,0,.55)), approximated with soft rings.
        theme.dropShadow(dl, panel, 12, 6, 6, 14, 0.075);
        dl.shape(panel, 12, theme.bg_panel, 1, theme.line_strong);
        dl.pushClip(panel.inset(1, 1));
        defer dl.popClip();

        // ── query row ──
        const scope = self.effectiveScope();
        const q_r: Rect = .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = header_h };
        dl.rect(.{ .x = q_r.x, .y = q_r.bottom() - 1, .w = q_r.w, .h = 1 }, theme.line);
        const shown = self.editor.bytes();
        // A typed prefix character is drawn as the prompt itself. The
        // command palette always has one (`>` for everything); quick open
        // has none unless a chip narrowed it.
        const typed_prefix = shown.len > 0 and Scope.fromPrefix(shown[0], self.mode) != null;
        const prompt_char: u8 = if (scope.prefix() != 0) scope.prefix() else if (self.mode == .commands) '>' else 0;
        const prompt = [_]u8{prompt_char};
        var x = q_r.x + 16;
        if (!typed_prefix and prompt_char != 0) x += dl.textCentered(theme.font_palette_prompt, x, q_r.centerY(), &prompt, theme.accent) + 10;
        {
            // "Esc" chip at the right.
            const label = "Esc";
            const lw = ui.text.measure(theme.font_kbd, label);
            const r: Rect = .{ .x = q_r.right() - 16 - lw - 12, .y = q_r.centerY() - 10, .w = lw + 12, .h = 20 };
            const st = ui.button(Ui.id("palette.esc", 0), r);
            dl.border(r, 4, 1, theme.line_strong);
            _ = dl.textCentered(theme.font_kbd, r.x + 6, r.centerY(), label, if (st.hover) theme.text else theme.text_2);
            if (st.clicked) {
                self.close();
                return null;
            }
        }
        const text_right = q_r.right() - 16 - 40 - 12;
        const text_rect: Rect = .{ .x = x - 4, .y = q_r.y, .w = text_right - x + 4, .h = q_r.h };
        const d = ui.drag(Ui.id("palette.text", 0), text_rect);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (shown.len == 0 and self.editor.marked.items.len == 0) {
            const hint = switch (self.mode) {
                .commands => "Search commands, tabs, history…",
                .files => "Search files by name (append :line to go to a line)",
            };
            _ = dl.textEllipsis(theme.font_palette, x + 5, q_r.centerY(), hint, text_right - x - 5, theme.text_3);
        }
        // Text with selection, then the caret.
        {
            const font = theme.font_palette;
            const scale = dl.scale;
            const clip = blk: {
                const c = dl.currentClip();
                break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
            };
            const sel = self.editor.selection();
            var pen = x * scale;
            var caret_px = pen;
            var it = gfx_text.Utf8Iter{ .bytes = shown };
            var hit_offset: ?usize = null;
            while (true) {
                const at = it.index;
                if (at == self.editor.cursor) caret_px = pen;
                const cp = it.next() orelse break;
                const is_prefix = typed_prefix and at == 0;
                const f = if (is_prefix) theme.font_palette_prompt else font;
                const adv = ui.text.advance(f, cp) * scale + (if (is_prefix) 10 * scale else 0);
                if ((d.started or d.dragging) and hit_offset == null and ui.mx * scale < pen + adv / 2) hit_offset = at;
                if (sel) |s| if (at >= s[0] and at < s[1]) {
                    dl.rect(.{ .x = pen / scale, .y = q_r.centerY() - 10, .w = adv / scale, .h = 20 }, theme.selection());
                };
                const baseline_px = @round(ui.text.baselineForCenter(f, q_r.centerY()) * scale);
                _ = dl.glyph(f, cp, pen, baseline_px, if (is_prefix) theme.accent else theme.text, clip);
                pen += adv;
            }
            if (d.started or d.dragging) {
                const off = hit_offset orelse shown.len;
                if (d.started and d.double_clicked) {
                    self.editor.selectWordAt(off);
                } else if (d.started) {
                    self.editor.setCursor(off, ui.mods.shift);
                } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                    self.editor.setCursor(off, true);
                }
            }
            var cx = caret_px / scale;
            if (self.editor.marked.items.len > 0) {
                const w = dl.textCentered(font, cx, q_r.centerY(), self.editor.marked.items, theme.text);
                dl.rect(.{ .x = cx, .y = q_r.centerY() + 9, .w = w, .h = 1 }, theme.text_2);
                cx += w;
            }
            self.caret = .{ .x = cx + 1, .y = q_r.centerY() - 9.5, .w = 2, .h = 19 };
            if (self.blink_on or ui.down) dl.rect(self.caret, theme.accent);
        }

        // ── scope chips ──
        const c_r: Rect = .{ .x = panel.x, .y = q_r.bottom(), .w = panel.w, .h = chips_h };
        dl.rect(.{ .x = c_r.x, .y = c_r.bottom() - 1, .w = c_r.w, .h = 1 }, theme.line);
        var cx = c_r.x + 16;
        for (self.mode.chips(), 0..) |s, si| {
            const active = s == scope;
            const has_prefix = s.prefix() != 0;
            const glyph = [_]u8{s.prefix()};
            const gw: f32 = if (has_prefix) ui.text.measure(theme.font_chip_prefix, &glyph) + 6 else 0;
            const lw = ui.text.measure(theme.font_chip, s.label());
            const r: Rect = .{ .x = cx, .y = c_r.y + 10, .w = 10 + gw + lw + 10, .h = 24 };
            const st = ui.button(Ui.id("palette.chip", si), r);
            if (active) {
                dl.rrect(r, 12, theme.chip_active);
            } else {
                if (st.hover) dl.rrect(r, 12, theme.hover);
                dl.border(r, 12, 1, theme.line);
            }
            var tx = r.x + 10;
            if (has_prefix) tx += dl.textCentered(theme.font_chip_prefix, tx, r.centerY(), &glyph, if (active) theme.accent else theme.text_3) + 6;
            _ = dl.textCentered(theme.font_chip, tx, r.centerY(), s.label(), if (active) theme.text else theme.text_2);
            if (st.clicked) self.setScope(s);
            cx += r.w + 6;
        }

        // ── rows ──
        const l_r: Rect = .{ .x = panel.x, .y = c_r.bottom(), .w = panel.w, .h = visible_list };
        const wheel = ui.takeScroll(l_r);
        if (wheel != 0) self.scroll = std.math.clamp(self.scroll - wheel, 0, @max(0, list_h - visible_list));
        dl.pushClip(l_r);
        const oy = l_r.y - self.scroll;
        if (self.count == 0) {
            _ = dl.textCentered(theme.font_row, l_r.x + list_pad_x + 10, oy + list_pad_top + row_h / 2, "No matches", theme.text_3);
        }
        var last: ?Group = null;
        for (0..self.count) |ei| {
            const e = &self.entries[ei];
            const y = oy + ys[ei];
            if (last == null or last.? != e.group) {
                const gh: f32 = if (last == null) group_h_first else group_h;
                _ = dl.textCentered(theme.font_group, l_r.x + list_pad_x + 8, y - gh + 8 + (gh - 12) / 2, groupTitle(e.group), theme.text_3);
                last = e.group;
            }
            const r: Rect = .{ .x = l_r.x + list_pad_x, .y = y, .w = l_r.w - 2 * list_pad_x, .h = row_h };
            const st = ui.button(Ui.id("palette.row", ei), r);
            const selected = ei == self.selected;
            if (selected) {
                dl.rrect(r, 8, theme.accent.alpha(0.14));
            } else if (st.hover) dl.rrect(r, 8, theme.hover);
            if (st.clicked) pick = e.pick;

            var tx = r.x + 10;
            var right = r.right() - 10;
            if (e.detail.len > 0) {
                const dfont = if (e.kbd) theme.font_kbd else theme.font_status;
                var fit_buf: [detail_len]u8 = undefined;
                const detail = if (e.kbd) e.detail else fitLeft(ui, dfont, e.detail, (r.w - 20) * 0.45, &fit_buf);
                right -= dl.textRight(dfont, right, r.centerY(), detail, theme.text_3) + 10;
            }
            if (e.dot) |c| {
                dl.circle(tx + 3.5, r.centerY(), 3.5, c);
                tx += 7 + 10;
            }
            if (e.prefix.len > 0) tx += dl.textCentered(theme.font_row, tx, r.centerY(), e.prefix, theme.text_2) + 5;
            const lf = if (e.mono) theme.font_row_mono else theme.font_row;
            const lb = if (e.mono) theme.font_row_mono_bold else theme.font_row_bold;
            drawHighlighted(ui, lf, lb, tx, r.centerY(), e.label, e.mask, right - tx, if (e.dim) theme.text_2 else theme.text);
        }
        dl.popClip();

        // ── footer ──
        const f_r: Rect = .{ .x = panel.x, .y = l_r.bottom(), .w = panel.w, .h = footer_h };
        dl.rect(f_r, theme.bg_panel_footer);
        dl.rect(.{ .x = f_r.x, .y = f_r.y, .w = f_r.w, .h = 1 }, theme.line);
        var fx = f_r.x + 16;
        const hints: []const []const u8 = switch (self.mode) {
            .commands => &.{ "↑↓ move", "↵ run", "Tab switch scope", "Esc close" },
            .files => &.{ "↑↓ move", "↵ open", "Tab switch scope", "Esc close" },
        };
        for (hints) |h| fx += dl.textCentered(theme.font_kbd, fx, f_r.centerY(), h, theme.text_3) + 16;
        const tail: []const u8 = switch (self.mode) {
            .commands => "type a prefix to narrow: > @ ! :",
            .files => "type a prefix to narrow: @ : >",
        };
        if (f_r.right() - 16 - ui.text.measure(theme.font_kbd, tail) > fx) {
            _ = dl.textRight(theme.font_kbd, f_r.right() - 16, f_r.centerY(), tail, theme.text_3);
        }

        if (pick) |p| {
            if (p == .none) pick = null else self.accept();
        }
        return pick;
    }
};

/// Draws `str` with the code points flagged in `mask` in the bold face,
/// truncated with an ellipsis when wider than `max_w`.
fn drawHighlighted(ui: *Ui, font: Font, bold: Font, x: f32, center_y: f32, str: []const u8, mask: u64, max_w: f32, color: Color) void {
    const dl = ui.dl;
    if (max_w <= 0) return;
    if (mask == 0) {
        _ = dl.textEllipsis(font, x, center_y, str, max_w, color);
        return;
    }
    const scale = dl.scale;
    const clip = blk: {
        const c = dl.currentClip();
        break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
    };
    const ell_w = ui.text.measure(font, "…");
    var pen = x * scale;
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = str };
    while (it.next()) |cp| : (idx += 1) {
        const f = if (idx < 64 and (mask >> @intCast(idx)) & 1 == 1) bold else font;
        const baseline_px = @round(ui.text.baselineForCenter(f, center_y) * scale);
        const adv = ui.text.advance(f, cp) * scale;
        if ((pen + adv) / scale - x + ell_w > max_w and it.index < str.len) {
            _ = dl.textCentered(font, pen / scale, center_y, "…", color);
            return;
        }
        pen += dl.glyph(f, cp, pen, baseline_px, color, clip);
    }
}

/// `s` shortened from the left to fit `max_w`: whole path components go
/// first ("…/ui/panes"), then characters. Uses `buf` for the result.
fn fitLeft(ui: *Ui, font: Font, s: []const u8, max_w: f32, buf: []u8) []const u8 {
    if (ui.text.measure(font, s) <= max_w) return s;
    const ell_w = ui.text.measure(font, "…");
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, start, '/')) |slash| {
        start = slash + 1;
        const tail = s[start..];
        if (ell_w + ui.text.measure(font, tail) <= max_w) return std.fmt.bufPrint(buf, "…{s}", .{tail}) catch tail;
    }
    var it = gfx_text.Utf8Iter{ .bytes = s[start..] };
    while (it.next()) |_| {
        const tail = s[start + it.index ..];
        if (tail.len == 0) break;
        if (ell_w + ui.text.measure(font, tail) <= max_w) return std.fmt.bufPrint(buf, "…{s}", .{tail}) catch tail;
    }
    return "…";
}

// ── tests ────────────────────────────────────────────────────────────────
test "scope prefixes depend on the mode" {
    try std.testing.expectEqual(Scope.commands, Scope.fromPrefix('>', .commands).?);
    try std.testing.expectEqual(Scope.history, Scope.fromPrefix('!', .commands).?);
    try std.testing.expectEqual(Scope.settings, Scope.fromPrefix(':', .commands).?);
    try std.testing.expect(Scope.fromPrefix('x', .commands) == null);
    // Quick open: `:` is go to line, `!` means nothing, `>` the commands.
    try std.testing.expectEqual(Scope.line, Scope.fromPrefix(':', .files).?);
    try std.testing.expect(Scope.fromPrefix('!', .files) == null);
    try std.testing.expectEqual(Scope.commands, Scope.fromPrefix('>', .files).?);
    try std.testing.expectEqual(Scope.tabs, Scope.fromPrefix('@', .files).?);
}

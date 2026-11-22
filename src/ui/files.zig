//! Files panel (right side): the folder the current shell is in, under a
//! Files / Search / Git strip. This file is the panel's shell — the
//! splitter on its left edge, the strip, and the three views it mounts:
//! the tree (the `explorer` feature: folders unfold in place, files open
//! in a viewer tab, a file can be pinned to a project, rows have a menu
//! and can be dragged), the Search view (`search_panel.zig`: find in
//! files, VS Code style) and, inside a git repository, the Git view (the
//! `repo` feature), whose reading also colours the names in the tree.
//! What a view asks of the app comes back as one `Result`; the app opens
//! the files, menus and boxes and runs the drags.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const repo = @import("../features/repo/repo.zig");
const explorer = @import("../features/explorer/explorer.zig");
const search_panel = @import("search_panel.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

/// A secondary click in the tree: what the row is and where the menu
/// should open; the path is `menuPath()`.
pub const FileMenu = explorer.FileMenu;

/// A Search match to open: the file, the spot in it.
pub const OpenAt = search_panel.Open;

/// A change of the Git view to show side by side.
pub const Diff = repo.Diff;

pub const Result = struct {
    open_file: ?[]const u8 = null,
    pin_file: ?[]const u8 = null,
    /// The Git view: a change to show side by side (valid this frame).
    open_diff: ?Diff = null,
    /// The Git view wants a discard confirmed (see `discardConfirmed`).
    confirm: ?repo.Confirm = null,
    /// The Git view's branch menu to open (see `menuPicked`).
    menu: ?repo.Menu = null,
    /// The Search view: a match to open (valid this frame).
    open_at: ?OpenAt = null,
    /// The Search view wants a Replace All confirmed (see `replaceConfirmed`).
    replace: ?search_panel.Confirm = null,
    /// A right-click on a row, the header or the blank space: the app
    /// opens the files menu for `menuPath()`.
    file_menu: ?FileMenu = null,
    /// A press on a row travelled: the app starts dragging this path
    /// (valid this frame).
    drag_file: ?[]const u8 = null,
    /// The dragged path was let go over a folder of the tree: the folder
    /// it moves into (valid this frame).
    drop_into: ?[]const u8 = null,
};

/// What the panel shows: the tree, the Search view, or the Git view.
pub const Mode = enum { files, search, git };

pub const FileBrowser = struct {
    gpa: std.mem.Allocator,
    width: f32 = theme.files_default_w,
    visible: bool = true,
    drag_dx: f32 = 0,
    tree: explorer.Tree,
    mode: Mode = .files,
    git: repo.Panel,
    search: search_panel.Panel,

    pub fn init(gpa: std.mem.Allocator) FileBrowser {
        return .{ .gpa = gpa, .tree = explorer.Tree.init(gpa), .git = repo.Panel.init(gpa), .search = search_panel.Panel.init(gpa) };
    }

    pub fn deinit(self: *FileBrowser) void {
        self.git.deinit();
        self.search.deinit();
        self.tree.deinit();
    }

    /// The folder the tree shows.
    pub fn rootPath(self: *const FileBrowser) []const u8 {
        return self.tree.rootPath();
    }

    /// The path the last menu was asked for (a file, a folder, or the
    /// folder on show).
    pub fn menuPath(self: *const FileBrowser) []const u8 {
        return self.tree.menuPath();
    }

    /// Lists the folders on show again, right now (after a rename, a
    /// move, a new file …).
    pub fn refresh(self: *FileBrowser, now: f64) void {
        self.tree.refresh(now);
    }

    /// Unfolds the folders down to `path` and, for a file, highlights it.
    pub fn reveal(self: *FileBrowser, path: []const u8) void {
        self.tree.reveal(path);
    }

    pub fn currentWidth(self: *const FileBrowser) f32 {
        return if (self.visible) self.width else 0;
    }

    pub fn toggle(self: *FileBrowser) void {
        self.visible = !self.visible;
    }

    /// Points the panel at `dir` (no-op if it already is).
    pub fn setRoot(self: *FileBrowser, dir: []const u8, now: f64) void {
        if (std.mem.eql(u8, self.tree.rootPath(), dir)) return;
        self.git.setDir(dir);
        self.search.setRoot(dir);
        self.tree.setRoot(dir, now);
    }

    /// Re-reads the visible folders now and then, and collects git's
    /// readings. True if anything changed.
    pub fn tick(self: *FileBrowser, now: f64) bool {
        if (!self.visible or self.tree.rootPath().len == 0) return false;
        var changed = self.git.tick(now);
        self.search.in_repo = self.git.isRepoFor(self.search.dirPath());
        if (self.search.tick(now)) changed = true;
        if (self.tree.tick(now)) changed = true;
        return changed;
    }

    // ── keyboard, routed by the app while a box of the Git or Search view has it ──
    pub fn hasFocus(self: *const FileBrowser) bool {
        if (!self.visible) return false;
        return switch (self.mode) {
            .git => self.git.hasFocus(),
            .search => self.search.hasFocus(),
            .files => false,
        };
    }

    /// ⌘⇧↵: amends, when the Git view's message box has the keyboard.
    /// False when it was not for this panel.
    pub fn commitAmend(self: *FileBrowser) bool {
        if (!self.visible or self.mode != .git or !self.git.hasFocus()) return false;
        self.git.amend();
        return true;
    }

    pub fn onText(self: *FileBrowser, utf8: []const u8) void {
        switch (self.mode) {
            .git => self.git.onText(utf8),
            .search => self.search.onText(utf8),
            .files => {},
        }
    }

    pub fn onMarkedText(self: *FileBrowser, utf8: []const u8) void {
        switch (self.mode) {
            .git => self.git.onMarkedText(utf8),
            .search => self.search.onMarkedText(utf8),
            .files => {},
        }
    }

    pub fn onEdit(self: *FileBrowser, cmd: EditCommand) void {
        switch (self.mode) {
            .git => self.git.onEdit(cmd),
            .search => self.search.onEdit(cmd),
            .files => {},
        }
    }

    pub fn onCtrl(self: *FileBrowser, key: u8) void {
        switch (self.mode) {
            .git => self.git.onCtrl(key),
            .search => self.search.onCtrl(key),
            .files => {},
        }
    }

    pub fn paste(self: *FileBrowser, utf8: []const u8) void {
        switch (self.mode) {
            .git => self.git.paste(utf8),
            .search => self.search.paste(utf8),
            .files => {},
        }
    }

    pub fn copy(self: *FileBrowser, out: *std.ArrayList(u8), cut: bool) bool {
        return switch (self.mode) {
            .git => self.git.copy(out, cut),
            .search => self.search.copy(out, cut),
            .files => false,
        };
    }

    pub fn hasMarkedText(self: *const FileBrowser) bool {
        return switch (self.mode) {
            .git => self.git.hasMarkedText(),
            .search => self.search.hasMarkedText(),
            .files => false,
        };
    }

    pub fn caretRect(self: *const FileBrowser) ui_mod.Rect {
        return switch (self.mode) {
            .git => self.git.caretRect(),
            .search => self.search.caretRect(),
            .files => .{},
        };
    }

    /// The discard box was accepted.
    pub fn discardConfirmed(self: *FileBrowser) void {
        self.git.discardConfirmed();
    }

    /// The Replace All box was accepted.
    pub fn replaceConfirmed(self: *FileBrowser) void {
        self.search.replaceConfirmed();
    }

    /// ⌘⇧F: the panel comes up on the Search view with the keyboard in
    /// its box.
    pub fn openSearch(self: *FileBrowser, now: f64) void {
        self.visible = true;
        self.setMode(.search);
        self.search.activate(self.tree.rootPath(), now);
    }

    /// Switches views; the one left gives the keyboard up.
    fn setMode(self: *FileBrowser, mode: Mode) void {
        if (self.mode == mode) return;
        self.dropFocus();
        self.mode = mode;
    }

    /// A box of the Git or Search view gives the keyboard up (a tab took it).
    pub fn dropFocus(self: *FileBrowser) void {
        switch (self.mode) {
            .git => self.git.dropFocus(),
            .search => self.search.dropFocus(),
            .files => {},
        }
    }

    /// Row `i` of the branch menu was picked.
    pub fn menuPicked(self: *FileBrowser, i: usize) void {
        self.git.menuPicked(i);
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// `drag` is the path being dragged from here, if any: folders under
    /// the pointer offer to take it, and rows do not click meanwhile.
    pub fn draw(self: *FileBrowser, ui: *Ui, rect: Rect, can_pin: bool, drag: ?[]const u8) Result {
        var res: Result = .{};
        if (!self.visible or rect.w <= 0) return res;
        const dl = ui.dl;

        // Splitter on the left edge, handled first so it wins over the rows.
        const grip: Rect = .{ .x = rect.x - 4, .y = rect.y, .w = 8, .h = rect.h };
        const d = ui.drag(Ui.id("files.split", 0), grip);
        if (d.started) self.drag_dx = ui.mx - rect.x;
        if (d.double_clicked) {
            self.width = theme.files_default_w;
        } else if (d.dragging) {
            const want = rect.right() - (ui.mx - self.drag_dx);
            if (want < 120) {
                self.visible = false;
            } else {
                self.width = std.math.clamp(want, theme.files_min_w, theme.files_max_w);
            }
        }
        if (d.hover or d.dragging) ui.cursor = .resize_lr;

        dl.rect(rect, theme.bg_side);
        dl.rect(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, theme.line);
        dl.pushClip(.{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 1, .h = rect.h });
        defer dl.popClip();

        var y = rect.y;
        // The tabs: Files and Search always, Git inside a repository.
        // A commit that failed in the Git view: what it printed, in a tab.
        if (self.git.takeFailure()) |path| res.open_file = path;
        const root = self.tree.rootPath();
        const is_repo = self.git.isRepoFor(root);
        if (!is_repo and self.mode == .git) self.mode = .files;
        self.drawModeStrip(ui, rect, &y, is_repo);
        const area: Rect = .{ .x = rect.x + 1, .y = y, .w = rect.w - 1, .h = @max(0, rect.bottom() - y) };
        switch (self.mode) {
            .files => {
                const tr = self.tree.draw(ui, area, &self.git, can_pin, drag);
                if (tr.open_file) |path| res.open_file = path;
                res.pin_file = tr.pin_file;
                res.file_menu = tr.file_menu;
                res.drag_file = tr.drag_file;
                res.drop_into = tr.drop_into;
            },
            .git => {
                const gr = self.git.draw(ui, area);
                res.open_diff = gr.open_diff;
                res.confirm = gr.confirm;
                res.menu = gr.menu;
            },
            .search => {
                const sr = self.search.draw(ui, area, root);
                res.open_at = sr.open;
                res.replace = sr.confirm;
            },
        }

        if (d.hover or d.dragging) {
            dl.rect(.{ .x = rect.x, .y = rect.y, .w = 2, .h = rect.h }, theme.accent.alpha(if (d.dragging) 0.9 else 0.55));
        }
        return res;
    }

    /// The Files / Search / Git tabs, drawn like the tab strip's but always
    /// at compact mode's sizes: Search carries the number of matches, Git
    /// the number of changes.
    fn drawModeStrip(self: *FileBrowser, ui: *Ui, rect: Rect, y: *f32, is_repo: bool) void {
        const dl = ui.dl;
        const strip_h = theme.compact_strip_h;
        const pad = theme.compact_tab_pad;
        const pill_y = y.* + (strip_h - theme.compact_tab_pill_h) / 2;
        var x = rect.x + 6;
        const modes = [_]struct { mode: Mode, label: []const u8 }{ .{ .mode = .files, .label = "Files" }, .{ .mode = .search, .label = "Search" }, .{ .mode = .git, .label = "Git" } };
        for (modes, 0..) |m, i| {
            if (m.mode == .git and !is_repo) continue;
            var count_buf: [16]u8 = undefined;
            const n: u32 = switch (m.mode) {
                .git => self.git.changeCount(),
                .search => self.search.matchCount(),
                .files => 0,
            };
            const count: []const u8 = if (n > 0) std.fmt.bufPrint(&count_buf, "{d}", .{n}) catch "" else "";
            const selected = self.mode == m.mode;
            const font = if (selected) theme.font_tab_active else theme.font_tab;
            const lw = ui.text.measure(font, m.label);
            const cw: f32 = if (count.len > 0) ui.text.measure(repo.font_badge, count) + 14 else 0;
            const r: Rect = .{ .x = x, .y = y.*, .w = lw + 2 * pad + cw, .h = strip_h };
            const st = ui.button(Ui.id("files.mode", i), r);
            if (st.hover and !selected) dl.rrect(.{ .x = r.x, .y = pill_y, .w = r.w, .h = theme.compact_tab_pill_h }, theme.compact_row_radius, theme.hover);
            const color = if (selected) theme.text else if (st.hover) theme.text_2 else theme.text_3;
            _ = dl.textCentered(font, r.x + pad, r.centerY(), m.label, color);
            if (count.len > 0) {
                const pill: Rect = .{ .x = r.x + pad + lw + 6, .y = r.centerY() - 8, .w = cw - 6, .h = 16 };
                dl.rrect(pill, 8, if (selected) theme.accent else theme.accent.alpha(0.55));
                _ = dl.textCentered(repo.font_badge, pill.x + 4, pill.centerY(), count, theme.on_accent);
            }
            if (selected) dl.rect(.{ .x = r.x, .y = r.bottom() - 2, .w = r.w, .h = 2 }, theme.accent);
            if (st.clicked) {
                self.setMode(m.mode);
                if (m.mode == .search) self.search.activate(self.tree.rootPath(), ui.now);
            }
            x += r.w;
        }
        dl.rect(.{ .x = rect.x + 1, .y = y.* + strip_h - 1, .w = rect.w - 1, .h = 1 }, theme.line);
        y.* += strip_h + 6;
    }
};

//! Floating, modal bits drawn over the workspace: context menus (a tab's,
//! a sidebar project's or resource's, a files-panel row's) and the
//! alert-like boxes they lead to (rename, close confirmation, the icon
//! picker, the name box for a new file). At most one is open; while it is,
//! the workspace under it is inert and keyboard input comes here (the app
//! routes it, see `App`). Two menus have a submenu: the files menu's
//! "Open with", whose rows the app hands over when it opens the menu, and
//! the tab menu's "Split & Move" (the four sides).
const std = @import("std");
const draw = @import("../gfx/draw.zig");
const gfx_text = @import("../gfx/text.zig");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const Editor = @import("../input/editor.zig").Editor;
const EditCommand = @import("../events.zig").EditCommand;
const icon_spec = @import("icon_spec.zig");
const Side = @import("../tabs/layout.zig").Side;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

pub const Mode = enum { none, menu, rename, confirm, icons, list };

/// What an open menu or box is about: a tab (by uid), a sidebar project
/// or resource (by id), the default project (no id), or a path of the
/// files panel (the panel remembers which).
pub const Subject = enum { tab, project, default_project, resource, file };

/// What a confirm box leads to when it is accepted (`close_others` and
/// `close_right` are the tab menu's "Close Others" / "Close to the Right").
pub const ConfirmKind = enum { close_tab, close_others, close_right, git_discard, delete_file, search_replace };

/// What a files-panel menu is about: a file, a folder, or the folder on
/// show itself (a click on the panel's blank space).
pub const FileKind = enum { file, folder, root };

/// What the name box asks for on a path: a new name, or the name of a
/// new file or folder inside it.
pub const NameKind = enum { rename, new_file, new_folder };

/// A row of the "Open with" submenu: what it shows and what comes back
/// when it is picked (an application's bundle path).
pub const SubItem = struct { label: []const u8, value: []const u8 };

/// What a tab's menu offers depends on the tab; the app says what applies.
pub const TabMenuOpts = struct {
    /// "Rename Tab…" (not for a tab whose title is its identity, like Settings).
    renamable: bool = true,
    /// The tab stands for a path on disk: the "Copy Path" rows and
    /// "Reveal in Finder".
    has_path: bool = false,
    /// The path is a document (not a shell's directory): the rename box
    /// then says the file keeps its name.
    document: bool = false,
    /// Tabs in the same strip besides this one, and to its right: with
    /// none, "Close Others" / "Close to the Right" are greyed out.
    others: usize = 0,
    to_right: usize = 0,
};

/// What the user decided; the app carries it out.
pub const Outcome = union(enum) {
    /// Tab menu → "Rename Tab…": open the rename box for this tab.
    rename_tab: u32,
    /// Tab menu → "Split & Move" → a side: the tab moves into a new pane
    /// on that side of its own.
    split_tab: struct { uid: u32, side: Side },
    /// Tab menu → "Split Right": a new pane on that side of the tab's own,
    /// with a shell (the tab stays where it is).
    split_beside: struct { uid: u32, side: Side },
    /// Tab menu → "Close": close this tab (the app asks first if it is busy).
    close_tab: u32,
    /// Tab menu → "Close Others" / "Close to the Right": the other tabs of
    /// the strip (the app asks first if any of them is busy).
    close_others: u32,
    close_right: u32,
    /// Those confirmations accepted.
    close_others_confirmed: u32,
    close_right_confirmed: u32,
    /// Tab menu → "Copy Path" / "Copy Relative Path".
    copy_tab_path: struct { uid: u32, relative: bool },
    /// Tab menu → "Reveal in Finder".
    reveal_tab: u32,
    /// Rename box confirmed for a tab. `name` points into the overlay's
    /// editor and is valid until the overlay is next opened.
    renamed: struct { uid: u32, name: []const u8 },
    /// Close confirmation accepted.
    close_confirmed: u32,
    /// The Git panel's "Discard" box accepted: the panel runs what it had pending.
    discard_confirmed: void,
    /// A row of a list menu (the Git panel's branch menu) was picked.
    list_picked: usize,
    /// The Search view's "Replace All" box accepted: the view rewrites the files.
    replace_confirmed: void,
    /// Project menu → "Rename…": open the rename box for this project.
    rename_project: u32,
    /// Rename box confirmed for a project (`name` as in `renamed`; blank
    /// means back to the folder's name).
    project_renamed: struct { id: u32, name: []const u8 },
    /// Project menu → "New Shell Group": a new group of shells under the
    /// project (id 0: under the default project).
    new_shells: u32,
    /// Project menu → "Remove Project".
    remove_project: u32,
    /// Resource menu → "Rename…": open the rename box for this resource.
    rename_resource: u32,
    /// Rename box confirmed for a resource (`name` as in `renamed`).
    resource_renamed: struct { id: u32, name: []const u8 },
    /// Resource menu → "Remove from Project".
    remove_resource: u32,
    /// Menu → "Set Icon…": open the icon picker for a project, the
    /// default project or a resource.
    set_icon: struct { subject: Subject, id: u32 },
    /// Icon picker: a name for `icon_spec` (a static string), null for none.
    icon_picked: struct { subject: Subject, id: u32, icon: ?[]const u8 },
    /// Files menu → "Open externally": the application the system would use.
    open_externally: void,
    /// Files menu → "Open with" → an application (its bundle path, valid
    /// until the overlay is next opened).
    open_with: []const u8,
    /// Files menu → "Reveal in Finder".
    reveal_in_finder: void,
    /// Files menu → "Copy path" (relative to the folder on show) or
    /// "Copy absolute path".
    copy_path: struct { absolute: bool },
    /// Files menu → "Rename…" / "New File…" / "New Folder…": open the name box.
    name_file: NameKind,
    /// The name box confirmed for a path (`name` as in `renamed`).
    file_named: struct { kind: NameKind, name: []const u8 },
    /// Files menu → "Delete": the app asks first.
    delete_file: void,
    /// The delete box accepted.
    delete_confirmed: void,
};

const MenuItem = enum { rename, split_beside, split_move, close, close_others, close_right, tab_copy_path, tab_copy_rel, new_shells, set_icon, remove, new_file, new_folder, open_external, open_with, reveal, copy_path, copy_abs_path, delete };
const MenuEntry = struct {
    item: MenuItem,
    label: []const u8,
    /// The keyboard shortcut shown at the right, if the row has one.
    kbd: []const u8 = "",
    /// A divider above the row.
    sep_before: bool = false,
    /// The row unfolds the submenu instead of doing something itself.
    submenu: bool = false,
    /// Greyed out: nothing to do right now (a "Close Others" with no others).
    disabled: bool = false,
};
/// Every row a tab's menu can have; `openTabMenu` keeps the ones that
/// apply (see `TabMenuOpts`), carrying a dropped row's divider forward.
const tab_menu_all = [_]MenuEntry{
    .{ .item = .close, .label = "Close", .kbd = "⌘W" },
    .{ .item = .close_others, .label = "Close Others" },
    .{ .item = .close_right, .label = "Close to the Right" },
    .{ .item = .rename, .label = "Rename Tab…", .sep_before = true },
    .{ .item = .tab_copy_path, .label = "Copy Path", .sep_before = true },
    .{ .item = .tab_copy_rel, .label = "Copy Relative Path" },
    .{ .item = .reveal, .label = "Reveal in Finder", .sep_before = true },
    .{ .item = .split_beside, .label = "Split Right", .kbd = "⌘D" },
    .{ .item = .split_move, .label = "Split & Move", .submenu = true },
};
/// The "Split & Move" submenu: one row per side, in this order.
const split_sides = [_]Side{ .left, .right, .top, .bottom };
const split_labels = [_][]const u8{ "Left", "Right", "Up", "Down" };
const project_menu = [_]MenuEntry{
    .{ .item = .rename, .label = "Rename…" },
    .{ .item = .new_shells, .label = "New Shell Group" },
    .{ .item = .set_icon, .label = "Set Icon…" },
    .{ .item = .remove, .label = "Remove Project" },
};
const default_project_menu = [_]MenuEntry{
    .{ .item = .new_shells, .label = "New Shell Group" },
    .{ .item = .set_icon, .label = "Set Icon…" },
};
const resource_menu = [_]MenuEntry{
    .{ .item = .rename, .label = "Rename…" },
    .{ .item = .set_icon, .label = "Set Icon…" },
    .{ .item = .remove, .label = "Remove from Project" },
};
const file_menu = [_]MenuEntry{
    .{ .item = .open_external, .label = "Open externally" },
    .{ .item = .open_with, .label = "Open with", .submenu = true },
    .{ .item = .reveal, .label = "Reveal in Finder" },
    .{ .item = .copy_path, .label = "Copy path", .sep_before = true },
    .{ .item = .copy_abs_path, .label = "Copy absolute path" },
    .{ .item = .rename, .label = "Rename…", .sep_before = true },
    .{ .item = .delete, .label = "Delete" },
};
const folder_menu = [_]MenuEntry{
    .{ .item = .new_file, .label = "New File…" },
    .{ .item = .new_folder, .label = "New Folder…" },
    .{ .item = .open_external, .label = "Open externally", .sep_before = true },
    .{ .item = .open_with, .label = "Open with", .submenu = true },
    .{ .item = .reveal, .label = "Reveal in Finder" },
    .{ .item = .copy_path, .label = "Copy path", .sep_before = true },
    .{ .item = .copy_abs_path, .label = "Copy absolute path" },
    .{ .item = .rename, .label = "Rename…", .sep_before = true },
    .{ .item = .delete, .label = "Delete" },
};
/// The folder on show itself (no "Copy path": that would be nothing).
const root_menu = [_]MenuEntry{
    .{ .item = .new_file, .label = "New File…" },
    .{ .item = .new_folder, .label = "New Folder…" },
    .{ .item = .open_external, .label = "Open externally", .sep_before = true },
    .{ .item = .open_with, .label = "Open with", .submenu = true },
    .{ .item = .reveal, .label = "Reveal in Finder" },
    .{ .item = .copy_abs_path, .label = "Copy absolute path", .sep_before = true },
};

// Metrics (points), in the palette's idiom.
const menu_w: f32 = 176;
const menu_pad: f32 = 5;
const menu_row_h: f32 = 28;
/// A divider's share of a menu's height.
const menu_sep_h: f32 = 9;
const submenu_min_w: f32 = 160;
const submenu_max_w: f32 = 320;
const box_w: f32 = 420;
const box_pad: f32 = 22;
const title_h: f32 = 22;
const line_h: f32 = 18;
const field_h: f32 = 34;
const button_h: f32 = 30;
const font_title = Font.semibold(15);
// The icon picker's grid.
const cell: f32 = 40;
const cell_gap: f32 = 6;
const section_gap: f32 = 14;

pub const Overlay = struct {
    gpa: std.mem.Allocator,
    mode: Mode = .none,
    /// What the open menu or box is about, and its uid (tab) or id
    /// (project, resource).
    subject: Subject = .tab,
    id: u32 = 0,

    // Menu: where it was summoned and the row the keyboard is on.
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,
    highlighted: ?usize = null,
    /// Where the pointer was last frame: the mouse only takes the
    /// highlight from the keyboard when it moves (after a right-click it
    /// rests on the menu's corner).
    last_mx: f32 = -1,
    last_my: f32 = -1,
    /// A tab's menu, as built for the tab it is about (see `openTabMenu`).
    tab_rows: [tab_menu_all.len]MenuEntry = undefined,
    tab_rows_len: usize = 0,
    /// Whether the tab a menu or rename box is about shows a document
    /// (the rename box then says the file keeps its name).
    tab_document: bool = false,
    /// For a files-panel menu or box: what the path is.
    file_kind: FileKind = .file,

    // Submenu ("Open with", "Split & Move"): its rows (copied) and what
    // they stand for, whether it is unfolded, and the row the keyboard is on.
    sub_labels: std.ArrayList([]u8) = .empty,
    sub_values: std.ArrayList([]u8) = .empty,
    sub_open: bool = false,
    sub_highlighted: ?usize = null,
    sub_scroll: f32 = 0,

    // Rename / name box: the name being typed, what it is for, and what
    // was wrong with the last attempt (blank: nothing).
    editor: Editor,
    name_kind: NameKind = .rename,
    name_error_buf: [120]u8 = undefined,
    name_error_len: usize = 0,
    seen_version: u64 = 0,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    /// Caret in window coordinates (for the IME candidate window).
    caret: Rect = .{},

    // Confirm box: its heading, its reason for asking and the label of
    // the button that goes ahead.
    title_buf: [160]u8 = undefined,
    title_len: usize = 0,
    reason_buf: [200]u8 = undefined,
    reason_len: usize = 0,
    ok_buf: [32]u8 = undefined,
    ok_len: usize = 0,
    confirm_kind: ConfirmKind = .close_tab,

    // Icon picker: the row of `icon_spec` that is set now, if any.
    icon_current: ?usize = null,

    // List menu: the rows handed over (copied), the one that is current
    // (ticked) and the row a divider follows.
    list_items: std.ArrayList([]u8) = .empty,
    list_checked: ?usize = null,
    list_sep_after: ?usize = null,
    list_scroll: f32 = 0,

    pub fn init(gpa: std.mem.Allocator) Overlay {
        return .{ .gpa = gpa, .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Overlay) void {
        self.editor.deinit();
        self.clearList();
        self.clearSub();
        self.sub_labels.deinit(self.gpa);
        self.sub_values.deinit(self.gpa);
    }

    fn clearList(self: *Overlay) void {
        for (self.list_items.items) |s| self.gpa.free(s);
        self.list_items.clearRetainingCapacity();
    }

    fn clearSub(self: *Overlay) void {
        for (self.sub_labels.items) |s| self.gpa.free(s);
        for (self.sub_values.items) |s| self.gpa.free(s);
        self.sub_labels.clearRetainingCapacity();
        self.sub_values.clearRetainingCapacity();
        self.sub_open = false;
        self.sub_highlighted = null;
        self.sub_scroll = 0;
    }

    /// The context menu of a file, a folder or the folder on show, with
    /// its top-left corner at (x, y); `apps` (copied) fill the "Open with"
    /// submenu. The files panel keeps the path the menu is about.
    pub fn openFileMenu(self: *Overlay, kind: FileKind, x: f32, y: f32, apps: []const SubItem) void {
        self.openMenu(.file, 0, x, y);
        self.file_kind = kind;
        self.setSubRows(apps);
    }

    /// The context menu of a tab, with its top-left corner at (x, y):
    /// the rows that apply to it, and the sides in the "Split & Move" submenu.
    pub fn openTabMenu(self: *Overlay, uid: u32, x: f32, y: f32, opts: TabMenuOpts) void {
        self.openMenu(.tab, uid, x, y);
        self.tab_document = opts.document;
        self.tab_rows_len = 0;
        var pending_sep = false;
        for (tab_menu_all) |m| {
            const keep = switch (m.item) {
                .rename => opts.renamable,
                .tab_copy_path, .tab_copy_rel, .reveal => opts.has_path,
                else => true,
            };
            if (!keep) {
                pending_sep = pending_sep or m.sep_before;
                continue;
            }
            var row = m;
            row.sep_before = self.tab_rows_len > 0 and (m.sep_before or pending_sep);
            row.disabled = switch (m.item) {
                .close_others => opts.others == 0,
                .close_right => opts.to_right == 0,
                else => false,
            };
            pending_sep = false;
            self.tab_rows[self.tab_rows_len] = row;
            self.tab_rows_len += 1;
        }
        var sides: [split_sides.len]SubItem = undefined;
        for (split_labels, 0..) |label, i| sides[i] = .{ .label = label, .value = @tagName(split_sides[i]) };
        self.setSubRows(&sides);
    }

    /// The submenu's rows (copied).
    fn setSubRows(self: *Overlay, rows: []const SubItem) void {
        self.clearSub();
        for (rows) |a| {
            const label = self.gpa.dupe(u8, a.label) catch continue;
            const value = self.gpa.dupe(u8, a.value) catch {
                self.gpa.free(label);
                continue;
            };
            self.sub_labels.append(self.gpa, label) catch {
                self.gpa.free(label);
                self.gpa.free(value);
                continue;
            };
            self.sub_values.append(self.gpa, value) catch {
                self.gpa.free(value);
                _ = self.sub_labels.pop();
                self.gpa.free(label);
            };
        }
    }

    /// The name box for a path of the files panel: a new name for it
    /// (prefilled with `current`, selected), or the name of a new file or
    /// folder inside it. `hint` is the line under the title.
    pub fn openName(self: *Overlay, kind: NameKind, file_kind: FileKind, current: []const u8, hint: []const u8) void {
        self.openRename(.file, 0, current);
        self.name_kind = kind;
        self.file_kind = file_kind;
        self.reason_len = copyInto(&self.reason_buf, hint);
        self.name_error_len = 0;
        // As Finder does: a file's name is selected without its extension.
        if (kind == .rename and file_kind == .file) {
            if (std.mem.lastIndexOfScalar(u8, current, '.')) |dot| {
                if (dot > 0) self.editor.cursor = dot;
            }
        }
    }

    /// The name box stays open and says what was wrong with the name.
    pub fn setNameError(self: *Overlay, why: []const u8) void {
        self.name_error_len = copyInto(&self.name_error_buf, why);
    }

    /// A menu of `items` (copied) with its top-left corner at (x, y):
    /// `checked` is ticked, a divider follows row `sep_after`. Picking a
    /// row gives `list_picked` with its index.
    pub fn openList(self: *Overlay, rows: []const []const u8, checked: ?usize, sep_after: ?usize, x: f32, y: f32) void {
        self.clearList();
        for (rows) |s| {
            const copy = self.gpa.dupe(u8, s) catch continue;
            self.list_items.append(self.gpa, copy) catch self.gpa.free(copy);
        }
        self.mode = .list;
        self.list_checked = checked;
        self.list_sep_after = sep_after;
        self.list_scroll = 0;
        self.anchor_x = x;
        self.anchor_y = y;
        self.highlighted = null;
        self.last_mx = -1;
        self.last_my = -1;
    }

    /// Whether the pointer moved since the last frame (the first frame
    /// after opening counts as a move).
    fn pointerMoved(self: *Overlay, ui: *Ui) bool {
        const moved = ui.mx != self.last_mx or ui.my != self.last_my;
        self.last_mx = ui.mx;
        self.last_my = ui.my;
        return moved;
    }

    pub fn isOpen(self: *const Overlay) bool {
        return self.mode != .none;
    }

    /// The tab the open menu or box is about, if it is about one (a git
    /// discard box is not, whatever its subject says).
    pub fn aboutTab(self: *const Overlay) ?u32 {
        if (!self.isOpen() or self.subject != .tab or self.mode == .list) return null;
        if (self.mode == .confirm) switch (self.confirm_kind) {
            .close_tab, .close_others, .close_right => {},
            .git_discard, .delete_file, .search_replace => return null,
        };
        return self.id;
    }

    pub fn close(self: *Overlay) void {
        self.mode = .none;
        self.highlighted = null;
        self.sub_open = false;
        self.sub_highlighted = null;
    }

    /// The context menu of a project or resource, with its top-left
    /// corner at (x, y) (a tab's is `openTabMenu`, a path's `openFileMenu`).
    pub fn openMenu(self: *Overlay, subject: Subject, id: u32, x: f32, y: f32) void {
        self.mode = .menu;
        self.subject = subject;
        self.id = id;
        self.anchor_x = x;
        self.anchor_y = y;
        self.highlighted = null;
        self.sub_open = false;
        self.sub_highlighted = null;
        self.last_mx = -1;
        self.last_my = -1;
    }

    /// The rows of the open menu.
    fn items(self: *const Overlay) []const MenuEntry {
        return switch (self.subject) {
            .tab => self.tab_rows[0..self.tab_rows_len],
            .project => &project_menu,
            .default_project => &default_project_menu,
            .resource => &resource_menu,
            .file => switch (self.file_kind) {
                .file => &file_menu,
                .folder => &folder_menu,
                .root => &root_menu,
            },
        };
    }

    /// The submenu row of the open menu, if it has one.
    fn submenuRow(self: *const Overlay) ?usize {
        for (self.items(), 0..) |m, i| {
            if (m.submenu) return i;
        }
        return null;
    }

    /// The icon picker for a project, the default project or a resource;
    /// `current` is the name set now (highlighted), if any.
    pub fn openIcons(self: *Overlay, subject: Subject, id: u32, current: ?[]const u8) void {
        self.mode = .icons;
        self.subject = subject;
        self.id = id;
        self.icon_current = icon_spec.indexOf(current);
        self.highlighted = self.icon_current;
        self.last_mx = -1;
        self.last_my = -1;
    }

    /// The rename box, prefilled with `current` (selected, so typing replaces it).
    pub fn openRename(self: *Overlay, subject: Subject, id: u32, current: []const u8) void {
        self.mode = .rename;
        self.subject = subject;
        self.id = id;
        self.editor.setText(current);
        if (current.len > 0) self.editor.anchor = 0;
    }

    /// The close confirmation; `reason` is the tab's sentence on what would be lost.
    pub fn openConfirm(self: *Overlay, uid: u32, title: []const u8, reason: []const u8) void {
        var heading_buf: [160]u8 = undefined;
        const heading = std.fmt.bufPrint(&heading_buf, "Close “{s}”?", .{title}) catch "Close this tab?";
        self.openConfirmAction(.close_tab, uid, heading, reason, "Close");
    }

    /// A box asking before something that cannot be undone (the Git
    /// panel's discards): `heading` as the question, `reason` under it,
    /// `ok` on the destructive button. What follows is the kind's outcome
    /// (`close_confirmed` for a tab, `discard_confirmed` for git).
    pub fn openConfirmAction(self: *Overlay, kind: ConfirmKind, id: u32, heading: []const u8, reason: []const u8, ok: []const u8) void {
        self.mode = .confirm;
        self.subject = .tab;
        self.confirm_kind = kind;
        self.id = id;
        self.title_len = copyInto(&self.title_buf, heading);
        self.reason_len = copyInto(&self.reason_buf, reason);
        self.ok_len = copyInto(&self.ok_buf, ok);
    }

    // ── per-tick ────────────────────────────────────────────────────────
    /// Caret blink while renaming; true when a redraw is needed.
    pub fn tick(self: *Overlay, now: f64) bool {
        if (self.mode != .rename) return false;
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

    // ── input ───────────────────────────────────────────────────────────
    pub fn onText(self: *Overlay, utf8: []const u8) void {
        if (self.mode == .rename) self.editor.insert(utf8);
    }

    pub fn onMarkedText(self: *Overlay, utf8: []const u8) void {
        if (self.mode == .rename) self.editor.setMarked(utf8);
    }

    pub fn onPaste(self: *Overlay, utf8: []const u8) void {
        if (self.mode != .rename) return;
        // A name is one line.
        const end = std.mem.indexOfAny(u8, utf8, "\r\n") orelse utf8.len;
        self.editor.insert(utf8[0..end]);
    }

    /// Esc cancels; ↵ confirms (in the menu: runs the highlighted row).
    pub fn onEdit(self: *Overlay, cmd: EditCommand) ?Outcome {
        switch (self.mode) {
            .none => {},
            .menu => if (self.sub_open) switch (cmd) {
                // Inside the submenu: up / down walk its rows, ← or Esc fold it.
                .cancel, .move_left, .select_left => self.foldSub(),
                .move_down, .select_down, .insert_tab => self.moveSubHighlight(1),
                .move_up, .select_up, .insert_backtab => self.moveSubHighlight(-1),
                .insert_newline, .insert_line_break => if (self.sub_highlighted) |i| return self.pickSub(i),
                else => {},
            } else switch (cmd) {
                .cancel => self.close(),
                .move_down, .select_down, .insert_tab => self.moveHighlight(1),
                .move_up, .select_up, .insert_backtab => self.moveHighlight(-1),
                // → (or ↵) on the "Open with" row unfolds its submenu.
                .move_right, .select_right => if (self.highlighted) |i| {
                    if (self.items()[i].submenu) self.unfoldSub(true);
                },
                .insert_newline, .insert_line_break => if (self.highlighted) |i| {
                    const m = self.items()[i];
                    if (m.submenu) self.unfoldSub(true) else if (!m.disabled) return self.pickMenu(i);
                },
                else => {},
            },
            .list => switch (cmd) {
                .cancel => self.close(),
                .move_down, .select_down, .insert_tab => self.moveHighlightN(1, self.list_items.items.len),
                .move_up, .select_up, .insert_backtab => self.moveHighlightN(-1, self.list_items.items.len),
                .insert_newline, .insert_line_break => if (self.highlighted) |i| return self.pickList(i),
                else => {},
            },
            .rename => switch (cmd) {
                .cancel => self.close(),
                .insert_newline, .insert_line_break => return self.renamed(),
                .insert_tab, .insert_backtab => {},
                else => _ = self.editor.apply(cmd),
            },
            .confirm => switch (cmd) {
                .cancel => self.close(),
                .insert_newline, .insert_line_break => return self.confirmClose(),
                else => {},
            },
            .icons => switch (cmd) {
                .cancel => self.close(),
                .move_right, .select_right, .insert_tab => self.moveIconHighlight(1),
                .move_left, .select_left, .insert_backtab => self.moveIconHighlight(-1),
                .move_down, .select_down => self.moveIconHighlight(@intCast(icon_cols)),
                .move_up, .select_up => self.moveIconHighlight(-@as(i32, @intCast(icon_cols))),
                .insert_newline, .insert_line_break => if (self.highlighted) |i| return self.pickIcon(icon_spec.nameAt(i)),
                else => {},
            },
        }
        return null;
    }

    /// Cells per row of the picker: what fits the box's inner width.
    const icon_cols: usize = @intFromFloat(@floor((box_w - 2 * box_pad + cell_gap) / (cell + cell_gap)));

    fn moveIconHighlight(self: *Overlay, delta: i32) void {
        const n: i32 = @intCast(icon_spec.count);
        const cur: i32 = if (self.highlighted) |h| @intCast(h) else (if (delta > 0) -1 else n);
        const next = cur + delta;
        // Left / right wrap around; up / down stop at the edges.
        if (delta == 1 or delta == -1) {
            self.highlighted = @intCast(@mod(next, n));
        } else if (next >= 0 and next < n) self.highlighted = @intCast(next);
    }

    fn pickIcon(self: *Overlay, icon: ?[]const u8) Outcome {
        const out: Outcome = .{ .icon_picked = .{ .subject = self.subject, .id = self.id, .icon = icon } };
        self.close();
        return out;
    }

    pub fn onCtrl(self: *Overlay, key: u8) ?Outcome {
        return switch (key) {
            'c', 'g' => self.onEdit(.cancel),
            'n' => self.onEdit(.move_down),
            'p' => self.onEdit(.move_up),
            'a' => self.onEdit(.move_line_start),
            'e' => self.onEdit(.move_line_end),
            'u' => self.onEdit(.delete_to_line_start),
            'k' => self.onEdit(.delete_to_line_end),
            'w' => self.onEdit(.delete_word_backward),
            'h' => self.onEdit(.delete_backward),
            else => null,
        };
    }

    /// The keyboard walks the menu's rows, wrapping and stepping over
    /// greyed-out ones.
    fn moveHighlight(self: *Overlay, delta: i32) void {
        const rows = self.items();
        for (rows) |_| {
            self.moveHighlightN(delta, rows.len);
            if (!rows[self.highlighted.?].disabled) return;
        }
        self.highlighted = null;
    }

    /// Unfolds the "Open with" submenu; `by_key` puts the keyboard on its
    /// first row (the mouse leaves the highlight to the pointer).
    fn unfoldSub(self: *Overlay, by_key: bool) void {
        self.sub_open = true;
        self.sub_scroll = 0;
        self.sub_highlighted = if (by_key and self.sub_labels.items.len > 0) 0 else null;
        if (self.submenuRow()) |i| self.highlighted = i;
    }

    fn foldSub(self: *Overlay) void {
        self.sub_open = false;
        self.sub_highlighted = null;
    }

    fn moveSubHighlight(self: *Overlay, delta: i32) void {
        const count = self.sub_labels.items.len;
        if (count == 0) return;
        const n: i32 = @intCast(count);
        const cur: i32 = if (self.sub_highlighted) |h| @intCast(h) else (if (delta > 0) -1 else n);
        self.sub_highlighted = @intCast(@mod(cur + delta, n));
    }

    fn pickSub(self: *Overlay, i: usize) Outcome {
        const out: Outcome = if (self.subject == .tab)
            .{ .split_tab = .{ .uid = self.id, .side = split_sides[@min(i, split_sides.len - 1)] } }
        else
            .{ .open_with = self.sub_values.items[i] };
        self.close();
        return out;
    }

    fn moveHighlightN(self: *Overlay, delta: i32, count: usize) void {
        if (count == 0) return;
        const n: i32 = @intCast(count);
        const cur: i32 = if (self.highlighted) |h| @intCast(h) else (if (delta > 0) -1 else n);
        self.highlighted = @intCast(@mod(cur + delta, n));
    }

    fn pickList(self: *Overlay, i: usize) Outcome {
        self.close();
        return .{ .list_picked = i };
    }

    fn pickMenu(self: *Overlay, i: usize) Outcome {
        const id = self.id;
        const subject = self.subject;
        const item = self.items()[i].item;
        self.close();
        return switch (item) {
            .rename => switch (subject) {
                .tab => .{ .rename_tab = id },
                .project, .default_project => .{ .rename_project = id },
                .resource => .{ .rename_resource = id },
                .file => .{ .name_file = .rename },
            },
            .split_beside => .{ .split_beside = .{ .uid = id, .side = .right } },
            // The row unfolds the submenu; it is never picked itself.
            .split_move => .{ .split_beside = .{ .uid = id, .side = .right } },
            .close => .{ .close_tab = id },
            .close_others => .{ .close_others = id },
            .close_right => .{ .close_right = id },
            .tab_copy_path => .{ .copy_tab_path = .{ .uid = id, .relative = false } },
            .tab_copy_rel => .{ .copy_tab_path = .{ .uid = id, .relative = true } },
            .new_shells => .{ .new_shells = id },
            .set_icon => .{ .set_icon = .{ .subject = subject, .id = id } },
            .remove => if (subject == .resource) .{ .remove_resource = id } else .{ .remove_project = id },
            .new_file => .{ .name_file = .new_file },
            .new_folder => .{ .name_file = .new_folder },
            .open_external => .open_externally,
            // The row unfolds the submenu; it is never picked itself.
            .open_with => .open_externally,
            .reveal => if (subject == .tab) .{ .reveal_tab = id } else .reveal_in_finder,
            .copy_path => .{ .copy_path = .{ .absolute = false } },
            .copy_abs_path => .{ .copy_path = .{ .absolute = true } },
            .delete => .delete_file,
        };
    }

    /// The rename box's answer, for whatever it was opened about.
    fn renamed(self: *Overlay) Outcome {
        const name = self.editor.bytes();
        return switch (self.subject) {
            .tab => .{ .renamed = .{ .uid = self.id, .name = name } },
            .project, .default_project => .{ .project_renamed = .{ .id = self.id, .name = name } },
            .resource => .{ .resource_renamed = .{ .id = self.id, .name = name } },
            .file => .{ .file_named = .{ .kind = self.name_kind, .name = name } },
        };
    }

    fn confirmClose(self: *Overlay) Outcome {
        const uid = self.id;
        const kind = self.confirm_kind;
        self.close();
        return switch (kind) {
            .git_discard => .discard_confirmed,
            .delete_file => .delete_confirmed,
            .search_replace => .replace_confirmed,
            .close_tab => .{ .close_confirmed = uid },
            .close_others => .{ .close_others_confirmed = uid },
            .close_right => .{ .close_right_confirmed = uid },
        };
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws whatever is open over the window; returns what the user picked.
    pub fn draw(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        return switch (self.mode) {
            .none => null,
            .menu => self.drawMenu(ui, width, height),
            .rename => self.drawRename(ui, width, height),
            .confirm => self.drawConfirm(ui, width, height),
            .list => self.drawList(ui, width, height),
            .icons => self.drawIcons(ui, width, height),
        };
    }

    /// Where picker row `i` sits: the symbols in a grid, the colours in
    /// their own grid under it.
    fn iconCell(i: usize, x: f32, y: f32) Rect {
        const glyph_rows = (icon_spec.glyphs.len + icon_cols - 1) / icon_cols;
        var idx = i;
        var oy = y;
        if (i >= icon_spec.glyphs.len) {
            idx = i - icon_spec.glyphs.len;
            oy += @as(f32, @floatFromInt(glyph_rows)) * (cell + cell_gap) - cell_gap + section_gap;
        }
        const col: f32 = @floatFromInt(idx % icon_cols);
        const row: f32 = @floatFromInt(idx / icon_cols);
        return .{ .x = x + col * (cell + cell_gap), .y = oy + row * (cell + cell_gap), .w = cell, .h = cell };
    }

    fn drawIcons(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        const last = iconCell(icon_spec.count - 1, 0, 0);
        const grid_h = last.bottom();
        const box = beginBox(ui, width, height, title_h + 8 + line_h + 16 + grid_h + 22 + button_h);
        const x = box.x + box_pad;
        const w = box.w - 2 * box_pad;
        var y = box.y + box_pad;
        _ = dl.textCentered(font_title, x, y + title_h / 2, "Choose an icon", theme.text);
        y += title_h + 8;
        _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, "A symbol or a colour, shown next to the name.", w, theme.text_2);
        y += line_h + 16;

        // As in the menu: the mouse owns the highlight while it moves over
        // the grid, the keyboard's choice stays put otherwise.
        const grid: Rect = .{ .x = x, .y = y, .w = w, .h = grid_h };
        const moved = self.pointerMoved(ui);
        if (moved and ui.mouseIn(grid)) self.highlighted = null;
        var out: ?Outcome = null;
        for (0..icon_spec.count) |i| {
            const r = iconCell(i, x, y);
            const st = ui.button(Ui.id("overlay.icon", i), r);
            if (st.hover and moved) self.highlighted = i;
            if (st.held) {
                dl.rrect(r, 8, theme.pressed);
            } else if (self.highlighted == i) dl.rrect(r, 8, theme.highlight);
            if (self.icon_current == i) dl.border(r, 8, 1.5, theme.accent);
            icon_spec.drawSpec(dl, icon_spec.specAt(i), r.x + (cell - 20) / 2, r.centerY(), 20, theme.text);
            if (st.clicked) out = self.pickIcon(icon_spec.nameAt(i));
        }
        y += grid_h + 22;

        var right = box.right() - box_pad;
        if (boxButton(ui, Ui.id("overlay.ok", 0), &right, y, "No icon", .plain)) out = self.pickIcon(null);
        if (boxButton(ui, Ui.id("overlay.cancel", 0), &right, y, "Cancel", .plain)) self.close();
        return out;
    }

    /// Height of a menu of `rows`: the rows plus their dividers.
    fn menuHeight(rows: []const MenuEntry) f32 {
        var h = menu_pad * 2 + menu_row_h * @as(f32, @floatFromInt(rows.len));
        for (rows) |m| {
            if (m.sep_before) h += menu_sep_h;
        }
        return h;
    }

    /// Where row `i` of a menu at `panel` sits.
    fn menuRow(panel: Rect, rows: []const MenuEntry, i: usize) Rect {
        var y = panel.y + menu_pad;
        for (rows[0 .. i + 1], 0..) |m, k| {
            if (m.sep_before) y += menu_sep_h;
            if (k < i) y += menu_row_h;
        }
        return .{ .x = panel.x + menu_pad, .y = y, .w = panel.w - 2 * menu_pad, .h = menu_row_h };
    }

    fn drawMenu(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        // Under a menu the window is inert; a click elsewhere just dismisses it.
        ui.interactive.append(ui.gpa, .{ .x = 0, .y = 0, .w = width, .h = height }) catch {};
        const rows = self.items();
        const h = menuHeight(rows);
        const panel: Rect = .{
            .x = std.math.clamp(self.anchor_x, 8, @max(8, width - 8 - menu_w)),
            .y = std.math.clamp(self.anchor_y, 8, @max(8, height - 8 - h)),
            .w = menu_w,
            .h = h,
        };
        // The submenu hangs off its row, to the right when there is room.
        const sub_panel: ?Rect = if (self.sub_open) self.subPanel(ui, panel, rows, width, height) else null;
        const in_sub = sub_panel != null and ui.mouseIn(sub_panel.?);
        if (ui.pressed and !panel.contains(ui.mx, ui.my) and !in_sub) {
            self.close();
            return null;
        }
        shadow(dl, panel, 8, 3);
        dl.shape(panel, 8, theme.bg_panel, 1, theme.line_strong);

        // The mouse owns the highlight while it moves over the menu; the
        // keyboard's choice stays put otherwise. Sliding onto the "Open
        // with" row unfolds the submenu, sliding onto another row folds it.
        const moved = self.pointerMoved(ui);
        if (moved and ui.mouseIn(panel)) self.highlighted = null;
        var out: ?Outcome = null;
        for (rows, 0..) |m, i| {
            const r = menuRow(panel, rows, i);
            if (m.sep_before) dl.rect(.{ .x = r.x + 4, .y = r.y - menu_sep_h / 2, .w = r.w - 8, .h = 1 }, theme.line_strong);
            if (m.disabled) {
                // Greyed out: the pointer passes over it, folding the submenu.
                if (moved and ui.mouseIn(r) and self.sub_open) self.foldSub();
                _ = dl.textCentered(theme.font_ui, r.x + 10, r.centerY(), m.label, theme.text_3);
                continue;
            }
            const st = ui.button(Ui.id("overlay.menu", i), r);
            if (st.hover and moved) {
                self.highlighted = i;
                if (m.submenu and !self.sub_open) self.unfoldSub(false);
                if (!m.submenu and self.sub_open) self.foldSub();
            }
            const lit = self.highlighted == i or (m.submenu and self.sub_open);
            if (st.held) {
                dl.rrect(r, 6, theme.pressed);
            } else if (lit) dl.rrect(r, 6, theme.highlight);
            _ = dl.textCentered(theme.font_ui, r.x + 10, r.centerY(), m.label, theme.text);
            if (m.submenu) dl.icon(.chevron_right, r.right() - 22, r.centerY() - 7, 14, theme.text_3);
            if (m.kbd.len > 0) _ = dl.textRight(theme.font_kbd, r.right() - 10, r.centerY(), m.kbd, theme.text_3);
            if (st.clicked) {
                if (m.submenu) self.unfoldSub(false) else out = self.pickMenu(i);
            }
        }
        if (sub_panel) |sp| {
            if (self.drawSub(ui, sp, moved)) |o| out = o;
        }
        return out;
    }

    /// Where the submenu goes: beside its row, flipped to the left of the
    /// menu when the window's edge is near, never taller than the window.
    fn subPanel(self: *const Overlay, ui: *Ui, panel: Rect, rows: []const MenuEntry, width: f32, height: f32) Rect {
        const labels = self.sub_labels.items;
        var widest: f32 = ui.text.measure(theme.font_ui, "No applications");
        for (labels) |s| widest = @max(widest, ui.text.measure(theme.font_ui, s));
        const w = std.math.clamp(widest + 2 * menu_pad + 20 + 14, submenu_min_w, submenu_max_w);
        const n: f32 = @floatFromInt(@max(1, labels.len));
        const content_h = menu_row_h * n;
        const inner_h = @min(content_h, @max(menu_row_h, height - 16 - 2 * menu_pad));
        const h = menu_pad * 2 + inner_h;
        const row = menuRow(panel, rows, self.submenuRow() orelse 0);
        const x = if (panel.right() + 2 + w <= width - 8) panel.right() + 2 else @max(8, panel.x - 2 - w);
        return .{ .x = x, .y = std.math.clamp(row.y - menu_pad, 8, @max(8, height - 8 - h)), .w = w, .h = h };
    }

    /// The submenu: the "Open with" applications (or a note that there
    /// are none) or the "Split & Move" sides. Scrolls when there are more
    /// than fit.
    fn drawSub(self: *Overlay, ui: *Ui, panel: Rect, moved: bool) ?Outcome {
        const dl = ui.dl;
        shadow(dl, panel, 8, 3);
        dl.shape(panel, 8, theme.bg_panel, 1, theme.line_strong);
        const labels = self.sub_labels.items;
        if (labels.len == 0) {
            _ = dl.textEllipsis(theme.font_ui, panel.x + menu_pad + 10, panel.y + menu_pad + menu_row_h / 2, "No applications", panel.w - 2 * menu_pad - 20, theme.text_3);
            return null;
        }
        const inner: Rect = .{ .x = panel.x, .y = panel.y + menu_pad, .w = panel.w, .h = panel.h - 2 * menu_pad };
        const content_h = menu_row_h * @as(f32, @floatFromInt(labels.len));
        const max_scroll = @max(0, content_h - inner.h);
        self.sub_scroll = std.math.clamp(self.sub_scroll - ui.takeScroll(panel), 0, max_scroll);
        if (self.sub_highlighted) |hl| if (!ui.mouseIn(panel)) {
            const top = menu_row_h * @as(f32, @floatFromInt(hl));
            if (top < self.sub_scroll) self.sub_scroll = top;
            if (top + menu_row_h > self.sub_scroll + inner.h) self.sub_scroll = top + menu_row_h - inner.h;
        };
        dl.pushClip(inner);
        defer dl.popClip();
        if (moved and ui.mouseIn(panel)) self.sub_highlighted = null;
        var out: ?Outcome = null;
        var y = inner.y - self.sub_scroll;
        for (labels, 0..) |label, i| {
            const r: Rect = .{ .x = panel.x + menu_pad, .y = y, .w = panel.w - 2 * menu_pad, .h = menu_row_h };
            y += menu_row_h;
            if (r.bottom() <= inner.y or r.y >= inner.bottom()) continue;
            const st = ui.button(Ui.id("overlay.sub", i), r);
            if (st.hover and moved) self.sub_highlighted = i;
            if (st.held) {
                dl.rrect(r, 6, theme.pressed);
            } else if (self.sub_highlighted == i) dl.rrect(r, 6, theme.highlight);
            _ = dl.textEllipsis(theme.font_ui, r.x + 10, r.centerY(), label, r.w - 20, theme.text);
            if (st.clicked) out = self.pickSub(i);
        }
        return out;
    }

    /// The list menu: as wide as its longest row needs, a tick on the
    /// current row, a divider where asked.
    fn drawList(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        ui.interactive.append(ui.gpa, .{ .x = 0, .y = 0, .w = width, .h = height }) catch {};
        const items_list = self.list_items.items;
        var widest: f32 = 0;
        for (items_list) |s| widest = @max(widest, ui.text.measure(theme.font_ui, s));
        const w = std.math.clamp(widest + 2 * menu_pad + 30 + 14, menu_w, 340);
        const sep_h: f32 = if (self.list_sep_after != null) 9 else 0;
        const content_h = menu_row_h * @as(f32, @floatFromInt(items_list.len)) + sep_h;
        // Taller than the window: the rows scroll inside the panel.
        const inner_h = @min(content_h, @max(menu_row_h, height - 16 - 2 * menu_pad));
        const h = menu_pad * 2 + inner_h;
        const panel: Rect = .{
            .x = std.math.clamp(self.anchor_x, 8, @max(8, width - 8 - w)),
            .y = std.math.clamp(self.anchor_y, 8, @max(8, height - 8 - h)),
            .w = w,
            .h = h,
        };
        if (ui.pressed and !panel.contains(ui.mx, ui.my)) {
            self.close();
            return null;
        }
        shadow(dl, panel, 8, 3);
        dl.shape(panel, 8, theme.bg_panel, 1, theme.line_strong);
        const max_scroll = @max(0, content_h - inner_h);
        self.list_scroll = std.math.clamp(self.list_scroll - ui.takeScroll(panel), 0, max_scroll);
        // The keyboard's row stays in view.
        if (self.highlighted) |hl| if (!ui.mouseIn(panel)) {
            const top = menu_row_h * @as(f32, @floatFromInt(hl)) + (if (self.list_sep_after) |sep| (if (hl > sep) sep_h else 0) else 0);
            if (top < self.list_scroll) self.list_scroll = top;
            if (top + menu_row_h > self.list_scroll + inner_h) self.list_scroll = top + menu_row_h - inner_h;
        };
        const inner: Rect = .{ .x = panel.x, .y = panel.y + menu_pad, .w = panel.w, .h = inner_h };
        dl.pushClip(inner);
        defer dl.popClip();
        const moved = self.pointerMoved(ui);
        if (moved and ui.mouseIn(panel)) self.highlighted = null;
        var out: ?Outcome = null;
        var y = inner.y - self.list_scroll;
        for (items_list, 0..) |label, i| {
            const r: Rect = .{ .x = panel.x + menu_pad, .y = y, .w = panel.w - 2 * menu_pad, .h = menu_row_h };
            y += menu_row_h;
            if (r.bottom() <= inner.y or r.y >= inner.bottom()) {
                if (self.list_sep_after == i) y += sep_h;
                continue;
            }
            const st = ui.button(Ui.id("overlay.list", i), r);
            if (st.hover and moved) self.highlighted = i;
            if (st.held) {
                dl.rrect(r, 6, theme.pressed);
            } else if (self.highlighted == i) dl.rrect(r, 6, theme.highlight);
            if (self.list_checked == i) dl.icon(.check, r.x + 8, r.centerY() - 7, 14, theme.accent);
            _ = dl.textEllipsis(theme.font_ui, r.x + 30, r.centerY(), label, r.w - 36, theme.text);
            if (st.clicked) out = self.pickList(i);
            if (self.list_sep_after == i) {
                dl.rect(.{ .x = r.x + 4, .y = y + 4, .w = r.w - 8, .h = 1 }, theme.line_strong);
                y += sep_h;
            }
        }
        return out;
    }

    fn drawRename(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        // A tab that stands for a file gets a second line: only the tab is
        // renamed, the file itself keeps its name.
        const hint2: ?[]const u8 = if (self.subject == .tab and self.tab_document) "Leave the name empty to go back to the automatic title." else null;
        const hint2_h: f32 = if (hint2 != null) line_h else 0;
        const box = beginBox(ui, width, height, title_h + 8 + line_h + hint2_h + 16 + field_h + 22 + button_h);
        const x = box.x + box_pad;
        const w = box.w - 2 * box_pad;
        var y = box.y + box_pad;
        const title: []const u8, const hint: []const u8, const ok: []const u8 = switch (self.subject) {
            .tab => .{ "Rename tab", if (hint2 != null) "Only the tab is renamed; the file itself keeps its name." else "Leave the name empty to go back to the automatic title.", "Rename" },
            .project, .default_project => .{ "Rename project", "Leave the name empty to go back to the folder's name.", "Rename" },
            .resource => .{ "Rename", "Only the sidebar label changes; the file or folder keeps its name.", "Rename" },
            .file => switch (self.name_kind) {
                .rename => .{ if (self.file_kind == .folder) "Rename folder" else "Rename file", self.reason_buf[0..self.reason_len], "Rename" },
                .new_file => .{ "New file", self.reason_buf[0..self.reason_len], "Create" },
                .new_folder => .{ "New folder", self.reason_buf[0..self.reason_len], "Create" },
            },
        };
        _ = dl.textCentered(font_title, x, y + title_h / 2, title, theme.text);
        y += title_h + 8;
        // What went wrong with the last attempt takes the hint's place.
        if (self.name_error_len > 0) {
            _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, self.name_error_buf[0..self.name_error_len], w, theme.red);
        } else _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, hint, w, theme.text_2);
        y += line_h;
        if (hint2) |h2| {
            _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, h2, w, theme.text_2);
            y += line_h;
        }
        y += 16;
        self.nameField(ui, .{ .x = x, .y = y, .w = w, .h = field_h });
        y += field_h + 22;

        var out: ?Outcome = null;
        var right = box.right() - box_pad;
        if (boxButton(ui, Ui.id("overlay.ok", 0), &right, y, ok, .primary)) out = self.renamed();
        if (boxButton(ui, Ui.id("overlay.cancel", 0), &right, y, "Cancel", .plain)) self.close();
        return out;
    }

    fn drawConfirm(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        const box = beginBox(ui, width, height, title_h + 8 + line_h + 22 + button_h);
        const x = box.x + box_pad;
        const w = box.w - 2 * box_pad;
        var y = box.y + box_pad;
        _ = dl.textEllipsis(font_title, x, y + title_h / 2, self.title_buf[0..self.title_len], w, theme.text);
        y += title_h + 8;
        _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, self.reason_buf[0..self.reason_len], w, theme.text_2);
        y += line_h + 22;

        var out: ?Outcome = null;
        var right = box.right() - box_pad;
        if (boxButton(ui, Ui.id("overlay.ok", 0), &right, y, self.ok_buf[0..self.ok_len], .destructive)) out = self.confirmClose();
        if (boxButton(ui, Ui.id("overlay.cancel", 0), &right, y, "Cancel", .plain)) self.close();
        return out;
    }

    /// The single-line name field: text with selection, IME text and caret;
    /// click and drag place the caret. Long names scroll to keep the caret in view.
    fn nameField(self: *Overlay, ui: *Ui, r: Rect) void {
        const dl = ui.dl;
        const font = theme.font_ui;
        dl.shape(r, 8, theme.bg_inset, 1, theme.accent.alpha(0.6));
        const d = ui.drag(Ui.id("overlay.name", 0), r);
        if (d.hover or d.dragging) ui.cursor = .ibeam;

        const inner = r.inset(12, 1);
        dl.pushClip(r.inset(6, 1));
        defer dl.popClip();
        const scale = dl.scale;
        const text = self.editor.bytes();
        const cy = r.centerY();

        // Where the caret would land, to scroll it into view when the name is long.
        var caret_off: f32 = 0;
        {
            var it = gfx_text.Utf8Iter{ .bytes = text };
            var pen: f32 = 0;
            while (true) {
                if (it.index == self.editor.cursor) caret_off = pen;
                const cp = it.next() orelse break;
                pen += ui.text.advance(font, cp);
            }
        }
        const marked_w: f32 = if (self.editor.marked.items.len > 0) ui.text.measure(font, self.editor.marked.items) else 0;
        const shift = @max(0, caret_off + marked_w + 2 - inner.w);
        const x0 = inner.x - shift;

        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const sel = self.editor.selection();
        const baseline_px = @round(ui.text.baselineForCenter(font, cy) * scale);
        var pen = x0 * scale;
        var caret_px = pen;
        var hit: ?usize = null;
        var it = gfx_text.Utf8Iter{ .bytes = text };
        while (true) {
            const at = it.index;
            if (at == self.editor.cursor) caret_px = pen;
            const cp = it.next() orelse break;
            const adv = ui.text.advance(font, cp) * scale;
            if ((d.started or d.dragging) and hit == null and ui.mx * scale < pen + adv / 2) hit = at;
            if (sel) |s| if (at >= s[0] and at < s[1]) {
                dl.rect(.{ .x = pen / scale, .y = cy - 10, .w = adv / scale, .h = 20 }, theme.selection());
            };
            _ = dl.glyph(font, cp, pen, baseline_px, theme.text, clip);
            pen += adv;
        }
        if (d.started or d.dragging) {
            const off = hit orelse text.len;
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
            const mw = dl.textCentered(font, cx, cy, self.editor.marked.items, theme.text);
            dl.rect(.{ .x = cx, .y = cy + 9, .w = mw, .h = 1 }, theme.text_2);
            cx += mw;
        }
        self.caret = .{ .x = cx, .y = cy - 9, .w = 2, .h = 18 };
        if (self.blink_on or ui.down) dl.rect(self.caret, theme.accent);
    }
};

fn copyInto(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

/// Scrim, shadow and panel of an alert-like box, a little above the middle
/// of the window. Returns the panel.
fn beginBox(ui: *Ui, width: f32, height: f32, content_h: f32) Rect {
    const dl = ui.dl;
    const window: Rect = .{ .x = 0, .y = 0, .w = width, .h = height };
    // Modal: nothing under the box reacts, not even the titlebar drag.
    ui.interactive.append(ui.gpa, window) catch {};
    dl.rect(window, theme.scrim);
    const w = @min(box_w, width - 40);
    const h = content_h + 2 * box_pad;
    const box: Rect = .{ .x = @round((width - w) / 2), .y = @round(@max(24, height * 0.38 - h / 2)), .w = w, .h = h };
    shadow(dl, box, 12, 6);
    dl.shape(box, 12, theme.bg_panel, 1, theme.line_strong);
    return box;
}

/// Soft drop shadow approximated with rings, as the palette does (a solid
/// offset block on e-ink).
fn shadow(dl: *draw.DrawList, r: Rect, radius: f32, rings: u32) void {
    theme.dropShadow(dl, r, radius, rings, 5, 8, 0.08);
}

const ButtonStyle = enum { plain, primary, destructive };

/// A box button, laid out right to left: `right` moves past it and the gap.
fn boxButton(ui: *Ui, wid: u64, right: *f32, y: f32, label: []const u8, style: ButtonStyle) bool {
    const dl = ui.dl;
    const font = theme.font_ui_medium;
    const lw = ui.text.measure(font, label);
    const w = @max(88, lw + 32);
    const r: Rect = .{ .x = right.* - w, .y = y, .w = w, .h = button_h };
    right.* = r.x - 10;
    const st = ui.button(wid, r);
    var color = theme.text;
    switch (style) {
        .plain => {
            ui.feedback(r, 8, st);
            dl.border(r, 8, 1, theme.line_strong);
        },
        .primary => {
            const fill = if (st.held) Color.mix(theme.accent, theme.on_accent, 0.15) else if (st.hover) Color.mix(theme.accent, theme.text, 0.12) else theme.accent;
            dl.rrect(r, 8, fill);
            color = theme.on_accent;
        },
        .destructive => {
            const a: f32 = if (st.held) 0.3 else if (st.hover) 0.22 else 0.14;
            dl.shape(r, 8, theme.red.alpha(a), 1, theme.red_line);
            color = theme.red;
        },
    }
    _ = dl.textCentered(font, r.x + (r.w - lw) / 2, r.centerY(), label, color);
    return st.clicked;
}

test "overlay: a tab's menu has the rows that apply to it" {
    var o = Overlay.init(std.testing.allocator);
    defer o.deinit();

    // A file tab, last of three: everything, with "Close to the Right" greyed out.
    o.openTabMenu(7, 0, 0, .{ .has_path = true, .document = true, .others = 2, .to_right = 0 });
    const rows = o.items();
    try std.testing.expectEqual(@as(usize, 9), rows.len);
    try std.testing.expectEqualStrings("Close", rows[0].label);
    try std.testing.expect(!rows[1].disabled);
    try std.testing.expect(rows[2].disabled);
    try std.testing.expect(rows[3].sep_before and rows[4].sep_before and rows[6].sep_before);
    try std.testing.expect(!rows[5].sep_before and !rows[7].sep_before and !rows[8].sep_before);
    try std.testing.expect(rows[8].submenu);
    try std.testing.expectEqual(@as(usize, 4), o.sub_labels.items.len);

    // Settings, alone: no "Rename Tab…", no path rows; the divider moves
    // down to "Split Right", the close-others rows are greyed out.
    o.openTabMenu(8, 0, 0, .{ .renamable = false });
    const alone = o.items();
    try std.testing.expectEqual(@as(usize, 5), alone.len);
    try std.testing.expect(alone[1].disabled and alone[2].disabled);
    try std.testing.expectEqualStrings("Split Right", alone[3].label);
    try std.testing.expect(alone[3].sep_before and !alone[4].sep_before);
    // The keyboard steps over the greyed-out rows.
    _ = o.onEdit(.move_down);
    try std.testing.expectEqual(@as(?usize, 0), o.highlighted);
    _ = o.onEdit(.move_down);
    try std.testing.expectEqual(@as(?usize, 3), o.highlighted);
    _ = o.onEdit(.move_up);
    try std.testing.expectEqual(@as(?usize, 0), o.highlighted);

    // What the rows and the submenu give back.
    o.openTabMenu(7, 0, 0, .{ .has_path = true, .others = 1, .to_right = 1 });
    try std.testing.expectEqual(@as(u32, 7), o.pickMenu(2).close_right);
    try std.testing.expect(!o.isOpen());
    o.openTabMenu(7, 0, 0, .{ .has_path = true, .others = 1, .to_right = 1 });
    try std.testing.expect(o.pickMenu(5).copy_tab_path.relative);
    o.openTabMenu(7, 0, 0, .{ .has_path = true });
    try std.testing.expectEqual(@as(u32, 7), o.pickMenu(6).reveal_tab);
    o.openTabMenu(7, 0, 0, .{ .has_path = true });
    try std.testing.expectEqual(Side.right, o.pickMenu(7).split_beside.side);
    o.openTabMenu(7, 0, 0, .{});
    try std.testing.expectEqual(Side.top, o.pickSub(2).split_tab.side);
    try std.testing.expect(!o.isOpen());

    // The confirmations that "Close Others" / "Close to the Right" lead to.
    o.openConfirmAction(.close_others, 7, "Close the other tabs?", "", "Close");
    try std.testing.expectEqual(@as(?u32, 7), o.aboutTab());
    try std.testing.expectEqual(@as(u32, 7), o.onEdit(.insert_newline).?.close_others_confirmed);
}

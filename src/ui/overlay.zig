//! Floating, modal bits drawn over the workspace: context menus (a tab's,
//! a sidebar project's or resource's) and the alert-like boxes they lead
//! to (rename, close confirmation, the icon picker). At most one is open;
//! while it is, the workspace under it is inert and keyboard input comes
//! here (the app routes it, see `App`).
const std = @import("std");
const draw = @import("../gfx/draw.zig");
const gfx_text = @import("../gfx/text.zig");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const Editor = @import("../input/editor.zig").Editor;
const EditCommand = @import("../events.zig").EditCommand;
const icon_spec = @import("icon_spec.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

pub const Mode = enum { none, menu, rename, confirm, icons };

/// What an open menu or box is about: a tab (by uid), a sidebar project
/// or resource (by id), or the default project (no id).
pub const Subject = enum { tab, project, default_project, resource };

/// What a confirm box leads to when it is accepted.
pub const ConfirmKind = enum { close_tab, git_discard };

/// What the user decided; the app carries it out.
pub const Outcome = union(enum) {
    /// Tab menu → "Rename…": open the rename box for this tab.
    rename_tab: u32,
    /// Tab menu → "Split Right" / "Split Down": the tab moves into a new
    /// pane on that side of its own.
    split_tab: struct { uid: u32, down: bool },
    /// Tab menu → "Close": close this tab (the app asks first if it is busy).
    close_tab: u32,
    /// Rename box confirmed for a tab. `name` points into the overlay's
    /// editor and is valid until the overlay is next opened.
    renamed: struct { uid: u32, name: []const u8 },
    /// Close confirmation accepted.
    close_confirmed: u32,
    /// The Git panel's "Discard" box accepted: the panel runs what it had pending.
    discard_confirmed: void,
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
};

const MenuItem = enum { rename, split_right, split_down, close, new_shells, set_icon, remove };
const MenuEntry = struct { item: MenuItem, label: []const u8 };
const tab_menu = [_]MenuEntry{
    .{ .item = .rename, .label = "Rename…" },
    .{ .item = .split_right, .label = "Split Right" },
    .{ .item = .split_down, .label = "Split Down" },
    .{ .item = .close, .label = "Close" },
};
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

// Metrics (points), in the palette's idiom.
const menu_w: f32 = 176;
const menu_pad: f32 = 5;
const menu_row_h: f32 = 28;
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
    /// Whether the open menu offers "Rename…" (not for a tab whose title
    /// is its identity, like Settings).
    renamable: bool = true,

    // Rename box: the name being typed.
    editor: Editor,
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

    pub fn init(gpa: std.mem.Allocator) Overlay {
        return .{ .gpa = gpa, .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Overlay) void {
        self.editor.deinit();
    }

    pub fn isOpen(self: *const Overlay) bool {
        return self.mode != .none;
    }

    pub fn close(self: *Overlay) void {
        self.mode = .none;
        self.highlighted = null;
    }

    /// The context menu of a tab, project or resource, with its top-left
    /// corner at (x, y). `renamable` only matters for a tab.
    pub fn openMenu(self: *Overlay, subject: Subject, id: u32, x: f32, y: f32, renamable: bool) void {
        self.mode = .menu;
        self.subject = subject;
        self.id = id;
        self.anchor_x = x;
        self.anchor_y = y;
        self.highlighted = null;
        self.renamable = renamable;
    }

    /// The rows of the open menu (a tab's "Rename…" comes first, when offered).
    fn items(self: *const Overlay) []const MenuEntry {
        const tab_all: []const MenuEntry = &tab_menu;
        return switch (self.subject) {
            .tab => if (self.renamable) tab_all else tab_all[1..],
            .project => &project_menu,
            .default_project => &default_project_menu,
            .resource => &resource_menu,
        };
    }

    /// The icon picker for a project, the default project or a resource;
    /// `current` is the name set now (highlighted), if any.
    pub fn openIcons(self: *Overlay, subject: Subject, id: u32, current: ?[]const u8) void {
        self.mode = .icons;
        self.subject = subject;
        self.id = id;
        self.icon_current = icon_spec.indexOf(current);
        self.highlighted = self.icon_current;
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
            .menu => switch (cmd) {
                .cancel => self.close(),
                .move_down, .select_down, .insert_tab => self.moveHighlight(1),
                .move_up, .select_up, .insert_backtab => self.moveHighlight(-1),
                .insert_newline, .insert_line_break => if (self.highlighted) |i| return self.pickMenu(i),
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

    fn moveHighlight(self: *Overlay, delta: i32) void {
        const n: i32 = @intCast(self.items().len);
        const cur: i32 = if (self.highlighted) |h| @intCast(h) else (if (delta > 0) -1 else n);
        self.highlighted = @intCast(@mod(cur + delta, n));
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
            },
            .split_right => .{ .split_tab = .{ .uid = id, .down = false } },
            .split_down => .{ .split_tab = .{ .uid = id, .down = true } },
            .close => .{ .close_tab = id },
            .new_shells => .{ .new_shells = id },
            .set_icon => .{ .set_icon = .{ .subject = subject, .id = id } },
            .remove => if (subject == .resource) .{ .remove_resource = id } else .{ .remove_project = id },
        };
    }

    /// The rename box's answer, for whatever it was opened about.
    fn renamed(self: *Overlay) Outcome {
        const name = self.editor.bytes();
        return switch (self.subject) {
            .tab => .{ .renamed = .{ .uid = self.id, .name = name } },
            .project, .default_project => .{ .project_renamed = .{ .id = self.id, .name = name } },
            .resource => .{ .resource_renamed = .{ .id = self.id, .name = name } },
        };
    }

    fn confirmClose(self: *Overlay) Outcome {
        const uid = self.id;
        const kind = self.confirm_kind;
        self.close();
        if (kind == .git_discard) return .discard_confirmed;
        return .{ .close_confirmed = uid };
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws whatever is open over the window; returns what the user picked.
    pub fn draw(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        return switch (self.mode) {
            .none => null,
            .menu => self.drawMenu(ui, width, height),
            .rename => self.drawRename(ui, width, height),
            .confirm => self.drawConfirm(ui, width, height),
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

        // As in the menu: the mouse owns the highlight while it is over the
        // grid, the keyboard's choice stays put otherwise.
        const grid: Rect = .{ .x = x, .y = y, .w = w, .h = grid_h };
        if (ui.mouseIn(grid)) self.highlighted = null;
        var out: ?Outcome = null;
        for (0..icon_spec.count) |i| {
            const r = iconCell(i, x, y);
            const st = ui.button(Ui.id("overlay.icon", i), r);
            if (st.hover) self.highlighted = i;
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

    fn drawMenu(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        // Under a menu the window is inert; a click elsewhere just dismisses it.
        ui.interactive.append(ui.gpa, .{ .x = 0, .y = 0, .w = width, .h = height }) catch {};
        const h = menu_pad * 2 + menu_row_h * @as(f32, @floatFromInt(self.items().len));
        const panel: Rect = .{
            .x = std.math.clamp(self.anchor_x, 8, @max(8, width - 8 - menu_w)),
            .y = std.math.clamp(self.anchor_y, 8, @max(8, height - 8 - h)),
            .w = menu_w,
            .h = h,
        };
        if (ui.pressed and !panel.contains(ui.mx, ui.my)) {
            self.close();
            return null;
        }
        shadow(dl, panel, 8, 3);
        dl.shape(panel, 8, theme.bg_panel, 1, theme.line_strong);

        // The mouse owns the highlight while it is over the menu; the
        // keyboard's choice stays put otherwise.
        if (ui.mouseIn(panel)) self.highlighted = null;
        var out: ?Outcome = null;
        for (self.items(), 0..) |m, i| {
            const r: Rect = .{ .x = panel.x + menu_pad, .y = panel.y + menu_pad + menu_row_h * @as(f32, @floatFromInt(i)), .w = panel.w - 2 * menu_pad, .h = menu_row_h };
            const st = ui.button(Ui.id("overlay.menu", i), r);
            if (st.hover) self.highlighted = i;
            if (st.held) {
                dl.rrect(r, 6, theme.pressed);
            } else if (self.highlighted == i) dl.rrect(r, 6, theme.highlight);
            _ = dl.textCentered(theme.font_ui, r.x + 10, r.centerY(), m.label, theme.text);
            if (st.clicked) out = self.pickMenu(i);
        }
        return out;
    }

    fn drawRename(self: *Overlay, ui: *Ui, width: f32, height: f32) ?Outcome {
        const dl = ui.dl;
        const box = beginBox(ui, width, height, title_h + 8 + line_h + 16 + field_h + 22 + button_h);
        const x = box.x + box_pad;
        const w = box.w - 2 * box_pad;
        var y = box.y + box_pad;
        const title: []const u8, const hint: []const u8 = switch (self.subject) {
            .tab => .{ "Rename tab", "Leave the name empty to go back to the automatic title." },
            .project, .default_project => .{ "Rename project", "Leave the name empty to go back to the folder's name." },
            .resource => .{ "Rename", "Only the sidebar label changes; the file or folder keeps its name." },
        };
        _ = dl.textCentered(font_title, x, y + title_h / 2, title, theme.text);
        y += title_h + 8;
        _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, hint, w, theme.text_2);
        y += line_h + 16;
        self.nameField(ui, .{ .x = x, .y = y, .w = w, .h = field_h });
        y += field_h + 22;

        var out: ?Outcome = null;
        var right = box.right() - box_pad;
        if (boxButton(ui, Ui.id("overlay.ok", 0), &right, y, "Rename", .primary)) out = self.renamed();
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

//! A single-line text field for forms (Settings): the value with selection,
//! IME text and a blinking caret while it has the focus; click and drag
//! place the caret; long values scroll to keep the caret in view. The
//! field itself is stateless — the page that draws it owns one `Focus`
//! (an `Editor` plus caret state) and passes it to the field that has it,
//! so a page with many fields carries one editor, not one per field.
const std = @import("std");
const gfx_text = @import("../gfx/text.zig");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const Editor = @import("../input/editor.zig").Editor;
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

pub const height: f32 = 32;

/// The keyboard focus of a form: the editor behind the focused field and
/// its caret. `id` says which field (the page's own numbering).
pub const Focus = struct {
    editor: Editor,
    /// Which field has the focus, in the owner's numbering; 0 = none.
    id: u64 = 0,
    /// The editor's version last copied back into the owner's data.
    synced: u64 = 0,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    seen_version: u64 = 0,
    /// Caret in window coordinates (for the IME candidate window).
    caret: Rect = .{},
    /// Where the focus should go next (Tab / ⇧Tab), consumed by the owner.
    move: i8 = 0,

    pub fn init(gpa: std.mem.Allocator) Focus {
        return .{ .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Focus) void {
        self.editor.deinit();
    }

    pub fn active(self: *const Focus) bool {
        return self.id != 0;
    }

    /// Focuses field `id`, loading `value` into the editor (all selected,
    /// so typing replaces it and ⌘C copies it).
    pub fn take(self: *Focus, id: u64, value: []const u8, now: f64) void {
        self.id = id;
        self.editor.setText(value);
        if (value.len > 0) self.editor.anchor = 0;
        self.synced = self.editor.version;
        self.blink_t0 = now;
        self.blink_on = true;
    }

    pub fn drop(self: *Focus) void {
        self.id = 0;
        self.move = 0;
        self.editor.clear();
    }

    /// True when the editor holds text the owner has not copied back yet;
    /// the owner then stores `editor.bytes()` and calls `markSynced`.
    pub fn changed(self: *const Focus) bool {
        return self.editor.version != self.synced;
    }

    pub fn markSynced(self: *Focus) void {
        self.synced = self.editor.version;
    }

    /// Caret blink; true when a redraw is needed.
    pub fn tick(self: *Focus, now: f64) bool {
        if (!self.active()) return false;
        if (self.editor.version != self.seen_version) {
            self.seen_version = self.editor.version;
            self.blink_t0 = now;
        }
        const on = theme.caretOn(now, self.blink_t0);
        if (on != self.blink_on) {
            self.blink_on = on;
            return true;
        }
        return false;
    }

    // ── keyboard, routed by the owner while a field is focused ──────────
    pub fn onText(self: *Focus, utf8: []const u8) void {
        if (self.active()) self.editor.insert(utf8);
    }

    pub fn onMarkedText(self: *Focus, utf8: []const u8) void {
        if (self.active()) self.editor.setMarked(utf8);
    }

    /// A value is one line: pasted text stops at the first line break.
    pub fn paste(self: *Focus, utf8: []const u8) void {
        if (!self.active()) return;
        const end = std.mem.indexOfAny(u8, utf8, "\r\n") orelse utf8.len;
        self.editor.insert(utf8[0..end]);
    }

    /// Esc and ↵ give the focus up, Tab / ⇧Tab ask to move it; anything
    /// else edits. True when the command was used.
    pub fn onEdit(self: *Focus, cmd: EditCommand) bool {
        if (!self.active()) return false;
        switch (cmd) {
            .cancel, .insert_newline, .insert_line_break => self.drop(),
            .insert_tab => self.move = 1,
            .insert_backtab => self.move = -1,
            .move_up, .move_down, .select_up, .select_down, .page_up, .page_down, .scroll_to_top, .scroll_to_bottom => return false,
            else => _ = self.editor.apply(cmd),
        }
        return true;
    }

    pub fn onCtrl(self: *Focus, key: u8) bool {
        if (!self.active()) return false;
        return switch (key) {
            'c', 'g' => self.onEdit(.cancel),
            'a' => self.onEdit(.move_line_start),
            'e' => self.onEdit(.move_line_end),
            'u' => self.onEdit(.delete_to_line_start),
            'k' => self.onEdit(.delete_to_line_end),
            'w' => self.onEdit(.delete_word_backward),
            'h' => self.onEdit(.delete_backward),
            else => false,
        };
    }

    pub fn copy(self: *Focus, out: *std.ArrayList(u8), cut: bool) bool {
        if (!self.active()) return false;
        const sel = self.editor.selectedText();
        if (sel.len == 0) return false;
        out.appendSlice(self.editor.gpa, sel) catch return false;
        if (cut) _ = self.editor.deleteSelection();
        return true;
    }

    pub fn hasMarkedText(self: *const Focus) bool {
        return self.active() and self.editor.marked.items.len > 0;
    }
};

pub const Options = struct {
    /// Secrets: the value is drawn as dots unless `revealed`.
    masked: bool = false,
    revealed: bool = false,
    /// Shown in place of an empty value.
    placeholder: []const u8 = "",
    font: Font = theme.font_ui,
    /// Room kept free at the right end, inside the box, for controls the
    /// owner draws there (the search field's switches).
    right_pad: f32 = 0,
};

pub const Result = struct {
    /// The field was clicked while another (or none) had the focus: the
    /// owner should `take` it.
    clicked: bool = false,
};

/// Draws field `id` in `r` showing `value`; while `focus.id == id` the
/// editor's text is shown instead and the caret blinks.
pub fn draw(ui: *Ui, focus: *Focus, id: u64, r: Rect, value: []const u8, opts: Options) Result {
    const dl = ui.dl;
    const font = opts.font;
    const focused = focus.id == id;
    const d = ui.drag(id, r);
    if (d.hover or d.dragging) ui.cursor = .ibeam;
    dl.shape(r, 8, theme.bg_inset, 1, if (focused) theme.accent.alpha(0.7) else if (d.hover) theme.line_strong else theme.line);

    var res: Result = .{};
    if (d.started and !focused) {
        res.clicked = true;
        // The caret lands where the click was on the next frame, once the
        // editor holds the value; a plain click selects all for now.
    }

    var inner = r.inset(12, 1);
    inner.w = @max(0, inner.w - opts.right_pad);
    dl.pushClip(.{ .x = r.x + 6, .y = r.y + 1, .w = @max(0, r.w - 12 - opts.right_pad), .h = r.h - 2 });
    defer dl.popClip();
    const cy = r.centerY();

    const text = if (focused) focus.editor.bytes() else value;
    if (text.len == 0) {
        // The placeholder shows in an empty box, focused (the caret sits
        // in front of it) or not.
        _ = dl.textEllipsis(font, inner.x, cy, opts.placeholder, inner.w, theme.text_3);
        if (!focused) return res;
    }

    const hide = opts.masked and !opts.revealed;
    const dot: u21 = '•';
    const scale = dl.scale;

    // Where the caret would land, to scroll it into view when the value is long.
    var shift: f32 = 0;
    if (focused) {
        var caret_off: f32 = 0;
        var it = gfx_text.Utf8Iter{ .bytes = text };
        var pen: f32 = 0;
        while (true) {
            if (it.index == focus.editor.cursor) caret_off = pen;
            const cp = it.next() orelse break;
            pen += ui.text.advance(font, if (hide) dot else cp);
        }
        const marked_w: f32 = if (focus.editor.marked.items.len > 0) ui.text.measure(font, focus.editor.marked.items) else 0;
        shift = @max(0, caret_off + marked_w + 2 - inner.w);
    }
    const x0 = inner.x - shift;

    const clip = blk: {
        const c = dl.currentClip();
        break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
    };
    const sel: ?[2]usize = if (focused) focus.editor.selection() else null;
    const color = if (focused) theme.text else theme.text_2;
    const baseline_px = @round(ui.text.baselineForCenter(font, cy) * scale);
    var pen = x0 * scale;
    var caret_px = pen;
    var hit: ?usize = null;
    var it = gfx_text.Utf8Iter{ .bytes = text };
    while (true) {
        const at = it.index;
        if (focused and at == focus.editor.cursor) caret_px = pen;
        const cp = it.next() orelse break;
        const adv = ui.text.advance(font, if (hide) dot else cp) * scale;
        if (focused and (d.started or d.dragging) and hit == null and ui.mx * scale < pen + adv / 2) hit = at;
        if (sel) |s| if (at >= s[0] and at < s[1]) {
            dl.rect(.{ .x = pen / scale, .y = cy - 10, .w = adv / scale, .h = 20 }, theme.selection());
        };
        _ = dl.glyph(font, if (hide) dot else cp, pen, baseline_px, color, clip);
        pen += adv;
    }
    if (!focused) return res;

    if (d.started or d.dragging) {
        const off = hit orelse text.len;
        if (d.started and d.double_clicked) {
            focus.editor.selectWordAt(off);
        } else if (d.started) {
            focus.editor.setCursor(off, ui.mods.shift);
        } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
            focus.editor.setCursor(off, true);
        }
    }
    var cx = caret_px / scale;
    if (focus.editor.marked.items.len > 0) {
        const mw = dl.textCentered(font, cx, cy, focus.editor.marked.items, theme.text);
        dl.rect(.{ .x = cx, .y = cy + 9, .w = mw, .h = 1 }, theme.text_2);
        cx += mw;
    }
    focus.caret = .{ .x = cx, .y = cy - 9, .w = 2, .h = 18 };
    if (focus.blink_on or ui.down) dl.rect(focus.caret, theme.accent);
    return res;
}

/// A small text button (a "Show" / "Hide" toggle beside a masked field,
/// "Remove" on a card …). Returns true when clicked.
pub fn textButton(ui: *Ui, id: u64, r: Rect, label: []const u8, color: Color) bool {
    const st = ui.button(id, r);
    ui.feedback(r, 6, st);
    const w = ui.text.measure(theme.font_hint, label);
    _ = ui.dl.textCentered(theme.font_hint, r.x + (r.w - w) / 2, r.centerY(), label, if (st.hover) theme.text else color);
    return st.clicked;
}

/// One pill of a segmented choice (Dark / Light / System, the providers).
/// Returns true when clicked.
pub fn chip(ui: *Ui, id: u64, r: Rect, label: []const u8, selected: bool) bool {
    const dl = ui.dl;
    const st = ui.button(id, r);
    if (selected) {
        dl.rrect(r, r.h / 2, theme.accent.alpha(0.16));
        dl.border(r, r.h / 2, 1, theme.accent.alpha(0.5));
    } else {
        dl.rrect(r, r.h / 2, if (st.held) theme.pressed else if (st.hover) theme.hover else theme.chip_active);
    }
    const w = ui.text.measure(theme.font_chip, label);
    _ = dl.textCentered(theme.font_chip, r.x + (r.w - w) / 2, r.centerY(), label, if (selected or st.hover) theme.text else theme.text_2);
    return st.clicked;
}

/// Width `chip` needs for `label`.
pub fn chipWidth(ui: *Ui, label: []const u8) f32 {
    return ui.text.measure(theme.font_chip, label) + 24;
}

// ── dropdown ────────────────────────────────────────────────────────────
/// What a dropdown row shows before its label.
pub const Swatch = union(enum) {
    none,
    /// A colour dot (the accent options).
    dot: Color,
    /// A theme in miniature: its background with four of its colours.
    theme: struct { bg: Color, dots: [4]Color },
    /// Two backgrounds side by side (following macOS: dark or light).
    split: struct { left: Color, right: Color },
};

/// One row of a dropdown.
pub const Choice = struct {
    label: []const u8,
    swatch: Swatch = .none,
    /// A thin line above the row (a group of its own starts here).
    sep_before: bool = false,
};

/// The dropdowns of one page. At most one menu is open. The page draws
/// each dropdown's button where it goes (`dropdown`), and the open menu
/// after everything else (`drawMenu`) so it lies on top; while one is
/// open the page draws with the mouse off (`modal`), so nothing under the
/// menu reacts. A pick made in the menu reaches the button's call on the
/// next frame (it asks for one).
pub const Dropdown = struct {
    pub const max_choices = 48;
    /// The open menu's dropdown, 0 = none.
    open: u64 = 0,
    anchor: Rect = .{},
    choices: [max_choices]Choice = undefined,
    count: usize = 0,
    selected: ?usize = null,
    /// The keyboard's row (↑/↓, ↵ picks it).
    highlighted: ?usize = null,
    scroll: f32 = 0,
    /// Scroll the current choice into view on the next draw (just opened).
    reveal: bool = false,
    /// A choice made in the menu, waiting for its dropdown's call.
    picked_id: u64 = 0,
    picked: usize = 0,
    last_mx: f32 = -1,
    last_my: f32 = -1,

    pub fn isOpen(self: *const Dropdown) bool {
        return self.open != 0;
    }

    pub fn close(self: *Dropdown) void {
        self.open = 0;
    }

    /// Keys while a menu is open: ↑/↓ move, ↵ picks, Esc closes. True
    /// when the key was the menu's.
    pub fn onEdit(self: *Dropdown, cmd: EditCommand) bool {
        if (!self.isOpen()) return false;
        switch (cmd) {
            .cancel => self.close(),
            .move_up => {
                const cur = self.highlighted orelse self.selected orelse 0;
                self.highlighted = if (cur == 0) self.count - 1 else cur - 1;
            },
            .move_down => {
                const cur = self.highlighted orelse self.selected orelse self.count - 1;
                self.highlighted = if (cur + 1 >= self.count) 0 else cur + 1;
            },
            .insert_newline => if (self.highlighted) |i| self.pick(i) else self.close(),
            else => return false,
        }
        return true;
    }

    fn pick(self: *Dropdown, i: usize) void {
        self.picked_id = self.open;
        self.picked = i;
        self.close();
    }

    /// Row height, the menu's inner padding and the gap between rows.
    const row_h: f32 = 32;
    const pad: f32 = 6;
    const sep_h: f32 = 9;

    /// The open menu, under its button (above it when there is no room
    /// below), inside `bounds`. Call after the page is drawn, with the
    /// mouse back on.
    pub fn drawMenu(self: *Dropdown, ui: *Ui, bounds: Rect) void {
        if (!self.isOpen()) return;
        const dl = ui.dl;
        const choices = self.choices[0..self.count];
        var widest: f32 = 0;
        var content_h: f32 = 0;
        for (choices, 0..) |c, i| {
            widest = @max(widest, ui.text.measure(theme.font_ui, c.label) + swatchWidth(c.swatch));
            content_h += row_h + (if (c.sep_before and i > 0) sep_h else 0);
        }
        const w = @max(self.anchor.w, @min(widest + 30 + 20 + 2 * pad, bounds.w - 16));
        const room_below = bounds.bottom() - 8 - (self.anchor.bottom() + 4);
        const room_above = self.anchor.y - 4 - (bounds.y + 8);
        const below = room_below >= @min(content_h + 2 * pad, 240) or room_below >= room_above;
        const inner_h = @max(row_h, @min(content_h, (if (below) room_below else room_above) - 2 * pad));
        const h = inner_h + 2 * pad;
        const panel: Rect = .{
            .x = std.math.clamp(self.anchor.right() - w, bounds.x + 8, @max(bounds.x + 8, bounds.right() - 8 - w)),
            .y = if (below) self.anchor.bottom() + 4 else self.anchor.y - 4 - h,
            .w = w,
            .h = h,
        };
        ui.interactive.append(ui.gpa, panel) catch {};
        if (ui.pressed and !panel.contains(ui.mx, ui.my)) {
            // Its own button's press closes it too (and does not reopen it:
            // the page drew with the mouse off).
            self.close();
            return;
        }
        theme.dropShadow(dl, panel, 8, 3, 5, 8, 0.08);
        dl.shape(panel, 8, theme.bg_panel, 1, theme.line_strong);
        const max_scroll = @max(0, content_h - inner_h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(panel), 0, max_scroll);
        // A long list opens with the current choice in the middle.
        if (self.reveal) {
            self.reveal = false;
            if (self.selected) |sel| if (sel < choices.len) {
                var top: f32 = 0;
                for (choices[0..sel], 0..) |c, i| top += row_h + (if (c.sep_before and i > 0) sep_h else 0);
                if (choices[sel].sep_before and sel > 0) top += sep_h;
                self.scroll = std.math.clamp(top + row_h / 2 - inner_h / 2, 0, max_scroll);
            };
        }
        // The keyboard's row stays in view.
        if (self.highlighted) |hl| if (!ui.mouseIn(panel)) {
            var top: f32 = 0;
            for (choices[0..hl], 0..) |c, i| top += row_h + (if (c.sep_before and i > 0) sep_h else 0);
            if (choices[hl].sep_before and hl > 0) top += sep_h;
            if (top < self.scroll) self.scroll = top;
            if (top + row_h > self.scroll + inner_h) self.scroll = top + row_h - inner_h;
        };
        const inner: Rect = .{ .x = panel.x, .y = panel.y + pad, .w = panel.w, .h = inner_h };
        dl.pushClip(inner);
        defer dl.popClip();
        // The mouse takes over the highlight only when it moves.
        const moved = ui.mx != self.last_mx or ui.my != self.last_my;
        self.last_mx = ui.mx;
        self.last_my = ui.my;
        var y = inner.y - self.scroll;
        for (choices, 0..) |c, i| {
            if (c.sep_before and i > 0) {
                dl.rect(.{ .x = panel.x + pad + 4, .y = y + sep_h / 2, .w = panel.w - 2 * pad - 8, .h = 1 }, theme.line);
                y += sep_h;
            }
            const r: Rect = .{ .x = panel.x + pad, .y = y, .w = panel.w - 2 * pad, .h = row_h };
            y += row_h;
            if (r.bottom() <= inner.y or r.y >= inner.bottom()) continue;
            const st = ui.button(Ui.id("field.dropdown.row", i), r);
            if (st.hover and moved) self.highlighted = i;
            if (st.held) {
                dl.rrect(r, 6, theme.pressed);
            } else if (self.highlighted == i) dl.rrect(r, 6, theme.highlight);
            if (self.selected == i) dl.icon(.check, r.x + 8, r.centerY() - 7, 14, theme.accent);
            const sx = r.x + 30;
            drawSwatch(dl, c.swatch, sx, r.centerY());
            _ = dl.textEllipsis(theme.font_ui, sx + swatchWidth(c.swatch), r.centerY(), c.label, r.right() - 10 - sx - swatchWidth(c.swatch), theme.text);
            if (st.clicked) {
                self.pick(i);
                ui.wants_frame = true;
            }
        }
        if (max_scroll > 0) {
            // A thin thumb at the right edge says there is more.
            const th = @max(24, inner_h * inner_h / content_h);
            const ty = inner.y + (inner_h - th) * (self.scroll / max_scroll);
            dl.rrect(.{ .x = panel.right() - 5, .y = ty, .w = 3, .h = th }, 1.5, theme.line_strong);
        }
    }
};

fn swatchWidth(s: Swatch) f32 {
    return switch (s) {
        .none => 0,
        .dot => 22,
        .theme, .split => 44,
    };
}

fn drawSwatch(dl: anytype, s: Swatch, x: f32, cy: f32) void {
    switch (s) {
        .none => {},
        .dot => |c| dl.circle(x + 7, cy, 7, c),
        .theme => |t| {
            const r: Rect = .{ .x = x, .y = cy - 9, .w = 34, .h = 18 };
            dl.shape(r, 4, t.bg, 1, theme.line_strong);
            for (t.dots, 0..) |c, i| dl.circle(r.x + 7 + @as(f32, @floatFromInt(i)) * 6.7, cy, 2.6, c);
        },
        .split => |sp| {
            const r: Rect = .{ .x = x, .y = cy - 9, .w = 34, .h = 18 };
            dl.rrect(r, 4, sp.right);
            dl.rrect(.{ .x = r.x, .y = r.y, .w = r.w / 2 + 4, .h = r.h }, 4, sp.left);
            dl.rect(.{ .x = r.x + r.w / 2, .y = r.y, .w = 4, .h = r.h }, sp.right);
            dl.border(r, 4, 1, theme.line_strong);
        },
    }
}

/// A dropdown: a button that shows the current choice and opens the menu
/// of `choices` (drawn later by `dd.drawMenu`). Returns the index picked,
/// once, on the frame after the pick.
pub fn dropdown(ui: *Ui, dd: *Dropdown, id: u64, r: Rect, choices: []const Choice, selected: ?usize) ?usize {
    const dl = ui.dl;
    const st = ui.button(id, r);
    const open = dd.open == id;
    dl.shape(r, 7, if (st.held) theme.pressed else if (st.hover or open) theme.hover else theme.bg_block, 1, if (open) theme.accent.alpha(0.6) else theme.line_strong);
    if (selected) |i| if (i < choices.len) {
        const c = choices[i];
        drawSwatch(dl, c.swatch, r.x + 10, r.centerY());
        const tx = r.x + 10 + swatchWidth(c.swatch);
        _ = dl.textEllipsis(theme.font_ui, tx, r.centerY(), c.label, r.right() - 30 - tx, theme.text);
    };
    dl.icon(.chevron_down, r.right() - 24, r.centerY() - 7, 14, if (st.hover or open) theme.text else theme.text_3);
    if (open) {
        // Kept current while open: labels and colours follow a scheme change.
        dd.anchor = r;
        dd.count = @min(choices.len, Dropdown.max_choices);
        @memcpy(dd.choices[0..dd.count], choices[0..dd.count]);
        dd.selected = selected;
    }
    if (st.clicked and !open) {
        dd.open = id;
        dd.anchor = r;
        dd.count = @min(choices.len, Dropdown.max_choices);
        @memcpy(dd.choices[0..dd.count], choices[0..dd.count]);
        dd.selected = selected;
        dd.highlighted = null;
        dd.scroll = 0;
        dd.reveal = true;
        dd.last_mx = ui.mx;
        dd.last_my = ui.my;
        ui.wants_frame = true;
    }
    if (dd.picked_id == id) {
        dd.picked_id = 0;
        return dd.picked;
    }
    return null;
}

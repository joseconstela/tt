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

    const inner = r.inset(12, 1);
    dl.pushClip(r.inset(6, 1));
    defer dl.popClip();
    const cy = r.centerY();

    const text = if (focused) focus.editor.bytes() else value;
    if (text.len == 0 and !focused) {
        _ = dl.textEllipsis(font, inner.x, cy, opts.placeholder, inner.w, theme.text_3);
        return res;
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

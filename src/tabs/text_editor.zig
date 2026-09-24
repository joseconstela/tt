//! The editing surface shared by the file tab and Markdown's source mode: a
//! `Document` drawn as mono text with syntax colours and line numbers, plus
//! a caret, a selection and IME composition. Keyboard input arrives as
//! `EditCommand`s (the user's own Cocoa key bindings), the mouse places the
//! caret and drags selections, a right-click asks for the edit menu (Cut /
//! Copy / Paste), and the view follows the caret after keys.
//!
//! Lines are not wrapped: long lines scroll horizontally, as in a code
//! editor, with draggable bars on both axes and a drag past an edge pulling
//! the view along. Only the visible lines are lexed and drawn, every frame,
//! from the document's per-line syntax state.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const gfx_text = @import("../gfx/text.zig");
const Position = @import("tab.zig").Position;
const lexer = @import("../syntax/lexer.zig");
const Document = @import("../input/document.zig").Document;
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const line_h = theme.output_line_h;
const tab_width: usize = 4;
const default_pad_top: f32 = 10;
const default_pad_bottom: f32 = 24;

pub const TextEditor = struct {
    gpa: std.mem.Allocator,
    doc: Document,
    /// Navigation and copying only.
    read_only: bool = false,
    /// Room above the first and below the last line. A file editor keeps
    /// the defaults; a notebook cell, sized to its text, wants less.
    pad_top: f32 = default_pad_top,
    pad_bottom: f32 = default_pad_bottom,
    /// The line-number gutter; off for a cell that shows a few lines.
    gutter: bool = true,
    scroll: f32 = 0,
    scroll_x: f32 = 0,
    content_h: f32 = 0,
    /// Rows that fit in the body, from the last draw (for ⇞/⇟).
    rows_visible: usize = 20,
    /// Bring the caret into view on the next draw (set by keyboard actions).
    follow: bool = false,
    /// With `follow`: put the caret's line in the middle of the view
    /// (a go-to-line jump) rather than just inside it.
    center: bool = false,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    seen_version: u64 = 0,
    caret: Rect = .{},
    /// Salt for the widget id, so two editors on screen do not share a drag.
    salt: usize,
    spans: lexer.Spans = .{},
    /// Widest line in display columns: measured on load, then kept up to
    /// date from the lines that get drawn. It never shrinks, which costs
    /// nothing but a little slack at the right; a reload measures afresh.
    max_cols: usize = 0,

    pub fn init(gpa: std.mem.Allocator, salt: usize) TextEditor {
        return .{ .gpa = gpa, .doc = Document.init(gpa), .salt = salt };
    }

    pub fn deinit(self: *TextEditor) void {
        self.doc.deinit();
    }

    pub fn load(self: *TextEditor, data: []const u8, lang: lexer.Language) !void {
        try self.doc.setText(data, lang);
        self.scroll = 0;
        self.scroll_x = 0;
        self.follow = false;
        self.max_cols = 0;
        var i: usize = 0;
        const n = self.doc.lineCount();
        while (i < n) : (i += 1) self.noteWidth(self.doc.lineText(i));
    }

    /// Byte offset of the caret (what a relaunch brings back).
    pub fn caretOffset(self: *const TextEditor) usize {
        return self.doc.editor.cursor;
    }

    /// Puts the caret at a byte offset from an earlier run — clamped, on a
    /// character boundary — and scrolls to it on the next draw.
    pub fn placeCaret(self: *TextEditor, offset: usize) void {
        const text = self.doc.bytes();
        var pos = @min(offset, text.len);
        while (pos > 0 and pos < text.len and (text[pos] & 0xC0) == 0x80) pos -= 1;
        self.doc.editor.setCursor(pos, false);
        self.follow = true;
    }

    /// Selects `len` bytes at a 0-based line and byte column (clamped to
    /// the line) and scrolls there on the next draw.
    pub fn selectSpan(self: *TextEditor, line: u32, col: u32, len: u32) void {
        const n = self.doc.lineCount();
        if (n == 0) return;
        const li: usize = @min(line, n - 1);
        const ls = self.doc.lineStartOf(li);
        const le = self.doc.lineEndOf(li);
        const start = @min(ls + col, le);
        const end = @min(start + len, le);
        self.doc.editor.setCursor(start, false);
        if (end > start) self.doc.editor.setCursor(end, true);
        self.follow = true;
    }

    /// Where the caret is, 1-based, as "go to line" counts (columns in
    /// display cells, tabs expanded).
    pub fn position(self: *const TextEditor) Position {
        const line = self.doc.lineOf(self.doc.editor.cursor);
        return .{ .line = line + 1, .col = self.colAt(line, self.doc.editor.cursor) + 1, .lines = self.doc.lineCount() };
    }

    /// Puts the caret on a 1-based line and column (0 = the line's start),
    /// both clamped to the text, and centres the line on the next draw.
    pub fn goTo(self: *TextEditor, line: usize, col: usize) void {
        const n = self.doc.lineCount();
        const li = @min(@max(line, 1), n) - 1;
        const off = self.offsetAtCol(li, if (col == 0) 0 else col - 1);
        self.doc.editor.setCursor(off, false);
        self.follow = true;
        self.center = true;
    }

    /// Height of the whole text with the padding: what a body must be for
    /// nothing to scroll (a notebook cell grows to this).
    pub fn height(self: *const TextEditor) f32 {
        return @as(f32, @floatFromInt(@max(1, self.doc.lineCount()))) * line_h + self.pad_top + self.pad_bottom;
    }

    // ── input ───────────────────────────────────────────────────────────
    fn mutates(cmd: EditCommand) bool {
        return switch (cmd) {
            .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward, .delete_to_line_start, .delete_to_line_end, .insert_newline, .insert_line_break, .insert_tab, .insert_backtab => true,
            else => false,
        };
    }

    pub fn onText(self: *TextEditor, utf8: []const u8) void {
        if (self.read_only) return;
        self.doc.insert(utf8);
        self.follow = true;
    }

    pub fn onMarkedText(self: *TextEditor, utf8: []const u8) void {
        if (self.read_only) return;
        self.doc.setMarked(utf8);
        self.follow = true;
    }

    pub fn onEdit(self: *TextEditor, cmd: EditCommand) void {
        const e = &self.doc.editor;
        switch (cmd) {
            .page_up, .page_down => {
                const step = @max(1, self.rows_visible) - 1;
                const cur_line = self.doc.lineOf(e.cursor);
                const target = if (cmd == .page_up) cur_line -| step else @min(self.doc.lineCount() - 1, cur_line + step);
                const col = e.cursor - self.doc.lineStartOf(cur_line);
                const ls = self.doc.lineStartOf(target);
                e.setCursor(@min(ls + col, self.doc.lineEndOf(target)), false);
            },
            .scroll_to_top => {
                self.scroll = 0;
                return;
            },
            .scroll_to_bottom => {
                self.scroll = self.content_h;
                return;
            },
            .cancel => {
                e.anchor = null;
                e.version +%= 1;
            },
            else => {
                if (self.read_only and mutates(cmd)) return;
                _ = self.doc.apply(cmd);
            },
        }
        self.follow = true;
    }

    pub fn copy(self: *TextEditor, out: *std.ArrayList(u8), cut: bool) bool {
        const sel = self.doc.editor.selection() orelse return false;
        out.appendSlice(self.gpa, self.doc.editor.selectedText()) catch return false;
        if (cut and !self.read_only) {
            self.doc.replace(sel[0], sel[1], "");
            self.follow = true;
        }
        return true;
    }

    pub fn paste(self: *TextEditor, utf8: []const u8) void {
        if (self.read_only) return;
        if (std.mem.indexOfScalar(u8, utf8, '\r') == null) {
            self.doc.insert(utf8);
        } else {
            var clean: std.ArrayList(u8) = .empty;
            defer clean.deinit(self.gpa);
            for (utf8, 0..) |b, i| {
                if (b == '\r') {
                    if (i + 1 < utf8.len and utf8[i + 1] == '\n') continue;
                    clean.append(self.gpa, '\n') catch return;
                } else clean.append(self.gpa, b) catch return;
            }
            self.doc.insert(clean.items);
        }
        self.follow = true;
    }

    pub fn hasMarkedText(self: *const TextEditor) bool {
        return self.doc.editor.marked.items.len > 0;
    }

    pub fn undo(self: *TextEditor) bool {
        if (self.read_only) return false;
        self.follow = true;
        return self.doc.undo();
    }

    pub fn redo(self: *TextEditor) bool {
        if (self.read_only) return false;
        self.follow = true;
        return self.doc.redo();
    }

    /// Caret blink; true when the view needs a redraw.
    pub fn tick(self: *TextEditor, now: f64, active: bool) bool {
        if (self.doc.editor.version != self.seen_version) {
            self.seen_version = self.doc.editor.version;
            self.blink_t0 = now;
            self.blink_on = true;
        }
        const on = theme.caretOn(now, self.blink_t0);
        if (on != self.blink_on) {
            self.blink_on = on;
            return active;
        }
        return false;
    }

    // ── columns ─────────────────────────────────────────────────────────
    fn advanceOf(cp: u21, col: usize) usize {
        if (cp == '\t') return tab_width - (col % tab_width);
        return gfx_text.cellWidth(cp);
    }

    /// Display column of byte `offset` within line `i`.
    fn colAt(self: *const TextEditor, i: usize, offset: usize) usize {
        const line = self.doc.lineText(i);
        const rel = offset -| self.doc.lineStartOf(i);
        var col: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = line };
        while (it.index < rel and it.index < line.len) {
            const cp = it.next() orelse break;
            col += advanceOf(cp, col);
        }
        return col;
    }

    /// Display column reached by `rest`, which starts at column `col`.
    fn colsOf(rest: []const u8, col: usize) usize {
        // Nearly every line is ASCII without tabs: one column per byte.
        var plain = true;
        for (rest) |b| {
            if (b >= 0x80 or b == '\t') {
                plain = false;
                break;
            }
        }
        if (plain) return col + rest.len;
        var c = col;
        var it = gfx_text.Utf8Iter{ .bytes = rest };
        while (it.next()) |cp| c += advanceOf(cp, c);
        return c;
    }

    fn noteWidth(self: *TextEditor, line: []const u8) void {
        self.max_cols = @max(self.max_cols, colsOf(line, 0));
    }

    /// Width of the text in points, with a little room past the longest line.
    fn contentW(self: *const TextEditor, cell: f32) f32 {
        return (@as(f32, @floatFromInt(self.max_cols)) + 2) * cell;
    }

    /// How far a drag past an edge (`lo`..`hi`) pulls the view per frame:
    /// gently near the edge, faster further out.
    fn edgePull(pos: f32, lo: f32, hi: f32) f32 {
        if (pos < lo) return -@min(48, 3 + (lo - pos) * 0.2);
        if (pos > hi) return @min(48, 3 + (pos - hi) * 0.2);
        return 0;
    }

    /// Byte offset (absolute) closest to display column `col` on line `i`.
    fn offsetAtCol(self: *const TextEditor, i: usize, col: usize) usize {
        const line = self.doc.lineText(i);
        const ls = self.doc.lineStartOf(i);
        var acc: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = line };
        while (true) {
            const at = it.index;
            const cp = it.next() orelse return ls + line.len;
            const w = advanceOf(cp, acc);
            if (acc + (w + 1) / 2 > col) return ls + at;
            acc += w;
        }
    }

    /// The line under a point of the body (clamped to the text).
    fn lineAt(self: *const TextEditor, my: f32, body: Rect) usize {
        const rel_y = @max(0, my - body.y - self.pad_top + self.scroll);
        return @min(self.doc.lineCount() - 1, @as(usize, @intFromFloat(@floor(rel_y / line_h))));
    }

    /// The byte offset nearest a point of the body, with the text starting
    /// at `text_x0` in cells `cell` wide.
    fn offsetAt(self: *const TextEditor, mx: f32, my: f32, body: Rect, text_x0: f32, cell: f32) usize {
        const rel_x = @max(0, mx - text_x0 + self.scroll_x);
        const col: usize = @intFromFloat(@floor(rel_x / cell + 0.5));
        return self.offsetAtCol(self.lineAt(my, body), col);
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *TextEditor, ui: *Ui, body: Rect, focused: bool) void {
        const dl = ui.dl;
        const scale = dl.scale;
        const font = theme.font_output;
        const doc = &self.doc;
        const e = &doc.editor;
        const cell = ui.text.cellAdvance(font);
        const n = doc.lineCount();

        const digits: f32 = @floatFromInt(@max(3, std.fmt.count("{d}", .{n})));
        const px = body.x + theme.block_pad_x;
        const gutter_w: f32 = if (self.gutter) digits * cell + 14 else 0;
        const text_x0 = px + gutter_w + (if (self.gutter) @as(f32, 10) else 0);
        const text_area: Rect = .{ .x = text_x0 - 4, .y = body.y, .w = @max(0, body.right() - theme.block_pad_x - (text_x0 - 4)), .h = body.h };
        const visible_w = @max(cell * 4, text_area.w - 12);

        self.content_h = @as(f32, @floatFromInt(n)) * line_h + self.pad_top + self.pad_bottom;
        self.rows_visible = @intFromFloat(@max(1, @floor((body.h - self.pad_top) / line_h)));
        const max_scroll = @max(0, self.content_h - body.h);

        // Wheel.
        self.scroll -= ui.takeScroll(body);
        if (ui.scroll_x != 0 and ui.mouseIn(body)) {
            self.scroll_x = @max(0, self.scroll_x - ui.scroll_x);
            ui.scroll_x = 0;
        }

        // Scrollbars take the mouse first, so a press on a thumb is never a
        // click in the text. The horizontal bar spans the text area only;
        // its content is padded so that its travel equals the scroll range.
        const vbar = Ui.id("text_editor.vbar", self.salt);
        const hbar = Ui.id("text_editor.hbar", self.salt);
        const hbar_area: Rect = .{ .x = text_area.x, .y = body.y, .w = text_area.w, .h = body.h };
        const hbar_pad = text_area.w - visible_w;
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, body, self.scroll, self.content_h)) |s| self.scroll = s;
        if (sidebar.scrollbarDrag(ui, hbar, .horizontal, hbar_area, self.scroll_x, self.contentW(cell) + hbar_pad)) |s| self.scroll_x = s;

        // Mouse: caret, word, line, drag selection. A drag past an edge
        // scrolls the view that way, so a selection can grow off screen.
        const d = ui.drag(Ui.id("text_editor", self.salt), body);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (d.dragging and !d.started) {
            const dy = edgePull(ui.my, body.y, body.bottom());
            const dx = edgePull(ui.mx, text_area.x, text_area.right());
            if (dy != 0 or dx != 0) {
                self.scroll = std.math.clamp(self.scroll + dy, 0, max_scroll);
                self.scroll_x = std.math.clamp(self.scroll_x + dx, 0, @max(0, self.contentW(cell) - visible_w));
                ui.wants_frame = true;
            }
        }
        if (d.started or d.dragging) {
            const line = self.lineAt(ui.my, body);
            const off = self.offsetAt(ui.mx, ui.my, body, text_x0, cell);
            if (d.started) {
                if (ui.click_count >= 3) {
                    doc.selectLine(line);
                } else if (ui.click_count == 2) {
                    e.selectWordAt(off);
                } else {
                    e.setCursor(off, ui.mods.shift);
                }
            } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                e.setCursor(off, true);
            }
            self.follow = false;
        }

        // A right-click puts the caret there, unless it lands in the
        // selection (what the menu then acts on), and asks for the edit menu.
        if (ui.rightClicked(body)) {
            const off = self.offsetAt(ui.mx, ui.my, body, text_x0, cell);
            const in_selection = if (e.selection()) |s| off >= s[0] and off <= s[1] else false;
            if (!in_selection) e.setCursor(off, false);
            self.follow = false;
            ui.askEditMenu(e.selection() != null, !self.read_only);
        }

        // Follow the caret after keyboard actions. The caret's line is
        // measured first, so the clamp below cannot cut the caret off.
        const caret_line = doc.lineOf(e.cursor);
        if (self.follow) {
            self.follow = false;
            self.noteWidth(doc.lineText(caret_line));
            const top = self.pad_top + @as(f32, @floatFromInt(caret_line)) * line_h;
            if (self.center) {
                self.center = false;
                self.scroll = @max(0, top - (body.h - line_h) / 2);
            } else {
                if (top - line_h < self.scroll) self.scroll = @max(0, top - line_h);
                if (top + 2 * line_h > self.scroll + body.h) self.scroll = top + 2 * line_h - body.h;
            }
            const cx = @as(f32, @floatFromInt(self.colAt(caret_line, e.cursor))) * cell;
            if (cx < self.scroll_x + cell) self.scroll_x = @max(0, cx - 4 * cell);
            if (cx > self.scroll_x + visible_w - cell) self.scroll_x = cx - visible_w + 6 * cell;
        }
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
        self.scroll_x = std.math.clamp(self.scroll_x, 0, @max(0, self.contentW(cell) - visible_w));

        dl.pushClip(body);
        defer dl.popClip();

        const first: usize = @intFromFloat(@floor(@max(0, self.scroll - self.pad_top) / line_h));
        const y0 = body.y + self.pad_top - self.scroll;
        const x_start = text_x0 - self.scroll_x;

        // Current line, quietly.
        if (focused and e.selection() == null) {
            const ly = y0 + @as(f32, @floatFromInt(caret_line)) * line_h;
            if (ly + line_h > body.y and ly < body.bottom()) dl.rect(.{ .x = body.x, .y = ly, .w = body.w, .h = line_h }, theme.line_highlight);
        }

        // Gutter.
        if (self.gutter) {
            var i = first;
            while (i < n) : (i += 1) {
                const y = y0 + @as(f32, @floatFromInt(i)) * line_h;
                if (y > body.bottom()) break;
                var num_buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
                const color = if (i == caret_line and focused) theme.text_2 else theme.text_3.alpha(0.7);
                _ = dl.textRight(font, px + gutter_w - 8, y + line_h / 2, num, color);
            }
        }

        // Text.
        dl.pushClip(text_area);
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const sel = e.selection();
        var caret_x: f32 = x_start;
        var caret_y: f32 = y0 + @as(f32, @floatFromInt(caret_line)) * line_h;
        var i = first;
        while (i < n) : (i += 1) {
            const y = y0 + @as(f32, @floatFromInt(i)) * line_h;
            if (y > body.bottom()) break;
            const line = doc.lineText(i);
            const ls = doc.lineStartOf(i);
            doc.lexInto(i, &self.spans);
            var cur: usize = 0;
            const baseline_px = @round(ui.text.baselineForCenter(font, y + line_h / 2) * scale);
            var col: usize = 0;
            var it = gfx_text.Utf8Iter{ .bytes = line };
            var past_right = false;
            var at: usize = 0;
            while (true) {
                at = it.index;
                if (i == caret_line and ls + at == e.cursor) caret_x = x_start + @as(f32, @floatFromInt(col)) * cell;
                const cp = it.next() orelse break;
                const w = advanceOf(cp, col);
                const cx = x_start + @as(f32, @floatFromInt(col)) * cell;
                const cw = @as(f32, @floatFromInt(w)) * cell;
                if (cx > text_area.right()) {
                    past_right = true;
                    break;
                }
                const visible = cx + cw >= text_area.x;
                if (visible) {
                    if (sel) |s| if (ls + at >= s[0] and ls + at < s[1]) {
                        dl.rect(.{ .x = cx, .y = y + 1, .w = cw, .h = line_h - 2 }, theme.selection());
                    };
                    if (cp != '\t' and cp != ' ') {
                        const scope = self.spans.scopeAt(&cur, at);
                        _ = dl.glyph(font, cp, @round(cx * scale), baseline_px, theme.scopeColor(scope), clip);
                    }
                }
                col += w;
            }
            // The line's full width feeds the horizontal range (the rest is
            // counted, not drawn, when it runs off the right).
            self.max_cols = @max(self.max_cols, if (past_right) colsOf(line[at..], col) else col);
            if (!past_right) {
                if (i == caret_line and e.cursor == ls + line.len) caret_x = x_start + @as(f32, @floatFromInt(col)) * cell;
                // The newline is part of the selection: a half cell says so.
                if (sel) |s| if (ls + line.len >= s[0] and ls + line.len < s[1] and i + 1 < n) {
                    dl.rect(.{ .x = x_start + @as(f32, @floatFromInt(col)) * cell, .y = y + 1, .w = cell * 0.5, .h = line_h - 2 }, theme.selection());
                };
            } else if (i == caret_line and e.cursor >= ls + it.index) {
                caret_x = text_area.right() + cell; // off screen to the right
            }
            if (i == caret_line) caret_y = y;
        }

        // IME composition at the caret, then the caret.
        if (e.marked.items.len > 0) {
            const w = dl.textCentered(font, caret_x, caret_y + line_h / 2, e.marked.items, theme.text);
            dl.rect(.{ .x = caret_x, .y = caret_y + line_h - 3, .w = w, .h = 1 }, theme.text_2);
            caret_x += w;
        }
        self.caret = .{ .x = caret_x, .y = caret_y + 2, .w = 2, .h = line_h - 4 };
        const caret_visible = caret_y + line_h > body.y and caret_y < body.bottom() and caret_x >= text_area.x - 1 and caret_x <= text_area.right();
        if (focused and caret_visible and (self.blink_on or ui.down)) dl.rect(self.caret, if (self.read_only) theme.text_3 else theme.accent);
        dl.popClip();

        sidebar.drawScrollbarAxis(ui, vbar, .vertical, body, self.scroll, self.content_h);
        sidebar.drawScrollbarAxis(ui, hbar, .horizontal, hbar_area, self.scroll_x, self.contentW(cell) + hbar_pad);
    }
};

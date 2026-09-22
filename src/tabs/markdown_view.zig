//! Markdown's visual mode: the document rendered in place — headings in
//! their sizes, bullets, quote bars, code blocks, bold and links — while it
//! stays the editable source. The Markdown lexer's spans are the
//! decorations: `.marker` spans are hidden except on the caret's line, where
//! the raw syntax shows so it can be edited (the Obsidian "live preview"
//! model). Every line is laid out from its spans, wrapped to the column
//! width, and its height cached; an edit patches the cache through the
//! document's change ring.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const gfx_text = @import("../gfx/text.zig");
const draw_mod = @import("../gfx/draw.zig");
const lexer = @import("../syntax/lexer.zig");
const markdown = @import("../syntax/markdown.zig");
const Document = @import("../input/document.zig").Document;
const TextEditor = @import("text_editor.zig").TextEditor;
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Font = draw_mod.Font;
const Color = draw_mod.Color;

// Type ramp.
const prose_font = Font.sans(15);
const prose_h: f32 = 25;
const heading_fonts = [6]Font{ Font.semibold(26), Font.semibold(21), Font.semibold(18), Font.semibold(16), Font.semibold(15), Font.semibold(15) };
const heading_h = [6]f32{ 36, 31, 28, 26, 25, 25 };
const heading_gap = [6]f32{ 14, 12, 10, 8, 6, 6 };
const code_font = Font.mono(13);
const code_h: f32 = 21;
const meta_font = Font.mono(12.5);
const meta_h: f32 = 19;
const blank_h: f32 = 22;
const hr_h: f32 = 22;
const fence_edge_h: f32 = 8;
const pad_top: f32 = 16;
const pad_bottom: f32 = 48;
const side_pad: f32 = theme.block_pad_x + 6;
const quote_indent: f32 = 18;
const list_text_indent: f32 = 22;
const indent_px: f32 = 7;
const tab_width: usize = 4;

const Bullet = enum { none, dot, todo, done };

const Glyph = struct {
    /// Byte range within the line.
    off: u32,
    end: u32,
    x: f32,
    w: f32,
    row: u16,
    font: Font,
    color: Color,
    cp: u21,
    underline: bool = false,
    strike: bool = false,
    code_bg: bool = false,
};

const Layout = struct {
    kind: markdown.BlockKind = .paragraph,
    row_h: f32 = prose_h,
    top_gap: f32 = 0,
    rows: u16 = 1,
    /// Text origin, relative to the content's left edge.
    x0: f32 = 0,
    code_bg: bool = false,
    hr: bool = false,
    quote_depth: u8 = 0,
    bullet: Bullet = .none,

    fn height(self: Layout) f32 {
        return self.top_gap + @as(f32, @floatFromInt(self.rows)) * self.row_h;
    }
};

fn bolder(f: Font) Font {
    return .{ .size = f.size, .face = switch (f.face) {
        .sans, .sans_medium => .sans_semibold,
        .mono, .mono_medium => .mono_semibold,
        else => f.face,
    } };
}

fn mediumOf(f: Font) Font {
    return .{ .size = f.size, .face = switch (f.face) {
        .sans => .sans_medium,
        .mono => .mono_medium,
        else => f.face,
    } };
}

pub const MarkdownView = struct {
    gpa: std.mem.Allocator,
    glyphs: std.ArrayList(Glyph) = .empty,
    spans: lexer.Spans = .{},
    /// Per-line heights with markers hidden; < 0 means not measured yet.
    heights: std.ArrayList(f32) = .empty,
    seen_serial: u64 = 0,
    width: f32 = 0,
    scroll: f32 = 0,
    content_h: f32 = 0,
    follow: bool = false,
    caret: Rect = .{},
    salt: usize,
    /// The app's text engine, kept from the last draw so keyboard-driven
    /// layout (↑/↓ across wrapped rows) can measure text.
    text: ?*gfx_text.TextEngine = null,

    pub fn init(gpa: std.mem.Allocator, salt: usize) MarkdownView {
        return .{ .gpa = gpa, .salt = salt };
    }

    pub fn deinit(self: *MarkdownView) void {
        self.glyphs.deinit(self.gpa);
        self.heights.deinit(self.gpa);
    }

    // ── height cache ────────────────────────────────────────────────────
    fn resetHeights(self: *MarkdownView, doc: *const Document) void {
        self.heights.resize(self.gpa, doc.lineCount()) catch return;
        @memset(self.heights.items, -1);
        self.seen_serial = doc.change_serial;
    }

    fn syncHeights(self: *MarkdownView, doc: *const Document) void {
        if (self.heights.items.len == 0 or self.seen_serial > doc.change_serial) {
            self.resetHeights(doc);
            return;
        }
        while (self.seen_serial < doc.change_serial) : (self.seen_serial += 1) {
            const ch = doc.changeAt(self.seen_serial) orelse {
                self.resetHeights(doc);
                return;
            };
            const first: usize = ch.first;
            if (first + ch.old_count > self.heights.items.len) {
                self.resetHeights(doc);
                return;
            }
            var fresh: [64]f32 = undefined;
            if (ch.new_count <= fresh.len) {
                @memset(fresh[0..ch.new_count], -1);
                self.heights.replaceRange(self.gpa, first, ch.old_count, fresh[0..ch.new_count]) catch {
                    self.resetHeights(doc);
                    return;
                };
            } else {
                self.heights.replaceRange(self.gpa, first, ch.old_count, &.{}) catch {
                    self.resetHeights(doc);
                    return;
                };
                var k: usize = 0;
                while (k < ch.new_count) : (k += 1) self.heights.insert(self.gpa, first + k, -1) catch {
                    self.resetHeights(doc);
                    return;
                };
            }
        }
        if (self.heights.items.len != doc.lineCount()) self.resetHeights(doc);
    }

    /// Height of line `i`; the revealed (caret) line is measured live.
    fn lineHeight(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize, reveal: ?usize) f32 {
        if (reveal == i) return self.layoutLine(text, doc, i, true).height();
        if (self.heights.items[i] < 0) self.heights.items[i] = self.layoutLine(text, doc, i, false).height();
        return self.heights.items[i];
    }

    // ── layout ──────────────────────────────────────────────────────────
    /// Lays out line `i` into `self.glyphs` (cleared first) and returns the
    /// block's metrics. With `reveal`, syntax markers are shown.
    fn layoutLine(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize, reveal: bool) Layout {
        self.glyphs.clearRetainingCapacity();
        const line = doc.lineText(i);
        const blk = markdown.blockOf(doc.lineState(i), line);
        doc.lexInto(i, &self.spans);

        var lay: Layout = .{ .kind = blk.kind };
        var base = prose_font;
        var base_color = theme.text;
        var hide_list = false;
        var struck = false;
        switch (blk.kind) {
            .heading => {
                const lv: usize = @intCast(@max(1, @min(6, blk.level)) - 1);
                base = heading_fonts[lv];
                lay.row_h = heading_h[lv];
                lay.top_gap = heading_gap[lv];
            },
            .paragraph => {},
            .list => {
                lay.x0 = @as(f32, @floatFromInt(blk.indent)) * indent_px + list_text_indent;
                if (blk.task != .none) {
                    // The box stands in for "- [ ] "; on the revealed line
                    // the raw marker is the thing to edit, so no box there.
                    if (!reveal) lay.bullet = if (blk.task == .done) .done else .todo;
                    hide_list = true;
                    struck = blk.task == .done;
                } else if (!blk.ordered) {
                    if (!reveal) lay.bullet = .dot;
                    hide_list = true;
                } else {
                    lay.x0 -= list_text_indent - 4;
                }
            },
            .quote => {
                lay.quote_depth = blk.level;
                lay.x0 = @as(f32, @floatFromInt(blk.level)) * quote_indent;
                base_color = theme.text_2;
            },
            .code => {
                base = code_font;
                base_color = theme.scopeColor(.code);
                lay.row_h = code_h;
                lay.code_bg = true;
            },
            .fence_open, .fence_close => {
                lay.code_bg = true;
                if (!reveal) {
                    lay.row_h = fence_edge_h;
                    return lay;
                }
                base = code_font;
                base_color = theme.text_3;
                lay.row_h = code_h;
            },
            .front_matter => {
                base = meta_font;
                base_color = theme.text_3;
                lay.row_h = meta_h;
                lay.code_bg = true;
            },
            .hr => {
                if (!reveal) {
                    lay.row_h = hr_h;
                    lay.hr = true;
                    return lay;
                }
                base = code_font;
                base_color = theme.text_3;
                lay.row_h = code_h;
            },
            .table_sep => {
                base = code_font;
                base_color = theme.text_3;
                lay.row_h = code_h;
            },
            .html => {
                base = meta_font;
                base_color = theme.text_3;
                lay.row_h = meta_h;
            },
            .blank => {
                lay.row_h = blank_h;
                return lay;
            },
        }
        if (struck) base_color = theme.text_3;

        const max_w = @max(60, self.width - lay.x0);
        var cur: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = line };
        var x: f32 = 0;
        var row: u16 = 0;
        var row_start: usize = 0;
        var last_space: ?usize = null;
        var col: usize = 0;
        while (true) {
            const at = it.index;
            const cp = it.next() orelse break;
            const scope = self.spans.scopeAt(&cur, at);
            if (!reveal) {
                if (scope == .marker or scope == .quote or (scope == .list and hide_list)) continue;
            }
            var font = base;
            var color = base_color;
            var g: Glyph = .{ .off = @intCast(at), .end = @intCast(it.index), .x = 0, .w = 0, .row = 0, .font = base, .color = base_color, .cp = cp, .strike = struck };
            switch (scope) {
                .strong => font = bolder(base),
                .emphasis => font = mediumOf(base),
                .strike => {
                    g.strike = true;
                    color = theme.text_3;
                },
                .code => if (blk.kind != .code and blk.kind != .fence_open and blk.kind != .fence_close) {
                    font = .{ .face = .mono, .size = @max(11, base.size - 2) };
                    color = theme.scopeColor(.code);
                    g.code_bg = true;
                },
                .link => {
                    color = theme.scopeColor(.link);
                    g.underline = true;
                },
                .marker, .quote, .punct => color = theme.text_3,
                .list => color = theme.accent,
                .property => color = if (blk.kind == .front_matter) theme.text_2 else theme.scopeColor(.property),
                .string => if (blk.kind == .front_matter) {
                    color = theme.text_3;
                },
                .comment => color = theme.text_3,
                else => {},
            }
            g.font = font;
            g.color = color;
            if (cp == '\t') {
                const n = tab_width - (col % tab_width);
                g.w = text.advance(font, ' ') * @as(f32, @floatFromInt(n));
                col += n;
            } else {
                g.w = text.advance(font, cp);
                col += 1;
            }
            // Wrap: move the current word down when it does not fit.
            if (x + g.w > max_w and self.glyphs.items.len > row_start) {
                if (last_space) |ls| {
                    if (ls + 1 < self.glyphs.items.len and ls >= row_start) {
                        const shift = self.glyphs.items[ls + 1].x;
                        for (self.glyphs.items[ls + 1 ..]) |*m| {
                            m.x -= shift;
                            m.row += 1;
                        }
                        x -= shift;
                        row += 1;
                        row_start = ls + 1;
                    } else {
                        row += 1;
                        x = 0;
                        row_start = self.glyphs.items.len;
                    }
                } else {
                    row += 1;
                    x = 0;
                    row_start = self.glyphs.items.len;
                }
                last_space = null;
            }
            g.x = x;
            g.row = row;
            self.glyphs.append(self.gpa, g) catch break;
            if (cp == ' ') last_space = self.glyphs.items.len - 1;
            x += g.w;
        }
        lay.rows = row + 1;
        return lay;
    }

    /// Caret position (row, x) for byte `rel` within the laid-out line.
    fn caretIn(self: *const MarkdownView, rel: usize) struct { row: u16, x: f32 } {
        for (self.glyphs.items) |g| {
            if (g.off >= rel) return .{ .row = g.row, .x = g.x };
        }
        if (self.glyphs.items.len > 0) {
            const last = self.glyphs.items[self.glyphs.items.len - 1];
            return .{ .row = last.row, .x = last.x + last.w };
        }
        return .{ .row = 0, .x = 0 };
    }

    /// Byte (within the line) nearest to `x` on `row` of the laid-out line.
    fn offsetInRow(self: *const MarkdownView, line_len: usize, row: u16, x: f32) usize {
        var last: ?Glyph = null;
        for (self.glyphs.items) |g| {
            if (g.row != row) continue;
            if (x < g.x + g.w / 2) return g.off;
            last = g;
        }
        if (last) |g| return g.end;
        // An empty row: the start of the line's content, or its end.
        for (self.glyphs.items) |g| {
            if (g.row > row) return g.off;
        }
        return line_len;
    }

    // ── input ───────────────────────────────────────────────────────────
    /// ↑/↓ across wrapped rows; falls back to source lines before the first draw.
    fn moveVertical(self: *MarkdownView, ed: *TextEditor, up: bool, extend: bool) void {
        const doc = &ed.doc;
        const e = &doc.editor;
        const text = self.text orelse {
            _ = doc.apply(if (up) (if (extend) .select_up else .move_up) else (if (extend) .select_down else .move_down));
            return;
        };
        const i = doc.lineOf(e.cursor);
        const lay = self.layoutLine(text, doc, i, true);
        const pos = self.caretIn(e.cursor - doc.lineStartOf(i));
        var target_line = i;
        var target_row: u16 = 0;
        if (up) {
            if (pos.row > 0) {
                target_row = pos.row - 1;
            } else if (i > 0) {
                target_line = i - 1;
                const prev = self.layoutLine(text, doc, target_line, false);
                target_row = prev.rows - 1;
            } else return;
        } else {
            if (pos.row + 1 < lay.rows) {
                target_row = pos.row + 1;
            } else if (i + 1 < doc.lineCount()) {
                target_line = i + 1;
                _ = self.layoutLine(text, doc, target_line, false);
                target_row = 0;
            } else return;
        }
        if (target_line == i) _ = self.layoutLine(text, doc, i, true);
        const off = self.offsetInRow(doc.lineText(target_line).len, target_row, pos.x);
        e.setCursor(doc.lineStartOf(target_line) + off, extend);
    }

    pub fn onEdit(self: *MarkdownView, ed: *TextEditor, cmd: EditCommand) void {
        switch (cmd) {
            .move_up => self.moveVertical(ed, true, false),
            .move_down => self.moveVertical(ed, false, false),
            .select_up => self.moveVertical(ed, true, true),
            .select_down => self.moveVertical(ed, false, true),
            .scroll_to_top => {
                self.scroll = 0;
                return;
            },
            .scroll_to_bottom => {
                self.scroll = self.content_h;
                return;
            },
            .page_up, .page_down => {
                // A page in visual rows is not a fixed number of lines; the
                // caret jumps a screen's worth of source lines and the view follows.
                ed.onEdit(cmd);
            },
            else => ed.onEdit(cmd),
        }
        self.follow = true;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *MarkdownView, ui: *Ui, ed: *TextEditor, body: Rect, focused: bool) void {
        const dl = ui.dl;
        const scale = dl.scale;
        const text = ui.text;
        self.text = text;
        const doc = &ed.doc;
        const e = &doc.editor;
        const n = doc.lineCount();

        const cx0 = body.x + side_pad;
        const content_w = @max(60, body.w - 2 * side_pad);
        if (self.width != content_w) {
            self.width = content_w;
            self.heights.clearRetainingCapacity();
        }
        self.syncHeights(doc);
        // The caret's line as the last frame drew it: that layout is what
        // the mouse is pointing at, so hit testing uses it. The line the
        // caret ends up on is taken again below, after the mouse moved it.
        const line_before = doc.lineOf(e.cursor);
        const reveal_before: ?usize = if (focused) line_before else null;

        // Heights: total, plus where the caret line sits.
        var total: f32 = pad_top;
        var caret_top: f32 = pad_top;
        var caret_h: f32 = prose_h;
        {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const h = self.lineHeight(text, doc, i, reveal_before);
                if (i == line_before) {
                    caret_top = total;
                    caret_h = h;
                }
                total += h;
            }
        }
        self.content_h = total + pad_bottom;
        const max_scroll = @max(0, self.content_h - body.h);

        self.scroll -= ui.takeScroll(body);
        const vbar = Ui.id("markdown_view.vbar", self.salt);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, body, self.scroll, self.content_h)) |s| self.scroll = s;

        // Mouse.
        const d = ui.drag(Ui.id("markdown_view", self.salt), body);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (d.started or d.dragging) {
            const hit = self.hitTest(text, doc, body, cx0, reveal_before, ui.mx, ui.my);
            const off = hit.off;
            if (d.started and ui.click_count == 1 and !ed.read_only) {
                // A click on a task box flips it and leaves the caret alone.
                if (taskBox(cx0, hit.top, hit.lay)) |box| if (box.inset(-4, -4).contains(ui.mx, ui.my)) {
                    toggleTask(doc, hit.line);
                    return self.drawAfterEdit(ui, ed, body, focused);
                };
            }
            if (d.started) {
                if (ui.click_count >= 3) {
                    doc.selectLine(doc.lineOf(off));
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

        if (self.follow) {
            self.follow = false;
            if (caret_top < self.scroll + 4) self.scroll = @max(0, caret_top - 8);
            if (caret_top + caret_h > self.scroll + body.h) self.scroll = caret_top + caret_h - body.h + 8;
        }
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);

        // Where the caret is now: a click above its old line moved it up,
        // and drawing with the old line would index before that line's start.
        const caret_line = doc.lineOf(e.cursor);
        const reveal: ?usize = if (focused) caret_line else null;

        dl.pushClip(body);
        defer dl.popClip();
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const sel = e.selection();

        var y = body.y + pad_top - self.scroll;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = self.lineHeight(text, doc, i, reveal);
            if (y > body.bottom()) break;
            if (y + h >= body.y) {
                const is_caret_line = reveal == i;
                const lay = self.layoutLine(text, doc, i, is_caret_line);
                const ls = doc.lineStartOf(i);

                // Backgrounds and block ornaments.
                if (lay.code_bg) dl.rect(.{ .x = cx0 - 10, .y = y, .w = content_w + 20, .h = h }, theme.bg_inset);
                if (lay.hr) dl.rect(.{ .x = cx0, .y = y + hr_h / 2, .w = content_w, .h = 1 }, theme.line_strong);
                var depth: usize = 0;
                while (depth < lay.quote_depth) : (depth += 1) {
                    dl.rect(.{ .x = cx0 + @as(f32, @floatFromInt(depth)) * quote_indent, .y = y + lay.top_gap, .w = 3, .h = h - lay.top_gap }, theme.line_strong);
                }
                const first_row_cy = y + lay.top_gap + lay.row_h / 2;
                switch (lay.bullet) {
                    .none => {},
                    .dot => dl.circle(cx0 + lay.x0 - 13, first_row_cy, 2.5, theme.text_2),
                    .todo, .done => {
                        const box = taskBox(cx0, y, lay).?;
                        const over = ui.mouseIn(box.inset(-4, -4));
                        if (over) ui.cursor = .pointer;
                        if (lay.bullet == .todo) {
                            dl.border(box, 3, 1.2, if (over) theme.text_2 else theme.text_3);
                        } else {
                            dl.rrect(box, 3, if (over) theme.accent.alpha(0.85) else theme.accent);
                            // A small tick: two strokes.
                            dl.rect(.{ .x = box.x + 3, .y = box.y + 6.5, .w = 3, .h = 2 }, theme.on_accent);
                            dl.rect(.{ .x = box.x + 5, .y = box.y + 4, .w = 5.5, .h = 2 }, theme.on_accent);
                        }
                    },
                }

                // Glyphs.
                for (self.glyphs.items) |g| {
                    const gx = cx0 + lay.x0 + g.x;
                    const row_top = y + lay.top_gap + @as(f32, @floatFromInt(g.row)) * lay.row_h;
                    if (row_top > body.bottom() or row_top + lay.row_h < body.y) continue;
                    if (g.code_bg) dl.rect(.{ .x = gx, .y = row_top + 3, .w = g.w, .h = lay.row_h - 6 }, theme.bg_inset);
                    if (sel) |s| if (ls + g.off >= s[0] and ls + g.off < s[1]) {
                        dl.rect(.{ .x = gx, .y = row_top + 2, .w = g.w, .h = lay.row_h - 4 }, theme.selection());
                    };
                    if (g.cp != ' ' and g.cp != '\t') {
                        const baseline_px = @round(text.baselineForCenter(g.font, row_top + lay.row_h / 2) * scale);
                        _ = dl.glyph(g.font, g.cp, @round(gx * scale), baseline_px, g.color, clip);
                    }
                    if (g.underline) dl.rect(.{ .x = gx, .y = row_top + lay.row_h - 5, .w = g.w, .h = 1 }, g.color.alpha(0.6));
                    if (g.strike) dl.rect(.{ .x = gx, .y = row_top + lay.row_h / 2, .w = g.w, .h = 1 }, g.color);
                }

                // Caret and IME text.
                if (i == caret_line) {
                    const pos = self.caretIn(e.cursor - ls);
                    var cx = cx0 + lay.x0 + pos.x;
                    const row_top = y + lay.top_gap + @as(f32, @floatFromInt(pos.row)) * lay.row_h;
                    if (e.marked.items.len > 0) {
                        const w = dl.textCentered(prose_font, cx, row_top + lay.row_h / 2, e.marked.items, theme.text);
                        dl.rect(.{ .x = cx, .y = row_top + lay.row_h - 4, .w = w, .h = 1 }, theme.text_2);
                        cx += w;
                    }
                    self.caret = .{ .x = cx, .y = row_top + 3, .w = 2, .h = lay.row_h - 6 };
                    if (focused and (ed.blink_on or ui.down)) dl.rect(self.caret, if (ed.read_only) theme.text_3 else theme.accent);
                }
            }
            y += h;
        }

        sidebar.drawScrollbarAxis(ui, vbar, .vertical, body, self.scroll, self.content_h);
    }

    const Hit = struct {
        /// Absolute byte offset nearest the point.
        off: usize,
        line: usize,
        /// Top of the line's block, in points.
        top: f32,
        lay: Layout,
    };

    fn hitTest(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, body: Rect, cx0: f32, reveal: ?usize, mx: f32, my: f32) Hit {
        const n = doc.lineCount();
        var y = body.y + pad_top - self.scroll;
        var i: usize = 0;
        var h: f32 = 0;
        while (i < n) : (i += 1) {
            h = self.lineHeight(text, doc, i, reveal);
            if (my < y + h or i + 1 == n) break;
            y += h;
        }
        if (i >= n) i = n - 1;
        const lay = self.layoutLine(text, doc, i, reveal == i);
        const rel_y = my - y - lay.top_gap;
        const row: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(rel_y / lay.row_h))), 0, @as(i64, lay.rows) - 1));
        const off = self.offsetInRow(doc.lineText(i).len, row, mx - cx0 - lay.x0);
        return .{ .off = doc.lineStartOf(i) + off, .line = i, .top = y, .lay = lay };
    }

    /// The checkbox drawn for a task line whose block starts at `top`.
    fn taskBox(cx0: f32, top: f32, lay: Layout) ?Rect {
        if (lay.bullet != .todo and lay.bullet != .done) return null;
        const cy = top + lay.top_gap + lay.row_h / 2;
        return .{ .x = cx0 + lay.x0 - 19, .y = cy - 6.5, .w = 13, .h = 13 };
    }

    /// "[ ]" ⇄ "[x]" on line `i`, keeping the caret and selection where they
    /// are (the edit is one byte for one byte, so offsets do not move).
    fn toggleTask(doc: *Document, i: usize) void {
        const mark = markdown.taskMark(doc.lineState(i), doc.lineText(i)) orelse return;
        const e = &doc.editor;
        const cursor = e.cursor;
        const anchor = e.anchor;
        const at = doc.lineStartOf(i) + mark.at;
        doc.replace(at, at + 1, if (mark.done) " " else "x");
        e.cursor = cursor;
        e.anchor = anchor;
    }

    /// Redraws once after a click changed the document, so the frame shows
    /// the new state. The click is spent: the press edge is cleared and the
    /// view lets go of the mouse, so holding the button down does not turn
    /// into a drag selection (and the second draw cannot toggle again).
    fn drawAfterEdit(self: *MarkdownView, ui: *Ui, ed: *TextEditor, body: Rect, focused: bool) void {
        ui.pressed = false;
        ui.active = 0;
        self.draw(ui, ed, body, focused);
    }
};

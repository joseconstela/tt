//! Markdown's visual mode: the document rendered in place — headings in
//! their sizes, bullets, quote bars, code blocks, bold and links, tables in
//! cells — while it stays the editable source. The Markdown lexer's spans
//! are the decorations: `.marker` spans are hidden except on the caret's
//! line, where the raw syntax shows so it can be edited (the Obsidian "live
//! preview" model). Every line is laid out from its spans, wrapped to the
//! column width, and its height cached; an edit patches the cache through
//! the document's change ring.
//!
//! Tables are the one place a line's layout depends on its neighbours: the
//! rows of a table share column widths, measured from every cell once per
//! document version and kept in a small cache keyed by the alignment row.
//! Inline HTML is rendered through the same spans: tags are markers (hidden,
//! styling the text they wrap), entities are single glyphs, "<br>" breaks
//! the line, and a line that is nothing but tags keeps a sliver of height.
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
/// A line that renders to nothing (a lone HTML tag, a comment) keeps a sliver.
const html_edge_h: f32 = 6;
const default_pad_top: f32 = 16;
const default_pad_bottom: f32 = 48;
const default_side_pad: f32 = theme.block_pad_x + 6;
const quote_indent: f32 = 18;
const list_text_indent: f32 = 22;
const indent_px: f32 = 7;
const tab_width: usize = 4;

// Tables.
const table_font = Font.sans(14);
const table_head_font = Font.medium(14);
const table_row_h: f32 = 22;
const cell_pad_x: f32 = 10;
const cell_pad_y: f32 = 4;
const min_col_w: f32 = 36;
const max_cols = markdown.max_cols;

const Bullet = enum { none, dot, todo, done };
const TableRole = enum { none, header, sep, body };

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

/// One table's geometry: which lines it spans and the column widths its
/// rows share. Relative to the content's left edge.
const Table = struct {
    /// The alignment row that opens the table, and one past its last row.
    sep: usize,
    end: usize,
    /// The paragraph line right above the alignment row, when there is one.
    header: ?usize,
    cols: u8,
    x: f32,
    /// Column widths, padding included.
    widths: [max_cols]f32,
    aligns: [max_cols]markdown.Align,

    fn width(self: *const Table) f32 {
        var w: f32 = 0;
        for (self.widths[0..self.cols]) |cw| w += cw;
        return w;
    }
};

const Layout = struct {
    kind: markdown.BlockKind = .paragraph,
    row_h: f32 = prose_h,
    top_gap: f32 = 0,
    bottom_gap: f32 = 0,
    rows: u16 = 1,
    /// Text origin, relative to the content's left edge.
    x0: f32 = 0,
    code_bg: bool = false,
    hr: bool = false,
    quote_depth: u8 = 0,
    bullet: Bullet = .none,
    table_role: TableRole = .none,
    table: ?Table = null,

    fn height(self: Layout) f32 {
        return self.top_gap + @as(f32, @floatFromInt(self.rows)) * self.row_h + self.bottom_gap;
    }
};

/// How a run of text is laid out: its base font and colour, and which
/// decorations apply.
const Run = struct {
    base: Font,
    color: Color,
    reveal: bool,
    struck: bool = false,
    hide_list: bool = false,
    /// Inside a fence or indented code: backticks are not code spans there.
    in_code: bool = false,
    front_matter: bool = false,
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

fn kindOf(doc: *const Document, i: usize) markdown.BlockKind {
    return markdown.blockOf(doc.lineState(i), doc.lineText(i)).kind;
}

/// A paragraph right above an alignment row is that table's header.
fn isHeader(doc: *const Document, i: usize) bool {
    return i + 1 < doc.lineCount() and kindOf(doc, i + 1) == .table_sep;
}

fn inTable(doc: *const Document, i: usize) bool {
    return switch (kindOf(doc, i)) {
        .table_row, .table_sep => true,
        .paragraph => isHeader(doc, i),
        else => false,
    };
}

pub const MarkdownView = struct {
    gpa: std.mem.Allocator,
    glyphs: std.ArrayList(Glyph) = .empty,
    spans: lexer.Spans = .{},
    /// Per-line heights with markers hidden; < 0 means not measured yet.
    heights: std.ArrayList(f32) = .empty,
    seen_serial: u64 = 0,
    /// Tables measured for the document version `tables_serial` at width
    /// `tables_width`; anything else starts the cache over.
    tables: std.ArrayList(Table) = .empty,
    tables_serial: u64 = 0,
    tables_width: f32 = 0,
    width: f32 = 0,
    scroll: f32 = 0,
    content_h: f32 = 0,
    follow: bool = false,
    caret: Rect = .{},
    salt: usize,
    /// Room around the prose: a Markdown file keeps the defaults, a
    /// notebook cell (sized to its text) wants less.
    pad_top: f32 = default_pad_top,
    pad_bottom: f32 = default_pad_bottom,
    side_pad: f32 = default_side_pad,
    /// The app's text engine, kept from the last draw so keyboard-driven
    /// layout (↑/↓ across wrapped rows) can measure text.
    text: ?*gfx_text.TextEngine = null,

    pub fn init(gpa: std.mem.Allocator, salt: usize) MarkdownView {
        return .{ .gpa = gpa, .salt = salt };
    }

    pub fn deinit(self: *MarkdownView) void {
        self.glyphs.deinit(self.gpa);
        self.heights.deinit(self.gpa);
        self.tables.deinit(self.gpa);
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
            if (self.heights.items.len == doc.lineCount()) self.invalidateAround(doc, first, ch.new_count);
        }
        if (self.heights.items.len != doc.lineCount()) self.resetHeights(doc);
    }

    /// Lines whose layout depends on the changed ones: the line above (it
    /// may have become a table's header, or stopped being one) and the rest
    /// of any table the change touches, since its rows share column widths.
    fn invalidateAround(self: *MarkdownView, doc: *const Document, first: usize, count: usize) void {
        const n = self.heights.items.len;
        if (first > 0) self.heights.items[first - 1] = -1;
        var lo = first;
        var hi = @min(n, first + count);
        while (lo > 0 and inTable(doc, lo - 1)) lo -= 1;
        while (hi < n and inTable(doc, hi)) hi += 1;
        if (lo < first) @memset(self.heights.items[lo..first], -1);
        if (hi > first + count) @memset(self.heights.items[@min(n, first + count)..hi], -1);
    }

    /// Height of line `i`; the revealed (caret) line is measured live.
    fn lineHeight(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize, reveal: ?usize) f32 {
        if (reveal == i) return self.layoutLine(text, doc, i, true).height();
        if (self.heights.items[i] < 0) self.heights.items[i] = self.layoutLine(text, doc, i, false).height();
        return self.heights.items[i];
    }

    // ── layout ──────────────────────────────────────────────────────────
    /// Lays out `line[from..to]` as glyphs appended to `self.glyphs`, x from
    /// 0 and rows from 0, wrapping at `max_w`. Uses `self.spans`, which must
    /// hold the line's spans. Returns the row count and the widest row.
    fn layoutRun(self: *MarkdownView, text: *gfx_text.TextEngine, line: []const u8, from: usize, to: usize, st: Run, max_w: f32) struct { rows: u16, width: f32 } {
        var cur: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = line[0..to], .index = from };
        var x: f32 = 0;
        var row: u16 = 0;
        var row_start: usize = self.glyphs.items.len;
        var last_space: ?usize = null;
        var col: usize = 0;
        var widest: f32 = 0;
        while (true) {
            const at = it.index;
            var cp = it.next() orelse break;
            var end = it.index;
            const scope = self.spans.scopeAt(&cur, at);
            if (!st.reveal) {
                if (scope == .marker or scope == .quote or scope == .comment or (scope == .list and st.hide_list)) {
                    // "<br>" is the one hidden thing that shows: as a line break.
                    if (scope == .marker and markdown.isBreakTag(line, at)) {
                        widest = @max(widest, x);
                        row += 1;
                        x = 0;
                        row_start = self.glyphs.items.len;
                        last_space = null;
                    }
                    continue;
                }
                // "&amp;" is one glyph.
                if (scope == .escape and cp == '&') {
                    if (markdown.entityAt(line[0..to], at)) |ent| {
                        cp = ent.cp;
                        end = at + ent.len;
                        it.index = end;
                    }
                }
            }
            var font = st.base;
            var color = st.color;
            var g: Glyph = .{ .off = @intCast(at), .end = @intCast(end), .x = 0, .w = 0, .row = 0, .font = st.base, .color = st.color, .cp = cp, .strike = st.struck };
            switch (scope) {
                .strong => font = bolder(st.base),
                .emphasis => font = mediumOf(st.base),
                .strike => {
                    g.strike = true;
                    color = theme.text_3;
                },
                .code => if (!st.in_code) {
                    font = .{ .face = .mono, .size = @max(11, st.base.size - 2) };
                    color = theme.scopeColor(.code);
                    g.code_bg = true;
                },
                .link => {
                    color = theme.scopeColor(.link);
                    g.underline = true;
                },
                .marker, .quote, .punct => color = theme.text_3,
                .list => color = theme.accent,
                .property => color = if (st.front_matter) theme.text_2 else theme.scopeColor(.property),
                .string => if (st.front_matter) {
                    color = theme.text_3;
                },
                .comment => color = theme.text_3,
                .escape => if (st.reveal) {
                    color = theme.scopeColor(.escape);
                },
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
            // Wrap: move the current word down when it does not fit. A
            // space hangs past the edge instead of opening an empty row.
            if (cp != ' ' and x + g.w > max_w and self.glyphs.items.len > row_start) {
                if (last_space) |ls| {
                    if (ls + 1 < self.glyphs.items.len and ls >= row_start) {
                        const shift = self.glyphs.items[ls + 1].x;
                        for (self.glyphs.items[ls + 1 ..]) |*m| {
                            m.x -= shift;
                            m.row += 1;
                        }
                        widest = @max(widest, shift);
                        x -= shift;
                        row += 1;
                        row_start = ls + 1;
                    } else {
                        widest = @max(widest, x);
                        row += 1;
                        x = 0;
                        row_start = self.glyphs.items.len;
                    }
                } else {
                    widest = @max(widest, x);
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
        return .{ .rows = row + 1, .width = @max(widest, x) };
    }

    /// Lays out line `i` into `self.glyphs` (cleared first) and returns the
    /// block's metrics. With `reveal`, syntax markers are shown.
    fn layoutLine(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize, reveal: bool) Layout {
        self.glyphs.clearRetainingCapacity();
        const line = doc.lineText(i);
        const blk = markdown.blockOf(doc.lineState(i), line);
        if (blk.kind == .table_row or blk.kind == .table_sep or (blk.kind == .paragraph and isHeader(doc, i))) {
            return self.layoutTableLine(text, doc, i, blk, reveal);
        }
        doc.lexInto(i, &self.spans);

        var lay: Layout = .{ .kind = blk.kind };
        var st: Run = .{ .base = prose_font, .color = theme.text, .reveal = reveal };
        switch (blk.kind) {
            .heading => {
                const lv: usize = @intCast(@max(1, @min(6, blk.level)) - 1);
                st.base = heading_fonts[lv];
                lay.row_h = heading_h[lv];
                lay.top_gap = heading_gap[lv];
            },
            .paragraph, .table_row => {},
            .list => {
                lay.x0 = @as(f32, @floatFromInt(blk.indent)) * indent_px + list_text_indent;
                if (blk.task != .none) {
                    // The box stands in for "- [ ] "; on the revealed line
                    // the raw marker is the thing to edit, so no box there.
                    if (!reveal) lay.bullet = if (blk.task == .done) .done else .todo;
                    st.hide_list = true;
                    st.struck = blk.task == .done;
                } else if (!blk.ordered) {
                    if (!reveal) lay.bullet = .dot;
                    st.hide_list = true;
                } else {
                    lay.x0 -= list_text_indent - 4;
                }
            },
            .quote => {
                lay.quote_depth = blk.level;
                lay.x0 = @as(f32, @floatFromInt(blk.level)) * quote_indent;
                st.color = theme.text_2;
            },
            .code => {
                st.base = code_font;
                st.color = theme.scopeColor(.code);
                st.in_code = true;
                lay.row_h = code_h;
                lay.code_bg = true;
            },
            .fence_open, .fence_close => {
                lay.code_bg = true;
                if (!reveal) {
                    lay.row_h = fence_edge_h;
                    return lay;
                }
                st.base = code_font;
                st.color = theme.text_3;
                st.in_code = true;
                lay.row_h = code_h;
            },
            .front_matter => {
                st.base = meta_font;
                st.color = theme.text_3;
                st.front_matter = true;
                lay.row_h = meta_h;
                lay.code_bg = true;
            },
            .hr => {
                if (!reveal) {
                    lay.row_h = hr_h;
                    lay.hr = true;
                    return lay;
                }
                st.base = code_font;
                st.color = theme.text_3;
                lay.row_h = code_h;
            },
            .table_sep => {
                st.base = code_font;
                st.color = theme.text_3;
                lay.row_h = code_h;
            },
            .html => {
                // Tags hide, the text between them is prose; a line of
                // nothing but tags (or a comment) collapses to a sliver.
                lay.x0 = @as(f32, @floatFromInt(blk.indent)) * indent_px;
            },
            .blank => {
                lay.row_h = blank_h;
                return lay;
            },
        }
        if (st.struck) st.color = theme.text_3;

        const max_w = @max(60, self.width - lay.x0);
        const run = self.layoutRun(text, line, 0, line.len, st, max_w);
        lay.rows = run.rows;
        if (blk.kind == .html and !reveal and self.glyphs.items.len == 0) {
            lay.rows = 1;
            lay.row_h = html_edge_h;
        }
        return lay;
    }

    /// A table line: the header, the alignment row (a rule, or the raw
    /// text when revealed) or a body row, each cell laid out in its column.
    fn layoutTableLine(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize, blk: markdown.Block, reveal: bool) Layout {
        const t = self.tableFor(text, doc, i);
        const line = doc.lineText(i);
        doc.lexInto(i, &self.spans);
        self.glyphs.clearRetainingCapacity();
        var lay: Layout = .{ .kind = blk.kind, .x0 = t.x, .row_h = table_row_h, .table = t };
        lay.table_role = if (blk.kind == .table_sep) .sep else if (blk.kind == .paragraph) .header else .body;
        if (lay.table_role == .sep) {
            // Hidden, the alignment row is the rule under the header (drawn
            // by the header); revealed it is raw text, like a fence edge.
            if (!reveal) {
                lay.row_h = 0;
                return lay;
            }
            lay.row_h = code_h;
            const run = self.layoutRun(text, line, 0, line.len, .{ .base = code_font, .color = theme.text_3, .reveal = true }, @max(60, self.width - t.x));
            lay.rows = run.rows;
            return lay;
        }
        lay.top_gap = cell_pad_y;
        lay.bottom_gap = cell_pad_y;
        const st: Run = .{ .base = if (lay.table_role == .header) table_head_font else table_font, .color = theme.text, .reveal = reveal };
        var starts: [max_cols + 1]u32 = undefined;
        const count = markdown.tableCells(line, &self.spans, &starts);
        var rows: u16 = 1;
        var cell_x: f32 = 0;
        var c: usize = 0;
        while (c < count) : (c += 1) {
            const col: usize = @min(c, @as(usize, t.cols) - 1);
            var inner_w = @max(8, t.widths[col] - 2 * cell_pad_x);
            var base_x = cell_x + cell_pad_x;
            const hidden = self.cellText(line, &starts, c, count);
            var range = hidden;
            if (reveal) {
                // Every byte shows, with the syntax in the gutters: the
                // leading "| " sits in the left padding so the text lines
                // up with its column, and the run may reach the right rule.
                range = .{ starts[c], starts[c + 1] };
                var lead_w: f32 = 0;
                for (line[starts[c]..@max(starts[c], hidden[0])]) |b| {
                    lead_w += if (b == '\t') text.advance(st.base, ' ') * @as(f32, @floatFromInt(tab_width)) else text.advance(st.base, b);
                }
                lead_w = @min(lead_w, cell_pad_x - 2);
                base_x -= lead_w;
                inner_w = @max(8, t.widths[col] - 2 - (cell_pad_x - lead_w));
            }
            const g0 = self.glyphs.items.len;
            const run = self.layoutRun(text, line, range[0], range[1], st, inner_w);
            rows = @max(rows, run.rows);
            self.placeCell(g0, inner_w, t.aligns[col], base_x);
            cell_x += t.widths[col];
        }
        lay.rows = rows;
        return lay;
    }

    /// Cell `c`'s text without its pipes and the blanks around them.
    fn cellText(self: *const MarkdownView, line: []const u8, starts: *const [max_cols + 1]u32, c: usize, count: usize) [2]usize {
        var from: usize = starts[c];
        var to: usize = starts[c + 1];
        while (from < to and (line[from] == ' ' or line[from] == '\t')) from += 1;
        if (from < to and line[from] == '|') from += 1;
        while (from < to and (line[from] == ' ' or line[from] == '\t')) from += 1;
        while (to > from and (line[to - 1] == ' ' or line[to - 1] == '\t')) to -= 1;
        if (c + 1 == count and to > from and line[to - 1] == '|') {
            var cur: usize = 0;
            if (self.spans.scopeAt(&cur, to - 1) == .punct) {
                to -= 1;
                while (to > from and (line[to - 1] == ' ' or line[to - 1] == '\t')) to -= 1;
            }
        }
        return .{ from, to };
    }

    /// Moves the glyphs from `g0` on into their cell: `base_x` in, plus the
    /// alignment's share of the room left on each row.
    fn placeCell(self: *MarkdownView, g0: usize, inner_w: f32, al: markdown.Align, base_x: f32) void {
        const items = self.glyphs.items;
        var k = g0;
        while (k < items.len) {
            const r = items[k].row;
            var j = k;
            while (j < items.len and items[j].row == r) j += 1;
            // A row's width ends at its last visible glyph.
            var last = j;
            while (last > k and items[last - 1].cp == ' ') last -= 1;
            const right: f32 = if (last > k) items[last - 1].x + items[last - 1].w else 0;
            const shift: f32 = switch (al) {
                .left => 0,
                .center => @max(0, (inner_w - right) / 2),
                .right => @max(0, inner_w - right),
            };
            for (items[k..j]) |*g| g.x += base_x + shift;
            k = j;
        }
    }

    /// The table line `i` belongs to, measured (column widths from every
    /// cell) or taken from the cache. Scratch: `self.spans` and `self.glyphs`.
    fn tableFor(self: *MarkdownView, text: *gfx_text.TextEngine, doc: *const Document, i: usize) Table {
        if (self.tables_serial != doc.change_serial or self.tables_width != self.width) {
            self.tables.clearRetainingCapacity();
            self.tables_serial = doc.change_serial;
            self.tables_width = self.width;
        }
        // The alignment row that opens the table: up from a row, down from
        // the header.
        const n = doc.lineCount();
        var sep = i;
        if (kindOf(doc, i) == .paragraph) {
            sep = i + 1;
        } else {
            while (sep > 0) : (sep -= 1) {
                const k = kindOf(doc, sep - 1);
                if (k != .table_row and k != .table_sep) break;
            }
        }
        for (self.tables.items) |t| if (t.sep == sep) return t;

        var t: Table = .{ .sep = sep, .end = sep + 1, .header = null, .cols = 0, .x = 0, .widths = [_]f32{0} ** max_cols, .aligns = [_]markdown.Align{.left} ** max_cols };
        if (sep > 0 and kindOf(doc, sep - 1) == .paragraph) t.header = sep - 1;
        while (t.end < n) : (t.end += 1) {
            const k = kindOf(doc, t.end);
            if (k != .table_row and k != .table_sep) break;
        }
        const sep_blk = markdown.blockOf(doc.lineState(sep), doc.lineText(sep));
        t.x = @as(f32, @floatFromInt(sep_blk.indent)) * indent_px;
        t.cols = @max(1, markdown.tableAligns(doc.lineText(sep), &t.aligns));

        // Natural widths: the widest cell of each column as it renders (the
        // caret's row, showing its syntax, wraps in its cell when wider).
        var nat = [_]f32{0} ** max_cols;
        var j = t.header orelse sep;
        while (j < t.end) : (j += 1) {
            const k = kindOf(doc, j);
            if (k == .table_sep) continue;
            const line = doc.lineText(j);
            doc.lexInto(j, &self.spans);
            var starts: [max_cols + 1]u32 = undefined;
            const count = markdown.tableCells(line, &self.spans, &starts);
            t.cols = @max(t.cols, count);
            const st: Run = .{ .base = if (t.header == j) table_head_font else table_font, .color = theme.text, .reveal = false };
            var c: usize = 0;
            while (c < count) : (c += 1) {
                self.glyphs.clearRetainingCapacity();
                const range = self.cellText(line, &starts, c, count);
                const run = self.layoutRun(text, line, range[0], range[1], st, 1e9);
                nat[c] = @max(nat[c], run.width);
            }
        }
        self.glyphs.clearRetainingCapacity();

        // Column widths: natural when the table fits, otherwise the narrow
        // columns keep theirs and the wide ones share what is left.
        const cols: usize = t.cols;
        const avail = @max(min_col_w * @as(f32, @floatFromInt(cols)), self.width - t.x);
        var want = [_]f32{0} ** max_cols;
        var want_sum: f32 = 0;
        for (0..cols) |c| {
            want[c] = @max(min_col_w, nat[c] + 2 * cell_pad_x);
            want_sum += want[c];
        }
        if (want_sum <= avail) {
            t.widths = want;
        } else {
            var remaining = avail;
            var left = cols;
            var done = [_]bool{false} ** max_cols;
            while (left > 0) : (left -= 1) {
                var best: usize = 0;
                var found = false;
                for (0..cols) |c| if (!done[c] and (!found or want[c] < want[best])) {
                    best = c;
                    found = true;
                };
                const share = remaining / @as(f32, @floatFromInt(left));
                t.widths[best] = @max(min_col_w, @min(want[best], share));
                remaining -= t.widths[best];
                done[best] = true;
            }
        }
        self.tables.append(self.gpa, t) catch {};
        return t;
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
    /// The height `draw` needs for the whole document at `width` (the
    /// body's width), the caret's line revealed when `focused`: what a
    /// notebook cell grows to. Keeps the height cache in step, so calling
    /// it before `draw` costs nothing extra.
    pub fn measure(self: *MarkdownView, text: *gfx_text.TextEngine, ed: *TextEditor, width: f32, focused: bool) f32 {
        const doc = &ed.doc;
        const content_w = @max(60, width - 2 * self.side_pad);
        if (self.width != content_w) {
            self.width = content_w;
            self.heights.clearRetainingCapacity();
        }
        self.syncHeights(doc);
        const reveal: ?usize = if (focused) doc.lineOf(doc.editor.cursor) else null;
        var total: f32 = self.pad_top;
        var i: usize = 0;
        const n = doc.lineCount();
        while (i < n) : (i += 1) total += self.lineHeight(text, doc, i, reveal);
        return total + self.pad_bottom;
    }

    pub fn draw(self: *MarkdownView, ui: *Ui, ed: *TextEditor, body: Rect, focused: bool) void {
        const dl = ui.dl;
        const scale = dl.scale;
        const text = ui.text;
        self.text = text;
        const doc = &ed.doc;
        const e = &doc.editor;
        const n = doc.lineCount();

        const cx0 = body.x + self.side_pad;
        const content_w = @max(60, body.w - 2 * self.side_pad);
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
        var total: f32 = self.pad_top;
        var caret_top: f32 = self.pad_top;
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
        self.content_h = total + self.pad_bottom;
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

        var y = body.y + self.pad_top - self.scroll;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = self.lineHeight(text, doc, i, reveal);
            if (y > body.bottom()) break;
            if (y + h >= body.y and h > 0) {
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
                if (lay.table) |t| self.drawTableRow(dl, t, lay.table_role, i, cx0, y, h);
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

    /// The grid around one table line: the header's fill and the rule under
    /// it, a rule under each body row, the column lines through all of them.
    fn drawTableRow(_: *MarkdownView, dl: *draw_mod.DrawList, t: Table, role: TableRole, i: usize, cx0: f32, y: f32, h: f32) void {
        const tx = cx0 + t.x;
        const tw = t.width();
        switch (role) {
            .header => {
                dl.rect(.{ .x = tx, .y = y, .w = tw, .h = h }, theme.bg_inset);
                dl.rect(.{ .x = tx, .y = y, .w = tw, .h = 1 }, theme.line);
                dl.rect(.{ .x = tx, .y = y + h - 1, .w = tw, .h = 1 }, theme.line_strong);
            },
            .sep => {
                // Only drawn revealed (hidden it has no height): the raw
                // alignment row on the code background, within the table.
                dl.rect(.{ .x = tx, .y = y, .w = tw, .h = h }, theme.bg_inset);
                dl.rect(.{ .x = tx, .y = y + h - 1, .w = tw, .h = 1 }, theme.line_strong);
            },
            .body => {
                if (t.header == null and i == t.sep + 1) dl.rect(.{ .x = tx, .y = y, .w = tw, .h = 1 }, theme.line);
                dl.rect(.{ .x = tx, .y = y + h - 1, .w = tw, .h = 1 }, theme.line);
            },
            .none => return,
        }
        var x = tx;
        for (t.widths[0..t.cols], 0..) |w, c| {
            dl.rect(.{ .x = x, .y = y, .w = 1, .h = h }, theme.line);
            x += w;
            if (c + 1 == t.cols) dl.rect(.{ .x = x - 1, .y = y, .w = 1, .h = h }, theme.line);
        }
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
        var y = body.y + self.pad_top - self.scroll;
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
        const row: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(rel_y / @max(1, lay.row_h)))), 0, @as(i64, lay.rows) - 1));
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

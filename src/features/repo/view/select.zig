//! Text a view draws that can be selected with the mouse and copied: the
//! commit details (a hash, a subject, a message, who and when). The view
//! draws each piece through `text` or `wrapped` instead of the draw list,
//! in reading order, between `begin` and `end`; this file remembers where
//! each piece landed (a *run*), paints the selection behind the pieces it
//! covers, and turns presses and drags into a selection: a drag selects
//! from where it started to where it is, a double click a word, a triple
//! click a whole run. A secondary click on a selection asks for the edit
//! menu (Copy).
//!
//! What is selected is kept as text of its own (`selected`), rebuilt each
//! frame, so copying never reads a view's strings after they have gone.
//! Pieces on one row are joined with a space, pieces on different rows
//! with a line break, and the lines a paragraph was wrapped into the way
//! the paragraph had them (a space where it was only wrapped).
//!
//! A selection belongs to what was on show when it was made: `begin`
//! takes a key for the content and drops the selection when it changes.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const wrap = @import("../../../ui/wrap.zig");
const gfx_text = @import("../../../gfx/text.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

/// What goes between a run and the one before it when both are copied.
const Sep = enum {
    /// By where they sit: a space on the same row, a line break otherwise.
    auto,
    space,
    line,
    /// A blank line: the next paragraph of a message.
    paragraph,
};

const Run = struct {
    text: []const u8,
    font: Font,
    x: f32,
    /// The vertical centre of its row, and the row's height.
    cy: f32,
    h: f32,
    /// How much of it is on show (it is clipped beyond).
    w: f32,
    sep: Sep = .auto,
};

/// A place in the text: a run and a byte offset into it.
const Pos = struct {
    run: usize = 0,
    off: usize = 0,

    fn before(a: Pos, b: Pos) bool {
        return a.run < b.run or (a.run == b.run and a.off < b.off);
    }
};

pub const Selectable = struct {
    gpa: std.mem.Allocator,
    /// The widget id of the area (one per view that has selectable text).
    wid: u64,
    /// This frame's runs, their text copied here so it outlives the view's own.
    arena: std.heap.ArenaAllocator,
    runs: std.ArrayList(Run) = .empty,
    anchor: Pos = .{},
    head: Pos = .{},
    /// Started by a single press, so a drag grows it (a double or triple
    /// click picked a word or a run, which a drag leaves alone).
    by_drag: bool = false,
    key: u64 = 0,
    copied: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, wid: u64) Selectable {
        return .{ .gpa = gpa, .wid = wid, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Selectable) void {
        self.runs.deinit(self.gpa);
        self.copied.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn clear(self: *Selectable) void {
        self.anchor = .{};
        self.head = .{};
        self.copied.clearRetainingCapacity();
    }

    /// Starts a frame. `key` stands for the content on show: a different
    /// one from last frame's drops the selection, whose places meant the
    /// old content.
    pub fn begin(self: *Selectable, key: u64) void {
        self.runs.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        if (key != self.key) {
            self.key = key;
            self.clear();
        }
    }

    /// The selection in reading order; null when nothing is selected.
    fn span(self: *const Selectable) ?[2]Pos {
        if (self.anchor.run == self.head.run and self.anchor.off == self.head.off) return null;
        return if (self.anchor.before(self.head)) .{ self.anchor, self.head } else .{ self.head, self.anchor };
    }

    pub fn hasSelection(self: *const Selectable) bool {
        return self.copied.items.len > 0;
    }

    /// The selected text, as it would be pasted.
    pub fn selected(self: *const Selectable) []const u8 {
        return self.copied.items;
    }

    /// Draws `str` on one row from `x`, centred on `cy`, clipped to
    /// `max_w` (no ellipsis: what is selected is what is there), with the
    /// selection behind it. Returns the width drawn.
    pub fn text(self: *Selectable, ui: *Ui, font: Font, x: f32, cy: f32, str: []const u8, max_w: f32, color: Color) f32 {
        return self.add(ui, font, x, cy, str, max_w, color, .auto);
    }

    fn add(self: *Selectable, ui: *Ui, font: Font, x: f32, cy: f32, str: []const u8, max_w: f32, color: Color, sep: Sep) f32 {
        const dl = ui.dl;
        const kept = self.arena.allocator().dupe(u8, str) catch return 0;
        const index = self.runs.items.len;
        const h = font.size + 7;
        const w = @min(ui.text.measure(font, kept), @max(0, max_w));
        if (self.span()) |sp| {
            if (index >= sp[0].run and index <= sp[1].run) {
                const from = if (index == sp[0].run) @min(sp[0].off, kept.len) else 0;
                const to = if (index == sp[1].run) @min(sp[1].off, kept.len) else kept.len;
                const x0 = x + @min(w, ui.text.measure(font, kept[0..from]));
                // A run selected to its end takes a little more, so a break shows as selected.
                const x1 = x + @min(w, ui.text.measure(font, kept[0..to])) + (if (to == kept.len and index < sp[1].run) @as(f32, 4) else 0);
                if (x1 > x0) dl.rect(.{ .x = x0, .y = cy - h / 2, .w = x1 - x0, .h = h }, theme.selection());
            }
        }
        dl.pushClip(.{ .x = x, .y = cy - h / 2 - 2, .w = @max(0, max_w), .h = h + 4 });
        _ = dl.textCentered(font, x, cy, kept, color);
        dl.popClip();
        self.runs.append(self.gpa, .{ .text = kept, .font = font, .x = x, .cy = cy, .h = h, .w = w, .sep = sep }) catch {};
        return w;
    }

    /// Draws `str` wrapped to `max_w` from (x, y), `lh` per line; with
    /// `paragraphs` its own line breaks are kept. Returns the y below the
    /// last line.
    pub fn wrapped(self: *Selectable, ui: *Ui, font: Font, str: []const u8, x: f32, y: f32, max_w: f32, lh: f32, color: Color, paragraphs: bool) f32 {
        var lines: Lines = .{ .owner = self, .ui = ui, .font = font, .x = x, .y = y, .max_w = max_w, .lh = lh, .color = color, .src = str };
        if (paragraphs) {
            _ = wrap.wrapParagraphs(ui, font, str, max_w, &lines);
        } else {
            _ = wrap.wrapLines(ui, font, str, max_w, &lines);
        }
        return lines.y;
    }

    const Lines = struct {
        owner: *Selectable,
        ui: *Ui,
        font: Font,
        x: f32,
        y: f32,
        max_w: f32,
        lh: f32,
        color: Color,
        /// The text being wrapped: each line is a slice of it.
        src: []const u8,
        /// Where the previous line ended in `src`, and whether a blank
        /// line came since.
        prev_end: ?usize = null,
        blank: bool = false,

        pub fn line(p: *Lines, s: []const u8) void {
            defer p.y += p.lh;
            if (s.len == 0) {
                p.blank = true;
                return;
            }
            var sep: Sep = .auto;
            const base = @intFromPtr(p.src.ptr);
            const at = @intFromPtr(s.ptr);
            if (at >= base and at + s.len <= base + p.src.len) {
                const start = at - base;
                if (p.prev_end) |before| {
                    // What the source has between the two lines says how they join.
                    const gap = p.src[@min(before, start)..start];
                    sep = if (p.blank) .paragraph else if (std.mem.indexOfScalar(u8, gap, '\n') != null) .line else .space;
                }
                p.prev_end = start + s.len;
            }
            p.blank = false;
            _ = p.owner.add(p.ui, p.font, p.x, p.y + p.lh / 2, s, p.max_w, p.color, sep);
        }
    };

    /// Ends the frame: the mouse over `area` (presses no button above
    /// took), and the selected text for whoever copies it.
    pub fn end(self: *Selectable, ui: *Ui, area: Rect) void {
        const d = ui.drag(self.wid, area);
        if ((d.hover or d.dragging) and self.under(ui.mx, ui.my) != null) ui.cursor = .ibeam;
        if (d.started) {
            if (self.hit(ui, ui.mx, ui.my)) |pos| self.press(pos, ui.click_count) else self.clear();
            ui.wants_frame = true;
        } else if (d.dragging and self.by_drag) {
            if (self.hit(ui, ui.mx, ui.my)) |pos| {
                if (pos.run != self.head.run or pos.off != self.head.off) ui.wants_frame = true;
                self.head = pos;
            }
        }
        self.gather();
        if (self.hasSelection() and ui.rightClicked(area)) ui.askEditMenu(true, false);
    }

    fn press(self: *Selectable, pos: Pos, clicks: u32) void {
        self.anchor = pos;
        self.head = pos;
        self.by_drag = clicks < 2;
        if (pos.run >= self.runs.items.len) return;
        const str = self.runs.items[pos.run].text;
        if (clicks >= 3) {
            self.anchor.off = 0;
            self.head.off = str.len;
        } else if (clicks == 2) {
            var from = @min(pos.off, str.len);
            var to = from;
            while (from > 0 and !isBreak(str[from - 1])) from -= 1;
            while (to < str.len and !isBreak(str[to])) to += 1;
            self.anchor.off = from;
            self.head.off = to;
        }
    }

    /// The run whose text the point is on, if it is on one.
    fn under(self: *const Selectable, mx: f32, my: f32) ?usize {
        for (self.runs.items, 0..) |r, i| {
            if (@abs(my - r.cy) <= r.h / 2 and mx >= r.x and mx <= r.x + r.w) return i;
        }
        return null;
    }

    /// The place in the text nearest the point: on its row the run it is
    /// over (or the one before it), elsewhere the nearest row's.
    fn hit(self: *const Selectable, ui: *Ui, mx: f32, my: f32) ?Pos {
        if (self.runs.items.len == 0) return null;
        var best: usize = 0;
        var best_dy: f32 = std.math.floatMax(f32);
        for (self.runs.items, 0..) |r, i| {
            const dy = @abs(my - r.cy);
            // Rows tie when the point is on them: the last run that starts
            // at or before the point wins, so a row's later pieces are reachable.
            const same_row = @abs(dy - best_dy) < 0.5;
            if (dy < best_dy - 0.5 or (same_row and r.x <= mx)) {
                best = i;
                best_dy = dy;
            }
        }
        const r = self.runs.items[best];
        // Above the first row is its start; below the last is its end.
        if (best == 0 and my < r.cy - r.h / 2) return .{ .run = 0, .off = 0 };
        if (best == self.runs.items.len - 1 and my > r.cy + r.h / 2) return .{ .run = best, .off = r.text.len };
        var pen: f32 = r.x;
        var it = gfx_text.Utf8Iter{ .bytes = r.text };
        while (true) {
            const at = it.index;
            const cp = it.next() orelse break;
            const adv = ui.text.advance(r.font, cp);
            if (mx < pen + adv / 2) return .{ .run = best, .off = at };
            pen += adv;
        }
        return .{ .run = best, .off = r.text.len };
    }

    /// Rebuilds `copied` from the selection and this frame's runs.
    fn gather(self: *Selectable) void {
        self.copied.clearRetainingCapacity();
        const sp = self.span() orelse return;
        const runs = self.runs.items;
        var i = sp[0].run;
        while (i <= sp[1].run and i < runs.len) : (i += 1) {
            const r = runs[i];
            const from = if (i == sp[0].run) @min(sp[0].off, r.text.len) else 0;
            const to = if (i == sp[1].run) @min(sp[1].off, r.text.len) else r.text.len;
            if (i > sp[0].run) {
                const joiner: []const u8 = switch (r.sep) {
                    .space => " ",
                    .line => "\n",
                    .paragraph => "\n\n",
                    .auto => if (@abs(r.cy - runs[i - 1].cy) < 1) " " else "\n",
                };
                self.copied.appendSlice(self.gpa, joiner) catch return;
            }
            if (to > from) self.copied.appendSlice(self.gpa, r.text[from..to]) catch return;
        }
    }
};

fn isBreak(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == ',' or ch == '(' or ch == ')' or ch == '"' or ch == '\'';
}

// ── tests ───────────────────────────────────────────────────────────────
fn testRun(str: []const u8, x: f32, cy: f32, sep: Sep) Run {
    return .{ .text = str, .font = Font.sans(13), .x = x, .cy = cy, .h = 20, .w = 200, .sep = sep };
}

test "what a selection copies: rows, pieces of a row, a wrapped paragraph" {
    const gpa = std.testing.allocator;
    var sel = Selectable.init(gpa, 1);
    defer sel.deinit();
    try sel.runs.appendSlice(gpa, &.{
        testRun("Author", 0, 10, .auto),
        testRun("María Lado", 60, 10, .auto),
        testRun("Queue with exponential", 0, 40, .auto),
        testRun("retries.", 0, 60, .space),
        testRun("Closes #128.", 0, 100, .paragraph),
    });
    try std.testing.expect(!sel.hasSelection());

    // Part of one run.
    sel.anchor = .{ .run = 1, .off = 0 };
    sel.head = .{ .run = 1, .off = 6 };
    sel.gather();
    try std.testing.expectEqualStrings("María", sel.selected());

    // Backwards, across everything: the same row joins with a space, the
    // wrapped line with the space it was wrapped at, the paragraph with a blank line.
    sel.anchor = .{ .run = 4, .off = 6 };
    sel.head = .{ .run = 0, .off = 0 };
    sel.gather();
    try std.testing.expectEqualStrings("Author María Lado\nQueue with exponential retries.\n\nCloses", sel.selected());

    // A double click picks the word, a triple click the whole run.
    sel.press(.{ .run = 2, .off = 8 }, 2);
    sel.gather();
    try std.testing.expectEqualStrings("with", sel.selected());
    sel.press(.{ .run = 2, .off = 8 }, 3);
    sel.gather();
    try std.testing.expectEqualStrings("Queue with exponential", sel.selected());

    // Other content: the selection does not carry over.
    sel.key = 7;
    sel.begin(8);
    try std.testing.expect(sel.span() == null);
    try std.testing.expectEqual(@as(usize, 0), sel.selected().len);
}

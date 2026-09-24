//! Text selection over a block buffer drawn as wrapped rows: a command's
//! output in the terminal, a cell's output in a notebook. Positions are a
//! buffer line and a cell in it; the view maps the mouse to them with
//! `hitTest` (from its row layout) and reads the text back with `appendText`.
const std = @import("std");
const buffer_mod = @import("buffer.zig");

const Buffer = buffer_mod.Buffer;
const Cell = buffer_mod.Cell;

pub const Pos = struct {
    line: usize = 0,
    cell: usize = 0,

    pub fn before(a: Pos, b: Pos) bool {
        return a.line < b.line or (a.line == b.line and a.cell < b.cell);
    }
};

/// Where a selection started and where it is now; a press sets both, a
/// drag moves the head.
pub const Selection = struct {
    anchor: Pos = .{},
    head: Pos = .{},
    /// Started by a single press, so a drag grows it (a double or triple
    /// click picked a word or a line, which a drag leaves alone).
    by_drag: bool = false,

    /// A press at `pos`: an empty selection there that a drag grows, the
    /// word under it on a double click, the whole line on a triple.
    pub fn press(self: *Selection, buf: *const Buffer, pos: Pos, clicks: u32) void {
        self.anchor = pos;
        self.head = pos;
        self.by_drag = clicks < 2;
        if (clicks >= 3) {
            self.anchor = .{ .line = pos.line, .cell = 0 };
            self.head = .{ .line = pos.line, .cell = lineLen(buf, pos.line) };
        } else if (clicks == 2) {
            self.selectWord(buf, pos);
        }
    }

    /// The word under `pos` (a run of non-blank cells); nothing on a blank.
    pub fn selectWord(self: *Selection, buf: *const Buffer, pos: Pos) void {
        const cells = lineCells(buf, pos.line);
        var from = @min(pos.cell, cells.len);
        var to = from;
        while (from > 0 and cells[from - 1].cp != ' ') from -= 1;
        while (to < cells.len and cells[to].cp != ' ') to += 1;
        self.anchor = .{ .line = pos.line, .cell = from };
        self.head = .{ .line = pos.line, .cell = to };
    }

    pub fn dragTo(self: *Selection, pos: Pos) void {
        if (self.by_drag) self.head = pos;
    }

    /// The span in reading order; null when nothing is selected.
    pub fn range(self: Selection) ?[2]Pos {
        if (self.anchor.line == self.head.line and self.anchor.cell == self.head.cell) return null;
        return if (self.anchor.before(self.head)) .{ self.anchor, self.head } else .{ self.head, self.anchor };
    }

    pub fn contains(self: Selection, pos: Pos) bool {
        const r = self.range() orelse return false;
        return !pos.before(r[0]) and pos.before(r[1]);
    }
};

fn lineCells(buf: *const Buffer, line: usize) []const Cell {
    if (line >= buf.lines.items.len) return &.{};
    return buf.lines.items[line].cells.items;
}

fn lineLen(buf: *const Buffer, line: usize) usize {
    return lineCells(buf, line).len;
}

/// How the view lays the buffer out: where each logical line starts in
/// wrapped rows of `cols` cells, and the slice of rows on show.
pub const Rows = struct {
    starts: []const u32,
    first_row: u32,
    rows: u32,
    cols: u32,
};

/// Maps a mouse position to the position under it, with the rows starting
/// at (x, rows_y); clamped to the rows on show, so a drag past the edges
/// selects up to them.
pub fn hitTest(buf: *const Buffer, l: Rows, x: f32, rows_y: f32, cell_w: f32, row_h: f32, mx: f32, my: f32) Pos {
    const starts = l.starts;
    if (starts.len == 0) return .{};
    const rel = @floor((my - rows_y) / row_h);
    const max_row: f32 = @floatFromInt(l.rows -| 1);
    const row: u32 = l.first_row + @as(u32, @intFromFloat(std.math.clamp(rel, 0, max_row)));

    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= row) lo = mid else hi = mid;
    }
    const len = lineLen(buf, lo);
    const seg: usize = row - starts[lo];
    const seg_start = @min(len, seg * l.cols);
    const seg_end = @min(len, seg_start + l.cols);
    if (rel < 0) return .{ .line = lo, .cell = seg_start };
    if (rel > max_row) return .{ .line = lo, .cell = seg_end };
    const c = @round((mx - x) / cell_w);
    const span: f32 = @floatFromInt(seg_end - seg_start);
    return .{ .line = lo, .cell = seg_start + @as(usize, @intFromFloat(std.math.clamp(c, 0, span))) };
}

/// Appends the text between two ordered positions, a newline between
/// lines; the blanks a program padded a line with are not content.
pub fn appendText(buf: *const Buffer, r: [2]Pos, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var line = r[0].line;
    while (line <= r[1].line and line < buf.lines.items.len) : (line += 1) {
        const cells = lineCells(buf, line);
        const from = if (line == r[0].line) @min(r[0].cell, cells.len) else 0;
        var to = if (line == r[1].line) @min(r[1].cell, cells.len) else cells.len;
        if (line != r[1].line or to == cells.len) {
            while (to > from and cells[to - 1].cp == ' ') to -= 1;
        }
        for (cells[from..to]) |cell| {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.cp, &utf8) catch continue;
            try out.appendSlice(gpa, utf8[0..n]);
        }
        if (line != r[1].line) try out.append(gpa, '\n');
    }
}

test "selection: words, lines, drags and the text they cover" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    buf.write("total = 42   ");
    buf.carriageReturn();
    buf.lineFeed();
    buf.write("done");

    var sel: Selection = .{};
    sel.press(&buf, .{ .line = 0, .cell = 9 }, 2);
    try std.testing.expect(sel.range() != null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendText(&buf, sel.range().?, &out, gpa);
    try std.testing.expectEqualStrings("42", out.items);
    // A drag does not stretch a word picked by a double click.
    sel.dragTo(.{ .line = 1, .cell = 2 });
    try std.testing.expectEqual(@as(usize, 0), sel.head.line);

    // A press and a drag across the line break: the padding is dropped.
    sel.press(&buf, .{ .line = 0, .cell = 8 }, 1);
    try std.testing.expect(sel.range() == null);
    sel.dragTo(.{ .line = 1, .cell = 4 });
    out.clearRetainingCapacity();
    try appendText(&buf, sel.range().?, &out, gpa);
    try std.testing.expectEqualStrings("42\ndone", out.items);
    try std.testing.expect(sel.contains(.{ .line = 0, .cell = 9 }));
    try std.testing.expect(!sel.contains(.{ .line = 0, .cell = 2 }));

    // Triple click: the whole line; a word press on a blank selects nothing.
    sel.press(&buf, .{ .line = 1, .cell = 1 }, 3);
    out.clearRetainingCapacity();
    try appendText(&buf, sel.range().?, &out, gpa);
    try std.testing.expectEqualStrings("done", out.items);
    sel.selectWord(&buf, .{ .line = 0, .cell = 11 });
    try std.testing.expect(sel.range() == null);

    // Hit testing over two wrapped rows of 8 cells.
    const starts = [_]u32{ 0, 2 };
    const l: Rows = .{ .starts = &starts, .first_row = 0, .rows = 3, .cols = 8 };
    const p = hitTest(&buf, l, 100, 50, 10, 20, 100 + 2 * 10, 50 + 20 + 5);
    try std.testing.expectEqual(Pos{ .line = 0, .cell = 10 }, p);
    const below = hitTest(&buf, l, 100, 50, 10, 20, 0, 500);
    try std.testing.expectEqual(Pos{ .line = 1, .cell = 4 }, below);
}

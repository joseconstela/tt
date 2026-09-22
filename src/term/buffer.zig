//! Output model for one command block: an unbounded list of logical lines with
//! a cursor, enough to honour what CLI tools actually emit outside of
//! full-screen mode (colours, \r progress bars, cursor-up redraws, erases).
const std = @import("std");
const Csi = @import("parser.zig").Csi;

/// 0 = default, 0x01_0000NN = palette index, 0x02_RRGGBB = true colour.
pub const ColorSpec = u32;
pub const color_default: ColorSpec = 0;

pub fn indexed(n: u8) ColorSpec {
    return 0x0100_0000 | @as(u32, n);
}
pub fn rgb(r: u8, g: u8, b: u8) ColorSpec {
    return 0x0200_0000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub const Style = struct {
    fg: ColorSpec = color_default,
    bg: ColorSpec = color_default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};

pub const Cell = struct {
    cp: u21,
    style: u16 = 0,
};

pub const Line = struct {
    cells: std.ArrayList(Cell) = .empty,
};

pub const max_lines: usize = 20_000;
const drop_chunk: usize = 2_000;

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    /// Style table; index 0 is always the default style.
    styles: std.ArrayList(Style) = .empty,
    pen: Style = .{},
    pen_id: u16 = 0,
    row: usize = 0,
    col: usize = 0,
    /// Lines discarded from the top once `max_lines` was exceeded.
    dropped: usize = 0,
    /// Bumped on every mutation; views use it to invalidate layout caches.
    version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Buffer {
        var self: Buffer = .{ .gpa = gpa };
        self.styles.append(gpa, .{}) catch {};
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.cells.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.styles.deinit(self.gpa);
    }

    /// Number of lines, ignoring trailing blank ones.
    pub fn lineCount(self: *const Buffer) usize {
        var n = self.lines.items.len;
        while (n > 0 and isBlank(self.lines.items[n - 1])) n -= 1;
        return n;
    }

    fn isBlank(line: Line) bool {
        for (line.cells.items) |cell| {
            if (cell.cp != ' ') return false;
            if (cell.style != 0) return false;
        }
        return true;
    }

    pub fn isEmpty(self: *const Buffer) bool {
        return self.lineCount() == 0;
    }

    pub fn style(self: *const Buffer, id: u16) Style {
        if (id < self.styles.items.len) return self.styles.items[id];
        return .{};
    }

    fn currentLine(self: *Buffer) ?*Line {
        while (self.lines.items.len <= self.row) {
            self.lines.append(self.gpa, .{}) catch return null;
        }
        return &self.lines.items[self.row];
    }

    fn internPen(self: *Buffer) void {
        for (self.styles.items, 0..) |s, i| {
            if (s.eql(self.pen)) {
                self.pen_id = @intCast(i);
                return;
            }
        }
        if (self.styles.items.len >= std.math.maxInt(u16)) {
            self.pen_id = 0;
            return;
        }
        self.styles.append(self.gpa, self.pen) catch {
            self.pen_id = 0;
            return;
        };
        self.pen_id = @intCast(self.styles.items.len - 1);
    }

    // ── writing ─────────────────────────────────────────────────────────
    pub fn print(self: *Buffer, cp: u21) void {
        const line = self.currentLine() orelse return;
        self.version +%= 1;
        while (line.cells.items.len < self.col) {
            line.cells.append(self.gpa, .{ .cp = ' ' }) catch return;
        }
        const cell: Cell = .{ .cp = cp, .style = self.pen_id };
        if (self.col < line.cells.items.len) {
            line.cells.items[self.col] = cell;
        } else {
            line.cells.append(self.gpa, cell) catch return;
        }
        self.col += 1;
    }

    pub fn write(self: *Buffer, text: []const u8) void {
        var view = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (view.nextCodepoint()) |cp| {
            if (cp == '\n') {
                self.carriageReturn();
                self.lineFeed();
            } else self.print(cp);
        }
    }

    pub fn lineFeed(self: *Buffer) void {
        self.row += 1;
        _ = self.currentLine();
        self.version +%= 1;
        if (self.lines.items.len > max_lines) self.dropOldest();
    }

    fn dropOldest(self: *Buffer) void {
        const n = @min(drop_chunk, self.lines.items.len - 1);
        for (self.lines.items[0..n]) |*l| l.cells.deinit(self.gpa);
        const remaining = self.lines.items.len - n;
        std.mem.copyForwards(Line, self.lines.items[0..remaining], self.lines.items[n..]);
        self.lines.items.len = remaining;
        self.row -|= n;
        self.dropped += n;
    }

    pub fn carriageReturn(self: *Buffer) void {
        self.col = 0;
    }

    pub fn backspace(self: *Buffer) void {
        self.col -|= 1;
    }

    pub fn tab(self: *Buffer) void {
        const next = (self.col / 8 + 1) * 8;
        while (self.col < next) self.print(' ');
    }

    pub fn execute(self: *Buffer, c: u8) void {
        switch (c) {
            '\n', 0x0B, 0x0C => self.lineFeed(),
            '\r' => self.carriageReturn(),
            0x08 => self.backspace(),
            '\t' => self.tab(),
            else => {},
        }
    }

    // ── CSI ─────────────────────────────────────────────────────────────
    pub fn csi(self: *Buffer, c: Csi) void {
        if (c.private != 0 or c.intermediate != 0) return;
        switch (c.final) {
            'm' => self.sgr(c.params),
            'K' => self.eraseLine(c.param(0, 0)),
            'J' => self.eraseDisplay(c.param(0, 0)),
            'A' => self.row -|= c.param(0, 1),
            'B', 'e' => self.moveDown(c.param(0, 1)),
            'C', 'a' => self.col += c.param(0, 1),
            'D' => self.col -|= c.param(0, 1),
            'E' => {
                self.moveDown(c.param(0, 1));
                self.col = 0;
            },
            'F' => {
                self.row -|= c.param(0, 1);
                self.col = 0;
            },
            'G', '`' => self.col = c.param(0, 1) - 1,
            'P' => self.deleteChars(c.param(0, 1)),
            'X' => self.eraseChars(c.param(0, 1)),
            '@' => self.insertBlanks(c.param(0, 1)),
            else => {},
        }
    }

    fn moveDown(self: *Buffer, n: usize) void {
        self.row += n;
        _ = self.currentLine();
    }

    fn eraseLine(self: *Buffer, mode: u16) void {
        const line = self.currentLine() orelse return;
        self.version +%= 1;
        switch (mode) {
            0 => if (self.col < line.cells.items.len) {
                line.cells.items.len = self.col;
            },
            1 => {
                const end = @min(self.col + 1, line.cells.items.len);
                for (line.cells.items[0..end]) |*cell| cell.* = .{ .cp = ' ' };
            },
            2 => line.cells.items.len = 0,
            else => {},
        }
    }

    fn eraseDisplay(self: *Buffer, mode: u16) void {
        self.version +%= 1;
        switch (mode) {
            0 => {
                self.eraseLine(0);
                var i = self.row + 1;
                while (i < self.lines.items.len) : (i += 1) self.lines.items[i].cells.items.len = 0;
            },
            2, 3 => {
                for (self.lines.items) |*l| l.cells.deinit(self.gpa);
                self.lines.items.len = 0;
                self.row = 0;
                self.col = 0;
            },
            else => {},
        }
    }

    fn deleteChars(self: *Buffer, n: usize) void {
        const line = self.currentLine() orelse return;
        if (self.col >= line.cells.items.len) return;
        self.version +%= 1;
        const count = @min(n, line.cells.items.len - self.col);
        const tail = line.cells.items[self.col + count ..];
        std.mem.copyForwards(Cell, line.cells.items[self.col..][0..tail.len], tail);
        line.cells.items.len -= count;
    }

    fn eraseChars(self: *Buffer, n: usize) void {
        const line = self.currentLine() orelse return;
        self.version +%= 1;
        const end = @min(self.col + n, line.cells.items.len);
        if (self.col >= end) return;
        for (line.cells.items[self.col..end]) |*cell| cell.* = .{ .cp = ' ' };
    }

    fn insertBlanks(self: *Buffer, n: usize) void {
        const line = self.currentLine() orelse return;
        if (self.col >= line.cells.items.len) return;
        self.version +%= 1;
        var i: usize = 0;
        while (i < n) : (i += 1) line.cells.insert(self.gpa, self.col, .{ .cp = ' ' }) catch return;
    }

    pub fn resetPen(self: *Buffer) void {
        self.pen = .{};
        self.pen_id = 0;
    }

    fn sgr(self: *Buffer, params: []const u16) void {
        applySgr(&self.pen, params);
        self.internPen();
    }

    /// Makes `s` the pen for what is printed next (used when a screen's
    /// cells are copied into a block).
    pub fn setPen(self: *Buffer, s: Style) void {
        self.pen = s;
        self.internPen();
    }

    // ── reading ─────────────────────────────────────────────────────────
    /// Appends the plain text of the buffer (for copy / tests).
    pub fn appendText(self: *const Buffer, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        const n = self.lineCount();
        for (self.lines.items[0..n], 0..) |line, idx| {
            var end = line.cells.items.len;
            while (end > 0 and line.cells.items[end - 1].cp == ' ') end -= 1;
            for (line.cells.items[0..end]) |cell| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try out.appendSlice(gpa, buf[0..len]);
            }
            if (idx + 1 < n) try out.append(gpa, '\n');
        }
    }
};

/// Applies an SGR parameter list ("CSI … m") to a pen. Shared by the block
/// buffer and the full-screen grid.
pub fn applySgr(pen: *Style, params: []const u16) void {
    if (params.len == 0) {
        pen.* = .{};
        return;
    }
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => pen.* = .{},
            1 => pen.bold = true,
            2 => pen.dim = true,
            3 => pen.italic = true,
            4 => pen.underline = true,
            7 => pen.inverse = true,
            9 => pen.strike = true,
            21, 22 => {
                pen.bold = false;
                pen.dim = false;
            },
            23 => pen.italic = false,
            24 => pen.underline = false,
            27 => pen.inverse = false,
            29 => pen.strike = false,
            30...37 => pen.fg = indexed(@intCast(p - 30)),
            39 => pen.fg = color_default,
            40...47 => pen.bg = indexed(@intCast(p - 40)),
            49 => pen.bg = color_default,
            90...97 => pen.fg = indexed(@intCast(p - 90 + 8)),
            100...107 => pen.bg = indexed(@intCast(p - 100 + 8)),
            38, 48 => {
                var spec: ColorSpec = color_default;
                if (i + 2 < params.len and params[i + 1] == 5) {
                    spec = indexed(@truncate(params[i + 2]));
                    i += 2;
                } else if (i + 4 < params.len and params[i + 1] == 2) {
                    spec = rgb(@truncate(params[i + 2]), @truncate(params[i + 3]), @truncate(params[i + 4]));
                    i += 4;
                } else break;
                if (p == 38) pen.fg = spec else pen.bg = spec;
            },
            else => {},
        }
    }
}

/// Writes the SGR sequence that selects `s` from any state — the inverse
/// of `applySgr`, for turning a buffer back into terminal bytes.
pub fn appendSgr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Style) !void {
    try out.appendSlice(gpa, "\x1b[0");
    if (s.bold) try out.appendSlice(gpa, ";1");
    if (s.dim) try out.appendSlice(gpa, ";2");
    if (s.italic) try out.appendSlice(gpa, ";3");
    if (s.underline) try out.appendSlice(gpa, ";4");
    if (s.inverse) try out.appendSlice(gpa, ";7");
    if (s.strike) try out.appendSlice(gpa, ";9");
    try appendColor(out, gpa, s.fg, 30);
    try appendColor(out, gpa, s.bg, 40);
    try out.append(gpa, 'm');
}

fn appendColor(out: *std.ArrayList(u8), gpa: std.mem.Allocator, spec: ColorSpec, base: u8) !void {
    switch (spec >> 24) {
        1 => {
            const n: u8 = @truncate(spec);
            if (n < 8) {
                try out.print(gpa, ";{d}", .{base + n});
            } else if (n < 16) {
                try out.print(gpa, ";{d}", .{base + 60 + (n - 8)});
            } else try out.print(gpa, ";{d};5;{d}", .{ base + 8, n });
        },
        2 => try out.print(gpa, ";{d};2;{d};{d};{d}", .{ base + 8, @as(u8, @truncate(spec >> 16)), @as(u8, @truncate(spec >> 8)), @as(u8, @truncate(spec)) }),
        else => {},
    }
}

/// Feeds a parser's events into a buffer, the way a block's output arrives.
pub const Sink = struct {
    buf: *Buffer,
    pub fn print(self: *Sink, cp: u21) void {
        self.buf.print(cp);
    }
    pub fn execute(self: *Sink, c: u8) void {
        self.buf.execute(c);
    }
    pub fn csi(self: *Sink, c: Csi) void {
        self.buf.csi(c);
    }
    pub fn osc(_: *Sink, _: []const u8) void {}
    pub fn esc(_: *Sink, _: u8, _: u8) void {}
};

// ── tests ────────────────────────────────────────────────────────────────
const Parser = @import("parser.zig").Parser;

fn expectText(input: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var sink = Sink{ .buf = &buf };
    var p = Parser{};
    p.feed(input, &sink);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try buf.appendText(&out, gpa);
    try std.testing.expectEqualStrings(expected, out.items);
}

test "lines and trailing newline" {
    try expectText("one\r\ntwo\r\n", "one\ntwo");
}

test "carriage return progress bar overwrites" {
    try expectText("10%\r50%\r100%\r\ndone\r\n", "100%\ndone");
}

test "erase line then rewrite" {
    try expectText("downloading...\r\x1b[2Kok\r\n", "ok");
    try expectText("abcdef\r\x1b[3C\x1b[K\r\n", "abc");
}

test "cursor up redraw (spinner style)" {
    try expectText("a\r\nb\r\n\x1b[2A\x1b[2KA\r\n\x1b[2KB\r\n", "A\nB");
}

test "sgr does not leak into text and styles are interned" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var sink = Sink{ .buf = &buf };
    var p = Parser{};
    p.feed("\x1b[1;32mok\x1b[0m plain \x1b[38;5;208mx\x1b[38;2;1;2;3my", &sink);
    const cells = buf.lines.items[0].cells.items;
    try std.testing.expect(buf.style(cells[0].style).bold);
    try std.testing.expectEqual(indexed(2), buf.style(cells[0].style).fg);
    try std.testing.expectEqual(@as(u16, 0), cells[3].style);
    try std.testing.expectEqual(indexed(208), buf.style(cells[9].style).fg);
    try std.testing.expectEqual(rgb(1, 2, 3), buf.style(cells[10].style).fg);
}

test "tabs and backspace" {
    try expectText("a\tb\r\n", "a       b");
    try expectText("abc\x08\x08X\r\n", "aXc");
}

test "clear screen wipes the block" {
    try expectText("junk\r\nmore\r\n\x1b[H\x1b[2Jfresh\r\n", "fresh");
}

test "line cap drops oldest lines" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var i: usize = 0;
    while (i < max_lines + 10) : (i += 1) {
        buf.print('x');
        buf.carriageReturn();
        buf.lineFeed();
    }
    try std.testing.expect(buf.lines.items.len <= max_lines);
    try std.testing.expect(buf.dropped > 0);
}

//! The terminal a full-screen program runs in, backed by libghostty-vt
//! (Ghostty's terminal emulation core): escape-sequence parsing, screen and
//! alternate-screen state, scrollback, and the replies to the queries such
//! programs make. A block hands its output here from the moment its program
//! takes over the terminal until it exits (see session.zig); the tab draws
//! the screen edge to edge from `render`. When the program exits, whatever it
//! left on the main screen goes back into the command's block.
const std = @import("std");
const vt = @import("ghostty-vt");
const buffer_mod = @import("buffer.zig");
const Parser = @import("parser.zig").Parser;
const Csi = @import("parser.zig").Csi;
const EditCommand = @import("../events.zig").EditCommand;
const theme = @import("../ui/theme.zig");

pub const Terminal = vt.Terminal;
pub const RenderState = vt.RenderState;
pub const Style = vt.Style;
pub const Cell = vt.Cell;
pub const KeyEvent = vt.input.KeyEvent;
pub const MouseEvent = vt.input.MouseEncodeEvent;
pub const Mods = vt.input.KeyMods;

const Stream = vt.TerminalStream;
const Handler = Stream.Handler;
const Effects = Handler.Effects;

/// Where the program's query replies go (the PTY).
pub const Writer = struct {
    ctx: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,
};

/// Default colours the program sees (OSC 10/11 queries, the formatter).
pub const Colors = struct {
    bg: [3]u8 = .{ 0x1A, 0x19, 0x17 },
    fg: [3]u8 = .{ 0xEC, 0xE7, 0xDC },
};

pub const Options = struct {
    cols: u16,
    rows: u16,
    /// Cell size in device pixels (size reports, mouse positions).
    cell_px: [2]u32 = .{ 1, 1 },
    colors: Colors = .{},
    out: Writer,
};

fn ReturnOf(comptime OptionalFnPtr: type) type {
    const FnPtr = @typeInfo(OptionalFnPtr).optional.child;
    const Fn = @typeInfo(FnPtr).pointer.child;
    return @typeInfo(Fn).@"fn".return_type.?;
}

pub const Screen = struct {
    gpa: std.mem.Allocator,
    term: Terminal,
    /// Parses the program's bytes into `term`. Its handler points back at
    /// `term`, so a Screen lives at one heap address for its whole life.
    stream: Stream,
    render: RenderState = .empty,
    out: Writer,
    cell_px: [2]u32,
    /// Bumped whenever the program may have changed something visible.
    version: u64 = 0,
    /// Last cell reported for mouse motion (the encoder's dedup state).
    last_mouse_cell: ?vt.Coordinate = null,

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Screen {
        const self = try gpa.create(Screen);
        errdefer gpa.destroy(self);
        const c = opts.colors;
        self.* = .{
            .gpa = gpa,
            .term = try Terminal.init(vt.TinyIo.init.io(), gpa, .{
                .cols = @max(1, opts.cols),
                .rows = @max(1, opts.rows),
                .max_scrollback_bytes = 8 * 1024 * 1024,
                .colors = .{
                    .background = .init(.{ .r = c.bg[0], .g = c.bg[1], .b = c.bg[2] }),
                    .foreground = .init(.{ .r = c.fg[0], .g = c.fg[1], .b = c.fg[2] }),
                    .cursor = .unset,
                    .palette = .default,
                },
            }),
            .stream = undefined,
            .out = opts.out,
            .cell_px = opts.cell_px,
        };
        errdefer self.term.deinit(gpa);
        self.stream = self.term.vtStream();
        var effects: Effects = .readonly;
        effects.write_pty = writePty;
        effects.device_attributes = deviceAttributes;
        effects.color_scheme = colorScheme;
        effects.size = sizeReport;
        effects.title_changed = titleChanged;
        effects.xtversion = xtversion;
        self.stream.handler.effects = effects;
        self.stream.handler.terminfo_name = "xterm-256color";
        return self;
    }

    pub fn destroy(self: *Screen) void {
        self.render.deinit(self.gpa);
        self.stream.deinit();
        self.term.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // ── effects the program can trigger ─────────────────────────────────
    fn fromHandler(h: *Handler) *Screen {
        const stream: *Stream = @fieldParentPtr("handler", h);
        return @fieldParentPtr("stream", stream);
    }

    fn writePty(h: *Handler, bytes: []const u8) void {
        const self = fromHandler(h);
        self.out.write(self.out.ctx, bytes);
    }

    fn deviceAttributes(_: *Handler) ReturnOf(@FieldType(Effects, "device_attributes")) {
        return .{};
    }

    /// What a program asking (DECRQM 2031 / OSC) is told: light on the
    /// light and e-ink schemes, so it picks a palette that reads there.
    fn colorScheme(_: *Handler) ReturnOf(@FieldType(Effects, "color_scheme")) {
        return if (theme.scheme == .dark) .dark else .light;
    }

    fn sizeReport(h: *Handler) ReturnOf(@FieldType(Effects, "size")) {
        const self = fromHandler(h);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = self.cell_px[0],
            .cell_height = self.cell_px[1],
        };
    }

    fn titleChanged(h: *Handler) void {
        fromHandler(h).version +%= 1;
    }

    fn xtversion(_: *Handler) []const u8 {
        return "tt 0.1.0";
    }

    // ── the program's output ────────────────────────────────────────────
    pub fn feed(self: *Screen, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
        self.version +%= 1;
    }

    pub fn resize(self: *Screen, cols_in: u16, rows_in: u16, cell_px: [2]u32) void {
        self.cell_px = cell_px;
        const cols = @max(1, cols_in);
        const rows = @max(1, rows_in);
        if (cols == self.term.cols and rows == self.term.rows) return;
        self.stream.handler.resize(.{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{ .width = cell_px[0], .height = cell_px[1] },
        }) catch |err| std.log.err("screen resize failed: {s}", .{@errorName(err)});
        self.version +%= 1;
    }

    /// Starts the main screen from what the block already captured, the
    /// way a real terminal already shows what a program printed before it
    /// took over, with the cursor where the block's was, so the program's
    /// relative redraws line up.
    pub fn seed(self: *Screen, buf: *const buffer_mod.Buffer) void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        encodeBuffer(buf, &bytes, self.gpa) catch return;
        self.feed(bytes.items);
    }

    /// Writes the main screen — scrollback first, trailing blank rows
    /// dropped, soft wraps undone so the block can reflow — into a block.
    pub fn dumpMain(self: *Screen, buf: *buffer_mod.Buffer) void {
        const primary = self.term.screens.get(.primary) orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var f: vt.formatter.ScreenFormatter = .init(primary, .{ .emit = .vt, .unwrap = true });
        f.extra = .{ .cursor = false, .style = true, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false };
        f.format(&aw.writer) catch return;
        var sink = buffer_mod.Sink{ .buf = buf };
        var p = Parser{};
        p.feed(aw.written(), &sink);
        buf.setPen(.{});
    }

    // ── what the tab draws ──────────────────────────────────────────────
    /// Refreshes `render` from the terminal; once per frame, before reading rows.
    pub fn update(self: *Screen) void {
        self.render.update(self.gpa, &self.term) catch |err| std.log.err("render state: {s}", .{@errorName(err)});
    }

    pub fn altActive(self: *const Screen) bool {
        return self.term.screens.active_key == .alternate;
    }

    pub fn title(self: *const Screen) ?[:0]const u8 {
        return self.term.getTitle();
    }

    /// The program asked for mouse reports.
    pub fn mouseTracking(self: *const Screen) bool {
        return self.term.flags.mouse_event != .none;
    }

    /// Wheel on the alternate screen stands in for arrow keys (DEC 1007).
    pub fn wheelAsArrows(self: *const Screen) bool {
        return self.altActive() and self.term.modes.get(.mouse_alternate_scroll);
    }

    /// Moves the viewport through the main screen's history (negative = up).
    pub fn scrollBy(self: *Screen, delta_rows: isize) void {
        self.term.scrollViewport(.{ .delta = delta_rows });
        self.version +%= 1;
    }

    pub fn scrollToBottom(self: *Screen) void {
        if (self.atBottom()) return;
        self.term.scrollViewport(.bottom);
        self.version +%= 1;
    }

    pub fn atBottom(self: *const Screen) bool {
        return self.term.screens.active.pages.viewport == .active;
    }

    // ── what the user sends ─────────────────────────────────────────────
    /// Bytes the program receives for a key, honouring the modes it set
    /// (application cursor keys, modifyOtherKeys, the Kitty keyboard protocol).
    pub fn encodeKey(self: *const Screen, buf: []u8, event: KeyEvent) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        vt.input.encodeKey(&w, event, .fromTerminal(&self.term)) catch return "";
        return w.buffered();
    }

    pub fn encodeFocus(self: *const Screen, buf: []u8, gained: bool) []const u8 {
        if (!self.term.modes.get(.focus_event)) return "";
        var w: std.Io.Writer = .fixed(buf);
        vt.input.encodeFocus(&w, if (gained) .gained else .lost) catch return "";
        return w.buffered();
    }

    /// Paste, bracketed when the program asked for it; caller frees.
    pub fn encodePaste(self: *const Screen, gpa: std.mem.Allocator, data: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try vt.input.encodePasteWriter(&aw.writer, data, .fromTerminal(&self.term));
        return aw.toOwnedSlice();
    }

    /// A mouse report, or "" when the program does not want this event.
    /// `pos` is in device pixels from the screen's top-left corner.
    pub fn encodeMouse(self: *Screen, buf: []u8, event: MouseEvent, screen_px: [2]u32, button_held: bool) []const u8 {
        var opts: vt.input.MouseEncodeOptions = .fromTerminal(&self.term, .{
            .screen = .{ .width = screen_px[0], .height = screen_px[1] },
            .cell = .{ .width = self.cell_px[0], .height = self.cell_px[1] },
            .padding = .{},
        });
        opts.any_button_pressed = button_held;
        opts.last_cell = &self.last_mouse_cell;
        var w: std.Io.Writer = .fixed(buf);
        vt.input.encodeMouse(&w, event, opts) catch return "";
        return w.buffered();
    }
};

/// The key a Cocoa editing command stands for, or null when it means
/// nothing to a terminal.
pub fn keyForCommand(cmd: EditCommand) ?KeyEvent {
    return switch (cmd) {
        .insert_newline => .{ .key = .enter },
        .insert_line_break => .{ .key = .enter, .mods = .{ .shift = true } },
        .insert_tab => .{ .key = .tab },
        .insert_backtab => .{ .key = .tab, .mods = .{ .shift = true } },
        .delete_backward => .{ .key = .backspace },
        .delete_forward => .{ .key = .delete },
        .delete_word_backward => .{ .key = .backspace, .mods = .{ .alt = true } },
        .delete_word_forward => .{ .key = .delete, .mods = .{ .alt = true } },
        .delete_to_line_start => ctrlKey('u'),
        .delete_to_line_end => ctrlKey('k'),
        .cancel => .{ .key = .escape },
        .move_up => .{ .key = .arrow_up },
        .move_down => .{ .key = .arrow_down },
        .move_left => .{ .key = .arrow_left },
        .move_right => .{ .key = .arrow_right },
        .select_up => .{ .key = .arrow_up, .mods = .{ .shift = true } },
        .select_down => .{ .key = .arrow_down, .mods = .{ .shift = true } },
        .select_left => .{ .key = .arrow_left, .mods = .{ .shift = true } },
        .select_right => .{ .key = .arrow_right, .mods = .{ .shift = true } },
        .move_word_left => .{ .key = .arrow_left, .mods = .{ .alt = true } },
        .move_word_right => .{ .key = .arrow_right, .mods = .{ .alt = true } },
        .select_word_left => .{ .key = .arrow_left, .mods = .{ .shift = true, .alt = true } },
        .select_word_right => .{ .key = .arrow_right, .mods = .{ .shift = true, .alt = true } },
        .move_line_start, .scroll_to_top => .{ .key = .home },
        .move_line_end, .scroll_to_bottom => .{ .key = .end },
        .select_line_start => .{ .key = .home, .mods = .{ .shift = true } },
        .select_line_end => .{ .key = .end, .mods = .{ .shift = true } },
        .move_doc_start => .{ .key = .home, .mods = .{ .ctrl = true } },
        .move_doc_end => .{ .key = .end, .mods = .{ .ctrl = true } },
        .select_doc_start => .{ .key = .home, .mods = .{ .ctrl = true, .shift = true } },
        .select_doc_end => .{ .key = .end, .mods = .{ .ctrl = true, .shift = true } },
        .page_up => .{ .key = .page_up },
        .page_down => .{ .key = .page_down },
        .select_all => null,
    };
}

/// ⌃ + a letter (or `\`), the way the platform layer reports control chords.
pub fn ctrlKey(letter: u8) ?KeyEvent {
    if (letter == '\\') return .{ .key = .backslash, .mods = .{ .ctrl = true }, .unshifted_codepoint = '\\' };
    if (letter < 'a' or letter > 'z') return null;
    var name: [5]u8 = "key_a".*;
    name[4] = letter;
    const key = std.meta.stringToEnum(vt.input.Key, &name) orelse return null;
    return .{ .key = key, .mods = .{ .ctrl = true }, .unshifted_codepoint = letter };
}

// ── block ⇄ screen ───────────────────────────────────────────────────────
/// A block's output as the bytes that would reproduce it on a terminal,
/// cursor position included.
fn encodeBuffer(buf: *const buffer_mod.Buffer, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const lines = buf.lines.items;
    if (lines.len == 0) return;
    const cursor_line = @min(buf.row, lines.len - 1);
    var current: u16 = 0;
    for (lines, 0..) |line, i| {
        if (i > 0) try out.appendSlice(gpa, "\r\n");
        for (line.cells.items) |cell| {
            if (cell.style != current) {
                current = cell.style;
                try buffer_mod.appendSgr(out, gpa, buf.style(cell.style));
            }
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.cp, &b) catch continue;
            try out.appendSlice(gpa, b[0..n]);
        }
    }
    if (current != 0) try out.appendSlice(gpa, "\x1b[m");
    // Back up to the cursor's line and column. At the end of the last line
    // it is already there (pending wrap and all).
    const below = lines.len - 1 - cursor_line;
    if (below > 0) try out.print(gpa, "\x1b[{d}A", .{below});
    if (below > 0 or buf.col < lines[cursor_line].cells.items.len) {
        try out.append(gpa, '\r');
        if (buf.col > 0) try out.print(gpa, "\x1b[{d}C", .{buf.col});
    }
}

/// Feeds VT bytes into a block's buffer (our own parser, so the block's
/// own wrapping and styles apply).
// ── tests ────────────────────────────────────────────────────────────────
const TestOut = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(ctx: *anyopaque, data: []const u8) void {
        const self: *TestOut = @ptrCast(@alignCast(ctx));
        self.bytes.appendSlice(std.testing.allocator, data) catch {};
    }
};

fn blockText(buf: *const buffer_mod.Buffer) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    try buf.appendText(&out, std.testing.allocator);
    return out.toOwnedSlice(std.testing.allocator);
}

test "block output seeds the screen and the screen comes back as a block" {
    const gpa = std.testing.allocator;
    var out = TestOut{};
    defer out.bytes.deinit(gpa);
    const s = try Screen.create(gpa, .{ .cols = 20, .rows = 3, .out = .{ .ctx = &out, .write = TestOut.write } });
    defer s.destroy();

    var buf = buffer_mod.Buffer.init(gpa);
    defer buf.deinit();
    var sink = buffer_mod.Sink{ .buf = &buf };
    var p = Parser{};
    p.feed("one\r\n\x1b[31mtwo\x1b[m\r\n> ", &sink);
    s.seed(&buf);

    // The program redraws relative to where the block's cursor was.
    s.feed("\x1b[1A\r\x1b[2Kdeux\r\n> x");
    var done = buffer_mod.Buffer.init(gpa);
    defer done.deinit();
    s.dumpMain(&done);
    const text = try blockText(&done);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("one\ndeux\n> x", text);
}

test "alternate screen, queries and key encoding" {
    const gpa = std.testing.allocator;
    var out = TestOut{};
    defer out.bytes.deinit(gpa);
    const s = try Screen.create(gpa, .{ .cols = 10, .rows = 2, .out = .{ .ctx = &out, .write = TestOut.write } });
    defer s.destroy();

    s.feed("main\x1b[?1049h\x1b[Halt");
    try std.testing.expect(s.altActive());
    s.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", out.bytes.items);
    s.feed("\x1b[?1049l");
    try std.testing.expect(!s.altActive());

    // What the program left on the main screen is what the block gets.
    var done = buffer_mod.Buffer.init(gpa);
    defer done.deinit();
    s.dumpMain(&done);
    const text = try blockText(&done);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("main", text);

    var kb: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", s.encodeKey(&kb, keyForCommand(.move_up).?));
    s.feed("\x1b[?1h");
    try std.testing.expectEqualStrings("\x1bOA", s.encodeKey(&kb, keyForCommand(.move_up).?));
    try std.testing.expectEqualStrings("\x15", s.encodeKey(&kb, ctrlKey('u').?));
    // ⇧↵ gets xterm's modifyOtherKeys form, as from Ghostty itself.
    try std.testing.expectEqualStrings("\x1b[27;2;13~", s.encodeKey(&kb, keyForCommand(.insert_line_break).?));
    try std.testing.expectEqualStrings("", s.encodeFocus(&kb, true));
    s.feed("\x1b[?1004h");
    try std.testing.expectEqualStrings("\x1b[I", s.encodeFocus(&kb, true));

    const plain = try s.encodePaste(gpa, "hi");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("hi", plain);
    s.feed("\x1b[?2004h");
    const bracketed = try s.encodePaste(gpa, "hi");
    defer gpa.free(bracketed);
    try std.testing.expectEqualStrings("\x1b[200~hi\x1b[201~", bracketed);
}

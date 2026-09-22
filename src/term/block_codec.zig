//! A session's finished blocks as text, so a tab's command history comes
//! back after a relaunch (see workspace.zig). Records, fields escaped as in
//! records.zig:
//!
//!   block <tab> done|failed <tab> exit code <tab> duration ms <tab> flags <tab> command
//!   note  <tab> text          a note shown instead of output
//!   out   <tab> line          one logical line of output, styles as SGR
//!
//! The flags are letters: `f` ran full-screen, `a` used the alternate
//! screen, `x` shown expanded, `g` an agent's reply (the output is what the
//! agent said); `-` when none. Output lines are written as the
//! terminal bytes that would have produced them and read back through the
//! same parser that built them, so colours and attributes survive. A long
//! output keeps its last `max_lines` lines, a session its newest blocks
//! within `max_bytes` (and never more than `max_blocks`); a block that is
//! still running is not written.
const std = @import("std");
const records = @import("../records.zig");
const buffer_mod = @import("buffer.zig");
const session_mod = @import("session.zig");
const Parser = @import("parser.zig").Parser;

const Session = session_mod.Session;
const Block = session_mod.Block;

pub const max_lines: usize = 2000;
pub const max_blocks: usize = 200;
pub const max_bytes: usize = 1 << 20;

pub fn write(session: *const Session, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const blocks = session.blocks.items;
    // Newest first until the budget is spent (the newest always fits), then
    // written oldest to newest so they read back in order.
    var first = blocks.len;
    var budget: usize = max_bytes;
    var kept: usize = 0;
    while (first > 0 and kept < max_blocks) {
        const b = blocks[first - 1];
        if (!b.finished()) {
            first -= 1;
            continue;
        }
        const size = estimate(b);
        if (kept > 0 and size > budget) break;
        budget -|= size;
        first -= 1;
        kept += 1;
    }
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (blocks[first..]) |b| {
        if (b.finished()) try writeBlock(b, out, &raw, gpa);
    }
}

/// Roughly how many bytes `writeBlock` produces.
fn estimate(b: *const Block) usize {
    var n: usize = b.command.len + 64;
    if (b.note) |note| n += note.len + 8;
    const count = b.buf.lineCount();
    for (b.buf.lines.items[count -| max_lines..count]) |line| n += line.cells.items.len + 8;
    return n;
}

fn writeBlock(b: *const Block, out: *std.ArrayList(u8), raw: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const ms: u64 = @intFromFloat(@max(0, b.duration(0)) * 1000);
    try out.print(gpa, "block\t{s}\t{d}\t{d}\t", .{ if (b.state == .failed) "failed" else "done", b.exit_code, ms });
    if (b.fullscreen) try out.append(gpa, 'f');
    if (b.used_alt_screen) try out.append(gpa, 'a');
    if (b.expanded) try out.append(gpa, 'x');
    if (b.agent) try out.append(gpa, 'g');
    if (!b.fullscreen and !b.used_alt_screen and !b.expanded and !b.agent) try out.append(gpa, '-');
    try out.append(gpa, '\t');
    try records.escape(out, gpa, b.command);
    try out.append(gpa, '\n');
    if (b.note) |note| {
        try out.appendSlice(gpa, "note\t");
        try records.escape(out, gpa, note);
        try out.append(gpa, '\n');
    }
    const count = b.buf.lineCount();
    for (b.buf.lines.items[count -| max_lines..count]) |line| {
        raw.clearRetainingCapacity();
        const cells = line.cells.items;
        // Unstyled spaces at the end of a line are padding, not content.
        var end = cells.len;
        while (end > 0 and cells[end - 1].cp == ' ' and cells[end - 1].style == 0) end -= 1;
        var current: u16 = 0;
        for (cells[0..end]) |cell| {
            if (cell.style != current) {
                current = cell.style;
                try buffer_mod.appendSgr(raw, gpa, b.buf.style(cell.style));
            }
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.cp, &utf8) catch continue;
            try raw.appendSlice(gpa, utf8[0..n]);
        }
        if (current != 0) try raw.appendSlice(gpa, "\x1b[m");
        try out.appendSlice(gpa, "out\t");
        try records.escape(out, gpa, raw.items);
        try out.append(gpa, '\n');
    }
}

/// Appends the blocks `write` produced to `session`, finished as they were.
pub fn read(session: *Session, data: []const u8) void {
    const gpa = session.gpa;
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(gpa);
    var current: ?*Block = null;
    var parser: Parser = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.splitScalar(u8, line, '\t');
        const tag = f.next() orelse continue;
        if (std.mem.eql(u8, tag, "block")) {
            current = null;
            const state = f.next() orelse continue;
            const exit = f.next() orelse continue;
            const ms = f.next() orelse continue;
            const flags = f.next() orelse continue;
            const command = records.unescape(&field, gpa, f.rest()) catch continue;
            const b = session.restoreBlock(command) orelse continue;
            b.state = if (std.mem.eql(u8, state, "failed")) .failed else .done;
            b.exit_code = std.fmt.parseInt(i32, exit, 10) catch 0;
            // Any base works for a finished block: only the difference shows.
            b.t_start = 1;
            b.t_end = 1 + @as(f64, @floatFromInt(std.fmt.parseInt(u64, ms, 10) catch 0)) / 1000;
            b.fullscreen = std.mem.indexOfScalar(u8, flags, 'f') != null;
            b.used_alt_screen = std.mem.indexOfScalar(u8, flags, 'a') != null;
            b.expanded = std.mem.indexOfScalar(u8, flags, 'x') != null;
            b.agent = std.mem.indexOfScalar(u8, flags, 'g') != null;
            parser = .{};
            current = b;
        } else if (std.mem.eql(u8, tag, "note")) {
            const b = current orelse continue;
            const text = records.unescape(&field, gpa, f.rest()) catch continue;
            if (b.note_owned) if (b.note) |old| gpa.free(old);
            b.note = gpa.dupe(u8, text) catch continue;
            b.note_owned = true;
        } else if (std.mem.eql(u8, tag, "out")) {
            const b = current orelse continue;
            const bytes = records.unescape(&field, gpa, f.rest()) catch continue;
            var sink = buffer_mod.Sink{ .buf = &b.buf };
            parser.feed(bytes, &sink);
            parser.feed("\r\n", &sink);
        }
    }
    if (current) |b| b.buf.resetPen();
}

// ── tests ────────────────────────────────────────────────────────────────
fn testSession() !*Session {
    return Session.create(std.testing.allocator, .{ .integration_dir = "", .user_zdotdir = "", .cwd = "/" });
}

fn fill(b: *Block, bytes: []const u8) void {
    var sink = buffer_mod.Sink{ .buf = &b.buf };
    var p = Parser{};
    p.feed(bytes, &sink);
}

test "block codec: blocks round-trip with their output, styles, notes, state and timing" {
    const gpa = std.testing.allocator;
    const s = try testSession();
    defer s.deinit();
    const a = s.restoreBlock("ls\t-la\nsecond line").?;
    fill(a, "plain \x1b[1;31mred\x1b[0m   \r\nnext\\line\x1b[38;2;1;2;3m \x1b[m\r\n");
    a.state = .done;
    a.t_start = 10;
    a.t_end = 11.5;
    a.expanded = true;
    const b = s.restoreBlock("vim").?;
    b.state = .failed;
    b.exit_code = 2;
    b.fullscreen = true;
    b.used_alt_screen = true;
    s.addNote("# hello", "a note");
    const asked = s.restoreBlock("how big is this folder").?;
    asked.agent = true;
    asked.state = .done;
    fill(asked, "du -sh .\r\n");
    const running = s.restoreBlock("sleep 9").?;
    running.state = .running;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(s, &out, gpa);
    try std.testing.expectEqualStrings(
        "block\tdone\t0\t1500\tx\tls\\t-la\\nsecond line\n" ++
            "out\tplain \\e[0;1;31mred\\e[m\n" ++
            "out\tnext\\\\line\\e[0;38;2;1;2;3m \\e[m\n" ++
            "block\tfailed\t2\t0\tfa\tvim\n" ++
            "block\tdone\t0\t0\t-\t# hello\n" ++
            "note\ta note\n" ++
            "block\tdone\t0\t0\tg\thow big is this folder\n" ++
            "out\tdu -sh .\n",
        out.items,
    );

    const t = try testSession();
    defer t.deinit();
    read(t, out.items);
    try std.testing.expectEqual(@as(usize, 4), t.blocks.items.len);
    const a2 = t.blocks.items[0];
    try std.testing.expectEqualStrings("ls\t-la\nsecond line", a2.command);
    try std.testing.expectEqual(session_mod.BlockState.done, a2.state);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), a2.duration(0), 0.001);
    try std.testing.expect(a2.expanded and !a2.fullscreen);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a2.buf.appendText(&text, gpa);
    try std.testing.expectEqualStrings("plain red\nnext\\line", text.items);
    const red = a2.buf.style(a2.buf.lines.items[0].cells.items[6].style);
    try std.testing.expect(red.bold);
    try std.testing.expectEqual(buffer_mod.indexed(1), red.fg);
    try std.testing.expectEqual(@as(u16, 0), a2.buf.lines.items[0].cells.items[5].style);
    const line2 = a2.buf.lines.items[1].cells.items;
    try std.testing.expectEqual(buffer_mod.rgb(1, 2, 3), a2.buf.style(line2[line2.len - 1].style).fg);
    const b2 = t.blocks.items[1];
    try std.testing.expectEqual(session_mod.BlockState.failed, b2.state);
    try std.testing.expectEqual(@as(i32, 2), b2.exit_code);
    try std.testing.expect(b2.fullscreen and b2.used_alt_screen and !b2.expanded);
    try std.testing.expectEqual(@as(usize, 0), b2.buf.lineCount());
    const c2 = t.blocks.items[2];
    try std.testing.expectEqualStrings("a note", c2.note.?);
    try std.testing.expect(c2.note_owned);
    const d2 = t.blocks.items[3];
    try std.testing.expect(d2.agent and !d2.expanded);
    try std.testing.expectEqual(session_mod.BlockState.done, d2.state);
    try std.testing.expectEqual(@as(u32, 5), t.next_block_id);
}

test "block codec: long outputs keep their last lines, old blocks make room for new ones" {
    const gpa = std.testing.allocator;
    const s = try testSession();
    defer s.deinit();
    const long = s.restoreBlock("seq").?;
    long.state = .done;
    var i: usize = 0;
    while (i < max_lines + 5) : (i += 1) {
        var buf: [16]u8 = undefined;
        fill(long, std.fmt.bufPrint(&buf, "{d}\r\n", .{i}) catch unreachable);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(s, &out, gpa);
    try std.testing.expectEqual(max_lines, std.mem.count(u8, out.items, "out\t"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "out\t5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "out\t4\n") == null);

    // A block bigger than the whole budget (long lines: the line cap alone
    // does not save it) pushes everything older out but is kept itself.
    const huge = s.restoreBlock("cat big").?;
    huge.state = .done;
    var line: [2002]u8 = undefined;
    @memset(&line, 'x');
    line[2000] = '\r';
    line[2001] = '\n';
    var j: usize = 0;
    while (j < max_bytes / 2000 + 1) : (j += 1) fill(huge, &line);
    out.clearRetainingCapacity();
    try write(s, &out, gpa);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "block\tdone\t0\t0\t-\tcat big\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "block\t"));
}

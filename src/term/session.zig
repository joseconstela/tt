//! One shell session: a long-lived interactive zsh on a PTY. Shell-integration
//! marks slice its output stream into command blocks.
const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Csi = @import("parser.zig").Csi;
const Buffer = @import("buffer.zig").Buffer;
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const Pty = @import("pty.zig").Pty;
const apple = @import("../apple.zig");
const sys = @import("../sys.zig");

pub const BlockState = enum { pending, running, done, failed };

/// How a failed block's "Explain" went: not asked, the agent is answering,
/// answered, or it could not answer (`explanation` then says why).
pub const ExplainState = enum { none, running, done, failed };

pub const Block = struct {
    id: u32,
    command: []u8,
    buf: Buffer,
    state: BlockState = .pending,
    exit_code: i32 = 0,
    t_start: f64 = 0,
    t_end: f64 = 0,
    /// The program took over the terminal — the alternate screen, or raw
    /// keyboard mode — and keeps the session's screen grid until it exits.
    fullscreen: bool = false,
    used_alt_screen: bool = false,
    /// A note instead of command output (e.g. "# ask in plain English").
    note: ?[]const u8 = null,
    /// The note is our own copy (read back from disk), not a string in the binary.
    note_owned: bool = false,
    /// The shell did not know a command on this line (its
    /// `command_not_found_handler` said so); with exit code 127 the line as
    /// a whole was that unknown command.
    unrecognised: bool = false,
    /// The line went to an agent (see the terminal tab): the output is the
    /// agent's reply, the state how the reply went.
    agent: bool = false,
    /// What the explain agent said about this failure ("Explain" on a
    /// failed block), shown under the output and kept across relaunches.
    explanation: std.ArrayList(u8) = .empty,
    explain_state: ExplainState = .none,
    /// Typed while another command ran: waits in `Session.queued` for its
    /// turn. `held` = a command before it failed (or was stopped), so it
    /// waits for the user to resume the queue or remove it.
    queued: bool = false,
    held: bool = false,

    // View state owned by the terminal tab.
    /// Wrapped-row index: row_starts[i] = first visual row of line i.
    row_starts: std.ArrayList(u32) = .empty,
    total_rows: u32 = 0,
    cache_cols: u32 = 0,
    cache_version: u64 = std.math.maxInt(u64),

    pub fn finished(self: *const Block) bool {
        return self.state == .done or self.state == .failed;
    }

    pub fn duration(self: *const Block, now: f64) f64 {
        if (self.t_start == 0) return 0;
        return (if (self.finished()) self.t_end else now) - self.t_start;
    }
};

/// `dormant` = no shell process yet; the first `submit` (or `spawn`) starts it.
pub const Phase = enum { dormant, starting, idle, pending, running, exited };

/// The bytes a parsed CSI came from.
fn encodeCsi(c: Csi, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("\x1b[") catch return "";
    if (c.private != 0) w.writeByte(c.private) catch return "";
    for (c.params, 0..) |p, i| {
        if (i > 0) w.writeByte(';') catch return "";
        w.print("{d}", .{p}) catch return "";
    }
    if (c.intermediate != 0) w.writeByte(c.intermediate) catch return "";
    w.writeByte(c.final) catch return "";
    return w.buffered();
}

const EarlyMode = struct { mode: u16, on: bool };

pub const Session = struct {
    gpa: std.mem.Allocator,
    pty: Pty,
    parser: Parser = .{},
    blocks: std.ArrayList(*Block) = .empty,
    current: ?*Block = null,
    phase: Phase = .starting,
    cwd: std.ArrayList(u8) = .empty,
    branch: std.ArrayList(u8) = .empty,
    bracketed_paste: bool = false,
    next_block_id: u32 = 1,
    now: f64 = 0,
    cols: u16 = 100,
    rows: u16 = 40,
    /// The terminal a full-screen program draws on (one per program).
    screen: ?*Screen = null,
    /// Size the tab gives a full-screen program (0 = not known yet).
    screen_cols: u16 = 0,
    screen_rows: u16 = 0,
    screen_cell_px: [2]u32 = .{ 1, 1 },
    screen_colors: screen_mod.Colors = .{},
    /// A finished full-screen block whose screen still has to be copied
    /// back into it, once every byte up to its "finished" mark went through.
    dump_pending: ?*Block = null,
    /// DEC private modes the running program set before it was found to
    /// own the terminal (cursor hidden, bracketed paste, mouse …); they are
    /// replayed into its screen, which never saw them.
    early_modes: std.ArrayList(EarlyMode) = .empty,
    /// Blocks waiting for their turn, oldest first (owned by `blocks`): the
    /// shell is still starting, or busy with an earlier command.
    queued: std.ArrayList(*Block) = .empty,
    integration_dir: []const u8,
    user_zdotdir: []const u8,

    pub const Options = struct {
        integration_dir: []const u8,
        user_zdotdir: []const u8,
        cwd: []const u8,
        cols: u16 = 100,
        rows: u16 = 40,
    };

    /// A session whose shell is not running yet. It behaves like an idle
    /// shell with no output; `submit` starts the process on demand.
    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .cols = opts.cols,
            .rows = opts.rows,
            .pty = .{ .gpa = gpa },
            .phase = .dormant,
            .integration_dir = opts.integration_dir,
            .user_zdotdir = opts.user_zdotdir,
        };
        try self.cwd.appendSlice(gpa, opts.cwd);
        return self;
    }

    /// A session with its shell started right away.
    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Session {
        const self = try create(gpa, opts);
        errdefer self.deinit();
        try self.spawn();
        return self;
    }

    pub fn dormant(self: *const Session) bool {
        return self.phase == .dormant;
    }

    /// Starts the shell of a dormant session (no-op otherwise).
    pub fn spawn(self: *Session) !void {
        if (self.phase != .dormant) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const overrides = [_][]const u8{
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "TERM_PROGRAM=tt",
            "TERM_PROGRAM_VERSION=0.1.0",
            "CLICOLOR=1",
            "PAGER=cat",
            "GIT_PAGER=cat",
            try std.fmt.allocPrint(arena, "ZDOTDIR={s}", .{self.integration_dir}),
            try std.fmt.allocPrint(arena, "TT_ZDOTDIR={s}", .{self.integration_dir}),
            try std.fmt.allocPrint(arena, "TT_USER_ZDOTDIR={s}", .{self.user_zdotdir}),
            // Inherited from whatever launched us; meaningless inside tt.
            "TERM_SESSION_ID",
            "__tt_loaded",
        };

        self.pty.deinit();
        self.pty = try Pty.spawn(self.gpa, .{
            .path = "/bin/zsh",
            .argv0 = "-zsh", // leading dash → login shell, like Terminal.app
            .cwd = self.cwd.items,
            .cols = self.cols,
            .rows = self.rows,
            .env_overrides = &overrides,
        });
        self.phase = .starting;
    }

    pub fn deinit(self: *Session) void {
        self.pty.deinit();
        if (self.screen) |g| g.destroy();
        self.early_modes.deinit(self.gpa);
        for (self.blocks.items) |b| self.freeBlock(b);
        self.blocks.deinit(self.gpa);
        self.queued.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.branch.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freeBlock(self: *Session, b: *Block) void {
        b.buf.deinit();
        b.row_starts.deinit(self.gpa);
        b.explanation.deinit(self.gpa);
        if (b.note_owned) if (b.note) |n| self.gpa.free(n);
        self.gpa.free(b.command);
        self.gpa.destroy(b);
    }

    pub fn clearBlocks(self: *Session) void {
        // Running and queued blocks survive a clear.
        var kept: usize = 0;
        for (self.blocks.items) |b| {
            const waiting = std.mem.indexOfScalar(*Block, self.queued.items, b) != null;
            if (b == self.current or waiting) {
                self.blocks.items[kept] = b;
                kept += 1;
            } else self.freeBlock(b);
        }
        self.blocks.items.len = kept;
    }

    /// A command is running (or about to).
    pub fn busy(self: *const Session) bool {
        return self.phase == .pending or self.phase == .running;
    }

    /// Busy, or has commands that will run without the user's say
    /// (queued ones on hold wait for it).
    pub fn working(self: *const Session) bool {
        return self.busy() or self.nextQueued() != null;
    }

    /// The queued block that runs next: the oldest not on hold.
    pub fn nextQueued(self: *const Session) ?usize {
        for (self.queued.items, 0..) |b, i| if (!b.held) return i;
        return null;
    }

    /// Queued blocks on hold after a failure.
    pub fn heldCount(self: *const Session) usize {
        var n: usize = 0;
        for (self.queued.items) |b| n += @intFromBool(b.held);
        return n;
    }

    /// Takes a queued block out of the queue and the tab before it ran;
    /// false when it is not waiting (any more).
    pub fn unqueue(self: *Session, id: u32) bool {
        const qi = for (self.queued.items, 0..) |b, i| {
            if (b.id == id) break i;
        } else return false;
        const b = self.queued.orderedRemove(qi);
        if (std.mem.indexOfScalar(*Block, self.blocks.items, b)) |bi| _ = self.blocks.orderedRemove(bi);
        self.freeBlock(b);
        return true;
    }

    /// Lets the block `id` run again, with the blocks on hold right after
    /// it in the tab (held by the same failure), in the order they were typed.
    pub fn resumeFrom(self: *Session, id: u32) void {
        const first = for (self.blocks.items, 0..) |b, i| {
            if (b.id == id) break i;
        } else return;
        for (self.blocks.items[first..]) |b| {
            if (!b.queued or !b.held) break;
            b.held = false;
        }
        self.runNext();
    }

    /// Starts the next queued block when the shell sits at its prompt.
    fn runNext(self: *Session) void {
        if (self.phase != .idle) return;
        const i = self.nextQueued() orelse return;
        self.dispatch(self.queued.orderedRemove(i));
    }

    fn newBlock(self: *Session, command: []const u8) ?*Block {
        const b = self.gpa.create(Block) catch return null;
        b.* = .{
            .id = self.next_block_id,
            .command = self.gpa.dupe(u8, command) catch {
                self.gpa.destroy(b);
                return null;
            },
            .buf = Buffer.init(self.gpa),
        };
        self.next_block_id += 1;
        self.blocks.append(self.gpa, b) catch {
            self.freeBlock(b);
            return null;
        };
        return b;
    }

    /// Adds a block that never reaches the shell (local notes).
    pub fn addNote(self: *Session, command: []const u8, note: []const u8) void {
        const b = self.newBlock(command) orelse return;
        b.note = note;
        b.state = .done;
        b.t_start = self.now;
        b.t_end = self.now;
    }

    /// Appends a block from an earlier run (see term/block_codec.zig);
    /// nothing reaches the shell. The caller fills in its state, output
    /// and timing.
    pub fn restoreBlock(self: *Session, command: []const u8) ?*Block {
        return self.newBlock(command);
    }

    /// Runs `command` in the shell as if the user had typed it. The block shows
    /// up immediately; if the shell is still starting (or busy) it waits its turn.
    pub fn submit(self: *Session, command: []const u8) void {
        if (self.phase == .exited) return;
        if (self.phase == .dormant) self.spawn() catch |err| {
            std.log.err("could not start the shell: {s}", .{@errorName(err)});
            return;
        };
        const b = self.newBlock(command) orelse return;
        b.t_start = self.now;
        // Blocks on hold do not stand in the way of a new command.
        if (self.phase == .idle and self.nextQueued() == null) {
            self.dispatch(b);
        } else {
            b.queued = true;
            self.queued.append(self.gpa, b) catch {};
        }
    }

    fn dispatch(self: *Session, b: *Block) void {
        b.queued = false;
        b.held = false;
        b.t_start = self.now;
        self.current = b;
        self.phase = .pending;
        self.early_modes.clearRetainingCapacity();
        if (self.bracketed_paste) {
            self.pty.write("\x1b[200~");
            self.pty.write(b.command);
            self.pty.write("\x1b[201~");
        } else self.pty.write(b.command);
        self.pty.write("\r");
    }

    /// Sends a line to the running program's stdin.
    pub fn sendLine(self: *Session, line: []const u8) void {
        if (self.phase == .dormant) return;
        self.pty.write(line);
        self.pty.write("\r");
    }

    pub fn sendBytes(self: *Session, bytes: []const u8) void {
        if (self.phase == .dormant) return;
        self.pty.write(bytes);
    }

    pub fn resize(self: *Session, cols: u16, rows: u16) void {
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
        self.pty.resize(cols, rows);
    }

    // ── full-screen programs ────────────────────────────────────────────
    /// The terminal a full-screen program is drawing on right now, if any.
    pub fn fullscreen(self: *const Session) ?*Screen {
        if (self.phase != .running) return null;
        const b = self.current orelse return null;
        if (!b.fullscreen) return null;
        return self.screen;
    }

    /// The size a full-screen program gets: the whole tab, in cells. While
    /// one is on screen this resizes it (and the PTY) right away.
    pub fn setScreenSize(self: *Session, cols: u16, rows: u16, cell_px: [2]u32, colors: screen_mod.Colors) void {
        self.screen_cols = cols;
        self.screen_rows = rows;
        self.screen_cell_px = cell_px;
        self.screen_colors = colors;
        if (self.fullscreen()) |g| {
            g.resize(cols, rows, cell_px);
            self.resize(cols, rows);
        }
    }

    /// Focus reporting (DEC 1004) for programs that asked for it.
    pub fn notifyFocus(self: *Session, focused: bool) void {
        const g = self.fullscreen() orelse return;
        var buf: [8]u8 = undefined;
        const seq = g.encodeFocus(&buf, focused);
        if (seq.len > 0) self.pty.write(seq);
    }

    fn writeReply(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.pty.write(bytes);
    }

    /// Hands the block's terminal to its program: from now on output goes
    /// to the grid. What the block already captured becomes the grid's
    /// starting content, as on a real terminal; the block gets it all back,
    /// with whatever the program leaves on the main screen, when it exits.
    /// `nudge` forces a redraw (SIGWINCH) even when the size does not change:
    /// a program found in raw mode may have drawn its first frame already.
    fn enterFullscreen(self: *Session, b: *Block, nudge: bool) void {
        const cols = if (self.screen_cols > 0) self.screen_cols else self.cols;
        const rows = if (self.screen_rows > 0) self.screen_rows else self.rows;
        if (self.screen) |old| old.destroy();
        self.screen = null;
        const g = Screen.create(self.gpa, .{
            .cols = cols,
            .rows = rows,
            .cell_px = self.screen_cell_px,
            .colors = self.screen_colors,
            .out = .{ .ctx = self, .write = writeReply },
        }) catch |err| {
            std.log.err("could not start a screen for the program: {s}", .{@errorName(err)});
            return;
        };
        self.screen = g;
        g.seed(&b.buf);
        for (self.early_modes.items) |m| {
            var seq: [16]u8 = undefined;
            g.feed(std.fmt.bufPrint(&seq, "\x1b[?{d}{c}", .{ m.mode, @as(u8, if (m.on) 'h' else 'l') }) catch continue);
        }
        self.early_modes.clearRetainingCapacity();
        b.buf.deinit();
        b.buf = Buffer.init(self.gpa);
        b.fullscreen = true;
        if (cols == self.cols and rows == self.rows) {
            if (nudge) {
                self.pty.resize(cols, rows + 1);
                self.pty.resize(cols, rows);
            }
        } else self.resize(cols, rows);
    }

    /// Drains the PTY. Returns true if anything visible changed.
    pub fn poll(self: *Session, now: f64) bool {
        self.now = now;
        if (self.phase == .exited or self.phase == .dormant) return false;
        self.pty.flush();
        var changed = false;
        // Sampled before reading. If the tty is in raw mode now and the
        // command is still running once everything pending has been read,
        // the program put it there — not zsh's line editor, which only turns
        // raw mode on after writing the "finished" mark that this read would
        // have delivered.
        const raw_before = self.phase == .running and self.current != null and !self.current.?.fullscreen and self.pty.rawMode();
        var drained = false;
        var buf: [16 * 1024]u8 = undefined;
        // The kernel's PTY buffer is only a few KB, so a program printing a lot
        // stalls until we read. While data is flowing we therefore keep draining
        // for a short time slice instead of taking one gulp per tick.
        const slice_start = apple.CACurrentMediaTime();
        const slice: f64 = 0.004;
        var dry_spins: u32 = 0;
        while (true) {
            switch (self.pty.read(&buf)) {
                .data => |n| {
                    self.consume(buf[0..n]);
                    changed = true;
                    dry_spins = 0;
                    if (apple.CACurrentMediaTime() - slice_start > slice) break;
                },
                .again => {
                    drained = true;
                    if (!changed) break; // idle: never spin
                    dry_spins += 1;
                    if (dry_spins > 6 or apple.CACurrentMediaTime() - slice_start > slice) break;
                    _ = sys.usleep(120);
                },
                .closed => {
                    self.finishCurrent(-1);
                    self.completeDump();
                    self.phase = .exited;
                    _ = self.pty.reap();
                    return true;
                },
            }
        }
        if (raw_before and drained and self.phase == .running) {
            if (self.current) |b| if (!b.fullscreen) {
                self.enterFullscreen(b, true);
                changed = true;
            };
        }
        self.completeDump();
        return changed;
    }

    /// Runs the bytes through our parser (marks, block output) and, for
    /// the stretches during which a full-screen program owns the terminal,
    /// through its screen as well. The split is exact to the byte: the
    /// screen sees everything up to the program's "finished" mark and
    /// nothing of the prompt that follows it.
    fn consume(self: *Session, bytes: []const u8) void {
        var seg_start: ?usize = if (self.fullscreen() != null) 0 else null;
        for (bytes, 0..) |b, i| {
            self.parser.step(b, self);
            const fs = self.fullscreen() != null;
            if (seg_start) |from| {
                if (!fs) {
                    self.feedScreen(bytes[from .. i + 1]);
                    self.completeDump();
                    seg_start = null;
                }
            } else if (fs) seg_start = i + 1;
        }
        if (seg_start) |from| if (from < bytes.len) self.feedScreen(bytes[from..]);
    }

    fn feedScreen(self: *Session, bytes: []const u8) void {
        if (self.screen) |g| g.feed(bytes);
    }

    /// Copies a finished program's main screen into its block.
    fn completeDump(self: *Session) void {
        const b = self.dump_pending orelse return;
        self.dump_pending = null;
        if (self.screen) |g| g.dumpMain(&b.buf);
    }

    fn finishCurrent(self: *Session, code: i32) void {
        const b = self.current orelse return;
        // The program's last main screen (plus what scrolled off it) is what
        // a terminal would leave behind: it becomes the block's output, once
        // the bytes up to this mark have reached the screen (see `consume`).
        if (b.fullscreen) self.dump_pending = b;
        b.exit_code = code;
        b.t_end = self.now;
        b.state = if (code == 0) .done else .failed;
        self.current = null;
    }

    fn capturing(self: *const Session) ?*Block {
        if (self.phase != .running) return null;
        const b = self.current orelse return null;
        if (b.fullscreen) return null;
        return b;
    }

    // ── parser handler ──────────────────────────────────────────────────
    // While a full-screen program runs, its screen parses the raw bytes
    // itself (see `consume`); this parser only keeps watching for marks.
    pub fn print(self: *Session, cp: u21) void {
        if (self.capturing()) |b| b.buf.print(cp);
    }

    pub fn execute(self: *Session, ch: u8) void {
        if (self.capturing()) |b| b.buf.execute(ch);
    }

    pub fn esc(_: *Session, _: u8, _: u8) void {}

    pub fn csi(self: *Session, c: Csi) void {
        if (c.private == '?' and (c.final == 'h' or c.final == 'l')) {
            const on = c.final == 'h';
            if (self.capturing() != null) {
                for (c.params) |p| {
                    if (p == 47 or p == 1047 or p == 1049) continue;
                    for (self.early_modes.items) |*m| {
                        if (m.mode == p) {
                            m.on = on;
                            break;
                        }
                    } else self.early_modes.append(self.gpa, .{ .mode = p, .on = on }) catch {};
                }
            }
            for (c.params) |p| switch (p) {
                2004 => self.bracketed_paste = on,
                47, 1047, 1049 => if (on) if (self.current) |b| {
                    if (self.phase == .running) {
                        b.used_alt_screen = true;
                        if (!b.fullscreen) {
                            self.enterFullscreen(b, false);
                            // The switch itself never reached the new screen: replay it.
                            var seq: [96]u8 = undefined;
                            if (self.fullscreen()) |g| g.feed(encodeCsi(c, &seq));
                        }
                    }
                },
                else => {},
            };
            return;
        }
        // A full-screen program's screen answers its queries itself.
        if (self.fullscreen() != null) return;
        // Answer the queries prompt themes tend to block on.
        if (c.private == 0 and c.final == 'n' and c.param(0, 0) == 6) {
            self.pty.write("\x1b[1;1R");
            return;
        }
        if (c.private == 0 and c.final == 'n' and c.param(0, 0) == 5) {
            self.pty.write("\x1b[0n");
            return;
        }
        if (c.final == 'c' and c.intermediate == 0) {
            if (c.private == 0) self.pty.write("\x1b[?62;22c");
            if (c.private == '>') self.pty.write("\x1b[>0;10;1c");
            return;
        }
        if (self.capturing()) |b| b.buf.csi(c);
    }

    pub fn osc(self: *Session, data: []const u8) void {
        if (std.mem.startsWith(u8, data, "133;")) {
            const rest = data[4..];
            if (rest.len == 0) return;
            switch (rest[0]) {
                'C' => if (self.phase == .pending) {
                    self.phase = .running;
                    if (self.current) |b| {
                        b.state = .running;
                        b.t_start = self.now;
                        b.buf.resetPen();
                    }
                },
                'D' => {
                    var code: i32 = 0;
                    if (rest.len > 2) code = std.fmt.parseInt(i32, rest[2..], 10) catch 0;
                    if (self.busy()) {
                        self.finishCurrent(code);
                        // What was typed after a command that failed (or was
                        // stopped) was meant for its success: it waits.
                        if (code != 0) for (self.queued.items) |b| {
                            b.held = true;
                        };
                    }
                    self.phase = .idle;
                },
                'A' => {
                    if (self.phase == .starting) self.phase = .idle;
                    self.runNext();
                },
                else => {},
            }
        } else if (std.mem.startsWith(u8, data, "7777;cwd;")) {
            self.cwd.clearRetainingCapacity();
            self.cwd.appendSlice(self.gpa, data[9..]) catch {};
        } else if (std.mem.startsWith(u8, data, "7777;branch;")) {
            self.branch.clearRetainingCapacity();
            self.branch.appendSlice(self.gpa, data[12..]) catch {};
        } else if (std.mem.startsWith(u8, data, "7777;cnf;")) {
            // The shell's command_not_found_handler ran for the current line.
            if (self.busy()) if (self.current) |b| {
                b.unrecognised = true;
            };
        }
    }
};

test "session: commands typed while one runs wait their turn; a failure holds them" {
    const gpa = std.testing.allocator;
    const s = try Session.create(gpa, .{ .integration_dir = "", .user_zdotdir = "", .cwd = "/" });
    defer s.deinit();
    // A shell at its prompt (no process: the PTY only buffers what is sent).
    s.phase = .idle;

    s.submit("make");
    try std.testing.expect(s.busy());
    s.submit("make test");
    s.submit("deploy");
    try std.testing.expectEqual(@as(usize, 2), s.queued.items.len);
    try std.testing.expect(s.queued.items[0].queued and !s.queued.items[0].held);

    // "make" succeeds: "make test" goes as soon as the prompt is back.
    s.osc("133;C");
    s.osc("133;D;0");
    s.osc("133;A");
    try std.testing.expectEqualStrings("make test", s.current.?.command);
    try std.testing.expect(!s.current.?.queued);

    // "make test" fails: "deploy" waits for the user.
    s.osc("133;C");
    s.osc("133;D;2");
    s.osc("133;A");
    try std.testing.expect(s.current == null);
    try std.testing.expect(s.queued.items[0].held);
    try std.testing.expectEqual(@as(usize, 1), s.heldCount());
    try std.testing.expect(!s.working());

    // A new command runs right away; what is on hold stays there.
    s.submit("git status");
    try std.testing.expectEqualStrings("git status", s.current.?.command);
    s.submit("ls");
    s.osc("133;C");
    s.osc("133;D;0");
    s.osc("133;A");
    try std.testing.expectEqualStrings("ls", s.current.?.command);
    s.osc("133;C");
    s.osc("133;D;0");
    s.osc("133;A");
    try std.testing.expect(s.current == null);

    // Resumed, the held command runs; a removed one never does.
    s.submit("sleep 1");
    s.submit("echo removed");
    const removed_id = s.queued.items[s.queued.items.len - 1].id;
    const blocks_before = s.blocks.items.len;
    try std.testing.expect(s.unqueue(removed_id));
    try std.testing.expect(!s.unqueue(removed_id));
    try std.testing.expectEqual(blocks_before - 1, s.blocks.items.len);
    s.osc("133;C");
    s.osc("133;D;0");
    s.osc("133;A");
    try std.testing.expect(s.current == null); // "deploy" is still on hold
    s.resumeFrom(s.queued.items[0].id);
    try std.testing.expectEqualStrings("deploy", s.current.?.command);
    try std.testing.expectEqual(@as(usize, 0), s.queued.items.len);
}

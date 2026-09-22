//! The terminal tab: a chat-like column of command blocks above an input box.
//! Commands run for real in a persistent zsh (see term/session.zig). Opened
//! with `start_shell = false` the tab is a blank "New" tab: the shell only
//! starts when the user presses ↵ or submits a command.
const std = @import("std");
const tab_mod = @import("tab.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const gfx_text = @import("../gfx/text.zig");
const session_mod = @import("../term/session.zig");
const buffer_mod = @import("../term/buffer.zig");
const screen_mod = @import("../term/screen.zig");
const boxdraw = @import("../gfx/boxdraw.zig");
const Editor = @import("../input/editor.zig").Editor;
const complete = @import("../input/complete.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");
const block_codec = @import("../term/block_codec.zig");
const agent = @import("../agent.zig");
const config = @import("../config.zig");
const settings_features = @import("settings_features.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Session = session_mod.Session;
const Block = session_mod.Block;
const Buffer = buffer_mod.Buffer;

const collapse_threshold: u32 = 30;
const collapsed_rows: u32 = 24;
const line_h = theme.output_line_h;
const input_row_h: f32 = 23;
const hint_h: f32 = 19;

const note_no_agent = "No agent takes plain-English lines yet: pick one under Settings › AI › Features.";
const note_empty_question = "Put the question after the #.";
const note_no_answer = "The agent sent no answer.";
/// What a question carries along: the tab's earlier turns — commands with
/// their output and exit codes, questions with their answers — the newest
/// within these budgets, so a small local model's context is not overrun.
/// Of a block's output, its last lines.
const max_context_bytes: usize = 32 * 1024;
const max_transcript_bytes: usize = 16 * 1024;
const max_output_lines: usize = 60;
const max_output_bytes: usize = 4 * 1024;

/// An agent's reply on its way into a block.
const Pending = struct { block_id: u32, req: *agent.Request };
const note_fullscreen = "Ran full-screen; it left nothing on the screen when it ended.";

pub const TerminalTab = struct {
    pub const kind_label = "Terminal";

    gpa: std.mem.Allocator,
    env: *tab_mod.Env,
    session: *Session,
    editor: Editor,

    /// Distance scrolled up from the newest block (0 = pinned to the bottom).
    scroll: f32 = 0,
    content_h: f32 = 0,

    suggestion: std.ArrayList(u8) = .empty,
    suggestion_for: u64 = std.math.maxInt(u64),

    hist_index: ?usize = null,
    hist_prefix: std.ArrayList(u8) = .empty,

    now: f64 = 0,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    seen_version: u64 = 0,
    timer_tick: i64 = 0,
    is_active: bool = true,
    unseen_failure: bool = false,
    last_block_checked: u32 = 0,
    rerun: ?[]u8 = null,
    closing: bool = false,
    /// Action button clicked during the current block's draw.
    clicked_id: u64 = 0,
    /// Distinguishes this tab's widgets from other terminal tabs'.
    wid_salt: usize = 0,
    /// Replies still coming in from the agent (see `ask`).
    pending: std.ArrayList(Pending) = .empty,
    /// The command last put in the input box by the agent, so a newer
    /// proposal may replace it but never what the user typed.
    last_proposal: ?[]u8 = null,

    // Input geometry from the last frame (for hit testing and the IME).
    text_x: f32 = 0,
    text_y: f32 = 0,
    text_cols: usize = 80,
    cell_w: f32 = 9,
    caret: Rect = .{},

    // Text selection inside a block's output (block id 0 = none).
    sel_block: u32 = 0,
    sel_anchor: Pos = .{},
    sel_head: Pos = .{},
    sel_by_drag: bool = false,

    // While a full-screen program has the tab.
    was_focused: bool = true,
    mouse_down: bool = false,
    last_mouse: [2]f32 = .{ -1, -1 },
    /// Wheel movement not yet turned into whole rows of history.
    scroll_px: f32 = 0,

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(TerminalTab);
        errdefer env.gpa.destroy(self);
        const opts: Session.Options = .{
            .integration_dir = env.integration_dir,
            .user_zdotdir = env.user_zdotdir,
            .cwd = args.cwd orelse env.launch_cwd,
        };
        self.* = .{
            .gpa = env.gpa,
            .env = env,
            .wid_salt = @intFromPtr(self),
            .editor = Editor.init(env.gpa),
            .session = if (args.start_shell) try Session.start(env.gpa, opts) else try Session.create(env.gpa, opts),
        };
        if (args.saved) |saved| {
            // The blocks of an earlier run; their failures were seen back then.
            block_codec.read(self.session, saved);
            const blocks = self.session.blocks.items;
            if (blocks.len > 0) self.last_block_checked = blocks[blocks.len - 1].id;
        }
        return tab_mod.Tab.from(TerminalTab, self);
    }

    pub fn deinit(self: *TerminalTab) void {
        for (self.pending.items) |p| p.req.release();
        self.pending.deinit(self.gpa);
        if (self.last_proposal) |p| self.gpa.free(p);
        self.session.deinit();
        self.editor.deinit();
        self.suggestion.deinit(self.gpa);
        self.hist_prefix.deinit(self.gpa);
        if (self.rerun) |r| self.gpa.free(r);
        self.gpa.destroy(self);
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *TerminalTab, buf: []u8) []const u8 {
        if (self.session.dormant() and self.session.blocks.items.len == 0) return "New tab";
        // A full-screen program that names its window (vim, htop …).
        if (self.session.fullscreen()) |scr| {
            if (scr.title()) |t| if (t.len > 0) {
                const n = @min(t.len, buf.len);
                @memcpy(buf[0..n], t[0..n]);
                return buf[0..n];
            };
        }
        if (self.session.current) |b| {
            if (self.session.busy()) {
                const first_line = b.command[0 .. std.mem.indexOfScalar(u8, b.command, '\n') orelse b.command.len];
                return first_line;
            }
        }
        // An agent still answering: the question, like a running command.
        if (self.pending.items.len > 0) {
            if (self.blockById(self.pending.items[0].block_id)) |b| {
                return b.command[0 .. std.mem.indexOfScalar(u8, b.command, '\n') orelse b.command.len];
            }
        }
        const dir = self.session.cwd.items;
        if (dir.len > 0 and !std.mem.eql(u8, dir, self.env.launch_cwd)) {
            if (std.mem.eql(u8, dir, sys.home())) return "~";
            const base = dir[if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| i + 1 else 0..];
            if (base.len > 0 and base.len <= buf.len) {
                @memcpy(buf[0..base.len], base);
                return buf[0..base.len];
            }
        }
        return kind_label;
    }

    pub fn status(self: *TerminalTab) tab_mod.Status {
        if (self.session.working() or self.pending.items.len > 0) return .running;
        if (self.unseen_failure) return .failed;
        return .none;
    }

    /// Context line in the tab strip: the git branch when there is one. The
    /// working directory is deliberately not shown here.
    pub fn info(self: *TerminalTab, buf: []u8) []const u8 {
        if (self.session.branch.items.len > 0) {
            return std.fmt.bufPrint(buf, "on branch {s}", .{self.session.branch.items}) catch "";
        }
        return "";
    }

    /// Where the shell is (or, before it starts, where it will start).
    pub fn cwd(self: *TerminalTab) []const u8 {
        return self.session.cwd.items;
    }

    pub fn wantsClose(self: *TerminalTab) bool {
        return self.closing or self.session.phase == .exited;
    }

    /// Why closing needs a confirmation: a command still running (or queued),
    /// or typed input that was never run.
    pub fn closeWarning(self: *TerminalTab, _: []u8) ?[]const u8 {
        if (self.session.working() or self.rerun != null) return "A command is still running; closing the tab will stop it.";
        if (!self.editor.isEmpty()) return "The command input has text you haven't run; it will be lost.";
        return null;
    }

    /// The finished blocks, output and all (see term/block_codec.zig); the
    /// shell itself starts again when the restored tab is first used.
    pub fn save(self: *TerminalTab, out: *std.ArrayList(u8)) bool {
        block_codec.write(self.session, out, self.gpa) catch return false;
        return true;
    }

    pub fn saveVersion(self: *TerminalTab) u64 {
        var h = std.hash.Wyhash.init(0);
        for (self.session.blocks.items) |b| {
            if (!b.finished()) continue;
            h.update(std.mem.asBytes(&b.id));
            h.update(std.mem.asBytes(&b.buf.version));
            h.update(std.mem.asBytes(&b.exit_code));
            h.update(&[_]u8{ @intFromEnum(b.state), @intFromBool(b.expanded) });
        }
        return h.final();
    }

    pub fn tick(self: *TerminalTab, now: f64, active: bool) bool {
        self.now = now;
        var redraw = self.session.poll(now);
        if (self.handOff()) redraw = true;
        if (self.pollAgents()) redraw = true;

        if (active and !self.is_active) self.unseen_failure = false;
        self.is_active = active;
        if (self.session.blocks.items.len > 0) {
            const last = self.session.blocks.items[self.session.blocks.items.len - 1];
            if (last.finished() and last.id != self.last_block_checked) {
                self.last_block_checked = last.id;
                if (last.state == .failed and !active) self.unseen_failure = true;
                redraw = true;
            }
        }
        if (!active) return redraw;

        // Live duration label while a command runs.
        if (self.session.busy()) {
            const t: i64 = @intFromFloat(now * 10);
            if (t != self.timer_tick) {
                self.timer_tick = t;
                redraw = true;
            }
        }
        // Caret blink.
        if (self.editor.version != self.seen_version) {
            self.seen_version = self.editor.version;
            self.blink_t0 = now;
        }
        const on = theme.caretOn(now, self.blink_t0);
        if (on != self.blink_on) {
            self.blink_on = on;
            redraw = true;
        }
        return redraw;
    }

    // ── input events ────────────────────────────────────────────────────
    pub fn onText(self: *TerminalTab, utf8: []const u8) void {
        if (self.session.fullscreen()) |scr| {
            scr.scrollToBottom();
            self.session.sendBytes(utf8);
            return;
        }
        self.editor.insert(utf8);
        self.hist_index = null;
    }

    pub fn onMarkedText(self: *TerminalTab, utf8: []const u8) void {
        self.editor.setMarked(utf8);
    }

    pub fn hasMarkedText(self: *TerminalTab) bool {
        return self.editor.marked.items.len > 0;
    }

    pub fn caretRect(self: *TerminalTab) Rect {
        return self.caret;
    }

    pub fn paste(self: *TerminalTab, utf8: []const u8) void {
        if (self.session.fullscreen()) |scr| {
            // Bracketed when the program asked; control bytes stripped.
            const bytes = scr.encodePaste(self.gpa, utf8) catch return;
            defer self.gpa.free(bytes);
            scr.scrollToBottom();
            self.session.sendBytes(bytes);
            return;
        }
        // Normalise line endings; a trailing newline would auto-run the command.
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.gpa);
        for (utf8) |ch| {
            if (ch == '\r') continue;
            clean.append(self.gpa, ch) catch return;
        }
        const trimmed = std.mem.trimEnd(u8, clean.items, "\n");
        self.editor.insert(trimmed);
        self.hist_index = null;
    }

    pub fn copy(self: *TerminalTab, out: *std.ArrayList(u8), cut: bool) bool {
        if (self.session.fullscreen() != null) return false;
        const sel = self.editor.selectedText();
        if (sel.len > 0) {
            out.appendSlice(self.gpa, sel) catch return false;
            if (cut) _ = self.editor.deleteSelection();
            return true;
        }
        return self.copyOutputSelection(out);
    }

    /// Appends the text selected in a block's output.
    fn copyOutputSelection(self: *TerminalTab, out: *std.ArrayList(u8)) bool {
        if (self.sel_block == 0) return false;
        const range = orderSelection(self.sel_anchor, self.sel_head) orelse return false;
        const block = for (self.session.blocks.items) |b| {
            if (b.id == self.sel_block) break b;
        } else return false;
        const lines = block.buf.lines.items;
        var line = range[0].line;
        while (line <= range[1].line and line < lines.len) : (line += 1) {
            const cells = lines[line].cells.items;
            const from = if (line == range[0].line) @min(range[0].cell, cells.len) else 0;
            var to = if (line == range[1].line) @min(range[1].cell, cells.len) else cells.len;
            // Padding the program added to the right of a line is not content.
            if (line != range[1].line or to == cells.len) {
                while (to > from and cells[to - 1].cp == ' ') to -= 1;
            }
            for (cells[from..to]) |cell| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                out.appendSlice(self.gpa, buf[0..n]) catch return false;
            }
            if (line != range[1].line) out.append(self.gpa, '\n') catch return false;
        }
        return out.items.len > 0;
    }

    pub fn onCtrl(self: *TerminalTab, key: u8) void {
        if (self.session.fullscreen()) |scr| {
            if (screen_mod.ctrlKey(key)) |event| self.sendKey(scr, event);
            return;
        }
        const busy = self.session.busy();
        switch (key) {
            'c' => if (busy) self.session.sendBytes("\x03") else if (self.pending.items.len > 0) self.stopAgents() else {
                self.editor.clear();
                self.hist_index = null;
            },
            'd' => if (busy) self.session.sendBytes("\x04") else if (self.editor.isEmpty()) {
                self.closing = true;
            } else {
                _ = self.editor.apply(.delete_forward);
            },
            'l' => self.session.clearBlocks(),
            'a' => _ = self.editor.apply(.move_line_start),
            'e' => _ = self.editor.apply(.move_line_end),
            'b' => _ = self.editor.apply(.move_left),
            'f' => self.onEdit(.move_right),
            'k' => _ = self.editor.apply(.delete_to_line_end),
            'u' => _ = self.editor.apply(.delete_to_line_start),
            'w' => _ = self.editor.apply(.delete_word_backward),
            'h' => _ = self.editor.apply(.delete_backward),
            'p' => self.onEdit(.move_up),
            'n' => self.onEdit(.move_down),
            else => if (busy and key >= 'a' and key <= 'z') {
                // Forward the raw control byte (^Z, ^\ …) to the program.
                self.session.sendBytes(&.{key - 'a' + 1});
            } else if (busy and key == '\\') {
                self.session.sendBytes("\x1c");
            },
        }
    }

    pub fn onEdit(self: *TerminalTab, cmd: EditCommand) void {
        if (self.session.fullscreen()) |scr| {
            if (screen_mod.keyForCommand(cmd)) |event| self.sendKey(scr, event);
            return;
        }
        switch (cmd) {
            .insert_newline => self.submit(),
            .insert_tab => {
                if (!self.acceptSuggestion() and self.session.busy()) self.session.sendBytes("\t");
            },
            .move_right, .move_line_end => {
                if (self.editor.atEnd() and self.editor.selection() == null and self.acceptSuggestion()) return;
                _ = self.editor.apply(cmd);
            },
            .move_up => if (!self.editor.apply(.move_up)) self.historyStep(true),
            .move_down => if (!self.editor.apply(.move_down)) self.historyStep(false),
            .cancel => {
                self.suggestion.clearRetainingCapacity();
                self.suggestion_for = self.editor.version;
                self.editor.anchor = null;
            },
            .page_up => self.scroll += 320,
            .page_down => self.scroll = @max(0, self.scroll - 320),
            .scroll_to_top => self.scroll = self.content_h,
            .scroll_to_bottom => self.scroll = 0,
            else => {
                _ = self.editor.apply(cmd);
                if (cmd != .select_all) self.hist_index = null;
            },
        }
    }

    /// A key for the full-screen program, encoded the way its modes ask.
    fn sendKey(self: *TerminalTab, scr: *screen_mod.Screen, event: screen_mod.KeyEvent) void {
        var buf: [64]u8 = undefined;
        const seq = scr.encodeKey(&buf, event);
        if (seq.len == 0) return;
        scr.scrollToBottom();
        self.session.sendBytes(seq);
    }

    fn submit(self: *TerminalTab) void {
        const text = self.editor.bytes();
        if (self.session.busy()) {
            // While a program runs, the box feeds its stdin.
            self.session.sendLine(text);
            self.editor.clear();
            return;
        }
        const cmd = std.mem.trim(u8, text, " \t\n");
        if (cmd.len == 0) {
            // ↵ on an empty box is how a "New" tab becomes a shell.
            if (self.session.dormant()) self.session.spawn() catch |err| {
                std.log.err("could not start the shell: {s}", .{@errorName(err)});
            };
            return;
        }
        self.run(cmd);
        self.editor.clear();
    }

    fn run(self: *TerminalTab, cmd: []const u8) void {
        self.env.history.add(cmd);
        self.hist_index = null;
        self.scroll = 0;
        if (std.mem.eql(u8, cmd, "clear")) {
            self.session.clearBlocks();
        } else if (cmd[0] == '#') {
            self.askQuestion(cmd);
        } else self.session.submit(cmd);
    }

    // ── the agent ───────────────────────────────────────────────────────
    // A line the shell does not know (its command_not_found_handler ran and
    // the line failed with 127) or a `# question` goes to the agent chosen
    // under Settings › AI › Features. The block becomes the conversation's
    // turn: the reply streams into its output, the earlier turns of the tab
    // go along as context.

    /// A `# question` never reaches the shell.
    fn askQuestion(self: *TerminalTab, cmd: []const u8) void {
        const question = questionOf(cmd);
        if (question.len == 0) {
            self.session.addNote(cmd, note_empty_question);
            return;
        }
        if (config.get().features.command_fallback_agent == null) {
            self.session.addNote(cmd, note_no_agent);
            return;
        }
        const b = self.session.restoreBlock(cmd) orelse return;
        self.ask(b, question);
    }

    /// Blocks the shell just finished on a command it did not know go to
    /// the agent, when one is set. A line that ran on despite an unknown
    /// command in it (`foo; ls`, `foo | grep x`) stays a shell block.
    fn handOff(self: *TerminalTab) bool {
        var changed = false;
        for (self.session.blocks.items) |b| {
            if (!b.unrecognised or !b.finished() or b.agent) continue;
            b.unrecognised = false;
            if (b.exit_code != 127) continue;
            if (config.get().features.command_fallback_agent == null) continue;
            self.ask(b, b.command);
            changed = true;
        }
        return changed;
    }

    /// Turns `b` into an agent block and sends `question`; what the shell
    /// printed into it is dropped.
    fn ask(self: *TerminalTab, b: *Block, question: []const u8) void {
        b.agent = true;
        b.unrecognised = false;
        b.buf.deinit();
        b.buf = Buffer.init(self.gpa);
        b.cache_version = std.math.maxInt(u64);
        self.clearNote(b);
        b.state = .running;
        b.exit_code = 0;
        b.t_start = self.now;
        b.t_end = 0;
        b.expanded = false;
        if (self.sel_block == b.id) self.sel_block = 0;

        const cfg = config.get();
        const name = cfg.features.command_fallback_agent orelse {
            self.failAgent(b, note_no_agent);
            return;
        };
        const a = cfg.findAgentByName(name) orelse {
            self.failAgent(b, "The agent chosen under Settings › AI › Features is no longer set up.");
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const system = self.systemPrompt(arena) catch "";
        var messages: std.ArrayList(agent.Message) = .empty;
        self.conversation(arena, &messages, b, question) catch {
            self.failAgent(b, "Out of memory.");
            return;
        };
        var prepared = agent.prepare(self.gpa, a, system, messages.items, .{ .tools = true }) catch |err| {
            var buf: [256]u8 = undefined;
            const why: []const u8 = switch (err) {
                error.NoModel => std.fmt.bufPrint(&buf, "The agent “{s}” has no model set (Settings › AI › Agents).", .{a.name}) catch "The agent has no model set.",
                error.NoApiKey => std.fmt.bufPrint(&buf, "The agent “{s}” needs an API key (Settings › AI › Agents).", .{a.name}) catch "The agent needs an API key.",
                error.NoBaseUrl => std.fmt.bufPrint(&buf, "The agent “{s}” has no base URL (Settings › AI › Agents).", .{a.name}) catch "The agent has no base URL.",
                error.OutOfMemory => "Out of memory.",
            };
            self.failAgent(b, why);
            return;
        };
        defer prepared.deinit(self.gpa);
        const req = agent.Request.start(&prepared) catch {
            self.failAgent(b, "Out of memory.");
            return;
        };
        self.pending.append(self.gpa, .{ .block_id = b.id, .req = req }) catch {
            req.release();
            self.failAgent(b, "Out of memory.");
        };
    }

    /// Moves what the agents sent so far into their blocks and settles the
    /// replies that are over; true when anything changed.
    fn pollAgents(self: *TerminalTab) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            const b = self.blockById(p.block_id) orelse {
                // The block was cleared away meanwhile.
                p.req.release();
                _ = self.pending.swapRemove(i);
                continue;
            };
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(self.gpa);
            var proposals: std.ArrayList([]u8) = .empty;
            defer {
                for (proposals.items) |c| self.gpa.free(c);
                proposals.deinit(self.gpa);
            }
            var err: std.ArrayList(u8) = .empty;
            defer err.deinit(self.gpa);
            const outcome = p.req.take(&text, &proposals, &err, self.gpa);
            if (text.items.len > 0) {
                appendReply(b, text.items);
                changed = true;
            }
            for (proposals.items) |cmd| {
                self.propose(b, cmd);
                changed = true;
            }
            switch (outcome) {
                .running => i += 1,
                .done => {
                    b.state = .done;
                    b.t_end = self.now;
                    if (b.buf.isEmpty()) self.setNote(b, note_no_answer);
                    p.req.release();
                    _ = self.pending.swapRemove(i);
                    changed = true;
                },
                .failed => {
                    self.failAgent(b, err.items);
                    p.req.release();
                    _ = self.pending.swapRemove(i);
                    changed = true;
                },
            }
        }
        agent.Request.reap();
        return changed;
    }

    /// ⌃C while a reply is coming in stops it; the block keeps what arrived.
    fn stopAgents(self: *TerminalTab) void {
        for (self.pending.items) |p| p.req.cancel();
    }

    /// A command the agent proposed: on its own line in the block and,
    /// unless the user is typing something else, in the input box, where
    /// it waits for ↵ (a newer proposal replaces an earlier one there).
    /// Nothing runs by itself.
    fn propose(self: *TerminalTab, b: *Block, cmd: []const u8) void {
        if (b.buf.col > 0) {
            b.buf.carriageReturn();
            b.buf.lineFeed();
        }
        b.buf.setPen(.{ .bold = true });
        appendReply(b, "→ ");
        appendReply(b, cmd);
        b.buf.resetPen();
        b.buf.carriageReturn();
        b.buf.lineFeed();
        const box = self.editor.bytes();
        const ours = if (self.last_proposal) |p| std.mem.eql(u8, box, p) else false;
        if (box.len == 0 or ours) {
            self.editor.clear();
            self.editor.insert(cmd);
            self.hist_index = null;
            if (self.last_proposal) |p| self.gpa.free(p);
            self.last_proposal = self.gpa.dupe(u8, cmd) catch null;
        }
    }

    /// The reply ends here without an answer, or short of one.
    fn failAgent(self: *TerminalTab, b: *Block, why: []const u8) void {
        b.state = .failed;
        b.t_end = self.now;
        // Whatever arrived stays; the reason shows when nothing did.
        if (b.buf.isEmpty()) self.setNote(b, why);
    }

    /// Adds reply text to a block's output: line breaks and tabs as the
    /// terminal would show them, other control bytes dropped.
    fn appendReply(b: *Block, text: []const u8) void {
        const view = std.unicode.Utf8View.init(text) catch {
            for (text) |c| putReply(b, if (c < 0x80) c else '?');
            return;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| putReply(b, cp);
    }

    fn putReply(b: *Block, cp: u21) void {
        switch (cp) {
            '\n' => {
                b.buf.carriageReturn();
                b.buf.lineFeed();
            },
            '\t' => b.buf.tab(),
            '\r' => {},
            else => if (cp >= 0x20 and cp != 0x7f) b.buf.print(cp),
        }
    }

    /// What the agent is told before the conversation: the prompt from
    /// Settings › AI › Features (or the default), then where the user is.
    fn systemPrompt(self: *TerminalTab, arena: std.mem.Allocator) ![]u8 {
        const own = config.get().features.command_fallback_prompt;
        const prompt = if (std.mem.trim(u8, own, " \t\r\n").len == 0) settings_features.default_prompt else own;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, prompt);
        try out.print(arena, "\n\nContext: the user is in a terminal on macOS running zsh, in the directory {s}", .{self.session.cwd.items});
        if (self.session.branch.items.len > 0) try out.print(arena, " (git branch {s})", .{self.session.branch.items});
        try out.appendSlice(arena, ". The messages carry a transcript of that terminal: the commands run so far, what they printed (stdout and stderr together, as the terminal showed them) and how they ended; read it before answering. When a command would do what the user wants, call propose_command with it: it lands in the user's input box for them to check and run, so never assume it ran and never make up its output; say in a line what it does. Answer in plain text for a monospaced terminal: no Markdown headings or tables, short lines.");
        return out.toOwnedSlice(arena);
    }

    /// The conversation as the agent sees it: the tab's earlier turns,
    /// oldest first — every shell block joins the terminal transcript that
    /// the next question carries, every answered question is a turn of its
    /// own — then `question`; the newest turns within the budgets.
    fn conversation(self: *TerminalTab, arena: std.mem.Allocator, out: *std.ArrayList(agent.Message), current: *Block, question: []const u8) !void {
        const Turn = struct { user: []const u8, answer: []const u8 };
        var turns: std.ArrayList(Turn) = .empty;
        var transcript: std.ArrayList([]const u8) = .empty;
        for (self.session.blocks.items) |b| {
            if (b == current or !b.finished()) continue;
            if (!b.agent) {
                try transcript.append(arena, try blockTranscript(arena, b));
                continue;
            }
            if (b.state != .done or b.buf.isEmpty()) continue;
            var text: std.ArrayList(u8) = .empty;
            try b.buf.appendText(&text, arena);
            const answer = std.mem.trim(u8, text.items, " \n");
            if (answer.len == 0) continue;
            try turns.append(arena, .{ .user = try userText(arena, transcript.items, questionOf(b.command), isQuestion(b.command)), .answer = answer });
            transcript.clearRetainingCapacity();
        }
        const last = try userText(arena, transcript.items, question, isQuestion(current.command));
        // The earlier turns that fit, newest first; the question always goes.
        var first = turns.items.len;
        var budget: usize = max_context_bytes -| last.len;
        while (first > 0) {
            const t = turns.items[first - 1];
            const size = t.user.len + t.answer.len;
            if (size > budget) break;
            budget -= size;
            first -= 1;
        }
        for (turns.items[first..]) |t| {
            try out.append(arena, .{ .role = .user, .text = t.user });
            try out.append(arena, .{ .role = .assistant, .text = t.answer });
        }
        try out.append(arena, .{ .role = .user, .text = last });
    }

    /// One user turn: the terminal transcript since the previous turn (the
    /// newest entries within the budget), then what the user typed.
    fn userText(arena: std.mem.Allocator, entries: []const []const u8, typed: []const u8, asked: bool) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = entries.len;
        var budget: usize = max_transcript_bytes;
        while (first > 0 and entries[first - 1].len <= budget) {
            budget -= entries[first - 1].len;
            first -= 1;
        }
        if (first < entries.len) {
            try out.appendSlice(arena, "Terminal transcript, oldest first:\n");
            if (first > 0) try out.appendSlice(arena, "[… earlier commands omitted]\n");
            for (entries[first..]) |e| try out.appendSlice(arena, e);
            try out.append(arena, '\n');
        }
        try out.appendSlice(arena, if (asked) "The user asks:\n" else "The user typed this line, which the shell did not recognise as a command:\n");
        try out.appendSlice(arena, typed);
        return out.toOwnedSlice(arena);
    }

    /// A shell block as the agent reads it: the command, the last lines of
    /// what it printed (stdout and stderr, merged as the terminal saw them)
    /// and how it ended.
    fn blockTranscript(arena: std.mem.Allocator, b: *const Block) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "$ ");
        try out.appendSlice(arena, b.command);
        try out.append(arena, '\n');
        var body: std.ArrayList(u8) = .empty;
        const n = b.buf.lineCount();
        const from = n -| max_output_lines;
        for (b.buf.lines.items[from..n]) |line| {
            const cells = line.cells.items;
            var end = cells.len;
            while (end > 0 and cells[end - 1].cp == ' ') end -= 1;
            for (cells[0..end]) |cell| {
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &utf8) catch continue;
                try body.appendSlice(arena, utf8[0..len]);
            }
            try body.append(arena, '\n');
        }
        // The last lines matter most: a long tail is cut from the front.
        var kept: []const u8 = body.items;
        if (kept.len > max_output_bytes) {
            kept = kept[kept.len - max_output_bytes ..];
            if (std.mem.indexOfScalar(u8, kept, '\n')) |nl| kept = kept[nl + 1 ..];
        }
        if (from > 0 or kept.len < body.items.len) try out.appendSlice(arena, "[… earlier output omitted]\n");
        try out.appendSlice(arena, kept);
        if (b.note) |note| {
            try out.appendSlice(arena, note);
            try out.append(arena, '\n');
        }
        if (b.state == .failed) {
            if (b.exit_code == 130) try out.appendSlice(arena, "[stopped with ⌃C]\n") else try out.print(arena, "[exit {d}]\n", .{b.exit_code});
        }
        return out.toOwnedSlice(arena);
    }

    /// A `# …` line: a question asked outright rather than a command the
    /// shell did not know.
    fn isQuestion(command: []const u8) bool {
        const t = std.mem.trimStart(u8, command, " \t");
        return t.len > 0 and t[0] == '#';
    }

    /// What was asked: the line without a leading `#`.
    fn questionOf(command: []const u8) []const u8 {
        const t = std.mem.trim(u8, command, " \t");
        if (t.len > 0 and t[0] == '#') return std.mem.trim(u8, t[1..], " \t");
        return t;
    }

    fn blockById(self: *TerminalTab, bid: u32) ?*Block {
        for (self.session.blocks.items) |b| {
            if (b.id == bid) return b;
        }
        return null;
    }

    fn setNote(self: *TerminalTab, b: *Block, text: []const u8) void {
        self.clearNote(b);
        b.note = self.gpa.dupe(u8, text) catch return;
        b.note_owned = true;
    }

    fn clearNote(self: *TerminalTab, b: *Block) void {
        if (b.note_owned) if (b.note) |n| self.gpa.free(n);
        b.note = null;
        b.note_owned = false;
    }

    fn historyStep(self: *TerminalTab, older: bool) void {
        const hist = self.env.history;
        if (self.hist_index == null) {
            if (!older) return;
            self.hist_prefix.clearRetainingCapacity();
            self.hist_prefix.appendSlice(self.gpa, self.editor.bytes()) catch {};
        }
        const from = self.hist_index orelse hist.entries.items.len;
        const found = if (older)
            hist.searchBack(from, self.hist_prefix.items, self.editor.bytes())
        else
            hist.searchForward(from, self.hist_prefix.items, self.editor.bytes());
        if (found) |idx| {
            self.hist_index = idx;
            self.editor.setText(hist.entries.items[idx]);
        } else if (!older) {
            // Walked past the newest entry: back to what the user had typed.
            self.hist_index = null;
            self.editor.setText(self.hist_prefix.items);
        }
        // Browsing should not trigger ghost text for the recalled entry.
        self.suggestion.clearRetainingCapacity();
        self.suggestion_for = self.editor.version;
    }

    fn acceptSuggestion(self: *TerminalTab) bool {
        self.refreshSuggestion();
        if (self.suggestion.items.len == 0) return false;
        self.editor.insert(self.suggestion.items);
        return true;
    }

    fn refreshSuggestion(self: *TerminalTab) void {
        if (self.suggestion_for == self.editor.version) return;
        self.suggestion_for = self.editor.version;
        self.suggestion.clearRetainingCapacity();
        const text = self.editor.bytes();
        if (self.session.busy() or text.len == 0 or !self.editor.atEnd() or self.editor.isMultiline()) return;
        if (self.editor.marked.items.len > 0) return;
        if (self.env.history.suggest(text)) |rest| {
            const one_line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
            self.suggestion.appendSlice(self.gpa, one_line) catch {};
            return;
        }
        if (complete.suggestPath(self.gpa, self.session.cwd.items, text)) |rest| {
            defer self.gpa.free(rest);
            self.suggestion.appendSlice(self.gpa, rest) catch {};
        }
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *TerminalTab, ui: *Ui, rect: Rect, focused: bool) void {
        self.now = ui.now;
        if (focused != self.was_focused) {
            self.was_focused = focused;
            self.session.notifyFocus(focused);
        }

        // What a full-screen program gets: the whole tab, edge to edge.
        const scr_cell_w = ui.text.cellAdvance(theme.font_output);
        const scr_cell_h = screenLineHeight(ui);
        const scale = ui.dl.scale;
        const scr_cols: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(rect.w / scr_cell_w))), 2, 500));
        const scr_rows: u16 = @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(rect.h / scr_cell_h))), 1, 300));
        self.session.setScreenSize(
            scr_cols,
            scr_rows,
            .{ @intFromFloat(@round(scr_cell_w * scale)), @intFromFloat(@round(scr_cell_h * scale)) },
            .{ .bg = rgb8(theme.bg), .fg = rgb8(theme.text) },
        );
        if (self.session.fullscreen() != null) {
            self.drawScreen(ui, rect, focused, scr_cell_w, scr_cell_h);
            return;
        }
        self.scroll_px = 0;
        self.mouse_down = false;

        const col_w = @max(240, @min(theme.content_max_w, rect.w - 2 * theme.content_pad));
        const col_x = rect.x + (rect.w - col_w) / 2;

        // Output width drives the PTY size so programs wrap where we do.
        const out_cell = ui.text.cellAdvance(theme.font_output);
        const inner_w = col_w - 2 * theme.block_pad_x - 28;
        const cols: u32 = @intFromFloat(@max(20, @floor(inner_w / out_cell)));
        self.session.resize(@intCast(@min(cols, 500)), 40);

        self.refreshSuggestion();
        const input_h = self.inputHeight(ui, col_w);
        const input_rect: Rect = .{ .x = col_x, .y = rect.bottom() - theme.content_pad - input_h, .w = col_w, .h = input_h };
        const area: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(0, input_rect.y - theme.block_gap - rect.y) };

        // A click anywhere drops the output selection; a press on output text
        // starts a new one later in this same frame.
        if (ui.pressed) self.sel_block = 0;
        if (self.editor.selection() != null) self.sel_block = 0;
        self.drawBlocks(ui, area, col_x, col_w, cols);
        self.drawInput(ui, input_rect, focused);

        if (self.rerun) |cmd| {
            self.rerun = null;
            defer self.gpa.free(cmd);
            self.run(cmd);
        }
    }

    const BlockLayout = struct {
        h: f32,
        header_h: f32,
        rows: u32,
        first_row: u32,
        hidden: u32,
        collapsible: bool,
        failed: bool,
        note: ?[]const u8,
        note_lines: u32 = 0,
    };

    fn ensureRows(self: *TerminalTab, b: *Block, cols: u32) void {
        if (b.cache_version == b.buf.version and b.cache_cols == cols) return;
        b.cache_version = b.buf.version;
        b.cache_cols = cols;
        b.row_starts.clearRetainingCapacity();
        var total: u32 = 0;
        const n = b.buf.lineCount();
        for (b.buf.lines.items[0..n]) |line| {
            b.row_starts.append(self.gpa, total) catch break;
            const len: u32 = @intCast(line.cells.items.len);
            total += @max(1, (len + cols - 1) / cols);
        }
        b.total_rows = total;
    }

    fn layoutBlock(self: *TerminalTab, ui: *Ui, b: *Block, cols: u32, col_w: f32) BlockLayout {
        self.ensureRows(b, cols);
        var l: BlockLayout = .{
            .h = 0,
            .header_h = 0,
            .rows = b.total_rows,
            .first_row = 0,
            .hidden = 0,
            .collapsible = b.total_rows > collapse_threshold,
            // ⌃C is the user's own doing, not a failure that needs fixing;
            // an agent's failure to answer is not one the agent can fix.
            .failed = b.state == .failed and b.exit_code != 130 and !b.agent,
            .note = b.note,
        };
        if (l.note == null and b.fullscreen and b.finished() and b.total_rows == 0) l.note = note_fullscreen;
        if (l.note) |note| {
            l.note_lines = wrapCount(ui, theme.font_ui, note, col_w - 2 * theme.block_pad_x);
            l.rows = 0;
            l.collapsible = false;
        }
        if (l.collapsible and !b.expanded) {
            l.rows = collapsed_rows;
            l.first_row = b.total_rows - collapsed_rows;
            l.hidden = l.first_row;
        }
        const hidden_row: f32 = if (l.hidden > 0) line_h else 0;
        const out_h = @as(f32, @floatFromInt(l.rows)) * line_h + hidden_row;
        const has_body = l.rows > 0 or l.note != null;

        if (l.failed) {
            l.header_h = 14 + 21 + (if (has_body) @as(f32, 6) else 0);
            l.h = l.header_h;
            if (l.note != null) l.h += @as(f32, @floatFromInt(l.note_lines)) * 21;
            if (l.rows > 0) l.h += 10 + out_h + 10;
            l.h += 14 + 34 + 16;
        } else {
            l.header_h = 14 + 21 + (if (has_body) @as(f32, 10) else 14);
            l.h = l.header_h;
            if (l.note != null) l.h += @as(f32, @floatFromInt(l.note_lines)) * 21 + 14;
            if (l.rows > 0) l.h += out_h + (if (l.collapsible) @as(f32, 4 + 28 + 10) else 14);
        }
        return l;
    }

    fn drawBlocks(self: *TerminalTab, ui: *Ui, area: Rect, col_x: f32, col_w: f32, cols: u32) void {
        const dl = ui.dl;
        const blocks = self.session.blocks.items;

        // Total height first, so scrolling can be clamped and kept stable.
        var total: f32 = 0;
        for (blocks) |b| total += self.layoutBlock(ui, b, cols, col_w).h + theme.block_gap;
        if (blocks.len > 0) total -= theme.block_gap;
        total += theme.content_pad; // breathing room above the first block
        if (self.scroll > 0 and self.content_h > 0 and total != self.content_h) {
            // Content grew/shrank below the viewport: keep what the user reads in place.
            self.scroll = @max(0, self.scroll + (total - self.content_h));
        }
        self.content_h = total;
        const max_scroll = @max(0, total - area.h);
        const vbar = Ui.id("terminal.vbar", self.wid_salt);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, area, max_scroll - self.scroll, total)) |s| self.scroll = max_scroll - s;
        self.scroll = std.math.clamp(self.scroll + ui.takeScroll(area), 0, max_scroll);

        dl.pushClip(area);
        defer dl.popClip();

        var y = area.bottom() + self.scroll;
        var i = blocks.len;
        while (i > 0) {
            i -= 1;
            const b = blocks[i];
            const l = self.layoutBlock(ui, b, cols, col_w);
            y -= l.h;
            if (y < area.bottom() and y + l.h > area.y) {
                self.drawBlock(ui, b, l, .{ .x = col_x, .y = y, .w = col_w, .h = l.h }, area, cols);
            }
            y -= theme.block_gap;
            if (y + theme.block_gap < area.y - 4000) break; // far above the viewport
        }

        sidebar.drawScrollbarAxis(ui, vbar, .vertical, area, max_scroll - self.scroll, total);
    }

    fn drawBlock(self: *TerminalTab, ui: *Ui, b: *Block, l: BlockLayout, r: Rect, area: Rect, cols: u32) void {
        const dl = ui.dl;
        dl.shape(r, theme.block_radius, theme.bg_block, if (l.failed) 1 else theme.block_border, if (l.failed) theme.red_line else theme.line);
        const px = r.x + theme.block_pad_x;
        const inner_w = r.w - 2 * theme.block_pad_x;

        // Header: "$ command" … status.
        const head_cy = r.y + 14 + 10.5;
        var status_buf: [64]u8 = undefined;
        const status_text = statusText(b, self.now, &status_buf);
        const status_color = switch (b.state) {
            .failed => if (b.exit_code == 130) theme.text_3 else theme.red,
            .running, .pending => theme.teal,
            .done => theme.text_3,
        };
        const sw = dl.textRight(theme.font_hint, r.right() - theme.block_pad_x, head_cy, status_text, status_color);

        // "Copy" appears on hover, left of the status.
        var right_limit = r.right() - theme.block_pad_x - sw - 12;
        if (ui.mouseIn(r) and (l.rows > 0)) {
            const label = if (b.agent) "Copy answer" else "Copy output";
            const lw = ui.text.measure(theme.font_hint, label);
            const cr: Rect = .{ .x = right_limit - lw - 16, .y = head_cy - 12, .w = lw + 16, .h = 24 };
            const st = ui.button(Ui.id("block.copy", b.id), cr);
            ui.feedback(cr, 6, st);
            _ = dl.textCentered(theme.font_hint, cr.x + 8, head_cy, label, if (st.hover) theme.text else theme.text_3);
            if (st.clicked) self.copyBlock(b);
            right_limit = cr.x - 8;
        }

        // "$" for the shell, the sparkle for the agent's turn.
        const prompt_w = if (b.agent) blk: {
            dl.icon(.sparkle, px - 1, head_cy - 8, 16, theme.accent);
            break :blk @as(f32, 14);
        } else dl.textCentered(theme.font_cmd, px, head_cy, "$", theme.accent);
        const cmd_x = px + prompt_w + ui.text.cellAdvance(theme.font_cmd);
        const first_line = b.command[0 .. std.mem.indexOfScalar(u8, b.command, '\n') orelse b.command.len];
        const multi = first_line.len != b.command.len;
        var cmd_buf: [512]u8 = undefined;
        const shown = if (multi) (std.fmt.bufPrint(&cmd_buf, "{s} …", .{first_line[0..@min(first_line.len, 500)]}) catch first_line) else first_line;
        _ = dl.textEllipsis(theme.font_cmd, cmd_x, head_cy, shown, right_limit - cmd_x, theme.text);

        var y = r.y + l.header_h;

        if (l.note) |note| {
            y = drawWrapped(ui, theme.font_ui, note, px, y, inner_w, 21, theme.text_2);
            if (!l.failed) y += 14;
        }

        if (l.rows > 0) {
            if (l.failed) {
                const inset: Rect = .{ .x = px, .y = y, .w = inner_w, .h = 20 + @as(f32, @floatFromInt(l.rows)) * line_h + (if (l.hidden > 0) line_h else 0) };
                dl.rrect(inset, 8, theme.bg_inset);
                y = self.drawRows(ui, b, l, px + 14, y + 10, area, cols) + 10;
            } else {
                y = self.drawRows(ui, b, l, px, y, area, cols);
            }
        }

        if (l.failed) {
            // Action row (design: Fix with agent · Explain · Run again ··· Show full output).
            const by = y + 14;
            var bx = px;
            bx = self.actionButton(ui, Ui.id("block.fix", b.id), bx, by, "Fix with agent", .primary) + 10;
            bx = self.actionButton(ui, Ui.id("block.explain", b.id), bx, by, "Explain", .outline) + 10;
            const run_again_id = Ui.id("block.rerun", b.id);
            _ = self.actionButton(ui, run_again_id, bx, by, "Run again", .outline);
            if (self.clicked_id == run_again_id) self.queueRerun(b.command);
            if (l.collapsible) self.expandToggle(ui, b, r.right() - theme.block_pad_x, by + 17);
        } else if (l.rows > 0 and l.collapsible) {
            self.expandToggle(ui, b, r.right() - theme.block_pad_x, y + 4 + 14);
        }
        self.clicked_id = 0;
    }

    const ButtonKind = enum { primary, outline };

    /// Draws a 34pt button at (x, y); returns its right edge.
    fn actionButton(self: *TerminalTab, ui: *Ui, wid: u64, x: f32, y: f32, label: []const u8, kind: ButtonKind) f32 {
        const font = if (kind == .primary) ui_mod.Font.semibold(13.5) else ui_mod.Font.sans(13.5);
        const pad: f32 = if (kind == .primary) 16 else 14;
        const w = ui.text.measure(font, label) + 2 * pad;
        const r: Rect = .{ .x = x, .y = y, .w = w, .h = 34 };
        const st = ui.button(wid, r);
        switch (kind) {
            .primary => {
                ui.dl.rrect(r, 8, if (st.held) theme.accent.alpha(0.8) else if (st.hover) Color.mix(theme.accent, theme.text, 0.18) else theme.accent);
                _ = ui.dl.textCentered(font, r.x + pad, r.centerY(), label, theme.on_accent);
            },
            .outline => {
                ui.feedback(r, 8, st);
                ui.dl.border(r, 8, 1, theme.line_strong);
                _ = ui.dl.textCentered(font, r.x + pad, r.centerY(), label, theme.text);
            },
        }
        if (st.clicked) self.clicked_id = wid;
        return r.right();
    }

    fn expandToggle(self: *TerminalTab, ui: *Ui, b: *Block, right: f32, cy: f32) void {
        _ = self;
        var buf: [64]u8 = undefined;
        const label = if (b.expanded) "Collapse output" else (std.fmt.bufPrint(&buf, "Show full output · {d} lines", .{b.total_rows}) catch "Show full output");
        const font = ui_mod.Font.sans(13.5);
        const w = ui.text.measure(font, label);
        const r: Rect = .{ .x = right - w - 8, .y = cy - 14, .w = w + 16, .h = 28 };
        const st = ui.button(Ui.id("block.expand", b.id), r);
        ui.feedback(r, 6, st);
        _ = ui.dl.textCentered(font, r.x + 8, cy, label, if (st.hover) theme.text else theme.text_2);
        if (st.clicked) b.expanded = !b.expanded;
    }

    fn queueRerun(self: *TerminalTab, cmd: []const u8) void {
        if (self.rerun != null or self.session.busy()) return;
        self.rerun = self.gpa.dupe(u8, cmd) catch null;
    }

    fn copyBlock(self: *TerminalTab, b: *Block) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        b.buf.appendText(&out, self.gpa) catch return;
        self.env.setClipboard(out.items);
    }

    /// Draws the visible output rows; returns the y below the last one.
    fn drawRows(self: *TerminalTab, ui: *Ui, b: *Block, l: BlockLayout, x: f32, y0: f32, area: Rect, cols: u32) f32 {
        const dl = ui.dl;
        var y = y0;
        if (l.hidden > 0) {
            var buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "··· {d} earlier lines", .{l.hidden}) catch "···";
            _ = dl.textCentered(theme.font_output, x, y + line_h / 2, label, theme.text_3);
            y += line_h;
        }
        if (b.row_starts.items.len == 0) return y;

        // Mouse text selection (drag; double-click = word, triple-click = line).
        {
            const cell_w = ui.text.cellAdvance(theme.font_output);
            const rows_rect: Rect = .{ .x = x - 6, .y = y, .w = @as(f32, @floatFromInt(cols)) * cell_w + 12, .h = @as(f32, @floatFromInt(l.rows)) * line_h };
            const d = ui.drag(Ui.id("block.select", b.id), rows_rect);
            if (d.hover or d.dragging) ui.cursor = .ibeam;
            if (d.started or d.dragging) {
                const pos = hitTest(b, l, x, y, cols, cell_w, ui.mx, ui.my);
                if (d.started) {
                    self.editor.anchor = null;
                    self.sel_block = b.id;
                    self.sel_anchor = pos;
                    self.sel_head = pos;
                    const cells = b.buf.lines.items[pos.line].cells.items;
                    if (ui.click_count >= 3) {
                        self.sel_anchor = .{ .line = pos.line, .cell = 0 };
                        self.sel_head = .{ .line = pos.line, .cell = cells.len };
                    } else if (ui.click_count == 2) {
                        var from = @min(pos.cell, cells.len);
                        var to = from;
                        while (from > 0 and cells[from - 1].cp != ' ') from -= 1;
                        while (to < cells.len and cells[to].cp != ' ') to += 1;
                        self.sel_anchor = .{ .line = pos.line, .cell = from };
                        self.sel_head = .{ .line = pos.line, .cell = to };
                    }
                    self.sel_by_drag = ui.click_count < 2;
                } else if (self.sel_block == b.id and self.sel_by_drag) {
                    self.sel_head = pos;
                }
            }
        }
        const sel: ?[2]Pos = if (self.sel_block == b.id) orderSelection(self.sel_anchor, self.sel_head) else null;

        // Skip rows above the viewport.
        var row = l.first_row;
        const end_row = l.first_row + l.rows;
        if (y < area.y) {
            const skip: u32 = @intFromFloat(@floor((area.y - y) / line_h));
            const s = @min(skip, l.rows);
            row += s;
            y += @as(f32, @floatFromInt(s)) * line_h;
        }

        // Locate the logical line containing `row`.
        var lo: usize = 0;
        var hi: usize = b.row_starts.items.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (b.row_starts.items[mid] <= row) lo = mid else hi = mid;
        }
        var line_idx = lo;

        const scale = dl.scale;
        const cell_px = ui.text.cellAdvance(theme.font_output) * scale;
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };

        while (row < end_row and line_idx < b.row_starts.items.len) : (row += 1) {
            if (y > area.bottom()) {
                y += @as(f32, @floatFromInt(end_row - row)) * line_h;
                break;
            }
            while (line_idx + 1 < b.row_starts.items.len and b.row_starts.items[line_idx + 1] <= row) line_idx += 1;
            const cells = b.buf.lines.items[line_idx].cells.items;
            const seg = row - b.row_starts.items[line_idx];
            const from = @min(cells.len, @as(usize, seg) * cols);
            const to = @min(cells.len, from + cols);

            const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, y + line_h / 2) * scale);
            const x_px = @round(x * scale);
            var col: f32 = 0;
            for (cells[from..to], from..) |cell, cell_idx| {
                const st = b.buf.style(cell.style);
                if (sel) |s| {
                    const here: Pos = .{ .line = line_idx, .cell = cell_idx };
                    if (!here.before(s[0]) and here.before(s[1])) {
                        const sw: f32 = @floatFromInt(@max(1, gfx_text.cellWidth(cell.cp)));
                        dl.rect(.{ .x = (x_px + col * cell_px) / scale, .y = y, .w = sw * cell_px / scale, .h = line_h }, theme.selection());
                    }
                }
                var fg = resolve(st.fg, if (st.bold) theme.text else theme.text_2, .fg);
                var bg: ?Color = if (st.bg != buffer_mod.color_default) resolve(st.bg, theme.bg_block, .bg) else null;
                if (st.inverse) {
                    const old_fg = fg;
                    fg = bg orelse theme.bg_block;
                    bg = old_fg;
                }
                if (st.dim) fg = fg.alpha(0.6);
                const w_cells: f32 = @floatFromInt(@max(1, gfx_text.cellWidth(cell.cp)));
                const cx = (x_px + col * cell_px) / scale;
                if (bg) |c| dl.rect(.{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = line_h }, c);
                if (cell.cp != ' ' and !boxdraw.draw(dl, .{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = line_h }, cell.cp, fg)) {
                    const font = if (st.bold) theme.font_output_bold else theme.font_output;
                    _ = dl.glyph(font, cell.cp, x_px + col * cell_px, baseline_px, fg, clip);
                }
                if (st.underline) dl.rect(.{ .x = cx, .y = y + line_h - 5, .w = w_cells * cell_px / scale, .h = 1 }, fg);
                if (st.strike) dl.rect(.{ .x = cx, .y = y + line_h / 2, .w = w_cells * cell_px / scale, .h = 1 }, fg);
                col += @floatFromInt(gfx_text.cellWidth(cell.cp));
            }
            y += line_h;
        }
        return y;
    }

    // ── full-screen programs ────────────────────────────────────────────
    /// The program's screen fills the tab: no card, no margins, one cell
    /// grid from the top-left corner, the way a plain terminal would show it.
    fn drawScreen(self: *TerminalTab, ui: *Ui, rect: Rect, focused: bool, cell_w: f32, cell_h: f32) void {
        const dl = ui.dl;
        const scr = self.session.fullscreen() orelse return;
        scr.update();
        const rs = &scr.render;
        dl.rect(rect, theme.bg);
        dl.pushClip(rect);
        defer dl.popClip();
        self.screenMouse(ui, rect, scr, cell_w, cell_h);

        const scale = dl.scale;
        const cell_px = cell_w * scale;
        const x0_px = @round(rect.x * scale);
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const rows_cells = rs.row_data.items(.cells);
        var y: usize = 0;
        while (y < rs.rows and y < rows_cells.len) : (y += 1) {
            const row_y = rect.y + @as(f32, @floatFromInt(y)) * cell_h;
            if (row_y >= rect.bottom()) break;
            const cells = rows_cells[y].slice();
            const raws = cells.items(.raw);
            const styles = cells.items(.style);

            // Backgrounds first, merged into runs, so no glyph gets covered.
            var x: usize = 0;
            while (x < raws.len) {
                const bg = cellBackground(rs, raws[x], styles[x]);
                var end = x + 1;
                while (end < raws.len and std.meta.eql(cellBackground(rs, raws[end], styles[end]), bg)) end += 1;
                if (bg) |color| {
                    const bx = (x0_px + @as(f32, @floatFromInt(x)) * cell_px) / scale;
                    dl.rect(.{ .x = bx, .y = row_y, .w = @as(f32, @floatFromInt(end - x)) * cell_w, .h = cell_h }, color);
                }
                x = end;
            }

            const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, row_y + cell_h / 2) * scale);
            for (raws, styles, 0..) |raw, style_in, cx_i| {
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => continue,
                };
                if (cp == 0 or cp == ' ') continue;
                const st: screen_mod.Style = if (raw.style_id == 0) .{} else style_in;
                if (st.flags.invisible) continue;
                const colors = screenColors(rs, st);
                const w_cells: f32 = if (raw.wide == .wide) 2 else 1;
                const gx_px = x0_px + @as(f32, @floatFromInt(cx_i)) * cell_px;
                const cell_rect: Rect = .{ .x = gx_px / scale, .y = row_y, .w = w_cells * cell_w, .h = cell_h };
                if (!boxdraw.draw(dl, cell_rect, cp, colors.fg)) {
                    const font = if (st.flags.bold) theme.font_output_bold else theme.font_output;
                    _ = dl.glyph(font, cp, gx_px, baseline_px, colors.fg, clip);
                }
                if (st.flags.underline != .none) dl.rect(.{ .x = cell_rect.x, .y = row_y + cell_h - 2, .w = cell_rect.w, .h = 1 }, colors.fg);
                if (st.flags.strikethrough) dl.rect(.{ .x = cell_rect.x, .y = row_y + @floor(cell_h / 2), .w = cell_rect.w, .h = 1 }, colors.fg);
            }
        }

        self.drawScreenCursor(ui, rect, rs, focused, cell_w, cell_h);

        // IME composition, underlined, at the cursor.
        if (self.editor.marked.items.len > 0) {
            const w = dl.textCentered(theme.font_output, self.caret.x, self.caret.y + cell_h / 2, self.editor.marked.items, theme.text);
            dl.rect(.{ .x = self.caret.x, .y = self.caret.y + cell_h - 2, .w = w, .h = 1 }, theme.text_2);
        }

        if (!scr.atBottom()) {
            const label = "Earlier output · scroll down or type to return";
            const w = ui.text.measure(theme.font_hint, label) + 20;
            const pr: Rect = .{ .x = rect.right() - w - 12, .y = rect.y + 10, .w = w, .h = 24 };
            dl.rrect(pr, 12, theme.bg_panel);
            dl.border(pr, 12, 1, theme.line_strong);
            _ = dl.textCentered(theme.font_hint, pr.x + 10, pr.centerY(), label, theme.text_2);
        }
    }

    fn drawScreenCursor(self: *TerminalTab, ui: *Ui, rect: Rect, rs: *const screen_mod.RenderState, focused: bool, cell_w: f32, cell_h: f32) void {
        const dl = ui.dl;
        self.caret = .{};
        if (!rs.cursor.visible) return;
        const cv = rs.cursor.viewport orelse return;
        const scale = dl.scale;
        const col: f32 = @floatFromInt(cv.x -| @as(u16, if (cv.wide_tail) 1 else 0));
        const cx = (@round(rect.x * scale) + col * cell_w * scale) / scale;
        const cy = rect.y + @as(f32, @floatFromInt(cv.y)) * cell_h;
        const wide = rs.cursor.cell.wide == .wide or cv.wide_tail;
        const cw: f32 = if (wide) 2 * cell_w else cell_w;
        self.caret = .{ .x = cx, .y = cy, .w = 2, .h = cell_h };
        const r: Rect = .{ .x = cx, .y = cy, .w = cw, .h = cell_h };
        if (!focused) {
            dl.border(r, 0, 1, theme.text_3);
            return;
        }
        switch (rs.cursor.visual_style) {
            .bar => dl.rect(.{ .x = cx, .y = cy, .w = 2, .h = cell_h }, theme.text),
            .underline => dl.rect(.{ .x = cx, .y = cy + cell_h - 2, .w = cw, .h = 2 }, theme.text),
            .block => {
                dl.rect(r, theme.text);
                // The glyph under it, in the background colour.
                const raw = rs.cursor.cell;
                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };
                if (cp != 0 and cp != ' ' and !boxdraw.draw(dl, r, cp, theme.bg)) {
                    const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, cy + cell_h / 2) * scale);
                    const clip = blk: {
                        const c = dl.currentClip();
                        break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
                    };
                    _ = dl.glyph(theme.font_output, cp, @round(cx * scale), baseline_px, theme.bg, clip);
                }
            },
            else => dl.border(r, 0, 1, theme.text),
        }
    }

    /// Mouse for the program: reports when it asked for them, else the
    /// wheel pages the alternate screen (as arrow keys) or the main
    /// screen's history.
    fn screenMouse(self: *TerminalTab, ui: *Ui, rect: Rect, scr: *screen_mod.Screen, cell_w: f32, cell_h: f32) void {
        _ = cell_w;
        const scale = ui.dl.scale;
        const inside = ui.mouseIn(rect);
        const dy = ui.takeScroll(rect);
        const screen_px: [2]u32 = .{ @intFromFloat(@round(rect.w * scale)), @intFromFloat(@round(rect.h * scale)) };
        const pos: screen_mod.MouseEvent.Pos = .{ .x = (ui.mx - rect.x) * scale, .y = (ui.my - rect.y) * scale };
        const mods = screenMods(ui.mods);
        var buf: [64]u8 = undefined;
        const tracking = scr.mouseTracking();

        if (dy != 0) {
            const notches: usize = @intFromFloat(@min(4, @max(1, @round(@abs(dy) / 24))));
            if (tracking and inside) {
                var i: usize = 0;
                while (i < notches) : (i += 1) {
                    self.send(scr.encodeMouse(&buf, .{ .action = .press, .button = if (dy > 0) .four else .five, .mods = mods, .pos = pos }, screen_px, self.mouse_down));
                }
            } else if (scr.wheelAsArrows()) {
                var i: usize = 0;
                while (i < notches) : (i += 1) self.send(scr.encodeKey(&buf, .{ .key = if (dy > 0) .arrow_up else .arrow_down }));
            } else {
                self.scroll_px += dy;
                const rows: isize = @intFromFloat(@divTrunc(self.scroll_px, cell_h));
                if (rows != 0) {
                    scr.scrollBy(-rows);
                    self.scroll_px -= @as(f32, @floatFromInt(rows)) * cell_h;
                }
            }
        }

        if (!tracking) {
            self.mouse_down = false;
            return;
        }
        if (ui.pressed and inside and ui.active == 0) {
            self.mouse_down = true;
            self.send(scr.encodeMouse(&buf, .{ .action = .press, .button = .left, .mods = mods, .pos = pos }, screen_px, true));
        }
        if (ui.rightClicked(rect)) {
            self.send(scr.encodeMouse(&buf, .{ .action = .press, .button = .right, .mods = mods, .pos = pos }, screen_px, true));
            self.send(scr.encodeMouse(&buf, .{ .action = .release, .button = .right, .mods = mods, .pos = pos }, screen_px, false));
        }
        if (ui.released and self.mouse_down) {
            self.mouse_down = false;
            self.send(scr.encodeMouse(&buf, .{ .action = .release, .button = .left, .mods = mods, .pos = pos }, screen_px, false));
        }
        if (ui.mx != self.last_mouse[0] or ui.my != self.last_mouse[1]) {
            self.last_mouse = .{ ui.mx, ui.my };
            if (inside or self.mouse_down) {
                self.send(scr.encodeMouse(&buf, .{ .action = .motion, .button = if (self.mouse_down) .left else null, .mods = mods, .pos = pos }, screen_px, self.mouse_down));
            }
        }
    }

    fn send(self: *TerminalTab, seq: []const u8) void {
        if (seq.len > 0) self.session.sendBytes(seq);
    }

    // ── input box ───────────────────────────────────────────────────────
    const InputLayout = struct { rows: usize, cols: usize, prompt_w: f32 };

    fn inputLayout(self: *TerminalTab, ui: *Ui, box_w: f32) InputLayout {
        const cell = ui.text.cellAdvance(theme.font_input);
        const prompt_w = cell * 2;
        const avail = box_w - 2 * theme.block_pad_x - prompt_w;
        const cols: usize = @intFromFloat(@max(8, @floor(avail / cell)));
        var rows: usize = 1;
        var col: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = self.editor.bytes() };
        while (it.next()) |cp| {
            if (cp == '\n') {
                rows += 1;
                col = 0;
                continue;
            }
            if (col >= cols) {
                rows += 1;
                col = 0;
            }
            col += 1;
        }
        return .{ .rows = rows, .cols = cols, .prompt_w = prompt_w };
    }

    fn inputHeight(self: *TerminalTab, ui: *Ui, box_w: f32) f32 {
        const l = self.inputLayout(ui, box_w);
        return 16 + @as(f32, @floatFromInt(l.rows)) * input_row_h + 12 + hint_h + 14;
    }

    /// Byte offset of the character cell at (row, col) in the wrapped layout.
    fn offsetAt(self: *TerminalTab, target_row: usize, target_col: usize) usize {
        var row: usize = 0;
        var col: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = self.editor.bytes() };
        while (true) {
            const at = it.index;
            const cp = it.next() orelse return at;
            if (cp != '\n' and col >= self.text_cols) {
                if (row == target_row) return at;
                row += 1;
                col = 0;
            }
            if (row == target_row and col >= target_col) return at;
            if (cp == '\n') {
                if (row == target_row) return at;
                row += 1;
                col = 0;
                continue;
            }
            col += 1;
        }
    }

    fn drawInput(self: *TerminalTab, ui: *Ui, r: Rect, focused: bool) void {
        const dl = ui.dl;
        const busy = self.session.busy();
        const lay = self.inputLayout(ui, r.w);
        const cell = ui.text.cellAdvance(theme.font_input);
        const border_color = if (!focused) theme.line_strong else if (busy) theme.teal.alpha(0.75) else theme.accent;
        dl.shape(r, theme.block_radius, theme.bg_inset, 1, border_color);

        const px = r.x + theme.block_pad_x;
        const text_x = px + lay.prompt_w;
        const text_y = r.y + 16;
        self.text_x = text_x;
        self.text_y = text_y;
        self.text_cols = lay.cols;
        self.cell_w = cell;

        _ = dl.textCentered(theme.font_input, px, text_y + input_row_h / 2, if (busy) "›" else "$", if (busy) theme.teal else theme.accent);

        // Mouse: place caret / drag-select.
        const text_rect: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 16 + @as(f32, @floatFromInt(lay.rows)) * input_row_h + 8 };
        const d = ui.drag(Ui.id("input.text", self.wid_salt), text_rect);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (d.started or d.dragging) {
            const rel_y = @max(0, ui.my - text_y);
            const row: usize = @min(lay.rows - 1, @as(usize, @intFromFloat(@floor(rel_y / input_row_h))));
            const rel_x = @max(0, ui.mx - text_x + cell / 2);
            const col: usize = @intFromFloat(@floor(rel_x / cell));
            const off = self.offsetAt(row, col);
            if (d.started and d.double_clicked) {
                self.editor.selectWordAt(off);
            } else if (d.started) {
                self.editor.setCursor(off, ui.mods.shift);
            } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                self.editor.setCursor(off, true);
            }
        }

        // Text, selection, caret.
        const masked = busy and !self.session.pty.echoEnabled();
        const sel = self.editor.selection();
        var row: usize = 0;
        var col: usize = 0;
        var caret_row: usize = 0;
        var caret_col: usize = 0;
        var it = gfx_text.Utf8Iter{ .bytes = self.editor.bytes() };
        const scale = dl.scale;
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        while (true) {
            const at = it.index;
            if (at == self.editor.cursor) {
                caret_row = row;
                caret_col = col;
                if (col >= lay.cols and at < self.editor.bytes().len and self.editor.bytes()[at] != '\n') {
                    caret_row += 1;
                    caret_col = 0;
                }
            }
            const cp = it.next() orelse break;
            if (cp == '\n') {
                if (sel) |s| if (at >= s[0] and at < s[1]) {
                    dl.rect(.{ .x = text_x + @as(f32, @floatFromInt(col)) * cell, .y = text_y + @as(f32, @floatFromInt(row)) * input_row_h + 1, .w = cell * 0.5, .h = input_row_h - 2 }, theme.selection());
                };
                row += 1;
                col = 0;
                continue;
            }
            if (col >= lay.cols) {
                row += 1;
                col = 0;
            }
            const cx = text_x + @as(f32, @floatFromInt(col)) * cell;
            const cy = text_y + @as(f32, @floatFromInt(row)) * input_row_h;
            if (sel) |s| if (at >= s[0] and at < s[1]) {
                dl.rect(.{ .x = cx, .y = cy + 1, .w = cell, .h = input_row_h - 2 }, theme.selection());
            };
            const baseline_px = @round(ui.text.baselineForCenter(theme.font_input, cy + input_row_h / 2) * scale);
            _ = dl.glyph(theme.font_input, if (masked) '•' else cp, @round(cx * scale), baseline_px, theme.text, clip);
            col += 1;
        }

        var cx = text_x + @as(f32, @floatFromInt(caret_col)) * cell;
        const cy = text_y + @as(f32, @floatFromInt(caret_row)) * input_row_h;

        // IME composition, underlined, right at the caret.
        if (self.editor.marked.items.len > 0) {
            const w = dl.textCentered(theme.font_input, cx, cy + input_row_h / 2, self.editor.marked.items, theme.text);
            dl.rect(.{ .x = cx, .y = cy + input_row_h - 3, .w = w, .h = 1 }, theme.text_2);
            cx += w;
        }

        self.caret = .{ .x = cx, .y = cy + 1.5, .w = 2, .h = 20 };
        if (focused and (self.blink_on or ui.down)) dl.rect(self.caret, theme.accent);

        // Ghost suggestion after the caret.
        const has_suggestion = self.suggestion.items.len > 0 and self.editor.atEnd() and self.editor.marked.items.len == 0;
        if (has_suggestion) {
            const room = (r.right() - theme.block_pad_x) - (cx + 3);
            _ = dl.textEllipsis(theme.font_input, cx + 3, cy + input_row_h / 2, self.suggestion.items, room, theme.text_3);
        }

        // Hint row.
        const hy = r.bottom() - 14 - hint_h / 2;
        var hx = px;
        if (busy) {
            hx += dl.textCentered(theme.font_hint, hx, hy, if (masked) "↵ Send (hidden)" else "↵ Send to program", theme.text_3) + 20;
            hx += dl.textCentered(theme.font_hint, hx, hy, "⌃C Stop", theme.text_3) + 20;
            _ = dl.textCentered(theme.font_hint, hx, hy, "⌃D End of input", theme.text_3);
        } else if (self.session.dormant()) {
            hx += dl.textCentered(theme.font_hint, hx, hy, "↵ Start shell", theme.text_3) + 20;
            _ = dl.textCentered(theme.font_hint, hx, hy, "Type a command to run it in a fresh shell", theme.text_3);
        } else {
            hx += dl.textCentered(theme.font_hint, hx, hy, "↵ Run", theme.text_3) + 20;
            hx += dl.textCentered(theme.font_hint, hx, hy, "Tab Accept suggestion", if (has_suggestion) theme.text_2 else theme.text_3) + 20;
            var tip_buf: [128]u8 = undefined;
            const tip = agentTip(&tip_buf);
            const tw = ui.text.measure(theme.font_hint, tip);
            if (r.right() - theme.block_pad_x - tw > hx + 8) {
                _ = dl.textCentered(theme.font_hint, r.right() - theme.block_pad_x - tw, hy, tip, theme.text_3);
            }
        }
    }
};

// ── helpers ──────────────────────────────────────────────────────────────
/// A position in a block's output: logical line + cell index.
const Pos = struct {
    line: usize = 0,
    cell: usize = 0,

    fn before(a: Pos, b: Pos) bool {
        return a.line < b.line or (a.line == b.line and a.cell < b.cell);
    }
};

fn orderSelection(a: Pos, b: Pos) ?[2]Pos {
    if (a.line == b.line and a.cell == b.cell) return null;
    return if (a.before(b)) .{ a, b } else .{ b, a };
}

/// Maps a mouse position to the output position under it (clamped to the
/// visible rows, so dragging past the edges selects up to them).
fn hitTest(b: *Block, l: TerminalTab.BlockLayout, x: f32, rows_y: f32, cols: u32, cell_w: f32, mx: f32, my: f32) Pos {
    const starts = b.row_starts.items;
    const rel = @floor((my - rows_y) / line_h);
    const max_row: f32 = @floatFromInt(l.rows -| 1);
    const row: u32 = l.first_row + @as(u32, @intFromFloat(std.math.clamp(rel, 0, max_row)));

    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= row) lo = mid else hi = mid;
    }
    const len = b.buf.lines.items[lo].cells.items.len;
    const seg: usize = row - starts[lo];
    const seg_start = @min(len, seg * cols);
    const seg_end = @min(len, seg_start + cols);
    if (rel < 0) return .{ .line = lo, .cell = seg_start };
    if (rel > max_row) return .{ .line = lo, .cell = seg_end };
    const c = @round((mx - x) / cell_w);
    const span: f32 = @floatFromInt(seg_end - seg_start);
    return .{ .line = lo, .cell = seg_start + @as(usize, @intFromFloat(std.math.clamp(c, 0, span))) };
}

/// The hint at the right of the input box: where a line the shell does
/// not know goes.
fn agentTip(buf: []u8) []const u8 {
    const cfg = config.get();
    if (cfg.features.command_fallback_agent) |name| {
        if (cfg.findAgentByName(name) != null) return std.fmt.bufPrint(buf, "Plain English goes to {s}", .{name}) catch "Plain English goes to the agent";
    }
    return "Plain English needs an agent: Settings › AI › Features";
}

fn statusText(b: *const Block, now: f64, buf: []u8) []const u8 {
    const d = b.duration(now);
    var dur_buf: [32]u8 = undefined;
    const dur = formatDuration(d, &dur_buf);
    if (b.agent) return switch (b.state) {
        .pending, .running => std.fmt.bufPrint(buf, "Thinking · {s}", .{dur}) catch "Thinking",
        .done => if (d >= 1.0) (std.fmt.bufPrint(buf, "Answered · {s}", .{dur}) catch "Answered") else "Answered",
        .failed => if (b.buf.isEmpty()) "No answer" else "Interrupted",
    };
    return switch (b.state) {
        .pending => "Starting…",
        .running => std.fmt.bufPrint(buf, "Running · {s}", .{dur}) catch "Running",
        .done => if (d >= 1.0) (std.fmt.bufPrint(buf, "Done · {s}", .{dur}) catch "Done") else "Done",
        .failed => blk: {
            if (b.exit_code == 130) break :blk std.fmt.bufPrint(buf, "Stopped · {s}", .{dur}) catch "Stopped";
            if (b.exit_code > 1) break :blk std.fmt.bufPrint(buf, "Failed · exit {d} · {s}", .{ b.exit_code, dur }) catch "Failed";
            break :blk std.fmt.bufPrint(buf, "Failed · {s}", .{dur}) catch "Failed";
        },
    };
}

fn formatDuration(seconds: f64, buf: []u8) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{seconds}) catch "";
    const total: u64 = @intFromFloat(seconds);
    if (total < 3600) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ total / 60, total % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ total / 3600, (total % 3600) / 60 }) catch "";
}

/// A style's colour for `role`: the theme's own 16 for the ANSI names,
/// the fixed 256-colour table and true colour as the theme shows them
/// (`theme.ink`), the default otherwise.
fn resolve(spec: buffer_mod.ColorSpec, default: Color, role: theme.InkRole) Color {
    return switch (spec >> 24) {
        1 => blk: {
            const n: u8 = @truncate(spec);
            break :blk if (n < 16 and role == .fg) theme.ansi[n] else theme.ink(palette(n), role);
        },
        2 => theme.ink(Color.fromRgb8(@truncate(spec >> 16), @truncate(spec >> 8), @truncate(spec)), role),
        else => default,
    };
}

fn palette(n: u8) Color {
    if (n < 16) return theme.ansi[n];
    if (n >= 232) {
        const v: u8 = 8 + 10 * (n - 232);
        return Color.fromRgb8(v, v, v);
    }
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    const i = n - 16;
    return Color.fromRgb8(levels[i / 36], levels[(i / 6) % 6], levels[i % 6]);
}

// ── full-screen screen helpers ───────────────────────────────────────────
/// Row height for a program's screen: the font's content height plus a
/// little leading. Box-drawing glyphs are drawn by hand (gfx/boxdraw.zig),
/// so lines still join across rows.
fn screenLineHeight(ui: *Ui) f32 {
    const font = theme.font_output;
    return @ceil(ui.text.ascent(font) + ui.text.descent(font)) + 2;
}

fn rgb8(c: Color) [3]u8 {
    return .{
        @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255)),
    };
}

fn screenMods(m: ui_mod.Mods) screen_mod.Mods {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.cmd };
}

/// Palette colours: the theme's calm 16, then the program's own 256-colour
/// table (which it may have changed with OSC 4).
fn paletteColor(rs: *const screen_mod.RenderState, i: u8) Color {
    if (i < 16) return theme.ansi[i];
    const c = rs.colors.palette[i];
    return Color.fromRgb8(c.r, c.g, c.b);
}

/// A screen style's colour for `role`, as the theme shows it (`theme.ink`).
fn styleColor(rs: *const screen_mod.RenderState, c: anytype, role: theme.InkRole) ?Color {
    return switch (c) {
        .none => null,
        .palette => |i| if (i < 16 and role == .fg) theme.ansi[i] else theme.ink(paletteColor(rs, i), role),
        .rgb => |rgb| theme.ink(Color.fromRgb8(rgb.r, rgb.g, rgb.b), role),
    };
}

const ScreenColors = struct { fg: Color, bg: ?Color };

fn screenColors(rs: *const screen_mod.RenderState, st: screen_mod.Style) ScreenColors {
    var fg = styleColor(rs, st.fg_color, .fg) orelse theme.text;
    var bg = styleColor(rs, st.bg_color, .bg);
    if (st.flags.inverse) {
        const old_fg = fg;
        fg = bg orelse theme.bg;
        bg = old_fg;
    }
    if (st.flags.faint) fg = fg.alpha(0.6);
    return .{ .fg = fg, .bg = bg };
}

/// A cell's background: a colour-only cell's own, else its style's.
fn cellBackground(rs: *const screen_mod.RenderState, raw: screen_mod.Cell, st: screen_mod.Style) ?Color {
    switch (raw.content_tag) {
        .bg_color_palette => return theme.ink(paletteColor(rs, raw.content.color_palette.data), .bg),
        .bg_color_rgb => {
            const c = raw.content.color_rgb;
            return theme.ink(Color.fromRgb8(c.r, c.g, c.b), .bg);
        },
        else => {},
    }
    if (raw.style_id == 0) return null;
    return screenColors(rs, st).bg;
}

/// Greedy word wrap; calls `emit` per line when given, returns the line count.
fn wrapLines(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32, ctx: anytype) u32 {
    var lines: u32 = 0;
    var start: usize = 0;
    while (start < str.len) {
        var end = start;
        var last_break: ?usize = null;
        var w: f32 = 0;
        var it = gfx_text.Utf8Iter{ .bytes = str, .index = start };
        while (it.next()) |cp| {
            const adv = ui.text.advance(font, cp);
            if (w + adv > max_w and end > start) break;
            w += adv;
            end = it.index;
            if (cp == ' ') last_break = end;
        }
        if (end < str.len) {
            if (last_break) |lb| end = lb;
        }
        ctx.line(std.mem.trimEnd(u8, str[start..end], " "));
        lines += 1;
        start = end;
    }
    return @max(lines, 1);
}

fn wrapCount(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32) u32 {
    const Counter = struct {
        fn line(_: @This(), _: []const u8) void {}
    };
    return wrapLines(ui, font, str, max_w, Counter{});
}

fn drawWrapped(ui: *Ui, font: ui_mod.Font, str: []const u8, x: f32, y: f32, max_w: f32, lh: f32, color: Color) f32 {
    const Painter = struct {
        ui: *Ui,
        font: ui_mod.Font,
        x: f32,
        y: *f32,
        lh: f32,
        color: Color,
        fn line(p: @This(), s: []const u8) void {
            _ = p.ui.dl.textCentered(p.font, p.x, p.y.* + p.lh / 2, s, p.color);
            p.y.* += p.lh;
        }
    };
    var cy = y;
    _ = wrapLines(ui, font, str, max_w, Painter{ .ui = ui, .font = font, .x = x, .y = &cy, .lh = lh, .color = color });
    return cy;
}

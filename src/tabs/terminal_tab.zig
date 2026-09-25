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
const selection = @import("../term/selection.zig");
const links = @import("../links.zig");
const screen_mod = @import("../term/screen.zig");
const boxdraw = @import("../gfx/boxdraw.zig");
const Editor = @import("../input/editor.zig").Editor;
const complete = @import("../input/complete.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");
const block_codec = @import("../term/block_codec.zig");
const agent = @import("../agent.zig");
const config = @import("../config.zig");
const coding_agents = @import("../coding_agents.zig");
const settings_features = @import("settings_features.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Session = session_mod.Session;
const Block = session_mod.Block;
const Buffer = buffer_mod.Buffer;

const input_row_h: f32 = 23;

/// The room kept between blocks and around the column: none in compact
/// mode, where the blocks and the input butt up against each other and
/// the pane's edges.
fn blockEdge(regular: f32) f32 {
    return if (theme.compact) 0 else regular;
}

const note_no_agent = "No agent takes plain-English lines yet: pick one under Settings › AI › Features.";
const note_empty_question = "Put the question after the #.";
const note_no_answer = "The agent sent no answer.";
const note_no_explain_agent = "No agent explains failures yet: pick one under Settings › AI › Features › Explain.";
const note_no_explanation = "The agent sent no explanation.";
const note_fix_off = "Fix with agent is off (Settings › AI › Features).";
const note_fix_none = "No coding agent found on this Mac: Settings › AI › Agents says how to install one.";
const note_fix_unknown = "The coding agent chosen under Settings › AI › Features is not one tt knows.";
/// Line height of the explanation under a failed command.
const explain_line_h: f32 = 21;
/// Gap above the explanation's label, and the label row itself.
const explain_gap: f32 = 12;
const explain_label_h: f32 = 22;
/// What a question carries along: the tab's earlier turns — commands with
/// their output and exit codes, questions with their answers — the newest
/// within these budgets, so a small local model's context is not overrun.
/// Of a block's output, its last lines.
const max_context_bytes: usize = 32 * 1024;
const max_transcript_bytes: usize = 16 * 1024;
const max_output_lines: usize = 60;
const max_output_bytes: usize = 4 * 1024;

/// An agent's reply on its way into a block: the answer to the line the
/// shell did not know (into the block's output) or the explanation of a
/// failure (into `Block.explanation`).
const PendingKind = enum { answer, explain };
const Pending = struct { block_id: u32, req: *agent.Request, kind: PendingKind = .answer };
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
    /// A line to run in the shell after this frame, without adding it to
    /// the history (the coding agent "Fix with agent" starts).
    launch: ?[]u8 = null,
    /// Why "Fix with agent" did nothing, shown beside the buttons of that
    /// block (a string from the binary; 0 = none).
    fix_note_block: u32 = 0,
    fix_note: []const u8 = "",
    closing: bool = false,
    /// Action button clicked during the current block's draw.
    clicked_id: u64 = 0,
    /// The queued block whose × or "Resume queue" was clicked during this
    /// frame's draw; applied once the blocks are drawn (0 = none).
    unqueue_id: u32 = 0,
    resume_id: u32 = 0,
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
    sel: selection.Selection = .{},

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
        if (self.launch) |l| self.gpa.free(l);
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
        if (self.session.busy() or self.rerun != null or self.launch != null) return "A command is still running; closing the tab will stop it.";
        if (self.session.queued.items.len > 0) return "Commands are queued in this tab; closing it drops them.";
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
            h.update(&[_]u8{ @intFromEnum(b.state), @intFromEnum(b.explain_state) });
            // An explanation counts once it is settled (the codec skips one
            // still coming in), so streaming does not rewrite the file.
            if (b.explain_state == .done or b.explain_state == .failed) h.update(b.explanation.items);
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
        const range = self.sel.range() orelse return false;
        const block = for (self.session.blocks.items) |b| {
            if (b.id == self.sel_block) break b;
        } else return false;
        selection.appendText(&block.buf, range, out, self.gpa) catch return false;
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
        const cmd = std.mem.trim(u8, text, " \t\n");
        // While a command runs, a line typed here waits its turn after it
        // (see `Session.queued`); a secret the program asks for (a line
        // read without echo) and a bare ↵ ("press ↵ to continue") go to
        // its stdin, as ⌥↵ sends anything (`sendToProgram`).
        if (self.session.busy() and (self.toProgram() or cmd.len == 0)) {
            _ = self.sendToProgram();
            return;
        }
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

    /// ⌥↵: the box's line goes to the running program's stdin instead of
    /// the queue. False when no command is running (↵ does the job then).
    pub fn sendToProgram(self: *TerminalTab) bool {
        if (!self.session.busy() or self.session.fullscreen() != null) return false;
        self.session.sendLine(self.editor.bytes());
        self.editor.clear();
        self.hist_index = null;
        return true;
    }

    /// The running program reads a line without echo (a password): what
    /// is typed is masked and ↵ hands it over.
    fn toProgram(self: *TerminalTab) bool {
        return self.session.busy() and !self.session.pty.echoEnabled();
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

    /// The terminal tab behind a generic tab, when that is what it is.
    pub fn fromTab(t: tab_mod.Tab) ?*TerminalTab {
        if (!std.mem.eql(u8, t.kind, "terminal")) return null;
        return @ptrCast(@alignCast(t.ptr));
    }

    /// Whether a line sent from another tab could run here right now.
    pub fn canLaunch(self: *const TerminalTab) bool {
        return !self.session.busy() and self.launch == null and self.rerun == null;
    }

    /// Runs `line` here after this frame, without a history entry (a
    /// notebook's "Fix with agent" starting the coding agent). False, and
    /// nothing queued, when the shell is busy.
    pub fn launchLine(self: *TerminalTab, line: []const u8) bool {
        if (!self.canLaunch()) return false;
        self.launch = self.gpa.dupe(u8, line) catch return false;
        return true;
    }

    /// A question from elsewhere in the app (a website tab's context menu):
    /// a block headed `label` asks the agent `question`, as a `# question`
    /// typed here would.
    pub fn askAgent(self: *TerminalTab, label: []const u8, question: []const u8) void {
        if (config.get().features.command_fallback_agent == null) {
            self.session.addNote(label, note_no_agent);
            return;
        }
        const b = self.session.restoreBlock(label) orelse return;
        self.scroll = 0;
        self.ask(b, question);
    }

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
            self.failAgent(b, prepareFailure(err, a, &buf));
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
            if (p.kind == .explain) {
                if (text.items.len > 0) {
                    appendExplanation(b, text.items, self.gpa);
                    changed = true;
                }
                for (proposals.items) |cmd| {
                    // The fix the agent suggests: a line of the explanation,
                    // and in the input box for the user to check and run.
                    if (b.explanation.items.len > 0 and b.explanation.items[b.explanation.items.len - 1] != '\n') b.explanation.append(self.gpa, '\n') catch {};
                    b.explanation.appendSlice(self.gpa, "→ ") catch {};
                    b.explanation.appendSlice(self.gpa, cmd) catch {};
                    b.explanation.append(self.gpa, '\n') catch {};
                    self.offer(cmd);
                    changed = true;
                }
                switch (outcome) {
                    .running => i += 1,
                    .done => {
                        b.explain_state = .done;
                        if (b.explanation.items.len == 0) self.explainFailed(b, note_no_explanation);
                        p.req.release();
                        _ = self.pending.swapRemove(i);
                        changed = true;
                    },
                    .failed => {
                        self.explainFailed(b, err.items);
                        p.req.release();
                        _ = self.pending.swapRemove(i);
                        changed = true;
                    },
                }
                continue;
            }
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

    // ── explain a failure ───────────────────────────────────────────────
    // "Explain" on a failed block asks the agent chosen under Settings › AI ›
    // Features › Explain why the command failed. The answer streams into
    // `Block.explanation`, shown under the error and saved with the block,
    // so it is still there after a relaunch.

    /// Asks (or asks again) about `b`; an earlier explanation is replaced.
    fn explain(self: *TerminalTab, b: *Block) void {
        if (b.explain_state == .running) return;
        b.explanation.clearRetainingCapacity();
        b.explain_state = .running;
        const cfg = config.get();
        const name = cfg.features.explain_agent orelse {
            self.explainFailed(b, note_no_explain_agent);
            return;
        };
        const a = cfg.findAgentByName(name) orelse {
            self.explainFailed(b, "The agent chosen for Explain under Settings › AI › Features is no longer set up.");
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const system = self.explainSystemPrompt(arena) catch "";
        const report = self.failureReport(arena, b) catch {
            self.explainFailed(b, "Out of memory.");
            return;
        };
        const messages = [_]agent.Message{.{ .role = .user, .text = report }};
        var prepared = agent.prepare(self.gpa, a, system, &messages, .{ .tools = true }) catch |err| {
            var buf: [256]u8 = undefined;
            self.explainFailed(b, prepareFailure(err, a, &buf));
            return;
        };
        defer prepared.deinit(self.gpa);
        const req = agent.Request.start(&prepared) catch {
            self.explainFailed(b, "Out of memory.");
            return;
        };
        self.pending.append(self.gpa, .{ .block_id = b.id, .req = req, .kind = .explain }) catch {
            req.release();
            self.explainFailed(b, "Out of memory.");
        };
    }

    /// The explanation ends here without an answer, or short of one.
    fn explainFailed(self: *TerminalTab, b: *Block, why: []const u8) void {
        b.explain_state = .failed;
        // Whatever arrived stays; the reason shows when nothing did.
        if (b.explanation.items.len == 0) b.explanation.appendSlice(self.gpa, why) catch {};
    }

    /// What the explain agent is told first: the prompt from Settings › AI ›
    /// Features › Explain (or its default), then where the user is and how
    /// to answer.
    fn explainSystemPrompt(self: *TerminalTab, arena: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, settings_features.promptFor(.explain));
        try out.print(arena, "\n\nContext: the user is in a terminal on macOS running zsh, in the directory {s}", .{self.session.cwd.items});
        if (self.session.branch.items.len > 0) try out.print(arena, " (git branch {s})", .{self.session.branch.items});
        try out.appendSlice(arena, ". The message carries the command that failed, what it printed (stdout and stderr together, as the terminal showed them) and its exit code; the commands run before it may be there too. When a corrected command would fix it, call propose_command with it: it lands in the user's input box for them to check and run, so never assume it ran. Answer in plain text for a monospaced terminal: no Markdown headings or tables, a few short lines.");
        return out.toOwnedSlice(arena);
    }

    /// The failed block as the agents read it: the shell blocks just
    /// before it (for context: a cd, an export …), then the failure itself.
    fn failureReport(self: *TerminalTab, arena: std.mem.Allocator, b: *Block) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        // Up to three earlier shell blocks, within the transcript budget.
        var earlier: std.ArrayList([]const u8) = .empty;
        var budget: usize = max_transcript_bytes / 2;
        var i = self.session.blocks.items.len;
        var seen_self = false;
        while (i > 0 and earlier.items.len < 3) {
            i -= 1;
            const other = self.session.blocks.items[i];
            if (other == b) {
                seen_self = true;
                continue;
            }
            if (!seen_self or other.agent or !other.finished()) continue;
            const t = try blockTranscript(arena, other);
            if (t.len > budget) break;
            budget -= t.len;
            try earlier.append(arena, t);
        }
        if (earlier.items.len > 0) {
            try out.appendSlice(arena, "Commands run just before, oldest first:\n");
            var k = earlier.items.len;
            while (k > 0) {
                k -= 1;
                try out.appendSlice(arena, earlier.items[k]);
            }
            try out.append(arena, '\n');
        }
        try out.appendSlice(arena, "This command failed:\n");
        try out.appendSlice(arena, try blockTranscript(arena, b));
        return out.toOwnedSlice(arena);
    }

    /// Why a request could not even be built, for the block.
    fn prepareFailure(err: agent.PrepareError, a: *const config.Agent, buf: []u8) []const u8 {
        return switch (err) {
            error.NoModel => std.fmt.bufPrint(buf, "The agent “{s}” has no model set (Settings › AI › APIs).", .{a.name}) catch "The agent has no model set.",
            error.NoApiKey => std.fmt.bufPrint(buf, "The agent “{s}” needs an API key (Settings › AI › APIs).", .{a.name}) catch "The agent needs an API key.",
            error.NoBaseUrl => std.fmt.bufPrint(buf, "The agent “{s}” has no base URL (Settings › AI › APIs).", .{a.name}) catch "The agent has no base URL.",
            error.OutOfMemory => "Out of memory.",
        };
    }

    /// Adds explanation text to a block: line breaks kept, CRs and other
    /// control bytes dropped, tabs as spaces.
    fn appendExplanation(b: *Block, text: []const u8, gpa: std.mem.Allocator) void {
        for (text) |c| switch (c) {
            '\r' => {},
            '\t' => b.explanation.appendSlice(gpa, "    ") catch return,
            else => if (c >= 0x20 or c == '\n') b.explanation.append(gpa, c) catch return,
        };
    }

    // ── fix with a coding agent ─────────────────────────────────────────
    // "Fix with agent" on a failed block starts the coding agent chosen
    // under Settings › AI › Features (Claude Code, Codex … from AI › Agents)
    // in this tab's shell, with the failure as its task. It runs like any
    // command typed here — full screen when it takes over the terminal.

    fn fixWithAgent(self: *TerminalTab, b: *Block) void {
        if (self.session.busy() or self.launch != null) return;
        const cfg = config.get();
        const f = &cfg.features;
        if (f.fixOff()) return self.noteFix(b, note_fix_off);
        const scan = coding_agents.get();
        const k: *const coding_agents.Known = blk: {
            if (f.fixAuto()) {
                // Whatever is installed now, not at the last scan.
                scan.rescan();
                const found = scan.first() orelse return self.noteFix(b, note_fix_none);
                break :blk found.known;
            }
            // A chosen agent runs even when the scan did not see it: the
            // shell's PATH may know more than ours.
            break :blk coding_agents.byId(f.fix_agent) orelse return self.noteFix(b, note_fix_unknown);
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var task: std.ArrayList(u8) = .empty;
        task.appendSlice(arena, settings_features.promptFor(.fix)) catch return;
        task.print(arena, "\n\nIn the directory {s}", .{self.session.cwd.items}) catch return;
        if (self.session.branch.items.len > 0) task.print(arena, " (git branch {s})", .{self.session.branch.items}) catch return;
        task.appendSlice(arena, ", this is what happened in the terminal (stdout and stderr together):\n\n") catch return;
        task.appendSlice(arena, self.failureReport(arena, b) catch return) catch return;
        self.launch = coding_agents.launchCommand(self.gpa, k, task.items) catch return;
        self.fix_note_block = 0;
        self.scroll = 0;
    }

    /// Why nothing was launched, shown beside the block's buttons.
    fn noteFix(self: *TerminalTab, b: *Block, why: []const u8) void {
        self.fix_note_block = b.id;
        self.fix_note = why;
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
        self.offer(cmd);
    }

    /// Puts a proposed command in the input box, unless the user is typing
    /// something else there (a newer proposal replaces an earlier one).
    fn offer(self: *TerminalTab, cmd: []const u8) void {
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
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, settings_features.promptFor(.fallback));
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
        if (self.toProgram() or text.len == 0 or !self.editor.atEnd() or self.editor.isMultiline()) return;
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

        // Compact mode: blocks and input take the pane's full width, flush
        // with its edges and bottom, like a plain terminal.
        const col_w = if (theme.compact) rect.w else @max(240, @min(theme.content_max_w, rect.w - 2 * theme.content_pad));
        const col_x = rect.x + (rect.w - col_w) / 2;

        // Output width drives the PTY size so programs wrap where we do.
        const out_cell = ui.text.cellAdvance(theme.font_output);
        const inner_w = col_w - 2 * theme.block_pad_x - 28;
        const cols: u32 = @intFromFloat(@max(20, @floor(inner_w / out_cell)));
        self.session.resize(@intCast(@min(cols, 500)), 40);

        self.refreshSuggestion();
        const input_h = self.inputHeight(ui, col_w);
        const input_rect: Rect = .{ .x = col_x, .y = rect.bottom() - blockEdge(theme.content_pad) - input_h, .w = col_w, .h = input_h };
        const area: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(0, input_rect.y - blockEdge(theme.block_gap) - rect.y) };

        // A click anywhere drops the output selection; a press on output text
        // starts a new one later in this same frame.
        if (ui.pressed) self.sel_block = 0;
        if (self.editor.selection() != null) self.sel_block = 0;
        self.drawBlocks(ui, area, col_x, col_w, cols);
        if (self.unqueue_id != 0) {
            _ = self.session.unqueue(self.unqueue_id);
            self.unqueue_id = 0;
        }
        if (self.resume_id != 0) {
            self.session.resumeFrom(self.resume_id);
            self.resume_id = 0;
        }
        self.drawInput(ui, input_rect, focused);

        if (self.rerun) |cmd| {
            self.rerun = null;
            defer self.gpa.free(cmd);
            self.run(cmd);
        }
        if (self.launch) |cmd| {
            self.launch = null;
            defer self.gpa.free(cmd);
            self.hist_index = null;
            self.scroll = 0;
            self.session.submit(cmd);
        }
    }

    const BlockLayout = struct {
        h: f32,
        header_h: f32,
        rows: u32,
        failed: bool,
        note: ?[]const u8,
        note_lines: u32 = 0,
        /// Lines of the explanation under a failed command (0 = none).
        explain_lines: u32 = 0,
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
            // ⌃C is the user's own doing, not a failure that needs fixing;
            // an agent's failure to answer is not one the agent can fix.
            .failed = b.state == .failed and b.exit_code != 130 and !b.agent,
            .note = b.note,
        };
        if (l.note == null and b.fullscreen and b.finished() and b.total_rows == 0) l.note = note_fullscreen;
        if (l.note) |note| {
            l.note_lines = wrapCount(ui, theme.font_ui, note, col_w - 2 * theme.block_pad_x);
            l.rows = 0;
        }
        const out_h = @as(f32, @floatFromInt(l.rows)) * theme.term_line_h;
        const has_body = l.rows > 0 or l.note != null;

        const pad_y = theme.block_pad_y;
        if (l.failed) {
            l.header_h = pad_y + 21 + (if (has_body) @as(f32, 6) else 0);
            l.h = l.header_h;
            if (l.note != null) l.h += @as(f32, @floatFromInt(l.note_lines)) * 21;
            if (l.rows > 0) l.h += 10 + out_h + 10;
            if (b.explain_state != .none) {
                l.explain_lines = if (b.explanation.items.len == 0) 1 else wrapParagraphCount(ui, theme.font_ui, b.explanation.items, col_w - 2 * theme.block_pad_x);
                l.h += explain_gap + explain_label_h + @as(f32, @floatFromInt(l.explain_lines)) * explain_line_h;
            }
            l.h += pad_y + 34 + pad_y + 2;
        } else {
            l.header_h = pad_y + 21 + (if (has_body) @as(f32, if (theme.compact) 2 else 10) else pad_y);
            l.h = l.header_h;
            if (l.note != null) l.h += @as(f32, @floatFromInt(l.note_lines)) * 21 + pad_y;
            if (l.rows > 0) l.h += out_h + pad_y;
        }
        return l;
    }

    fn drawBlocks(self: *TerminalTab, ui: *Ui, area: Rect, col_x: f32, col_w: f32, cols: u32) void {
        const dl = ui.dl;
        const blocks = self.session.blocks.items;

        // Total height first, so scrolling can be clamped and kept stable.
        var total: f32 = 0;
        const gap = blockEdge(theme.block_gap);
        for (blocks) |b| total += self.layoutBlock(ui, b, cols, col_w).h + gap;
        if (blocks.len > 0) total -= gap;
        total += blockEdge(theme.content_pad); // breathing room above the first block
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
            y -= gap;
            if (y + gap < area.y - 4000) break; // far above the viewport
        }

        sidebar.drawScrollbarAxis(ui, vbar, .vertical, area, max_scroll - self.scroll, total);
    }

    fn drawBlock(self: *TerminalTab, ui: *Ui, b: *Block, l: BlockLayout, r: Rect, area: Rect, cols: u32) void {
        const dl = ui.dl;
        if (theme.compact and !l.failed) {
            // Rows of one listing: no card, a hairline under each block.
            dl.rect(r, theme.bg_block);
            dl.rect(.{ .x = r.x, .y = r.bottom() - 1, .w = r.w, .h = 1 }, theme.line);
        } else dl.shape(r, theme.block_radius, theme.bg_block, if (l.failed) 1 else theme.block_border, if (l.failed) theme.red_line else theme.line);
        const px = r.x + theme.block_pad_x;
        const inner_w = r.w - 2 * theme.block_pad_x;

        // Header: "$ command" … status.
        const head_cy = r.y + theme.block_pad_y + 10.5;
        var status_buf: [64]u8 = undefined;
        var status_x = r.right() - theme.block_pad_x;
        if (b.queued) status_x = self.queueControls(ui, b, status_x, head_cy);
        const status_text = if (b.queued) self.queuedStatus(b) else statusText(b, self.now, &status_buf);
        const status_color = if (b.queued) (if (b.held) theme.text_2 else theme.text_3) else switch (b.state) {
            .failed => if (b.exit_code == 130) theme.text_3 else theme.red,
            .running, .pending => theme.teal,
            .done => theme.text_3,
        };
        const sw = dl.textRight(theme.font_hint, status_x, head_cy, status_text, status_color);

        // "Copy" appears on hover, left of the status.
        var right_limit = status_x - sw - 12;
        if (b.held and self.startsHold(b)) {
            // Only the user sends what waits after a failure on its way:
            // this block and the ones on hold right under it.
            const label = "Resume queue";
            const lw = ui.text.measure(theme.font_hint, label);
            const rr: Rect = .{ .x = right_limit - lw - 16, .y = head_cy - 12, .w = lw + 16, .h = 24 };
            const st = ui.button(Ui.id("block.resume", b.id), rr);
            ui.feedback(rr, 6, st);
            dl.border(rr, 6, 1, theme.line_strong);
            _ = dl.textCentered(theme.font_hint, rr.x + 8, head_cy, label, theme.text);
            if (st.clicked) self.resume_id = b.id;
            right_limit = rr.x - 8;
        }
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
        _ = dl.textEllipsis(theme.font_cmd, cmd_x, head_cy, shown, right_limit - cmd_x, if (b.queued) theme.text_2 else theme.text);

        var y = r.y + l.header_h;

        if (l.note) |note| {
            y = drawWrapped(ui, theme.font_ui, note, px, y, inner_w, 21, theme.text_2);
            if (!l.failed) y += theme.block_pad_y;
        }

        if (l.rows > 0) {
            if (l.failed) {
                const inset: Rect = .{ .x = px, .y = y, .w = inner_w, .h = 20 + @as(f32, @floatFromInt(l.rows)) * theme.term_line_h };
                dl.rrect(inset, theme.row_radius, theme.bg_inset);
                y = self.drawRows(ui, b, l, px + 14, y + 10, area, cols) + 10;
            } else {
                y = self.drawRows(ui, b, l, px, y, area, cols);
            }
        }

        if (l.failed) {
            if (l.explain_lines > 0) y = self.drawExplanation(ui, b, px, y, inner_w);

            // Action row (design: Fix with agent · Explain · Run again).
            const by = y + theme.block_pad_y;
            var bx = px;
            const fix_id = Ui.id("block.fix", b.id);
            bx = self.actionButton(ui, fix_id, bx, by, "Fix with agent", .primary) + 10;
            if (self.clicked_id == fix_id) self.fixWithAgent(b);
            const explain_id = Ui.id("block.explain", b.id);
            const explain_label: []const u8 = switch (b.explain_state) {
                .none => "Explain",
                .running => "Explaining…",
                .done, .failed => "Explain again",
            };
            bx = self.actionButton(ui, explain_id, bx, by, explain_label, .outline) + 10;
            if (self.clicked_id == explain_id) self.explain(b);
            const run_again_id = Ui.id("block.rerun", b.id);
            bx = self.actionButton(ui, run_again_id, bx, by, "Run again", .outline) + 14;
            if (self.clicked_id == run_again_id) self.queueRerun(b.command);
            const right = r.right() - theme.block_pad_x;
            if (self.fix_note_block == b.id and right - bx > 60) {
                _ = dl.textEllipsis(theme.font_hint, bx, by + 17, self.fix_note, right - bx, theme.text_3);
            }
        }
        self.clicked_id = 0;
    }

    /// The × that takes a queued block out of the queue, at the header's
    /// right end; returns where the status text ends.
    fn queueControls(self: *TerminalTab, ui: *Ui, b: *Block, right: f32, cy: f32) f32 {
        const xr: Rect = .{ .x = right - 22, .y = cy - 11, .w = 22, .h = 22 };
        const st = ui.button(Ui.id("block.unqueue", b.id), xr);
        ui.feedback(xr, 6, st);
        ui.dl.icon(.close, xr.x + 4, xr.y + 4, 14, if (st.hover) theme.text else theme.text_3);
        if (st.clicked) self.unqueue_id = b.id;
        return xr.x - 8;
    }

    /// Where a queued block stands: next in line, further back, or on
    /// hold after a failure.
    fn queuedStatus(self: *TerminalTab, b: *const Block) []const u8 {
        if (b.held) return "On hold";
        const next = if (self.session.nextQueued()) |i| self.session.queued.items[i] == b else false;
        if (next) return if (self.session.busy()) "Up next" else "Starting…";
        return "Queued";
    }

    /// `b` is the first of the blocks one failure put on hold: the block
    /// above it in the tab is not on hold.
    fn startsHold(self: *TerminalTab, b: *const Block) bool {
        const blocks = self.session.blocks.items;
        const i = std.mem.indexOfScalar(*Block, blocks, @constCast(b)) orelse return false;
        return i == 0 or !blocks[i - 1].held;
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
                ui.dl.rrect(r, theme.row_radius, if (st.held) theme.accent.alpha(0.8) else if (st.hover) Color.mix(theme.accent, theme.text, 0.18) else theme.accent);
                _ = ui.dl.textCentered(font, r.x + pad, r.centerY(), label, theme.on_accent);
            },
            .outline => {
                ui.feedback(r, theme.row_radius, st);
                ui.dl.border(r, theme.row_radius, 1, theme.line_strong);
                _ = ui.dl.textCentered(font, r.x + pad, r.centerY(), label, theme.text);
            },
        }
        if (st.clicked) self.clicked_id = wid;
        return r.right();
    }

    /// The explanation under a failed command: a label saying how it is
    /// going, then the agent's text, wrapped. Returns the y below it.
    fn drawExplanation(self: *TerminalTab, ui: *Ui, b: *Block, x: f32, y0: f32, w: f32) f32 {
        _ = self;
        const dl = ui.dl;
        var y = y0 + explain_gap;
        const label: []const u8 = switch (b.explain_state) {
            .none => "",
            .running => "Explaining…",
            .done => "Explanation",
            .failed => if (b.explanation.items.len > 0 and !std.mem.startsWith(u8, b.explanation.items, "No agent") and !std.mem.startsWith(u8, b.explanation.items, "The agent")) "Explanation · stopped" else "Could not explain",
        };
        const color = switch (b.explain_state) {
            .running => theme.teal,
            .failed => theme.red,
            else => theme.text_3,
        };
        const cy = y + explain_label_h / 2;
        dl.icon(.sparkle, x, cy - 7, 14, if (b.explain_state == .failed) theme.red else theme.accent);
        _ = dl.textCentered(theme.font_hint, x + 20, cy, label, color);
        y += explain_label_h;
        if (b.explanation.items.len == 0) {
            _ = dl.textCentered(theme.font_ui, x, y + explain_line_h / 2, if (b.explain_state == .running) "Thinking…" else "", theme.text_3);
            return y + explain_line_h;
        }
        return drawWrappedParagraphs(ui, theme.font_ui, b.explanation.items, x, y, w, explain_line_h, if (b.explain_state == .failed and b.explanation.items.len < 200) theme.text_3 else theme.text_2);
    }

    fn queueRerun(self: *TerminalTab, cmd: []const u8) void {
        // While a command runs, the rerun is queued after it.
        if (self.rerun != null) return;
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
        if (b.row_starts.items.len == 0) return y;

        // A link under the pointer: ⌘/⌃-click opens it, before the
        // selection below can take the press.
        var link_buf: [links.max_len]u8 = undefined;
        const link: ?selection.Link = blk: {
            const cell_w = ui.text.cellAdvance(theme.font_output);
            const rows_rect: Rect = .{ .x = x, .y = y, .w = @as(f32, @floatFromInt(cols)) * cell_w, .h = @as(f32, @floatFromInt(l.rows)) * theme.term_line_h };
            if (!ui.mouseIn(rows_rect)) break :blk null;
            const rows: selection.Rows = .{ .starts = b.row_starts.items, .first_row = 0, .rows = l.rows, .cols = cols };
            const found = selection.linkUnder(&b.buf, rows, x, y, cell_w, theme.term_line_h, ui.mx, ui.my, &link_buf) orelse break :blk null;
            _ = ui.link(found.url);
            break :blk found;
        };

        // Mouse text selection (drag; double-click = word, triple-click = line).
        {
            const cell_w = ui.text.cellAdvance(theme.font_output);
            const rows_rect: Rect = .{ .x = x - 6, .y = y, .w = @as(f32, @floatFromInt(cols)) * cell_w + 12, .h = @as(f32, @floatFromInt(l.rows)) * theme.term_line_h };
            const d = ui.drag(Ui.id("block.select", b.id), rows_rect);
            if (d.hover or d.dragging) ui.cursor = .ibeam;
            if (d.started or d.dragging) {
                const rows: selection.Rows = .{ .starts = b.row_starts.items, .first_row = 0, .rows = l.rows, .cols = cols };
                const pos = selection.hitTest(&b.buf, rows, x, y, cell_w, theme.term_line_h, ui.mx, ui.my);
                if (d.started) {
                    self.editor.anchor = null;
                    self.sel_block = b.id;
                    self.sel.press(&b.buf, pos, ui.click_count);
                } else if (self.sel_block == b.id) {
                    self.sel.dragTo(pos);
                }
            }
        }
        const sel: ?[2]selection.Pos = if (self.sel_block == b.id) self.sel.range() else null;

        // Skip rows above the viewport.
        var row: u32 = 0;
        const end_row = l.rows;
        if (y < area.y) {
            const skip: u32 = @intFromFloat(@floor((area.y - y) / theme.term_line_h));
            const s = @min(skip, l.rows);
            row += s;
            y += @as(f32, @floatFromInt(s)) * theme.term_line_h;
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
                y += @as(f32, @floatFromInt(end_row - row)) * theme.term_line_h;
                break;
            }
            while (line_idx + 1 < b.row_starts.items.len and b.row_starts.items[line_idx + 1] <= row) line_idx += 1;
            const cells = b.buf.lines.items[line_idx].cells.items;
            const seg = row - b.row_starts.items[line_idx];
            const from = @min(cells.len, @as(usize, seg) * cols);
            const to = @min(cells.len, from + cols);

            const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, y + theme.term_line_h / 2) * scale);
            const x_px = @round(x * scale);
            var col: f32 = 0;
            for (cells[from..to], from..) |cell, cell_idx| {
                const st = b.buf.style(cell.style);
                if (sel) |s| {
                    const here: selection.Pos = .{ .line = line_idx, .cell = cell_idx };
                    if (!here.before(s[0]) and here.before(s[1])) {
                        const sw: f32 = @floatFromInt(@max(1, gfx_text.cellWidth(cell.cp)));
                        dl.rect(.{ .x = (x_px + col * cell_px) / scale, .y = y, .w = sw * cell_px / scale, .h = theme.term_line_h }, theme.selection());
                    }
                }
                var fg = resolve(st.fg, if (st.bold) theme.text else theme.term_fg, .fg);
                var bg: ?Color = if (st.bg != buffer_mod.color_default) resolve(st.bg, theme.bg_block, .bg) else null;
                if (st.inverse) {
                    const old_fg = fg;
                    fg = bg orelse theme.bg_block;
                    bg = old_fg;
                }
                if (st.dim) fg = fg.alpha(0.6);
                const on_link = if (link) |lk| lk.covers(line_idx, cell_idx) else false;
                if (on_link and ui.linkModifier()) fg = theme.scopeColor(.link);
                const w_cells: f32 = @floatFromInt(@max(1, gfx_text.cellWidth(cell.cp)));
                const cx = (x_px + col * cell_px) / scale;
                if (bg) |c| dl.rect(.{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = theme.term_line_h }, c);
                if (cell.cp != ' ' and !boxdraw.draw(dl, .{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = theme.term_line_h }, cell.cp, fg)) {
                    const font = if (st.bold) theme.font_output_bold else theme.font_output;
                    _ = dl.glyph(font, cell.cp, x_px + col * cell_px, baseline_px, fg, clip);
                }
                if (st.underline or on_link) dl.rect(.{ .x = cx, .y = y + theme.term_line_h - 5, .w = w_cells * cell_px / scale, .h = 1 }, fg);
                if (st.strike) dl.rect(.{ .x = cx, .y = y + theme.term_line_h / 2, .w = w_cells * cell_px / scale, .h = 1 }, fg);
                col += @floatFromInt(gfx_text.cellWidth(cell.cp));
            }
            y += theme.term_line_h;
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
        // A link on the row under the pointer: ⌘/⌃-click opens it instead of
        // reaching the program.
        var link_buf: [links.max_len]u8 = undefined;
        const link = screenLink(ui, rect, rs, cell_w, cell_h, &link_buf);
        if (link) |lk| _ = ui.link(lk.url);
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
                var colors = screenColors(rs, st);
                const on_link = if (link) |lk| lk.row == y and lk.span.contains(cx_i) else false;
                if (on_link and ui.linkModifier()) colors.fg = theme.scopeColor(.link);
                const w_cells: f32 = if (raw.wide == .wide) 2 else 1;
                const gx_px = x0_px + @as(f32, @floatFromInt(cx_i)) * cell_px;
                const cell_rect: Rect = .{ .x = gx_px / scale, .y = row_y, .w = w_cells * cell_w, .h = cell_h };
                if (!boxdraw.draw(dl, cell_rect, cp, colors.fg)) {
                    const font = if (st.flags.bold) theme.font_output_bold else theme.font_output;
                    _ = dl.glyph(font, cp, gx_px, baseline_px, colors.fg, clip);
                }
                if (st.flags.underline != .none or on_link) dl.rect(.{ .x = cell_rect.x, .y = row_y + cell_h - 2, .w = cell_rect.w, .h = 1 }, colors.fg);
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
            .bar => dl.rect(.{ .x = cx, .y = cy, .w = 2, .h = cell_h }, theme.cursor),
            .underline => dl.rect(.{ .x = cx, .y = cy + cell_h - 2, .w = cw, .h = 2 }, theme.cursor),
            .block => {
                dl.rect(r, theme.cursor);
                // The glyph under it, in the cursor's text colour.
                const raw = rs.cursor.cell;
                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };
                if (cp != 0 and cp != ' ' and !boxdraw.draw(dl, r, cp, theme.cursor_text)) {
                    const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, cy + cell_h / 2) * scale);
                    const clip = blk: {
                        const c = dl.currentClip();
                        break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
                    };
                    _ = dl.glyph(theme.font_output, cp, @round(cx * scale), baseline_px, theme.cursor_text, clip);
                }
            },
            else => dl.border(r, 0, 1, theme.cursor),
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

    /// The prompt at the left of the input box, like the robbyrussell zsh
    /// theme: the folder the shell is in (grey), `git:(branch)` when it is
    /// in a repository (blue, the branch red) and the `$` (yellow; `›` in
    /// teal while a program has the input). The pieces come from the shell
    /// hook (`Session.cwd` / `Session.branch`), so they follow every `cd`
    /// and checkout.
    const PromptLayout = struct {
        folder: []const u8,
        branch: []const u8,
        /// Room the branch may take; a longer name gets an ellipsis so the
        /// line stays for the command.
        branch_max_w: f32,
        /// Width of the whole prompt with its trailing space: where the
        /// typed text starts.
        w: f32,
    };

    fn promptLayout(self: *TerminalTab, ui: *Ui, box_w: f32) PromptLayout {
        const cell = ui.text.cellAdvance(theme.font_input);
        const dir = self.session.cwd.items;
        const folder: []const u8 = if (dir.len == 0) "" else if (std.mem.eql(u8, dir, sys.home())) "~" else sys.basename(dir);
        const branch = self.session.branch.items;
        var w: f32 = 0;
        if (folder.len > 0) w += ui.text.measure(theme.font_input, folder) + cell;
        var branch_max_w: f32 = 0;
        if (branch.len > 0) {
            const git_w = ui.text.measure(theme.font_input, "git:(") + ui.text.measure(theme.font_input, ")");
            // The prompt keeps to the left ~40% of the box (never fewer
            // than 4 cells of branch), the rest is for the command.
            const budget = @max(cell * 12, (box_w - 2 * theme.block_pad_x) * 0.4);
            branch_max_w = @max(cell * 4, budget - w - git_w - 3 * cell);
            w += git_w + fitWidth(ui, theme.font_input, branch, branch_max_w) + cell;
        }
        w += cell * 2; // "$ "
        return .{ .folder = folder, .branch = branch, .branch_max_w = branch_max_w, .w = w };
    }

    fn inputLayout(self: *TerminalTab, ui: *Ui, box_w: f32) InputLayout {
        const cell = ui.text.cellAdvance(theme.font_input);
        const prompt_w = self.promptLayout(ui, box_w).w;
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
        return 2 * theme.input_pad_y + @as(f32, @floatFromInt(l.rows)) * input_row_h;
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
        const to_program = self.toProgram();
        if (theme.compact) {
            // Flush with the pane: a line on top says where the focus is.
            dl.rect(r, theme.bg_inset);
            dl.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, border_color);
        } else dl.shape(r, theme.block_radius, theme.bg_inset, 1, border_color);

        const px = r.x + theme.block_pad_x;
        const text_x = px + lay.prompt_w;
        const text_y = r.y + theme.input_pad_y;
        self.text_x = text_x;
        self.text_y = text_y;
        self.text_cols = lay.cols;
        self.cell_w = cell;

        // Prompt: `folder git:(branch) $`.
        {
            const p = self.promptLayout(ui, r.w);
            const pcy = text_y + input_row_h / 2;
            var x = px;
            if (p.folder.len > 0) x += dl.textCentered(theme.font_input, x, pcy, p.folder, theme.text_2) + cell;
            if (p.branch.len > 0) {
                x += dl.textCentered(theme.font_input, x, pcy, "git:(", theme.ansi[4]);
                x += dl.textEllipsis(theme.font_input, x, pcy, p.branch, p.branch_max_w, theme.ansi[1]);
                x += dl.textCentered(theme.font_input, x, pcy, ")", theme.ansi[4]) + cell;
            }
            _ = dl.textCentered(theme.font_input, x, pcy, if (to_program) "›" else "$", if (to_program) theme.teal else theme.ansi[3]);
        }

        // Mouse: place caret / drag-select.
        const text_rect: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = theme.input_pad_y + @as(f32, @floatFromInt(lay.rows)) * input_row_h + 8 };
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
        const masked = to_program;
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

        // While a command runs, an empty box says where ↵ sends a line.
        if (busy and self.editor.isEmpty() and self.editor.marked.items.len == 0) {
            const hint: []const u8 = if (to_program) "The program asks for a hidden answer · ↵ sends it" else "↵ queue next · ⌥↵ send to the running program";
            const room = (r.right() - theme.block_pad_x) - (cx + 3);
            _ = dl.textEllipsis(theme.font_input, cx + 3, cy + input_row_h / 2, hint, room, theme.text_3);
        }

        // Ghost suggestion after the caret.
        const has_suggestion = self.suggestion.items.len > 0 and self.editor.atEnd() and self.editor.marked.items.len == 0;
        if (has_suggestion) {
            const room = (r.right() - theme.block_pad_x) - (cx + 3);
            _ = dl.textEllipsis(theme.font_input, cx + 3, cy + input_row_h / 2, self.suggestion.items, room, theme.text_3);
        }
    }
};

// ── helpers ──────────────────────────────────────────────────────────────
/// A position in a block's output: logical line + cell index.
/// Width `DrawList.textEllipsis` will use for `str` within `max_w`: the
/// whole string when it fits, else the longest prefix plus the ellipsis.
fn fitWidth(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32) f32 {
    if (max_w <= 0) return 0;
    const full = ui.text.measure(font, str);
    if (full <= max_w) return full;
    const ell_w = ui.text.measure(font, "…");
    var it = gfx_text.Utf8Iter{ .bytes = str };
    var w: f32 = 0;
    var end: usize = 0;
    while (it.next()) |cp| {
        const adv = ui.text.advance(font, cp);
        if (w + adv + ell_w > max_w) break;
        w += adv;
        end = it.index;
    }
    while (end > 0 and str[end - 1] == ' ') {
        end -= 1;
        w -= ui.text.advance(font, ' ');
    }
    return w + ell_w;
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
        // A finished command needs no label: just how long it took.
        .done => if (d >= 1.0) (std.fmt.bufPrint(buf, "{s}", .{dur}) catch "") else "",
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
const ScreenLink = struct { row: usize, span: links.Span, url: []const u8 };

fn screenCp(raw: screen_mod.Cell) u21 {
    return switch (raw.content_tag) {
        .codepoint, .codepoint_grapheme => if (raw.content.codepoint.data == 0) ' ' else raw.content.codepoint.data,
        else => ' ',
    };
}

/// The link on the full-screen row under the pointer (a program's own
/// wrapping is not known, so one row at a time), its address in `out`.
fn screenLink(ui: *Ui, rect: Rect, rs: *const screen_mod.RenderState, cell_w: f32, cell_h: f32, out: []u8) ?ScreenLink {
    if (!ui.mouseIn(rect)) return null;
    const col: usize = @intFromFloat(@floor((ui.mx - rect.x) / cell_w));
    const row: usize = @intFromFloat(@floor((ui.my - rect.y) / cell_h));
    const rows_cells = rs.row_data.items(.cells);
    if (row >= rs.rows or row >= rows_cells.len) return null;
    const raws = rows_cells[row].slice().items(.raw);
    const span = links.spanAt(screen_mod.Cell, raws, col, screenCp) orelse return null;
    if (span.end - span.start > out.len) return null;
    for (raws[span.start..span.end], 0..) |raw, i| out[i] = @intCast(screenCp(raw));
    return .{ .row = row, .span = span, .url = out[0 .. span.end - span.start] };
}

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

const wrap = @import("../ui/wrap.zig");
const wrapLines = wrap.wrapLines;
const wrapParagraphs = wrap.wrapParagraphs;
const wrapParagraphCount = wrap.wrapParagraphCount;
const drawWrappedParagraphs = wrap.drawWrappedParagraphs;
const wrapCount = wrap.wrapCount;
const drawWrapped = wrap.drawWrapped;

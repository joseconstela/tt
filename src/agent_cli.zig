//! Asking a coding agent's CLI (Claude Code, Codex, Gemini CLI …) one
//! question without its interface: what "Unrecognised commands" does when
//! a coding agent, not an API, is chosen for it under Settings › AI ›
//! Features. The agent is started as its `coding_agents.Known.ask`
//! arguments say (`claude --tools "" -p <prompt>` and the like), in the
//! directory the question is about, with nothing on stdin; what it prints
//! is the answer.
//!
//! Such a program has no `propose_command` tool to call, so the prompt
//! asks for the command in a fenced code block (`command_form` /
//! `cell_form`) and `parseReply` takes the last block out of the answer:
//! it becomes the proposal, exactly as an API agent's tool call would. The
//! answer arrives whole when the program exits, not streamed.
//!
//! `Reply` is either kind of request — an API's (`agent.Request`) or a
//! CLI's (`Request` here) — behind the three calls a tab makes on one, and
//! `answerer` says which of the two the config asks for.
const std = @import("std");
const sys = @import("sys.zig");
const agent = @import("agent.zig");
const config = @import("config.zig");
const coding_agents = @import("coding_agents.zig");

pub const Status = agent.Status;

/// How a coding agent is told to hand over a shell command (the API
/// agents are told to call `propose_command` instead).
pub const command_form = "When a command would do what the user wants, end your answer with that command alone in a fenced code block (three backticks, nothing after it): it lands in the user's input box for them to check and run, so never assume it ran and never make up its output; say in a line what it does. Run nothing yourself and use no tools: answer from what this message says.";
/// The same for a notebook: the block is the source of one new cell.
pub const cell_form = "When code would do what the user wants, end your answer with the source of one new cell alone in a fenced code block (three backticks, nothing after it): it is added to the notebook under the question for the user to review and run, so never assume it ran and never make up its output; say in a line what it does. Run nothing yourself and use no tools: answer from what this message says.";

/// Who answers "Unrecognised commands" (and what else asks that agent: a
/// `# question`, a notebook's ask cell).
pub const Answerer = union(enum) {
    off,
    api: *const config.Agent,
    /// The API chosen is no longer set up.
    api_gone,
    cli: Cli,
    /// The coding agent chosen is not one tt can ask.
    cli_gone,

    pub const Cli = struct {
        known: *const coding_agents.Known,
        /// Where the scan found it; null leaves the name to PATH.
        path: ?[]const u8,
    };
};

/// A coding agent, when one is chosen, comes before the API.
pub fn answerer(cfg: *config.Config) Answerer {
    const f = &cfg.features;
    if (f.command_fallback_coding_agent.len > 0) {
        const k = coding_agents.byId(f.command_fallback_coding_agent) orelse return .cli_gone;
        if (k.ask == null) return .cli_gone;
        const found = coding_agents.get().find(k.id);
        return .{ .cli = .{ .known = k, .path = if (found) |x| x.path else null } };
    }
    const name = f.command_fallback_agent orelse return .off;
    const a = cfg.findAgentByName(name) orelse return .api_gone;
    return .{ .api = a };
}

pub const note_cli_gone = "The coding agent chosen under Settings › AI › Features cannot answer here: pick another.";

/// The one prompt a CLI gets: what an API would get as the system prompt,
/// the earlier turns, then the last message.
pub fn flatten(arena: std.mem.Allocator, system: []const u8, messages: []const agent.Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, system);
    if (messages.len > 1) {
        try out.appendSlice(arena, "\n\nEarlier in this conversation, oldest first:");
        for (messages[0 .. messages.len - 1]) |m| {
            try out.appendSlice(arena, if (m.role == .user) "\n\n[user]\n" else "\n\n[you answered]\n");
            try out.appendSlice(arena, m.text);
        }
        try out.appendSlice(arena, "\n\nNow:");
    }
    if (messages.len > 0) {
        try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, messages[messages.len - 1].text);
    }
    return out.toOwnedSlice(arena);
}

/// An answer split into its text and the command it ends with.
pub const Parsed = struct {
    text: []u8,
    command: ?[]u8,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.command) |c| gpa.free(c);
    }
};

/// Reads what a CLI printed: terminal escapes and CRs dropped, the last
/// fenced code block taken out as the command (none when the answer has
/// no block, or an empty one), the fence lines of earlier blocks dropped
/// while their content stays. An unclosed last fence runs to the end.
pub fn parseReply(gpa: std.mem.Allocator, raw: []const u8) !Parsed {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    try stripEscapes(gpa, &clean, raw);

    // The fence lines, as line indices.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var fences: std.ArrayList(usize) = .empty;
    defer fences.deinit(gpa);
    var it = std.mem.splitScalar(u8, clean.items, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) try fences.append(gpa, lines.items.len);
        try lines.append(gpa, line);
    }
    // The last block: its opening fence is the last one at an even place.
    var open: ?usize = null;
    var close: usize = lines.items.len;
    if (fences.items.len > 0) {
        const last_open = (fences.items.len - 1) & ~@as(usize, 1);
        open = fences.items[last_open];
        if (last_open + 1 < fences.items.len) close = fences.items[last_open + 1];
    }

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    var next_fence: usize = 0;
    for (lines.items, 0..) |line, i| {
        if (next_fence < fences.items.len and fences.items[next_fence] == i) {
            next_fence += 1;
            continue;
        }
        const in_block = if (open) |o| i > o and i < close else false;
        const dst = if (in_block) &command else &text;
        try dst.appendSlice(gpa, line);
        try dst.append(gpa, '\n');
    }
    const cmd = std.mem.trim(u8, command.items, " \t\n");
    const body = std.mem.trim(u8, text.items, " \t\n");
    const kept_cmd: ?[]u8 = if (cmd.len > 0) try gpa.dupe(u8, cmd) else null;
    errdefer if (kept_cmd) |c| gpa.free(c);
    var kept_text: std.ArrayList(u8) = .empty;
    errdefer kept_text.deinit(gpa);
    if (body.len > 0) {
        try kept_text.appendSlice(gpa, body);
        try kept_text.append(gpa, '\n');
    }
    text.deinit(gpa);
    return .{ .text = try kept_text.toOwnedSlice(gpa), .command = kept_cmd };
}

/// `raw` without CSI / OSC escape sequences, other control bytes (tabs and
/// line breaks stay) and CRs.
fn stripEscapes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const b = raw[i];
        if (b == 0x1b and i + 1 < raw.len) {
            if (raw[i + 1] == '[') {
                // CSI: parameters, then one final byte @ … ~.
                i += 2;
                while (i < raw.len and (raw[i] < 0x40 or raw[i] > 0x7e)) i += 1;
                i += 1;
                continue;
            }
            if (raw[i + 1] == ']') {
                // OSC: up to BEL or ESC \.
                i += 2;
                while (i < raw.len and raw[i] != 0x07 and raw[i] != 0x1b) i += 1;
                if (i < raw.len and raw[i] == 0x1b) i += 1;
                i += 1;
                continue;
            }
            i += 2;
            continue;
        }
        if (b == '\n' or b == '\t' or (b >= 0x20 and b != 0x7f)) try out.append(gpa, b);
        i += 1;
    }
}

/// One question on its way through a coding agent's CLI. The program runs
/// on a thread of the request's own; the owner picks the answer up on its
/// tick with `take`, as it does an API's.
pub const Request = struct {
    gpa: std.mem.Allocator,
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    status: Status = .running,
    text: []u8 = &.{},
    command: ?[]u8 = null,
    err: std.ArrayList(u8) = .empty,
    /// `take` handed the answer over.
    delivered: bool = false,
    /// The owner is gone: the thread frees the request when it ends.
    released: bool = false,
    watch: sys.Watch = .{},
    // What to run; the request's own copies.
    argv: [][]u8,
    cwd: []u8,
    path_env: []u8,
    label: []const u8,

    pub const StartError = error{ OutOfMemory, NoAskMode, NoThread };

    /// Starts `who` on `prompt` in `cwd`.
    pub fn start(who: Answerer.Cli, cwd: []const u8, prompt: []const u8) StartError!*Request {
        const gpa = std.heap.c_allocator;
        const borrowed = (try coding_agents.askArgv(gpa, who.known, who.path, prompt)) orelse return error.NoAskMode;
        defer gpa.free(borrowed);
        const argv = try gpa.alloc([]u8, borrowed.len);
        var made: usize = 0;
        errdefer {
            for (argv[0..made]) |a| gpa.free(a);
            gpa.free(argv);
        }
        for (borrowed) |a| {
            argv[made] = try gpa.dupe(u8, a);
            made += 1;
        }
        const cwd_copy = try gpa.dupe(u8, cwd);
        errdefer gpa.free(cwd_copy);
        const path_env = try coding_agents.pathEnv(gpa, who.path);
        errdefer gpa.free(path_env);
        const self = try gpa.create(Request);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .argv = argv, .cwd = cwd_copy, .path_env = path_env, .label = who.known.label };
        const thread = std.Thread.spawn(.{}, run, .{self}) catch return error.NoThread;
        thread.detach();
        return self;
    }

    fn run(self: *Request) void {
        var result = sys.runWatched(self.gpa, self.cwd, self.argv, &.{self.path_env}, &self.watch) catch |e| {
            self.settle(.failed, &.{}, null, switch (e) {
                error.SpawnFailed => "could not be started: is it still installed? (Settings › AI › Agents)",
                else => "could not be run.",
            });
            return;
        };
        defer result.deinit();
        if (self.watch.stopped.load(.seq_cst)) return self.settle(.failed, &.{}, null, "");
        if (!result.ok()) {
            // What it had to say for itself: stderr first, else stdout.
            var buf: [64]u8 = undefined;
            var why = firstLine(result.stderr);
            if (why.len == 0) why = firstLine(result.stdout);
            if (why.len == 0) why = std.fmt.bufPrint(&buf, "ended with status {d}.", .{result.status}) catch "failed.";
            return self.settle(.failed, &.{}, null, why);
        }
        var parsed = parseReply(self.gpa, result.stdout) catch return self.settle(.failed, &.{}, null, "ran out of memory.");
        self.settle(.done, parsed.text, parsed.command, "");
        parsed = undefined;
    }

    /// The thread's last word: the outcome, and the request itself when
    /// nobody is waiting for it any more. Takes `text` and `command`.
    fn settle(self: *Request, status: Status, text: []u8, command: ?[]u8, why: []const u8) void {
        self.lockMutex();
        self.text = text;
        self.command = command;
        if (status == .failed) {
            if (why.len == 0) {
                self.err.appendSlice(self.gpa, "Stopped.") catch {};
            } else {
                self.err.print(self.gpa, "{s}: {s}", .{ self.label, why }) catch {};
            }
        }
        self.status = status;
        const gone = self.released;
        self.unlockMutex();
        if (gone) self.destroy();
    }

    /// As `agent.Request.take`: the answer, whole, once the program is
    /// over (`text` and at most one proposal, copies the caller frees with
    /// `gpa`), and how it ended (`err` gets the reason).
    pub fn take(self: *Request, text: *std.ArrayList(u8), proposals: *std.ArrayList([]u8), err: *std.ArrayList(u8), gpa: std.mem.Allocator) Status {
        self.lockMutex();
        defer self.unlockMutex();
        if (self.status == .running) return .running;
        if (!self.delivered) {
            self.delivered = true;
            text.appendSlice(gpa, self.text) catch {};
            if (self.command) |c| {
                if (gpa.dupe(u8, c)) |copy| proposals.append(gpa, copy) catch gpa.free(copy) else |_| {}
            }
        }
        if (self.status == .failed) err.appendSlice(gpa, self.err.items) catch {};
        return self.status;
    }

    /// Stops the program; the request ends as failed with "Stopped.".
    pub fn cancel(self: *Request) void {
        self.watch.stop();
    }

    /// The owner is done with the request: freed now when the program is
    /// over, else stopped and freed by its thread.
    pub fn release(self: *Request) void {
        self.lockMutex();
        const over = self.status != .running;
        self.released = true;
        self.unlockMutex();
        if (over) self.destroy() else self.watch.stop();
    }

    fn destroy(self: *Request) void {
        const gpa = self.gpa;
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        gpa.free(self.cwd);
        gpa.free(self.path_env);
        gpa.free(self.text);
        if (self.command) |c| gpa.free(c);
        self.err.deinit(gpa);
        gpa.destroy(self);
    }

    fn lockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_lock(&self.lock);
    }

    fn unlockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_unlock(&self.lock);
    }
};

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    const end = std.mem.indexOfAny(u8, t, "\r\n") orelse t.len;
    return t[0..@min(end, 300)];
}

/// A question on its way, whoever answers it.
pub const Reply = union(enum) {
    api: *agent.Request,
    cli: *Request,

    pub fn take(self: Reply, text: *std.ArrayList(u8), proposals: *std.ArrayList([]u8), err: *std.ArrayList(u8), gpa: std.mem.Allocator) Status {
        return switch (self) {
            inline else => |r| r.take(text, proposals, err, gpa),
        };
    }

    pub fn cancel(self: Reply) void {
        switch (self) {
            inline else => |r| r.cancel(),
        }
    }

    pub fn release(self: Reply) void {
        switch (self) {
            inline else => |r| r.release(),
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
test "parseReply: the last fenced block is the command, the rest the text" {
    const gpa = std.testing.allocator;
    var a = try parseReply(gpa, "Lists files by size, largest first:\n\n```zsh\nls -lhS\n```\n");
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("Lists files by size, largest first:\n", a.text);
    try std.testing.expectEqualStrings("ls -lhS", a.command.?);

    // No block: all text, nothing proposed.
    var b = try parseReply(gpa, "That is not something a command does.\r\n");
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("That is not something a command does.\n", b.text);
    try std.testing.expect(b.command == null);

    // Two blocks: the first stays in the text without its fences.
    var c = try parseReply(gpa, "First try:\n```\nfoo --bar\n```\nor better:\n  ```sh\n  git status \\\n    --short\n  ```\ntrailing words");
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("First try:\nfoo --bar\nor better:\ntrailing words\n", c.text);
    try std.testing.expectEqualStrings("git status \\\n    --short", c.command.?);

    // An unclosed fence runs to the end; an empty block proposes nothing.
    var d = try parseReply(gpa, "Run:\n```\nmake test");
    defer d.deinit(gpa);
    try std.testing.expectEqualStrings("make test", d.command.?);
    var e = try parseReply(gpa, "Nothing:\n```\n```\n");
    defer e.deinit(gpa);
    try std.testing.expect(e.command == null);
    try std.testing.expectEqualStrings("Nothing:\n", e.text);

    // Only a command.
    var f = try parseReply(gpa, "```\nls\n```");
    defer f.deinit(gpa);
    try std.testing.expectEqualStrings("", f.text);
    try std.testing.expectEqualStrings("ls", f.command.?);
}

test "parseReply: terminal escapes and control bytes are dropped" {
    const gpa = std.testing.allocator;
    var a = try parseReply(gpa, "\x1b[1m\x1b[91mBold\x1b[0m and \x1b]8;;http://x\x07link\x1b]8;;\x1b\\ \x07done\n```\n\x1b[32mls\x1b[0m\n```\n");
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("Bold and link done\n", a.text);
    try std.testing.expectEqualStrings("ls", a.command.?);
}

test "flatten: the system text, the earlier turns, then the question" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = try flatten(arena, "Be brief.", &.{.{ .role = .user, .text = "list files" }});
    try std.testing.expectEqualStrings("Be brief.\n\nlist files", one);
    const three = try flatten(arena, "Be brief.", &.{
        .{ .role = .user, .text = "list files" },
        .{ .role = .assistant, .text = "ls" },
        .{ .role = .user, .text = "by size" },
    });
    try std.testing.expectEqualStrings("Be brief.\n\nEarlier in this conversation, oldest first:\n\n[user]\nlist files\n\n[you answered]\nls\n\nNow:\n\nby size", three);
}

/// A stand-in coding agent: an executable script named `claude` in a
/// folder of its own. Returns the script's path (the caller frees it and
/// removes the folder with `removeFake`).
fn makeFake(gpa: std.mem.Allocator, tag: []const u8, script: []const u8) ![]u8 {
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/tt-agent-cli-{s}-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), tag, std.c.getpid() });
    defer gpa.free(dir);
    sys.mkdir(gpa, dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/claude", .{dir});
    errdefer gpa.free(path);
    try sys.writeFile(gpa, path, script, false);
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    _ = std.c.chmod(pz.ptr, 0o755);
    return path;
}

fn removeFake(gpa: std.mem.Allocator, path: []u8) void {
    sys.deleteFile(gpa, path);
    if (gpa.dupeSentinel(u8, sys.dirname(path), 0)) |dz| {
        _ = std.c.rmdir(dz.ptr);
        gpa.free(dz);
    } else |_| {}
    gpa.free(path);
}

/// Waits for `req` to end, collecting what it hands over.
fn waitFor(req: *Request, text: *std.ArrayList(u8), proposals: *std.ArrayList([]u8), err: *std.ArrayList(u8), gpa: std.mem.Allocator) Status {
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        const st = req.take(text, proposals, err, gpa);
        if (st != .running) return st;
        _ = sys.usleep(5_000);
    }
    return .running;
}

test "Request: runs the agent with its arguments and the prompt, reads the answer" {
    const gpa = std.testing.allocator;
    // Says what it was given, so the test sees the arguments arrive whole.
    const path = try makeFake(gpa, "ok",
        \\#!/bin/sh
        \\[ "$1" = "--tools" ] && [ "$2" = "" ] && [ "$4" = "-p" ] || { echo "bad arguments: $*" >&2; exit 2; }
        \\echo "You said: $5"
        \\echo "in $(basename "$PWD")"
        \\echo '```'
        \\echo "ls -lhS"
        \\echo '```'
        \\
    );
    defer removeFake(gpa, path);
    const req = try Request.start(.{ .known = coding_agents.byId("claude").?, .path = path }, "/usr/bin", "list 'my files'\nby size");
    defer req.release();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var proposals: std.ArrayList([]u8) = .empty;
    defer {
        for (proposals.items) |p| gpa.free(p);
        proposals.deinit(gpa);
    }
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    try std.testing.expectEqual(Status.done, waitFor(req, &text, &proposals, &err, gpa));
    try std.testing.expectEqualStrings("You said: list 'my files'\nby size\nin bin\n", text.items);
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqualStrings("ls -lhS", proposals.items[0]);
    // Handed over once.
    try std.testing.expectEqual(Status.done, req.take(&text, &proposals, &err, gpa));
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
}

test "Request: a failing agent says why, a missing one that it is missing" {
    const gpa = std.testing.allocator;
    const path = try makeFake(gpa, "fail", "#!/bin/sh\necho 'Not logged in. Run /login' >&2\nexit 1\n");
    defer removeFake(gpa, path);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var proposals: std.ArrayList([]u8) = .empty;
    defer proposals.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    const req = try Request.start(.{ .known = coding_agents.byId("claude").?, .path = path }, "/", "x");
    try std.testing.expectEqual(Status.failed, waitFor(req, &text, &proposals, &err, gpa));
    req.release();
    try std.testing.expectEqualStrings("Claude Code: Not logged in. Run /login", err.items);

    err.clearRetainingCapacity();
    const gone = try Request.start(.{ .known = coding_agents.byId("claude").?, .path = "/nonexistent/tt/claude" }, "/", "x");
    try std.testing.expectEqual(Status.failed, waitFor(gone, &text, &proposals, &err, gpa));
    gone.release();
    try std.testing.expect(std.mem.startsWith(u8, err.items, "Claude Code: could not be started"));
    try std.testing.expectEqual(@as(usize, 0), text.items.len);
}

test "Request: cancel stops the agent and what it started" {
    const gpa = std.testing.allocator;
    const path = try makeFake(gpa, "slow", "#!/bin/sh\nsleep 30 &\nwait\necho late\n");
    defer removeFake(gpa, path);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var proposals: std.ArrayList([]u8) = .empty;
    defer proposals.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    const req = try Request.start(.{ .known = coding_agents.byId("claude").?, .path = path }, "/", "x");
    _ = sys.usleep(100_000);
    try std.testing.expectEqual(Status.running, req.take(&text, &proposals, &err, gpa));
    req.cancel();
    try std.testing.expectEqual(Status.failed, waitFor(req, &text, &proposals, &err, gpa));
    req.release();
    try std.testing.expectEqualStrings("Stopped.", err.items);
}

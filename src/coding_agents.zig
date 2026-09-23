//! The coding agents that may be installed on this Mac — Claude Code,
//! Codex, Gemini CLI … — as opposed to the model APIs in `config.zig`.
//! Knows which ones to look for, finds the ones that are there (Settings ›
//! AI › Agents shows the result) and builds the shell line that starts one
//! on a task ("Fix with agent" on a failed block). Nothing here runs
//! anything: the line goes to the tab's own shell like a typed command.
const std = @import("std");
const sys = @import("sys.zig");

/// A coding agent tt knows how to launch.
pub const Known = struct {
    /// Stable id, what the config stores (`features.fix_agent`).
    id: []const u8,
    label: []const u8,
    /// The executable looked for.
    binary: []const u8,
    /// How it is started on a task: `{prompt}` becomes the quoted prompt.
    template: []const u8,
    blurb: []const u8,
    /// How to get it, for the card of one that is not installed.
    install: []const u8,
};

/// In the order they are listed and, for "automatic", tried.
pub const known = [_]Known{
    .{ .id = "claude", .label = "Claude Code", .binary = "claude", .template = "claude {prompt}", .blurb = "Anthropic's coding agent for the terminal.", .install = "npm install -g @anthropic-ai/claude-code" },
    .{ .id = "codex", .label = "Codex", .binary = "codex", .template = "codex {prompt}", .blurb = "OpenAI's coding agent for the terminal.", .install = "npm install -g @openai/codex" },
    .{ .id = "gemini", .label = "Gemini CLI", .binary = "gemini", .template = "gemini -i {prompt}", .blurb = "Google's coding agent for the terminal.", .install = "npm install -g @google/gemini-cli" },
    .{ .id = "opencode", .label = "OpenCode", .binary = "opencode", .template = "opencode --prompt {prompt}", .blurb = "Open-source agent that works with any model.", .install = "curl -fsSL https://opencode.ai/install | bash" },
    .{ .id = "copilot", .label = "GitHub Copilot CLI", .binary = "copilot", .template = "copilot -i -p {prompt}", .blurb = "GitHub's coding agent for the terminal.", .install = "npm install -g @github/copilot" },
    .{ .id = "cursor", .label = "Cursor Agent", .binary = "cursor-agent", .template = "cursor-agent {prompt}", .blurb = "Cursor's agent for the terminal.", .install = "curl https://cursor.com/install -fsS | bash" },
    .{ .id = "aider", .label = "Aider", .binary = "aider", .template = "aider --message {prompt}", .blurb = "Pair programming in the terminal; runs the task and hands back.", .install = "python -m pip install aider-install && aider-install" },
    .{ .id = "goose", .label = "Goose", .binary = "goose", .template = "goose run -s -t {prompt}", .blurb = "Block's open-source agent.", .install = "brew install block-goose-cli" },
};

pub fn byId(id: []const u8) ?*const Known {
    for (&known) |*k| {
        if (std.mem.eql(u8, k.id, id)) return k;
    }
    return null;
}

/// A known agent that is installed, and where.
pub const Found = struct { known: *const Known, path: []u8 };

/// The result of looking for the known agents. `ensure` looks once,
/// `rescan` again (the Settings page has a button for it).
pub const Scan = struct {
    gpa: std.mem.Allocator,
    found: std.ArrayList(Found) = .empty,
    done: bool = false,

    pub fn init(gpa: std.mem.Allocator) Scan {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scan) void {
        self.clear();
        self.found.deinit(self.gpa);
    }

    fn clear(self: *Scan) void {
        for (self.found.items) |f| self.gpa.free(f.path);
        self.found.clearRetainingCapacity();
    }

    pub fn ensure(self: *Scan) void {
        if (!self.done) self.rescan();
    }

    /// Looks for every known agent in the app's PATH and the folders the
    /// installers use (the app's PATH is short when launched from Finder).
    pub fn rescan(self: *Scan) void {
        self.done = true;
        self.clear();
        var dirs: std.ArrayList([]const u8) = .empty;
        defer {
            for (dirs.items) |d| self.gpa.free(d);
            dirs.deinit(self.gpa);
        }
        if (sys.getenv("PATH")) |path| {
            var it = std.mem.splitScalar(u8, path, ':');
            while (it.next()) |d| {
                if (d.len == 0) continue;
                dirs.append(self.gpa, self.gpa.dupe(u8, d) catch continue) catch continue;
            }
        }
        const home = sys.home();
        const Extra = struct { in_home: bool, path: []const u8 };
        const extras = [_]Extra{
            .{ .in_home = true, .path = "/.local/bin" },
            .{ .in_home = false, .path = "/opt/homebrew/bin" },
            .{ .in_home = false, .path = "/usr/local/bin" },
            .{ .in_home = true, .path = "/.opencode/bin" },
            .{ .in_home = true, .path = "/.bun/bin" },
            .{ .in_home = true, .path = "/.npm-global/bin" },
            .{ .in_home = true, .path = "/.cargo/bin" },
            .{ .in_home = true, .path = "/go/bin" },
            .{ .in_home = true, .path = "/.claude/local" },
        };
        for (extras) |e| {
            const d = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ if (e.in_home) home else "", e.path }) catch continue;
            dirs.append(self.gpa, d) catch self.gpa.free(d);
        }
        self.scanDirs(dirs.items);
    }

    /// Looks in `dirs`, in order; the first match of a binary wins.
    pub fn scanDirs(self: *Scan, dirs: []const []const u8) void {
        self.done = true;
        self.clear();
        for (&known) |*k| {
            const path = locate(self.gpa, k.binary, dirs) orelse continue;
            self.found.append(self.gpa, .{ .known = k, .path = path }) catch self.gpa.free(path);
        }
    }

    pub fn find(self: *const Scan, id: []const u8) ?*const Found {
        for (self.found.items) |*f| {
            if (std.mem.eql(u8, f.known.id, id)) return f;
        }
        return null;
    }

    /// The agent "automatic" picks: the first installed one.
    pub fn first(self: *const Scan) ?*const Found {
        if (self.found.items.len == 0) return null;
        return &self.found.items[0];
    }
};

/// The first `dirs` entry holding an executable file named `binary`.
pub fn locate(gpa: std.mem.Allocator, binary: []const u8, dirs: []const []const u8) ?[]u8 {
    for (dirs) |d| {
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, binary }) catch return null;
        if (isExecutableFile(gpa, path)) return path;
        gpa.free(path);
    }
    return null;
}

fn isExecutableFile(gpa: std.mem.Allocator, path: []const u8) bool {
    const st = sys.statFile(gpa, path) orelse return false;
    // S_IFMT / S_IFREG: a regular file (or a symlink to one), not a folder.
    if (st.mode & 0o170000 != 0o100000) return false;
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.X_OK) == 0;
}

/// The shell line that starts `k` on `prompt`: the template with
/// `{prompt}` replaced by the prompt in zsh's `$'…'` quoting, so the line
/// stays a single line whatever the prompt contains. Owned by the caller.
pub fn launchCommand(gpa: std.mem.Allocator, k: *const Known, prompt: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const marker = "{prompt}";
    if (std.mem.indexOf(u8, k.template, marker)) |at| {
        try out.appendSlice(gpa, k.template[0..at]);
        try quote(&out, gpa, prompt);
        try out.appendSlice(gpa, k.template[at + marker.len ..]);
    } else {
        try out.appendSlice(gpa, k.template);
        try out.append(gpa, ' ');
        try quote(&out, gpa, prompt);
    }
    return out.toOwnedSlice(gpa);
}

/// `s` as a zsh `$'…'` word: backslash and quote escaped, line breaks and
/// tabs as `\n` / `\t`, other control bytes as `\xHH`; UTF-8 passes through.
pub fn quote(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(gpa, "$'");
    for (s) |ch| switch (ch) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\'' => try out.appendSlice(gpa, "\\'"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => if (ch < 0x20 or ch == 0x7f) try out.print(gpa, "\\x{X:0>2}", .{ch}) else try out.append(gpa, ch),
    };
    try out.append(gpa, '\'');
}

// ── the single instance ─────────────────────────────────────────────────
var current: ?Scan = null;

/// The scan shared by the app, made (and run) on first use.
pub fn get() *Scan {
    if (current == null) current = Scan.init(std.heap.c_allocator);
    const s = &current.?;
    s.ensure();
    return s;
}

// ── tests ───────────────────────────────────────────────────────────────
test "quote: zsh $'…' keeps everything on one line" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try quote(&out, gpa, "it's a \"test\"\n\twith \\ and \x1b[31m colour, ünïcode");
    try std.testing.expectEqualStrings("$'it\\'s a \"test\"\\n\\twith \\\\ and \\x1B[31m colour, ünïcode'", out.items);
}

test "launchCommand: the template's {prompt} takes the quoted prompt" {
    const gpa = std.testing.allocator;
    const claude = byId("claude").?;
    const line = try launchCommand(gpa, claude, "fix it\nplease");
    defer gpa.free(line);
    try std.testing.expectEqualStrings("claude $'fix it\\nplease'", line);
    const gemini = byId("gemini").?;
    const line2 = try launchCommand(gpa, gemini, "x");
    defer gpa.free(line2);
    try std.testing.expectEqualStrings("gemini -i $'x'", line2);
    // A template without the marker gets the prompt appended.
    const bare: Known = .{ .id = "t", .label = "t", .binary = "t", .template = "tool --go", .blurb = "", .install = "" };
    const line3 = try launchCommand(gpa, &bare, "a");
    defer gpa.free(line3);
    try std.testing.expectEqualStrings("tool --go $'a'", line3);
    try std.testing.expect(byId("nonsense") == null);
}

test "scanDirs: finds executables by name, first folder wins, skips non-executables and folders" {
    const gpa = std.testing.allocator;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const root = try std.fmt.allocPrint(gpa, "{s}/tt-coding-agents-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), std.c.getpid() });
    defer gpa.free(root);
    const a = try std.fmt.allocPrint(gpa, "{s}/a", .{root});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/b", .{root});
    defer gpa.free(b);
    sys.mkdir(gpa, root);
    sys.mkdir(gpa, a);
    sys.mkdir(gpa, b);
    const files = [_]struct { dir: []const u8, name: []const u8, exec: bool, dir_entry: bool = false }{
        .{ .dir = a, .name = "claude", .exec = true },
        .{ .dir = b, .name = "claude", .exec = true },
        .{ .dir = a, .name = "codex", .exec = false },
        .{ .dir = b, .name = "codex", .exec = true },
        .{ .dir = a, .name = "gemini", .exec = true, .dir_entry = true },
    };
    var made: std.ArrayList([]u8) = .empty;
    defer {
        for (made.items) |p| {
            const pz = gpa.dupeZ(u8, p) catch continue;
            defer gpa.free(pz);
            _ = std.c.unlink(pz.ptr);
            _ = std.c.rmdir(pz.ptr);
            gpa.free(p);
        }
        made.deinit(gpa);
        for ([_][]const u8{ a, b, root }) |d| {
            const dz = gpa.dupeZ(u8, d) catch continue;
            defer gpa.free(dz);
            _ = std.c.rmdir(dz.ptr);
        }
    }
    for (files) |f| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ f.dir, f.name });
        try made.append(gpa, p);
        if (f.dir_entry) {
            sys.mkdir(gpa, p);
            continue;
        }
        try sys.writeFile(gpa, p, "#!/bin/sh\n", false);
        const pz = try gpa.dupeZ(u8, p);
        defer gpa.free(pz);
        _ = std.c.chmod(pz.ptr, if (f.exec) 0o755 else 0o644);
    }

    var scan = Scan.init(gpa);
    defer scan.deinit();
    scan.scanDirs(&.{ a, b });
    try std.testing.expectEqual(@as(usize, 2), scan.found.items.len);
    const claude = scan.find("claude").?;
    try std.testing.expect(std.mem.startsWith(u8, claude.path, a));
    try std.testing.expect(std.mem.endsWith(u8, claude.path, "/claude"));
    const codex = scan.find("codex").?;
    try std.testing.expect(std.mem.startsWith(u8, codex.path, b));
    try std.testing.expect(scan.find("gemini") == null);
    try std.testing.expect(scan.first().?.known == byId("claude").?);

    scan.scanDirs(&.{});
    try std.testing.expectEqual(@as(usize, 0), scan.found.items.len);
    try std.testing.expect(scan.first() == null);
}

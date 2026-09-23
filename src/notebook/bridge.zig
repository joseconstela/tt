//! The kernel behind a notebook tab: a Jupyter kernel, reached through the
//! bridge script (assets/notebook/tt_jupyter.py, embedded in the binary and
//! written next to the shell integration files at first use). The script
//! runs with the notebook's own Python — the nearest `.venv`, the active
//! virtualenv, else the interpreters on PATH and the usual places — and
//! needs jupyter_client there, which ipykernel brings; when an interpreter
//! lacks it the script exits with 3 and the next one is tried, so a
//! notebook in a venv with ipykernel runs in that venv and one without
//! falls back to a system Python that has it.
//!
//! Requests go down the script's stdin and events come up its stdout, one
//! JSON object per line (the protocol is documented at the top of the
//! script). Both pipes are non-blocking and polled from the UI tick, like
//! the terminal's PTY: no threads here. Events are decoded into `Event`s
//! that the tab drains with `take`.
const std = @import("std");
const c = std.c;
const sys = @import("../sys.zig");

extern "c" fn __error() *c_int;
const EINTR: c_int = 4;
const EAGAIN: c_int = 35;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004;
const WNOHANG: c_int = 1;

pub const script_name = "tt_jupyter.py";
/// The script's exit status when jupyter_client is not importable.
const exit_no_jupyter: i32 = 3;

var script_path: ?[]u8 = null;

/// Writes the bridge script into `dir` (once per run) and returns its
/// path, kept for the whole run.
pub fn scriptPath(gpa: std.mem.Allocator, dir: []const u8) ![]const u8 {
    if (script_path) |p| return p;
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, script_name });
    errdefer gpa.free(path);
    try sys.writeFile(gpa, path, @embedFile("jupyter_bridge"), false);
    script_path = path;
    return path;
}

// ── interpreters ─────────────────────────────────────────────────────────
/// The Pythons worth trying for a notebook in `dir`, best first: a
/// virtualenv in the folder or one above it and the active one, then the
/// interpreters (`python3`, `python3.12` …) on PATH and in the usual
/// places that have jupyter_client installed next to them, then the rest.
/// Only files that exist, each once. The caller frees the strings.
pub fn interpreters(gpa: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([]u8)) !void {
    var found: std.ArrayList(Candidate) = .empty;
    defer found.deinit(gpa);
    errdefer for (found.items) |cand| gpa.free(cand.path);

    var d = std.mem.trimEnd(u8, dir, "/");
    var levels: usize = 0;
    while (levels < 8) : (levels += 1) {
        for ([_][]const u8{ ".venv", "venv" }) |name| {
            try consider(gpa, &found, try std.fmt.allocPrint(gpa, "{s}/{s}/bin/python", .{ d, name }), .env);
        }
        const up = std.mem.lastIndexOfScalar(u8, d, '/') orelse break;
        if (up == 0) break;
        d = d[0..up];
    }
    for ([_][*:0]const u8{ "VIRTUAL_ENV", "CONDA_PREFIX" }) |name| {
        if (sys.getenv(name)) |root| {
            if (root.len > 0) try consider(gpa, &found, try std.fmt.allocPrint(gpa, "{s}/bin/python", .{std.mem.trimEnd(u8, root, "/")}), .env);
        }
    }
    if (sys.getenv("PATH")) |path| {
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |entry| {
            if (entry.len > 0) try scanDir(gpa, &found, std.mem.trimEnd(u8, entry, "/"));
        }
    }
    for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" }) |bin| try scanDir(gpa, &found, bin);

    // Best first: the notebook's own environment, then whatever has Jupyter.
    for ([_]Tier{ .env, .jupyter, .other }) |tier| {
        for (found.items) |cand| {
            if (cand.tier == tier) try out.append(gpa, cand.path);
        }
    }
    found.clearRetainingCapacity();
}

const Tier = enum { env, jupyter, other };
const Candidate = struct { path: []u8, tier: Tier };

/// `python3` and every `python3.N` in `bin`, newest version first.
fn scanDir(gpa: std.mem.Allocator, found: *std.ArrayList(Candidate), bin: []const u8) !void {
    try consider(gpa, found, try std.fmt.allocPrint(gpa, "{s}/python3", .{bin}), null);
    var versions: [32]u32 = undefined;
    var n: usize = 0;
    const Collect = struct {
        versions: *[32]u32,
        n: *usize,
        fn visit(self: @This(), e: sys.DirEntry) void {
            if (e.is_dir or self.n.* >= self.versions.len) return;
            const v = versionOf(e.name) orelse return;
            if (v == 0) return; // a bare python3, already considered
            for (self.versions[0..self.n.*]) |have| if (have == v) return;
            self.versions[self.n.*] = v;
            self.n.* += 1;
        }
    };
    sys.listDir(gpa, bin, Collect{ .versions = &versions, .n = &n }, Collect.visit);
    std.mem.sort(u32, versions[0..n], {}, std.sort.desc(u32));
    for (versions[0..n]) |v| {
        try consider(gpa, found, try std.fmt.allocPrint(gpa, "{s}/python3.{d}", .{ bin, v % 1000 }), null);
    }
}

/// "python3.12" → 3012, "python3" → 0, anything else → null.
fn versionOf(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "python3")) return null;
    const rest = name["python3".len..];
    if (rest.len == 0) return 0;
    if (rest[0] != '.' or rest.len < 2) return null;
    const minor = std.fmt.parseInt(u32, rest[1..], 10) catch return null;
    return 3000 + minor;
}

/// Keeps `candidate` (owned) when it exists and is new; frees it
/// otherwise. A null tier is worked out from what is installed beside it.
fn consider(gpa: std.mem.Allocator, found: *std.ArrayList(Candidate), candidate: []u8, tier: ?Tier) !void {
    errdefer gpa.free(candidate);
    for (found.items) |have| {
        if (std.mem.eql(u8, have.path, candidate)) {
            gpa.free(candidate);
            return;
        }
    }
    if (!sys.exists(gpa, candidate)) {
        gpa.free(candidate);
        return;
    }
    const t = tier orelse if (hasJupyter(gpa, candidate)) Tier.jupyter else Tier.other;
    try found.append(gpa, .{ .path = candidate, .tier = t });
}

/// Whether jupyter_client is installed for `python`, judged from the
/// site-packages next to it (`<prefix>/lib/python3.N/site-packages`) and
/// the user's own (`~/Library/Python/3.N/lib/python/site-packages`), so
/// no interpreter has to start to find out.
pub fn hasJupyter(gpa: std.mem.Allocator, python: []const u8) bool {
    const bin = sys.dirname(python);
    const prefix = sys.dirname(bin);
    var buf: [1024]u8 = undefined;
    // A bare `python3` is a link to a `python3.N`: the link says which.
    var real_buf: [1024]u8 = undefined;
    const base = blk: {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{python}) catch break :blk sys.basename(python);
        const real = c.realpath(z.ptr, &real_buf) orelse break :blk sys.basename(python);
        const resolved = std.mem.span(real);
        break :blk if (versionOf(sys.basename(resolved))) |v| (if (v != 0) sys.basename(resolved) else sys.basename(python)) else sys.basename(python);
    };
    if (versionOf(base)) |v| if (v != 0) {
        return jupyterAt(gpa, prefix, v % 1000, &buf);
    };
    // A bare python3 (or python): whatever versions live under lib/.
    var versions: [32]u32 = undefined;
    var n: usize = 0;
    const Collect = struct {
        versions: *[32]u32,
        n: *usize,
        fn visit(self: @This(), e: sys.DirEntry) void {
            if (!e.is_dir or self.n.* >= self.versions.len) return;
            const v = versionOf(e.name) orelse return;
            if (v == 0) return;
            self.versions[self.n.*] = v;
            self.n.* += 1;
        }
    };
    const lib = std.fmt.bufPrint(&buf, "{s}/lib", .{prefix}) catch return false;
    var lib_buf: [1024]u8 = undefined;
    @memcpy(lib_buf[0..lib.len], lib);
    sys.listDir(gpa, lib_buf[0..lib.len], Collect{ .versions = &versions, .n = &n }, Collect.visit);
    for (versions[0..n]) |v| {
        if (jupyterAt(gpa, prefix, v % 1000, &buf)) return true;
    }
    return false;
}

fn jupyterAt(gpa: std.mem.Allocator, prefix: []const u8, minor: u32, buf: []u8) bool {
    const site = std.fmt.bufPrint(buf, "{s}/lib/python3.{d}/site-packages/jupyter_client", .{ prefix, minor }) catch return false;
    if (sys.exists(gpa, site)) return true;
    const user = std.fmt.bufPrint(buf, "{s}/Library/Python/3.{d}/lib/python/site-packages/jupyter_client", .{ sys.home(), minor }) catch return false;
    return sys.exists(gpa, user);
}

// ── events ───────────────────────────────────────────────────────────────
pub const Phase = enum { off, launching, starting, ready, restarting, dead, failed };

/// How a cell's execution ended, as the kernel said.
pub const DoneStatus = enum { ok, @"error", aborted };

pub const Var = struct { name: []u8, kind: []u8, value: []u8 };

/// One line from the script, decoded. Strings are owned by the event
/// (`deinit`); a consumer that keeps one swaps in an empty slice.
pub const Event = union(enum) {
    /// The kernel is up: what it is.
    ready: struct { interpreter: []u8, version: []u8, display_name: []u8, language: []u8 },
    /// starting / restarting / dead, from the script.
    phase: Phase,
    /// Nothing will run: why (the script's reason), with details.
    fatal: struct { reason: []u8, detail: []u8, python: []u8 },
    status: struct { busy: bool, cell: []u8 },
    stream: struct { cell: []u8, stderr: bool, text: []u8 },
    /// A mime bundle (JSON object text) shown for the cell; `result` is
    /// the cell's value with its count.
    display: struct { cell: []u8, data: []u8, metadata: []u8 },
    result: struct { cell: []u8, count: ?i64, data: []u8, metadata: []u8 },
    err: struct { cell: []u8, ename: []u8, evalue: []u8, traceback: []u8 },
    clear: struct { cell: []u8, wait: bool },
    done: struct { cell: []u8, status: DoneStatus, count: ?i64, ms: i64 },
    vars: []Var,
    input_request: struct { cell: []u8, prompt: []u8, password: bool },
    memory_mb: i64,
    log: []u8,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |r| {
                gpa.free(r.interpreter);
                gpa.free(r.version);
                gpa.free(r.display_name);
                gpa.free(r.language);
            },
            .phase, .memory_mb => {},
            .fatal => |f| {
                gpa.free(f.reason);
                gpa.free(f.detail);
                gpa.free(f.python);
            },
            .status => |s| gpa.free(s.cell),
            .stream => |s| {
                gpa.free(s.cell);
                gpa.free(s.text);
            },
            .display => |d| {
                gpa.free(d.cell);
                gpa.free(d.data);
                gpa.free(d.metadata);
            },
            .result => |r| {
                gpa.free(r.cell);
                gpa.free(r.data);
                gpa.free(r.metadata);
            },
            .err => |e| {
                gpa.free(e.cell);
                gpa.free(e.ename);
                gpa.free(e.evalue);
                gpa.free(e.traceback);
            },
            .clear => |cl| gpa.free(cl.cell),
            .done => |d| gpa.free(d.cell),
            .vars => |list| {
                for (list) |v| {
                    gpa.free(v.name);
                    gpa.free(v.kind);
                    gpa.free(v.value);
                }
                gpa.free(list);
            },
            .input_request => |i| {
                gpa.free(i.cell);
                gpa.free(i.prompt);
            },
            .log => |l| gpa.free(l),
        }
        self.* = .{ .memory_mb = 0 };
    }
};

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) ![]u8 {
    const value = get(v, key) orelse return gpa.dupe(u8, "");
    return switch (value) {
        .string => |s| gpa.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(gpa, "{d}", .{i}),
        else => gpa.dupe(u8, ""),
    };
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    const value = get(v, key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn boolean(v: std.json.Value, key: []const u8) bool {
    const value = get(v, key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

/// A JSON object under `key` as minified text ("" when absent or empty).
fn objectText(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) ![]u8 {
    const value = get(v, key) orelse return gpa.dupe(u8, "");
    switch (value) {
        .object => |o| if (o.count() == 0) return gpa.dupe(u8, ""),
        else => return gpa.dupe(u8, ""),
    }
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

/// A list of strings joined by \n (the traceback).
fn joined(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) ![]u8 {
    const value = get(v, key) orelse return gpa.dupe(u8, "");
    switch (value) {
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            for (a.items, 0..) |item, i| {
                if (i > 0) try out.append(gpa, '\n');
                switch (item) {
                    .string => |s| try out.appendSlice(gpa, s),
                    else => {},
                }
            }
            return out.toOwnedSlice(gpa);
        },
        .string => |s| return gpa.dupe(u8, s),
        else => return gpa.dupe(u8, ""),
    }
}

/// Decodes one line from the script; null for lines that are not events.
pub fn decode(gpa: std.mem.Allocator, line: []const u8) !?Event {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    const ev = switch (get(v, "ev") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (std.mem.eql(u8, ev, "kernel")) {
        const state = switch (get(v, "state") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (std.mem.eql(u8, state, "ready")) {
            const spec = get(v, "spec") orelse std.json.Value{ .null = {} };
            return .{ .ready = .{
                .interpreter = try str(gpa, spec, "interpreter"),
                .version = try str(gpa, v, "version"),
                .display_name = try str(gpa, spec, "display_name"),
                .language = try str(gpa, v, "language"),
            } };
        }
        const phase: Phase = if (std.mem.eql(u8, state, "starting")) .starting else if (std.mem.eql(u8, state, "restarting")) .restarting else if (std.mem.eql(u8, state, "dead")) .dead else return null;
        return .{ .phase = phase };
    }
    if (std.mem.eql(u8, ev, "fatal")) return .{ .fatal = .{ .reason = try str(gpa, v, "reason"), .detail = try str(gpa, v, "detail"), .python = try str(gpa, v, "python") } };
    if (std.mem.eql(u8, ev, "status")) {
        const state = try str(gpa, v, "state");
        defer gpa.free(state);
        return .{ .status = .{ .busy = std.mem.eql(u8, state, "busy"), .cell = try str(gpa, v, "id") } };
    }
    if (std.mem.eql(u8, ev, "stream")) {
        const name = try str(gpa, v, "name");
        defer gpa.free(name);
        return .{ .stream = .{ .cell = try str(gpa, v, "id"), .stderr = std.mem.eql(u8, name, "stderr"), .text = try str(gpa, v, "text") } };
    }
    if (std.mem.eql(u8, ev, "display")) return .{ .display = .{ .cell = try str(gpa, v, "id"), .data = try objectText(gpa, v, "data"), .metadata = try objectText(gpa, v, "metadata") } };
    if (std.mem.eql(u8, ev, "result")) return .{ .result = .{ .cell = try str(gpa, v, "id"), .count = int(v, "count"), .data = try objectText(gpa, v, "data"), .metadata = try objectText(gpa, v, "metadata") } };
    if (std.mem.eql(u8, ev, "error")) return .{ .err = .{ .cell = try str(gpa, v, "id"), .ename = try str(gpa, v, "ename"), .evalue = try str(gpa, v, "evalue"), .traceback = try joined(gpa, v, "traceback") } };
    if (std.mem.eql(u8, ev, "clear")) return .{ .clear = .{ .cell = try str(gpa, v, "id"), .wait = boolean(v, "wait") } };
    if (std.mem.eql(u8, ev, "done")) {
        const status = try str(gpa, v, "status");
        defer gpa.free(status);
        const st: DoneStatus = if (std.mem.eql(u8, status, "ok")) .ok else if (std.mem.eql(u8, status, "error")) .@"error" else .aborted;
        return .{ .done = .{ .cell = try str(gpa, v, "id"), .status = st, .count = int(v, "count"), .ms = int(v, "ms") orelse 0 } };
    }
    if (std.mem.eql(u8, ev, "vars")) {
        var list: std.ArrayList(Var) = .empty;
        errdefer {
            for (list.items) |item| {
                gpa.free(item.name);
                gpa.free(item.kind);
                gpa.free(item.value);
            }
            list.deinit(gpa);
        }
        if (get(v, "items")) |items| switch (items) {
            .array => |a| for (a.items) |item| {
                const name = try str(gpa, item, "name");
                errdefer gpa.free(name);
                const kind = try str(gpa, item, "type");
                errdefer gpa.free(kind);
                const value = try str(gpa, item, "value");
                errdefer gpa.free(value);
                try list.append(gpa, .{ .name = name, .kind = kind, .value = value });
            },
            else => {},
        };
        return .{ .vars = try list.toOwnedSlice(gpa) };
    }
    if (std.mem.eql(u8, ev, "input_request")) return .{ .input_request = .{ .cell = try str(gpa, v, "id"), .prompt = try str(gpa, v, "prompt"), .password = boolean(v, "password") } };
    if (std.mem.eql(u8, ev, "memory")) return .{ .memory_mb = int(v, "rss_mb") orelse 0 };
    if (std.mem.eql(u8, ev, "log")) return .{ .log = try str(gpa, v, "text") };
    return null;
}

// ── the process ──────────────────────────────────────────────────────────
pub const Options = struct {
    script: []const u8,
    /// The notebook's folder: the kernel's working directory.
    cwd: []const u8,
    /// The kernelspec to start ("python3" when the file names none).
    kernel_name: []const u8,
    /// Interpreters to try, best first (see `interpreters`); owned by
    /// the caller for the kernel's life.
    interpreters: []const []const u8,
    /// Ask for the variables after every run (the inspector).
    want_vars: bool = true,
};

pub const Kernel = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    phase: Phase = .off,
    /// The kernel is running something (the script's status events).
    busy: bool = false,
    /// Which of `opts.interpreters` is in use / being tried.
    which: usize = 0,
    /// Set once the script said the kernel is up: an exit after that is
    /// a death, not a reason to try the next interpreter.
    reported: bool = false,
    /// The script said jupyter_client is missing here: try the next one.
    try_next: bool = false,
    /// Why nothing runs (`phase == .failed`), for the tab's notice.
    failure: std.ArrayList(u8) = .empty,
    /// What the script wrote on stderr, its last part (a traceback).
    stderr_tail: std.ArrayList(u8) = .empty,
    events: std.ArrayList(Event) = .empty,

    pid: c.pid_t = -1,
    in_fd: c_int = -1,
    out_fd: c_int = -1,
    err_fd: c_int = -1,
    pending: std.ArrayList(u8) = .empty,
    line_buf: std.ArrayList(u8) = .empty,
    err_line: std.ArrayList(u8) = .empty,
    exit_status: ?c_int = null,

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Kernel {
        const self = try gpa.create(Kernel);
        self.* = .{ .gpa = gpa, .opts = opts };
        self.launch();
        return self;
    }

    pub fn destroy(self: *Kernel) void {
        self.stop();
        for (self.events.items) |*e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.failure.deinit(self.gpa);
        self.stderr_tail.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.line_buf.deinit(self.gpa);
        self.err_line.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The interpreter in use (or last tried).
    pub fn interpreter(self: *const Kernel) []const u8 {
        if (self.opts.interpreters.len == 0) return "python3";
        return self.opts.interpreters[@min(self.which, self.opts.interpreters.len - 1)];
    }

    pub fn alive(self: *const Kernel) bool {
        return self.pid > 0 and self.exit_status == null;
    }

    /// Starts the script with the current interpreter.
    fn launch(self: *Kernel) void {
        if (self.which >= self.opts.interpreters.len) {
            self.fail("No Python with Jupyter was found for this notebook.");
            return;
        }
        self.phase = .launching;
        self.reported = false;
        self.try_next = false;
        self.spawn(self.opts.interpreters[self.which]) catch |err| {
            var buf: [160]u8 = undefined;
            self.fail(std.fmt.bufPrint(&buf, "The Jupyter bridge could not be started: {s}.", .{@errorName(err)}) catch "The Jupyter bridge could not be started.");
        };
    }

    fn fail(self: *Kernel, why: []const u8) void {
        self.phase = .failed;
        self.failure.clearRetainingCapacity();
        self.failure.appendSlice(self.gpa, why) catch {};
    }

    fn spawn(self: *Kernel, python: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const argv = [_][]const u8{ python, self.opts.script, "--kernel", self.opts.kernel_name, "--cwd", self.opts.cwd, "--vars" };
        const argv_z = try arena.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;
        argv_z[argv.len] = null;
        // Only the last of `--vars` matters when the inspector is off.
        const argc: usize = if (self.opts.want_vars) argv.len else argv.len - 1;
        argv_z[argc] = null;

        const environ = sys._NSGetEnviron().*;
        var env_count: usize = 0;
        while (environ[env_count] != null) env_count += 1;
        const extra = [_][]const u8{ "PYTHONUNBUFFERED=1", "TT_NOTEBOOK=1" };
        const envp = try arena.alloc(?[*:0]const u8, env_count + extra.len + 1);
        for (0..env_count) |i| envp[i] = environ[i];
        for (extra, 0..) |e, i| envp[env_count + i] = (try arena.dupeZ(u8, e)).ptr;
        envp[env_count + extra.len] = null;
        const cwd_z = try arena.dupeZ(u8, if (self.opts.cwd.len == 0) "." else self.opts.cwd);

        var in_pipe: [2]c.fd_t = undefined;
        var out_pipe: [2]c.fd_t = undefined;
        var err_pipe: [2]c.fd_t = undefined;
        if (c.pipe(&in_pipe) != 0) return error.PipeFailed;
        if (c.pipe(&out_pipe) != 0) {
            closePair(in_pipe);
            return error.PipeFailed;
        }
        if (c.pipe(&err_pipe) != 0) {
            closePair(in_pipe);
            closePair(out_pipe);
            return error.PipeFailed;
        }

        var actions: c.posix_spawn_file_actions_t = undefined;
        _ = c.posix_spawn_file_actions_init(&actions);
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        _ = c.posix_spawn_file_actions_adddup2(&actions, in_pipe[0], 0);
        _ = c.posix_spawn_file_actions_adddup2(&actions, out_pipe[1], 1);
        _ = c.posix_spawn_file_actions_adddup2(&actions, err_pipe[1], 2);
        _ = c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z.ptr);
        var attr: c.posix_spawnattr_t = undefined;
        _ = c.posix_spawnattr_init(&attr);
        defer _ = c.posix_spawnattr_destroy(&attr);
        // Only the three standard descriptors reach the child.
        _ = c.posix_spawnattr_setflags(&attr, .{ .CLOEXEC_DEFAULT = true, .SETSIGDEF = true });

        var pid: c.pid_t = 0;
        const rc = c.posix_spawnp(&pid, argv_z[0].?, &actions, &attr, @ptrCast(argv_z.ptr), @ptrCast(envp.ptr));
        _ = c.close(in_pipe[0]);
        _ = c.close(out_pipe[1]);
        _ = c.close(err_pipe[1]);
        if (rc != 0) {
            _ = c.close(in_pipe[1]);
            _ = c.close(out_pipe[0]);
            _ = c.close(err_pipe[0]);
            return error.SpawnFailed;
        }
        for ([_]c_int{ in_pipe[1], out_pipe[0], err_pipe[0] }) |fd| {
            const flags = c.fcntl(fd, F_GETFL);
            _ = c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
        self.pid = pid;
        self.in_fd = in_pipe[1];
        self.out_fd = out_pipe[0];
        self.err_fd = err_pipe[0];
        self.exit_status = null;
        self.line_buf.clearRetainingCapacity();
        self.err_line.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
    }

    fn closePair(p: [2]c.fd_t) void {
        _ = c.close(p[0]);
        _ = c.close(p[1]);
    }

    fn closeFds(self: *Kernel) void {
        if (self.in_fd >= 0) _ = c.close(self.in_fd);
        if (self.out_fd >= 0) _ = c.close(self.out_fd);
        if (self.err_fd >= 0) _ = c.close(self.err_fd);
        self.in_fd = -1;
        self.out_fd = -1;
        self.err_fd = -1;
    }

    /// Asks the script to shut the kernel down and waits briefly for it;
    /// what does not go quietly is killed.
    fn stop(self: *Kernel) void {
        if (self.pid <= 0) return;
        if (self.exit_status == null) {
            self.send("{\"op\":\"shutdown\"}\n");
            self.flush();
            if (self.in_fd >= 0) _ = c.close(self.in_fd);
            self.in_fd = -1;
            var waited: u32 = 0;
            while (waited < 80 and !self.reap()) : (waited += 1) _ = sys.usleep(10_000);
            if (self.exit_status == null) {
                _ = c.kill(self.pid, .TERM);
                waited = 0;
                while (waited < 30 and !self.reap()) : (waited += 1) _ = sys.usleep(10_000);
            }
            if (self.exit_status == null) {
                _ = c.kill(self.pid, .KILL);
                var status: c_int = 0;
                _ = c.waitpid(self.pid, &status, 0);
                self.exit_status = status;
            }
        }
        self.closeFds();
        self.pid = -1;
    }

    fn reap(self: *Kernel) bool {
        if (self.pid <= 0) return true;
        if (self.exit_status != null) return true;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, WNOHANG);
        if (r == self.pid) {
            self.exit_status = status;
            return true;
        }
        return false;
    }

    fn exitCode(self: *const Kernel) i32 {
        const st: u32 = @bitCast(self.exit_status orelse return -1);
        return if (c.W.IFEXITED(st)) c.W.EXITSTATUS(st) else -1;
    }

    // ── requests ────────────────────────────────────────────────────────
    fn send(self: *Kernel, line: []const u8) void {
        if (self.in_fd < 0) return;
        self.pending.appendSlice(self.gpa, line) catch return;
        self.flush();
    }

    fn flush(self: *Kernel) void {
        if (self.in_fd < 0) return;
        while (self.pending.items.len > 0) {
            const n = c.write(self.in_fd, self.pending.items.ptr, self.pending.items.len);
            if (n <= 0) {
                const err = __error().*;
                if (err == EINTR) continue;
                return; // EAGAIN: the rest goes on the next tick
            }
            const written: usize = @intCast(n);
            const rest = self.pending.items.len - written;
            std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[written..]);
            self.pending.items.len = rest;
        }
    }

    fn request(self: *Kernel, op: []const u8, cell: ?[]const u8, key: ?[]const u8, value: ?[]const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        js.beginObject() catch return;
        js.objectField("op") catch return;
        js.write(op) catch return;
        if (cell) |id| {
            js.objectField("id") catch return;
            js.write(id) catch return;
        }
        if (key) |k| {
            js.objectField(k) catch return;
            js.write(value orelse "") catch return;
        }
        js.endObject() catch return;
        aw.writer.writeByte('\n') catch return;
        self.send(aw.written());
    }

    /// Runs `code` as the cell `id`; the events say how it goes.
    pub fn exec(self: *Kernel, id: []const u8, code: []const u8) void {
        self.request("exec", id, "code", code);
    }

    pub fn interrupt(self: *Kernel) void {
        self.request("interrupt", null, null, null);
    }

    pub fn restart(self: *Kernel) void {
        if (self.phase == .failed or self.phase == .off) {
            // Nothing to restart: try again from the first interpreter.
            self.stop();
            self.which = 0;
            self.launch();
            return;
        }
        if (self.phase == .dead) {
            self.stop();
            self.launch();
            return;
        }
        self.request("restart", null, null, null);
    }

    pub fn requestVars(self: *Kernel) void {
        self.request("vars", null, null, null);
    }

    /// The answer to an `input_request`.
    pub fn input(self: *Kernel, text: []const u8) void {
        self.request("input", null, "text", text);
    }

    // ── polling ─────────────────────────────────────────────────────────
    /// Reads what the script wrote and turns it into events; true when
    /// there is something new for the tab.
    pub fn poll(self: *Kernel) bool {
        if (self.pid <= 0) return false;
        self.flush();
        var changed = false;
        if (self.drain(self.out_fd, &self.line_buf, false)) changed = true;
        if (self.drain(self.err_fd, &self.err_line, true)) changed = true;
        if (self.exit_status == null and self.reap()) {
            changed = true;
            self.closeFds();
            const code = self.exitCode();
            if ((self.try_next or code == exit_no_jupyter) and !self.reported) {
                self.which += 1;
                self.pid = -1;
                self.launch();
            } else if (self.phase != .failed) {
                self.phase = if (self.reported) .dead else .failed;
                if (!self.reported) {
                    var buf: [256]u8 = undefined;
                    const tail = std.mem.trim(u8, lastLine(self.stderr_tail.items), " \r\n\t");
                    const why = if (tail.len > 0) std.fmt.bufPrint(&buf, "The Jupyter bridge stopped: {s}", .{tail[0..@min(tail.len, 200)]}) catch "The Jupyter bridge stopped." else std.fmt.bufPrint(&buf, "The Jupyter bridge stopped (exit {d}).", .{code}) catch "The Jupyter bridge stopped.";
                    self.fail(why);
                }
                self.events.append(self.gpa, .{ .phase = self.phase }) catch {};
                self.pid = -1;
            }
        }
        return changed;
    }

    fn lastLine(text: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, text, "\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
        return trimmed[nl + 1 ..];
    }

    /// Reads a pipe until it runs dry, feeding complete lines on.
    fn drain(self: *Kernel, fd: c_int, acc: *std.ArrayList(u8), is_err: bool) bool {
        if (fd < 0) return false;
        var changed = false;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n > 0) {
                acc.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return changed;
                while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl| {
                    const line = acc.items[0..nl];
                    if (is_err) self.onStderr(line) else self.onLine(line);
                    changed = true;
                    const rest = acc.items.len - (nl + 1);
                    std.mem.copyForwards(u8, acc.items[0..rest], acc.items[nl + 1 ..]);
                    acc.items.len = rest;
                }
                continue;
            }
            if (n == 0) return changed; // closed
            const err = __error().*;
            if (err == EINTR) continue;
            return changed; // EAGAIN
        }
    }

    fn onStderr(self: *Kernel, line: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return;
        if (self.stderr_tail.items.len > 8 * 1024) {
            const keep = self.stderr_tail.items[self.stderr_tail.items.len - 4 * 1024 ..];
            std.mem.copyForwards(u8, self.stderr_tail.items[0..keep.len], keep);
            self.stderr_tail.items.len = keep.len;
        }
        self.stderr_tail.appendSlice(self.gpa, trimmed) catch {};
        self.stderr_tail.append(self.gpa, '\n') catch {};
        if (sys.getenv("TT_DEBUG_EVENTS") != null) std.debug.print("kernel stderr: {s}\n", .{trimmed});
    }

    fn onLine(self: *Kernel, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) return;
        if (sys.getenv("TT_DEBUG_EVENTS") != null) std.debug.print("kernel: {s}\n", .{trimmed[0..@min(trimmed.len, 300)]});
        var ev = (decode(self.gpa, trimmed) catch null) orelse return;
        switch (ev) {
            .ready => {
                self.phase = .ready;
                self.reported = true;
                self.busy = false;
            },
            .phase => |p| {
                if (p == .starting) {
                    self.phase = .starting;
                    self.reported = true; // the script is alive and has jupyter_client
                } else self.phase = p;
                if (p == .dead) self.busy = false;
            },
            .fatal => |f| {
                if (std.mem.eql(u8, f.reason, "no_jupyter_client")) {
                    self.try_next = true;
                    self.reported = false;
                    // The event still goes to the tab: with no interpreter
                    // left it is what the notice says.
                } else {
                    var buf: [320]u8 = undefined;
                    const why = if (std.mem.eql(u8, f.reason, "no_such_kernel"))
                        std.fmt.bufPrint(&buf, "The kernel “{s}” is not installed for {s}.", .{ self.opts.kernel_name, f.python }) catch "The kernel is not installed."
                    else
                        std.fmt.bufPrint(&buf, "The kernel could not start: {s}", .{f.detail[0..@min(f.detail.len, 200)]}) catch "The kernel could not start.";
                    self.fail(why);
                    self.reported = true;
                }
            },
            .status => |s| self.busy = s.busy,
            else => {},
        }
        self.events.append(self.gpa, ev) catch ev.deinit(self.gpa);
    }

    /// Hands the events gathered since the last call to the caller, who
    /// frees each with `Event.deinit`.
    pub fn take(self: *Kernel, out: *std.ArrayList(Event)) void {
        out.appendSlice(self.gpa, self.events.items) catch return;
        self.events.clearRetainingCapacity();
    }
};

// ── tests ────────────────────────────────────────────────────────────────
test "bridge: events decode with their strings owned" {
    const gpa = std.testing.allocator;
    var ev = (try decode(gpa, "{\"ev\":\"stream\",\"id\":\"c1\",\"name\":\"stderr\",\"text\":\"oops\\n\"}")).?;
    defer ev.deinit(gpa);
    try std.testing.expect(ev.stream.stderr);
    try std.testing.expectEqualStrings("c1", ev.stream.cell);
    try std.testing.expectEqualStrings("oops\n", ev.stream.text);

    var r = (try decode(gpa, "{\"ev\":\"result\",\"id\":\"c1\",\"count\":4,\"data\":{\"text/plain\":\"2\"},\"metadata\":{}}")).?;
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(?i64, 4), r.result.count);
    try std.testing.expectEqualStrings("{\"text/plain\":\"2\"}", r.result.data);
    try std.testing.expectEqualStrings("", r.result.metadata);

    var e = (try decode(gpa, "{\"ev\":\"error\",\"id\":\"c2\",\"ename\":\"ValueError\",\"evalue\":\"boom\",\"traceback\":[\"a\",\"b\"]}")).?;
    defer e.deinit(gpa);
    try std.testing.expectEqualStrings("a\nb", e.err.traceback);

    var k = (try decode(gpa, "{\"ev\":\"kernel\",\"state\":\"ready\",\"spec\":{\"interpreter\":\"/x/python\",\"display_name\":\"Python 3\"},\"version\":\"3.12.1\",\"language\":\"python\"}")).?;
    defer k.deinit(gpa);
    try std.testing.expectEqualStrings("/x/python", k.ready.interpreter);
    try std.testing.expectEqualStrings("3.12.1", k.ready.version);

    var d = (try decode(gpa, "{\"ev\":\"done\",\"id\":\"c1\",\"status\":\"aborted\",\"count\":null,\"ms\":12}")).?;
    defer d.deinit(gpa);
    try std.testing.expectEqual(DoneStatus.aborted, d.done.status);
    try std.testing.expect(d.done.count == null);

    var vs = (try decode(gpa, "{\"ev\":\"vars\",\"items\":[{\"name\":\"df\",\"type\":\"DataFrame\",\"value\":\"3 × 2\"}]}")).?;
    defer vs.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), vs.vars.len);
    try std.testing.expectEqualStrings("DataFrame", vs.vars[0].kind);

    try std.testing.expect((try decode(gpa, "{\"no\":\"ev\"}")) == null);
    try std.testing.expect((try decode(gpa, "garbage")) == null);
    var p = (try decode(gpa, "{\"ev\":\"kernel\",\"state\":\"dead\"}")).?;
    defer p.deinit(gpa);
    try std.testing.expectEqual(Phase.dead, p.phase);
}

test "bridge: interpreters are the existing ones, each once, and versions parse" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    try interpreters(gpa, "/nonexistent/deep/folder", &list);
    // Whatever the machine has, nothing is listed twice and all exist.
    for (list.items, 0..) |p, i| {
        try std.testing.expect(sys.exists(gpa, p));
        for (list.items[i + 1 ..]) |q| try std.testing.expect(!std.mem.eql(u8, p, q));
    }
    try std.testing.expectEqual(@as(?u32, 3012), versionOf("python3.12"));
    try std.testing.expectEqual(@as(?u32, 0), versionOf("python3"));
    try std.testing.expect(versionOf("python3-config") == null);
    try std.testing.expect(versionOf("python3.") == null);
    try std.testing.expect(versionOf("pip3") == null);
    try std.testing.expect(!hasJupyter(gpa, "/nonexistent/bin/python3.12"));
}

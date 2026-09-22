//! Pseudo-terminal + child process. The master side is non-blocking and is
//! polled from the UI tick, so there are no threads to synchronise.
const std = @import("std");
const c = std.c;
const sys = @import("../sys.zig");

const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;
extern "c" fn tcgetattr(fd: c_int, termios: *[128]u8) c_int;
extern "c" fn __error() *c_int;

const TIOCSWINSZ: c_ulong = 0x80087467;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004;
const EAGAIN: c_int = 35;
const EINTR: c_int = 4;
const WNOHANG: c_int = 1;
const ECHO_FLAG: u64 = 0x00000008;

pub const ReadResult = union(enum) {
    data: usize,
    again,
    closed,
};

pub const Pty = struct {
    gpa: std.mem.Allocator,
    master: c_int = -1,
    pid: c_int = -1,
    pending: std.ArrayList(u8) = .empty,
    exit_status: ?c_int = null,

    pub const SpawnOptions = struct {
        path: [:0]const u8,
        argv0: [:0]const u8,
        cwd: []const u8,
        cols: u16,
        rows: u16,
        /// "NAME=value" overrides; a bare "NAME" removes the variable.
        env_overrides: []const []const u8,
    };

    pub fn spawn(gpa: std.mem.Allocator, opts: SpawnOptions) !Pty {
        // Everything the child needs is prepared before forking: after fork()
        // only async-signal-safe calls are allowed.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var env: std.ArrayList(?[*:0]const u8) = .empty;
        const environ = sys._NSGetEnviron().*;
        var i: usize = 0;
        outer: while (environ[i]) |entry| : (i += 1) {
            const kv = std.mem.span(entry);
            const name = kv[0 .. std.mem.indexOfScalar(u8, kv, '=') orelse kv.len];
            for (opts.env_overrides) |ov| {
                const ov_name = ov[0 .. std.mem.indexOfScalar(u8, ov, '=') orelse ov.len];
                if (std.mem.eql(u8, ov_name, name)) continue :outer;
            }
            try env.append(arena, entry);
        }
        for (opts.env_overrides) |ov| {
            if (std.mem.indexOfScalar(u8, ov, '=') == null) continue;
            try env.append(arena, (try arena.dupeZ(u8, ov)).ptr);
        }
        try env.append(arena, null);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env.items.ptr);

        const argv = [_:null]?[*:0]const u8{opts.argv0.ptr};
        const cwd_z = try arena.dupeZ(u8, opts.cwd);

        var ws: Winsize = .{ .row = opts.rows, .col = opts.cols };
        var master: c_int = -1;
        const pid = forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Child.
            _ = signal(13, null); // SIGPIPE → default
            _ = c.chdir(cwd_z.ptr);
            _ = c.execve(opts.path.ptr, &argv, envp);
            c._exit(127);
        }

        const flags = c.fcntl(master, F_GETFL);
        _ = c.fcntl(master, F_SETFL, flags | O_NONBLOCK);
        return .{ .gpa = gpa, .master = master, .pid = pid };
    }

    pub fn deinit(self: *Pty) void {
        if (self.master >= 0) _ = c.close(self.master);
        self.master = -1;
        if (self.pid > 0 and self.exit_status == null) {
            _ = c.kill(self.pid, .HUP);
            var status: c_int = 0;
            _ = c.waitpid(self.pid, &status, WNOHANG);
        }
        self.pending.deinit(self.gpa);
    }

    pub fn read(self: *Pty, buf: []u8) ReadResult {
        if (self.master < 0) return .closed;
        while (true) {
            const n = c.read(self.master, buf.ptr, buf.len);
            if (n > 0) return .{ .data = @intCast(n) };
            if (n == 0) return .closed;
            const err = __error().*;
            if (err == EINTR) continue;
            if (err == EAGAIN) return .again;
            return .closed; // EIO once the child side is gone
        }
    }

    /// Queues bytes for the child; flushed opportunistically.
    pub fn write(self: *Pty, bytes: []const u8) void {
        self.pending.appendSlice(self.gpa, bytes) catch return;
        self.flush();
    }

    pub fn flush(self: *Pty) void {
        if (self.master < 0) return;
        while (self.pending.items.len > 0) {
            const n = c.write(self.master, self.pending.items.ptr, self.pending.items.len);
            if (n <= 0) {
                const err = __error().*;
                if (err == EINTR) continue;
                return; // EAGAIN: try again next tick
            }
            const written: usize = @intCast(n);
            const rest = self.pending.items.len - written;
            std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[written..]);
            self.pending.items.len = rest;
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        if (self.master < 0) return;
        var ws: Winsize = .{ .row = rows, .col = cols };
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// False while a program has turned terminal echo off (password prompts).
    pub fn echoEnabled(self: *Pty) bool {
        if (self.master < 0) return true;
        var t: [128]u8 align(8) = undefined;
        if (tcgetattr(self.master, &t) != 0) return true;
        // struct termios on Darwin: c_iflag, c_oflag, c_cflag, c_lflag (u64 each).
        const lflag = std.mem.readInt(u64, t[24..32], .little);
        // Raw-mode programs (vim, fzf …) also clear ECHO; only a *line-mode*
        // read without echo is a secret being typed.
        const ICANON_FLAG: u64 = 0x00000100;
        if (lflag & ICANON_FLAG == 0) return true;
        return (lflag & ECHO_FLAG) != 0;
    }

    /// True while the terminal is in raw (non-canonical) mode: the running
    /// program reads keys one at a time, as full-screen programs and line
    /// editors do.
    pub fn rawMode(self: *Pty) bool {
        if (self.master < 0) return false;
        var t: [128]u8 align(8) = undefined;
        if (tcgetattr(self.master, &t) != 0) return false;
        const lflag = std.mem.readInt(u64, t[24..32], .little);
        const ICANON_FLAG: u64 = 0x00000100;
        return (lflag & ICANON_FLAG) == 0;
    }

    /// Reaps the child if it has exited.
    pub fn reap(self: *Pty) bool {
        if (self.pid <= 0 or self.exit_status != null) return self.exit_status != null;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, WNOHANG);
        if (r == self.pid) {
            self.exit_status = status;
            return true;
        }
        return false;
    }
};

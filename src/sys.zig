//! Thin libc helpers. We link libc anyway (AppKit), and going through it keeps
//! this code independent from std's evolving I/O layer.
const std = @import("std");
const c = std.c;

pub extern "c" fn usleep(usec: c_uint) c_int;
pub extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
pub extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
pub extern "c" fn getuid() c_uint;

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

pub fn home() []const u8 {
    return getenv("HOME") orelse "/";
}

/// Reads at most the last `max_bytes` of a file.
pub fn readFileTail(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    const size = lseek(fd, 0, 2);
    if (size < 0) return error.SeekFailed;
    const total: usize = @intCast(size);
    const want = @min(total, max_bytes);
    _ = lseek(fd, @intCast(total - want), 0);

    const buf = try gpa.alloc(u8, want);
    errdefer gpa.free(buf);
    var got: usize = 0;
    while (got < want) {
        const n = c.read(fd, buf.ptr + got, want - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return gpa.realloc(buf, got) catch buf[0..got];
}

/// Size of a file in bytes, or null if it cannot be opened.
pub fn fileSize(gpa: std.mem.Allocator, path: []const u8) ?usize {
    const path_z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const size = lseek(fd, 0, 2);
    if (size < 0) return null;
    return @intCast(size);
}

pub const FileHead = struct { data: []u8, total: usize };

/// Reads at most the first `max_bytes` of a file; `total` is its full size.
pub fn readFileHead(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) !FileHead {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    const size = lseek(fd, 0, 2);
    if (size < 0) return error.SeekFailed;
    _ = lseek(fd, 0, 0);
    const total: usize = @intCast(size);
    const want = @min(total, max_bytes);

    const buf = try gpa.alloc(u8, want);
    errdefer gpa.free(buf);
    var got: usize = 0;
    while (got < want) {
        const n = c.read(fd, buf.ptr + got, want - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return .{ .data = gpa.realloc(buf, got) catch buf[0..got], .total = total };
}

/// Last path component ("/" for the root).
pub fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

pub fn dirname(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    return if (slash == 0) "/" else trimmed[0..slash];
}

/// "~/…" spelling of a path inside the home directory (uses `buf`).
pub fn abbreviateHome(path: []const u8, buf: []u8) []const u8 {
    const h = home();
    if (std.mem.startsWith(u8, path, h) and (path.len == h.len or path[h.len] == '/')) {
        return std.fmt.bufPrint(buf, "~{s}", .{path[h.len..]}) catch path;
    }
    return path;
}

pub fn writeFile(gpa: std.mem.Allocator, path: []const u8, data: []const u8, append: bool) !void {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !append, .APPEND = append }, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

pub fn mkdir(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(path_z);
    _ = c.mkdir(path_z.ptr, 0o700);
}

pub const DirEntry = struct { name: []const u8, is_dir: bool };

/// Iterates a directory, calling `visit(ctx, entry)` for every entry except
/// "." and "..". Entry names are only valid during the callback.
pub fn listDir(gpa: std.mem.Allocator, path: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), DirEntry) void) void {
    const path_z = gpa.dupeZ(u8, if (path.len == 0) "." else path) catch return;
    defer gpa.free(path_z);
    const dir = c.opendir(path_z.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = ent.name[0..ent.namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var is_dir = ent.type == 4; // DT_DIR
        if (ent.type == 10 or ent.type == 0) { // DT_LNK / DT_UNKNOWN → stat
            is_dir = isDir(gpa, path, name);
        }
        visit(ctx, .{ .name = name, .is_dir = is_dir });
    }
}

fn isDir(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const full = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }, 0) catch return false;
    defer gpa.free(full);
    const d = c.opendir(full.ptr) orelse return false;
    _ = c.closedir(d);
    return true;
}

// ── files being edited ──────────────────────────────────────────────────
pub extern "c" fn mkstemp(template: [*:0]u8) c_int;
// std.c's darwin `stat` binding is missing on arm64 in Zig 0.16; bind it here.
extern "c" fn @"stat$INODE64"(path: [*:0]const u8, buf: *c.Stat) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *c.Stat) c_int;
const c_stat = if (@import("builtin").cpu.arch == .x86_64) @"stat$INODE64" else stat;

pub const FileStat = struct {
    /// Modification time in nanoseconds since the epoch.
    mtime_ns: i128,
    size: usize,
    mode: u16,
};

pub fn statFile(gpa: std.mem.Allocator, path: []const u8) ?FileStat {
    const path_z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(path_z);
    var st: c.Stat = undefined;
    if (c_stat(path_z.ptr, &st) != 0) return null;
    const mt = st.mtime();
    return .{
        .mtime_ns = @as(i128, mt.sec) * 1_000_000_000 + mt.nsec,
        .size = if (st.size < 0) 0 else @intCast(st.size),
        .mode = st.mode,
    };
}

/// True when the file can be written (or, for a file that does not exist
/// yet, when its directory can be).
pub fn isWritable(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    if (c.access(path_z.ptr, c.F_OK) != 0) {
        const dir_z = gpa.dupeZ(u8, dirname(path)) catch return false;
        defer gpa.free(dir_z);
        return c.access(dir_z.ptr, c.W_OK) == 0;
    }
    return c.access(path_z.ptr, c.W_OK) == 0;
}

/// Writes `data` to a temporary file next to `path`, fsyncs it and renames
/// it over `path`, so a crash mid-write never leaves a half-written file.
/// The original's permission bits are kept.
pub fn writeFileAtomic(gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const dir = dirname(path);
    const name = basename(path);
    const tmpl = try std.fmt.allocPrintSentinel(gpa, "{s}/.{s}.conch-XXXXXX", .{ dir, name }, 0);
    defer gpa.free(tmpl);
    const fd = mkstemp(tmpl.ptr);
    if (fd < 0) return error.OpenFailed;
    var ok = false;
    defer if (!ok) {
        _ = c.unlink(tmpl.ptr);
    };
    {
        defer _ = c.close(fd);
        var off: usize = 0;
        while (off < data.len) {
            const n = c.write(fd, data.ptr + off, data.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
        if (c.fsync(fd) != 0) return error.WriteFailed;
        if (statFile(gpa, path)) |st| _ = c.fchmod(fd, st.mode & 0o7777);
    }
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    if (c.rename(tmpl.ptr, path_z.ptr) != 0) return error.RenameFailed;
    ok = true;
}

// ── child processes ─────────────────────────────────────────────────────
extern "c" fn __error() *c_int;
const EINTR: c_int = 4;

/// What a finished command left behind. Free with `deinit`.
pub const RunResult = struct {
    gpa: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    /// The exit status, or -1 when the command was killed by a signal.
    status: i32,

    pub fn ok(self: *const RunResult) bool {
        return self.status == 0;
    }

    /// The first line of stderr (what a failed git command has to say).
    pub fn firstErrorLine(self: *const RunResult) []const u8 {
        const s = std.mem.trim(u8, self.stderr, " \r\n\t");
        const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
        return s[0..end];
    }

    pub fn deinit(self: *RunResult) void {
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
    }
};

/// Runs `argv` in `cwd` with stdin from /dev/null and collects what it
/// writes until it exits. `extra_env` (NAME=value) is added to our own
/// environment. Blocks until the command is done: call it for quick
/// commands, or from a thread of its own.
pub fn run(gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, extra_env: []const []const u8) !RunResult {
    if (argv.len == 0) return error.NoCommand;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv_z = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;
    argv_z[argv.len] = null;

    const environ = _NSGetEnviron().*;
    var env_count: usize = 0;
    while (environ[env_count] != null) env_count += 1;
    const envp = try arena.alloc(?[*:0]const u8, env_count + extra_env.len + 1);
    for (0..env_count) |i| envp[i] = environ[i];
    for (extra_env, 0..) |e, i| envp[env_count + i] = (try arena.dupeZ(u8, e)).ptr;
    envp[env_count + extra_env.len] = null;
    const cwd_z = try arena.dupeZ(u8, if (cwd.len == 0) "." else cwd);

    var out_pipe: [2]c.fd_t = undefined;
    var err_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&out_pipe) != 0) return error.PipeFailed;
    if (c.pipe(&err_pipe) != 0) {
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
        return error.PipeFailed;
    }

    var actions: c.posix_spawn_file_actions_t = undefined;
    _ = c.posix_spawn_file_actions_init(&actions);
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    _ = c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", 0, 0);
    _ = c.posix_spawn_file_actions_adddup2(&actions, out_pipe[1], 1);
    _ = c.posix_spawn_file_actions_adddup2(&actions, err_pipe[1], 2);
    _ = c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z.ptr);
    var attr: c.posix_spawnattr_t = undefined;
    _ = c.posix_spawnattr_init(&attr);
    defer _ = c.posix_spawnattr_destroy(&attr);
    // Only the three standard descriptors reach the child: no pty or pipe
    // of ours leaks into it.
    _ = c.posix_spawnattr_setflags(&attr, .{ .CLOEXEC_DEFAULT = true, .SETSIGDEF = true });

    var pid: c.pid_t = 0;
    const rc = c.posix_spawnp(&pid, argv_z[0].?, &actions, &attr, @ptrCast(argv_z.ptr), @ptrCast(envp.ptr));
    _ = c.close(out_pipe[1]);
    _ = c.close(err_pipe[1]);
    if (rc != 0) {
        _ = c.close(out_pipe[0]);
        _ = c.close(err_pipe[0]);
        return error.SpawnFailed;
    }

    var bufs: [2]std.ArrayList(u8) = .{ .empty, .empty };
    errdefer for (&bufs) |*b| b.deinit(gpa);
    var fds = [2]c.pollfd{
        .{ .fd = out_pipe[0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = err_pipe[0], .events = c.POLL.IN, .revents = 0 },
    };
    var open_count: usize = 2;
    while (open_count > 0) {
        const n = c.poll(&fds, 2, -1);
        if (n < 0) {
            if (__error().* == EINTR) continue;
            break;
        }
        for (&fds, 0..) |*p, i| {
            if (p.fd < 0 or p.revents == 0) continue;
            var chunk: [8192]u8 = undefined;
            const got = c.read(p.fd, &chunk, chunk.len);
            if (got > 0) {
                try bufs[i].appendSlice(gpa, chunk[0..@intCast(got)]);
            } else if (got < 0 and __error().* == EINTR) {
                continue;
            } else {
                _ = c.close(p.fd);
                p.fd = -1;
                open_count -= 1;
            }
        }
    }
    for (&fds) |*p| if (p.fd >= 0) {
        _ = c.close(p.fd);
    };

    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0) {
        if (__error().* != EINTR) break;
    }
    const st: u32 = @bitCast(status);
    const code: i32 = if (c.W.IFEXITED(st)) c.W.EXITSTATUS(st) else -1;
    return .{
        .gpa = gpa,
        .stdout = try bufs[0].toOwnedSlice(gpa),
        .stderr = try bufs[1].toOwnedSlice(gpa),
        .status = code,
    };
}

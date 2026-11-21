//! Paths on the command line: `tt .` opens a folder, `tt notes.md` a file,
//! both in the default project (`App.openPath`).
//!
//! A tt that is already running gets them instead of a second app starting:
//! it listens on a Unix socket, `~/.tt/tt.sock` (or `$TT_SOCKET`), and the
//! `tt` typed in a shell connects, writes its paths and exits. Only the
//! first instance owns the socket; a later one runs without listening.
//!
//! The message is the absolute paths, each followed by a NUL byte, then the
//! writer closes. Nothing is answered. A connection that closes without
//! a byte is a second instance checking whether the socket is taken, and
//! is ignored.
//!
//! With no instance to hand them to, `detach` restarts the program in a
//! session of its own (`--foreground` marks the copy that is the app), so
//! the shell gets its prompt back as it does after `open` or `code .`.
//!
//! `install` is the app menu's "Install CLI Tools…": it links
//! `/usr/local/bin/tt` (on every macOS `PATH`) to the running binary, asking
//! macOS for an administrator's password when the folder is not ours to
//! write. `$TT_CLI_LINK` names another place for the link (tests).
const std = @import("std");
const sys = @import("sys.zig");
const c = std.c;

/// What one message may weigh; more than any command line carries.
const max_message = 256 * 1024;

/// Where the running app listens. Null when the path does not fit a socket
/// address (a very long home directory).
pub fn socketPath(buf: []u8) ?[]const u8 {
    const path = if (sys.getenv("TT_SOCKET")) |p|
        std.fmt.bufPrint(buf, "{s}", .{p}) catch return null
    else
        std.fmt.bufPrint(buf, "{s}/.tt/tt.sock", .{sys.home()}) catch return null;
    if (path.len == 0 or path.len >= 104) return null;
    return path;
}

/// `arg` as typed in `cwd`, made absolute: `.` and `..` are folded away and
/// nothing is looked up on disk, so a file that does not exist yet keeps
/// its name. Caller owns the result.
pub fn absolute(gpa: std.mem.Allocator, cwd: []const u8, arg: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (arg.len == 0 or arg[0] != '/') try out.appendSlice(gpa, std.mem.trimEnd(u8, cwd, "/"));
    var it = std.mem.tokenizeScalar(u8, arg, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            out.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0);
            continue;
        }
        try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '/');
    return out.toOwnedSlice(gpa);
}

fn address(path: []const u8) ?sys.SockaddrUn {
    var addr: sys.SockaddrUn = .{};
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn connectTo(path: []const u8) ?c_int {
    const addr = address(path) orelse return null;
    const fd = sys.socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) return null;
    if (sys.connect(fd, &addr, @sizeOf(sys.SockaddrUn)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// Hands the paths in `list` (absolute) to the tt listening at `socket_path`. False when
/// none is, or the message did not get through.
pub fn send(socket_path: []const u8, list: []const []const u8) bool {
    const fd = connectTo(socket_path) orelse return false;
    defer _ = c.close(fd);
    for (list) |p| {
        if (!writeAll(fd, p) or !writeAll(fd, "\x00")) return false;
    }
    return true;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes.ptr + done, bytes.len - done);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

/// The listening end, polled once per app tick.
pub const Server = struct {
    fd: c_int,
    path_buf: [104]u8 = undefined,
    path_len: usize = 0,

    /// Null when another tt already answers at `socket_path`, or the socket
    /// cannot be made. A socket file left by a tt that is gone is replaced.
    pub fn listen(socket_path: []const u8) ?Server {
        const addr = address(socket_path) orelse return null;
        if (connectTo(socket_path)) |live| {
            _ = c.close(live);
            return null;
        }
        _ = c.unlink(@ptrCast(&addr.path));
        const fd = sys.socket(1, 1, 0);
        if (fd < 0) return null;
        if (sys.bind(fd, &addr, @sizeOf(sys.SockaddrUn)) != 0 or sys.listen(fd, 8) != 0) {
            _ = c.close(fd);
            return null;
        }
        var self: Server = .{ .fd = fd, .path_len = socket_path.len };
        @memcpy(self.path_buf[0..socket_path.len], socket_path);
        return self;
    }

    pub fn deinit(self: *Server) void {
        _ = c.close(self.fd);
        var addr = address(self.path_buf[0..self.path_len]) orelse return;
        _ = c.unlink(@ptrCast(&addr.path));
    }

    /// One waiting message, if a `tt` has connected: its paths, NUL after
    /// each (walk them with `paths`). Returns at once when nobody has, or
    /// when whoever did said nothing (another instance's check); a
    /// writer that stalls is given a quarter of a second, then dropped.
    /// Caller owns the result.
    pub fn accept(self: *Server, gpa: std.mem.Allocator) ?[]u8 {
        var waiting = [_]sys.PollFd{.{ .fd = self.fd }};
        if (sys.poll(&waiting, 1, 0) <= 0) return null;
        const conn = sys.accept(self.fd, null, null);
        if (conn < 0) return null;
        defer _ = c.close(conn);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (out.items.len < max_message) {
            var ready = [_]sys.PollFd{.{ .fd = conn }};
            if (sys.poll(&ready, 1, 250) <= 0) break;
            const n = c.read(conn, &buf, buf.len);
            if (n <= 0) break;
            out.appendSlice(gpa, buf[0..@intCast(n)]) catch break;
        }
        if (out.items.len == 0) {
            out.deinit(gpa);
            return null;
        }
        return out.toOwnedSlice(gpa) catch {
            out.deinit(gpa);
            return null;
        };
    }
};

/// The paths of a message, in order.
pub fn paths(message: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, message, 0);
}

/// Starts this program again, detached from the terminal, with
/// `--foreground` ahead of `args` (the arguments after the program's name),
/// and exits. Returns only when that could not be done: the caller then
/// runs the app itself, attached.
pub fn detach(gpa: std.mem.Allocator, args: []const []const u8) void {
    var raw: [4096]u8 = undefined;
    var size: u32 = raw.len;
    if (sys._NSGetExecutablePath(&raw, &size) != 0) return;
    // Through a symlink on the PATH to the binary inside the bundle, so the
    // app finds its Info.plist and resources.
    var real: [c.PATH_MAX]u8 = undefined;
    const exe: [*:0]const u8 = c.realpath(@ptrCast(&raw), &real) orelse return;

    // Everything the child needs is prepared before forking.
    const argv = gpa.allocSentinel(?[*:0]const u8, args.len + 2, null) catch return;
    argv[0] = exe;
    argv[1] = "--foreground";
    for (args, 0..) |a, i| argv[i + 2] = (gpa.dupeSentinel(u8, a, 0) catch return).ptr;

    const pid = sys.fork();
    if (pid < 0) return;
    if (pid > 0) c._exit(0);
    _ = sys.setsid();
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (null_fd >= 0) {
        _ = sys.dup2(null_fd, 0);
        _ = sys.dup2(null_fd, 1);
        _ = sys.dup2(null_fd, 2);
        if (null_fd > 2) _ = c.close(null_fd);
    }
    _ = sys.execv(exe, argv.ptr);
    c._exit(127);
}

/// Where "Install CLI Tools…" puts the link.
pub fn linkPath() []const u8 {
    return sys.getenv("TT_CLI_LINK") orelse "/usr/local/bin/tt";
}

pub const Install = enum {
    installed,
    /// The link was there and already points at this binary.
    already,
    /// The password prompt was dismissed.
    cancelled,
    /// Something that is not a link has the name: left alone.
    taken,
    failed,
};

/// Links `link` to the running binary. A link already there (an older
/// install, a build since moved) is replaced; a real file is not. Blocks
/// while macOS asks for a password: call it from a thread of its own.
pub fn install(gpa: std.mem.Allocator, link: []const u8) Install {
    var raw: [4096]u8 = undefined;
    var size: u32 = raw.len;
    if (sys._NSGetExecutablePath(&raw, &size) != 0) return .failed;
    var real: [c.PATH_MAX]u8 = undefined;
    const exe_z: [*:0]const u8 = c.realpath(@ptrCast(&raw), &real) orelse return .failed;
    const exe = std.mem.span(exe_z);
    const link_z = gpa.dupeSentinel(u8, link, 0) catch return .failed;
    defer gpa.free(link_z);

    var current: [c.PATH_MAX]u8 = undefined;
    const n = sys.readlink(link_z.ptr, &current, current.len);
    if (n >= 0) {
        if (std.mem.eql(u8, current[0..@intCast(n)], exe)) return .already;
    } else if (sys.exists(gpa, link)) return .taken;

    // Without asking, where the folder lets us.
    if (n >= 0) _ = c.unlink(link_z.ptr);
    if (sys.symlink(exe_z, link_z.ptr) == 0) return .installed;

    // As an administrator: macOS shows its own password prompt. The paths
    // travel as arguments and are quoted by AppleScript, not pasted in.
    var result = sys.run(gpa, "/", &.{
        "/usr/bin/osascript",
        "-e",
        "on run argv",
        "-e",
        "do shell script \"/bin/mkdir -p \" & quoted form of (item 1 of argv) & \" && /bin/ln -sfn \" & quoted form of (item 2 of argv) & \" \" & quoted form of (item 3 of argv) with prompt \"tt wants to install its command line tool.\" with administrator privileges",
        "-e",
        "end run",
        sys.dirname(link),
        exe,
        link,
    }, &.{}) catch return .failed;
    defer result.deinit();
    if (result.ok()) return .installed;
    // -128: the user pressed Cancel.
    if (std.mem.indexOf(u8, result.stderr, "-128") != null) return .cancelled;
    return .failed;
}

test "install links the running binary and leaves real files alone" {
    const gpa = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const link = try std.fmt.bufPrint(&buf, "/tmp/tt-cli-link-{d}", .{c.getpid()});
    defer sys.deleteFile(gpa, link);

    try std.testing.expectEqual(Install.installed, install(gpa, link));
    try std.testing.expectEqual(Install.already, install(gpa, link));
    // A link to somewhere else is ours to replace.
    sys.deleteFile(gpa, link);
    const link_z = try gpa.dupeSentinel(u8, link, 0);
    defer gpa.free(link_z);
    try std.testing.expect(sys.symlink("/somewhere/else", link_z.ptr) == 0);
    try std.testing.expectEqual(Install.installed, install(gpa, link));
    // A file is not.
    sys.deleteFile(gpa, link);
    try sys.writeFile(gpa, link, "someone else's tt", false);
    try std.testing.expectEqual(Install.taken, install(gpa, link));
}

test "absolute folds dots and keeps absolute paths" {
    const gpa = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "/a/b", ".", "/a/b" },
        .{ "/a/b", "file.txt", "/a/b/file.txt" },
        .{ "/a/b", "../c/./d.md", "/a/c/d.md" },
        .{ "/a/b/", "x//y/", "/a/b/x/y" },
        .{ "/a/b", "/etc/hosts", "/etc/hosts" },
        .{ "/a", "../../..", "/" },
        .{ "/", "notes", "/notes" },
    };
    for (cases) |case| {
        const got = try absolute(gpa, case[0], case[1]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[2], got);
    }
}

test "paths reach a listening server, and only one can listen" {
    const gpa = std.testing.allocator;
    var buf: [104]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/tt-cli-test-{d}.sock", .{c.getpid()});

    try std.testing.expect(!send(path, &.{"/nobody/listens"}));
    var server = Server.listen(path) orelse return error.NoServer;
    defer server.deinit();
    try std.testing.expect(Server.listen(path) == null);
    try std.testing.expect(server.accept(gpa) == null);

    try std.testing.expect(send(path, &.{ "/a/b", "/c d/e.txt" }));
    const message = server.accept(gpa) orelse return error.NoMessage;
    defer gpa.free(message);
    var it = paths(message);
    try std.testing.expectEqualStrings("/a/b", it.next().?);
    try std.testing.expectEqualStrings("/c d/e.txt", it.next().?);
    try std.testing.expect(it.next() == null);
}

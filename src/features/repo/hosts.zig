//! The effects the repository feature is handed instead of reaching for
//! them: the one that runs a command (`Runner`), the one that sends an
//! HTTP request (`Http`), and the time of day. `client/` goes through
//! these and never imports `sys.zig` or `http.zig` itself, so a test
//! hands it a stand-in that answers from memory; the app hands it
//! `system()` and `systemHttp()`.
const std = @import("std");
const sys = @import("../../sys.zig");
const http = @import("../../http.zig");
const coding_agents = @import("../../coding_agents.zig");

/// What a finished command left behind. Free with `deinit`.
pub const Output = sys.RunResult;

/// Runs `argv` in `cwd` with `env` (NAME=value) added to the environment,
/// and returns once it exited. Called from worker threads as well as the
/// UI's, so an implementation must cope with both at once.
pub const Runner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8) anyerror!Output,
    /// The same with `input` written to the command's stdin; a runner
    /// without one cannot feed a command.
    feedFn: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8, input: []const u8) anyerror!Output = null,

    pub fn run(self: Runner, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8) anyerror!Output {
        return self.runFn(self.ptr, gpa, cwd, argv, env);
    }

    /// Runs `argv` with `input` on its stdin (a few lines: a question for
    /// `git credential fill`).
    pub fn feed(self: Runner, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8, input: []const u8) anyerror!Output {
        const f = self.feedFn orelse return error.Unsupported;
        return f(self.ptr, gpa, cwd, argv, env, input);
    }
};

var system_state: u8 = 0;

fn systemRun(_: *anyopaque, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8) anyerror!Output {
    return sys.run(gpa, cwd, argv, env);
}

fn systemFeed(_: *anyopaque, gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const []const u8, input: []const u8) anyerror!Output {
    return sys.runWithInput(gpa, cwd, argv, env, input);
}

/// The `PATH=…` a tool found by name is run with (`gh`, `glab`): the
/// app's own, then the usual places, since an app started from the
/// Finder has a short one. Owned by the caller.
pub fn toolPath(gpa: std.mem.Allocator) ![]u8 {
    return coding_agents.pathEnv(gpa, null);
}

/// Writes `text` to a file of its own in tt's corner of the temporary
/// folder and returns where (owned by the caller): how something too
/// long for a status line is handed to a tab to read. The same `name`
/// writes the same file again, so a tab already showing it follows.
pub fn saveScratch(gpa: std.mem.Allocator, name: []const u8, text: []const u8) ![]u8 {
    const tmp = std.mem.trimEnd(u8, sys.getenv("TMPDIR") orelse "/tmp", "/");
    const dir = try std.fmt.allocPrint(gpa, "{s}/tt", .{tmp});
    defer gpa.free(dir);
    sys.mkdir(gpa, dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    errdefer gpa.free(path);
    try sys.writeFile(gpa, path, text, false);
    return path;
}

/// Now, in seconds since the epoch: what "2 h ago" is counted from.
pub fn wallClock() i64 {
    return sys.wallClock();
}

/// Real child processes (`sys.run`).
pub fn system() Runner {
    return .{ .ptr = &system_state, .runFn = systemRun, .feedFn = systemFeed };
}

pub const HttpHeader = http.Header;
pub const HttpState = http.State;

pub const HttpOptions = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const HttpHeader = &.{},
    body: []const u8 = "",
};

/// Sends HTTP requests and keeps each answer until it is released. A
/// request is polled (`state`) from the UI's tick; its status, headers
/// and body are read once it is `done`, its reason once it `failed`.
pub const Http = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// One request under way or answered.
    pub const Handle = *anyopaque;

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, options: HttpOptions) anyerror!Handle,
        state: *const fn (ptr: *anyopaque, h: Handle) HttpState,
        status: *const fn (ptr: *anyopaque, h: Handle) i64,
        body: *const fn (ptr: *anyopaque, h: Handle) []const u8,
        header: *const fn (ptr: *anyopaque, h: Handle, name: []const u8) ?[]const u8,
        failure: *const fn (ptr: *anyopaque, h: Handle) []const u8,
        release: *const fn (ptr: *anyopaque, h: Handle) void,
    };

    pub fn start(self: Http, options: HttpOptions) anyerror!Handle {
        return self.vtable.start(self.ptr, options);
    }
    pub fn state(self: Http, h: Handle) HttpState {
        return self.vtable.state(self.ptr, h);
    }
    pub fn status(self: Http, h: Handle) i64 {
        return self.vtable.status(self.ptr, h);
    }
    pub fn body(self: Http, h: Handle) []const u8 {
        return self.vtable.body(self.ptr, h);
    }
    pub fn header(self: Http, h: Handle, name: []const u8) ?[]const u8 {
        return self.vtable.header(self.ptr, h, name);
    }
    pub fn failure(self: Http, h: Handle) []const u8 {
        return self.vtable.failure(self.ptr, h);
    }
    pub fn release(self: Http, h: Handle) void {
        self.vtable.release(self.ptr, h);
    }
};

const system_http = struct {
    fn req(h: Http.Handle) *http.Request {
        return @ptrCast(@alignCast(h));
    }
    fn start(_: *anyopaque, options: HttpOptions) anyerror!Http.Handle {
        // Requests that were let go of before they ended are freed here, on the UI's thread.
        http.Request.reap();
        return try http.Request.start(.{ .method = options.method, .url = options.url, .headers = options.headers, .body = options.body });
    }
    fn state(_: *anyopaque, h: Http.Handle) HttpState {
        return req(h).state();
    }
    fn status(_: *anyopaque, h: Http.Handle) i64 {
        return req(h).status;
    }
    fn body(_: *anyopaque, h: Http.Handle) []const u8 {
        return req(h).body.items;
    }
    fn header(_: *anyopaque, h: Http.Handle, name: []const u8) ?[]const u8 {
        return req(h).header(name);
    }
    fn failure(_: *anyopaque, h: Http.Handle) []const u8 {
        return req(h).err.items;
    }
    fn release(_: *anyopaque, h: Http.Handle) void {
        req(h).release();
    }
    const vtable: Http.VTable = .{ .start = start, .state = state, .status = status, .body = body, .header = header, .failure = failure, .release = release };
};

/// Real requests (`http.zig`, NSURLSession).
pub fn systemHttp() Http {
    return .{ .ptr = &system_state, .vtable = &system_http.vtable };
}

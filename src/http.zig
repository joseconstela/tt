//! One HTTP request, whole: any method, the response's status, headers
//! and body kept until the owner has read them. What a client of a REST
//! API needs (a hosting provider's, for pull requests): the paging and
//! rate-limit headers are as much the answer as the body is.
//!
//! The transport is NSURLSession, as the agents' is (`agent.zig`, which
//! streams instead and keeps its own): one session per request with a
//! delegate object whose indexed ivars hold the pointer back here. The
//! delegate's callbacks arrive on the session's own queue, so a run with
//! no window (a script) is answered too, and everything they touch sits
//! under `lock`. The owner polls `state` from its tick; once it is not
//! `pending` nothing writes to the answer any more and it is read without
//! the lock. The session invalidates itself when the task is over and its
//! "did become invalid" callback is the last it sends: only then is the
//! request freed. An owner that goes away first (`release`) leaves it on
//! the orphan list, which `reap` sweeps from the main thread.
//!
//! Nothing here knows who is asked or why, and nothing is sent that the
//! caller did not put in `Options`.
const std = @import("std");
const objc = @import("objc.zig");

const msg = objc.msg;
const id = objc.id;
const SEL = objc.SEL;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Options = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const Header = &.{},
    /// Sent as the body when not empty.
    body: []const u8 = "",
    /// Seconds without a byte before the request gives up.
    timeout: f64 = 30,
    /// A response longer than this is cut off and the request fails.
    max_bytes: usize = 32 << 20,
};

pub const State = enum { pending, done, failed };

pub const Request = struct {
    gpa: std.mem.Allocator,
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    current: State = .pending,
    /// The HTTP status once the response has started; 0 before, and for
    /// a request that never got one. A status of 400 or more is still
    /// `done`: the body says what was wrong.
    status: i64 = 0,
    /// The response's headers, each name followed by its value.
    header_list: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// Why the request `failed` (no connection, a timeout, "Stopped.").
    err: std.ArrayList(u8) = .empty,
    max_bytes: usize,
    too_long: bool = false,
    /// No callback will come after this.
    invalidated: bool = false,
    session: id = null,
    task: id = null,
    delegate: id = null,
    next_orphan: ?*Request = null,

    /// Sends the request. What comes back may already have failed (an
    /// address that is not one): `state` says so.
    pub fn start(options: Options) error{OutOfMemory}!*Request {
        const gpa = std.heap.c_allocator;
        const self = try gpa.create(Request);
        self.* = .{ .gpa = gpa, .max_bytes = options.max_bytes };

        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const nsurl = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(options.url)});
        if (nsurl == null) {
            self.fail("The address is not a valid one.");
            self.invalidated = true;
            return self;
        }
        const req = msg(id, objc.class("NSMutableURLRequest"), "requestWithURL:", .{nsurl});
        msg(void, req, "setHTTPMethod:", .{objc.nsString(options.method)});
        msg(void, req, "setTimeoutInterval:", .{options.timeout});
        for (options.headers) |h| {
            msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString(h.value), objc.nsString(h.name) });
        }
        if (options.body.len > 0) {
            const data = msg(id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, options.body.ptr), @as(NSUInteger, options.body.len) });
            msg(void, req, "setHTTPBody:", .{data});
        }

        const delegate = msg(id, msg(id, delegateClass(), "alloc", .{}), "init", .{});
        const slot: *?*Request = @ptrCast(@alignCast(object_getIndexedIvars(delegate).?));
        slot.* = self;
        self.delegate = delegate;

        // Nothing is kept between requests: no cookies, no cache, no credentials.
        const cfg = msg(id, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
        msg(void, cfg, "setTimeoutIntervalForRequest:", .{options.timeout});
        const session = msg(id, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ cfg, delegate, @as(id, null) });
        self.session = objc.retain(session);
        const task = msg(id, session, "dataTaskWithRequest:", .{req});
        self.task = objc.retain(task);
        msg(void, task, "resume", .{});
        // Invalidates once the task is over; the delegate hears about it last.
        msg(void, session, "finishTasksAndInvalidate", .{});
        return self;
    }

    /// Whether the answer is in. Until it is, the fields above are not to be read.
    pub fn state(self: *Request) State {
        self.lockMutex();
        defer self.unlockMutex();
        return self.current;
    }

    /// A response header by its name, whatever its case; null when the
    /// response has none by that name. Only once `state` is `done`.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return find(self.header_list.items, name);
    }

    /// Stops the request; it ends as failed with "Stopped.".
    pub fn cancel(self: *Request) void {
        if (self.task != null) msg(void, self.task, "cancel", .{});
    }

    /// The owner is done with the request. Freed now when no callback can
    /// still come, otherwise cancelled and swept up later by `reap`.
    pub fn release(self: *Request) void {
        self.lockMutex();
        const gone = self.invalidated;
        self.unlockMutex();
        if (gone) {
            self.destroy();
            return;
        }
        self.cancel();
        self.next_orphan = orphans;
        orphans = self;
    }

    /// Frees the released requests whose sessions have since finished.
    /// Called from the main thread, as `release` is.
    pub fn reap() void {
        var p = &orphans;
        while (p.*) |r| {
            r.lockMutex();
            const gone = r.invalidated;
            r.unlockMutex();
            if (gone) {
                p.* = r.next_orphan;
                r.destroy();
            } else p = &r.next_orphan;
        }
    }

    fn destroy(self: *Request) void {
        objc.release(self.task);
        objc.release(self.session);
        objc.release(self.delegate);
        for (self.header_list.items) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        self.header_list.deinit(self.gpa);
        self.body.deinit(self.gpa);
        self.err.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn lockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_lock(&self.lock);
    }

    fn unlockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_unlock(&self.lock);
    }

    /// Ends the request as failed, unless it has ended already.
    fn fail(self: *Request, why: []const u8) void {
        if (self.current != .pending) return;
        self.err.clearRetainingCapacity();
        self.err.appendSlice(self.gpa, why) catch {};
        self.current = .failed;
    }

    /// The status and the headers of the task's response, once there is one.
    fn noteResponse(self: *Request, task: id) void {
        if (self.status != 0) return;
        const resp = msg(id, task, "response", .{});
        if (resp == null) return;
        if (!msg(bool, resp, "respondsToSelector:", .{objc.sel("statusCode")})) {
            self.status = 200;
            return;
        }
        self.status = msg(NSInteger, resp, "statusCode", .{});
        const fields = msg(id, resp, "allHeaderFields", .{});
        if (fields == null) return;
        const keys = msg(id, fields, "allKeys", .{});
        const count: usize = msg(NSUInteger, keys, "count", .{});
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const key = msg(id, keys, "objectAtIndex:", .{@as(NSUInteger, i)});
            const value = msg(id, fields, "objectForKey:", .{key});
            if (key == null or value == null) continue;
            const name = self.gpa.dupe(u8, objc.utf8(key)) catch continue;
            const text = self.gpa.dupe(u8, objc.utf8(value)) catch {
                self.gpa.free(name);
                continue;
            };
            self.header_list.append(self.gpa, .{ .name = name, .value = text }) catch {
                self.gpa.free(name);
                self.gpa.free(text);
            };
        }
    }
};

/// The value of the header called `name`, whatever its case.
pub fn find(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

var orphans: ?*Request = null;

extern "c" fn object_getIndexedIvars(obj: id) ?*anyopaque;

var delegate_class: objc.Class = null;

fn delegateClass() objc.Class {
    if (delegate_class == null) {
        const cls = objc.objc_allocateClassPair(objc.class("NSObject"), "TTHttpDelegate", @sizeOf(?*Request));
        if (cls == null) std.debug.panic("failed to allocate objc class TTHttpDelegate", .{});
        const proto = objc.objc_getProtocol("NSURLSessionDataDelegate");
        if (proto != null) _ = objc.class_addProtocol(cls, proto);
        _ = objc.class_addMethod(cls, objc.sel("URLSession:dataTask:didReceiveData:"), @ptrCast(&didReceiveData), "v@:@@@");
        _ = objc.class_addMethod(cls, objc.sel("URLSession:task:didCompleteWithError:"), @ptrCast(&didComplete), "v@:@@@");
        _ = objc.class_addMethod(cls, objc.sel("URLSession:didBecomeInvalidWithError:"), @ptrCast(&didInvalidate), "v@:@@");
        objc.objc_registerClassPair(cls);
        delegate_class = cls;
    }
    return delegate_class;
}

fn requestOf(delegate: id) ?*Request {
    const slot: *?*Request = @ptrCast(@alignCast(object_getIndexedIvars(delegate) orelse return null));
    return slot.*;
}

fn didReceiveData(self: id, _: SEL, _: id, _: id, data: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    const len: usize = msg(NSUInteger, data, "length", .{});
    const ptr = msg(?[*]const u8, data, "bytes", .{});
    const bytes: []const u8 = if (ptr) |p| p[0..len] else "";
    req.lockMutex();
    defer req.unlockMutex();
    if (req.current != .pending) return;
    if (req.body.items.len + bytes.len > req.max_bytes) {
        req.too_long = true;
        return;
    }
    req.body.appendSlice(req.gpa, bytes) catch {
        req.too_long = true;
    };
}

fn didComplete(self: id, _: SEL, _: id, task: id, err: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    req.lockMutex();
    defer req.unlockMutex();
    req.noteResponse(task);
    if (err != null) {
        const code = msg(NSInteger, err, "code", .{});
        // NSURLErrorCancelled: `cancel` was called.
        if (code == -999) req.fail("Stopped.") else req.fail(objc.utf8(msg(id, err, "localizedDescription", .{})));
    } else if (req.too_long) {
        req.fail("The answer was too long to keep.");
    } else if (req.current == .pending) {
        req.current = .done;
    }
}

fn didInvalidate(self: id, _: SEL, _: id, _: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    req.lockMutex();
    defer req.unlockMutex();
    req.fail("The connection closed before the answer was complete.");
    req.invalidated = true;
}

test "headers are found whatever their case" {
    const headers = [_]Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "link", .value = "<https://example.invalid/2>; rel=\"next\"" },
    };
    try std.testing.expectEqualStrings("application/json", find(&headers, "content-type").?);
    try std.testing.expectEqualStrings("<https://example.invalid/2>; rel=\"next\"", find(&headers, "Link").?);
    try std.testing.expect(find(&headers, "etag") == null);
}

//! A repository on its host, asked about its pull requests: the one place
//! of the feature that sends to a hosting API. `Session` picks the
//! backend for the remote's kind (`github.zig`, `gitlab.zig`,
//! `bitbucket.zig`, `gitea.zig`), sends the calls it builds through the
//! `Http` it was handed (`hosts.zig`), and keeps what comes back:
//!
//!   - the list for a filter (open, merged, closed), a page at a time;
//!   - each pull request looked at closely (`want`), one at a time: its
//!     reviewers, checks and threads, which also feed the list's rows;
//!   - one action under way (merge, reply, resolve, update, create), and
//!     how the last one ended (`takeDone`).
//!
//! Everything is polled from the UI's tick; nothing here waits. A request
//! goes only to the API of the host the session was made for, with that
//! host's account and nothing else.
const std = @import("std");
const hosts = @import("../hosts.zig");
const wire = @import("wire.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");
const link_header = @import("../model/link_header.zig");
const github = @import("github.zig");
const gitlab = @import("gitlab.zig");
const bitbucket = @import("bitbucket.zig");
const gitea = @import("gitea.zig");

const Http = hosts.Http;
pub const Remote = wire.Remote;
pub const Draft = wire.Draft;

pub fn capabilities(kind: pr.Kind) pr.Capabilities {
    return switch (kind) {
        .github => github.capabilities,
        .gitlab => gitlab.capabilities,
        .bitbucket => bitbucket.capabilities,
        .gitea => gitea.capabilities,
    };
}

/// Where the API of the host a remote is on lives.
pub fn apiBase(a: std.mem.Allocator, kind: pr.Kind, remote: url.Remote) ![]u8 {
    return switch (kind) {
        .github => github.apiBase(a, remote),
        .gitlab => gitlab.apiBase(a, remote),
        .bitbucket => bitbucket.apiBase(a, remote),
        .gitea => gitea.apiBase(a, remote),
    };
}

/// The ref (on the remote) a pull request's head is fetched through.
pub fn headRef(a: std.mem.Allocator, kind: pr.Kind, p: pr.PullRequest) ![]const u8 {
    return switch (kind) {
        .github => github.headRef(a, p),
        .gitlab => gitlab.headRef(a, p),
        .bitbucket => bitbucket.headRef(a, p),
        .gitea => gitea.headRef(a, p),
    };
}

/// What a host said went wrong, in a line: its own message when the body
/// has one, else what the status usually means.
pub fn describe(a: std.mem.Allocator, status: i64, body: []const u8) []const u8 {
    const Message = struct {
        message: ?[]const u8 = null,
        @"error": ?std.json.Value = null,
    };
    if (wire.decode(Message, a, body)) |m| {
        if (m.message) |text| if (text.len > 0) return std.fmt.allocPrint(a, "{s} ({d})", .{ text, status }) catch text;
        if (m.@"error") |e| switch (e) {
            .string => |text| return std.fmt.allocPrint(a, "{s} ({d})", .{ text, status }) catch text,
            .object => |o| if (o.get("message")) |inner| if (inner == .string) return std.fmt.allocPrint(a, "{s} ({d})", .{ inner.string, status }) catch inner.string,
            else => {},
        };
    } else |_| {}
    return switch (status) {
        401 => "The host did not accept the account's token (401).",
        403 => "The host refused: the token may lack a permission, or a rate limit was reached (403).",
        404 => "Not found: the account may have no access to this repository (404).",
        429 => "Too many requests: the host asks to wait (429).",
        else => std.fmt.allocPrint(a, "The host answered with an error ({d}).", .{status}) catch "The host answered with an error.",
    };
}

pub const Action = enum { merge, reply, resolve, update, create };

pub const Done = struct { what: Action, ok: bool };

/// A pull request looked at closely, kept until it changes.
const Kept = struct {
    arena: std.heap.ArenaAllocator,
    detail: pr.Detail,
    /// The pull request's `updated` when this was read.
    updated: i64,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    number: u64,
    updated: i64,
    pull: pr.PullRequest,
    handles: []?Http.Handle,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    http: Http,
    /// The remote's own strings.
    arena: std.heap.ArenaAllocator,
    remote: Remote,
    headers: []const wire.Header = &.{},

    filter: pr.Filter = .open,
    /// The list on show, its strings in `list_arena`.
    list_arena: std.heap.ArenaAllocator,
    pulls: std.ArrayList(pr.PullRequest) = .empty,
    next: ?[]const u8 = null,
    list_request: ?Http.Handle = null,
    /// The request under way adds a page (rather than starting the list over).
    appending: bool = false,
    loaded: bool = false,
    list_error: std.ArrayList(u8) = .empty,

    details: std.AutoHashMapUnmanaged(u64, *Kept) = .empty,
    queue: std.ArrayList(u64) = .empty,
    job: ?*Job = null,

    action: ?Http.Handle = null,
    action_what: Action = .merge,
    action_error: std.ArrayList(u8) = .empty,
    finished: std.ArrayList(Done) = .empty,

    /// Who the account is on the host, once asked ("" until then), and
    /// what the host said instead when it would not say.
    me: []u8 = &.{},
    me_request: ?Http.Handle = null,
    me_error: std.ArrayList(u8) = .empty,
    /// Bumped whenever something the views show changed.
    generation: u64 = 0,

    /// `remote` is copied.
    pub fn create(gpa: std.mem.Allocator, http: Http, remote: Remote) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .http = http, .arena = std.heap.ArenaAllocator.init(gpa), .remote = undefined, .list_arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.remote = .{
            .kind = remote.kind,
            .api = try a.dupe(u8, std.mem.trimEnd(u8, remote.api, "/")),
            .path = try a.dupe(u8, remote.path),
            .user = try a.dupe(u8, remote.user),
            .token = try a.dupe(u8, remote.token),
        };
        self.headers = try self.buildHeaders(a);
        return self;
    }

    pub fn destroy(self: *Session) void {
        const gpa = self.gpa;
        if (self.list_request) |h| self.http.release(h);
        if (self.action) |h| self.http.release(h);
        if (self.me_request) |h| self.http.release(h);
        self.dropJob();
        var it = self.details.valueIterator();
        while (it.next()) |kept| {
            kept.*.arena.deinit();
            gpa.destroy(kept.*);
        }
        self.details.deinit(gpa);
        self.queue.deinit(gpa);
        self.pulls.deinit(gpa);
        self.list_arena.deinit();
        self.list_error.deinit(gpa);
        self.action_error.deinit(gpa);
        self.finished.deinit(gpa);
        gpa.free(self.me);
        self.me_error.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn buildHeaders(self: *Session, a: std.mem.Allocator) ![]const wire.Header {
        const base = switch (self.remote.kind) {
            .github => try github.headers(a, &self.remote),
            .gitlab => try gitlab.headers(a, &self.remote),
            .bitbucket => try bitbucket.headers(a, &self.remote),
            .gitea => try gitea.headers(a, &self.remote),
        };
        // A body, when there is one, is JSON.
        const out = try a.alloc(wire.Header, base.len + 1);
        @memcpy(out[0..base.len], base);
        out[base.len] = .{ .name = "Content-Type", .value = "application/json" };
        return out;
    }

    fn send(self: *Session, call: wire.Call) ?Http.Handle {
        return self.http.start(.{ .method = call.method, .url = call.url, .headers = self.headers, .body = call.body }) catch null;
    }

    pub fn caps(self: *const Session) pr.Capabilities {
        return capabilities(self.remote.kind);
    }

    pub fn loading(self: *const Session) bool {
        return self.list_request != null;
    }

    pub fn acting(self: *const Session) bool {
        return self.action != null;
    }

    /// Reads the list for `filter` from its first page; what is on show
    /// stays until the answer is in.
    pub fn load(self: *Session, filter: pr.Filter) void {
        if (self.list_request) |h| self.http.release(h);
        self.list_request = null;
        self.filter = filter;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.listCall(a, &self.remote, filter),
            .gitlab => gitlab.listCall(a, &self.remote, filter),
            .bitbucket => bitbucket.listCall(a, &self.remote, filter),
            .gitea => gitea.listCall(a, &self.remote, filter),
        }) catch return;
        self.list_request = self.send(call);
        self.appending = false;
        if (self.me.len == 0 and self.me_request == null and self.remote.token.len > 0) {
            const who = (switch (self.remote.kind) {
                .github => github.userCall(a, &self.remote),
                .gitlab => gitlab.userCall(a, &self.remote),
                .bitbucket => bitbucket.userCall(a, &self.remote),
                .gitea => gitea.userCall(a, &self.remote),
            }) catch return;
            self.me_request = self.send(who);
        }
    }

    /// Asks the host who the account is: the answer lands in `me`, a
    /// refusal in `me_error`. What Settings' "Test" does.
    pub fn identify(self: *Session) void {
        if (self.me_request != null) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const who = (switch (self.remote.kind) {
            .github => github.userCall(a, &self.remote),
            .gitlab => gitlab.userCall(a, &self.remote),
            .bitbucket => bitbucket.userCall(a, &self.remote),
            .gitea => gitea.userCall(a, &self.remote),
        }) catch return;
        self.me_error.clearRetainingCapacity();
        self.me_request = self.send(who);
        if (self.me_request == null) self.me_error.appendSlice(self.gpa, "The request could not be sent.") catch {};
    }

    /// True while `identify` waits for its answer.
    pub fn identifying(self: *const Session) bool {
        return self.me_request != null;
    }

    /// Asks for the next page, when there is one and nothing is under way.
    pub fn more(self: *Session) void {
        if (self.list_request != null) return;
        const next = self.next orelse return;
        self.list_request = self.send(.{ .url = next });
        self.appending = self.list_request != null;
    }

    pub fn find(self: *const Session, number: u64) ?pr.PullRequest {
        for (self.pulls.items) |p| if (p.number == number) return p;
        return null;
    }

    /// What looking closely at pull request `number` found, if it has been.
    pub fn detail(self: *const Session, number: u64) ?*const pr.Detail {
        const kept = self.details.get(number) orelse return null;
        return &kept.detail;
    }

    /// Asks for pull request `number` to be looked at closely, unless it
    /// has been since it last changed. Cheap to call every frame.
    pub fn want(self: *Session, number: u64) void {
        const p = self.find(number) orelse return;
        if (self.details.get(number)) |kept| {
            if (kept.updated == p.updated) return;
        }
        if (self.job) |j| if (j.number == number) return;
        for (self.queue.items) |q| if (q == number) return;
        self.queue.append(self.gpa, number) catch {};
    }

    /// Reads pull request `number` again, whatever was kept (after an action).
    pub fn refresh(self: *Session, number: u64) void {
        if (self.details.get(number)) |kept| kept.updated = -1;
        self.want(number);
    }

    fn dropJob(self: *Session) void {
        const job = self.job orelse return;
        for (job.handles) |h| if (h) |handle| self.http.release(handle);
        job.arena.deinit();
        self.gpa.destroy(job);
        self.job = null;
    }

    fn startJob(self: *Session) void {
        while (self.job == null and self.queue.items.len > 0) {
            const number = self.queue.orderedRemove(0);
            const listed = self.find(number) orelse continue;
            const job = self.gpa.create(Job) catch return;
            job.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .number = number, .updated = listed.updated, .pull = listed, .handles = &.{} };
            const a = job.arena.allocator();
            // The list may be read again while this is under way: the
            // pull request's own strings come along.
            job.pull = copyPull(a, listed) catch {
                job.arena.deinit();
                self.gpa.destroy(job);
                continue;
            };
            const calls = (switch (self.remote.kind) {
                .github => github.detailCalls(a, &self.remote, job.pull),
                .gitlab => gitlab.detailCalls(a, &self.remote, job.pull),
                .bitbucket => bitbucket.detailCalls(a, &self.remote, job.pull),
                .gitea => gitea.detailCalls(a, &self.remote, job.pull),
            }) catch {
                job.arena.deinit();
                self.gpa.destroy(job);
                continue;
            };
            job.handles = a.alloc(?Http.Handle, calls.len) catch {
                job.arena.deinit();
                self.gpa.destroy(job);
                continue;
            };
            for (calls, 0..) |call, i| job.handles[i] = self.send(call);
            self.job = job;
        }
    }

    // ── actions ─────────────────────────────────────────────────────────
    fn act(self: *Session, what: Action, call: wire.Call) void {
        if (self.action != null) return;
        self.action_error.clearRetainingCapacity();
        self.action = self.send(call);
        self.action_what = what;
        if (self.action == null) self.fail(what, "The request could not be sent.");
    }

    fn fail(self: *Session, what: Action, why: []const u8) void {
        self.action_error.clearRetainingCapacity();
        self.action_error.appendSlice(self.gpa, why) catch {};
        self.finished.append(self.gpa, .{ .what = what, .ok = false }) catch {};
        self.generation +%= 1;
    }

    pub fn merge(self: *Session, p: pr.PullRequest, method: pr.MergeMethod) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.mergeCall(a, &self.remote, p, method),
            .gitlab => gitlab.mergeCall(a, &self.remote, p, method),
            .bitbucket => bitbucket.mergeCall(a, &self.remote, p, method),
            .gitea => gitea.mergeCall(a, &self.remote, p, method),
        }) catch return;
        self.act(.merge, call);
    }

    pub fn reply(self: *Session, p: pr.PullRequest, thread_id: []const u8, body: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.replyCall(a, &self.remote, p, thread_id, body),
            .gitlab => gitlab.replyCall(a, &self.remote, p, thread_id, body),
            .bitbucket => bitbucket.replyCall(a, &self.remote, p, thread_id, body),
            .gitea => gitea.replyCall(a, &self.remote, p, thread_id, body),
        }) catch return self.fail(.reply, "This host's API has no way to reply to a thread.");
        self.act(.reply, call);
    }

    pub fn resolve(self: *Session, p: pr.PullRequest, thread_id: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.resolveCall(a, &self.remote, p, thread_id),
            .gitlab => gitlab.resolveCall(a, &self.remote, p, thread_id),
            .bitbucket => bitbucket.resolveCall(a, &self.remote, p, thread_id),
            .gitea => gitea.resolveCall(a, &self.remote, p, thread_id),
        }) catch return;
        self.act(.resolve, call orelse return self.fail(.resolve, "This host's API has no way to resolve a thread."));
    }

    /// Brings the pull request's branch up to date with its base, the way
    /// the host does it (`caps().update`).
    pub fn update(self: *Session, p: pr.PullRequest) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.updateCall(a, &self.remote, p),
            .gitlab => gitlab.updateCall(a, &self.remote, p),
            .bitbucket => bitbucket.updateCall(a, &self.remote, p),
            .gitea => gitea.updateCall(a, &self.remote, p),
        }) catch return;
        self.act(.update, call orelse return self.fail(.update, "This host cannot update a branch from its base."));
    }

    pub fn open(self: *Session, draft: Draft) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const call = (switch (self.remote.kind) {
            .github => github.createCall(a, &self.remote, draft),
            .gitlab => gitlab.createCall(a, &self.remote, draft),
            .bitbucket => bitbucket.createCall(a, &self.remote, draft),
            .gitea => gitea.createCall(a, &self.remote, draft),
        }) catch return;
        self.act(.create, call);
    }

    /// How the next finished action ended, once; `action_error` says why
    /// one failed.
    pub fn takeDone(self: *Session) ?Done {
        if (self.finished.items.len == 0) return null;
        return self.finished.orderedRemove(0);
    }

    // ── polling ─────────────────────────────────────────────────────────
    /// Takes answers in. True when something the views show changed.
    pub fn tick(self: *Session) bool {
        var changed = false;
        if (self.list_request) |h| if (self.http.state(h) != .pending) {
            self.list_request = null;
            defer self.http.release(h);
            self.takeList(h);
            changed = true;
        };
        if (self.me_request) |h| if (self.http.state(h) != .pending) {
            self.me_request = null;
            defer self.http.release(h);
            self.takeMe(h);
            changed = true;
        };
        if (self.job) |job| {
            var pending = false;
            for (job.handles) |maybe| if (maybe) |h| {
                if (self.http.state(h) == .pending) pending = true;
            };
            if (!pending) {
                self.takeDetail(job);
                self.dropJob();
                changed = true;
            }
        }
        self.startJob();
        if (self.action) |h| if (self.http.state(h) != .pending) {
            self.action = null;
            defer self.http.release(h);
            self.takeAction(h);
            changed = true;
        };
        if (changed) self.generation +%= 1;
        return changed;
    }

    fn takeList(self: *Session, h: Http.Handle) void {
        self.list_error.clearRetainingCapacity();
        self.loaded = true;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        if (self.http.state(h) == .failed) {
            self.list_error.appendSlice(self.gpa, self.http.failure(h)) catch {};
            return;
        }
        const status = self.http.status(h);
        const body = self.http.body(h);
        if (status >= 400) {
            self.list_error.appendSlice(self.gpa, describe(scratch.allocator(), status, body)) catch {};
            return;
        }
        if (!self.appending) {
            // The pull request a detail is being read for lives in its own job.
            self.pulls.clearRetainingCapacity();
            _ = self.list_arena.reset(.retain_capacity);
            self.next = null;
        }
        const a = self.list_arena.allocator();
        const page = (switch (self.remote.kind) {
            .github => github.parseList(a, body, self.filter),
            .gitlab => gitlab.parseList(a, body, self.filter),
            .bitbucket => bitbucket.parseList(a, body, self.filter),
            .gitea => gitea.parseList(a, body, self.filter),
        }) catch {
            self.list_error.appendSlice(self.gpa, "The host's answer could not be read.") catch {};
            return;
        };
        self.pulls.appendSlice(self.gpa, page) catch {};
        self.next = null;
        if (self.remote.kind == .bitbucket) {
            self.next = bitbucket.nextPage(a, body) catch null;
        } else if (self.http.header(h, "Link")) |link| {
            if (link_header.find(link, "next")) |next| self.next = a.dupe(u8, next) catch null;
        }
    }

    fn takeMe(self: *Session, h: Http.Handle) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        self.me_error.clearRetainingCapacity();
        if (self.http.state(h) == .failed) {
            self.me_error.appendSlice(self.gpa, self.http.failure(h)) catch {};
            return;
        }
        if (self.http.status(h) >= 400) {
            self.me_error.appendSlice(self.gpa, describe(a, self.http.status(h), self.http.body(h))) catch {};
            return;
        }
        const body = self.http.body(h);
        const name = (switch (self.remote.kind) {
            .github => github.parseUser(a, body),
            .gitlab => gitlab.parseUser(a, body),
            .bitbucket => bitbucket.parseUser(a, body),
            .gitea => gitea.parseUser(a, body),
        }) catch return;
        const copy = self.gpa.dupe(u8, name) catch return;
        self.gpa.free(self.me);
        self.me = copy;
    }

    fn takeDetail(self: *Session, job: *Job) void {
        const kept = self.gpa.create(Kept) catch return;
        kept.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .detail = .{}, .updated = job.updated };
        const a = kept.arena.allocator();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const bodies = scratch.allocator().alloc(?[]const u8, job.handles.len) catch {
            kept.arena.deinit();
            self.gpa.destroy(kept);
            return;
        };
        for (job.handles, 0..) |maybe, i| {
            bodies[i] = null;
            const h = maybe orelse continue;
            if (self.http.state(h) == .done and self.http.status(h) < 400) bodies[i] = self.http.body(h);
        }
        kept.detail = (switch (self.remote.kind) {
            .github => github.parseDetail(a, job.pull, bodies),
            .gitlab => gitlab.parseDetail(a, job.pull, bodies),
            .bitbucket => bitbucket.parseDetail(a, job.pull, bodies),
            .gitea => gitea.parseDetail(a, job.pull, bodies),
        }) catch {
            kept.arena.deinit();
            self.gpa.destroy(kept);
            return;
        };
        if (self.details.fetchRemove(job.number)) |old| {
            old.value.arena.deinit();
            self.gpa.destroy(old.value);
        }
        self.details.put(self.gpa, job.number, kept) catch {
            kept.arena.deinit();
            self.gpa.destroy(kept);
        };
    }

    fn takeAction(self: *Session, h: Http.Handle) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        self.action_error.clearRetainingCapacity();
        var ok = true;
        if (self.http.state(h) == .failed) {
            ok = false;
            self.action_error.appendSlice(self.gpa, self.http.failure(h)) catch {};
        } else if (self.http.status(h) >= 400) {
            ok = false;
            self.action_error.appendSlice(self.gpa, describe(scratch.allocator(), self.http.status(h), self.http.body(h))) catch {};
        }
        self.finished.append(self.gpa, .{ .what = self.action_what, .ok = ok }) catch {};
    }
};

/// `p` with its strings copied into `a`.
fn copyPull(a: std.mem.Allocator, p: pr.PullRequest) !pr.PullRequest {
    var out = p;
    out.title = try a.dupe(u8, p.title);
    out.author = try a.dupe(u8, p.author);
    out.head = try a.dupe(u8, p.head);
    out.base = try a.dupe(u8, p.base);
    out.head_sha = try a.dupe(u8, p.head_sha);
    out.base_sha = try a.dupe(u8, p.base_sha);
    out.merged_by = try a.dupe(u8, p.merged_by);
    out.url = try a.dupe(u8, p.url);
    const labels = try a.alloc(pr.Label, p.labels.len);
    for (p.labels, 0..) |l, i| labels[i] = .{ .name = try a.dupe(u8, l.name), .color = l.color };
    out.labels = labels;
    const requested = try a.alloc([]const u8, p.requested.len);
    for (p.requested, 0..) |r, i| requested[i] = try a.dupe(u8, r);
    out.requested = requested;
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────
/// Answers from memory: each request is matched by a piece of its address.
const FakeHost = struct {
    const Canned = struct { match: []const u8, status: i64 = 200, body: []const u8, link: ?[]const u8 = null };
    const Sent = struct { method: []u8, url: []u8, body: []u8, auth: []u8, canned: ?usize };

    canned: []const Canned,
    sent: std.ArrayList(Sent) = .empty,

    fn http(self: *FakeHost) Http {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *FakeHost) void {
        const t = std.testing.allocator;
        for (self.sent.items) |s| {
            t.free(s.method);
            t.free(s.url);
            t.free(s.body);
            t.free(s.auth);
        }
        self.sent.deinit(t);
    }

    fn of(ptr: *anyopaque) *FakeHost {
        return @ptrCast(@alignCast(ptr));
    }

    fn start(ptr: *anyopaque, options: hosts.HttpOptions) anyerror!Http.Handle {
        const self = of(ptr);
        const t = std.testing.allocator;
        var which: ?usize = null;
        for (self.canned, 0..) |c, i| {
            if (std.mem.indexOf(u8, options.url, c.match) != null) {
                which = i;
                break;
            }
        }
        var auth: []const u8 = "";
        for (options.headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization") or std.mem.eql(u8, h.name, "PRIVATE-TOKEN")) auth = h.value;
        }
        try self.sent.append(t, .{ .method = try t.dupe(u8, options.method), .url = try t.dupe(u8, options.url), .body = try t.dupe(u8, options.body), .auth = try t.dupe(u8, auth), .canned = which });
        // Handles are 1-based places in `sent`.
        return @ptrFromInt(self.sent.items.len);
    }

    fn answer(ptr: *anyopaque, h: Http.Handle) ?Canned {
        const self = of(ptr);
        const which = self.sent.items[@intFromPtr(h) - 1].canned orelse return null;
        return self.canned[which];
    }

    fn state(_: *anyopaque, _: Http.Handle) hosts.HttpState {
        return .done;
    }
    fn status(ptr: *anyopaque, h: Http.Handle) i64 {
        return if (answer(ptr, h)) |c| c.status else 404;
    }
    fn body(ptr: *anyopaque, h: Http.Handle) []const u8 {
        return if (answer(ptr, h)) |c| c.body else "{\"message\":\"Not Found\"}";
    }
    fn header(ptr: *anyopaque, h: Http.Handle, name: []const u8) ?[]const u8 {
        if (!std.ascii.eqlIgnoreCase(name, "link")) return null;
        return if (answer(ptr, h)) |c| c.link else null;
    }
    fn failure(_: *anyopaque, _: Http.Handle) []const u8 {
        return "";
    }
    fn release(_: *anyopaque, _: Http.Handle) void {}

    const vtable: Http.VTable = .{ .start = start, .state = state, .status = status, .body = body, .header = header, .failure = failure, .release = release };
};

test "github: the list, a page more, a pull request looked at closely" {
    const gpa = std.testing.allocator;
    var host: FakeHost = .{ .canned = &.{
        .{ .match = "/pulls?state=open", .body = @embedFile("../fixtures/github_pulls.json"), .link = "<https://api.github.com/repositories/5/pulls?page=2>; rel=\"next\"" },
        .{ .match = "/repositories/5/pulls?page=2", .body = "[]" },
        .{ .match = "/user", .body = "{\"login\":\"jconstela\"}" },
        .{ .match = "/pulls/142/reviews", .body = @embedFile("../fixtures/github_reviews.json") },
        .{ .match = "/pulls/142/comments", .body = @embedFile("../fixtures/github_comments.json") },
        .{ .match = "/check-runs", .body = @embedFile("../fixtures/github_checks.json") },
        .{ .match = "/status", .status = 500, .body = "oops" },
        .{ .match = "/pulls/142", .body = @embedFile("../fixtures/github_pull.json") },
    } };
    defer host.deinit();
    const s = try Session.create(gpa, host.http(), .{ .kind = .github, .api = "https://api.github.com/", .path = "acme/orchard-api", .token = "t0ken" });
    defer s.destroy();

    s.load(.open);
    try std.testing.expect(s.loading());
    try std.testing.expect(s.tick());
    try std.testing.expect(s.loaded and !s.loading());
    try std.testing.expectEqual(@as(usize, 2), s.pulls.items.len);
    try std.testing.expectEqualStrings("jconstela", s.me);
    try std.testing.expectEqualStrings("Bearer t0ken", host.sent.items[0].auth);
    try std.testing.expectEqualStrings("https://api.github.com/repos/acme/orchard-api/pulls?state=open&sort=updated&direction=desc&per_page=30", host.sent.items[0].url);

    // The next page is where the Link header said, and the end has none.
    s.more();
    _ = s.tick();
    try std.testing.expectEqual(@as(usize, 2), s.pulls.items.len);
    try std.testing.expect(s.next == null);

    // Asked for twice, read once; the statuses call failed and only its part is missing.
    s.want(142);
    s.want(142);
    _ = s.tick();
    try std.testing.expect(s.detail(142) == null);
    _ = s.tick();
    const d = s.detail(142).?;
    try std.testing.expectEqual(@as(?u32, 640), d.additions);
    try std.testing.expectEqual(@as(u32, 2), d.reviewSummary().approvals);
    try std.testing.expectEqual(@as(u32, 3), d.checkSummary().total);
    try std.testing.expectEqual(@as(usize, 1), d.threads.len);
    // Read after the job that fetched it is gone: nothing of it may point into the job.
    try std.testing.expectEqualStrings("speon", d.reviewers[d.reviewers.len - 1].name);
    try std.testing.expectEqual(pr.ReviewState.pending, d.reviewers[d.reviewers.len - 1].state);
    const sent_before = host.sent.items.len;
    s.want(142);
    _ = s.tick();
    try std.testing.expectEqual(sent_before, host.sent.items.len);
}

test "actions: what is sent, and what a refusal says" {
    const gpa = std.testing.allocator;
    var host: FakeHost = .{ .canned = &.{
        .{ .match = "/merge_requests?state=opened", .body = @embedFile("../fixtures/gitlab_merge_requests.json") },
        .{ .match = "/merge_requests/142/merge", .status = 405, .body = "{\"message\":\"405 Method Not Allowed\"}" },
        .{ .match = "/discussions/6a9c1d8f?resolved=true", .body = "{}" },
    } };
    defer host.deinit();
    const s = try Session.create(gpa, host.http(), .{ .kind = .gitlab, .api = "https://gitlab.example.com/api/v4", .path = "acme/platform/orchard-api", .token = "t0ken" });
    defer s.destroy();
    s.load(.open);
    _ = s.tick();
    const p = s.find(142).?;

    s.resolve(p, "6a9c1d8f");
    try std.testing.expect(s.acting());
    _ = s.tick();
    try std.testing.expectEqual(Done{ .what = .resolve, .ok = true }, s.takeDone().?);
    try std.testing.expectEqualStrings("PUT", host.sent.items[host.sent.items.len - 1].method);
    try std.testing.expectEqualStrings("t0ken", host.sent.items[host.sent.items.len - 1].auth);

    s.merge(p, .squash);
    _ = s.tick();
    try std.testing.expectEqual(Done{ .what = .merge, .ok = false }, s.takeDone().?);
    try std.testing.expectEqualStrings("405 Method Not Allowed (405)", s.action_error.items);
    try std.testing.expect(s.takeDone() == null);
}

test "a host with no answer for an action says so without sending" {
    const gpa = std.testing.allocator;
    var host: FakeHost = .{ .canned = &.{} };
    defer host.deinit();
    const s = try Session.create(gpa, host.http(), .{ .kind = .bitbucket, .api = "https://api.bitbucket.org/2.0", .path = "acme/orchard-api", .user = "me@example.invalid", .token = "t0ken" });
    defer s.destroy();
    try std.testing.expectEqual(pr.Update.none, s.caps().update);
    s.update(.{ .number = 1, .title = "", .author = "" });
    try std.testing.expectEqual(@as(usize, 0), host.sent.items.len);
    try std.testing.expectEqual(Done{ .what = .update, .ok = false }, s.takeDone().?);
    // A list the host refuses: its own words, with the status.
    s.load(.open);
    _ = s.tick();
    try std.testing.expectEqualStrings("Not Found (404)", s.list_error.items);
}

test "errors in the hosts' own shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Bad credentials (401)", describe(a, 401, "{\"message\":\"Bad credentials\",\"documentation_url\":\"x\"}"));
    try std.testing.expectEqualStrings("Repository not found (404)", describe(a, 404, "{\"type\":\"error\",\"error\":{\"message\":\"Repository not found\"}}"));
    try std.testing.expectEqualStrings("invalid_token (401)", describe(a, 401, "{\"error\":\"invalid_token\"}"));
    try std.testing.expectEqualStrings("The host did not accept the account's token (401).", describe(a, 401, "<html>nope</html>"));
    try std.testing.expectEqualStrings("The host answered with an error (502).", describe(a, 502, ""));
}

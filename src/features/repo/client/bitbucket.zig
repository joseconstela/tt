//! Bitbucket Cloud (bitbucket.org, at `api.bitbucket.org/2.0`): its REST
//! API as calls to send and answers decoded. Nothing here sends.
//! Bitbucket Data Center is a different API and is not this.
//!
//! One pull request looked at closely is three calls: the pull request
//! itself (its description and its participants, each with what they
//! said of it), the build statuses of its head, and its comments, which
//! come flat and are grouped here into threads by the comment each one
//! replies to. A list's next page is named in the body (`next`), not in
//! a header. Bitbucket has no labels and no way to update a branch from
//! its base: neither is offered.
//!
//! An API token is sent with the account's e-mail as Basic auth; a
//! repository or workspace access token has no user and goes as Bearer.
const std = @import("std");
const wire = @import("wire.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");

const Remote = wire.Remote;
const Call = wire.Call;

pub const capabilities: pr.Capabilities = .{
    .labels = false,
    .resolve = true,
    .update = .none,
    .merge_methods = &.{ .merge, .squash, .fast_forward },
    .noun = "pull request",
};

pub fn apiBase(a: std.mem.Allocator, _: url.Remote) ![]u8 {
    return a.dupe(u8, "https://api.bitbucket.org/2.0");
}

pub fn headers(a: std.mem.Allocator, r: *const Remote) ![]wire.Header {
    var out: std.ArrayList(wire.Header) = .empty;
    try out.append(a, .{ .name = "Accept", .value = "application/json" });
    if (r.token.len > 0) {
        const value = if (r.user.len > 0) try wire.basic(a, r.user, r.token) else try std.fmt.allocPrint(a, "Bearer {s}", .{r.token});
        try out.append(a, .{ .name = "Authorization", .value = value });
    }
    return out.items;
}

pub fn userCall(a: std.mem.Allocator, r: *const Remote) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/user", .{r.api}) };
}

pub fn parseUser(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const u = try wire.decode(User, a, body);
    return who(u);
}

pub fn listCall(a: std.mem.Allocator, r: *const Remote, filter: pr.Filter) !Call {
    const state = switch (filter) {
        .open => "OPEN",
        .merged => "MERGED",
        .closed => "DECLINED",
    };
    return .{ .url = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests?state={s}&pagelen=30&sort=-updated_on", .{ r.api, r.path, state }) };
}

const User = struct { display_name: ?[]const u8 = null, nickname: ?[]const u8 = null };
const Branch = struct { name: ?[]const u8 = null };
const Commit = struct { hash: ?[]const u8 = null };
const End = struct { branch: ?Branch = null, commit: ?Commit = null };
const Href = struct { href: ?[]const u8 = null };
const Links = struct { html: ?Href = null };
const Participant = struct { user: ?User = null, role: ?[]const u8 = null, approved: ?bool = null, state: ?[]const u8 = null };
const Pull = struct {
    id: u64 = 0,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,
    draft: ?bool = null,
    author: ?User = null,
    closed_by: ?User = null,
    source: ?End = null,
    destination: ?End = null,
    created_on: ?[]const u8 = null,
    updated_on: ?[]const u8 = null,
    links: ?Links = null,
    comment_count: ?u32 = null,
    // Only when a single pull request is asked for.
    participants: ?[]const Participant = null,
    reviewers: ?[]const User = null,
};
const Page = struct { values: ?[]const Pull = null, next: ?[]const u8 = null };

fn who(u: ?User) []const u8 {
    const user = u orelse return "";
    return user.display_name orelse user.nickname orelse "";
}

fn toPull(p: Pull) pr.PullRequest {
    const state_text = wire.text(p.state);
    const merged = std.mem.eql(u8, state_text, "MERGED");
    return .{
        .number = p.id,
        .title = wire.text(p.title),
        .author = who(p.author),
        .state = if (merged) .merged else if (std.mem.eql(u8, state_text, "OPEN")) .open else .closed,
        .draft = p.draft orelse false,
        .head = if (p.source) |s| (if (s.branch) |b| wire.text(b.name) else "") else "",
        .base = if (p.destination) |d| (if (d.branch) |b| wire.text(b.name) else "") else "",
        .head_sha = if (p.source) |s| (if (s.commit) |c| wire.text(c.hash) else "") else "",
        .base_sha = if (p.destination) |d| (if (d.commit) |c| wire.text(c.hash) else "") else "",
        .created = pr.parseTime(wire.text(p.created_on)),
        .updated = pr.parseTime(wire.text(p.updated_on)),
        .merged_by = if (merged) who(p.closed_by) else "",
        .url = if (p.links) |l| (if (l.html) |h| wire.text(h.href) else "") else "",
        .comments = p.comment_count,
    };
}

pub fn parseList(a: std.mem.Allocator, body: []const u8, _: pr.Filter) ![]pr.PullRequest {
    const page = try wire.decode(Page, a, body);
    const raw = page.values orelse &.{};
    const out = try a.alloc(pr.PullRequest, raw.len);
    for (raw, 0..) |p, i| out[i] = toPull(p);
    return out;
}

/// Where the next page of a list is, as its body says; null at the end.
pub fn nextPage(a: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const page = try wire.decode(struct { next: ?[]const u8 = null }, a, body);
    return page.next;
}

/// In this order: the pull request, its head's build statuses, its comments.
pub fn detailCalls(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) ![]Call {
    const base = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests/{d}", .{ r.api, r.path, p.number });
    const calls = try a.alloc(Call, 3);
    calls[0] = .{ .url = base };
    calls[1] = .{ .url = try std.fmt.allocPrint(a, "{s}/statuses?pagelen=100", .{base}) };
    calls[2] = .{ .url = try std.fmt.allocPrint(a, "{s}/comments?pagelen=100", .{base}) };
    return calls;
}

const Build = struct { name: ?[]const u8 = null, key: ?[]const u8 = null, state: ?[]const u8 = null, created_on: ?[]const u8 = null, updated_on: ?[]const u8 = null };
const Builds = struct { values: ?[]const Build = null };
const Content = struct { raw: ?[]const u8 = null };
const Inline = struct { path: ?[]const u8 = null, to: ?u32 = null, from: ?u32 = null };
const Parent = struct { id: u64 = 0 };
const Resolution = struct { type: ?[]const u8 = null };
const RawComment = struct {
    id: u64 = 0,
    content: ?Content = null,
    user: ?User = null,
    created_on: ?[]const u8 = null,
    deleted: ?bool = null,
    @"inline": ?Inline = null,
    parent: ?Parent = null,
    resolution: ?Resolution = null,
};
const Comments = struct { values: ?[]const RawComment = null };

/// `bodies` are the answers to `detailCalls`, in its order; one that
/// failed is null and what it would have said is left out.
pub fn parseDetail(a: std.mem.Allocator, _: pr.PullRequest, bodies: []const ?[]const u8) !pr.Detail {
    var out: pr.Detail = .{};
    if (bodies.len > 0) if (bodies[0]) |body| {
        const p = try wire.decode(Pull, a, body);
        out.body = wire.text(p.description);
        out.comments = p.comment_count;
        var reviewers: std.ArrayList(pr.Reviewer) = .empty;
        for (p.participants orelse &.{}) |part| {
            const said = wire.text(part.state);
            const state: pr.ReviewState = if (part.approved orelse false or std.mem.eql(u8, said, "approved"))
                .approved
            else if (std.mem.eql(u8, said, "changes_requested"))
                .changes_requested
            else if (std.mem.eql(u8, wire.text(part.role), "REVIEWER"))
                .pending
            else
                continue;
            try reviewers.append(a, .{ .name = who(part.user), .state = state });
        }
        out.reviewers = reviewers.items;
    };

    if (bodies.len > 1) if (bodies[1]) |body| {
        var checks: std.ArrayList(pr.Check) = .empty;
        const builds = try wire.decode(Builds, a, body);
        for (builds.values orelse &.{}) |b| {
            const s = wire.text(b.state);
            const state: pr.CheckState = if (std.mem.eql(u8, s, "SUCCESSFUL")) .passed else if (std.mem.eql(u8, s, "INPROGRESS")) .pending else .failed;
            try checks.append(a, .{ .name = wire.text(b.name orelse b.key), .state = state, .seconds = if (state == .pending) null else wire.elapsed(b.created_on, b.updated_on) });
        }
        out.checks = checks.items;
    };

    if (bodies.len > 2) if (bodies[2]) |body| {
        const raw = try wire.decode(Comments, a, body);
        out.threads = try threads(a, raw.values orelse &.{});
    };
    return out;
}

/// Comments on a line start a thread; a reply names its parent, which may
/// itself be a reply: it joins the thread its parent is in.
fn threads(a: std.mem.Allocator, comments: []const RawComment) ![]pr.Thread {
    const Building = struct { root: u64, path: []const u8, line: u32, old_line: u32, resolved: bool, ids: std.ArrayList(u64), comments: std.ArrayList(pr.Comment) };
    var list: std.ArrayList(Building) = .empty;
    for (comments) |c| {
        if (c.deleted orelse false) continue;
        const comment: pr.Comment = .{
            .id = try wire.number(a, c.id),
            .author = who(c.user),
            .created = pr.parseTime(wire.text(c.created_on)),
            .body = if (c.content) |content| wire.text(content.raw) else "",
        };
        if (c.parent) |parent| {
            for (list.items) |*t| {
                var mine = false;
                for (t.ids.items) |id| {
                    if (id == parent.id) mine = true;
                }
                if (!mine) continue;
                try t.ids.append(a, c.id);
                try t.comments.append(a, comment);
            }
            continue;
        }
        const at = c.@"inline" orelse continue;
        var fresh: Building = .{ .root = c.id, .path = wire.text(at.path), .line = at.to orelse 0, .old_line = if (at.to == null) at.from orelse 0 else 0, .resolved = c.resolution != null, .ids = .empty, .comments = .empty };
        try fresh.ids.append(a, c.id);
        try fresh.comments.append(a, comment);
        try list.append(a, fresh);
    }
    const out = try a.alloc(pr.Thread, list.items.len);
    for (list.items, 0..) |t, i| out[i] = .{ .id = try wire.number(a, t.root), .path = t.path, .line = t.line, .old_line = t.old_line, .resolved = t.resolved, .comments = t.comments.items };
    return out;
}

pub fn mergeCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, method: pr.MergeMethod) !Call {
    const how = switch (method) {
        .squash => "squash",
        .fast_forward => "fast_forward",
        .merge, .rebase => "merge_commit",
    };
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests/{d}/merge", .{ r.api, r.path, p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"merge_strategy\":\"{s}\"}}", .{how}),
    };
}

pub fn replyCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, thread_id: []const u8, body: []const u8) !Call {
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests/{d}/comments", .{ r.api, r.path, p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"content\":{{\"raw\":{s}}},\"parent\":{{\"id\":{s}}}}}", .{ try wire.quote(a, body), thread_id }),
    };
}

pub fn resolveCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, thread_id: []const u8) !?Call {
    return .{ .method = "POST", .url = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests/{d}/comments/{s}/resolve", .{ r.api, r.path, p.number, thread_id }) };
}

pub fn updateCall(_: std.mem.Allocator, _: *const Remote, _: pr.PullRequest) !?Call {
    return null;
}

pub fn createCall(a: std.mem.Allocator, r: *const Remote, d: wire.Draft) !Call {
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repositories/{s}/pullrequests", .{ r.api, r.path }),
        .body = try std.fmt.allocPrint(a, "{{\"title\":{s},\"description\":{s},\"source\":{{\"branch\":{{\"name\":{s}}}}},\"destination\":{{\"branch\":{{\"name\":{s}}}}},\"draft\":{s}}}", .{ try wire.quote(a, d.title), try wire.quote(a, d.body), try wire.quote(a, d.head), try wire.quote(a, d.base), if (d.draft) "true" else "false" }),
    };
}

/// Bitbucket keeps no ref per pull request: its head is its source branch.
pub fn headRef(a: std.mem.Allocator, p: pr.PullRequest) ![]const u8 {
    return a.dupe(u8, p.head);
}

// ── tests ───────────────────────────────────────────────────────────────
const remote: Remote = .{ .kind = .bitbucket, .api = "https://api.bitbucket.org/2.0", .path = "acme/orchard-api", .user = "me@example.invalid", .token = "t0ken" };

test "bitbucket: what a request carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try headers(a, &remote);
    try std.testing.expect(std.mem.startsWith(u8, h[1].value, "Basic "));
    // An access token has no user.
    const access: Remote = .{ .kind = .bitbucket, .api = remote.api, .path = remote.path, .token = "t0ken" };
    try std.testing.expectEqualStrings("Bearer t0ken", (try headers(a, &access))[1].value);
    try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/acme/orchard-api/pullrequests?state=DECLINED&pagelen=30&sort=-updated_on", (try listCall(a, &remote, .closed)).url);
}

test "bitbucket: a list, and where its next page is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = @embedFile("../fixtures/bitbucket_pullrequests.json");
    const list = try parseList(a, body, .open);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u64, 142), list[0].number);
    try std.testing.expectEqualStrings("María Lado", list[0].author);
    try std.testing.expectEqualStrings("feat/webhooks", list[0].head);
    try std.testing.expectEqualStrings("6f6fc36", list[0].head_sha);
    try std.testing.expectEqualStrings("https://bitbucket.org/acme/orchard-api/pull-requests/142", list[0].url);
    try std.testing.expectEqual(@as(?u32, 8), list[0].comments);
    try std.testing.expectEqual(@as(i64, 1795286520), list[0].updated);
    try std.testing.expectEqual(@as(usize, 0), list[0].labels.len);
    try std.testing.expect(list[1].draft);
    try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/acme/orchard-api/pullrequests?state=OPEN&pagelen=30&page=2", (try nextPage(a, body)).?);
    try std.testing.expect((try nextPage(a, "{\"values\":[]}")) == null);
}

test "bitbucket: a pull request looked at closely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseList(a, @embedFile("../fixtures/bitbucket_pullrequests.json"), .open);
    const d = try parseDetail(a, list[0], &.{
        @embedFile("../fixtures/bitbucket_pullrequest.json"),
        @embedFile("../fixtures/bitbucket_statuses.json"),
        @embedFile("../fixtures/bitbucket_comments.json"),
    });
    try std.testing.expectEqualStrings("Queue with exponential retries.", d.body);
    // One approved, one asked for changes, one reviewer has not answered; the author took part but reviews nothing.
    const r = d.reviewSummary();
    try std.testing.expectEqual(@as(u32, 1), r.approvals);
    try std.testing.expectEqual(@as(u32, 1), r.changes_requested);
    try std.testing.expectEqual(@as(u32, 1), r.waiting);
    try std.testing.expectEqual(@as(usize, 3), d.reviewers.len);
    const c = d.checkSummary();
    try std.testing.expectEqual(@as(u32, 2), c.total);
    try std.testing.expectEqual(@as(u32, 1), c.failed);
    try std.testing.expectEqual(@as(?u32, 134), d.checks[0].seconds);
    // A comment on a line with a reply and a reply to that reply; the general comment is no thread.
    try std.testing.expectEqual(@as(usize, 1), d.threads.len);
    try std.testing.expectEqual(@as(u32, 10), d.threads[0].line);
    try std.testing.expectEqual(@as(usize, 3), d.threads[0].comments.len);
    try std.testing.expectEqual(@as(?bool, false), d.threads[0].resolved);
}

test "bitbucket: what the actions send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: pr.PullRequest = .{ .number = 142, .title = "", .author = "", .head = "feat/webhooks" };
    try std.testing.expectEqualStrings("{\"merge_strategy\":\"fast_forward\"}", (try mergeCall(a, &remote, p, .fast_forward)).body);
    try std.testing.expectEqualStrings("{\"content\":{\"raw\":\"ok\"},\"parent\":{\"id\":9001}}", (try replyCall(a, &remote, p, "9001", "ok")).body);
    try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/acme/orchard-api/pullrequests/142/comments/9001/resolve", (try resolveCall(a, &remote, p, "9001")).?.url);
    try std.testing.expect((try updateCall(a, &remote, p)) == null);
    try std.testing.expectEqualStrings("feat/webhooks", try headRef(a, p));
}

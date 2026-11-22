//! Gitea and Forgejo (codeberg.org, gitea.com, self-hosted, at
//! `<host>/api/v1`): their REST API as calls to send and answers decoded.
//! Nothing here sends.
//!
//! One pull request looked at closely is three calls: the pull request
//! itself, its reviews, and the combined status of its head commit. The
//! list already carries the line counts, the comment count and whether
//! the pull request merges cleanly. Comment threads are not read: each
//! review's comments are a call of their own, and replying to or
//! resolving one is not in the API these servers share.
const std = @import("std");
const wire = @import("wire.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");

const Remote = wire.Remote;
const Call = wire.Call;

pub const capabilities: pr.Capabilities = .{
    .labels = true,
    .reply = false,
    .resolve = false,
    .update = .rebase,
    .merge_methods = &.{ .merge, .squash, .rebase },
    .noun = "pull request",
};

pub fn apiBase(a: std.mem.Allocator, r: url.Remote) ![]u8 {
    const scheme = if (r.secure) "https" else "http";
    if (r.port) |p| return std.fmt.allocPrint(a, "{s}://{s}:{d}/api/v1", .{ scheme, r.host, p });
    return std.fmt.allocPrint(a, "{s}://{s}/api/v1", .{ scheme, r.host });
}

pub fn headers(a: std.mem.Allocator, r: *const Remote) ![]wire.Header {
    var out: std.ArrayList(wire.Header) = .empty;
    try out.append(a, .{ .name = "Accept", .value = "application/json" });
    if (r.token.len > 0) try out.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "token {s}", .{r.token}) });
    return out.items;
}

pub fn userCall(a: std.mem.Allocator, r: *const Remote) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/user", .{r.api}) };
}

pub fn parseUser(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const u = try wire.decode(User, a, body);
    return wire.text(u.login);
}

/// Merged and closed are both "closed" here: `parseList` tells them apart.
pub fn listCall(a: std.mem.Allocator, r: *const Remote, filter: pr.Filter) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls?state={s}&sort=recentupdate&limit=30", .{ r.api, r.path, if (filter == .open) "open" else "closed" }) };
}

const User = struct { login: ?[]const u8 = null };
const Ref = struct { ref: ?[]const u8 = null, sha: ?[]const u8 = null };
const RawLabel = struct { name: ?[]const u8 = null, color: ?[]const u8 = null };
const Pull = struct {
    number: u64 = 0,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    draft: ?bool = null,
    user: ?User = null,
    head: ?Ref = null,
    base: ?Ref = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    merged: ?bool = null,
    merged_by: ?User = null,
    html_url: ?[]const u8 = null,
    comments: ?u32 = null,
    review_comments: ?u32 = null,
    additions: ?u32 = null,
    deletions: ?u32 = null,
    mergeable: ?bool = null,
    labels: ?[]const RawLabel = null,
    requested_reviewers: ?[]const User = null,
};

fn toPull(a: std.mem.Allocator, p: Pull) !pr.PullRequest {
    var labels: std.ArrayList(pr.Label) = .empty;
    for (p.labels orelse &.{}) |l| try labels.append(a, .{ .name = wire.text(l.name), .color = pr.parseColor(wire.text(l.color)) });
    var requested: std.ArrayList([]const u8) = .empty;
    for (p.requested_reviewers orelse &.{}) |u| try requested.append(a, wire.text(u.login));
    const merged = p.merged orelse false;
    const title = wire.text(p.title);
    return .{
        .number = p.number,
        .title = title,
        .author = if (p.user) |u| wire.text(u.login) else "",
        .state = if (merged) .merged else if (std.mem.eql(u8, wire.text(p.state), "open")) .open else .closed,
        // Older servers have no `draft`: a work in progress says so in its title.
        .draft = p.draft orelse (std.ascii.startsWithIgnoreCase(title, "WIP:") or std.ascii.startsWithIgnoreCase(title, "[WIP]")),
        .head = if (p.head) |h| wire.text(h.ref) else "",
        .base = if (p.base) |b| wire.text(b.ref) else "",
        .head_sha = if (p.head) |h| wire.text(h.sha) else "",
        .base_sha = if (p.base) |b| wire.text(b.sha) else "",
        .created = pr.parseTime(wire.text(p.created_at)),
        .updated = pr.parseTime(wire.text(p.updated_at)),
        .merged_by = if (p.merged_by) |u| wire.text(u.login) else "",
        .url = wire.text(p.html_url),
        .comments = if (p.comments) |c| c + (p.review_comments orelse 0) else null,
        .additions = p.additions,
        .deletions = p.deletions,
        .labels = labels.items,
        .requested = requested.items,
        .mergeable = if (merged) null else p.mergeable,
    };
}

pub fn parseList(a: std.mem.Allocator, body: []const u8, filter: pr.Filter) ![]pr.PullRequest {
    const raw = try wire.decode([]const Pull, a, body);
    var out: std.ArrayList(pr.PullRequest) = .empty;
    for (raw) |p| {
        const pull = try toPull(a, p);
        const wanted = switch (filter) {
            .open => pull.state == .open,
            .merged => pull.state == .merged,
            .closed => pull.state == .closed,
        };
        if (wanted) try out.append(a, pull);
    }
    return out.items;
}

/// In this order: the pull request, its reviews, its head's combined status.
pub fn detailCalls(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) ![]Call {
    const calls = try a.alloc(Call, 3);
    calls[0] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}", .{ r.api, r.path, p.number }) };
    calls[1] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/reviews", .{ r.api, r.path, p.number }) };
    calls[2] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/commits/{s}/status", .{ r.api, r.path, p.head_sha }) };
    return calls;
}

const Review = struct { user: ?User = null, state: ?[]const u8 = null, dismissed: ?bool = null, stale: ?bool = null };
const Status = struct { context: ?[]const u8 = null, status: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };
const Combined = struct { statuses: ?[]const Status = null };

/// `bodies` are the answers to `detailCalls`, in its order; one that
/// failed is null and what it would have said is left out.
pub fn parseDetail(a: std.mem.Allocator, p: pr.PullRequest, bodies: []const ?[]const u8) !pr.Detail {
    var out: pr.Detail = .{ .additions = p.additions, .deletions = p.deletions, .comments = p.comments, .mergeable = p.mergeable };
    if (bodies.len > 0) if (bodies[0]) |body| {
        const full = try toPull(a, try wire.decode(Pull, a, body));
        const raw = try wire.decode(struct { body: ?[]const u8 = null }, a, body);
        out.body = wire.text(raw.body);
        out.additions = full.additions;
        out.deletions = full.deletions;
        out.comments = full.comments;
        out.mergeable = full.mergeable;
    };

    var reviewers: std.ArrayList(pr.Reviewer) = .empty;
    if (bodies.len > 1) if (bodies[1]) |body| {
        for (try wire.decode([]const Review, a, body)) |rv| {
            if (rv.dismissed orelse false) continue;
            const name = if (rv.user) |u| wire.text(u.login) else "";
            if (name.len == 0) continue;
            const s = wire.text(rv.state);
            const state: pr.ReviewState = if (std.mem.eql(u8, s, "APPROVED"))
                .approved
            else if (std.mem.eql(u8, s, "REQUEST_CHANGES"))
                .changes_requested
            else if (std.mem.eql(u8, s, "REQUEST_REVIEW"))
                .pending
            else if (std.mem.eql(u8, s, "COMMENT"))
                .commented
            else
                continue;
            var found = false;
            for (reviewers.items) |*have| {
                if (!std.mem.eql(u8, have.name, name)) continue;
                if (state != .commented) have.state = state;
                found = true;
            }
            if (!found) try reviewers.append(a, .{ .name = name, .state = state });
        }
    };
    for (p.requested) |name| {
        var found = false;
        for (reviewers.items) |have| {
            if (std.mem.eql(u8, have.name, name)) found = true;
        }
        // The name is the list's, which may go before this detail does.
        if (!found) try reviewers.append(a, .{ .name = try a.dupe(u8, name), .state = .pending });
    }
    out.reviewers = reviewers.items;

    if (bodies.len > 2) if (bodies[2]) |body| {
        var checks: std.ArrayList(pr.Check) = .empty;
        const combined = try wire.decode(Combined, a, body);
        for (combined.statuses orelse &.{}) |s| {
            const said = wire.text(s.status);
            const state: pr.CheckState = if (std.mem.eql(u8, said, "success")) .passed else if (std.mem.eql(u8, said, "pending")) .pending else if (std.mem.eql(u8, said, "skipped")) .skipped else .failed;
            try checks.append(a, .{ .name = wire.text(s.context), .state = state, .seconds = if (state == .pending) null else wire.elapsed(s.created_at, s.updated_at) });
        }
        out.checks = checks.items;
    };
    return out;
}

pub fn mergeCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, method: pr.MergeMethod) !Call {
    const how = switch (method) {
        .squash => "squash",
        .rebase => "rebase",
        .merge, .fast_forward => "merge",
    };
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/merge", .{ r.api, r.path, p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"Do\":\"{s}\",\"head_commit_id\":{s}}}", .{ how, try wire.quote(a, p.head_sha) }),
    };
}

pub fn replyCall(_: std.mem.Allocator, _: *const Remote, _: pr.PullRequest, _: []const u8, _: []const u8) !Call {
    return error.Unsupported;
}

pub fn resolveCall(_: std.mem.Allocator, _: *const Remote, _: pr.PullRequest, _: []const u8) !?Call {
    return null;
}

pub fn updateCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) !?Call {
    return .{ .method = "POST", .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/update?style=rebase", .{ r.api, r.path, p.number }) };
}

/// A draft is a pull request whose title says so.
pub fn createCall(a: std.mem.Allocator, r: *const Remote, d: wire.Draft) !Call {
    const title = if (d.draft) try std.fmt.allocPrint(a, "WIP: {s}", .{d.title}) else d.title;
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls", .{ r.api, r.path }),
        .body = try std.fmt.allocPrint(a, "{{\"title\":{s},\"body\":{s},\"head\":{s},\"base\":{s}}}", .{ try wire.quote(a, title), try wire.quote(a, d.body), try wire.quote(a, d.head), try wire.quote(a, d.base) }),
    };
}

pub fn headRef(a: std.mem.Allocator, p: pr.PullRequest) ![]const u8 {
    return std.fmt.allocPrint(a, "refs/pull/{d}/head", .{p.number});
}

// ── tests ───────────────────────────────────────────────────────────────
const remote: Remote = .{ .kind = .gitea, .api = "https://codeberg.org/api/v1", .path = "acme/orchard-api", .token = "t0ken" };

test "gitea: where the API is, and what a request carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http://localhost:3000/api/v1", try apiBase(a, .{ .host = "localhost", .path = "a/b", .port = 3000, .secure = false }));
    try std.testing.expectEqualStrings("token t0ken", (try headers(a, &remote))[1].value);
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/acme/orchard-api/pulls?state=open&sort=recentupdate&limit=30", (try listCall(a, &remote, .open)).url);
}

test "gitea: a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = @embedFile("../fixtures/gitea_pulls.json");
    const open = try parseList(a, body, .open);
    try std.testing.expectEqual(@as(usize, 2), open.len);
    try std.testing.expectEqual(@as(u64, 142), open[0].number);
    try std.testing.expectEqualStrings("mlado", open[0].author);
    try std.testing.expectEqual(@as(?u32, 640), open[0].additions);
    try std.testing.expectEqual(@as(?u32, 8), open[0].comments);
    try std.testing.expectEqual(@as(?bool, true), open[0].mergeable);
    try std.testing.expectEqual(@as(?u24, 0x5bd0c0), open[0].labels[0].color);
    try std.testing.expectEqual(@as(i64, 1795286520), open[0].updated);
    // No `draft` field on this one: its title says it is one.
    try std.testing.expect(open[1].draft);
    const merged = try parseList(a, body, .merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("jconstela", merged[0].merged_by);
}

test "gitea: a pull request looked at closely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseList(a, @embedFile("../fixtures/gitea_pulls.json"), .open);
    const d = try parseDetail(a, list[0], &.{ null, @embedFile("../fixtures/gitea_reviews.json"), @embedFile("../fixtures/gitea_status.json") });
    // The pull request's own call failed: the list's counts stand.
    try std.testing.expectEqual(@as(?u32, 640), d.additions);
    // One approval; a dismissed one does not count; speon was asked and waits.
    const r = d.reviewSummary();
    try std.testing.expectEqual(@as(u32, 1), r.approvals);
    try std.testing.expectEqual(@as(u32, 1), r.waiting);
    try std.testing.expectEqual(@as(usize, 2), d.reviewers.len);
    const c = d.checkSummary();
    try std.testing.expectEqual(@as(u32, 2), c.total);
    try std.testing.expectEqual(@as(u32, 1), c.passed);
    try std.testing.expectEqual(@as(u32, 1), c.pending);
    try std.testing.expectEqual(@as(usize, 0), d.threads.len);
}

test "gitea: what the actions send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: pr.PullRequest = .{ .number = 142, .title = "", .author = "", .head_sha = "abc" };
    try std.testing.expectEqualStrings("{\"Do\":\"rebase\",\"head_commit_id\":\"abc\"}", (try mergeCall(a, &remote, p, .rebase)).body);
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/acme/orchard-api/pulls/142/update?style=rebase", (try updateCall(a, &remote, p)).?.url);
    try std.testing.expectError(error.Unsupported, replyCall(a, &remote, p, "1", "x"));
    const made = try createCall(a, &remote, .{ .title = "T", .head = "feat/x", .base = "main", .draft = true });
    try std.testing.expectEqualStrings("{\"title\":\"WIP: T\",\"body\":\"\",\"head\":\"feat/x\",\"base\":\"main\"}", made.body);
}

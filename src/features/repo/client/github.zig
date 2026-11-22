//! GitHub (github.com, and GitHub Enterprise at `<host>/api/v3`): its
//! REST API as calls to send and answers decoded. Nothing here sends.
//!
//! One pull request looked at closely is five calls: the pull request
//! itself (its counts and whether it merges cleanly), its reviews, the
//! check runs and the commit statuses of its head, and its review
//! comments, which come flat and are grouped here into threads by the
//! comment each one replies to.
//!
//! What REST does not offer, and so is not here: whether a thread is
//! resolved and resolving one, and updating a branch by rebase (both are
//! in GitHub's GraphQL API only). Updating a branch merges its base in.
const std = @import("std");
const wire = @import("wire.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");

const Remote = wire.Remote;
const Call = wire.Call;

pub const capabilities: pr.Capabilities = .{
    .labels = true,
    .resolve = false,
    .update = .merge,
    .merge_methods = &.{ .squash, .merge, .rebase },
    .noun = "pull request",
};

pub fn apiBase(a: std.mem.Allocator, r: url.Remote) ![]u8 {
    if (std.ascii.eqlIgnoreCase(r.host, "github.com")) return a.dupe(u8, "https://api.github.com");
    const scheme = if (r.secure) "https" else "http";
    if (r.port) |p| return std.fmt.allocPrint(a, "{s}://{s}:{d}/api/v3", .{ scheme, r.host, p });
    return std.fmt.allocPrint(a, "{s}://{s}/api/v3", .{ scheme, r.host });
}

pub fn headers(a: std.mem.Allocator, r: *const Remote) ![]wire.Header {
    var out: std.ArrayList(wire.Header) = .empty;
    try out.append(a, .{ .name = "Accept", .value = "application/vnd.github+json" });
    try out.append(a, .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" });
    if (r.token.len > 0) try out.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{r.token}) });
    return out.items;
}

pub fn userCall(a: std.mem.Allocator, r: *const Remote) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/user", .{r.api}) };
}

pub fn parseUser(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const u = try wire.decode(User, a, body);
    return wire.text(u.login);
}

/// Merged and closed are both "closed" to GitHub: `parseList` tells them apart.
pub fn listCall(a: std.mem.Allocator, r: *const Remote, filter: pr.Filter) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls?state={s}&sort=updated&direction=desc&per_page=30", .{ r.api, r.path, if (filter == .open) "open" else "closed" }) };
}

const User = struct { login: ?[]const u8 = null };
const Ref = struct { ref: ?[]const u8 = null, sha: ?[]const u8 = null };
const RawLabel = struct { name: ?[]const u8 = null, color: ?[]const u8 = null };
const Pull = struct {
    number: u64 = 0,
    title: ?[]const u8 = null,
    state: ?[]const u8 = null,
    draft: ?bool = null,
    user: ?User = null,
    head: ?Ref = null,
    base: ?Ref = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    merged_at: ?[]const u8 = null,
    merged_by: ?User = null,
    html_url: ?[]const u8 = null,
    body: ?[]const u8 = null,
    labels: ?[]const RawLabel = null,
    requested_reviewers: ?[]const User = null,
    // Only when a single pull request is asked for.
    additions: ?u32 = null,
    deletions: ?u32 = null,
    comments: ?u32 = null,
    review_comments: ?u32 = null,
    commits: ?u32 = null,
    mergeable: ?bool = null,
};

fn toPull(a: std.mem.Allocator, p: Pull) !pr.PullRequest {
    var labels: std.ArrayList(pr.Label) = .empty;
    for (p.labels orelse &.{}) |l| try labels.append(a, .{ .name = wire.text(l.name), .color = pr.parseColor(wire.text(l.color)) });
    var requested: std.ArrayList([]const u8) = .empty;
    for (p.requested_reviewers orelse &.{}) |u| try requested.append(a, wire.text(u.login));
    const merged = p.merged_at != null;
    return .{
        .number = p.number,
        .title = wire.text(p.title),
        .author = if (p.user) |u| wire.text(u.login) else "",
        .state = if (merged) .merged else if (std.mem.eql(u8, wire.text(p.state), "open")) .open else .closed,
        .draft = p.draft orelse false,
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
        .mergeable = p.mergeable,
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

/// In this order: the pull request, its reviews, its head's check runs,
/// its head's statuses, its review comments.
pub fn detailCalls(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) ![]Call {
    const calls = try a.alloc(Call, 5);
    calls[0] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}", .{ r.api, r.path, p.number }) };
    calls[1] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/reviews?per_page=100", .{ r.api, r.path, p.number }) };
    calls[2] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/commits/{s}/check-runs?per_page=100", .{ r.api, r.path, p.head_sha }) };
    calls[3] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/commits/{s}/status", .{ r.api, r.path, p.head_sha }) };
    calls[4] = .{ .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/comments?per_page=100", .{ r.api, r.path, p.number }) };
    return calls;
}

const Review = struct { user: ?User = null, state: ?[]const u8 = null };
const CheckRun = struct {
    name: ?[]const u8 = null,
    status: ?[]const u8 = null,
    conclusion: ?[]const u8 = null,
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
};
const CheckRuns = struct { check_runs: ?[]const CheckRun = null };
const Status = struct { context: ?[]const u8 = null, state: ?[]const u8 = null };
const Combined = struct { statuses: ?[]const Status = null };
const ReviewComment = struct {
    id: u64 = 0,
    in_reply_to_id: ?u64 = null,
    path: ?[]const u8 = null,
    line: ?u32 = null,
    original_line: ?u32 = null,
    side: ?[]const u8 = null,
    user: ?User = null,
    body: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
};

/// `bodies` are the answers to `detailCalls`, in its order; one that
/// failed is null and what it would have said is left out.
pub fn parseDetail(a: std.mem.Allocator, p: pr.PullRequest, bodies: []const ?[]const u8) !pr.Detail {
    var out: pr.Detail = .{};
    if (bodies.len > 0) if (bodies[0]) |body| {
        const full = try wire.decode(Pull, a, body);
        out.body = wire.text(full.body);
        out.additions = full.additions;
        out.deletions = full.deletions;
        out.commits = full.commits;
        out.mergeable = full.mergeable;
        if (full.comments) |c| out.comments = c + (full.review_comments orelse 0);
    };

    // The last word of each reviewer counts; who was asked and has not answered waits.
    var reviewers: std.ArrayList(pr.Reviewer) = .empty;
    if (bodies.len > 1) if (bodies[1]) |body| {
        for (try wire.decode([]const Review, a, body)) |rv| {
            const name = if (rv.user) |u| wire.text(u.login) else "";
            const state_text = wire.text(rv.state);
            const state: pr.ReviewState = if (std.mem.eql(u8, state_text, "APPROVED"))
                .approved
            else if (std.mem.eql(u8, state_text, "CHANGES_REQUESTED"))
                .changes_requested
            else if (std.mem.eql(u8, state_text, "COMMENTED"))
                .commented
            else
                continue;
            if (name.len == 0) continue;
            var found = false;
            for (reviewers.items) |*have| {
                if (!std.mem.eql(u8, have.name, name)) continue;
                // A comment after an approval does not take the approval back.
                if (state != .commented) have.state = state;
                found = true;
            }
            if (!found) try reviewers.append(a, .{ .name = name, .state = state });
        }
    };
    for (p.requested) |name| {
        var found = false;
        for (reviewers.items) |*have| {
            if (std.mem.eql(u8, have.name, name)) {
                have.state = .pending;
                found = true;
            }
        }
        // The name is the list's, which may go before this detail does.
        if (!found) try reviewers.append(a, .{ .name = try a.dupe(u8, name), .state = .pending });
    }
    out.reviewers = reviewers.items;

    var checks: std.ArrayList(pr.Check) = .empty;
    if (bodies.len > 2) if (bodies[2]) |body| {
        const runs = try wire.decode(CheckRuns, a, body);
        for (runs.check_runs orelse &.{}) |c| {
            const conclusion = wire.text(c.conclusion);
            const state: pr.CheckState = if (!std.mem.eql(u8, wire.text(c.status), "completed"))
                .pending
            else if (std.mem.eql(u8, conclusion, "success"))
                .passed
            else if (std.mem.eql(u8, conclusion, "skipped") or std.mem.eql(u8, conclusion, "neutral"))
                .skipped
            else
                .failed;
            try checks.append(a, .{ .name = wire.text(c.name), .state = state, .seconds = wire.elapsed(c.started_at, c.completed_at) });
        }
    };
    if (bodies.len > 3) if (bodies[3]) |body| {
        const combined = try wire.decode(Combined, a, body);
        for (combined.statuses orelse &.{}) |s| {
            const state_text = wire.text(s.state);
            const state: pr.CheckState = if (std.mem.eql(u8, state_text, "success")) .passed else if (std.mem.eql(u8, state_text, "pending")) .pending else .failed;
            try checks.append(a, .{ .name = wire.text(s.context), .state = state });
        }
    };
    out.checks = checks.items;

    if (bodies.len > 4) if (bodies[4]) |body| {
        out.threads = try threads(a, try wire.decode([]const ReviewComment, a, body));
    };
    return out;
}

/// Review comments come flat, each reply naming the comment that started
/// its thread: grouped here, in the order the threads began.
fn threads(a: std.mem.Allocator, comments: []const ReviewComment) ![]pr.Thread {
    const Building = struct { root: u64, path: []const u8, line: u32, old_line: u32, comments: std.ArrayList(pr.Comment) };
    var list: std.ArrayList(Building) = .empty;
    for (comments) |c| {
        const root = c.in_reply_to_id orelse c.id;
        const comment: pr.Comment = .{
            .id = try wire.number(a, c.id),
            .author = if (c.user) |u| wire.text(u.login) else "",
            .created = pr.parseTime(wire.text(c.created_at)),
            .body = wire.text(c.body),
        };
        var placed = false;
        for (list.items) |*t| {
            if (t.root != root) continue;
            try t.comments.append(a, comment);
            placed = true;
        }
        if (placed) continue;
        const left = std.mem.eql(u8, wire.text(c.side), "LEFT");
        const line = c.line orelse c.original_line orelse 0;
        var fresh: Building = .{ .root = root, .path = wire.text(c.path), .line = if (left) 0 else line, .old_line = if (left) line else 0, .comments = .empty };
        try fresh.comments.append(a, comment);
        try list.append(a, fresh);
    }
    const out = try a.alloc(pr.Thread, list.items.len);
    for (list.items, 0..) |t, i| out[i] = .{ .id = try wire.number(a, t.root), .path = t.path, .line = t.line, .old_line = t.old_line, .comments = t.comments.items };
    return out;
}

pub fn mergeCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, method: pr.MergeMethod) !Call {
    const how = switch (method) {
        .squash => "squash",
        .rebase => "rebase",
        .merge, .fast_forward => "merge",
    };
    return .{
        .method = "PUT",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/merge", .{ r.api, r.path, p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"merge_method\":\"{s}\",\"sha\":{s}}}", .{ how, try wire.quote(a, p.head_sha) }),
    };
}

pub fn replyCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, thread_id: []const u8, body: []const u8) !Call {
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/comments/{s}/replies", .{ r.api, r.path, p.number, thread_id }),
        .body = try std.fmt.allocPrint(a, "{{\"body\":{s}}}", .{try wire.quote(a, body)}),
    };
}

pub fn resolveCall(_: std.mem.Allocator, _: *const Remote, _: pr.PullRequest, _: []const u8) !?Call {
    return null;
}

pub fn updateCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) !?Call {
    return .{
        .method = "PUT",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls/{d}/update-branch", .{ r.api, r.path, p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"expected_head_sha\":{s}}}", .{try wire.quote(a, p.head_sha)}),
    };
}

pub fn createCall(a: std.mem.Allocator, r: *const Remote, d: wire.Draft) !Call {
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/repos/{s}/pulls", .{ r.api, r.path }),
        .body = try std.fmt.allocPrint(a, "{{\"title\":{s},\"body\":{s},\"head\":{s},\"base\":{s},\"draft\":{s}}}", .{ try wire.quote(a, d.title), try wire.quote(a, d.body), try wire.quote(a, d.head), try wire.quote(a, d.base), if (d.draft) "true" else "false" }),
    };
}

/// The local ref a fetch of the pull request's head goes through.
pub fn headRef(a: std.mem.Allocator, p: pr.PullRequest) ![]const u8 {
    return std.fmt.allocPrint(a, "refs/pull/{d}/head", .{p.number});
}

// ── tests ───────────────────────────────────────────────────────────────
const remote: Remote = .{ .kind = .github, .api = "https://api.github.com", .path = "acme/orchard-api", .token = "t0ken" };

test "github: where the API is, and what a request carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://api.github.com", try apiBase(a, .{ .host = "github.com", .path = "a/b" }));
    try std.testing.expectEqualStrings("https://git.acme.example/api/v3", try apiBase(a, .{ .host = "git.acme.example", .path = "a/b" }));
    const h = try headers(a, &remote);
    try std.testing.expectEqualStrings("Bearer t0ken", h[2].value);
    const anon: Remote = .{ .kind = .github, .api = remote.api, .path = remote.path };
    try std.testing.expectEqual(@as(usize, 2), (try headers(a, &anon)).len);
    try std.testing.expectEqualStrings("https://api.github.com/repos/acme/orchard-api/pulls?state=closed&sort=updated&direction=desc&per_page=30", (try listCall(a, &remote, .merged)).url);
}

test "github: a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = @embedFile("../fixtures/github_pulls.json");
    const open = try parseList(a, body, .open);
    try std.testing.expectEqual(@as(usize, 2), open.len);
    try std.testing.expectEqual(@as(u64, 142), open[0].number);
    try std.testing.expectEqualStrings("feat(webhooks): delivery with retries and HMAC signing", open[0].title);
    try std.testing.expectEqualStrings("mlado", open[0].author);
    try std.testing.expectEqualStrings("feat/webhooks", open[0].head);
    try std.testing.expectEqualStrings("main", open[0].base);
    try std.testing.expectEqualStrings("6f6fc36000000000000000000000000000000000", open[0].head_sha);
    try std.testing.expectEqual(@as(i64, 1795286520), open[0].updated);
    try std.testing.expectEqual(@as(usize, 2), open[0].labels.len);
    try std.testing.expectEqual(@as(?u24, 0x5bd0c0), open[0].labels[0].color);
    try std.testing.expectEqualStrings("speon", open[0].requested[0]);
    try std.testing.expect(open[0].additions == null and open[0].comments == null);
    try std.testing.expect(open[1].draft);
    // The same answer to "closed" holds the merged one and the one closed unmerged.
    const merged = try parseList(a, body, .merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqual(@as(u64, 134), merged[0].number);
    const closed = try parseList(a, body, .closed);
    try std.testing.expectEqual(@as(u64, 130), closed[0].number);
}

test "github: a pull request looked at closely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseList(a, @embedFile("../fixtures/github_pulls.json"), .open);
    const calls = try detailCalls(a, &remote, list[0]);
    try std.testing.expectEqualStrings("https://api.github.com/repos/acme/orchard-api/commits/6f6fc36000000000000000000000000000000000/check-runs?per_page=100", calls[2].url);
    const d = try parseDetail(a, list[0], &.{
        @embedFile("../fixtures/github_pull.json"),
        @embedFile("../fixtures/github_reviews.json"),
        @embedFile("../fixtures/github_checks.json"),
        @embedFile("../fixtures/github_status.json"),
        @embedFile("../fixtures/github_comments.json"),
    });
    try std.testing.expectEqual(@as(?u32, 640), d.additions);
    try std.testing.expectEqual(@as(?u32, 8), d.comments);
    try std.testing.expectEqual(@as(?bool, true), d.mergeable);
    // arivas approved, then commented: still approved. speon was asked and waits.
    const r = d.reviewSummary();
    try std.testing.expectEqual(@as(u32, 2), r.approvals);
    try std.testing.expectEqual(@as(u32, 1), r.waiting);
    const c = d.checkSummary();
    try std.testing.expectEqual(@as(u32, 4), c.total);
    try std.testing.expectEqual(@as(u32, 3), c.passed);
    try std.testing.expectEqual(@as(u32, 1), c.pending);
    try std.testing.expectEqual(@as(?u32, 134), d.checks[0].seconds);
    try std.testing.expectEqual(@as(usize, 1), d.threads.len);
    try std.testing.expectEqualStrings("src/webhooks/sign.js", d.threads[0].path);
    try std.testing.expectEqual(@as(u32, 10), d.threads[0].line);
    try std.testing.expectEqual(@as(usize, 2), d.threads[0].comments.len);
    try std.testing.expectEqualStrings("9001", d.threads[0].id);
    try std.testing.expect(d.threads[0].resolved == null);
    // A call that failed leaves its part out and nothing else.
    const partial = try parseDetail(a, list[0], &.{ null, null, null, null, null });
    try std.testing.expectEqual(@as(usize, 1), partial.reviewers.len);
}

test "github: what the actions send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: pr.PullRequest = .{ .number = 142, .title = "", .author = "", .head_sha = "abc" };
    const m = try mergeCall(a, &remote, p, .squash);
    try std.testing.expectEqualStrings("PUT", m.method);
    try std.testing.expectEqualStrings("{\"merge_method\":\"squash\",\"sha\":\"abc\"}", m.body);
    const reply = try replyCall(a, &remote, p, "9001", "Good \"catch\"");
    try std.testing.expectEqualStrings("https://api.github.com/repos/acme/orchard-api/pulls/142/comments/9001/replies", reply.url);
    try std.testing.expectEqualStrings("{\"body\":\"Good \\\"catch\\\"\"}", reply.body);
    try std.testing.expect((try resolveCall(a, &remote, p, "9001")) == null);
    try std.testing.expectEqualStrings("https://api.github.com/repos/acme/orchard-api/pulls/142/update-branch", (try updateCall(a, &remote, p)).?.url);
    const made = try createCall(a, &remote, .{ .title = "T", .head = "feat/x", .base = "main", .draft = true });
    try std.testing.expectEqualStrings("{\"title\":\"T\",\"body\":\"\",\"head\":\"feat/x\",\"base\":\"main\",\"draft\":true}", made.body);
}

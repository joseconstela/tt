//! GitLab (gitlab.com and self-hosted, at `<host>/api/v4`): its REST API
//! as calls to send and answers decoded. Nothing here sends. GitLab calls
//! a pull request a merge request and numbers it per project (`iid`).
//!
//! One merge request looked at closely is three calls: the merge request
//! itself (its description, its head pipeline, the two ends of its diff),
//! its approvals, and its discussions, which are already threads. The
//! pipeline shows as one check: its jobs would be a call more per
//! pipeline. GitLab counts changed files, not lines: `additions` and
//! `deletions` stay empty and come from git once the head is fetched.
const std = @import("std");
const wire = @import("wire.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");

const Remote = wire.Remote;
const Call = wire.Call;

pub const capabilities: pr.Capabilities = .{
    .labels = true,
    .resolve = true,
    .update = .rebase,
    .merge_methods = &.{ .merge, .squash },
    .noun = "merge request",
};

pub fn apiBase(a: std.mem.Allocator, r: url.Remote) ![]u8 {
    const scheme = if (r.secure) "https" else "http";
    if (r.port) |p| return std.fmt.allocPrint(a, "{s}://{s}:{d}/api/v4", .{ scheme, r.host, p });
    return std.fmt.allocPrint(a, "{s}://{s}/api/v4", .{ scheme, r.host });
}

pub fn headers(a: std.mem.Allocator, r: *const Remote) ![]wire.Header {
    var out: std.ArrayList(wire.Header) = .empty;
    try out.append(a, .{ .name = "Accept", .value = "application/json" });
    if (r.token.len > 0) try out.append(a, .{ .name = "PRIVATE-TOKEN", .value = r.token });
    return out.items;
}

/// `<api>/projects/<the path, as one segment>`.
fn project(a: std.mem.Allocator, r: *const Remote) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/projects/{s}", .{ r.api, try wire.encode(a, r.path) });
}

pub fn userCall(a: std.mem.Allocator, r: *const Remote) !Call {
    return .{ .url = try std.fmt.allocPrint(a, "{s}/user", .{r.api}) };
}

pub fn parseUser(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const u = try wire.decode(User, a, body);
    return wire.text(u.username);
}

pub fn listCall(a: std.mem.Allocator, r: *const Remote, filter: pr.Filter) !Call {
    const state = switch (filter) {
        .open => "opened",
        .merged => "merged",
        .closed => "closed",
    };
    return .{ .url = try std.fmt.allocPrint(a, "{s}/merge_requests?state={s}&order_by=updated_at&sort=desc&per_page=30&with_labels_details=true", .{ try project(a, r), state }) };
}

const User = struct { username: ?[]const u8 = null, name: ?[]const u8 = null };
const RawLabel = struct { name: ?[]const u8 = null, color: ?[]const u8 = null };
const Pipeline = struct { status: ?[]const u8 = null, duration: ?f64 = null };
const DiffRefs = struct { base_sha: ?[]const u8 = null, head_sha: ?[]const u8 = null };
const MergeRequest = struct {
    iid: u64 = 0,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,
    draft: ?bool = null,
    work_in_progress: ?bool = null,
    author: ?User = null,
    source_branch: ?[]const u8 = null,
    target_branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    merged_by: ?User = null,
    merge_user: ?User = null,
    web_url: ?[]const u8 = null,
    user_notes_count: ?u32 = null,
    labels: ?[]const RawLabel = null,
    reviewers: ?[]const User = null,
    has_conflicts: ?bool = null,
    // Only when a single merge request is asked for.
    head_pipeline: ?Pipeline = null,
    diff_refs: ?DiffRefs = null,
};

fn who(u: ?User) []const u8 {
    const user = u orelse return "";
    return user.username orelse user.name orelse "";
}

fn toPull(a: std.mem.Allocator, m: MergeRequest) !pr.PullRequest {
    var labels: std.ArrayList(pr.Label) = .empty;
    for (m.labels orelse &.{}) |l| try labels.append(a, .{ .name = wire.text(l.name), .color = pr.parseColor(wire.text(l.color)) });
    var requested: std.ArrayList([]const u8) = .empty;
    for (m.reviewers orelse &.{}) |u| try requested.append(a, who(u));
    const state_text = wire.text(m.state);
    return .{
        .number = m.iid,
        .title = wire.text(m.title),
        .author = who(m.author),
        .state = if (std.mem.eql(u8, state_text, "merged")) .merged else if (std.mem.eql(u8, state_text, "opened")) .open else .closed,
        .draft = m.draft orelse m.work_in_progress orelse false,
        .head = wire.text(m.source_branch),
        .base = wire.text(m.target_branch),
        .head_sha = if (m.diff_refs) |d| wire.text(d.head_sha orelse m.sha) else wire.text(m.sha),
        .base_sha = if (m.diff_refs) |d| wire.text(d.base_sha) else "",
        .created = pr.parseTime(wire.text(m.created_at)),
        .updated = pr.parseTime(wire.text(m.updated_at)),
        .merged_by = who(m.merge_user orelse m.merged_by),
        .url = wire.text(m.web_url),
        .comments = m.user_notes_count,
        .labels = labels.items,
        .requested = requested.items,
        .mergeable = if (m.has_conflicts) |c| !c else null,
    };
}

pub fn parseList(a: std.mem.Allocator, body: []const u8, _: pr.Filter) ![]pr.PullRequest {
    const raw = try wire.decode([]const MergeRequest, a, body);
    const out = try a.alloc(pr.PullRequest, raw.len);
    for (raw, 0..) |m, i| out[i] = try toPull(a, m);
    return out;
}

/// In this order: the merge request, its approvals, its discussions.
pub fn detailCalls(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) ![]Call {
    const base = try std.fmt.allocPrint(a, "{s}/merge_requests/{d}", .{ try project(a, r), p.number });
    const calls = try a.alloc(Call, 3);
    calls[0] = .{ .url = base };
    calls[1] = .{ .url = try std.fmt.allocPrint(a, "{s}/approvals", .{base}) };
    calls[2] = .{ .url = try std.fmt.allocPrint(a, "{s}/discussions?per_page=100", .{base}) };
    return calls;
}

const Approver = struct { user: ?User = null };
const Approvals = struct { approvals_left: ?u32 = null, approved_by: ?[]const Approver = null };
const Position = struct { new_path: ?[]const u8 = null, old_path: ?[]const u8 = null, new_line: ?u32 = null, old_line: ?u32 = null };
const Note = struct {
    id: u64 = 0,
    body: ?[]const u8 = null,
    author: ?User = null,
    created_at: ?[]const u8 = null,
    system: ?bool = null,
    resolvable: ?bool = null,
    resolved: ?bool = null,
    position: ?Position = null,
};
const Discussion = struct { id: ?[]const u8 = null, notes: ?[]const Note = null };

/// `bodies` are the answers to `detailCalls`, in its order; one that
/// failed is null and what it would have said is left out.
pub fn parseDetail(a: std.mem.Allocator, p: pr.PullRequest, bodies: []const ?[]const u8) !pr.Detail {
    var out: pr.Detail = .{};
    var checks: std.ArrayList(pr.Check) = .empty;
    if (bodies.len > 0) if (bodies[0]) |body| {
        const m = try wire.decode(MergeRequest, a, body);
        out.body = wire.text(m.description);
        out.comments = m.user_notes_count;
        if (m.has_conflicts) |c| out.mergeable = !c;
        if (m.head_pipeline) |pipe| {
            const s = wire.text(pipe.status);
            const state: pr.CheckState = if (std.mem.eql(u8, s, "success"))
                .passed
            else if (std.mem.eql(u8, s, "failed") or std.mem.eql(u8, s, "canceled"))
                .failed
            else if (std.mem.eql(u8, s, "skipped"))
                .skipped
            else
                .pending;
            try checks.append(a, .{ .name = "pipeline", .state = state, .seconds = if (pipe.duration) |d| @intFromFloat(@max(0, d)) else null });
        }
    };
    out.checks = checks.items;

    var reviewers: std.ArrayList(pr.Reviewer) = .empty;
    if (bodies.len > 1) if (bodies[1]) |body| {
        const ap = try wire.decode(Approvals, a, body);
        out.approvals_left = ap.approvals_left;
        for (ap.approved_by orelse &.{}) |by| {
            const name = who(by.user);
            if (name.len > 0) try reviewers.append(a, .{ .name = name, .state = .approved });
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
        var threads: std.ArrayList(pr.Thread) = .empty;
        for (try wire.decode([]const Discussion, a, body)) |d| {
            const notes = d.notes orelse continue;
            // Only discussions on a line of the diff are threads here.
            if (notes.len == 0) continue;
            const pos = notes[0].position orelse continue;
            var comments: std.ArrayList(pr.Comment) = .empty;
            for (notes) |n| {
                if (n.system orelse false) continue;
                try comments.append(a, .{ .id = try wire.number(a, n.id), .author = who(n.author), .created = pr.parseTime(wire.text(n.created_at)), .body = wire.text(n.body) });
            }
            if (comments.items.len == 0) continue;
            try threads.append(a, .{
                .id = wire.text(d.id),
                .path = wire.text(pos.new_path orelse pos.old_path),
                .line = pos.new_line orelse 0,
                .old_line = if (pos.new_line == null) pos.old_line orelse 0 else 0,
                .resolved = if (notes[0].resolvable orelse false) notes[0].resolved orelse false else null,
                .comments = comments.items,
            });
        }
        out.threads = threads.items;
    };
    return out;
}

pub fn mergeCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, method: pr.MergeMethod) !Call {
    return .{
        .method = "PUT",
        .url = try std.fmt.allocPrint(a, "{s}/merge_requests/{d}/merge", .{ try project(a, r), p.number }),
        .body = try std.fmt.allocPrint(a, "{{\"squash\":{s},\"sha\":{s}}}", .{ if (method == .squash) "true" else "false", try wire.quote(a, p.head_sha) }),
    };
}

pub fn replyCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, thread_id: []const u8, body: []const u8) !Call {
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/merge_requests/{d}/discussions/{s}/notes", .{ try project(a, r), p.number, thread_id }),
        .body = try std.fmt.allocPrint(a, "{{\"body\":{s}}}", .{try wire.quote(a, body)}),
    };
}

pub fn resolveCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest, thread_id: []const u8) !?Call {
    return .{
        .method = "PUT",
        .url = try std.fmt.allocPrint(a, "{s}/merge_requests/{d}/discussions/{s}?resolved=true", .{ try project(a, r), p.number, thread_id }),
    };
}

pub fn updateCall(a: std.mem.Allocator, r: *const Remote, p: pr.PullRequest) !?Call {
    return .{ .method = "PUT", .url = try std.fmt.allocPrint(a, "{s}/merge_requests/{d}/rebase", .{ try project(a, r), p.number }) };
}

/// A draft is a merge request whose title says so.
pub fn createCall(a: std.mem.Allocator, r: *const Remote, d: wire.Draft) !Call {
    const title = if (d.draft) try std.fmt.allocPrint(a, "Draft: {s}", .{d.title}) else d.title;
    return .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/merge_requests", .{try project(a, r)}),
        .body = try std.fmt.allocPrint(a, "{{\"title\":{s},\"description\":{s},\"source_branch\":{s},\"target_branch\":{s}}}", .{ try wire.quote(a, title), try wire.quote(a, d.body), try wire.quote(a, d.head), try wire.quote(a, d.base) }),
    };
}

pub fn headRef(a: std.mem.Allocator, p: pr.PullRequest) ![]const u8 {
    return std.fmt.allocPrint(a, "refs/merge-requests/{d}/head", .{p.number});
}

// ── tests ───────────────────────────────────────────────────────────────
const remote: Remote = .{ .kind = .gitlab, .api = "https://gitlab.example.com/api/v4", .path = "acme/platform/orchard-api", .token = "t0ken" };

test "gitlab: where the API is, and what a request carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://gitlab.com/api/v4", try apiBase(a, .{ .host = "gitlab.com", .path = "a/b" }));
    try std.testing.expectEqualStrings("http://git.lan:8080/api/v4", try apiBase(a, .{ .host = "git.lan", .path = "a/b", .port = 8080, .secure = false }));
    const h = try headers(a, &remote);
    try std.testing.expectEqualStrings("PRIVATE-TOKEN", h[1].name);
    // A nested group goes in as one segment.
    try std.testing.expectEqualStrings("https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Forchard-api/merge_requests?state=opened&order_by=updated_at&sort=desc&per_page=30&with_labels_details=true", (try listCall(a, &remote, .open)).url);
}

test "gitlab: a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseList(a, @embedFile("../fixtures/gitlab_merge_requests.json"), .open);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u64, 142), list[0].number);
    try std.testing.expectEqualStrings("mlado", list[0].author);
    try std.testing.expectEqualStrings("feat/webhooks", list[0].head);
    try std.testing.expectEqual(pr.State.open, list[0].state);
    try std.testing.expectEqual(@as(?u32, 8), list[0].comments);
    try std.testing.expectEqual(@as(?u24, 0x5bd0c0), list[0].labels[0].color);
    try std.testing.expectEqual(@as(?bool, true), list[0].mergeable);
    try std.testing.expectEqual(@as(i64, 1795286520), list[0].updated);
    try std.testing.expect(list[0].additions == null);
    try std.testing.expect(list[1].draft);
    try std.testing.expectEqual(@as(?bool, false), list[1].mergeable);
}

test "gitlab: a merge request looked at closely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseList(a, @embedFile("../fixtures/gitlab_merge_requests.json"), .open);
    const calls = try detailCalls(a, &remote, list[0]);
    try std.testing.expectEqualStrings("https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Forchard-api/merge_requests/142/approvals", calls[1].url);
    const d = try parseDetail(a, list[0], &.{
        @embedFile("../fixtures/gitlab_merge_request.json"),
        @embedFile("../fixtures/gitlab_approvals.json"),
        @embedFile("../fixtures/gitlab_discussions.json"),
    });
    try std.testing.expectEqualStrings("Queue with exponential retries.", d.body);
    try std.testing.expectEqual(@as(?u32, 1), d.approvals_left);
    try std.testing.expectEqual(@as(usize, 1), d.checks.len);
    try std.testing.expectEqual(pr.CheckState.passed, d.checks[0].state);
    try std.testing.expectEqual(@as(?u32, 412), d.checks[0].seconds);
    // arivas approved; speon was asked to review and has not.
    const r = d.reviewSummary();
    try std.testing.expectEqual(@as(u32, 1), r.approvals);
    try std.testing.expectEqual(@as(u32, 1), r.waiting);
    // The system note and the comment that is not on a line are not threads.
    try std.testing.expectEqual(@as(usize, 1), d.threads.len);
    try std.testing.expectEqualStrings("6a9c1d8f", d.threads[0].id);
    try std.testing.expectEqualStrings("src/webhooks/sign.js", d.threads[0].path);
    try std.testing.expectEqual(@as(u32, 10), d.threads[0].line);
    try std.testing.expectEqual(@as(?bool, false), d.threads[0].resolved);
    try std.testing.expectEqual(@as(usize, 2), d.threads[0].comments.len);
}

test "gitlab: what the actions send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: pr.PullRequest = .{ .number = 142, .title = "", .author = "", .head_sha = "abc" };
    try std.testing.expectEqualStrings("{\"squash\":true,\"sha\":\"abc\"}", (try mergeCall(a, &remote, p, .squash)).body);
    try std.testing.expectEqualStrings("https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Forchard-api/merge_requests/142/discussions/6a9c1d8f?resolved=true", (try resolveCall(a, &remote, p, "6a9c1d8f")).?.url);
    try std.testing.expectEqualStrings("https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Forchard-api/merge_requests/142/rebase", (try updateCall(a, &remote, p)).?.url);
    const made = try createCall(a, &remote, .{ .title = "T", .head = "feat/x", .base = "main", .draft = true });
    try std.testing.expectEqualStrings("{\"title\":\"Draft: T\",\"description\":\"\",\"source_branch\":\"feat/x\",\"target_branch\":\"main\"}", made.body);
}

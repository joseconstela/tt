//! Pull requests as data, the same whichever host they come from. GitHub,
//! GitLab ("merge requests"), Bitbucket and Gitea each answer in their own
//! JSON; the backends in `client/` decode it into what is here, and the
//! views draw only this.
//!
//! A `PullRequest` is what a host's list gives for one row. A `Detail` is
//! what looking at one closely adds: its description, who reviewed it and
//! how, the checks of its head commit, the comment threads on its lines.
//! A value a host does not give is null (or empty), never a guess: the
//! views leave that part out. `Capabilities` says what a host can do at
//! all, so a control it has no answer for is not shown.
//!
//! Every slice belongs to the arena of the page or detail it came in.
const std = @import("std");

pub const Kind = enum {
    github,
    gitlab,
    bitbucket,
    gitea,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .github => "GitHub",
            .gitlab => "GitLab",
            .bitbucket => "Bitbucket",
            .gitea => "Gitea",
        };
    }
};

pub const State = enum { open, merged, closed };

/// Which pull requests a list asks for.
pub const Filter = enum { open, merged, closed };

pub const ReviewState = enum { pending, approved, changes_requested, commented };

pub const Reviewer = struct { name: []const u8, state: ReviewState };

pub const CheckState = enum { pending, passed, failed, skipped };

pub const Check = struct {
    name: []const u8,
    state: CheckState,
    /// How long it ran, when the host says.
    seconds: ?u32 = null,
};

pub const Label = struct {
    name: []const u8,
    /// The label's own colour, when the host gives one.
    color: ?u24 = null,
};

pub const Comment = struct {
    /// The host's id, as text: what a reply is addressed to.
    id: []const u8,
    author: []const u8,
    created: i64,
    body: []const u8,
};

/// Comments on one line of a file, the first one and its replies.
pub const Thread = struct {
    /// What resolving it, or replying to it, is addressed to.
    id: []const u8,
    path: []const u8,
    /// The line on the new side; 0 when the comment is on a removed line
    /// (`old_line` then) or on the file as a whole.
    line: u32 = 0,
    old_line: u32 = 0,
    /// Null when the host has no notion of a resolved thread.
    resolved: ?bool = null,
    comments: []const Comment,
};

pub const PullRequest = struct {
    number: u64,
    title: []const u8,
    author: []const u8,
    state: State = .open,
    draft: bool = false,
    /// The branch it comes from, and the one it goes into.
    head: []const u8 = "",
    base: []const u8 = "",
    head_sha: []const u8 = "",
    base_sha: []const u8 = "",
    /// Seconds since the epoch; 0 when not given.
    created: i64 = 0,
    updated: i64 = 0,
    merged_by: []const u8 = "",
    /// Its page on the host.
    url: []const u8 = "",
    comments: ?u32 = null,
    additions: ?u32 = null,
    deletions: ?u32 = null,
    labels: []const Label = &.{},
    /// Who was asked to review and has not yet.
    requested: []const []const u8 = &.{},
    /// Whether it merges without conflicts, when the host says.
    mergeable: ?bool = null,
};

pub const Checks = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    pending: u32 = 0,
};

pub const ReviewSummary = struct {
    approvals: u32 = 0,
    changes_requested: u32 = 0,
    /// Reviewers asked who have not answered.
    waiting: u32 = 0,
};

pub const Detail = struct {
    body: []const u8 = "",
    additions: ?u32 = null,
    deletions: ?u32 = null,
    comments: ?u32 = null,
    commits: ?u32 = null,
    mergeable: ?bool = null,
    /// How many approvals the host still wants before a merge, when it says.
    approvals_left: ?u32 = null,
    reviewers: []const Reviewer = &.{},
    checks: []const Check = &.{},
    threads: []const Thread = &.{},

    pub fn checkSummary(self: *const Detail) Checks {
        var out: Checks = .{};
        for (self.checks) |c| {
            if (c.state == .skipped) continue;
            out.total += 1;
            switch (c.state) {
                .passed => out.passed += 1,
                .failed => out.failed += 1,
                .pending => out.pending += 1,
                .skipped => {},
            }
        }
        return out;
    }

    pub fn reviewSummary(self: *const Detail) ReviewSummary {
        var out: ReviewSummary = .{};
        for (self.reviewers) |r| switch (r.state) {
            .approved => out.approvals += 1,
            .changes_requested => out.changes_requested += 1,
            .pending => out.waiting += 1,
            .commented => {},
        };
        return out;
    }
};

pub const MergeMethod = enum {
    merge,
    squash,
    rebase,
    fast_forward,

    pub fn label(self: MergeMethod) []const u8 {
        return switch (self) {
            .merge => "Merge commit",
            .squash => "Squash and merge",
            .rebase => "Rebase and merge",
            .fast_forward => "Fast-forward",
        };
    }
};

/// How a pull request's branch is brought up to date with its base.
pub const Update = enum { none, merge, rebase };

/// What a host can do; a control with nothing behind it is not shown.
pub const Capabilities = struct {
    labels: bool = true,
    /// Comment threads can be replied to, and marked resolved, through
    /// the API tt uses.
    reply: bool = true,
    resolve: bool = false,
    update: Update = .none,
    merge_methods: []const MergeMethod = &.{.merge},
    /// What the host calls one: "pull request" or "merge request".
    noun: []const u8 = "pull request",
};

/// An ISO 8601 time (`2026-11-21T18:42:00Z`, with fractions of a second
/// or a `+01:00` offset as some hosts write them) as seconds since the
/// epoch; 0 when it does not parse.
pub fn parseTime(text: []const u8) i64 {
    if (text.len < 19) return 0;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return 0;
    if (month < 1 or month > 12 or day < 1 or day > 31) return 0;

    // Days since 1970-01-01 (the civil-from-days arithmetic, backwards).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    var out = days * 86400 + hour * 3600 + minute * 60 + second;

    // An offset from UTC, after the seconds and any fraction.
    var i: usize = 19;
    while (i < text.len and (text[i] == '.' or std.ascii.isDigit(text[i]))) i += 1;
    if (i < text.len and (text[i] == '+' or text[i] == '-') and text.len >= i + 3) {
        const oh = std.fmt.parseInt(i64, text[i + 1 .. i + 3], 10) catch 0;
        const rest = std.mem.trimStart(u8, text[i + 3 ..], ":");
        const om = if (rest.len >= 2) std.fmt.parseInt(i64, rest[0..2], 10) catch 0 else 0;
        const offset = oh * 3600 + om * 60;
        out += if (text[i] == '+') -offset else offset;
    }
    return out;
}

/// A colour as hosts write it: `d73a4a`, `#d73a4a`, `#ABC`.
pub fn parseColor(text: []const u8) ?u24 {
    const hex = std.mem.trimStart(u8, std.mem.trim(u8, text, " "), "#");
    if (hex.len == 6) return std.fmt.parseInt(u24, hex, 16) catch null;
    if (hex.len == 3) {
        const v = std.fmt.parseInt(u24, hex, 16) catch return null;
        const r = (v >> 8) & 0xf;
        const g = (v >> 4) & 0xf;
        const b = v & 0xf;
        return (r * 17) << 16 | (g * 17) << 8 | (b * 17);
    }
    return null;
}

test "times as the hosts write them" {
    try std.testing.expectEqual(@as(i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 951782400), parseTime("2000-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1795286520), parseTime("2026-11-21T18:42:00Z"));
    // GitLab: fractions; Bitbucket: fractions and an offset; an offset east of UTC is earlier.
    try std.testing.expectEqual(@as(i64, 1795286520), parseTime("2026-11-21T18:42:00.123Z"));
    try std.testing.expectEqual(@as(i64, 1795286520), parseTime("2026-11-21T18:42:00.123456+00:00"));
    try std.testing.expectEqual(@as(i64, 1795286520), parseTime("2026-11-21T19:42:00+01:00"));
    try std.testing.expectEqual(@as(i64, 1795286520), parseTime("2026-11-21T13:12:00-05:30"));
    try std.testing.expectEqual(@as(i64, 0), parseTime("yesterday"));
    try std.testing.expectEqual(@as(i64, 0), parseTime(""));
}

test "label colours" {
    try std.testing.expectEqual(@as(?u24, 0xd73a4a), parseColor("d73a4a"));
    try std.testing.expectEqual(@as(?u24, 0xd73a4a), parseColor("#D73A4A"));
    try std.testing.expectEqual(@as(?u24, 0xaabbcc), parseColor("#abc"));
    try std.testing.expect(parseColor("red") == null);
}

test "summaries" {
    const d: Detail = .{
        .checks = &.{
            .{ .name = "build", .state = .passed },
            .{ .name = "lint", .state = .failed },
            .{ .name = "e2e", .state = .pending },
            .{ .name = "docs", .state = .skipped },
        },
        .reviewers = &.{
            .{ .name = "a", .state = .approved },
            .{ .name = "b", .state = .approved },
            .{ .name = "c", .state = .pending },
            .{ .name = "d", .state = .commented },
        },
    };
    const c = d.checkSummary();
    try std.testing.expectEqual(@as(u32, 3), c.total);
    try std.testing.expectEqual(@as(u32, 1), c.passed);
    try std.testing.expectEqual(@as(u32, 1), c.failed);
    const r = d.reviewSummary();
    try std.testing.expectEqual(@as(u32, 2), r.approvals);
    try std.testing.expectEqual(@as(u32, 1), r.waiting);
}

//! What the four hosting backends share: a repository on a host as a
//! request is addressed to it (`Remote`), a request before it is sent
//! (`Call`), and the small tools both sides of JSON need (decoding into a
//! typed struct, quoting a string, percent-encoding a path, Basic auth).
//!
//! A backend (`github.zig`, `gitlab.zig`, `bitbucket.zig`, `gitea.zig`)
//! is a set of functions that build calls and decode answers into
//! `model/pull_request.zig`; none of them sends anything. `forge.zig`
//! picks the backend for a remote's kind and does the sending.
const std = @import("std");
const hosts = @import("../hosts.zig");
const pr = @import("../model/pull_request.zig");

pub const Header = hosts.HttpHeader;

pub const Remote = struct {
    kind: pr.Kind,
    /// Where the host's API lives, without a trailing slash.
    api: []const u8,
    /// The repository as the API names it: `owner/repo`.
    path: []const u8,
    /// Who the token belongs to; Bitbucket's API tokens need it.
    user: []const u8 = "",
    token: []const u8 = "",
};

pub const Call = struct {
    method: []const u8 = "GET",
    url: []const u8,
    /// JSON, when not empty.
    body: []const u8 = "",
};

/// One page of a list, and where the next one is (null at the end).
pub const List = struct {
    pulls: []pr.PullRequest,
    next: ?[]const u8 = null,
};

/// A new pull request.
pub const Draft = struct {
    title: []const u8,
    body: []const u8 = "",
    head: []const u8,
    base: []const u8,
    draft: bool = false,
};

/// Decodes `body` into `T`, every string copied into `a` (the body goes
/// away with its request). Fields the type does not name are skipped.
pub fn decode(comptime T: type, a: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn text(v: ?[]const u8) []const u8 {
    return v orelse "";
}

/// `s` as a JSON string, quotes included.
pub fn quote(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => if (ch < 0x20) {
            var buf: [8]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable);
        } else try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.items;
}

/// `s` percent-encoded for one segment of a URL: a GitLab project path
/// (`group/sub/repo`) goes in as `group%2Fsub%2Frepo`.
pub fn encode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(a, ch);
        } else {
            var buf: [4]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable);
        }
    }
    return out.items;
}

/// The value of an `Authorization: Basic` header for a user and a secret.
pub fn basic(a: std.mem.Allocator, user: []const u8, secret: []const u8) ![]u8 {
    const pair = try std.fmt.allocPrint(a, "{s}:{s}", .{ user, secret });
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, "Basic ".len + enc.calcSize(pair.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], pair);
    return out;
}

/// Seconds between two ISO times, when both parse and the second is later.
pub fn elapsed(started: ?[]const u8, ended: ?[]const u8) ?u32 {
    const a = pr.parseTime(started orelse return null);
    const b = pr.parseTime(ended orelse return null);
    if (a == 0 or b < a) return null;
    return @intCast(@min(b - a, std.math.maxInt(u32)));
}

/// A number as text, in `a` (ids are kept as text: some hosts' are not numbers).
pub fn number(a: std.mem.Allocator, n: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

test "quoting, encoding and basic auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"a \\\"b\\\"\\n\\tc\\\\\\u0001\"", try quote(a, "a \"b\"\n\tc\\\x01"));
    try std.testing.expectEqualStrings("group%2Fsub%2Fmy%20repo", try encode(a, "group/sub/my repo"));
    try std.testing.expectEqualStrings("Basic dXNlcjpzZWNyZXQ=", try basic(a, "user", "secret"));
    try std.testing.expectEqual(@as(?u32, 134), elapsed("2026-11-21T18:40:00Z", "2026-11-21T18:42:14Z"));
    try std.testing.expect(elapsed(null, "2026-11-21T18:42:14Z") == null);
}

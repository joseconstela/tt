//! A git remote's address taken apart: which host it is on and which
//! repository there. The three spellings git accepts are read:
//!
//!   git@github.com:owner/repo.git             (scp-like)
//!   ssh://git@gitlab.example.com:2222/group/sub/repo.git
//!   https://user@codeberg.org/owner/repo
//!
//! `path` is the repository as the host's API names it (`owner/repo`, on
//! GitLab possibly `group/sub/repo`), without `.git`. A port is kept only
//! for http and https addresses: an SSH port says nothing about where the
//! host's API listens.
const std = @import("std");
const Kind = @import("pull_request.zig").Kind;

pub const Remote = struct {
    host: []const u8,
    path: []const u8,
    /// The web port, when the address is http(s) and names one.
    port: ?u16 = null,
    /// False only for an `http://` address.
    secure: bool = true,
};

pub fn parse(url_raw: []const u8) ?Remote {
    var url = std.mem.trim(u8, url_raw, " \t\r\n");
    if (url.len == 0) return null;
    var out: Remote = .{ .host = "", .path = "" };
    var web = false;

    if (std.mem.indexOf(u8, url, "://")) |at| {
        const scheme = url[0..at];
        url = url[at + 3 ..];
        if (std.ascii.eqlIgnoreCase(scheme, "http")) {
            out.secure = false;
            web = true;
        } else if (std.ascii.eqlIgnoreCase(scheme, "https")) {
            web = true;
        } else if (!std.ascii.eqlIgnoreCase(scheme, "ssh") and !std.ascii.eqlIgnoreCase(scheme, "git") and !std.ascii.eqlIgnoreCase(scheme, "git+ssh")) {
            return null;
        }
        const slash = std.mem.indexOfScalar(u8, url, '/') orelse return null;
        var authority = url[0..slash];
        out.path = url[slash + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |a| authority = authority[a + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
            if (web) out.port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch null;
            authority = authority[0..c];
        }
        out.host = authority;
    } else {
        // scp-like: [user@]host:path, and no slash before the colon
        // (that would be a local path).
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        var authority = url[0..colon];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |a| authority = authority[a + 1 ..];
        out.host = authority;
        out.path = url[colon + 1 ..];
    }

    out.path = std.mem.trim(u8, out.path, "/");
    if (std.mem.endsWith(u8, out.path, ".git")) out.path = out.path[0 .. out.path.len - 4];
    out.path = std.mem.trimEnd(u8, out.path, "/");
    if (out.host.len == 0 or std.mem.indexOfScalar(u8, out.path, '/') == null) return null;
    return out;
}

/// The hosts whose kind needs no telling.
pub fn knownKind(host: []const u8) ?Kind {
    const table = [_]struct { host: []const u8, kind: Kind }{
        .{ .host = "github.com", .kind = .github },
        .{ .host = "gitlab.com", .kind = .gitlab },
        .{ .host = "bitbucket.org", .kind = .bitbucket },
        .{ .host = "codeberg.org", .kind = .gitea },
        .{ .host = "gitea.com", .kind = .gitea },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(t.host, host)) return t.kind;
    return null;
}

/// The owner (everything before the repository's own name) and the name.
pub fn split(path: []const u8) struct { owner: []const u8, name: []const u8 } {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .owner = "", .name = path };
    return .{ .owner = path[0..slash], .name = path[slash + 1 ..] };
}

test "the spellings of a remote" {
    const a = parse("git@github.com:owner/repo.git").?;
    try std.testing.expectEqualStrings("github.com", a.host);
    try std.testing.expectEqualStrings("owner/repo", a.path);
    try std.testing.expect(a.port == null and a.secure);

    const b = parse("ssh://git@gitlab.example.com:2222/group/sub/repo.git").?;
    try std.testing.expectEqualStrings("gitlab.example.com", b.host);
    try std.testing.expectEqualStrings("group/sub/repo", b.path);
    try std.testing.expect(b.port == null);

    const c = parse("https://user:secret@codeberg.org/owner/repo/\n").?;
    try std.testing.expectEqualStrings("codeberg.org", c.host);
    try std.testing.expectEqualStrings("owner/repo", c.path);

    const d = parse("http://localhost:3000/me/thing.git").?;
    try std.testing.expectEqualStrings("localhost", d.host);
    try std.testing.expectEqual(@as(?u16, 3000), d.port);
    try std.testing.expect(!d.secure);

    try std.testing.expect(parse("/Users/me/repos/thing.git") == null);
    try std.testing.expect(parse("../thing") == null);
    try std.testing.expect(parse("file:///srv/git/thing.git") == null);
    try std.testing.expect(parse("git@github.com:justaname") == null);
    try std.testing.expect(parse("") == null);
}

test "known hosts, and the two halves of a path" {
    try std.testing.expectEqual(@as(?Kind, .github), knownKind("GitHub.com"));
    try std.testing.expectEqual(@as(?Kind, .gitea), knownKind("codeberg.org"));
    try std.testing.expect(knownKind("git.example.com") == null);
    const s = split("group/sub/repo");
    try std.testing.expectEqualStrings("group/sub", s.owner);
    try std.testing.expectEqualStrings("repo", s.name);
}

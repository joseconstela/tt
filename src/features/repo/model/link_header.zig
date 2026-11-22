//! The `Link` response header (RFC 8288), as GitHub, GitLab and Gitea
//! use it to say where the next page of a list is:
//!
//!   <https://api.example.com/pulls?page=2>; rel="next", <…page=9>; rel="last"
const std = @import("std");

/// The address of the link whose relation is `rel` ("next"), a slice of
/// `header`; null when there is none.
pub fn find(header: []const u8, rel: []const u8) ?[]const u8 {
    var rest = header;
    while (std.mem.indexOfScalar(u8, rest, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '>') orelse return null;
        const url = rest[open + 1 .. close];
        // The parameters run to the next link's "<" (a comma inside a URL
        // is between the brackets, so it does not end them early).
        const end = std.mem.indexOfScalarPos(u8, rest, close, '<') orelse rest.len;
        var params = std.mem.tokenizeAny(u8, rest[close + 1 .. end], ";,");
        while (params.next()) |param_raw| {
            const param = std.mem.trim(u8, param_raw, " \t");
            if (!std.ascii.startsWithIgnoreCase(param, "rel=")) continue;
            var rels = std.mem.tokenizeScalar(u8, std.mem.trim(u8, param[4..], "\""), ' ');
            while (rels.next()) |r| if (std.ascii.eqlIgnoreCase(r, rel)) return url;
        }
        rest = rest[end..];
    }
    return null;
}

test "next and last" {
    const h = "<https://api.github.com/repositories/1/pulls?state=open&page=2>; rel=\"next\", <https://api.github.com/repositories/1/pulls?state=open&page=50>; rel=\"last\"";
    try std.testing.expectEqualStrings("https://api.github.com/repositories/1/pulls?state=open&page=2", find(h, "next").?);
    try std.testing.expectEqualStrings("https://api.github.com/repositories/1/pulls?state=open&page=50", find(h, "last").?);
    try std.testing.expect(find(h, "prev") == null);
    // Gitea writes no space after the comma; a URL may hold one itself.
    const g = "<https://codeberg.org/api/v1/repos/a/b/pulls?labels=1,2&page=3>; rel=\"next\",<https://codeberg.org/api/v1/repos/a/b/pulls?page=9>; rel=\"last\"";
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/a/b/pulls?labels=1,2&page=3", find(g, "next").?);
    try std.testing.expect(find("", "next") == null);
    try std.testing.expect(find("<broken", "next") == null);
}

//! Pure path helpers for the files panel: a path's spelling relative to
//! the folder on show, whether one path lives under another, and what is
//! wrong with a name typed into the "New file" / "Rename" box.
const std = @import("std");

/// `path` relative to `base` ("" when they are the same folder), or
/// `path` itself when it does not live under `base`.
pub fn relativeTo(base: []const u8, path: []const u8) []const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    if (b.len == 0) return std.mem.trimStart(u8, path, "/");
    if (std.mem.eql(u8, path, b)) return "";
    if (path.len > b.len + 1 and std.mem.startsWith(u8, path, b) and path[b.len] == '/') return path[b.len + 1 ..];
    return path;
}

/// True when `path` is `dir` itself or lives somewhere below it.
pub fn isUnder(dir: []const u8, path: []const u8) bool {
    const d = std.mem.trimEnd(u8, dir, "/");
    if (d.len == 0) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, d)) return false;
    return path.len == d.len or path[d.len] == '/';
}

/// Why `name` will not do as a file or folder name, or null when it will.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "Type a name.";
    if (std.mem.indexOfScalar(u8, name, '/') != null) return "A name cannot contain “/”.";
    if (std.mem.indexOfScalar(u8, name, 0) != null) return "That name cannot be used.";
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return "That name is reserved.";
    if (name.len > 255) return "That name is too long.";
    return null;
}

/// `dir/name`, without a doubled slash under the root.
pub fn join(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const d = std.mem.trimEnd(u8, dir, "/");
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, name });
}

test "paths: relativeTo" {
    try std.testing.expectEqualStrings("src/app.zig", relativeTo("/Users/x/tt", "/Users/x/tt/src/app.zig"));
    try std.testing.expectEqualStrings("src/app.zig", relativeTo("/Users/x/tt/", "/Users/x/tt/src/app.zig"));
    try std.testing.expectEqualStrings("", relativeTo("/Users/x/tt", "/Users/x/tt"));
    try std.testing.expectEqualStrings("/Users/x/other", relativeTo("/Users/x/tt", "/Users/x/other"));
    try std.testing.expectEqualStrings("/Users/x/tt2/a", relativeTo("/Users/x/tt", "/Users/x/tt2/a"));
    try std.testing.expectEqualStrings("Users/x", relativeTo("/", "/Users/x"));
}

test "paths: isUnder" {
    try std.testing.expect(isUnder("/a/b", "/a/b"));
    try std.testing.expect(isUnder("/a/b", "/a/b/c"));
    try std.testing.expect(isUnder("/a/b/", "/a/b/c"));
    try std.testing.expect(!isUnder("/a/b", "/a/bc"));
    try std.testing.expect(!isUnder("/a/b", "/a"));
    try std.testing.expect(isUnder("/", "/a"));
}

test "paths: nameProblem" {
    try std.testing.expect(nameProblem("notes.md") == null);
    try std.testing.expect(nameProblem(".env") == null);
    try std.testing.expect(nameProblem("") != null);
    try std.testing.expect(nameProblem("a/b") != null);
    try std.testing.expect(nameProblem(".") != null);
    try std.testing.expect(nameProblem("..") != null);
}

test "paths: join" {
    const a = try join(std.testing.allocator, "/a/b", "c");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("/a/b/c", a);
    const r = try join(std.testing.allocator, "/", "c");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/c", r);
}

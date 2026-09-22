//! Inline path suggestions for the command input ("git diff src/in" →
//! "gest/"). Only proposes something when it is unambiguous enough to help.
const std = @import("std");
const sys = @import("../sys.zig");

/// Start of the last shell word in `text` (honours backslash-escaped spaces).
pub fn lastWordStart(text: []const u8) usize {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '=' or text[i] == ';' or text[i] == '|' or text[i] == '&' or text[i] == '<' or text[i] == '>') start = i + 1;
    }
    return start;
}

const Matcher = struct {
    gpa: std.mem.Allocator,
    prefix: []const u8,
    /// Longest common completion among matches so far.
    common: std.ArrayList(u8) = .empty,
    count: usize = 0,
    only_is_dir: bool = false,

    fn visit(self: *Matcher, entry: sys.DirEntry) void {
        if (!std.mem.startsWith(u8, entry.name, self.prefix)) return;
        if (self.prefix.len == 0 and entry.name[0] == '.') return;
        if (self.count == 0) {
            self.common.appendSlice(self.gpa, entry.name) catch return;
            self.only_is_dir = entry.is_dir;
        } else {
            var n: usize = 0;
            const lim = @min(self.common.items.len, entry.name.len);
            while (n < lim and self.common.items[n] == entry.name[n]) n += 1;
            // Never cut a UTF-8 sequence in half.
            while (n > 0 and n < self.common.items.len and (self.common.items[n] & 0xC0) == 0x80) n -= 1;
            self.common.items.len = n;
            self.only_is_dir = false;
        }
        self.count += 1;
    }
};

/// Returns the text to append after `text` (caller owns it), or null.
pub fn suggestPath(gpa: std.mem.Allocator, cwd: []const u8, text: []const u8) ?[]u8 {
    const word_start = lastWordStart(text);
    // Command position: leave it to history unless it is clearly a path.
    const word = text[word_start..];
    if (word.len == 0) return null;
    const is_first = std.mem.trim(u8, text[0..word_start], " \t").len == 0;
    if (is_first and std.mem.indexOfScalar(u8, word, '/') == null) return null;
    if (word[0] == '-' or word[0] == '$' or word[0] == '"' or word[0] == '\'') return null;

    // Unescape the word to get the on-disk spelling.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        if (word[i] == '\\' and i + 1 < word.len) i += 1;
        plain.append(gpa, word[i]) catch return null;
    }

    const slash = std.mem.lastIndexOfScalar(u8, plain.items, '/');
    const dir_part = if (slash) |s| plain.items[0 .. s + 1] else "";
    const prefix = if (slash) |s| plain.items[s + 1 ..] else plain.items;
    if (prefix.len == 0 and dir_part.len == 0) return null;

    var dir_path: std.ArrayList(u8) = .empty;
    defer dir_path.deinit(gpa);
    if (std.mem.startsWith(u8, dir_part, "~/")) {
        dir_path.appendSlice(gpa, sys.home()) catch return null;
        dir_path.appendSlice(gpa, dir_part[1..]) catch return null;
    } else if (dir_part.len > 0 and dir_part[0] == '/') {
        dir_path.appendSlice(gpa, dir_part) catch return null;
    } else {
        dir_path.appendSlice(gpa, cwd) catch return null;
        dir_path.append(gpa, '/') catch return null;
        dir_path.appendSlice(gpa, dir_part) catch return null;
    }

    var m = Matcher{ .gpa = gpa, .prefix = prefix };
    defer m.common.deinit(gpa);
    sys.listDir(gpa, dir_path.items, &m, Matcher.visit);
    if (m.count == 0 or m.common.items.len <= prefix.len) {
        if (!(m.count == 1 and m.only_is_dir and m.common.items.len == prefix.len)) return null;
    }

    var out: std.ArrayList(u8) = .empty;
    for (m.common.items[prefix.len..]) |ch| {
        if (ch == ' ' or ch == '(' or ch == ')' or ch == '&' or ch == ';' or ch == '\'' or ch == '"' or ch == '$' or ch == '*' or ch == '?' or ch == '[' or ch == ']' or ch == '!' or ch == '\\') {
            out.append(gpa, '\\') catch {};
        }
        out.append(gpa, ch) catch {};
    }
    if (m.count == 1 and m.only_is_dir) out.append(gpa, '/') catch {};
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

test "last word detection" {
    try std.testing.expectEqual(@as(usize, 9), lastWordStart("git diff src/in"));
    try std.testing.expectEqual(@as(usize, 3), lastWordStart("cd My\\ Documents/fo"));
    try std.testing.expectEqual(@as(usize, 0), lastWordStart("ls"));
    try std.testing.expectEqual(@as(usize, 4), lastWordStart("FOO=ba"));
}

test "path suggestion against the real filesystem" {
    const gpa = std.testing.allocator;
    // /usr/bi → n/
    const s1 = suggestPath(gpa, "/", "ls /usr/bi") orelse return error.NoSuggestion;
    defer gpa.free(s1);
    try std.testing.expectEqualStrings("n/", s1);
    // relative to cwd
    const s2 = suggestPath(gpa, "/usr", "cat bi") orelse return error.NoSuggestion;
    defer gpa.free(s2);
    try std.testing.expectEqualStrings("n/", s2);
    // command position without a slash: nothing
    try std.testing.expect(suggestPath(gpa, "/usr", "bi") == null);
}

//! Links in text: finding the web address under the pointer in a
//! command's output, a notebook output, a source file or a program's
//! screen (runs of characters), and the target of a Markdown link in the
//! preview. Pure logic; the views hit-test, `Ui.link` records the hover
//! and the ⌘/⌃-click, and the app opens the address (config
//! `browser.open_links`: a website tab in tt or the default browser).
const std = @import("std");

/// A half-open range of indices into the searched run.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn contains(self: Span, i: usize) bool {
        return i >= self.start and i < self.end;
    }
};

/// Longest address kept; anything longer is not treated as a link.
pub const max_len = 2048;

const schemes = [_][]const u8{ "https://", "http://", "file://", "ftp://", "mailto:" };

/// A character that can be part of an address found in plain text. Blanks,
/// quotes, angle brackets and the like end one; so does anything outside
/// ASCII, which keeps the box-drawing frames of tables out of it.
fn isUrlChar(cp: u21) bool {
    if (cp <= 0x20 or cp >= 0x7f) return false;
    return switch (cp) {
        '<', '>', '"', '\'', '`', '{', '}', '|', '\\', '^' => false,
        else => true,
    };
}

fn lower(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

fn isAlnum(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
}

/// The URL covering index `at` of `items`, whose characters `cpOf` reads:
/// "http(s)://", "file://", "ftp://", "mailto:" or a bare "www." name,
/// without the punctuation that usually follows one in prose (a closing
/// full stop, comma or unbalanced bracket).
pub fn spanAt(comptime T: type, items: []const T, at: usize, comptime cpOf: fn (T) u21) ?Span {
    if (at >= items.len or !isUrlChar(cpOf(items[at]))) return null;
    // The run of address characters around `at`.
    var s = at;
    while (s > 0 and isUrlChar(cpOf(items[s - 1]))) s -= 1;
    var e = at + 1;
    while (e < items.len and isUrlChar(cpOf(items[e]))) e += 1;

    // Where the address starts: the first scheme (or "www.") at or before
    // `at`, not glued to a word before it.
    var start: ?usize = null;
    var body: usize = 0;
    var i = s;
    find: while (i <= at) : (i += 1) {
        if (i > s and isAlnum(cpOf(items[i - 1]))) continue;
        for (schemes ++ [_][]const u8{"www."}) |p| {
            if (i + p.len > e) continue;
            var ok = true;
            for (p, 0..) |ch, k| {
                if (lower(cpOf(items[i + k])) != ch) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                start = i;
                body = i + p.len;
                break :find;
            }
        }
    }
    const from = start orelse return null;

    // Trailing punctuation belongs to the sentence, and a closing bracket
    // to the text around the address unless the address opened it.
    var end = e;
    while (end > body) {
        const c = cpOf(items[end - 1]);
        switch (c) {
            '.', ',', ';', ':', '!', '?', '*' => end -= 1,
            ')', ']' => {
                const open: u21 = if (c == ')') '(' else '[';
                var depth: isize = 0;
                for (items[from..end]) |it| {
                    const x = cpOf(it);
                    if (x == open) depth += 1 else if (x == c) depth -= 1;
                }
                if (depth < 0) end -= 1 else break;
            },
            else => break,
        }
    }
    // Something must follow the scheme ("http://" alone is not a link).
    if (end <= body or end - from > max_len) return null;
    if (at >= end) return null;
    return .{ .start = from, .end = end };
}

fn byteCp(b: u8) u21 {
    return b;
}

/// `spanAt` over UTF-8 text, by byte.
pub fn textSpanAt(text: []const u8, at: usize) ?Span {
    return spanAt(u8, text, at, byteCp);
}

/// The address to open for what was found: a bare "www." name gets
/// "https://" in front, a "<me@host>" autolink "mailto:". Returns a slice
/// of `buf`, or of `found`.
pub fn normalize(found: []const u8, buf: []u8) []const u8 {
    if (startsWithIgnoreCase(found, "www.")) {
        return std.fmt.bufPrint(buf, "https://{s}", .{found}) catch found;
    }
    if (!hasScheme(found) and std.mem.indexOfScalar(u8, found, '@') != null and std.mem.indexOfAny(u8, found, "/: ") == null) {
        return std.fmt.bufPrint(buf, "mailto:{s}", .{found}) catch found;
    }
    return found;
}

/// What a found link opens: `normalize`d, and null when it is not an
/// address with a scheme (a relative path or "#anchor" in Markdown).
pub fn resolve(found_text: []const u8, buf: []u8) ?[]const u8 {
    const url = normalize(found_text, buf);
    return if (hasScheme(url)) url else null;
}

/// True for addresses a website tab can show (http and https); others
/// (mailto:, ftp:, file:) always go to the system.
pub fn isWeb(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http://") or startsWithIgnoreCase(url, "https://");
}

/// Something worth handing to a browser or the system: it has a scheme
/// (relative paths and "#anchors" in a Markdown file are not links here).
pub fn hasScheme(url: []const u8) bool {
    for (schemes) |p| if (startsWithIgnoreCase(url, p)) return true;
    return false;
}

fn startsWithIgnoreCase(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p);
}

/// A Markdown link found on a line: the bytes it covers and where it goes.
pub const Target = struct {
    span: Span,
    url: []const u8,
};

/// The link covering byte `at` of a Markdown line: "[text](url)",
/// "<https://…>", "<a href=…>text</a>" or a bare address. The url is a
/// slice of `line` (possibly relative: check `hasScheme`); "www." names
/// still need `normalize`.
pub fn markdownAt(line: []const u8, at: usize) ?Target {
    if (at >= line.len) return null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '[' => {
                if (i + 1 < line.len and line[i + 1] == '[') continue; // [[wikilink]]
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, ']') orelse continue;
                if (close + 1 >= line.len or line[close + 1] != '(') continue;
                const paren = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse continue;
                const from = if (i > 0 and line[i - 1] == '!') i - 1 else i;
                const span: Span = .{ .start = from, .end = paren + 1 };
                if (span.contains(at)) {
                    var dest = std.mem.trim(u8, line[close + 2 .. paren], " \t");
                    // [text](url "title") and [text](<url>).
                    if (std.mem.indexOfAny(u8, dest, " \t")) |sp| dest = dest[0..sp];
                    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
                    return .{ .span = span, .url = dest };
                }
                i = paren;
            },
            '<' => {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, '>') orelse continue;
                const inner = line[i + 1 .. close];
                if (inner.len > 2 and (inner[0] == 'a' or inner[0] == 'A') and (inner[1] == ' ' or inner[1] == '\t')) {
                    // <a href="…">text</a>
                    const end_tag = std.ascii.indexOfIgnoreCasePos(line, close + 1, "</a>") orelse line.len;
                    const span: Span = .{ .start = i, .end = @min(line.len, end_tag + 4) };
                    if (span.contains(at)) {
                        const href = attr(inner, "href") orelse return null;
                        return .{ .span = span, .url = href };
                    }
                    i = span.end -| 1;
                } else if (inner.len > 0 and inner[0] != ' ' and std.mem.indexOfAny(u8, inner, " \t") == null and
                    (std.mem.indexOf(u8, inner, "://") != null or std.mem.indexOfScalar(u8, inner, '@') != null))
                {
                    // <https://…> and <me@host> autolinks.
                    const span: Span = .{ .start = i, .end = close + 1 };
                    if (span.contains(at)) return .{ .span = span, .url = inner };
                    i = close;
                }
            },
            else => {},
        }
    }
    const s = textSpanAt(line, at) orelse return null;
    return .{ .span = s, .url = line[s.start..s.end] };
}

/// The value of `name="…"` (or '…', or bare) in a tag's inside.
fn attr(inner: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(inner, from, name)) |p| {
        from = p + name.len;
        if (p > 0 and inner[p - 1] != ' ' and inner[p - 1] != '\t') continue;
        var k = p + name.len;
        while (k < inner.len and inner[k] == ' ') k += 1;
        if (k >= inner.len or inner[k] != '=') continue;
        k += 1;
        while (k < inner.len and inner[k] == ' ') k += 1;
        if (k >= inner.len) return null;
        const q = inner[k];
        if (q == '"' or q == '\'') {
            const end = std.mem.indexOfScalarPos(u8, inner, k + 1, q) orelse return null;
            return inner[k + 1 .. end];
        }
        const end = std.mem.indexOfAnyPos(u8, inner, k, " \t/") orelse inner.len;
        return inner[k..end];
    }
    return null;
}

fn foundIn(text: []const u8, at: usize) []const u8 {
    const s = textSpanAt(text, at) orelse return "";
    return text[s.start..s.end];
}

test "links: plain addresses in text, without the punctuation around them" {
    const t = std.testing;
    try t.expectEqualStrings("https://example.com/a", foundIn("see https://example.com/a.", 10));
    try t.expectEqualStrings("https://example.com/a", foundIn("see https://example.com/a.", 4));
    try t.expectEqualStrings("", foundIn("see https://example.com/a.", 2));
    try t.expectEqualStrings("", foundIn("see https://example.com/a.", 25));
    try t.expectEqualStrings("http://x.y/q?a=1&b=2", foundIn("(http://x.y/q?a=1&b=2), then", 5));
    // Brackets the address opened are kept.
    try t.expectEqualStrings("https://en.wikipedia.org/wiki/Zig_(language)", foundIn("https://en.wikipedia.org/wiki/Zig_(language)", 0));
    try t.expectEqualStrings("https://a.b/c", foundIn("\"https://a.b/c\"", 3));
    try t.expectEqualStrings("https://a.b/?u=https://c.d", foundIn("x https://a.b/?u=https://c.d y", 22));
    try t.expectEqualStrings("www.ziglang.org", foundIn("go to www.ziglang.org!", 8));
    try t.expectEqualStrings("mailto:me@x.y", foundIn("mailto:me@x.y", 3));
    try t.expectEqualStrings("", foundIn("http:// nothing", 2));
    try t.expectEqualStrings("", foundIn("xhttps://a.b", 3));
    try t.expectEqualStrings("", foundIn("plain words", 3));
    // A table frame drawn around it stays out.
    try t.expectEqualStrings("https://a.b", foundIn("│https://a.b│", 5));

    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("https://www.a.b", normalize("www.a.b", &buf));
    try t.expectEqualStrings("http://a.b", normalize("http://a.b", &buf));
    try t.expectEqualStrings("mailto:me@a.b", normalize("me@a.b", &buf));
    try t.expect(isWeb("HTTPS://a.b") and !isWeb("mailto:x@y") and hasScheme("mailto:x@y") and !hasScheme("notes.md"));
}

test "links: runs of cells, through a character accessor" {
    const Cell = struct { cp: u21 };
    const cps = [_]u21{ 'a', ' ', 'h', 't', 't', 'p', ':', '/', '/', 'z', '.', 'o', ' ', 0x2500 };
    var cells: [cps.len]Cell = undefined;
    for (cps, 0..) |c, i| cells[i] = .{ .cp = c };
    const get = struct {
        fn f(c: Cell) u21 {
            return c.cp;
        }
    }.f;
    try std.testing.expectEqual(Span{ .start = 2, .end = 12 }, spanAt(Cell, &cells, 10, get).?);
    try std.testing.expect(spanAt(Cell, &cells, 0, get) == null);
    try std.testing.expect(spanAt(Cell, &cells, 13, get) == null);
}

test "links: Markdown links resolve to their destination" {
    const t = std.testing;
    const line = "see [the docs](https://x.y/d \"Docs\") and <https://a.b> or <a href=\"https://h.i\">here</a>, www.w.w";
    try t.expectEqualStrings("https://x.y/d", markdownAt(line, 6).?.url);
    try t.expectEqualStrings("https://x.y/d", markdownAt(line, 20).?.url);
    try t.expect(markdownAt(line, 1) == null);
    try t.expectEqualStrings("https://a.b", markdownAt(line, 44).?.url);
    const here = std.mem.indexOf(u8, line, "here").?;
    try t.expectEqualStrings("https://h.i", markdownAt(line, here).?.url);
    try t.expectEqualStrings("www.w.w", markdownAt(line, line.len - 2).?.url);
    try t.expectEqualStrings("notes.md", markdownAt("[n](notes.md)", 1).?.url);
    try t.expectEqualStrings("https://img", markdownAt("![alt](<https://img>)", 0).?.url);
    try t.expect(markdownAt("[[wiki]] https://q.r", 3) == null);
    try t.expectEqualStrings("https://q.r", markdownAt("[[wiki]] https://q.r", 12).?.url);
}

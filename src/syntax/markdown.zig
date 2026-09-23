//! Markdown, one line at a time. Serves two readers: the source view colours
//! the spans like any other language, and the visual view uses the same
//! spans as *decorations* — `.marker` spans are the syntax it hides, `.list`
//! becomes a bullet, `.code` inside a fence gets the code background — plus
//! `blockOf` for what kind of line it is. That is the CodeMirror/Obsidian
//! model: the source stays the only truth, rendering is a view over spans.
//!
//! Inline parsing is single pass with bounded look-ahead, so a line of a
//! million asterisks costs a million steps, never a million squared.
const std = @import("std");
const lexer = @import("lexer.zig");

const Scope = lexer.Scope;
const State = lexer.State;
const Spans = lexer.Spans;

// States.
pub const state_normal: State = 0;
const state_fence_tick: State = 1;
const state_fence_tilde: State = 2;
const state_front_matter: State = 3;
/// The document's first line: a "---" here opens YAML front matter.
pub const initial_state: State = 4;
/// After a table's alignment row: paragraph lines are table rows until a
/// blank line or another block starts.
pub const state_table: State = 5;
/// Inside a "<!-- … -->" comment that did not close on its line.
pub const state_html_comment: State = 6;

/// How far a delimiter may look for its partner on the same line.
const max_lookahead: usize = 800;

pub const BlockKind = enum { paragraph, blank, heading, quote, list, fence_open, fence_close, code, hr, table_sep, table_row, front_matter, html };

/// What a line is, for layout.
pub const Block = struct {
    kind: BlockKind = .paragraph,
    /// Heading level (1–6) or quote depth.
    level: u8 = 0,
    /// Leading blanks, in columns (tabs count 4).
    indent: u8 = 0,
    /// Where the text after the block markers begins.
    content: u32 = 0,
    /// Ordered list item?
    ordered: bool = false,
    task: enum { none, todo, done } = .none,
};

fn isBlank(line: []const u8) bool {
    for (line) |b| if (b != ' ' and b != '\t') return false;
    return true;
}

fn leadingBlanks(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

fn columnsOf(prefix: []const u8) u8 {
    var c: usize = 0;
    for (prefix) |b| c += if (b == '\t') 4 else 1;
    return @intCast(@min(c, 255));
}

fn runOf(line: []const u8, at: usize, ch: u8) usize {
    var n: usize = 0;
    while (at + n < line.len and line[at + n] == ch) n += 1;
    return n;
}

/// "``` info" / "~~~": returns the fence character or null.
fn fenceAt(line: []const u8, at: usize) ?u8 {
    if (at >= line.len) return null;
    const ch = line[at];
    if (ch != '`' and ch != '~') return null;
    if (runOf(line, at, ch) < 3) return null;
    // A backtick fence's info string may not contain backticks.
    if (ch == '`' and std.mem.indexOfScalarPos(u8, line, at + 3, '`') != null) return null;
    return ch;
}

fn isHr(line: []const u8, from: usize) bool {
    var count: usize = 0;
    var ch: u8 = 0;
    for (line[from..]) |b| {
        if (b == ' ' or b == '\t') continue;
        if (b != '-' and b != '*' and b != '_') return false;
        if (ch == 0) ch = b else if (b != ch) return false;
        count += 1;
    }
    return count >= 3;
}

/// A table alignment row: only | - : and blanks, with at least one dash.
fn isTableSep(line: []const u8, from: usize) bool {
    var dashes: usize = 0;
    var pipes: usize = 0;
    for (line[from..]) |b| switch (b) {
        '-' => dashes += 1,
        '|' => pipes += 1,
        ':', ' ', '\t' => {},
        else => return false,
    };
    return dashes > 0 and pipes > 0;
}

/// Bullet / number marker at `at`; returns the byte after the marker's
/// trailing space, or null.
fn listMarkerEnd(line: []const u8, at: usize, ordered: *bool) ?usize {
    if (at >= line.len) return null;
    const b = line[at];
    if (b == '-' or b == '*' or b == '+') {
        if (at + 1 < line.len and (line[at + 1] == ' ' or line[at + 1] == '\t')) {
            ordered.* = false;
            return at + 2;
        }
        if (at + 1 == line.len) {
            ordered.* = false;
            return at + 1;
        }
        return null;
    }
    var i = at;
    while (i < line.len and i - at < 9 and std.ascii.isDigit(line[i])) i += 1;
    if (i == at or i >= line.len) return null;
    if (line[i] != '.' and line[i] != ')') return null;
    if (i + 1 < line.len and line[i + 1] != ' ' and line[i + 1] != '\t') return null;
    ordered.* = true;
    return @min(i + 2, line.len);
}

/// Classifies a line for layout. Cheap: looks at the prefix only.
pub fn blockOf(state: State, line: []const u8) Block {
    switch (state) {
        state_fence_tick, state_fence_tilde => {
            const at = leadingBlanks(line);
            if (fenceAt(line, at)) |ch| {
                if ((ch == '`') == (state == state_fence_tick) and isBlank(line[at + runOf(line, at, ch) ..]))
                    return .{ .kind = .fence_close, .content = @intCast(line.len) };
            }
            return .{ .kind = .code, .content = 0 };
        },
        state_front_matter => {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "---")) return .{ .kind = .fence_close, .content = @intCast(line.len) };
            return .{ .kind = .front_matter };
        },
        state_html_comment => return .{ .kind = .html, .content = 0 },
        state_table => {
            // The table goes on while the lines would otherwise be paragraphs.
            var blk = blockOf(state_normal, line);
            if (blk.kind == .paragraph) blk.kind = .table_row;
            return blk;
        },
        else => {},
    }
    if (state == initial_state and std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "---")) {
        return .{ .kind = .fence_open, .content = @intCast(line.len) };
    }
    if (isBlank(line)) return .{ .kind = .blank, .content = @intCast(line.len) };
    var at = leadingBlanks(line);
    var blk: Block = .{ .indent = columnsOf(line[0..at]) };
    // Quotes nest: "> > text".
    while (at < line.len and line[at] == '>') {
        blk.level += 1;
        at += 1;
        if (at < line.len and line[at] == ' ') at += 1;
        blk.kind = .quote;
    }
    if (blk.kind == .quote) {
        blk.content = @intCast(at);
        return blk;
    }
    if (fenceAt(line, at) != null) return .{ .kind = .fence_open, .indent = blk.indent, .content = @intCast(line.len) };
    if (at < line.len and line[at] == '#') {
        const n = runOf(line, at, '#');
        if (n <= 6 and (at + n == line.len or line[at + n] == ' ' or line[at + n] == '\t')) {
            var c = at + n;
            if (c < line.len) c += 1;
            return .{ .kind = .heading, .level = @intCast(n), .indent = blk.indent, .content = @intCast(c) };
        }
    }
    if (isHr(line, at)) return .{ .kind = .hr, .indent = blk.indent, .content = @intCast(line.len) };
    if (isTableSep(line, at)) return .{ .kind = .table_sep, .indent = blk.indent, .content = @intCast(line.len) };
    var ordered = false;
    if (listMarkerEnd(line, at, &ordered)) |end| {
        blk.kind = .list;
        blk.ordered = ordered;
        blk.content = @intCast(end);
        // Task box.
        if (end + 3 <= line.len and line[end] == '[' and line[end + 2] == ']' and (end + 3 == line.len or line[end + 3] == ' ')) {
            const mark = line[end + 1];
            if (mark == ' ') {
                blk.task = .todo;
                blk.content = @intCast(@min(end + 4, line.len));
            } else if (mark == 'x' or mark == 'X') {
                blk.task = .done;
                blk.content = @intCast(@min(end + 4, line.len));
            }
        }
        return blk;
    }
    if (at < line.len and line[at] == '<' and at + 1 < line.len and (std.ascii.isAlphabetic(line[at + 1]) or line[at + 1] == '/' or line[at + 1] == '!')) {
        // A few block tags map onto the Markdown block they stand for, so
        // the visual mode renders them the same way; the rest is `.html`.
        if (tagAt(line, at)) |tag| {
            if (!tag.closing) {
                if (tag.name.len == 2 and (tag.name[0] == 'h' or tag.name[0] == 'H') and tag.name[1] >= '1' and tag.name[1] <= '6') {
                    return .{ .kind = .heading, .level = tag.name[1] - '0', .indent = blk.indent, .content = @intCast(tag.end) };
                }
                if (std.ascii.eqlIgnoreCase(tag.name, "hr")) return .{ .kind = .hr, .indent = blk.indent, .content = @intCast(line.len) };
                if (std.ascii.eqlIgnoreCase(tag.name, "li")) {
                    blk.kind = .list;
                    blk.content = @intCast(tag.end);
                    while (blk.content < line.len and line[blk.content] == ' ') blk.content += 1;
                    return blk;
                }
                if (std.ascii.eqlIgnoreCase(tag.name, "blockquote")) {
                    blk.kind = .quote;
                    blk.level = 1;
                    blk.content = @intCast(tag.end);
                    while (blk.content < line.len and line[blk.content] == ' ') blk.content += 1;
                    return blk;
                }
            }
        }
        return .{ .kind = .html, .indent = blk.indent, .content = @intCast(at) };
    }
    blk.content = @intCast(at);
    return blk;
}

/// The mark of a task-list line ("- [ ] …" / "- [x] …"): the byte between
/// the brackets, and whether it is ticked. Null for every other line.
pub fn taskMark(state: State, line: []const u8) ?struct { at: usize, done: bool } {
    const blk = blockOf(state, line);
    if (blk.kind != .list or blk.task == .none) return null;
    const open = std.mem.lastIndexOfScalar(u8, line[0..blk.content], '[') orelse return null;
    return .{ .at = open + 1, .done = blk.task == .done };
}

// ── HTML ────────────────────────────────────────────────────────────────
/// An HTML tag starting at `at`: "<name …>", "</name>", "<name/>".
pub const Tag = struct {
    name: []const u8,
    /// Byte after the closing ">".
    end: usize,
    closing: bool,
    /// The bytes between "<" and ">", attributes included.
    inner: []const u8,
};

/// The tag at `at`, or null when the "<" there does not open one. A quoted
/// attribute value may contain ">"; the search is bounded like every other
/// look-ahead.
pub fn tagAt(line: []const u8, at: usize) ?Tag {
    if (at + 1 >= line.len or line[at] != '<') return null;
    var i = at + 1;
    const closing = line[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '-')) i += 1;
    if (i == name_start or !std.ascii.isAlphabetic(line[name_start])) return null;
    const name = line[name_start..i];
    // What follows the name decides: attributes, "/>", ">" — or not a tag
    // at all ("<https://…>", "<mail@host>", "a<b").
    if (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '>' and line[i] != '/') return null;
    const limit = @min(line.len, at + max_lookahead);
    var quote: u8 = 0;
    while (i < limit) : (i += 1) {
        const b = line[i];
        if (quote != 0) {
            if (b == quote) quote = 0;
            continue;
        }
        if (b == '"' or b == '\'') {
            quote = b;
            continue;
        }
        if (b == '>') return .{ .name = name, .end = i + 1, .closing = closing, .inner = line[at + 1 .. i] };
        if (b == '<') return null;
    }
    return null;
}

/// The value of attribute `name` inside a tag's `inner` bytes (quoted values
/// only), as a range within `inner`.
pub fn tagAttr(inner: []const u8, name: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i + name.len < inner.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(inner[i .. i + name.len], name)) continue;
        if (i > 0 and !(inner[i - 1] == ' ' or inner[i - 1] == '\t')) continue;
        var j = i + name.len;
        while (j < inner.len and inner[j] == ' ') j += 1;
        if (j >= inner.len or inner[j] != '=') continue;
        j += 1;
        while (j < inner.len and inner[j] == ' ') j += 1;
        if (j >= inner.len or (inner[j] != '"' and inner[j] != '\'')) return null;
        const q = inner[j];
        const close = std.mem.indexOfScalarPos(u8, inner, j + 1, q) orelse return null;
        return .{ .start = j + 1, .end = close };
    }
    return null;
}

/// What an inline tag does to the text after it.
const TagStyle = enum { none, strong, emphasis, strike, code, link };

fn tagStyle(name: []const u8) TagStyle {
    const T = struct { n: []const u8, s: TagStyle };
    const table = [_]T{
        .{ .n = "b", .s = .strong },        .{ .n = "strong", .s = .strong }, .{ .n = "i", .s = .emphasis },
        .{ .n = "em", .s = .emphasis },     .{ .n = "cite", .s = .emphasis }, .{ .n = "var", .s = .emphasis },
        .{ .n = "dfn", .s = .emphasis },    .{ .n = "s", .s = .strike },      .{ .n = "del", .s = .strike },
        .{ .n = "strike", .s = .strike },   .{ .n = "code", .s = .code },     .{ .n = "kbd", .s = .code },
        .{ .n = "samp", .s = .code },       .{ .n = "tt", .s = .code },       .{ .n = "a", .s = .link },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(name, t.n)) return t.s;
    return .none;
}

/// Is the marker at `at` a "<br>" (or "<br/>", "<br />")?
pub fn isBreakTag(line: []const u8, at: usize) bool {
    if (at + 3 >= line.len or line[at] != '<') return false;
    if (std.ascii.toLower(line[at + 1]) != 'b' or std.ascii.toLower(line[at + 2]) != 'r') return false;
    const b = line[at + 3];
    return b == '>' or b == '/' or b == ' ';
}

const Entity = struct { n: []const u8, cp: u21 };
const entities = [_]Entity{
    .{ .n = "amp", .cp = '&' },        .{ .n = "lt", .cp = '<' },         .{ .n = "gt", .cp = '>' },
    .{ .n = "quot", .cp = '"' },       .{ .n = "apos", .cp = '\'' },      .{ .n = "nbsp", .cp = 0xA0 },
    .{ .n = "copy", .cp = 0xA9 },      .{ .n = "reg", .cp = 0xAE },       .{ .n = "trade", .cp = 0x2122 },
    .{ .n = "mdash", .cp = 0x2014 },   .{ .n = "ndash", .cp = 0x2013 },   .{ .n = "hellip", .cp = 0x2026 },
    .{ .n = "laquo", .cp = 0xAB },     .{ .n = "raquo", .cp = 0xBB },     .{ .n = "lsquo", .cp = 0x2018 },
    .{ .n = "rsquo", .cp = 0x2019 },   .{ .n = "ldquo", .cp = 0x201C },   .{ .n = "rdquo", .cp = 0x201D },
    .{ .n = "times", .cp = 0xD7 },     .{ .n = "divide", .cp = 0xF7 },    .{ .n = "middot", .cp = 0xB7 },
    .{ .n = "bull", .cp = 0x2022 },    .{ .n = "rarr", .cp = 0x2192 },    .{ .n = "larr", .cp = 0x2190 },
    .{ .n = "uarr", .cp = 0x2191 },    .{ .n = "darr", .cp = 0x2193 },    .{ .n = "harr", .cp = 0x2194 },
    .{ .n = "rArr", .cp = 0x21D2 },    .{ .n = "hearts", .cp = 0x2665 },  .{ .n = "deg", .cp = 0xB0 },
    .{ .n = "plusmn", .cp = 0xB1 },    .{ .n = "euro", .cp = 0x20AC },    .{ .n = "pound", .cp = 0xA3 },
    .{ .n = "yen", .cp = 0xA5 },       .{ .n = "cent", .cp = 0xA2 },      .{ .n = "sect", .cp = 0xA7 },
    .{ .n = "para", .cp = 0xB6 },      .{ .n = "frac12", .cp = 0xBD },    .{ .n = "frac14", .cp = 0xBC },
    .{ .n = "frac34", .cp = 0xBE },    .{ .n = "sup2", .cp = 0xB2 },      .{ .n = "sup3", .cp = 0xB3 },
    .{ .n = "micro", .cp = 0xB5 },     .{ .n = "iexcl", .cp = 0xA1 },     .{ .n = "iquest", .cp = 0xBF },
    .{ .n = "szlig", .cp = 0xDF },     .{ .n = "ntilde", .cp = 0xF1 },    .{ .n = "Ntilde", .cp = 0xD1 },
    .{ .n = "aacute", .cp = 0xE1 },    .{ .n = "eacute", .cp = 0xE9 },    .{ .n = "iacute", .cp = 0xED },
    .{ .n = "oacute", .cp = 0xF3 },    .{ .n = "uacute", .cp = 0xFA },    .{ .n = "agrave", .cp = 0xE0 },
    .{ .n = "egrave", .cp = 0xE8 },    .{ .n = "auml", .cp = 0xE4 },      .{ .n = "ouml", .cp = 0xF6 },
    .{ .n = "uuml", .cp = 0xFC },      .{ .n = "Auml", .cp = 0xC4 },      .{ .n = "Ouml", .cp = 0xD6 },
    .{ .n = "Uuml", .cp = 0xDC },      .{ .n = "ccedil", .cp = 0xE7 },    .{ .n = "check", .cp = 0x2713 },
    .{ .n = "cross", .cp = 0x2717 },   .{ .n = "star", .cp = 0x2606 },    .{ .n = "starf", .cp = 0x2605 },
    .{ .n = "infin", .cp = 0x221E },   .{ .n = "ne", .cp = 0x2260 },      .{ .n = "le", .cp = 0x2264 },
    .{ .n = "ge", .cp = 0x2265 },      .{ .n = "minus", .cp = 0x2212 },   .{ .n = "shy", .cp = 0xAD },
    .{ .n = "zwj", .cp = 0x200D },     .{ .n = "zwnj", .cp = 0x200C },    .{ .n = "ensp", .cp = 0x2002 },
    .{ .n = "emsp", .cp = 0x2003 },    .{ .n = "thinsp", .cp = 0x2009 },
};

/// The entity starting at `at` ("&amp;", "&#169;", "&#xA9;"): its byte
/// length and code point, or null. Unknown names stay literal text, as in
/// CommonMark.
pub fn entityAt(line: []const u8, at: usize) ?struct { len: usize, cp: u21 } {
    if (at + 2 >= line.len or line[at] != '&') return null;
    var i = at + 1;
    if (line[i] == '#') {
        i += 1;
        const hex = i < line.len and (line[i] == 'x' or line[i] == 'X');
        if (hex) i += 1;
        const digits = i;
        var v: u32 = 0;
        while (i < line.len and i - digits < 8) : (i += 1) {
            const d = std.fmt.charToDigit(line[i], if (hex) 16 else 10) catch break;
            v = v * (if (hex) @as(u32, 16) else 10) + d;
        }
        if (i == digits or i >= line.len or line[i] != ';') return null;
        const cp: u21 = if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else @intCast(v);
        return .{ .len = i + 1 - at, .cp = cp };
    }
    const name_start = i;
    while (i < line.len and i - name_start < 32 and std.ascii.isAlphanumeric(line[i])) i += 1;
    if (i == name_start or i >= line.len or line[i] != ';') return null;
    const name = line[name_start..i];
    for (entities) |e| if (std.mem.eql(u8, e.n, name)) return .{ .len = i + 1 - at, .cp = e.cp };
    return null;
}

/// Table cells of a row line: `starts[k]` is where cell k begins (its
/// leading "|", when it has one, included) and `starts[count]` is the
/// line's end. Only "|" bytes lexed as `.punct` divide cells, so an escaped
/// or code-span pipe stays inside its cell. A trailing "|" (plus blanks)
/// belongs to the last cell rather than opening an empty one.
pub const max_cols = 24;

pub fn tableCells(line: []const u8, spans: *const Spans, starts: *[max_cols + 1]u32) u8 {
    var count: u8 = 1;
    starts[0] = 0;
    var cur: usize = 0;
    const first = leadingBlanks(line);
    var p: usize = 0;
    while (p < line.len) : (p += 1) {
        if (line[p] != '|') continue;
        if (spans.scopeAt(&cur, p) != .punct) continue;
        if (p == first) continue; // the leading pipe belongs to cell 0
        if (count == max_cols) break;
        starts[count] = @intCast(p);
        count += 1;
    }
    starts[count] = @intCast(line.len);
    if (count > 1 and isBlank(line[starts[count - 1] + 1 ..])) {
        count -= 1;
        starts[count] = @intCast(line.len);
    }
    return count;
}

pub const Align = enum { left, center, right };

/// Column alignments from an alignment row ("|:--|:-:|--:|").
pub fn tableAligns(line: []const u8, out: *[max_cols]Align) u8 {
    var count: u8 = 0;
    var i = leadingBlanks(line);
    if (i < line.len and line[i] == '|') i += 1;
    while (i < line.len and count < max_cols) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        const left = line[i] == ':';
        var j = i;
        while (j < line.len and line[j] != '|') j += 1;
        var k = j;
        while (k > i and (line[k - 1] == ' ' or line[k - 1] == '\t')) k -= 1;
        const right = k > i and line[k - 1] == ':';
        out[count] = if (left and right) .center else if (right) .right else .left;
        count += 1;
        i = j + 1;
    }
    return count;
}

// ── inline ──────────────────────────────────────────────────────────────
fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn isPunct(b: u8) bool {
    return std.ascii.isPunctuation(b);
}

/// Closing run of `ch` × `n` after `from`, within the look-ahead window.
fn findRun(line: []const u8, from: usize, ch: u8, n: usize) ?usize {
    const limit = @min(line.len, from + max_lookahead);
    var i = from;
    while (i < limit) : (i += 1) {
        if (line[i] != ch) continue;
        const run = runOf(line, i, ch);
        if (run == n) return i;
        i += run - 1;
    }
    return null;
}

fn findByte(line: []const u8, from: usize, ch: u8) ?usize {
    const limit = @min(line.len, from + max_lookahead);
    return std.mem.indexOfScalarPos(u8, line[0..limit], from, ch);
}

/// Lexes `line[from..]` as inline Markdown; `base` is the scope of plain
/// text there (`.heading` inside a heading). Inline HTML is part of it:
/// tags are markers that style the text they wrap, entities are escapes,
/// "<!-- … -->" is a comment. Returns true when a comment is still open at
/// the end of the line.
fn lexInline(line: []const u8, from: usize, base: Scope, out: ?*Spans) bool {
    var i = from;
    var strong = false;
    var em = false;
    var strike = false;
    var code_tag = false;
    var link_tag = false;
    while (i < line.len) {
        const text_scope: Scope = if (code_tag) .code else if (link_tag) .link else if (strong) .strong else if (em) .emphasis else if (strike) .strike else base;
        const b = line[i];
        switch (b) {
            '\\' => {
                if (i + 1 < line.len and isPunct(line[i + 1])) {
                    lexer.emit(out, i + 1, .marker);
                    lexer.emit(out, i + 2, text_scope);
                    i += 2;
                    continue;
                }
            },
            '`' => {
                const n = runOf(line, i, '`');
                if (findRun(line, i + n, '`', n)) |close| {
                    lexer.emit(out, i + n, .marker);
                    lexer.emit(out, close, .code);
                    lexer.emit(out, close + n, .marker);
                    i = close + n;
                    continue;
                }
                lexer.emit(out, i + n, text_scope);
                i += n;
                continue;
            },
            '*', '_', '~' => {
                const n = runOf(line, i, b);
                const before_ok = i == 0 or !isWordByte(line[i - 1]) or b == '*';
                const after = if (i + n < line.len) line[i + n] else ' ';
                const before = if (i > 0) line[i - 1] else ' ';
                const can_open = after != ' ' and after != '\t' and (b != '_' or before_ok);
                const can_close = before != ' ' and before != '\t' and (b != '_' or i + n >= line.len or !isWordByte(after));
                var handled = false;
                if (b == '~' and n >= 2) {
                    if (strike and can_close) {
                        strike = false;
                        handled = true;
                    } else if (!strike and can_open) {
                        strike = true;
                        handled = true;
                    }
                } else if (b != '~') {
                    if (n >= 2) {
                        if (strong and can_close) {
                            strong = false;
                            handled = true;
                        } else if (!strong and can_open) {
                            strong = true;
                            handled = true;
                        }
                        if (n >= 3 and handled) {
                            // "***" toggles both.
                            if (em and can_close) em = false else if (!em and can_open) em = true;
                        }
                    } else {
                        if (em and can_close) {
                            em = false;
                            handled = true;
                        } else if (!em and can_open) {
                            em = true;
                            handled = true;
                        }
                    }
                }
                if (handled) {
                    lexer.emit(out, i + n, .marker);
                } else {
                    lexer.emit(out, i + n, text_scope);
                }
                i += n;
                continue;
            },
            '[' => {
                if (i + 1 < line.len and line[i + 1] == '[') {
                    // [[wikilink|alias]]
                    if (findByte(line, i + 2, ']')) |close| {
                        if (close + 1 < line.len and line[close + 1] == ']') {
                            lexer.emit(out, i + 2, .marker);
                            lexer.emit(out, close, .link);
                            lexer.emit(out, close + 2, .marker);
                            i = close + 2;
                            continue;
                        }
                    }
                } else if (findByte(line, i + 1, ']')) |close| {
                    const image = i > 0 and line[i - 1] == '!';
                    _ = image;
                    if (close + 1 < line.len and line[close + 1] == '(') {
                        if (findByte(line, close + 2, ')')) |paren| {
                            lexer.emit(out, i + 1, .marker);
                            lexer.emit(out, close, .link);
                            lexer.emit(out, paren + 1, .marker);
                            i = paren + 1;
                            continue;
                        }
                    }
                }
            },
            '!' => {
                if (i + 1 < line.len and line[i + 1] == '[') {
                    // The '[' branch handles the rest; the bang is part of the marker.
                    lexer.emit(out, i + 1, .marker);
                    i += 1;
                    continue;
                }
            },
            '<' => {
                if (std.mem.startsWith(u8, line[i..], "<!--")) {
                    if (std.mem.indexOfPos(u8, line[0..@min(line.len, i + max_lookahead)], i + 4, "-->")) |close| {
                        lexer.emit(out, close + 3, .comment);
                        i = close + 3;
                        continue;
                    }
                    lexer.emit(out, line.len, .comment);
                    return true;
                }
                if (tagAt(line, i)) |tag| {
                    const style = tagStyle(tag.name);
                    const on = !tag.closing;
                    switch (style) {
                        .strong => strong = on,
                        .emphasis => em = on,
                        .strike => strike = on,
                        .code => code_tag = on,
                        .link => link_tag = on,
                        .none => {},
                    }
                    // An image shows as its alt text, like "![alt](src)" does.
                    if (on and std.ascii.eqlIgnoreCase(tag.name, "img")) {
                        if (tagAttr(tag.inner, "alt")) |alt| if (alt.end > alt.start) {
                            lexer.emit(out, i + 1 + alt.start, .marker);
                            lexer.emit(out, i + 1 + alt.end, .link);
                        };
                    }
                    lexer.emit(out, tag.end, .marker);
                    i = tag.end;
                    continue;
                }
                // <https://…> autolink.
                if (i + 1 < line.len and line[i + 1] != ' ') {
                    if (findByte(line, i + 1, '>')) |close| {
                        const inner = line[i + 1 .. close];
                        if (std.mem.indexOf(u8, inner, "://") != null or std.mem.indexOfScalar(u8, inner, '@') != null) {
                            lexer.emit(out, i + 1, .marker);
                            lexer.emit(out, close, .link);
                            lexer.emit(out, close + 1, .marker);
                            i = close + 1;
                            continue;
                        }
                    }
                }
            },
            'h' => {
                if ((i == 0 or !isWordByte(line[i - 1])) and (std.mem.startsWith(u8, line[i..], "http://") or std.mem.startsWith(u8, line[i..], "https://"))) {
                    var end = i;
                    while (end < line.len and line[end] != ' ' and line[end] != '\t' and line[end] != '<' and line[end] != '>') end += 1;
                    while (end > i and (line[end - 1] == '.' or line[end - 1] == ',' or line[end - 1] == ')' or line[end - 1] == ';')) end -= 1;
                    lexer.emit(out, end, .link);
                    i = end;
                    continue;
                }
            },
            '#' => {
                // #tag (not at the start of the line, where it is a heading).
                if (i > from and (line[i - 1] == ' ' or line[i - 1] == '\t') and i + 1 < line.len and (std.ascii.isAlphabetic(line[i + 1]) or line[i + 1] >= 0x80)) {
                    var end = i + 1;
                    while (end < line.len and (isWordByte(line[end]) or line[end] == '-' or line[end] == '/')) end += 1;
                    lexer.emit(out, end, .property);
                    i = end;
                    continue;
                }
            },
            '|' => {
                lexer.emit(out, i + 1, .punct);
                i += 1;
                continue;
            },
            '&' => {
                if (entityAt(line, i)) |ent| {
                    lexer.emit(out, i + ent.len, .escape);
                    i += ent.len;
                    continue;
                }
            },
            else => {},
        }
        lexer.emit(out, i + 1, text_scope);
        i += 1;
    }
    return false;
}

fn afterInline(open_comment: bool) State {
    return if (open_comment) state_html_comment else state_normal;
}

pub fn lexLine(state: State, line: []const u8, out: ?*Spans) State {
    const blk = blockOf(state, line);
    switch (blk.kind) {
        .code => {
            lexer.emit(out, line.len, .code);
            return state;
        },
        .front_matter => {
            // key: value
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                lexer.emit(out, colon + 1, .property);
                lexer.emit(out, line.len, .string);
            } else lexer.emit(out, line.len, .string);
            return state;
        },
        .fence_close => {
            lexer.emit(out, line.len, .marker);
            return state_normal;
        },
        .fence_open => {
            if (state == initial_state) {
                lexer.emit(out, line.len, .marker);
                return state_front_matter;
            }
            const at = leadingBlanks(line);
            const ch = line[at];
            const n = runOf(line, at, ch);
            lexer.emit(out, at + n, .marker);
            lexer.emit(out, line.len, .comment);
            return if (ch == '`') state_fence_tick else state_fence_tilde;
        },
        .blank => {
            lexer.emit(out, line.len, .plain);
            return state_normal;
        },
        .hr => {
            lexer.emit(out, line.len, .marker);
            return state_normal;
        },
        .table_sep => {
            lexer.emit(out, line.len, .marker);
            return state_table;
        },
        .table_row => {
            return if (lexInline(line, 0, .plain, out)) state_html_comment else state_table;
        },
        .html => {
            if (state == state_html_comment) {
                // The rest of a comment opened on an earlier line.
                if (std.mem.indexOf(u8, line, "-->")) |close| {
                    lexer.emit(out, close + 3, .comment);
                    return afterInline(lexInline(line, close + 3, .plain, out));
                }
                lexer.emit(out, line.len, .comment);
                return state_html_comment;
            }
            return afterInline(lexInline(line, blk.content, .plain, out));
        },
        .heading => {
            lexer.emit(out, blk.content, .marker);
            // Optional closing #s.
            var end = line.len;
            while (end > blk.content and (line[end - 1] == ' ' or line[end - 1] == '#')) end -= 1;
            const open = lexInline(line[0..end], blk.content, .heading, out);
            lexer.emit(out, line.len, .marker);
            return afterInline(open);
        },
        .quote => {
            lexer.emit(out, blk.content, .quote);
            // A quote may hold a list, a heading …: classify the rest.
            const inner = blockOf(state_normal, line[blk.content..]);
            switch (inner.kind) {
                .heading => {
                    lexer.emit(out, blk.content + inner.content, .marker);
                    return afterInline(lexInline(line, blk.content + inner.content, .heading, out));
                },
                .list => {
                    lexer.emit(out, blk.content + inner.content, .list);
                    return afterInline(lexInline(line, blk.content + inner.content, .plain, out));
                },
                else => return afterInline(lexInline(line, blk.content, .plain, out)),
            }
        },
        .list => {
            lexer.emit(out, blk.content, .list);
            return afterInline(lexInline(line, blk.content, .plain, out));
        },
        .paragraph => {
            return afterInline(lexInline(line, blk.content, .plain, out));
        },
    }
}

// ── tests ───────────────────────────────────────────────────────────────
fn scopesOf(line: []const u8, state: State, buf: []Scope) []Scope {
    var out: Spans = .{};
    _ = lexer.lexLine(.markdown, state, line, &out);
    var n: usize = 0;
    for (out.slice()) |sp| {
        buf[n] = sp.scope;
        n += 1;
    }
    return buf[0..n];
}

test "blocks" {
    try std.testing.expectEqual(BlockKind.heading, blockOf(0, "## Title").kind);
    try std.testing.expectEqual(@as(u8, 2), blockOf(0, "## Title").level);
    try std.testing.expectEqual(@as(u32, 3), blockOf(0, "## Title").content);
    try std.testing.expectEqual(BlockKind.paragraph, blockOf(0, "#hashtag").kind);
    try std.testing.expectEqual(BlockKind.list, blockOf(0, "  - item").kind);
    try std.testing.expectEqual(@as(u8, 2), blockOf(0, "  - item").indent);
    try std.testing.expectEqual(@as(u32, 4), blockOf(0, "  - item").content);
    try std.testing.expect(blockOf(0, "3. third").ordered);
    try std.testing.expectEqual(BlockKind.paragraph, blockOf(0, "3.14 is pi").kind);
    try std.testing.expectEqual(@as(u32, 6), blockOf(0, "- [x] done").content);
    try std.testing.expectEqual(BlockKind.quote, blockOf(0, "> > deep").kind);
    try std.testing.expectEqual(@as(u8, 2), blockOf(0, "> > deep").level);
    try std.testing.expectEqual(BlockKind.hr, blockOf(0, "- - -").kind);
    try std.testing.expectEqual(BlockKind.hr, blockOf(0, "***").kind);
    try std.testing.expectEqual(BlockKind.table_sep, blockOf(0, "|:--|---:|").kind);
    try std.testing.expectEqual(BlockKind.table_row, blockOf(state_table, "| a | b |").kind);
    try std.testing.expectEqual(BlockKind.table_row, blockOf(state_table, "no pipes, still a row").kind);
    try std.testing.expectEqual(BlockKind.blank, blockOf(state_table, "").kind);
    try std.testing.expectEqual(BlockKind.heading, blockOf(state_table, "# ends the table").kind);
    try std.testing.expectEqual(BlockKind.table_sep, blockOf(state_table, "|---|").kind);
    try std.testing.expectEqual(BlockKind.heading, blockOf(0, "<h2>Title</h2>").kind);
    try std.testing.expectEqual(@as(u8, 2), blockOf(0, "<h2>Title</h2>").level);
    try std.testing.expectEqual(@as(u32, 4), blockOf(0, "<h2>Title</h2>").content);
    try std.testing.expectEqual(BlockKind.hr, blockOf(0, "<hr/>").kind);
    try std.testing.expectEqual(BlockKind.list, blockOf(0, "<li> item").kind);
    try std.testing.expectEqual(@as(u32, 5), blockOf(0, "<li> item").content);
    try std.testing.expectEqual(BlockKind.quote, blockOf(0, "<blockquote>q</blockquote>").kind);
    try std.testing.expectEqual(BlockKind.html, blockOf(0, "<div align=\"center\">").kind);
    try std.testing.expectEqual(BlockKind.html, blockOf(0, "</details>").kind);
    try std.testing.expectEqual(BlockKind.html, blockOf(0, "<!-- note -->").kind);
    try std.testing.expectEqual(BlockKind.html, blockOf(state_html_comment, "# not a heading").kind);
    try std.testing.expectEqual(BlockKind.paragraph, blockOf(0, "<3 you").kind);
    try std.testing.expectEqual(BlockKind.fence_open, blockOf(0, "```zig").kind);
    try std.testing.expectEqual(BlockKind.code, blockOf(state_fence_tick, "~~~").kind);
    try std.testing.expectEqual(BlockKind.code, blockOf(state_fence_tick, "const x = 1;").kind);
    try std.testing.expectEqual(BlockKind.fence_close, blockOf(state_fence_tick, "```  ").kind);
    try std.testing.expectEqual(BlockKind.fence_open, blockOf(initial_state, "---").kind);
    try std.testing.expectEqual(BlockKind.hr, blockOf(0, "---").kind);
    try std.testing.expectEqual(BlockKind.blank, blockOf(0, "   ").kind);
}

test "task marks" {
    try std.testing.expectEqual(@as(usize, 3), taskMark(0, "- [ ] todo").?.at);
    try std.testing.expect(!taskMark(0, "- [ ] todo").?.done);
    try std.testing.expect(taskMark(0, "  * [X] done").?.done);
    try std.testing.expectEqual(@as(usize, 5), taskMark(0, "  * [X] done").?.at);
    try std.testing.expectEqual(@as(usize, 4), taskMark(0, "1. [x]").?.at);
    try std.testing.expect(taskMark(0, "- [link](x) not a task") == null);
    try std.testing.expect(taskMark(0, "[ ] no list marker") == null);
    try std.testing.expect(taskMark(state_fence_tick, "- [ ] inside a fence") == null);
}

test "fence and front matter states" {
    try std.testing.expectEqual(state_front_matter, lexLine(initial_state, "---", null));
    try std.testing.expectEqual(state_front_matter, lexLine(state_front_matter, "tags: [a]", null));
    try std.testing.expectEqual(state_normal, lexLine(state_front_matter, "---", null));
    try std.testing.expectEqual(state_normal, lexLine(initial_state, "# Not front matter", null));
    try std.testing.expectEqual(state_fence_tick, lexLine(0, "```sql", null));
    try std.testing.expectEqual(state_fence_tick, lexLine(state_fence_tick, "~~~", null));
    try std.testing.expectEqual(state_normal, lexLine(state_fence_tick, "```", null));
    try std.testing.expectEqual(state_fence_tilde, lexLine(0, "~~~", null));
    // Tables: the alignment row opens the table state, a blank line ends it.
    try std.testing.expectEqual(state_normal, lexLine(0, "| a | b |", null));
    try std.testing.expectEqual(state_table, lexLine(0, "|---|---|", null));
    try std.testing.expectEqual(state_table, lexLine(state_table, "| 1 | 2 |", null));
    try std.testing.expectEqual(state_normal, lexLine(state_table, "", null));
    try std.testing.expectEqual(state_normal, lexLine(state_table, "- list", null));
    // Comments span lines.
    try std.testing.expectEqual(state_html_comment, lexLine(0, "<!-- open", null));
    try std.testing.expectEqual(state_html_comment, lexLine(state_html_comment, "still", null));
    try std.testing.expectEqual(state_normal, lexLine(state_html_comment, "done --> text", null));
    try std.testing.expectEqual(state_normal, lexLine(0, "<!-- closed --> text", null));
    try std.testing.expectEqual(state_html_comment, lexLine(0, "| cell <!-- open", null));
}

test "inline html and entities" {
    var buf: [64]Scope = undefined;
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .marker, .strong, .marker, .plain }, scopesOf("a <b>b</b> c", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .emphasis, .marker }, scopesOf("<EM>x</EM>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .link, .marker }, scopesOf("<a href=\"https://x.y\">go</a>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .code, .marker }, scopesOf("<kbd>⌘K</kbd>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .strike, .marker }, scopesOf("<del>old</del>", 0, &buf));
    // A quoted ">" inside an attribute does not end the tag.
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .plain, .marker }, scopesOf("<span title=\"a>b\">t</span>", 0, &buf));
    // Block lines: the tag is a marker, the text keeps its Markdown.
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .plain, .marker, .strong, .marker }, scopesOf("<p align=\"center\">Hi **there**</p>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.marker}, scopesOf("<div>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .heading, .marker }, scopesOf("<h3>Head</h3>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .list, .plain, .marker }, scopesOf("<li>item</li>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .link, .marker }, scopesOf("<img src=\"a.png\" alt=\"Logo\">", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.marker}, scopesOf("<img src=\"a.png\">", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.comment}, scopesOf("<!-- hidden -->", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .comment }, scopesOf("text <!-- open", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .comment, .plain }, scopesOf("end --> shown", state_html_comment, &buf));
    // Autolinks and stray "<" stay what they were.
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .link, .marker }, scopesOf("<https://x.y>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .link, .marker }, scopesOf("<me@x.y>", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.plain}, scopesOf("a < b > c", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.plain}, scopesOf("<b", 0, &buf));
    // Entities.
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .escape, .plain }, scopesOf("a &amp; b", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .escape, .plain }, scopesOf("&#169;&#xA9; x", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.plain}, scopesOf("&bogus; & &#; &amp", 0, &buf));
    try std.testing.expectEqual(@as(u21, '&'), entityAt("&amp;", 0).?.cp);
    try std.testing.expectEqual(@as(usize, 5), entityAt("&amp;", 0).?.len);
    try std.testing.expectEqual(@as(u21, 0xA9), entityAt("&#xA9;", 0).?.cp);
    try std.testing.expectEqual(@as(u21, 0x2192), entityAt("&rarr;", 0).?.cp);
    try std.testing.expectEqual(@as(u21, 0xFFFD), entityAt("&#0;", 0).?.cp);
    try std.testing.expect(entityAt("&nope;", 0) == null);
    try std.testing.expect(isBreakTag("a<br>b", 1));
    try std.testing.expect(isBreakTag("<br />", 0));
    try std.testing.expect(!isBreakTag("<bra>", 0));
}

test "table cells and alignments" {
    var out: Spans = .{};
    var starts: [max_cols + 1]u32 = undefined;
    _ = lexer.lexLine(.markdown, state_table, "| a | b | c |", &out);
    try std.testing.expectEqual(@as(u8, 3), tableCells("| a | b | c |", &out, &starts));
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 8, 13 }, starts[0..4]);
    _ = lexer.lexLine(.markdown, state_table, "a | b", &out);
    try std.testing.expectEqual(@as(u8, 2), tableCells("a | b", &out, &starts));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 5 }, starts[0..3]);
    // Escaped and code-span pipes do not divide.
    _ = lexer.lexLine(.markdown, state_table, "| a \\| b | `c|d` |", &out);
    try std.testing.expectEqual(@as(u8, 2), tableCells("| a \\| b | `c|d` |", &out, &starts));
    // An empty cell in the middle counts; a trailing pipe does not.
    _ = lexer.lexLine(.markdown, state_table, "|  | x |", &out);
    try std.testing.expectEqual(@as(u8, 2), tableCells("|  | x |", &out, &starts));
    _ = lexer.lexLine(.markdown, state_table, "|", &out);
    try std.testing.expectEqual(@as(u8, 1), tableCells("|", &out, &starts));
    var al: [max_cols]Align = undefined;
    try std.testing.expectEqual(@as(u8, 3), tableAligns("|:--|:-:|--:|", &al));
    try std.testing.expectEqualSlices(Align, &.{ .left, .center, .right }, al[0..3]);
    try std.testing.expectEqual(@as(u8, 2), tableAligns("--- | ---:", &al));
    try std.testing.expectEqualSlices(Align, &.{ .left, .right }, al[0..2]);
}

test "inline spans" {
    var buf: [64]Scope = undefined;
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .heading }, scopesOf("# Hi", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .marker, .strong, .marker, .plain }, scopesOf("a **b** c", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .marker, .emphasis, .marker }, scopesOf("a _b_", 0, &buf));
    // Underscores inside words are not emphasis; "2 * 3" is not either.
    try std.testing.expectEqualSlices(Scope, &.{.plain}, scopesOf("snake_case_name and 2 * 3", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .marker, .code, .marker }, scopesOf("run `ls -la`", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .marker, .link, .marker, .plain }, scopesOf("see [docs](https://x.y) now", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .link, .marker }, scopesOf("[[Other note|alias]]", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .list, .plain }, scopesOf("- item", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .quote, .plain, .marker, .strike, .marker }, scopesOf("> a ~~b~~", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .link, .plain }, scopesOf("go to https://example.com/a.", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .plain, .property }, scopesOf("note #tag", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{ .marker, .plain }, scopesOf("\\*literal", 0, &buf));
    try std.testing.expectEqualSlices(Scope, &.{.code}, scopesOf("x = 1", state_fence_tick, &buf));
}

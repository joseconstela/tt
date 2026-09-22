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

/// How far a delimiter may look for its partner on the same line.
const max_lookahead: usize = 800;

pub const BlockKind = enum { paragraph, blank, heading, quote, list, fence_open, fence_close, code, hr, table_sep, front_matter, html };

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
/// text there (`.heading` inside a heading).
fn lexInline(line: []const u8, from: usize, base: Scope, out: ?*Spans) void {
    var i = from;
    var strong = false;
    var em = false;
    var strike = false;
    while (i < line.len) {
        const text_scope: Scope = if (strong) .strong else if (em) .emphasis else if (strike) .strike else base;
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
            else => {},
        }
        lexer.emit(out, i + 1, text_scope);
        i += 1;
    }
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
        .hr, .table_sep => {
            lexer.emit(out, line.len, .marker);
            return state_normal;
        },
        .html => {
            lexer.emit(out, line.len, .comment);
            return state_normal;
        },
        .heading => {
            lexer.emit(out, blk.content, .marker);
            // Optional closing #s.
            var end = line.len;
            while (end > blk.content and (line[end - 1] == ' ' or line[end - 1] == '#')) end -= 1;
            lexInline(line[0..end], blk.content, .heading, out);
            lexer.emit(out, line.len, .marker);
            return state_normal;
        },
        .quote => {
            lexer.emit(out, blk.content, .quote);
            // A quote may hold a list, a heading …: classify the rest.
            const inner = blockOf(state_normal, line[blk.content..]);
            switch (inner.kind) {
                .heading => {
                    lexer.emit(out, blk.content + inner.content, .marker);
                    lexInline(line, blk.content + inner.content, .heading, out);
                },
                .list => {
                    lexer.emit(out, blk.content + inner.content, .list);
                    lexInline(line, blk.content + inner.content, .plain, out);
                },
                else => lexInline(line, blk.content, .plain, out),
            }
            return state_normal;
        },
        .list => {
            lexer.emit(out, blk.content, .list);
            lexInline(line, blk.content, .plain, out);
            return state_normal;
        },
        .paragraph => {
            lexInline(line, blk.content, .plain, out);
            return state_normal;
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

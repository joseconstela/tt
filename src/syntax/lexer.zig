//! Syntax colouring, one line at a time.
//!
//! Every language is a function `lexLine(state, line, out) state'`: it reads
//! one line (no line ending) starting in `state`, appends spans that cover the
//! line exactly, and returns the state the *next* line starts in. States carry
//! the only thing a line cannot know on its own — "inside a block comment",
//! "inside a fenced code block" … — so a document keeps one byte per line and
//! can re-lex any line in isolation. Editors re-run the pass from an edited
//! line only until the states converge.
//!
//! Rules that keep this layer boring: byte oriented (bytes ≥ 0x80 are word
//! characters, UTF-8 is never decoded), every loop consumes at least one byte,
//! no allocation, no recursion, no regex. Unknown input is plain text.
const std = @import("std");
const filetype = @import("../filetype.zig");
const langs = @import("langs.zig");
const markdown = @import("markdown.zig");

pub const Language = filetype.Language;

/// What a span *is*; the theme maps it to a colour (and Markdown's visual
/// mode to a font). Kept small on purpose.
pub const Scope = enum(u8) {
    plain,
    comment,
    keyword,
    type,
    string,
    number,
    constant,
    operator,
    punct,
    escape,
    /// Keys, attributes, CSS properties.
    property,
    /// Function names and builtins.
    func,
    // CSV columns cycle through these.
    field_a,
    field_b,
    field_c,
    field_d,
    // Markdown.
    heading,
    strong,
    emphasis,
    strike,
    code,
    link,
    /// Syntax characters that Markdown's visual mode hides: `#`, `**`, `[`, `](url)` …
    marker,
    quote,
    /// A list bullet or number.
    list,
};

/// Where a line starts. 0 is "nothing special"; each language defines the rest.
pub const State = u8;

/// A run ending at byte `end` (exclusive) of the line.
pub const Span = struct { end: u32, scope: Scope };

/// Fixed-size span sink. Spans are contiguous from byte 0; when the buffer
/// fills up the rest of the line is plain, so a pathological line costs a
/// bounded amount of work per frame.
pub const Spans = struct {
    pub const max = 512;

    items: [max]Span = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn reset(self: *Spans) void {
        self.len = 0;
        self.truncated = false;
    }

    fn lastEnd(self: *const Spans) usize {
        return if (self.len == 0) 0 else self.items[self.len - 1].end;
    }

    /// Extends the covered range to `end` with `scope`. Adjacent spans of the
    /// same scope merge, so lexers can emit byte by byte if that is simplest.
    pub fn push(self: *Spans, end: usize, scope: Scope) void {
        const prev = self.lastEnd();
        if (end <= prev) return;
        if (self.len > 0 and self.items[self.len - 1].scope == scope) {
            self.items[self.len - 1].end = @intCast(end);
            return;
        }
        if (self.len == max) {
            self.truncated = true;
            return;
        }
        self.items[self.len] = .{ .end = @intCast(end), .scope = scope };
        self.len += 1;
    }

    /// Pads with plain text so the spans cover exactly `line_len` bytes.
    pub fn finish(self: *Spans, line_len: usize) void {
        const prev = self.lastEnd();
        if (prev >= line_len) {
            // A lexer that ran past the end (should not happen) is clamped.
            while (self.len > 0 and self.items[self.len - 1].end > line_len) {
                if (self.len >= 2 and self.items[self.len - 2].end >= line_len) {
                    self.len -= 1;
                } else {
                    self.items[self.len - 1].end = @intCast(line_len);
                }
            }
            return;
        }
        if (self.len == max) {
            self.items[max - 1].end = @intCast(line_len);
            return;
        }
        self.items[self.len] = .{ .end = @intCast(line_len), .scope = .plain };
        self.len += 1;
    }

    pub fn slice(self: *const Spans) []const Span {
        return self.items[0..self.len];
    }

    /// Scope at byte `offset`, walked with a monotonic cursor so a drawing
    /// loop asks once per glyph in O(1) amortised.
    pub fn scopeAt(self: *const Spans, cursor: *usize, offset: usize) Scope {
        while (cursor.* < self.len and self.items[cursor.*].end <= offset) cursor.* += 1;
        if (cursor.* >= self.len) return .plain;
        return self.items[cursor.*].scope;
    }
};

/// Appends to `out` when there is one; the state-only pass passes null.
pub inline fn emit(out: ?*Spans, end: usize, scope: Scope) void {
    if (out) |o| o.push(end, scope);
}

/// State the first line of a document starts in.
pub fn initialState(lang: Language) State {
    return if (lang == .markdown) markdown.initial_state else 0;
}

/// Lexes one line. `out` (if given) is reset first and covers the line
/// exactly on return.
pub fn lexLine(lang: Language, state: State, line: []const u8, out: ?*Spans) State {
    if (out) |o| o.reset();
    const next: State = switch (lang) {
        .plain => blk: {
            emit(out, line.len, .plain);
            break :blk 0;
        },
        .markdown => markdown.lexLine(state, line, out),
        else => langs.lexLine(lang, state, line, out),
    };
    if (out) |o| o.finish(line.len);
    return next;
}

// ── tests ───────────────────────────────────────────────────────────────
test "spans merge, pad and clamp" {
    var s: Spans = .{};
    s.push(3, .keyword);
    s.push(5, .keyword);
    s.push(5, .string); // empty: ignored
    s.push(9, .string);
    s.finish(12);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u32, 5), s.items[0].end);
    try std.testing.expectEqual(Scope.plain, s.items[2].scope);
    var cur: usize = 0;
    try std.testing.expectEqual(Scope.keyword, s.scopeAt(&cur, 0));
    try std.testing.expectEqual(Scope.string, s.scopeAt(&cur, 7));
    try std.testing.expectEqual(Scope.plain, s.scopeAt(&cur, 11));
    try std.testing.expectEqual(Scope.plain, s.scopeAt(&cur, 40));
}

fn checkCoverage(spans: *const Spans, line_len: usize) !void {
    var prev: u32 = 0;
    for (spans.slice()) |sp| {
        try std.testing.expect(sp.end > prev);
        prev = sp.end;
    }
    try std.testing.expectEqual(@as(u32, @intCast(line_len)), prev);
}

test "every language terminates and covers random lines exactly" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var buf: [200]u8 = undefined;
    var out: Spans = .{};
    inline for (std.meta.fields(Language)) |f| {
        const lang: Language = @enumFromInt(f.value);
        var state: State = 0;
        var round: usize = 0;
        while (round < 300) : (round += 1) {
            const len = rnd.uintLessThan(usize, buf.len);
            const line = buf[0..len];
            // Mix of printable ASCII (dense in syntax characters) and raw bytes.
            const syntax_chars = "#*_`[]()<>\"'/-=:;,.{}|\\$@!~^&%";
            for (line) |*b| {
                b.* = switch (rnd.uintLessThan(u8, 6)) {
                    0 => rnd.int(u8),
                    1 => syntax_chars[rnd.uintLessThan(usize, syntax_chars.len)],
                    2 => ' ',
                    else => 'a' + rnd.uintLessThan(u8, 26),
                };
            }
            state = lexLine(lang, state, line, &out);
            try checkCoverage(&out, len);
        }
        // Empty line, and a line of only high bytes.
        _ = lexLine(lang, 0, "", &out);
        try checkCoverage(&out, 0);
        @memset(&buf, 0xE9);
        _ = lexLine(lang, 0, &buf, &out);
        try checkCoverage(&out, buf.len);
    }
}

test "state-only pass matches the span pass" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [120]u8 = undefined;
    var out: Spans = .{};
    inline for (std.meta.fields(Language)) |f| {
        const lang: Language = @enumFromInt(f.value);
        var a: State = 0;
        var b: State = 0;
        var round: usize = 0;
        while (round < 200) : (round += 1) {
            const len = rnd.uintLessThan(usize, buf.len);
            const alphabet = "ab /*-#`\"'$<>=\\_[]()";
            for (buf[0..len]) |*ch| ch.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const line = buf[0..len];
            a = lexLine(lang, a, line, &out);
            b = lexLine(lang, b, line, null);
            try std.testing.expectEqual(a, b);
        }
    }
}

test {
    _ = langs;
    _ = markdown;
}

//! The languages. Most are a `Spec` — comment and string delimiters plus word
//! lists — run through one generic engine; a handful (CSV, diff, HTML, CSS,
//! YAML, INI) are small hand-written lexers because their structure is not
//! token-shaped. Adding a language is a spec here, an enum member plus label
//! in `filetype.zig`, and a golden test at the bottom.
//!
//! Generic engine states: 0 normal · 1 inside a block comment ·
//! 2+n inside the n-th (multi-line) string kind of the spec.
const std = @import("std");
const lexer = @import("lexer.zig");

const Scope = lexer.Scope;
const State = lexer.State;
const Spans = lexer.Spans;
const Language = lexer.Language;
const emit = lexer.emit;

const Str = []const u8;

const st_block: State = 1;
const st_string: State = 2;

// ── spec ────────────────────────────────────────────────────────────────
const StringSpec = struct {
    open: Str,
    /// Empty means "same as open".
    close: Str = "",
    /// 0 = no escapes.
    escape: u8 = '\\',
    multiline: bool = false,
    /// A doubled closer is a literal (SQL `'it''s'`).
    doubled: bool = false,
    /// A char literal: one code point or one escape, then the closer — else
    /// the opener is not a string at all (Rust lifetimes, stray quotes).
    char_literal: bool = false,
    scope: Scope = .string,
};

const Hook = *const fn (line: []const u8, i: usize, out: ?*Spans) ?usize;

const Spec = struct {
    line_comments: []const Str = &.{},
    /// A line comment counts only at the start of a word (shell: `a#b`, `${N}#1`).
    comment_boundary: bool = false,
    block_open: Str = "",
    block_close: Str = "",
    strings: []const StringSpec = &.{},
    /// Space-separated word lists.
    keywords: Str = "",
    types: Str = "",
    constants: Str = "",
    builtins: Str = "",
    case_insensitive: bool = false,
    /// Bytes that start a variable (`$NAME`, `${NAME}`, `@ivar`) → .property.
    var_prefixes: Str = "",
    /// `$(NAME)` is a variable too (make).
    var_paren: bool = false,
    /// `@name` (builtins, decorators, annotations) → this scope.
    at_prefix: ?Scope = null,
    /// `#name` is a directive (C preprocessor, Swift `#available`).
    hash_directives: bool = false,
    /// A string followed by `:` is a key (JSON).
    key_strings: bool = false,
    /// A line whose first token starts with this is a string to its end (zig `\\`).
    line_string_prefix: Str = "",
    /// `name!` is a macro (Rust).
    bang_macros: bool = false,
    /// `:name` is a symbol (Ruby).
    symbols: bool = false,
    operators: Str = "+-*/%=<>!&|^~?",
    puncts: Str = "()[]{},;.:",
    /// Tried first at every token start; returns the index after what it consumed.
    hook: ?Hook = null,
};

// ── word sets ───────────────────────────────────────────────────────────
fn countWords(comptime s: Str) usize {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    var in_word = false;
    for (s) |c| {
        if (c == ' ') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
    }
    return n;
}

fn splitWords(comptime s: Str) [countWords(s)]struct { []const u8 } {
    @setEvalBranchQuota(100_000);
    var out: [countWords(s)]struct { []const u8 } = undefined;
    var n: usize = 0;
    var start: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == ' ') {
            if (start) |st| {
                out[n] = .{s[st..i]};
                n += 1;
                start = null;
            }
        } else if (start == null) start = i;
    }
    if (start) |st| {
        out[n] = .{s[st..]};
        n += 1;
    }
    return out;
}

fn WordSet(comptime words: Str, comptime ci: bool) type {
    const Map = if (ci)
        std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase)
    else
        std.StaticStringMap(void);
    return struct {
        const list = splitWords(words);
        const map = Map.initComptime(list);
        fn has(s: []const u8) bool {
            if (list.len == 0) return false;
            return map.has(s);
        }
    };
}

// ── byte classes ────────────────────────────────────────────────────────
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
inline fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}
inline fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}
inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}
inline fn has(set: Str, c: u8) bool {
    return std.mem.indexOfScalar(u8, set, c) != null;
}
fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}
/// Only blanks before `i`.
fn atLineStart(line: []const u8, i: usize) bool {
    for (line[0..i]) |c| if (!isSpace(c)) return false;
    return true;
}
fn skipSpaces(line: []const u8, from: usize) usize {
    var j = from;
    while (j < line.len and isSpace(line[j])) j += 1;
    return j;
}
fn wordEnd(line: []const u8, from: usize) usize {
    var j = from;
    while (j < line.len and isWordByte(line[j])) j += 1;
    return j;
}

fn scanNumber(line: []const u8, start: usize) usize {
    var j = start;
    if (line[j] == '0' and j + 1 < line.len and has("xXbBoO", line[j + 1])) {
        j += 2;
        while (j < line.len and (std.ascii.isHex(line[j]) or line[j] == '_')) j += 1;
    } else {
        while (j < line.len and (isDigit(line[j]) or line[j] == '_')) j += 1;
        if (j + 1 < line.len and line[j] == '.' and isDigit(line[j + 1])) {
            j += 1;
            while (j < line.len and (isDigit(line[j]) or line[j] == '_')) j += 1;
        }
        if (j < line.len and (line[j] == 'e' or line[j] == 'E')) {
            var k = j + 1;
            if (k < line.len and (line[k] == '+' or line[k] == '-')) k += 1;
            if (k < line.len and isDigit(line[k])) {
                j = k;
                while (j < line.len and isDigit(line[j])) j += 1;
            }
        }
    }
    // Suffixes: 10px, 3u8, 1L, 2n …
    return wordEnd(line, j);
}

const Scan = struct { end: usize, closed: bool, ok: bool };

/// Scans a string body from `from` (just after the opener).
fn scanString(line: []const u8, from: usize, comptime s: StringSpec) Scan {
    const close = if (s.close.len == 0) s.open else s.close;
    if (s.char_literal) return scanChar(line, from, close, s.escape);
    var j = from;
    while (j < line.len) {
        if (s.escape != 0 and line[j] == s.escape) {
            j = @min(line.len, j + 2);
            continue;
        }
        if (startsWith(line[j..], close)) {
            if (s.doubled and startsWith(line[j + close.len ..], close)) {
                j += 2 * close.len;
                continue;
            }
            return .{ .end = j + close.len, .closed = true, .ok = true };
        }
        j += 1;
    }
    return .{ .end = line.len, .closed = false, .ok = true };
}

/// `'a'`, `'\n'`, `'\u{1F600}'`, `'é'`: exactly one code point or one escape.
fn scanChar(line: []const u8, from: usize, close: Str, escape: u8) Scan {
    const not_a_char: Scan = .{ .end = from, .closed = false, .ok = false };
    if (from >= line.len) return not_a_char;
    var j = from;
    if (escape != 0 and line[j] == escape) {
        j += 1;
        // Up to 10 bytes of escape body (`\u{10FFFF}`), never a closer inside.
        const limit = @min(line.len, from + 12);
        while (j < limit and !startsWith(line[j..], close)) j += 1;
        if (j == from + 1) return not_a_char;
    } else {
        const cp_len: usize = if (line[j] < 0x80) 1 else if (line[j] & 0xE0 == 0xC0) 2 else if (line[j] & 0xF0 == 0xE0) 3 else 4;
        if (startsWith(line[j..], close)) return not_a_char; // ''
        j = @min(line.len, j + cp_len);
    }
    if (!startsWith(line[j..], close)) return not_a_char;
    return .{ .end = j + close.len, .closed = true, .ok = true };
}

fn findClose(line: []const u8, from: usize, close: Str) ?usize {
    if (from >= line.len) return null;
    const at = std.mem.indexOfPos(u8, line, from, close) orelse return null;
    return at + close.len;
}

/// `"key":` — the string that just ended at `end` is followed by a colon.
fn isKey(line: []const u8, end: usize) bool {
    const j = skipSpaces(line, end);
    return j < line.len and line[j] == ':';
}

// ── the generic engine ──────────────────────────────────────────────────
fn lexGeneric(comptime spec: Spec, state_in: State, line: []const u8, out: ?*Spans) State {
    const KW = WordSet(spec.keywords, spec.case_insensitive);
    const TY = WordSet(spec.types, spec.case_insensitive);
    const CO = WordSet(spec.constants, spec.case_insensitive);
    const BI = WordSet(spec.builtins, spec.case_insensitive);

    var i: usize = 0;
    var state = state_in;
    if (state >= st_string and state - st_string >= spec.strings.len) state = 0;

    // Resume what the previous line left open.
    if (state == st_block) {
        if (spec.block_close.len > 0) {
            if (findClose(line, 0, spec.block_close)) |end| {
                emit(out, end, .comment);
                i = end;
            } else {
                emit(out, line.len, .comment);
                return st_block;
            }
        }
    } else if (state >= st_string) {
        const n = state - st_string;
        inline for (spec.strings, 0..) |s, idx| {
            if (idx == n) {
                const r = scanString(line, 0, s);
                emit(out, r.end, s.scope);
                i = r.end;
                if (!r.closed) return state;
            }
        }
    }

    while (i < line.len) {
        const ch = line[i];
        if (isSpace(ch)) {
            i = skipSpaces(line, i);
            emit(out, i, .plain);
            continue;
        }
        if (spec.hook) |hook| {
            if (hook(line, i, out)) |ni| {
                std.debug.assert(ni > i and ni <= line.len);
                i = ni;
                continue;
            }
        }
        if (spec.line_string_prefix.len > 0 and startsWith(line[i..], spec.line_string_prefix) and atLineStart(line, i)) {
            emit(out, line.len, .string);
            return 0;
        }
        if (spec.block_open.len > 0 and startsWith(line[i..], spec.block_open)) {
            if (findClose(line, i + spec.block_open.len, spec.block_close)) |end| {
                emit(out, end, .comment);
                i = end;
                continue;
            }
            emit(out, line.len, .comment);
            return st_block;
        }
        inline for (spec.line_comments) |lc| {
            if (startsWith(line[i..], lc) and (!spec.comment_boundary or i == 0 or has(" \t;|&()", line[i - 1]))) {
                emit(out, line.len, .comment);
                return 0;
            }
        }
        var matched = false;
        inline for (spec.strings, 0..) |s, idx| {
            if (!matched and startsWith(line[i..], s.open)) {
                const r = scanString(line, i + s.open.len, s);
                if (r.ok) {
                    matched = true;
                    const scope: Scope = if (spec.key_strings and r.closed and isKey(line, r.end)) .property else s.scope;
                    emit(out, r.end, scope);
                    i = r.end;
                    if (!r.closed and s.multiline) return st_string + @as(State, idx);
                }
            }
        }
        if (matched) continue;
        if (isDigit(ch) or (ch == '.' and i + 1 < line.len and isDigit(line[i + 1]) and (i == 0 or !isWordByte(line[i - 1])))) {
            const end = scanNumber(line, i);
            emit(out, end, .number);
            i = end;
            continue;
        }
        if (isWordStart(ch)) {
            var j = wordEnd(line, i + 1);
            const word = line[i..j];
            var scope: Scope = .plain;
            if (CO.has(word)) {
                scope = .constant;
            } else if (KW.has(word)) {
                scope = .keyword;
            } else if (TY.has(word)) {
                scope = .type;
            } else if (BI.has(word)) {
                scope = .func;
            }
            if (spec.bang_macros and j < line.len and line[j] == '!' and (j + 1 >= line.len or line[j + 1] != '=')) {
                j += 1;
                scope = .func;
            }
            emit(out, j, scope);
            i = j;
            continue;
        }
        if (spec.var_prefixes.len > 0 and has(spec.var_prefixes, ch)) {
            var j = i + 1;
            while (j < line.len and has(spec.var_prefixes, line[j])) j += 1; // @@class_var
            if (j < line.len and (line[j] == '{' or (spec.var_paren and line[j] == '('))) {
                const closer: u8 = if (line[j] == '{') '}' else ')';
                j = if (std.mem.indexOfScalarPos(u8, line, j, closer)) |k| k + 1 else line.len;
                emit(out, j, .property);
                i = j;
                continue;
            }
            if (j < line.len and isWordByte(line[j])) {
                emit(out, wordEnd(line, j), .property);
                i = wordEnd(line, j);
                continue;
            }
            if (ch == '$' and j < line.len and has("@*#?!-<^+%", line[j])) { // $? $# … and make's $@ $< $^
                emit(out, j + 1, .property);
                i = j + 1;
                continue;
            }
            emit(out, j, .operator);
            i = j;
            continue;
        }
        if (spec.at_prefix) |sc| {
            if (ch == '@' and i + 1 < line.len and isWordStart(line[i + 1])) {
                const j = wordEnd(line, i + 1);
                emit(out, j, sc);
                i = j;
                continue;
            }
        }
        if (spec.hash_directives and ch == '#') {
            var j = skipSpaces(line, i + 1);
            if (j < line.len and isWordStart(line[j])) {
                const name_start = j;
                j = wordEnd(line, j);
                emit(out, j, .keyword);
                i = j;
                // #include <stdio.h> / #import <Foundation/Foundation.h>
                const name = line[name_start..j];
                if (std.mem.eql(u8, name, "include") or std.mem.eql(u8, name, "import")) {
                    const k = skipSpaces(line, j);
                    if (k < line.len and line[k] == '<') {
                        emit(out, k, .plain);
                        const end = if (std.mem.indexOfScalarPos(u8, line, k, '>')) |g| g + 1 else line.len;
                        emit(out, end, .string);
                        i = end;
                    }
                }
                continue;
            }
        }
        if (spec.symbols and ch == ':' and i + 1 < line.len and isWordStart(line[i + 1]) and (i == 0 or line[i - 1] != ':')) {
            const j = wordEnd(line, i + 1);
            emit(out, j, .constant);
            i = j;
            continue;
        }
        if (has(spec.operators, ch)) {
            var j = i + 1;
            while (j < line.len and has(spec.operators, line[j])) j += 1;
            emit(out, j, .operator);
            i = j;
            continue;
        }
        if (has(spec.puncts, ch)) {
            emit(out, i + 1, .punct);
            i += 1;
            continue;
        }
        emit(out, i + 1, .plain);
        i += 1;
    }
    return 0;
}

// ── specs ───────────────────────────────────────────────────────────────
const sql_spec: Spec = .{
    .line_comments = &.{"--"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "'", .escape = 0, .doubled = true },
        .{ .open = "$$", .escape = 0, .multiline = true },
        .{ .open = "\"", .escape = 0, .doubled = true, .scope = .property },
        .{ .open = "`", .escape = 0, .scope = .property },
    },
    .case_insensitive = true,
    .keywords = "select from where insert into values update set delete create table view index drop alter add column " ++
        "primary key foreign references unique not null default check constraint if exists as on join inner left right " ++
        "full outer cross using and or in is between like ilike similar order by group having limit offset union all " ++
        "distinct case when then else end begin commit rollback transaction with recursive returning cascade truncate " ++
        "grant revoke explain analyze vacuum replace temp temporary schema database except intersect asc desc nulls " ++
        "first last over partition window rows range preceding following current row fetch next only lateral natural " ++
        "for share nowait lock trigger function procedure returns language declare cursor loop while do handler " ++
        "materialized sequence type domain extension owner to rename before after each execute conflict nothing " ++
        "any some exists collate cast",
    .types = "int integer smallint bigint serial bigserial numeric decimal real double precision float boolean bool " ++
        "text varchar char character varying date time timestamp timestamptz interval json jsonb uuid bytea blob " ++
        "array money tinyint mediumint datetime year enum bit binary varbinary",
    .constants = "true false null unknown",
    .builtins = "count sum avg min max coalesce nullif now current_timestamp current_date current_time length lower " ++
        "upper substring substr trim ltrim rtrim concat abs round floor ceil ceiling greatest least array_agg string_agg " ++
        "json_agg row_number rank dense_rank date_trunc extract to_char to_date generate_series unnest position " ++
        "replace left right split_part md5 random age",
    .operators = "+-*/%=<>!|^~:",
    .puncts = "()[]{},;.",
};

const json_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{.{ .open = "\"" }},
    .key_strings = true,
    .constants = "true false null NaN Infinity",
    .operators = "-+",
    .puncts = "{}[],:",
};

fn zigHook(line: []const u8, i: usize, out: ?*Spans) ?usize {
    // u8, i32, u21 … : an int type of any width.
    if ((line[i] == 'u' or line[i] == 'i') and i + 1 < line.len and isDigit(line[i + 1]) and (i == 0 or !isWordByte(line[i - 1]))) {
        var j = i + 1;
        while (j < line.len and isDigit(line[j])) j += 1;
        if (j >= line.len or !isWordByte(line[j])) {
            emit(out, j, .type);
            return j;
        }
    }
    return null;
}

const zig_spec: Spec = .{
    .line_comments = &.{"//"},
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'", .char_literal = true },
    },
    .line_string_prefix = "\\\\",
    .keywords = "fn pub const var if else while for switch return break continue defer errdefer try catch orelse " ++
        "unreachable struct enum union error comptime inline noinline export extern packed align linksection callconv " ++
        "threadlocal test and or async await suspend resume nosuspend usingnamespace anytype volatile allowzero " ++
        "addrspace asm opaque",
    .types = "void bool usize isize f16 f32 f64 f80 f128 c_int c_uint c_long c_ulong c_short c_ushort c_longlong " ++
        "c_ulonglong c_char c_longdouble anyopaque anyerror noreturn type comptime_int comptime_float",
    .constants = "true false null undefined",
    .at_prefix = .func,
    .hook = zigHook,
};

const shell_spec: Spec = .{
    .line_comments = &.{"#"},
    .comment_boundary = true,
    .strings = &.{
        .{ .open = "\"", .multiline = true },
        .{ .open = "'", .escape = 0, .multiline = true },
    },
    .keywords = "if then fi for do done case esac function local export return while until elif else in select " ++
        "declare readonly typeset time coproc",
    .builtins = "echo cd source alias unalias unset set shift exit exec eval printf read test true false pwd pushd " ++
        "popd trap wait kill jobs fg bg let command builtin type hash umask ulimit sudo",
    .var_prefixes = "$",
    .operators = "|&;<>!=",
    .puncts = "()[]{}",
};

const python_spec: Spec = .{
    .line_comments = &.{"#"},
    .strings = &.{
        .{ .open = "\"\"\"", .multiline = true },
        .{ .open = "'''", .multiline = true },
        .{ .open = "\"" },
        .{ .open = "'" },
    },
    .keywords = "def class return if elif else for while in not and or is import from as with pass break continue " ++
        "lambda yield try except finally raise global nonlocal assert del async await match case",
    .types = "int str float list dict set tuple bool bytes object complex frozenset bytearray",
    .constants = "True False None Ellipsis NotImplemented",
    .builtins = "print len range open enumerate zip map filter sorted reversed sum min max abs isinstance issubclass " ++
        "type super input any all iter next round format repr hasattr getattr setattr delattr id ord chr hex oct bin " ++
        "callable vars dir help exit quit",
    .at_prefix = .func,
};

const js_keywords = "var let const function return if else for while do break continue new delete typeof instanceof " ++
    "in of class extends super this import export default from as async await yield try catch finally throw switch " ++
    "case void with debugger static get set";
const js_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'" },
        .{ .open = "`", .multiline = true },
    },
    .keywords = js_keywords,
    .constants = "true false null undefined NaN Infinity",
    .builtins = "console Math JSON Object Array Promise Date Number String Boolean Map Set WeakMap Symbol Error " ++
        "RegExp parseInt parseFloat setTimeout setInterval clearTimeout require document window fetch globalThis " ++
        "process module exports",
    .at_prefix = .func,
};
const ts_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = js_spec.strings,
    .keywords = js_keywords ++ " interface type enum implements declare namespace module abstract readonly public " ++
        "private protected keyof infer satisfies is asserts override",
    .types = "string number boolean any void never unknown object symbol bigint",
    .constants = js_spec.constants,
    .builtins = js_spec.builtins,
    .at_prefix = .func,
};

const c_keywords = "auto break case const continue default do else enum extern for goto if inline register " ++
    "restrict return sizeof static struct switch typedef union volatile while _Bool _Complex _Atomic _Static_assert " ++
    "_Thread_local _Alignas _Alignof _Generic _Noreturn";
const c_types = "int char short long unsigned signed float double void size_t ssize_t ptrdiff_t intptr_t uintptr_t " ++
    "int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t bool wchar_t FILE";
const c_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'", .char_literal = true },
    },
    .keywords = c_keywords,
    .types = c_types,
    .constants = "NULL true false EOF",
    .hash_directives = true,
};
const cpp_spec: Spec = .{
    .line_comments = c_spec.line_comments,
    .block_open = "/*",
    .block_close = "*/",
    .strings = c_spec.strings,
    .keywords = c_keywords ++ " class namespace template typename using new delete this public private protected " ++
        "virtual override final explicit friend operator try catch throw constexpr consteval constinit static_cast " ++
        "dynamic_cast reinterpret_cast const_cast noexcept mutable decltype concept requires co_await co_return " ++
        "co_yield export import module and or not",
    .types = c_types ++ " string vector map set unordered_map unordered_set array pair tuple optional variant " ++
        "shared_ptr unique_ptr weak_ptr string_view",
    .constants = "NULL nullptr true false",
    .hash_directives = true,
};
const objc_spec: Spec = .{
    .line_comments = c_spec.line_comments,
    .block_open = "/*",
    .block_close = "*/",
    .strings = c_spec.strings,
    .keywords = c_keywords ++ " self super in out inout bycopy byref oneway",
    .types = c_types ++ " id BOOL SEL IMP Class instancetype NSString NSInteger NSUInteger CGFloat NSArray " ++
        "NSDictionary NSObject NSNumber NSError CGRect CGPoint CGSize",
    .constants = "NULL nil Nil YES NO true false",
    .at_prefix = .keyword,
    .hash_directives = true,
};

const rust_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"", .multiline = true },
        .{ .open = "'", .char_literal = true },
    },
    .keywords = "as break const continue crate else enum extern fn for if impl in let loop match mod move mut pub " ++
        "ref return self Self static struct super trait type unsafe use where while async await dyn union macro_rules",
    .types = "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result " ++
        "Box Rc Arc HashMap HashSet BTreeMap Cell RefCell Mutex",
    .constants = "true false None Some Ok Err",
    .bang_macros = true,
};

const go_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "`", .escape = 0, .multiline = true },
        .{ .open = "'", .char_literal = true },
    },
    .keywords = "break case chan const continue default defer else fallthrough for func go goto if import " ++
        "interface map package range return select struct switch type var",
    .types = "bool byte rune string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 " ++
        "float64 complex64 complex128 error any",
    .constants = "true false nil iota",
    .builtins = "append cap close copy delete len make new panic print println recover min max clear",
};

const java_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"\"\"", .multiline = true },
        .{ .open = "\"" },
        .{ .open = "'", .char_literal = true },
    },
    .keywords = "abstract assert break case catch class const continue default do else enum extends final finally " ++
        "for goto if implements import instanceof interface native new package private protected public return " ++
        "static strictfp super switch synchronized this throw throws transient try void volatile while var record " ++
        "sealed permits yield",
    .types = "boolean byte char short int long float double String Object List Map Set Integer Long Double " ++
        "Boolean Character Optional",
    .constants = "true false null",
    .at_prefix = .func,
};

const swift_spec: Spec = .{
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"\"\"", .multiline = true },
        .{ .open = "\"" },
    },
    .keywords = "let var func class struct enum protocol extension import if else guard for while repeat in " ++
        "return switch case default break continue fallthrough where as is try catch throw throws rethrows do " ++
        "defer init deinit self Self super static final override public private fileprivate internal open " ++
        "mutating inout some any async await actor typealias associatedtype subscript operator lazy weak " ++
        "unowned optional required convenience indirect nonisolated",
    .types = "Int Double Float String Bool Character Array Dictionary Set Optional Any AnyObject Void UInt Int8 " ++
        "Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 CGFloat Error Never Result",
    .constants = "true false nil",
    .at_prefix = .keyword,
    .hash_directives = true,
};

const ruby_spec: Spec = .{
    .line_comments = &.{"#"},
    .comment_boundary = true,
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'", .escape = 0 },
    },
    .keywords = "def end if elsif else unless while until for in do begin rescue ensure return yield class module " ++
        "self super and or not then case when break next redo retry alias undef defined? require require_relative " ++
        "include extend private public protected raise lambda proc",
    .constants = "true false nil",
    .builtins = "puts print p pp attr_accessor attr_reader attr_writer new each map select reject reduce " ++
        "inject times loop",
    .var_prefixes = "@$",
    .symbols = true,
};

fn phpHook(line: []const u8, i: usize, out: ?*Spans) ?usize {
    if (startsWith(line[i..], "<?php") or startsWith(line[i..], "<?=")) {
        const end = if (line[i + 2] == '=') i + 3 else i + 5;
        emit(out, end, .keyword);
        return end;
    }
    if (startsWith(line[i..], "?>")) {
        emit(out, i + 2, .keyword);
        return i + 2;
    }
    return null;
}

const php_spec: Spec = .{
    .line_comments = &.{ "//", "#" },
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{
        .{ .open = "\"", .multiline = true },
        .{ .open = "'", .multiline = true },
    },
    .keywords = "abstract and array as break callable case catch class clone const continue declare default do " ++
        "echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for " ++
        "foreach function global goto if implements include include_once instanceof insteadof interface isset " ++
        "list match namespace new or print private protected public readonly require require_once return static " ++
        "switch throw trait try unset use var while xor yield enum",
    .types = "int float string bool array object mixed void iterable callable self parent never",
    .constants = "true false null TRUE FALSE NULL",
    .var_prefixes = "$",
    .hook = phpHook,
};

fn tomlHook(line: []const u8, i: usize, out: ?*Spans) ?usize {
    if (!atLineStart(line, i)) return null;
    if (line[i] == '[') {
        const end = if (std.mem.lastIndexOfScalar(u8, line, ']')) |k| k + 1 else line.len;
        emit(out, end, .keyword);
        return end;
    }
    // bare or dotted key before `=`
    if (isWordByte(line[i]) or line[i] == '-') {
        var j = i;
        while (j < line.len and (isWordByte(line[j]) or line[j] == '-' or line[j] == '.')) j += 1;
        if (skipSpaces(line, j) < line.len and line[skipSpaces(line, j)] == '=') {
            emit(out, j, .property);
            return j;
        }
    }
    return null;
}

const toml_spec: Spec = .{
    .line_comments = &.{"#"},
    .strings = &.{
        .{ .open = "\"\"\"", .multiline = true },
        .{ .open = "'''", .escape = 0, .multiline = true },
        .{ .open = "\"" },
        .{ .open = "'", .escape = 0 },
    },
    .constants = "true false inf nan",
    .operators = "=+-",
    .puncts = "[]{},.",
    .hook = tomlHook,
};

fn makeHook(line: []const u8, i: usize, out: ?*Spans) ?usize {
    if (i != 0 or line[0] == '\t') return null;
    // The first token of a line: `target:` or `VAR =` / `:=` / `?=` / `+=`.
    var j: usize = 0;
    while (j < line.len and !has(" \t:=#$?+!", line[j])) j += 1;
    if (j == 0) return null;
    const k = skipSpaces(line, j);
    if (k < line.len and line[k] == ':' and (k + 1 >= line.len or line[k + 1] != '=')) {
        emit(out, j, if (line[0] == '.') .keyword else .func);
        return j;
    }
    if (k < line.len and (line[k] == '=' or (k + 1 < line.len and has(":?+!", line[k]) and line[k + 1] == '='))) {
        emit(out, j, .property);
        return j;
    }
    return null;
}

const make_spec: Spec = .{
    .line_comments = &.{"#"},
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'", .escape = 0 },
    },
    .keywords = "ifeq ifneq ifdef ifndef else endif include sinclude define endef export unexport override vpath",
    .builtins = "wildcard patsubst subst shell foreach call addprefix addsuffix filter filter-out sort dir notdir " ++
        "basename suffix join word words firstword lastword strip if or and eval value origin error warning info",
    .var_prefixes = "$",
    .var_paren = true,
    .operators = "=:?+|<>;",
    .puncts = "()[]{},",
    .hook = makeHook,
};

const dockerfile_spec: Spec = .{
    .line_comments = &.{"#"},
    .comment_boundary = true,
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'", .escape = 0 },
    },
    .case_insensitive = true,
    .keywords = "from run cmd label expose env add copy entrypoint volume user workdir arg onbuild stopsignal " ++
        "healthcheck shell maintainer as",
    .var_prefixes = "$",
    .operators = "|&;<>=",
    .puncts = "[]{},",
};

const lua_spec: Spec = .{
    .line_comments = &.{"--"},
    .block_open = "--[[",
    .block_close = "]]",
    .strings = &.{
        .{ .open = "\"" },
        .{ .open = "'" },
        .{ .open = "[[", .close = "]]", .escape = 0, .multiline = true },
    },
    .keywords = "and break do else elseif end for function goto if in local not or repeat return then until while",
    .constants = "nil true false",
    .builtins = "print pairs ipairs type tostring tonumber require setmetatable getmetatable table string math " ++
        "io os error pcall xpcall assert select next unpack rawget rawset rawequal coroutine",
};

// ── custom lexers ───────────────────────────────────────────────────────
fn lexCsv(line: []const u8, out: ?*Spans) State {
    // The delimiter is whichever of , \t ; appears most outside quotes.
    var counts = [3]usize{ 0, 0, 0 };
    var quoted = false;
    for (line) |c| {
        if (c == '"') quoted = !quoted;
        if (quoted) continue;
        switch (c) {
            ',' => counts[0] += 1,
            '\t' => counts[1] += 1,
            ';' => counts[2] += 1,
            else => {},
        }
    }
    var best: usize = 0;
    for (counts, 0..) |n, k| if (n > counts[best]) {
        best = k;
    };
    if (counts[best] == 0) {
        emit(out, line.len, .plain);
        return 0;
    }
    const delim: u8 = ([_]u8{ ',', '\t', ';' })[best];
    const cycle = [_]Scope{ .field_a, .field_b, .field_c, .field_d };
    var field: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == delim) {
            emit(out, i + 1, .punct);
            i += 1;
            field += 1;
            continue;
        }
        var j = i;
        if (line[j] == '"') {
            j += 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '"') {
                    if (j + 1 < line.len and line[j + 1] == '"') {
                        j += 1;
                        continue;
                    }
                    j += 1;
                    break;
                }
            }
        }
        while (j < line.len and line[j] != delim) j += 1;
        emit(out, j, cycle[field % cycle.len]);
        i = j;
    }
    return 0;
}

fn lexDiff(line: []const u8, out: ?*Spans) State {
    if (startsWith(line, "@@")) {
        // `@@ -1,3 +1,4 @@ context`: the hunk range as number, the rest plain.
        const end = if (std.mem.indexOfPos(u8, line, 2, "@@")) |k| k + 2 else line.len;
        emit(out, end, .number);
        emit(out, line.len, .plain);
        return 0;
    }
    const headers = [_]Str{ "+++ ", "--- ", "diff ", "index ", "rename ", "similarity ", "new file", "deleted file" };
    var scope: Scope = .plain;
    for (headers) |h| {
        if (startsWith(line, h)) scope = .comment;
    }
    if (scope == .plain and startsWith(line, "+")) scope = .string;
    if (scope == .plain and startsWith(line, "-")) scope = .constant;
    emit(out, line.len, scope);
    return 0;
}

const html_text: State = 0;
const html_tag: State = 1;
const html_comment: State = 2;
const html_dq: State = 3;
const html_sq: State = 4;

fn lexMarkup(state_in: State, line: []const u8, out: ?*Spans) State {
    var state = if (state_in > html_sq) html_text else state_in;
    var i: usize = 0;
    while (i < line.len) {
        switch (state) {
            html_comment => {
                if (findClose(line, i, "-->")) |end| {
                    emit(out, end, .comment);
                    i = end;
                    state = html_text;
                } else {
                    emit(out, line.len, .comment);
                    return html_comment;
                }
            },
            html_dq, html_sq => {
                const q: u8 = if (state == html_dq) '"' else '\'';
                if (std.mem.indexOfScalarPos(u8, line, i, q)) |k| {
                    emit(out, k + 1, .string);
                    i = k + 1;
                    state = html_tag;
                } else {
                    emit(out, line.len, .string);
                    return state;
                }
            },
            html_tag => {
                const ch = line[i];
                if (isSpace(ch)) {
                    i = skipSpaces(line, i);
                    emit(out, i, .plain);
                } else if (ch == '>') {
                    emit(out, i + 1, .punct);
                    i += 1;
                    state = html_text;
                } else if (ch == '/' or ch == '?') {
                    emit(out, i + 1, .punct);
                    i += 1;
                } else if (ch == '=') {
                    emit(out, i + 1, .operator);
                    i += 1;
                } else if (ch == '"' or ch == '\'') {
                    state = if (ch == '"') html_dq else html_sq;
                    emit(out, i + 1, .string);
                    i += 1;
                } else if (isWordByte(ch) or ch == '-' or ch == ':' or ch == '.') {
                    var j = i + 1;
                    while (j < line.len and (isWordByte(line[j]) or line[j] == '-' or line[j] == ':' or line[j] == '.')) j += 1;
                    emit(out, j, .property);
                    i = j;
                } else {
                    emit(out, i + 1, .plain);
                    i += 1;
                }
            },
            else => { // text
                if (line[i] == '<') {
                    if (startsWith(line[i..], "<!--")) {
                        if (findClose(line, i + 4, "-->")) |end| {
                            emit(out, end, .comment);
                            i = end;
                        } else {
                            emit(out, line.len, .comment);
                            return html_comment;
                        }
                        continue;
                    }
                    var j = i + 1;
                    while (j < line.len and (line[j] == '/' or line[j] == '!' or line[j] == '?')) j += 1;
                    emit(out, j, .punct);
                    if (j < line.len and (isWordStart(line[j]) or line[j] == '[')) {
                        var k = j;
                        while (k < line.len and (isWordByte(line[k]) or line[k] == '-' or line[k] == ':' or line[k] == '[')) k += 1;
                        emit(out, k, .keyword);
                        j = k;
                    }
                    i = j;
                    state = html_tag;
                } else if (line[i] == '&') {
                    // &amp; &#x27;
                    var j = i + 1;
                    while (j < line.len and (isWordByte(line[j]) or line[j] == '#')) j += 1;
                    if (j < line.len and line[j] == ';' and j > i + 1) {
                        emit(out, j + 1, .escape);
                        i = j + 1;
                    } else {
                        emit(out, i + 1, .plain);
                        i += 1;
                    }
                } else {
                    var j = i + 1;
                    while (j < line.len and line[j] != '<' and line[j] != '&') j += 1;
                    emit(out, j, .plain);
                    i = j;
                }
            },
        }
    }
    return state;
}

const css_comment: u8 = 0x80;

fn lexCss(state_in: State, line: []const u8, out: ?*Spans) State {
    var depth: u8 = state_in & 0x7f;
    var i: usize = 0;
    if (state_in & css_comment != 0) {
        if (findClose(line, 0, "*/")) |end| {
            emit(out, end, .comment);
            i = end;
        } else {
            emit(out, line.len, .comment);
            return state_in;
        }
    }
    while (i < line.len) {
        const ch = line[i];
        if (isSpace(ch)) {
            i = skipSpaces(line, i);
            emit(out, i, .plain);
        } else if (startsWith(line[i..], "/*")) {
            if (findClose(line, i + 2, "*/")) |end| {
                emit(out, end, .comment);
                i = end;
            } else {
                emit(out, line.len, .comment);
                return depth | css_comment;
            }
        } else if (ch == '"' or ch == '\'') {
            var j = i + 1;
            while (j < line.len and line[j] != ch) : (j += 1) {
                if (line[j] == '\\') j += 1;
            }
            j = @min(line.len, j + 1);
            emit(out, j, .string);
            i = j;
        } else if (ch == '{') {
            depth +|= 1;
            if (depth > 0x7f) depth = 0x7f;
            emit(out, i + 1, .punct);
            i += 1;
        } else if (ch == '}') {
            depth -|= 1;
            emit(out, i + 1, .punct);
            i += 1;
        } else if (ch == '@' or ch == '!') {
            const j = cssWordEnd(line, i + 1);
            emit(out, j, if (j > i + 1) .keyword else .plain);
            i = j;
        } else if (ch == '#' and depth > 0) {
            const j = cssWordEnd(line, i + 1);
            emit(out, j, .constant);
            i = j;
        } else if (isDigit(ch) or (ch == '.' and i + 1 < line.len and isDigit(line[i + 1])) or
            (ch == '-' and i + 1 < line.len and isDigit(line[i + 1])))
        {
            var j = scanNumber(line, if (ch == '-') i + 1 else i);
            if (j < line.len and line[j] == '%') j += 1;
            emit(out, j, .number);
            i = j;
        } else if (isWordStart(ch) or ch == '-') {
            const j = cssWordEnd(line, i + 1);
            const k = skipSpaces(line, j);
            const is_prop = depth > 0 and k < line.len and line[k] == ':';
            emit(out, j, if (is_prop) .property else .plain);
            i = j;
        } else if (has(";,:>+~*=", ch)) {
            emit(out, i + 1, .punct);
            i += 1;
        } else {
            emit(out, i + 1, .plain);
            i += 1;
        }
    }
    return depth;
}

fn cssWordEnd(line: []const u8, from: usize) usize {
    var j = from;
    while (j < line.len and (isWordByte(line[j]) or line[j] == '-')) j += 1;
    return j;
}

fn lexYaml(line: []const u8, out: ?*Spans) State {
    var i = skipSpaces(line, 0);
    emit(out, i, .plain);
    if (i >= line.len) return 0;
    if (startsWith(line, "---") or startsWith(line, "...")) {
        emit(out, 3, .punct);
        i = 3;
    }
    if (i < line.len and line[i] == '#') {
        emit(out, line.len, .comment);
        return 0;
    }
    // "- " list markers, possibly nested on one line: "- - a".
    while (i < line.len and line[i] == '-' and (i + 1 >= line.len or isSpace(line[i + 1]))) {
        emit(out, i + 1, .punct);
        i = skipSpaces(line, i + 1);
        emit(out, i, .plain);
    }
    // key:
    if (i < line.len and !has("#\"'[{|>&*!", line[i])) {
        var j = i;
        while (j < line.len) : (j += 1) {
            if (line[j] == '#' and j > 0 and isSpace(line[j - 1])) break;
            if (line[j] == ':' and (j + 1 >= line.len or isSpace(line[j + 1]))) {
                emit(out, j, .property);
                emit(out, j + 1, .punct);
                i = j + 1;
                break;
            }
        }
    } else if (i < line.len and (line[i] == '"' or line[i] == '\'')) {
        const q = line[i];
        var j = i + 1;
        while (j < line.len and line[j] != q) : (j += 1) {
            if (line[j] == '\\' and q == '"') j += 1;
        }
        j = @min(line.len, j + 1);
        const k = skipSpaces(line, j);
        if (k < line.len and line[k] == ':') {
            emit(out, j, .property);
            emit(out, k + 1, .punct);
            i = k + 1;
        }
    }
    // value
    while (i < line.len) {
        const ch = line[i];
        if (isSpace(ch)) {
            i = skipSpaces(line, i);
            emit(out, i, .plain);
        } else if (ch == '#' and (i == 0 or isSpace(line[i - 1]))) {
            emit(out, line.len, .comment);
            return 0;
        } else if (ch == '"' or ch == '\'') {
            var j = i + 1;
            while (j < line.len and line[j] != ch) : (j += 1) {
                if (line[j] == '\\' and ch == '"') j += 1;
            }
            j = @min(line.len, j + 1);
            emit(out, j, .string);
            i = j;
        } else if (has("&*!", ch)) {
            var j = i + 1;
            while (j < line.len and !isSpace(line[j]) and !has(",]}", line[j])) j += 1;
            emit(out, j, .constant);
            i = j;
        } else if ((ch == '|' or ch == '>') and (i + 1 >= line.len or has("-+0123456789 ", line[i + 1]))) {
            emit(out, i + 1, .operator);
            i += 1;
        } else if (has("[]{},", ch)) {
            emit(out, i + 1, .punct);
            i += 1;
        } else if (isDigit(ch) or ((ch == '-' or ch == '.') and i + 1 < line.len and isDigit(line[i + 1]))) {
            const j = scanNumber(line, if (ch == '-') i + 1 else i);
            emit(out, j, .number);
            i = j;
        } else if (isWordStart(ch) or ch == '~') {
            var j = i + 1;
            while (j < line.len and !isSpace(line[j]) and !has(",]}#", line[j])) j += 1;
            const w = line[i..j];
            const is_const = std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null") or
                std.mem.eql(u8, w, "~") or std.mem.eql(u8, w, "yes") or std.mem.eql(u8, w, "no");
            emit(out, j, if (is_const) .constant else .plain);
            i = j;
        } else {
            emit(out, i + 1, .plain);
            i += 1;
        }
    }
    return 0;
}

fn lexIni(line: []const u8, out: ?*Spans) State {
    const i = skipSpaces(line, 0);
    emit(out, i, .plain);
    if (i >= line.len) return 0;
    if (line[i] == ';' or line[i] == '#') {
        emit(out, line.len, .comment);
        return 0;
    }
    if (line[i] == '[') {
        const end = if (std.mem.indexOfScalarPos(u8, line, i, ']')) |k| k + 1 else line.len;
        emit(out, end, .keyword);
        emit(out, line.len, .plain);
        return 0;
    }
    var j = i;
    while (j < line.len and line[j] != '=' and line[j] != ':') j += 1;
    if (j >= line.len) {
        emit(out, line.len, .plain);
        return 0;
    }
    // key, separator, value (quoted values as strings; a trailing ; comment)
    var key_end = j;
    while (key_end > i and isSpace(line[key_end - 1])) key_end -= 1;
    emit(out, key_end, .property);
    emit(out, j, .plain);
    emit(out, j + 1, .operator);
    const v = skipSpaces(line, j + 1);
    emit(out, v, .plain);
    if (v < line.len and (line[v] == '"' or line[v] == '\'')) {
        const q = line[v];
        const end = if (std.mem.indexOfScalarPos(u8, line, v + 1, q)) |k| k + 1 else line.len;
        emit(out, end, .string);
        emit(out, line.len, .plain);
        return 0;
    }
    if (v < line.len and isDigit(line[v]) and scanNumber(line, v) == line.len) {
        emit(out, line.len, .number);
        return 0;
    }
    emit(out, line.len, .plain);
    return 0;
}

// ── dispatch ────────────────────────────────────────────────────────────
pub fn lexLine(lang: Language, state: State, line: []const u8, out: ?*Spans) State {
    return switch (lang) {
        .plain, .markdown => blk: {
            emit(out, line.len, .plain);
            break :blk 0;
        },
        .sql => lexGeneric(sql_spec, state, line, out),
        .csv => lexCsv(line, out),
        .json => lexGeneric(json_spec, state, line, out),
        .zig => lexGeneric(zig_spec, state, line, out),
        .shell => lexGeneric(shell_spec, state, line, out),
        .python => lexGeneric(python_spec, state, line, out),
        .javascript => lexGeneric(js_spec, state, line, out),
        .typescript => lexGeneric(ts_spec, state, line, out),
        .c => lexGeneric(c_spec, state, line, out),
        .cpp => lexGeneric(cpp_spec, state, line, out),
        .objc => lexGeneric(objc_spec, state, line, out),
        .rust => lexGeneric(rust_spec, state, line, out),
        .go => lexGeneric(go_spec, state, line, out),
        .java => lexGeneric(java_spec, state, line, out),
        .swift => lexGeneric(swift_spec, state, line, out),
        .ruby => lexGeneric(ruby_spec, state, line, out),
        .php => lexGeneric(php_spec, state, line, out),
        .yaml => lexYaml(line, out),
        .toml => lexGeneric(toml_spec, state, line, out),
        .ini => lexIni(line, out),
        .make => lexGeneric(make_spec, state, line, out),
        .dockerfile => lexGeneric(dockerfile_spec, state, line, out),
        .lua => lexGeneric(lua_spec, state, line, out),
        .css => lexCss(state, line, out),
        .html, .xml => lexMarkup(state, line, out),
        .diff => lexDiff(line, out),
    };
}

// ── tests ───────────────────────────────────────────────────────────────
const Ex = struct { []const u8, Scope };

/// Checks the spans of one line: text and scope, in order. Adjacent expected
/// entries with the same scope are merged first, as the sink merges them.
fn expectLine(lang: Language, state: State, line: []const u8, expected: []const Ex) !State {
    var out: Spans = .{};
    const next = lexer.lexLine(lang, state, line, &out);
    var start: usize = 0;
    var k: usize = 0; // index into `expected`
    for (out.slice()) |sp| {
        const text = line[start..sp.end];
        if (k >= expected.len) {
            std.debug.print("{s}: extra span '{s}' ({s})\n", .{ @tagName(lang), text, @tagName(sp.scope) });
            return error.TestUnexpectedResult;
        }
        // Gather the expected run of this scope.
        var want_buf: [256]u8 = undefined;
        var want_len: usize = 0;
        const scope = expected[k].@"1";
        while (k < expected.len and expected[k].@"1" == scope) : (k += 1) {
            const t = expected[k].@"0";
            @memcpy(want_buf[want_len .. want_len + t.len], t);
            want_len += t.len;
        }
        std.testing.expectEqualStrings(want_buf[0..want_len], text) catch |e| {
            std.debug.print("{s}: got '{s}' ({s}), wanted '{s}' ({s})\n", .{ @tagName(lang), text, @tagName(sp.scope), want_buf[0..want_len], @tagName(scope) });
            return e;
        };
        std.testing.expectEqual(scope, sp.scope) catch |e| {
            std.debug.print("{s}: '{s}' is {s}, wanted {s}\n", .{ @tagName(lang), text, @tagName(sp.scope), @tagName(scope) });
            return e;
        };
        start = sp.end;
    }
    if (k != expected.len) {
        std.debug.print("{s}: missing expected span '{s}'\n", .{ @tagName(lang), expected[k].@"0" });
        return error.TestUnexpectedResult;
    }
    return next;
}

test "sql" {
    _ = try expectLine(.sql, 0, "SELECT id, name FROM users WHERE x = 'a''b' -- c", &.{
        .{ "SELECT", .keyword }, .{ " ", .plain },      .{ "id", .plain }, .{ ",", .punct },
        .{ " ", .plain },        .{ "name", .plain },   .{ " ", .plain },  .{ "FROM", .keyword },
        .{ " ", .plain },        .{ "users", .plain },  .{ " ", .plain },  .{ "WHERE", .keyword },
        .{ " x ", .plain },      .{ "=", .operator },   .{ " ", .plain },  .{ "'a''b'", .string },
        .{ " ", .plain },        .{ "-- c", .comment },
    });
    _ = try expectLine(.sql, 0, "create table \"T\" (n INT default 1.5e3);", &.{
        .{ "create", .keyword }, .{ " ", .plain },      .{ "table", .keyword }, .{ " ", .plain },
        .{ "\"T\"", .property }, .{ " ", .plain },      .{ "(", .punct },       .{ "n", .plain },
        .{ " ", .plain },        .{ "INT", .type },     .{ " ", .plain },       .{ "default", .keyword },
        .{ " ", .plain },        .{ "1.5e3", .number }, .{ ")", .punct },       .{ ";", .punct },
    });
    // A block comment and a $$ body carry state across lines.
    const s1 = try expectLine(.sql, 0, "x /* open", &.{ .{ "x ", .plain }, .{ "/* open", .comment } });
    try std.testing.expectEqual(st_block, s1);
    const s2 = try expectLine(.sql, s1, "still */ SELECT", &.{ .{ "still */", .comment }, .{ " ", .plain }, .{ "SELECT", .keyword } });
    try std.testing.expectEqual(@as(State, 0), s2);
    const s3 = try expectLine(.sql, 0, "AS $$ begin", &.{ .{ "AS", .keyword }, .{ " ", .plain }, .{ "$$ begin", .string } });
    try std.testing.expect(s3 >= st_string);
    _ = try expectLine(.sql, s3, "end $$ LANGUAGE plpgsql", &.{ .{ "end $$", .string }, .{ " ", .plain }, .{ "LANGUAGE", .keyword }, .{ " plpgsql", .plain } });
}

test "json" {
    _ = try expectLine(.json, 0, "{\"a\": [1, -2.5, true, null], \"s\": \"x\\\"y\"}", &.{
        .{ "{", .punct },       .{ "\"a\"", .property }, .{ ":", .punct },           .{ " ", .plain },
        .{ "[", .punct },       .{ "1", .number },       .{ ",", .punct },           .{ " ", .plain },
        .{ "-", .operator },    .{ "2.5", .number },     .{ ",", .punct },           .{ " ", .plain },
        .{ "true", .constant }, .{ ",", .punct },        .{ " ", .plain },           .{ "null", .constant },
        .{ "]", .punct },       .{ ",", .punct },        .{ " ", .plain },           .{ "\"s\"", .property },
        .{ ":", .punct },       .{ " ", .plain },        .{ "\"x\\\"y\"", .string }, .{ "}", .punct },
    });
}

test "zig" {
    _ = try expectLine(.zig, 0, "pub fn f(x: u21) !void { return @intCast(x); } // hi", &.{
        .{ "pub", .keyword },    .{ " ", .plain }, .{ "fn", .keyword },    .{ " f", .plain },
        .{ "(", .punct },        .{ "x", .plain }, .{ ":", .punct },       .{ " ", .plain },
        .{ "u21", .type },       .{ ")", .punct }, .{ " ", .plain },       .{ "!", .operator },
        .{ "void", .type },      .{ " ", .plain }, .{ "{", .punct },       .{ " ", .plain },
        .{ "return", .keyword }, .{ " ", .plain }, .{ "@intCast", .func }, .{ "(", .punct },
        .{ "x", .plain },        .{ ")", .punct }, .{ ";", .punct },       .{ " ", .plain },
        .{ "}", .punct },        .{ " ", .plain }, .{ "// hi", .comment },
    });
    _ = try expectLine(.zig, 0, "    \\\\line of text", &.{ .{ "    ", .plain }, .{ "\\\\line of text", .string } });
    _ = try expectLine(.zig, 0, "const c = 'x'; const s = \"a\\\"b\";", &.{
        .{ "const", .keyword }, .{ " c ", .plain },  .{ "=", .operator }, .{ " ", .plain },
        .{ "'x'", .string },    .{ ";", .punct },    .{ " ", .plain },    .{ "const", .keyword },
        .{ " s ", .plain },     .{ "=", .operator }, .{ " ", .plain },    .{ "\"a\\\"b\"", .string },
        .{ ";", .punct },
    });
}

test "shell" {
    _ = try expectLine(.shell, 0, "if [ -f \"$HOME/x\" ]; then echo ${N}#1 $# a#b # c", &.{
        .{ "if", .keyword },         .{ " ", .plain },       .{ "[", .punct },  .{ " -f ", .plain },
        .{ "\"$HOME/x\"", .string }, .{ " ", .plain },       .{ "]", .punct },  .{ ";", .operator },
        .{ " ", .plain },            .{ "then", .keyword },  .{ " ", .plain },  .{ "echo", .func },
        .{ " ", .plain },            .{ "${N}", .property }, .{ "#", .plain },  .{ "1", .number },
        .{ " ", .plain },            .{ "$#", .property },   .{ " a", .plain }, .{ "#", .plain },
        .{ "b ", .plain },           .{ "# c", .comment },
    });
}

test "csv" {
    _ = try expectLine(.csv, 0, "a,\"b,c\",3", &.{
        .{ "a", .field_a }, .{ ",", .punct }, .{ "\"b,c\"", .field_b }, .{ ",", .punct }, .{ "3", .field_c },
    });
    _ = try expectLine(.csv, 0, "x\ty\tz\tw\tv", &.{
        .{ "x", .field_a }, .{ "\t", .punct },  .{ "y", .field_b }, .{ "\t", .punct },  .{ "z", .field_c },
        .{ "\t", .punct },  .{ "w", .field_d }, .{ "\t", .punct },  .{ "v", .field_a },
    });
    _ = try expectLine(.csv, 0, "no delimiter here", &.{.{ "no delimiter here", .plain }});
}

test "python triple-quoted string spans lines" {
    const s = try expectLine(.python, 0, "x = \"\"\"start", &.{ .{ "x ", .plain }, .{ "=", .operator }, .{ " ", .plain }, .{ "\"\"\"start", .string } });
    try std.testing.expect(s >= st_string);
    _ = try expectLine(.python, s, "mid", &.{.{ "mid", .string }});
    const e = try expectLine(.python, s, "end\"\"\" + None", &.{ .{ "end\"\"\"", .string }, .{ " ", .plain }, .{ "+", .operator }, .{ " ", .plain }, .{ "None", .constant } });
    try std.testing.expectEqual(@as(State, 0), e);
    _ = try expectLine(.python, 0, "@app.route('/') # d", &.{
        .{ "@app", .func }, .{ ".", .punct }, .{ "route", .plain }, .{ "(", .punct }, .{ "'/'", .string },
        .{ ")", .punct },   .{ " ", .plain }, .{ "# d", .comment },
    });
}

test "c preprocessor, rust macros and lifetimes, go raw strings" {
    _ = try expectLine(.c, 0, "#include <stdio.h>", &.{ .{ "#include", .keyword }, .{ " ", .plain }, .{ "<stdio.h>", .string } });
    _ = try expectLine(.c, 0, "char c = 'a'; int *p = NULL;", &.{
        .{ "char", .type }, .{ " c ", .plain },  .{ "=", .operator }, .{ " ", .plain },       .{ "'a'", .string },
        .{ ";", .punct },   .{ " ", .plain },    .{ "int", .type },   .{ " ", .plain },       .{ "*", .operator },
        .{ "p ", .plain },  .{ "=", .operator }, .{ " ", .plain },    .{ "NULL", .constant }, .{ ";", .punct },
    });
    _ = try expectLine(.rust, 0, "fn f<'a>(s: &'a str) { println!(\"{}\", s); }", &.{
        .{ "fn", .keyword }, .{ " f", .plain },      .{ "<", .operator }, .{ "'a", .plain },      .{ ">", .operator },
        .{ "(", .punct },    .{ "s", .plain },       .{ ":", .punct },    .{ " ", .plain },       .{ "&", .operator },
        .{ "'a ", .plain },  .{ "str", .type },      .{ ")", .punct },    .{ " ", .plain },       .{ "{", .punct },
        .{ " ", .plain },    .{ "println!", .func }, .{ "(", .punct },    .{ "\"{}\"", .string }, .{ ",", .punct },
        .{ " s", .plain },   .{ ")", .punct },       .{ ";", .punct },    .{ " ", .plain },       .{ "}", .punct },
    });
    const g = try expectLine(.go, 0, "s := `raw", &.{ .{ "s ", .plain }, .{ ":", .punct }, .{ "=", .operator }, .{ " ", .plain }, .{ "`raw", .string } });
    try std.testing.expect(g >= st_string);
    _ = try expectLine(.go, g, "end` // c", &.{ .{ "end`", .string }, .{ " ", .plain }, .{ "// c", .comment } });
}

test "yaml, toml, ini" {
    _ = try expectLine(.yaml, 0, "  - name: web # svc", &.{
        .{ "  ", .plain }, .{ "-", .punct },     .{ " ", .plain },       .{ "name", .property },
        .{ ":", .punct },  .{ " web ", .plain }, .{ "# svc", .comment },
    });
    _ = try expectLine(.yaml, 0, "ports: [80, 443]", &.{
        .{ "ports", .property }, .{ ":", .punct }, .{ " ", .plain },    .{ "[", .punct }, .{ "80", .number },
        .{ ",", .punct },        .{ " ", .plain }, .{ "443", .number }, .{ "]", .punct },
    });
    _ = try expectLine(.yaml, 0, "enabled: true", &.{ .{ "enabled", .property }, .{ ":", .punct }, .{ " ", .plain }, .{ "true", .constant } });
    _ = try expectLine(.toml, 0, "[server.http]", &.{.{ "[server.http]", .keyword }});
    _ = try expectLine(.toml, 0, "port = 8080 # c", &.{
        .{ "port", .property }, .{ " ", .plain },     .{ "=", .operator }, .{ " ", .plain }, .{ "8080", .number },
        .{ " ", .plain },       .{ "# c", .comment },
    });
    _ = try expectLine(.ini, 0, "[core]", &.{.{ "[core]", .keyword }});
    _ = try expectLine(.ini, 0, "name = \"x\"", &.{ .{ "name", .property }, .{ " ", .plain }, .{ "=", .operator }, .{ " ", .plain }, .{ "\"x\"", .string } });
    _ = try expectLine(.ini, 0, "; note", &.{.{ "; note", .comment }});
}

test "make, dockerfile, diff" {
    _ = try expectLine(.make, 0, "build: main.o", &.{ .{ "build", .func }, .{ ":", .operator }, .{ " main.o", .plain } });
    _ = try expectLine(.make, 0, "CC := gcc", &.{ .{ "CC", .property }, .{ " ", .plain }, .{ ":=", .operator }, .{ " gcc", .plain } });
    _ = try expectLine(.make, 0, "\t$(CC) -o $@ $<", &.{
        .{ "\t", .plain },    .{ "$(CC)", .property }, .{ " -o ", .plain }, .{ "$@", .property }, .{ " ", .plain },
        .{ "$<", .property },
    });
    _ = try expectLine(.dockerfile, 0, "FROM alpine:3.19 AS base", &.{
        .{ "FROM", .keyword }, .{ " alpine:", .plain }, .{ "3.19", .number }, .{ " ", .plain },
        .{ "AS", .keyword },   .{ " base", .plain },
    });
    _ = try expectLine(.diff, 0, "@@ -1,3 +1,4 @@ fn main", &.{ .{ "@@ -1,3 +1,4 @@", .number }, .{ " fn main", .plain } });
    _ = try expectLine(.diff, 0, "+added", &.{.{ "+added", .string }});
    _ = try expectLine(.diff, 0, "-gone", &.{.{ "-gone", .constant }});
    _ = try expectLine(.diff, 0, "--- a/x", &.{.{ "--- a/x", .comment }});
    _ = try expectLine(.diff, 0, " ctx", &.{.{ " ctx", .plain }});
}

test "html and css carry state" {
    const t = try expectLine(.html, 0, "<a href=\"x", &.{
        .{ "<", .punct }, .{ "a", .keyword }, .{ " ", .plain }, .{ "href", .property }, .{ "=", .operator }, .{ "\"x", .string },
    });
    try std.testing.expectEqual(html_dq, t);
    _ = try expectLine(.html, t, "y\">hi &amp; <!-- c", &.{
        .{ "y\"", .string }, .{ ">", .punct }, .{ "hi ", .plain }, .{ "&amp;", .escape }, .{ " ", .plain }, .{ "<!-- c", .comment },
    });
    const c1 = try expectLine(.css, 0, "a:hover { color: #fff; /* x", &.{
        .{ "a", .plain }, .{ ":", .punct },        .{ "hover", .plain },  .{ " ", .plain }, .{ "{", .punct },
        .{ " ", .plain }, .{ "color", .property }, .{ ":", .punct },      .{ " ", .plain }, .{ "#fff", .constant },
        .{ ";", .punct }, .{ " ", .plain },        .{ "/* x", .comment },
    });
    try std.testing.expect(c1 & css_comment != 0);
    _ = try expectLine(.css, c1, "*/ margin: 10px }", &.{
        .{ "*/", .comment },  .{ " ", .plain }, .{ "margin", .property }, .{ ":", .punct }, .{ " ", .plain },
        .{ "10px", .number }, .{ " ", .plain }, .{ "}", .punct },
    });
}

test "javascript, typescript, ruby, php, lua" {
    _ = try expectLine(.javascript, 0, "const s = `a${b}`; // x", &.{
        .{ "const", .keyword }, .{ " s ", .plain }, .{ "=", .operator },   .{ " ", .plain }, .{ "`a${b}`", .string },
        .{ ";", .punct },       .{ " ", .plain },   .{ "// x", .comment },
    });
    _ = try expectLine(.typescript, 0, "let n: number = 1;", &.{
        .{ "let", .keyword }, .{ " n", .plain },   .{ ":", .punct }, .{ " ", .plain },  .{ "number", .type },
        .{ " ", .plain },     .{ "=", .operator }, .{ " ", .plain }, .{ "1", .number }, .{ ";", .punct },
    });
    _ = try expectLine(.ruby, 0, "def go(x) @a = :sym; puts x end", &.{
        .{ "def", .keyword },   .{ " go", .plain },   .{ "(", .punct }, .{ "x", .plain },    .{ ")", .punct },
        .{ " ", .plain },       .{ "@a", .property }, .{ " ", .plain }, .{ "=", .operator }, .{ " ", .plain },
        .{ ":sym", .constant }, .{ ";", .punct },     .{ " ", .plain }, .{ "puts", .func },  .{ " x ", .plain },
        .{ "end", .keyword },
    });
    _ = try expectLine(.php, 0, "<?php echo $x; ?>", &.{
        .{ "<?php", .keyword }, .{ " ", .plain }, .{ "echo", .keyword }, .{ " ", .plain }, .{ "$x", .property },
        .{ ";", .punct },       .{ " ", .plain }, .{ "?>", .keyword },
    });
    _ = try expectLine(.lua, 0, "local t = {} --[[ c ]] print(nil)", &.{
        .{ "local", .keyword }, .{ " t ", .plain },    .{ "=", .operator },        .{ " ", .plain }, .{ "{", .punct },
        .{ "}", .punct },       .{ " ", .plain },      .{ "--[[ c ]]", .comment }, .{ " ", .plain }, .{ "print", .func },
        .{ "(", .punct },       .{ "nil", .constant }, .{ ")", .punct },
    });
}

test "objc, swift, java" {
    _ = try expectLine(.objc, 0, "@interface Foo : NSObject", &.{
        .{ "@interface", .keyword }, .{ " Foo ", .plain }, .{ ":", .punct }, .{ " ", .plain }, .{ "NSObject", .type },
    });
    _ = try expectLine(.swift, 0, "let x: Int? = nil", &.{
        .{ "let", .keyword }, .{ " x", .plain }, .{ ":", .punct },    .{ " ", .plain }, .{ "Int", .type },
        .{ "?", .operator },  .{ " ", .plain },  .{ "=", .operator }, .{ " ", .plain }, .{ "nil", .constant },
    });
    _ = try expectLine(.java, 0, "@Override public String name() { return null; }", &.{
        .{ "@Override", .func }, .{ " ", .plain },        .{ "public", .keyword }, .{ " ", .plain },       .{ "String", .type },
        .{ " name", .plain },    .{ "(", .punct },        .{ ")", .punct },        .{ " ", .plain },       .{ "{", .punct },
        .{ " ", .plain },        .{ "return", .keyword }, .{ " ", .plain },        .{ "null", .constant }, .{ ";", .punct },
        .{ " ", .plain },        .{ "}", .punct },
    });
}

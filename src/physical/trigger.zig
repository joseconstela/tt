//! Finding the trigger word in what speech recognition heard. Recognisers
//! write a short word like "tt" in many ways — "TT", "T.T.", "t-t",
//! "tee tee", "T T", in Spanish "te te" or "té té" — so both sides are
//! compared as bare letters and digits (accented and other non-ASCII
//! letters kept as they are), and a word may also stand for the letter it
//! names ("tee", "té" → t) or for several, run together ("tete",
//! "teetee" → tt). A trigger of several words ("hey tt") matches across
//! words the same way.
//!
//! Pure functions on text: the voice controller runs them on each new
//! transcript, the Settings page uses the matches to highlight them.
const std = @import("std");

/// The trigger when the setting is blank.
pub const default_word = "tt";

/// At most this many matches are reported for one transcript.
pub const max_matches = 16;
/// A match spans at most this many words ("hey tee tee" is three).
const max_span = 8;

/// A match: byte range in the transcript, from the first letter of the
/// first matched word to the last letter of the last one (the comma of
/// "tt, open" is not part of it).
pub const Match = struct { start: usize, end: usize };

pub const Matches = struct {
    items: [max_matches]Match = undefined,
    len: usize = 0,

    pub fn slice(self: *const Matches) []const Match {
        return self.items[0..self.len];
    }

    pub fn last(self: *const Matches) ?Match {
        return if (self.len == 0) null else self.items[self.len - 1];
    }
};

/// Letters and digits: ASCII ones, and every byte of a non-ASCII
/// character (UTF-8), so "é" or "ñ" count as letters.
fn isWordByte(c: u8) bool {
    return c >= 0x80 or std.ascii.isAlphanumeric(c);
}

/// The trigger as it is compared: lowercase letters and digits only.
/// Blank (or nothing but punctuation) is the default word.
pub fn normalize(buf: []u8, trigger: []const u8) []const u8 {
    var n: usize = 0;
    for (trigger) |c| {
        if (!isWordByte(c)) continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    if (n == 0) return default_word;
    return buf[0..n];
}

/// The spoken names of the letters, as recognisers tend to write them:
/// English, then Spanish (the Mac's language is what speech is recognised
/// in by default).
const letter_names = [_]struct { []const u8, u8 }{
    .{ "ay", 'a' },     .{ "bee", 'b' },   .{ "be", 'b' },    .{ "see", 'c' },   .{ "sea", 'c' },
    .{ "dee", 'd' },    .{ "ee", 'e' },    .{ "ef", 'f' },    .{ "eff", 'f' },   .{ "gee", 'g' },
    .{ "aitch", 'h' },  .{ "eye", 'i' },   .{ "jay", 'j' },   .{ "kay", 'k' },   .{ "el", 'l' },
    .{ "ell", 'l' },    .{ "em", 'm' },    .{ "en", 'n' },    .{ "oh", 'o' },    .{ "pee", 'p' },
    .{ "pea", 'p' },    .{ "cue", 'q' },   .{ "queue", 'q' }, .{ "ar", 'r' },    .{ "are", 'r' },
    .{ "es", 's' },     .{ "ess", 's' },   .{ "tee", 't' },   .{ "tea", 't' },   .{ "you", 'u' },
    .{ "vee", 'v' },    .{ "ex", 'x' },    .{ "why", 'y' },   .{ "zee", 'z' },   .{ "zed", 'z' },
    // Spanish.
    .{ "ce", 'c' },     .{ "de", 'd' },    .{ "dé", 'd' },    .{ "efe", 'f' },   .{ "ge", 'g' },
    .{ "hache", 'h' },  .{ "jota", 'j' },  .{ "ka", 'k' },    .{ "ele", 'l' },   .{ "eme", 'm' },
    .{ "ene", 'n' },    .{ "pe", 'p' },    .{ "cu", 'q' },    .{ "erre", 'r' },  .{ "ere", 'r' },
    .{ "ese", 's' },    .{ "te", 't' },    .{ "té", 't' },    .{ "uve", 'v' },   .{ "equis", 'x' },
    .{ "ye", 'y' },     .{ "zeta", 'z' },  .{ "ceta", 'z' },
};

fn letterFor(word: []const u8) ?u8 {
    for (letter_names) |ln| {
        if (std.ascii.eqlIgnoreCase(word, ln[0])) return ln[1];
    }
    return null;
}

const Word = struct {
    start: usize,
    end: usize,
    /// Its letters and digits, lowercased.
    bare: [48]u8 = undefined,
    bare_len: usize = 0,
    /// The letter it names, if it names one.
    letter: ?u8 = null,

    fn bareSlice(self: *const Word) []const u8 {
        return self.bare[0..self.bare_len];
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The next word of `text` from `i` (whitespace-separated); null at the end.
fn nextWord(text: []const u8, i: *usize) ?Word {
    while (i.* < text.len and isSpace(text[i.*])) i.* += 1;
    if (i.* >= text.len) return null;
    var w: Word = .{ .start = i.*, .end = i.* };
    while (i.* < text.len and !isSpace(text[i.*])) i.* += 1;
    w.end = i.*;
    for (text[w.start..w.end]) |c| {
        if (!isWordByte(c) or w.bare_len == w.bare.len) continue;
        w.bare[w.bare_len] = std.ascii.toLower(c);
        w.bare_len += 1;
    }
    w.letter = letterFor(w.bareSlice());
    return w;
}

/// How many of `words` (from the first) spell `want` exactly, each word as
/// its bare text or as the letter it names; 0 when they do not.
fn spell(words: []const Word, want: []const u8) usize {
    if (want.len == 0) return 0;
    if (words.len == 0) return 0;
    const w = &words[0];
    const bare = w.bareSlice();
    // A word of punctuation only ("—") is skipped inside a match.
    if (bare.len == 0) {
        const n = spell(words[1..], want);
        return if (n == 0) 0 else n + 1;
    }
    if (std.mem.startsWith(u8, want, bare)) {
        if (bare.len == want.len) return 1;
        const n = spell(words[1..], want[bare.len..]);
        if (n > 0) return n + 1;
    }
    if (w.letter) |l| {
        if (want[0] == l) {
            if (want.len == 1) return 1;
            const n = spell(words[1..], want[1..]);
            if (n > 0) return n + 1;
        }
    }
    const run = letterRun(bare, want);
    if (run >= 2) {
        if (run == want.len) return 1;
        const n = spell(words[1..], want[run..]);
        if (n > 0) return n + 1;
    }
    return 0;
}

/// How many letters of `want` a word spells as letter names run together
/// ("tete", "teetee" → 2); 0 when it does not, all of it.
fn letterRun(bare: []const u8, want: []const u8) usize {
    if (bare.len == 0 or want.len == 0) return 0;
    for (letter_names) |ln| {
        if (want[0] != ln[1] or !std.mem.startsWith(u8, bare, ln[0])) continue;
        if (bare.len == ln[0].len) return 1;
        const n = letterRun(bare[ln[0].len..], want[1..]);
        if (n > 0) return n + 1;
    }
    return 0;
}

/// Phrases to tell the recogniser to expect, besides the trigger itself:
/// a short word of letters spelled out ("tt" → "T T"), as it is said.
pub fn spelled(buf: []u8, trigger: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, trigger, " \t");
    if (t.len < 2 or t.len > 4 or t.len * 2 > buf.len) return null;
    for (t) |c| {
        if (!std.ascii.isAlphabetic(c)) return null;
    }
    var n: usize = 0;
    for (t, 0..) |c, i| {
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = std.ascii.toUpper(c);
        n += 1;
    }
    return buf[0..n];
}

/// Every place `text` says the trigger (already normalised), in order.
pub fn find(text: []const u8, trigger_norm: []const u8) Matches {
    var out: Matches = .{};
    // A window of the next words, refilled as it slides.
    var words: [max_span]Word = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (true) {
        while (count < max_span) {
            words[count] = nextWord(text, &i) orelse break;
            count += 1;
        }
        if (count == 0) break;
        const n = spell(words[0..count], trigger_norm);
        var used: usize = 1;
        if (n > 0 and words[0].bare_len > 0) {
            if (out.len < max_matches) {
                out.items[out.len] = trimmed(text, words[0].start, words[n - 1].end);
                out.len += 1;
            }
            used = n;
        }
        std.mem.copyForwards(Word, words[0 .. count - used], words[used..count]);
        count -= used;
    }
    return out;
}

/// The range without the punctuation around it.
fn trimmed(text: []const u8, start: usize, end: usize) Match {
    var a = start;
    var b = end;
    while (a < b and !isWordByte(text[a])) a += 1;
    while (b > a and !isWordByte(text[b - 1])) b -= 1;
    return .{ .start = a, .end = b };
}

/// What was said after the last trigger: the command, once commands exist.
/// Leading punctuation (the comma of "tt, open …") is dropped.
pub fn afterLast(text: []const u8, matches: *const Matches) []const u8 {
    const m = matches.last() orelse return "";
    var rest = text[m.end..];
    while (rest.len > 0 and (isSpace(rest[0]) or rest[0] == ',' or rest[0] == '.' or rest[0] == ':' or rest[0] == '!' or rest[0] == '?')) rest = rest[1..];
    return std.mem.trimEnd(u8, rest, " \t\r\n");
}

// ── tests ───────────────────────────────────────────────────────────────

fn expectFinds(text: []const u8, trigger: []const u8, want: []const []const u8) !void {
    var buf: [64]u8 = undefined;
    const m = find(text, normalize(&buf, trigger));
    try std.testing.expectEqual(want.len, m.len);
    for (m.slice(), want) |got, w| try std.testing.expectEqualStrings(w, text[got.start..got.end]);
}

test "trigger: the ways a recogniser writes tt" {
    try expectFinds("TT open the files", "tt", &.{"TT"});
    try expectFinds("hey T.T. what's up", "tt", &.{"T.T"});
    try expectFinds("tee tee, run the tests", "tt", &.{"tee tee"});
    try expectFinds("(TT)", "tt", &.{"TT"});
    try expectFinds("T T show me", "tt", &.{"T T"});
    try expectFinds("t-t", "tt", &.{"t-t"});
    try expectFinds("tt and then TT again", "tt", &.{ "tt", "TT" });
    // Not inside a longer word, nor a lone letter.
    try expectFinds("the attic", "tt", &.{});
    try expectFinds("tea for two", "tt", &.{});
    try expectFinds("", "tt", &.{});
}

test "trigger: Spanish letter names and accented words" {
    try expectFinds("Té té, abre los archivos", "tt", &.{"Té té"});
    try expectFinds("te te abre", "tt", &.{"te te"});
    // Letter names run together.
    try expectFinds("Tete, abre los archivos", "tt", &.{"Tete"});
    try expectFinds("teetee open", "tt", &.{"teetee"});
    try expectFinds("hey teetee", "hey tt", &.{"hey teetee"});
    try expectFinds("tetera", "tt", &.{});
    // An accented letter is a letter: "té" alone is not "t".
    try expectFinds("un tét", "tt", &.{});
    try expectFinds("José, abre", "José", &.{"José"});
    try expectFinds("Jose, abre", "José", &.{});
}

test "trigger: several words, other words, blank means the default" {
    try expectFinds("okay hey tee tee go", "Hey TT", &.{"hey tee tee"});
    try expectFinds("Computer, open the files", "computer", &.{"Computer"});
    try expectFinds("TT", "  ", &.{"TT"});
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("heytt", normalize(&buf, "Hey, T.T.!"));
}

test "trigger: a short word of letters is spelled out for the recogniser" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("T T", spelled(&buf, "tt").?);
    try std.testing.expectEqualStrings("A B C", spelled(&buf, " abc ").?);
    try std.testing.expect(spelled(&buf, "computer") == null);
    try std.testing.expect(spelled(&buf, "t") == null);
    try std.testing.expect(spelled(&buf, "t1") == null);
}

test "trigger: the command is what follows the last trigger" {
    var buf: [16]u8 = undefined;
    const text = "tt stop. TT, open the files";
    const m = find(text, normalize(&buf, "tt"));
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("open the files", afterLast(text, &m));
    const none = find("nothing here", "tt");
    try std.testing.expectEqualStrings("", afterLast("nothing here", &none));
}

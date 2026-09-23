//! A text document being edited: the input box's `Editor` (buffer, caret,
//! selection, IME) plus what a file needs on top — a line index, undo/redo,
//! the syntax state at the start of every line, and "modified since it was
//! saved". Every change to the buffer goes through `replace`, which is what
//! keeps those four in step.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const EditCommand = @import("../events.zig").EditCommand;
const lexer = @import("../syntax/lexer.zig");

pub const Language = lexer.Language;

/// Undo entries beyond this are dropped, oldest first.
const max_undo: usize = 4000;

pub const Document = struct {
    gpa: std.mem.Allocator,
    editor: Editor,
    lang: Language = .plain,
    /// Byte offset where each line starts. `line_starts[0]` is 0, so there
    /// is always at least one line.
    line_starts: std.ArrayList(u32) = .empty,
    /// Lexer state at the start of each line, parallel to `line_starts`.
    states: std.ArrayList(lexer.State) = .empty,
    undo_stack: std.ArrayList(Edit) = .empty,
    redo_stack: std.ArrayList(Edit) = .empty,
    /// Bumped on every buffer change (never on caret moves).
    revision: u64 = 0,
    /// Serial of the undo entry on top of the stack when the file was last
    /// saved or loaded: "modified" means a different entry is on top now,
    /// so undoing back to the saved point makes the document clean again.
    saved_top: u64 = 0,
    next_serial: u64 = 1,
    /// The file used "\r\n"; it is written back that way.
    crlf: bool = false,
    /// Indentation the file already uses; new indentation follows it.
    uses_tabs: bool = false,
    /// `editor.version` when the last edit was recorded, so navigation in
    /// between breaks an undo group.
    last_edit_version: u64 = 0,
    /// The most recent line-range changes, so views can patch per-line
    /// caches instead of rebuilding them. `change_serial` counts every
    /// change ever made; the ring holds the last `changes.len`.
    changes: [32]Change = undefined,
    change_serial: u64 = 0,

    /// Lines [first, first + old_count) became new_count lines.
    pub const Change = struct { first: u32, old_count: u32, new_count: u32 };

    pub const Edit = struct {
        at: u32,
        removed: []u8,
        inserted: []u8,
        cursor_before: u32,
        cursor_after: u32,
        /// Consecutive typing / backspacing merges into one entry.
        kind: enum { other, typing, backspace },
        serial: u64,
    };

    pub fn init(gpa: std.mem.Allocator) Document {
        return .{ .gpa = gpa, .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Document) void {
        self.clearEdits(&self.undo_stack);
        self.clearEdits(&self.redo_stack);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.line_starts.deinit(self.gpa);
        self.states.deinit(self.gpa);
        self.editor.deinit();
    }

    fn clearEdits(self: *Document, stack: *std.ArrayList(Edit)) void {
        for (stack.items) |e| {
            self.gpa.free(e.removed);
            self.gpa.free(e.inserted);
        }
        stack.clearRetainingCapacity();
    }

    // ── loading and saving ──────────────────────────────────────────────
    /// Replaces the whole text (a fresh load): no undo history, caret at
    /// the top, "\r\n" normalised to "\n".
    pub fn setText(self: *Document, data: []const u8, lang: Language) !void {
        self.lang = lang;
        self.crlf = std.mem.indexOf(u8, data, "\r\n") != null;
        self.uses_tabs = std.mem.indexOfScalar(u8, data, '\t') != null;
        self.editor.text.clearRetainingCapacity();
        try self.editor.text.ensureTotalCapacity(self.gpa, data.len);
        if (self.crlf) {
            var i: usize = 0;
            while (i < data.len) : (i += 1) {
                if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
                self.editor.text.appendAssumeCapacity(data[i]);
            }
        } else {
            self.editor.text.appendSliceAssumeCapacity(data);
        }
        self.editor.cursor = 0;
        self.editor.anchor = null;
        self.editor.marked.clearRetainingCapacity();
        self.editor.version +%= 1;
        self.clearEdits(&self.undo_stack);
        self.clearEdits(&self.redo_stack);
        try self.rebuildIndex();
        // A reload invalidates every per-line cache: push the ring out of reach.
        self.change_serial += self.changes.len + 1;
        self.revision += 1;
        self.saved_top = 0;
        self.last_edit_version = self.editor.version;
    }

    pub fn setLanguage(self: *Document, lang: Language) void {
        if (self.lang == lang) return;
        self.lang = lang;
        _ = self.relexFrom(0, self.lineCount());
    }

    fn topSerial(self: *const Document) u64 {
        const n = self.undo_stack.items.len;
        return if (n == 0) 0 else self.undo_stack.items[n - 1].serial;
    }

    pub fn modified(self: *const Document) bool {
        return self.topSerial() != self.saved_top;
    }

    pub fn markSaved(self: *Document) void {
        self.saved_top = self.topSerial();
        // Typing that continues after the save must not merge into the
        // entry the save points at.
        self.last_edit_version = 0;
    }

    pub fn bytes(self: *const Document) []const u8 {
        return self.editor.text.items;
    }

    /// The text as it should be written to disk (caller frees).
    pub fn serialize(self: *const Document, gpa: std.mem.Allocator) ![]u8 {
        const src = self.bytes();
        if (!self.crlf) return gpa.dupe(u8, src);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, src.len + self.lineCount());
        for (src) |b| {
            if (b == '\n') out.appendAssumeCapacity('\r');
            out.appendAssumeCapacity(b);
        }
        return out.toOwnedSlice(gpa);
    }

    // ── lines ───────────────────────────────────────────────────────────
    pub fn lineCount(self: *const Document) usize {
        return self.line_starts.items.len;
    }

    pub fn lineStartOf(self: *const Document, i: usize) usize {
        return self.line_starts.items[i];
    }

    /// End of line `i`, excluding its "\n".
    pub fn lineEndOf(self: *const Document, i: usize) usize {
        if (i + 1 < self.line_starts.items.len) return self.line_starts.items[i + 1] - 1;
        return self.editor.text.items.len;
    }

    pub fn lineText(self: *const Document, i: usize) []const u8 {
        return self.editor.text.items[self.lineStartOf(i)..self.lineEndOf(i)];
    }

    pub fn lineState(self: *const Document, i: usize) lexer.State {
        return self.states.items[i];
    }

    /// Index of the line containing byte `offset` (offset == len is the last line).
    pub fn lineOf(self: *const Document, offset: usize) usize {
        const starts = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= offset) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Lexes line `i` into `out`.
    pub fn lexInto(self: *const Document, i: usize, out: *lexer.Spans) void {
        _ = lexer.lexLine(self.lang, self.states.items[i], self.lineText(i), out);
    }

    fn rebuildIndex(self: *Document) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.gpa, 0);
        const text = self.editor.text.items;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |nl| {
            try self.line_starts.append(self.gpa, @intCast(nl + 1));
            pos = nl + 1;
        }
        try self.states.resize(self.gpa, self.line_starts.items.len);
        @memset(self.states.items, 0);
        self.states.items[0] = lexer.initialState(self.lang);
        _ = self.relexFrom(0, self.lineCount());
    }

    /// Recomputes start states from line `from`; lines before `must_end`
    /// are recomputed unconditionally, after that only until the new state
    /// matches the stored one (from then on nothing downstream can change).
    /// Returns one past the last line whose start state was written, so a
    /// change record can cover every line whose rendering may have changed.
    fn relexFrom(self: *Document, from: usize, must_end: usize) usize {
        const n = self.lineCount();
        if (from >= n) return from;
        var st = self.states.items[from];
        var i = from;
        while (true) : (i += 1) {
            st = lexer.lexLine(self.lang, st, self.lineText(i), null);
            if (i + 1 >= n) break;
            if (i + 1 >= must_end and self.states.items[i + 1] == st) break;
            self.states.items[i + 1] = st;
        }
        return @max(must_end, i + 1);
    }

    /// Fixes the line index after bytes [from, to) became `ins_len` bytes.
    fn reindex(self: *Document, from: usize, to: usize, inserted: []const u8) !void {
        const starts = &self.line_starts;
        const li = self.lineOf(from);
        // Entries strictly inside (from, to] belonged to newlines that are gone.
        var a = li + 1;
        while (a < starts.items.len and starts.items[a] <= from) a += 1;
        var b = a;
        while (b < starts.items.len and starts.items[b] <= to) b += 1;
        // New entries for the newlines in the inserted text.
        var fresh: std.ArrayList(u32) = .empty;
        defer fresh.deinit(self.gpa);
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, inserted, pos, '\n')) |nl| {
            try fresh.append(self.gpa, @intCast(from + nl + 1));
            pos = nl + 1;
        }
        const delta: i64 = @as(i64, @intCast(inserted.len)) - @as(i64, @intCast(to - from));
        for (starts.items[b..]) |*s| s.* = @intCast(@as(i64, s.*) + delta);
        try starts.replaceRange(self.gpa, a, b - a, fresh.items);
        // States: placeholders for the new lines, then relex from the edited line.
        try self.states.replaceRange(self.gpa, a, b - a, &.{});
        var k: usize = 0;
        while (k < fresh.items.len) : (k += 1) try self.states.insert(self.gpa, a + k, 0);
        // Lines past the edit whose start state changed (a fence or table
        // opened above them) are in the record too, mapped onto themselves.
        const relexed = self.relexFrom(li, a + fresh.items.len);
        const extra: u32 = @intCast(relexed - (a + fresh.items.len));
        self.changes[self.change_serial % self.changes.len] = .{ .first = @intCast(li), .old_count = @intCast(1 + (b - a) + extra), .new_count = @intCast(1 + fresh.items.len + extra) };
        self.change_serial += 1;
    }

    /// Change number `serial` (0-based), if still in the ring.
    pub fn changeAt(self: *const Document, serial: u64) ?Change {
        if (serial >= self.change_serial or self.change_serial - serial > self.changes.len) return null;
        return self.changes[serial % self.changes.len];
    }

    // ── editing ─────────────────────────────────────────────────────────
    /// The one primitive: bytes [from, to) become `text`. Records an undo
    /// entry (merging with the previous one for runs of typing) and leaves
    /// the caret after the inserted text.
    pub fn replace(self: *Document, from_in: usize, to_in: usize, text: []const u8) void {
        const len = self.editor.text.items.len;
        const from = @min(from_in, len);
        const to = @min(@max(to_in, from), len);
        if (from == to and text.len == 0) return;
        const cursor_before: u32 = @intCast(self.editor.cursor);
        const removed = self.gpa.dupe(u8, self.editor.text.items[from..to]) catch return;
        const inserted = self.gpa.dupe(u8, text) catch {
            self.gpa.free(removed);
            return;
        };
        self.applyRaw(from, to, text) catch {
            self.gpa.free(removed);
            self.gpa.free(inserted);
            return;
        };
        const kind: @TypeOf(@as(Edit, undefined).kind) = if (removed.len == 0 and inserted.len > 0 and std.mem.indexOfScalar(u8, inserted, '\n') == null)
            .typing
        else if (inserted.len == 0 and removed.len > 0 and removed.len <= 4 and std.mem.indexOfScalar(u8, removed, '\n') == null)
            .backspace
        else
            .other;
        const cursor_after: u32 = @intCast(self.editor.cursor);
        self.clearEdits(&self.redo_stack);
        // Merge with the previous entry when this continues it.
        const continues = self.undo_stack.items.len > 0 and self.last_edit_version == self.editor.version -% 1;
        if (continues) {
            const prev = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (kind == .typing and prev.kind == .typing and prev.at + prev.inserted.len == from) {
                const merged = std.mem.concat(self.gpa, u8, &.{ prev.inserted, inserted }) catch null;
                if (merged) |m| {
                    self.gpa.free(prev.inserted);
                    prev.inserted = m;
                    prev.cursor_after = cursor_after;
                    self.gpa.free(removed);
                    self.gpa.free(inserted);
                    self.last_edit_version = self.editor.version;
                    return;
                }
            } else if (kind == .backspace and prev.kind == .backspace and from + removed.len == prev.at) {
                const merged = std.mem.concat(self.gpa, u8, &.{ removed, prev.removed }) catch null;
                if (merged) |m| {
                    self.gpa.free(prev.removed);
                    prev.removed = m;
                    prev.at = @intCast(from);
                    prev.cursor_after = cursor_after;
                    self.gpa.free(removed);
                    self.gpa.free(inserted);
                    self.last_edit_version = self.editor.version;
                    return;
                }
            }
        }
        if (self.undo_stack.items.len >= max_undo) {
            const old = self.undo_stack.orderedRemove(0);
            self.gpa.free(old.removed);
            self.gpa.free(old.inserted);
        }
        self.undo_stack.append(self.gpa, .{
            .at = @intCast(from),
            .removed = removed,
            .inserted = inserted,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
            .kind = kind,
            .serial = self.next_serial,
        }) catch {
            self.gpa.free(removed);
            self.gpa.free(inserted);
        };
        self.next_serial += 1;
        self.last_edit_version = self.editor.version;
    }

    /// Buffer + index change without touching the undo history.
    fn applyRaw(self: *Document, from: usize, to: usize, text: []const u8) !void {
        try self.editor.text.replaceRange(self.gpa, from, to - from, text);
        self.editor.cursor = from + text.len;
        self.editor.anchor = null;
        self.editor.marked.clearRetainingCapacity();
        self.editor.version +%= 1;
        self.revision += 1;
        try self.reindex(from, to, text);
    }

    pub fn undo(self: *Document) bool {
        const e = self.undo_stack.pop() orelse return false;
        self.applyRaw(e.at, e.at + e.inserted.len, e.removed) catch return false;
        self.editor.cursor = @min(e.cursor_before, self.editor.text.items.len);
        self.redo_stack.append(self.gpa, e) catch {
            self.gpa.free(e.removed);
            self.gpa.free(e.inserted);
        };
        self.last_edit_version = 0;
        return true;
    }

    pub fn redo(self: *Document) bool {
        const e = self.redo_stack.pop() orelse return false;
        self.applyRaw(e.at, e.at + e.removed.len, e.inserted) catch return false;
        self.editor.cursor = @min(e.cursor_after, self.editor.text.items.len);
        self.undo_stack.append(self.gpa, e) catch {
            self.gpa.free(e.removed);
            self.gpa.free(e.inserted);
        };
        self.last_edit_version = 0;
        return true;
    }

    /// Types `text` at the caret, replacing the selection.
    pub fn insert(self: *Document, text: []const u8) void {
        const e = &self.editor;
        if (e.selection()) |sel| {
            self.replace(sel[0], sel[1], text);
        } else {
            self.replace(e.cursor, e.cursor, text);
        }
    }

    pub fn setMarked(self: *Document, text: []const u8) void {
        if (self.editor.selection()) |sel| self.replace(sel[0], sel[1], "");
        self.editor.marked.clearRetainingCapacity();
        self.editor.marked.appendSlice(self.gpa, text) catch {};
        self.editor.version +%= 1;
    }

    /// Leading blanks of the line the caret is on.
    fn currentIndent(self: *const Document) []const u8 {
        const line = self.lineText(self.lineOf(self.editor.cursor));
        var n: usize = 0;
        while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
        return line[0..n];
    }

    fn indentUnit(self: *const Document) []const u8 {
        return if (self.uses_tabs) "\t" else "    ";
    }

    /// Applies an editing command: mutations are routed through `replace`,
    /// navigation and selection go straight to the editor. Returns false
    /// for commands that are not the document's concern.
    pub fn apply(self: *Document, cmd: EditCommand) bool {
        const e = &self.editor;
        const c = e.cursor;
        switch (cmd) {
            .delete_backward => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else if (c > 0) self.replace(e.prev(c), c, "");
            },
            .delete_forward => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else self.replace(c, e.next(c), "");
            },
            .delete_word_backward => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else self.replace(e.wordLeft(c), c, "");
            },
            .delete_word_forward => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else self.replace(c, e.wordRight(c), "");
            },
            .delete_to_line_start => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else self.replace(e.lineStart(c), c, "");
            },
            .delete_to_line_end => {
                if (e.selection()) |sel| self.replace(sel[0], sel[1], "") else self.replace(c, e.lineEnd(c), "");
            },
            .insert_newline, .insert_line_break => {
                var buf: [256]u8 = undefined;
                const indent = self.currentIndent();
                if (e.selection() == null and indent.len > 0 and indent.len < buf.len and c >= e.lineStart(c) + indent.len) {
                    buf[0] = '\n';
                    @memcpy(buf[1 .. 1 + indent.len], indent);
                    self.insert(buf[0 .. 1 + indent.len]);
                } else {
                    self.insert("\n");
                }
            },
            .insert_tab => {
                if (e.selection()) |sel| {
                    if (self.lineOf(sel[0]) != self.lineOf(sel[1])) return self.indentLines(sel[0], sel[1], true);
                }
                self.insert(self.indentUnit());
            },
            .insert_backtab => {
                const sel = e.selection() orelse [2]usize{ c, c };
                return self.indentLines(sel[0], sel[1], false);
            },
            .select_all => {
                e.anchor = 0;
                e.cursor = e.text.items.len;
                e.version +%= 1;
            },
            else => return e.apply(cmd),
        }
        return true;
    }

    /// Indents (or dedents) every line touched by [from, to] and keeps the
    /// range selected.
    fn indentLines(self: *Document, from: usize, to: usize, indent: bool) bool {
        const first = self.lineOf(from);
        const last = self.lineOf(if (to > from and to > 0 and self.editor.text.items[to - 1] == '\n') to - 1 else to);
        const unit = self.indentUnit();
        var i = last + 1;
        var changed = false;
        while (i > first) {
            i -= 1;
            const ls = self.lineStartOf(i);
            if (indent) {
                if (self.lineText(i).len == 0) continue;
                self.replace(ls, ls, unit);
                changed = true;
            } else {
                const line = self.lineText(i);
                var n: usize = 0;
                if (line.len > 0 and line[0] == '\t') {
                    n = 1;
                } else while (n < line.len and n < 4 and line[n] == ' ') n += 1;
                if (n == 0) continue;
                self.replace(ls, ls + n, "");
                changed = true;
            }
            self.last_edit_version = 0; // each line is its own undo entry
        }
        // Reselect the whole affected block.
        self.editor.anchor = self.lineStartOf(first);
        self.editor.cursor = self.lineEndOf(last);
        self.editor.version +%= 1;
        return changed;
    }

    pub fn selectLine(self: *Document, i: usize) void {
        self.editor.anchor = self.lineStartOf(i);
        self.editor.cursor = if (i + 1 < self.lineCount()) self.lineStartOf(i + 1) else self.lineEndOf(i);
        self.editor.version +%= 1;
    }
};

// ── tests ───────────────────────────────────────────────────────────────
fn expectLines(doc: *const Document, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, doc.lineCount());
    for (expected, 0..) |line, i| try std.testing.expectEqualStrings(line, doc.lineText(i));
}

test "line index follows edits" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.setText("one\ntwo\nthree", .plain);
    try expectLines(&doc, &.{ "one", "two", "three" });
    try std.testing.expectEqual(@as(usize, 1), doc.lineOf(4));
    try std.testing.expectEqual(@as(usize, 2), doc.lineOf(13));

    // Insert a newline inside "two".
    doc.replace(5, 5, "\n");
    try expectLines(&doc, &.{ "one", "t", "wo", "three" });
    // Join lines by deleting a newline.
    doc.replace(3, 4, "");
    try expectLines(&doc, &.{ "onet", "wo", "three" });
    // Replace across several lines with several lines.
    doc.replace(2, 9, "X\nY\nZ");
    try expectLines(&doc, &.{ "onX", "Y", "Zhree" });
    try std.testing.expectEqualStrings("onX\nY\nZhree", doc.bytes());
    // Delete everything.
    doc.replace(0, doc.bytes().len, "");
    try expectLines(&doc, &.{""});
}

test "undo and redo restore text and caret; typing coalesces" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.setText("hello", .plain);
    try std.testing.expect(!doc.modified());
    doc.editor.cursor = 5;
    doc.insert(" ");
    doc.insert("w");
    doc.insert("o");
    doc.insert("rld");
    try std.testing.expectEqualStrings("hello world", doc.bytes());
    try std.testing.expect(doc.modified());
    try std.testing.expectEqual(@as(usize, 1), doc.undo_stack.items.len);
    try std.testing.expect(doc.undo());
    try std.testing.expectEqualStrings("hello", doc.bytes());
    try std.testing.expectEqual(@as(usize, 5), doc.editor.cursor);
    try std.testing.expect(doc.redo());
    try std.testing.expectEqualStrings("hello world", doc.bytes());
    try std.testing.expectEqual(@as(usize, 11), doc.editor.cursor);

    // Moving the caret breaks the run: two entries.
    _ = doc.apply(.move_left);
    doc.insert("!");
    try std.testing.expectEqual(@as(usize, 2), doc.undo_stack.items.len);
    // Backspaces coalesce too, and a new edit clears redo.
    try std.testing.expectEqualStrings("hello worl!d", doc.bytes());
    _ = doc.apply(.delete_backward);
    _ = doc.apply(.delete_backward);
    try std.testing.expectEqualStrings("hello word", doc.bytes());
    try std.testing.expectEqual(@as(usize, 3), doc.undo_stack.items.len);
    try std.testing.expect(doc.undo());
    try std.testing.expectEqualStrings("hello worl!d", doc.bytes());
    try std.testing.expect(doc.undo());
    try std.testing.expect(doc.undo());
    try std.testing.expect(!doc.undo());
    try std.testing.expectEqualStrings("hello", doc.bytes());
    try std.testing.expect(!doc.modified());
    doc.markSaved();
}

test "newline keeps indentation; tab and backtab; crlf round-trips" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.setText("fn main() {\r\n    call();\r\n}\r\n", .plain);
    try std.testing.expect(doc.crlf);
    try expectLines(&doc, &.{ "fn main() {", "    call();", "}", "" });
    doc.editor.cursor = doc.lineEndOf(1);
    _ = doc.apply(.insert_newline);
    try std.testing.expectEqualStrings("    ", doc.lineText(2));
    _ = doc.apply(.insert_tab);
    try std.testing.expectEqualStrings("        ", doc.lineText(2));
    _ = doc.apply(.insert_backtab);
    _ = doc.apply(.insert_backtab);
    try std.testing.expectEqualStrings("", doc.lineText(2));
    const out = try doc.serialize(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fn main() {\r\n    call();\r\n\r\n}\r\n", out);
}

test "selection replace and whole-document operations" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.setText("a\nb\nc", .plain);
    doc.selectLine(1);
    try std.testing.expectEqualStrings("b\n", doc.editor.selectedText());
    doc.insert("B!");
    try std.testing.expectEqualStrings("a\nB!c", doc.bytes());
    _ = doc.apply(.select_all);
    _ = doc.apply(.delete_backward);
    try std.testing.expectEqualStrings("", doc.bytes());
    try std.testing.expectEqual(@as(usize, 1), doc.lineCount());
    try std.testing.expect(doc.undo());
    try std.testing.expectEqualStrings("a\nB!c", doc.bytes());
}

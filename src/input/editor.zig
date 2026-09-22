//! Text model behind the command input: UTF-8 buffer, caret, selection and
//! IME marked text. Rendering and key mapping live elsewhere.
const std = @import("std");
const EditCommand = @import("../events.zig").EditCommand;

pub const Editor = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Caret as a byte offset, always on a code point boundary.
    cursor: usize = 0,
    /// Selection anchor; selection is [min(anchor,cursor), max(anchor,cursor)).
    anchor: ?usize = null,
    /// In-progress IME composition, shown at the caret.
    marked: std.ArrayList(u8) = .empty,
    /// Bumped on every edit so views can reset caret blink, suggestions, etc.
    version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.gpa);
        self.marked.deinit(self.gpa);
    }

    pub fn bytes(self: *const Editor) []const u8 {
        return self.text.items;
    }

    pub fn isEmpty(self: *const Editor) bool {
        return self.text.items.len == 0;
    }

    pub fn selection(self: *const Editor) ?[2]usize {
        const a = self.anchor orelse return null;
        if (a == self.cursor) return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
    }

    pub fn selectedText(self: *const Editor) []const u8 {
        const sel = self.selection() orelse return "";
        return self.text.items[sel[0]..sel[1]];
    }

    pub fn atEnd(self: *const Editor) bool {
        return self.cursor == self.text.items.len;
    }

    // ── mutation ────────────────────────────────────────────────────────
    pub fn setText(self: *Editor, s: []const u8) void {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.gpa, s) catch {};
        self.cursor = self.text.items.len;
        self.anchor = null;
        self.marked.clearRetainingCapacity();
        self.version +%= 1;
    }

    pub fn clear(self: *Editor) void {
        self.setText("");
    }

    pub fn insert(self: *Editor, s: []const u8) void {
        self.marked.clearRetainingCapacity();
        _ = self.deleteSelection();
        if (s.len == 0) return;
        self.text.insertSlice(self.gpa, self.cursor, s) catch return;
        self.cursor += s.len;
        self.version +%= 1;
    }

    pub fn setMarked(self: *Editor, s: []const u8) void {
        _ = self.deleteSelection();
        self.marked.clearRetainingCapacity();
        self.marked.appendSlice(self.gpa, s) catch {};
        self.version +%= 1;
    }

    pub fn deleteSelection(self: *Editor) bool {
        const sel = self.selection() orelse {
            self.anchor = null;
            return false;
        };
        self.removeRange(sel[0], sel[1]);
        self.cursor = sel[0];
        self.anchor = null;
        return true;
    }

    fn removeRange(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        self.text.replaceRange(self.gpa, from, to - from, &.{}) catch return;
        self.version +%= 1;
    }

    // ── navigation helpers ──────────────────────────────────────────────
    pub fn prev(self: *const Editor, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0 and (self.text.items[p] & 0xC0) == 0x80) p -= 1;
        return p;
    }

    pub fn next(self: *const Editor, pos: usize) usize {
        const len = self.text.items.len;
        if (pos >= len) return len;
        var p = pos + 1;
        while (p < len and (self.text.items[p] & 0xC0) == 0x80) p += 1;
        return p;
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
    }

    pub fn wordLeft(self: *const Editor, pos: usize) usize {
        var p = pos;
        while (p > 0 and !isWordByte(self.text.items[p - 1])) p -= 1;
        while (p > 0 and isWordByte(self.text.items[p - 1])) p -= 1;
        return p;
    }

    pub fn wordRight(self: *const Editor, pos: usize) usize {
        const len = self.text.items.len;
        var p = pos;
        while (p < len and !isWordByte(self.text.items[p])) p += 1;
        while (p < len and isWordByte(self.text.items[p])) p += 1;
        return p;
    }

    pub fn lineStart(self: *const Editor, pos: usize) usize {
        var p = pos;
        while (p > 0 and self.text.items[p - 1] != '\n') p -= 1;
        return p;
    }

    pub fn lineEnd(self: *const Editor, pos: usize) usize {
        var p = pos;
        while (p < self.text.items.len and self.text.items[p] != '\n') p += 1;
        return p;
    }

    fn moveTo(self: *Editor, pos: usize, extend: bool) void {
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
        self.cursor = pos;
        self.version +%= 1;
    }

    pub fn setCursor(self: *Editor, pos: usize, extend: bool) void {
        var p = @min(pos, self.text.items.len);
        while (p > 0 and p < self.text.items.len and (self.text.items[p] & 0xC0) == 0x80) p -= 1;
        self.moveTo(p, extend);
    }

    pub fn selectWordAt(self: *Editor, pos: usize) void {
        const p = @min(pos, self.text.items.len);
        var start = p;
        var end = p;
        const word = p < self.text.items.len and isWordByte(self.text.items[p]);
        if (word) {
            while (start > 0 and isWordByte(self.text.items[start - 1])) start -= 1;
            while (end < self.text.items.len and isWordByte(self.text.items[end])) end += 1;
        } else if (p < self.text.items.len) {
            end = self.next(p);
        }
        self.anchor = start;
        self.cursor = end;
        self.version +%= 1;
    }

    /// True when the text spans several lines (so ↑/↓ should move the caret
    /// instead of browsing history).
    pub fn isMultiline(self: *const Editor) bool {
        return std.mem.indexOfScalar(u8, self.text.items, '\n') != null;
    }

    fn moveVertical(self: *Editor, up: bool, extend: bool) bool {
        const ls = self.lineStart(self.cursor);
        const col = self.cursor - ls;
        if (up) {
            if (ls == 0) return false;
            const prev_start = self.lineStart(ls - 1);
            self.moveTo(@min(prev_start + col, ls - 1), extend);
        } else {
            const le = self.lineEnd(self.cursor);
            if (le >= self.text.items.len) return false;
            const next_end = self.lineEnd(le + 1);
            self.moveTo(@min(le + 1 + col, next_end), extend);
        }
        return true;
    }

    /// Applies an editing command. Returns false if the command is not an
    /// editor concern (or could not move), so the caller may reinterpret it.
    pub fn apply(self: *Editor, cmd: EditCommand) bool {
        switch (cmd) {
            .move_left => {
                if (self.selection()) |sel| self.moveTo(sel[0], false) else self.moveTo(self.prev(self.cursor), false);
            },
            .move_right => {
                if (self.selection()) |sel| self.moveTo(sel[1], false) else self.moveTo(self.next(self.cursor), false);
            },
            .select_left => self.moveTo(self.prev(self.cursor), true),
            .select_right => self.moveTo(self.next(self.cursor), true),
            .move_word_left => self.moveTo(self.wordLeft(self.cursor), false),
            .move_word_right => self.moveTo(self.wordRight(self.cursor), false),
            .select_word_left => self.moveTo(self.wordLeft(self.cursor), true),
            .select_word_right => self.moveTo(self.wordRight(self.cursor), true),
            .move_line_start => self.moveTo(self.lineStart(self.cursor), false),
            .move_line_end => self.moveTo(self.lineEnd(self.cursor), false),
            .select_line_start => self.moveTo(self.lineStart(self.cursor), true),
            .select_line_end => self.moveTo(self.lineEnd(self.cursor), true),
            .move_doc_start => self.moveTo(0, false),
            .move_doc_end => self.moveTo(self.text.items.len, false),
            .select_doc_start => self.moveTo(0, true),
            .select_doc_end => self.moveTo(self.text.items.len, true),
            .move_up => return self.moveVertical(true, false),
            .move_down => return self.moveVertical(false, false),
            .select_up => return self.moveVertical(true, true),
            .select_down => return self.moveVertical(false, true),
            .select_all => {
                self.anchor = 0;
                self.cursor = self.text.items.len;
                self.version +%= 1;
            },
            .delete_backward => {
                if (!self.deleteSelection()) {
                    const p = self.prev(self.cursor);
                    self.removeRange(p, self.cursor);
                    self.cursor = p;
                }
            },
            .delete_forward => {
                if (!self.deleteSelection()) self.removeRange(self.cursor, self.next(self.cursor));
            },
            .delete_word_backward => {
                if (!self.deleteSelection()) {
                    const p = self.wordLeft(self.cursor);
                    self.removeRange(p, self.cursor);
                    self.cursor = p;
                }
            },
            .delete_word_forward => {
                if (!self.deleteSelection()) self.removeRange(self.cursor, self.wordRight(self.cursor));
            },
            .delete_to_line_start => {
                if (!self.deleteSelection()) {
                    const p = self.lineStart(self.cursor);
                    self.removeRange(p, self.cursor);
                    self.cursor = p;
                }
            },
            .delete_to_line_end => {
                if (!self.deleteSelection()) self.removeRange(self.cursor, self.lineEnd(self.cursor));
            },
            .insert_line_break => self.insert("\n"),
            else => return false,
        }
        return true;
    }
};

// ── tests ────────────────────────────────────────────────────────────────
test "insert, move and delete respect utf-8 boundaries" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.insert("echo ñandú");
    try std.testing.expectEqual(e.text.items.len, e.cursor);
    _ = e.apply(.delete_backward);
    try std.testing.expectEqualStrings("echo ñand", e.bytes());
    _ = e.apply(.move_line_start);
    _ = e.apply(.move_word_right);
    try std.testing.expectEqual(@as(usize, 4), e.cursor);
    _ = e.apply(.move_right);
    _ = e.apply(.delete_forward);
    try std.testing.expectEqualStrings("echo and", e.bytes());
}

test "selection replace and word delete" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.insert("git status --short");
    _ = e.apply(.select_word_left);
    try std.testing.expectEqualStrings("short", e.selectedText());
    e.insert("sb");
    try std.testing.expectEqualStrings("git status --sb", e.bytes());
    _ = e.apply(.delete_word_backward);
    _ = e.apply(.delete_word_backward);
    try std.testing.expectEqualStrings("git ", e.bytes());
    _ = e.apply(.select_all);
    try std.testing.expect(e.deleteSelection());
    try std.testing.expect(e.isEmpty());
}

test "vertical movement in multi-line input" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.insert("for f in *; do\n  echo $f\ndone");
    try std.testing.expect(e.isMultiline());
    try std.testing.expect(e.apply(.move_up));
    try std.testing.expect(e.apply(.move_up));
    try std.testing.expect(!e.apply(.move_up));
    try std.testing.expectEqual(@as(usize, 4), e.cursor);
}

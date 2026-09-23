//! What every document viewer shares — file, image, PDF and whatever comes
//! next: the body they draw into, a one-line notice for the failure cases,
//! scroll-key handling and size formatting. A viewer gets the whole tab,
//! edge to edge, the way a full-screen program takes a terminal: no card,
//! no margins, no header row. The file's name is the tab's title and what
//! it is (kind, size, state) goes in the tab's `info`, the context line at
//! the right of the tab strip, so the content starts right under the strip.
const std = @import("std");
const records = @import("../records.zig");
const sys = @import("../sys.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const filetype = @import("../filetype.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

/// Clears the tab's area and returns it as the body: all of it, from the
/// line under the strip to the pane's edges.
pub fn frame(ui: *Ui, rect: Rect) Rect {
    ui.dl.rect(rect, theme.bg);
    return rect;
}

/// The kind a viewer names first in its context line: the extension in
/// capitals ("PNG", "HEIC"), or `fallback` when the file has none.
pub fn kindLabel(path: []const u8, fallback: []const u8, buf: []u8) []const u8 {
    const ext = filetype.extension(path);
    if (ext.len == 0 or ext.len > buf.len) return fallback;
    return std.ascii.upperString(buf[0..ext.len], ext);
}

/// A quiet one-liner in the body: empty file, cannot open, …
pub fn notice(ui: *Ui, body: Rect, text: []const u8) void {
    _ = ui.dl.textCentered(theme.font_hint, body.x + theme.block_pad_x, body.y + 24, text, theme.text_3);
}

/// Keyboard scrolling shared by the viewers: returns the new offset, ≥ 0
/// (the caller clamps the top end when it knows the content height).
pub fn scrollKey(cmd: EditCommand, scroll: f32, line: f32, page: f32, end: f32) f32 {
    const next = switch (cmd) {
        .move_up => scroll - line,
        .move_down => scroll + line,
        .page_up => scroll - page,
        .page_down => scroll + page,
        .scroll_to_top, .move_doc_start => 0,
        .scroll_to_bottom, .move_doc_end => end,
        else => scroll,
    };
    return @max(0, next);
}

pub fn formatSize(bytes: usize, buf: []u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024) return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{kb / 1024.0}) catch "";
}

// ── across relaunches ────────────────────────────────────────────────────
/// What a viewer keeps across relaunches (see workspace.zig): one `file`
/// record with the path, then whatever the kind adds as tab-separated
/// fields (a caret, a mode, a page …) that it reads back from `Kept`.
pub fn keep(out: *std.ArrayList(u8), gpa: std.mem.Allocator, file_path: []const u8, extra: []const u8) bool {
    out.appendSlice(gpa, "file\t") catch return false;
    records.escape(out, gpa, file_path) catch return false;
    if (extra.len > 0) {
        out.append(gpa, '\t') catch return false;
        out.appendSlice(gpa, extra) catch return false;
    }
    out.append(gpa, '\n') catch return false;
    return true;
}

/// Changes whenever `keep` would write something different.
pub fn keptVersion(file_path: []const u8, extra: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(file_path);
    h.update(&[_]u8{0});
    h.update(extra);
    return h.final();
}

pub const Kept = struct {
    /// Owned by the caller.
    path: []u8,
    /// The kind's own fields, tab-separated, pointing into the saved text.
    extra: []const u8,

    pub fn deinit(self: *Kept, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }

    /// Field `i` of the kind's own fields; null when absent or empty.
    pub fn field(self: Kept, i: usize) ?[]const u8 {
        var f = std.mem.splitScalar(u8, self.extra, '\t');
        var k: usize = 0;
        while (f.next()) |v| : (k += 1) {
            if (k == i) return if (v.len == 0) null else v;
        }
        return null;
    }
};

/// What `keep` wrote in an earlier run: null when the tab is not being
/// restored, `error.FileGone` when the file it showed no longer exists
/// (there is nothing to show, so the tab is not brought back).
pub fn kept(gpa: std.mem.Allocator, saved: ?[]const u8) !?Kept {
    const text = saved orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, f.next() orelse continue, "file")) continue;
        const raw = f.next() orelse continue;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const path = try records.unescape(&buf, gpa, raw);
        if (sys.statFile(gpa, path) == null) return error.FileGone;
        return .{ .path = try gpa.dupe(u8, path), .extra = f.rest() };
    }
    return null;
}

test "viewer: what a file viewer keeps comes back, unless the file is gone" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(keep(&out, gpa, "/no/such/a\tb.txt", "12\tsource"));
    try std.testing.expectEqualStrings("file\t/no/such/a\\tb.txt\t12\tsource\n", out.items);
    try std.testing.expect(try kept(gpa, null) == null);
    try std.testing.expectError(error.FileGone, kept(gpa, out.items));
    out.clearRetainingCapacity();
    try std.testing.expect(keep(&out, gpa, "/tmp", "3"));
    var k = (try kept(gpa, out.items)).?;
    defer k.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp", k.path);
    try std.testing.expectEqualStrings("3", k.field(0).?);
    try std.testing.expect(k.field(1) == null);
    try std.testing.expect(keptVersion("/tmp", "3") != keptVersion("/tmp", "4"));
}

//! What every document viewer shares — file, image, PDF and whatever comes
//! next: the centred card with its header row (icon, name, meta on the
//! right), a one-line notice for the failure cases, scroll-key handling
//! and size formatting. A new viewer draws only its body.
const std = @import("std");
const records = @import("../records.zig");
const sys = @import("../sys.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("../gfx/icons.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const head_h: f32 = 46;

/// The card a viewer lives in, centred in the content area.
pub fn card(rect: Rect) Rect {
    const col_w = @max(240, @min(theme.content_max_w, rect.w - 2 * theme.content_pad));
    const col_x = rect.x + (rect.w - col_w) / 2;
    return .{ .x = col_x, .y = rect.y + theme.content_pad, .w = col_w, .h = rect.h - 2 * theme.content_pad };
}

/// Draws the card and its header; returns the body under the divider.
pub fn header(ui: *Ui, c: Rect, icon: icons.Icon, name: []const u8, meta: []const u8) Rect {
    return headerWith(ui, c, icon, name, meta, 0);
}

/// `header` with `trailing` points kept free at the right end of the header
/// row, for a control the viewer draws there itself (see `trailingRect`).
pub fn headerWith(ui: *Ui, c: Rect, icon: icons.Icon, name: []const u8, meta: []const u8, trailing: f32) Rect {
    const dl = ui.dl;
    dl.shape(c, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
    const px = c.x + theme.block_pad_x;
    const hcy = c.y + head_h / 2;
    dl.icon(icon, px, hcy - 8, 16, theme.text_3);
    const meta_right = c.right() - theme.block_pad_x - (if (trailing > 0) trailing + 14 else 0);
    const mw = dl.textRight(theme.font_hint, meta_right, hcy, meta, theme.text_3);
    const name_x = px + 16 + 10;
    _ = dl.textEllipsis(theme.font_ui_medium, name_x, hcy, name, meta_right - mw - 12 - name_x, theme.text);
    dl.rect(.{ .x = c.x, .y = c.y + head_h, .w = c.w, .h = 1 }, theme.line);
    return .{ .x = c.x, .y = c.y + head_h + 1, .w = c.w, .h = @max(0, c.h - head_h - 1) };
}

/// The area `headerWith` kept free: `w` × `h` points, right-aligned and
/// vertically centred in the header row of card `c`.
pub fn trailingRect(c: Rect, w: f32, h: f32) Rect {
    return .{ .x = c.right() - theme.block_pad_x - w, .y = c.y + (head_h - h) / 2, .w = w, .h = h };
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

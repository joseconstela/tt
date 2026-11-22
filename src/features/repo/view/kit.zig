//! Small drawing helpers the repository tab's views share: section
//! labels, the status letter of a file, count pills, the two kinds of
//! button, an author's initials in a circle, the "+12 −3" of a change.
//! Colours come from the theme's tokens, so every view follows the style
//! in use; the design's fixed hues (green for added, red for removed,
//! amber for modified, one colour per graph lane) map onto the theme's
//! terminal colours.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const icons = @import("../../../gfx/icons.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

pub const font_label = Font.semibold(11);
pub const font_text = Font.sans(13);
pub const font_text_bold = Font.semibold(13);
pub const font_small = Font.sans(12);
pub const font_mono = Font.mono(12);
pub const font_mono_small = Font.mono(11);
pub const font_chip = Font.mono(10.5);
pub const font_title = Font.semibold(14);
pub const font_button = Font.medium(12.5);

pub fn green() Color {
    return theme.ansi[2];
}

pub fn amber() Color {
    return theme.ansi[3];
}

pub fn purple() Color {
    return theme.ansi[5];
}

pub fn blue() Color {
    return theme.ansi[4];
}

/// The colour of a graph lane, of a branch's chip, of an author's
/// initials: a short cycle of the theme's hues.
pub fn hue(i: usize) Color {
    return switch (i % 6) {
        0 => theme.ansi[4],
        1 => theme.teal,
        2 => theme.ansi[5],
        3 => theme.ansi[3],
        4 => theme.ansi[2],
        else => theme.ansi[6],
    };
}

/// A steady colour for a name (the same author always gets the same one).
pub fn hueOf(name: []const u8) Color {
    var h: u32 = 0;
    for (name) |ch| h = h *% 31 +% ch;
    return hue(h % 6);
}

/// The colour a file's status letter gets.
pub fn letterColor(letter: u8) Color {
    return switch (letter) {
        'A', 'U', '?' => green(),
        'D', '!' => theme.red,
        'R', 'C' => blue(),
        else => amber(),
    };
}

/// An upper-case label over a group ("BRANCHES"); returns its width.
pub fn label(ui: *Ui, x: f32, cy: f32, text: []const u8) f32 {
    return ui.dl.textCentered(font_label, x, cy, text, theme.text_3);
}

/// A file's status letter on a tinted square, its left edge at `x`.
pub fn badge(ui: *Ui, x: f32, cy: f32, letter: u8, size: f32) void {
    const color = letterColor(letter);
    const r: Rect = .{ .x = x, .y = cy - size / 2, .w = size, .h = size };
    ui.dl.rrect(r, 4, color.alpha(0.17));
    const s = [_]u8{letter};
    const w = ui.text.measure(font_mono_small, &s);
    _ = ui.dl.textCentered(font_mono_small, r.x + (size - w) / 2, cy, &s, color);
}

/// A number on a pill, its right edge at `right`; returns the pill's width.
pub fn countPill(ui: *Ui, right: f32, cy: f32, n: usize) f32 {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return 0;
    const w = ui.text.measure(font_mono_small, s) + 12;
    const r: Rect = .{ .x = right - w, .y = cy - 9, .w = w, .h = 18 };
    ui.dl.rrect(r, 9, theme.chip_active);
    _ = ui.dl.textCentered(font_mono_small, r.x + 6, cy, s, theme.text_2);
    return w;
}

/// "+12 −3" ending at `right`, the counts in green and red; a count of
/// zero on both sides draws nothing. Returns the width used.
pub fn plusMinus(ui: *Ui, right: f32, cy: f32, added: u32, removed: u32, font: Font) f32 {
    if (added == 0 and removed == 0) return 0;
    var a_buf: [16]u8 = undefined;
    var r_buf: [20]u8 = undefined;
    var x = right;
    if (removed > 0) {
        const s = std.fmt.bufPrint(&r_buf, "−{d}", .{removed}) catch "";
        x -= ui.dl.textRight(font, x, cy, s, theme.red);
    }
    if (added > 0) {
        if (removed > 0) x -= 6;
        const s = std.fmt.bufPrint(&a_buf, "+{d}", .{added}) catch "";
        x -= ui.dl.textRight(font, x, cy, s, green());
    }
    return right - x;
}

pub const ButtonStyle = enum { primary, secondary };

/// A labelled button, an icon before the label when one is given. Dim and
/// inert when `enabled` is false. True when clicked.
pub fn button(ui: *Ui, wid: u64, r: Rect, text: []const u8, icon: ?icons.Icon, style: ButtonStyle, enabled: bool) bool {
    const dl = ui.dl;
    var st: ui_mod.ButtonState = .{};
    if (enabled) st = ui.button(wid, r);
    const fill: Color = switch (style) {
        .primary => if (!enabled) theme.accent.alpha(0.35) else if (st.held) Color.mix(theme.accent, theme.on_accent, 0.15) else if (st.hover) Color.mix(theme.accent, theme.text, 0.12) else theme.accent,
        .secondary => if (st.held) theme.pressed else if (st.hover) theme.hover else theme.chip_active,
    };
    dl.rrect(r, 8, fill);
    if (style == .secondary) dl.border(r, 8, 1, theme.line);
    const ink: Color = switch (style) {
        .primary => if (enabled) theme.on_accent else theme.on_accent.alpha(0.7),
        .secondary => if (!enabled) theme.text_3.alpha(0.6) else if (st.hover) theme.text else theme.text_2,
    };
    const tw = ui.text.measure(font_button, text);
    const iw: f32 = if (icon != null) 14 + 6 else 0;
    var x = r.x + @max(6, (r.w - tw - iw) / 2);
    if (icon) |ic| {
        dl.icon(ic, x, r.centerY() - 7, 14, ink);
        x += 20;
    }
    _ = dl.textEllipsis(font_button, x, r.centerY(), text, @max(0, r.right() - 6 - x), ink);
    return st.clicked;
}

pub const Split = struct {
    /// The button itself was clicked.
    clicked: bool = false,
    /// The arrow inside it was: its menu is wanted.
    arrow: bool = false,
    /// Where the arrow is, to hang the menu from.
    arrow_rect: Rect,
};

/// One primary button with an arrow inside its right end, past a thin
/// rule: the button does the thing, the arrow opens the choices about
/// how. It is drawn as a single shape; each part lights up on its own
/// under the pointer. When `enabled` is false the button is dim and
/// inert, but the arrow still answers (a choice may be what enables it).
pub fn splitButton(ui: *Ui, wid: u64, arrow_wid: u64, r: Rect, text: []const u8, icon: ?icons.Icon, font: Font, enabled: bool) Split {
    const dl = ui.dl;
    const arrow_w = @min(r.h, r.w / 3);
    const main: Rect = .{ .x = r.x, .y = r.y, .w = r.w - arrow_w, .h = r.h };
    const arrow: Rect = .{ .x = main.right(), .y = r.y, .w = arrow_w, .h = r.h };
    var st: ui_mod.ButtonState = .{};
    if (enabled) st = ui.button(wid, main);
    const ast = ui.button(arrow_wid, arrow);

    dl.rrect(r, 8, if (enabled) theme.accent else theme.accent.alpha(0.35));
    // A part under the pointer is tinted through a clip, so the shape's
    // own corners stay round and nothing shows between the two.
    inline for (.{ .{ main, st }, .{ arrow, ast } }) |part| {
        const tint: ?Color = if (part[1].held) theme.on_accent.alpha(0.15) else if (part[1].hover) theme.text.alpha(0.12) else null;
        if (tint) |c| {
            dl.pushClip(part[0]);
            dl.rrect(r, 8, c);
            dl.popClip();
        }
    }
    dl.rect(.{ .x = arrow.x, .y = r.y + 7, .w = 1, .h = @max(0, r.h - 14) }, theme.on_accent.alpha(0.28));

    const ink = if (enabled) theme.on_accent else theme.on_accent.alpha(0.7);
    const icon_size: f32 = if (font.size >= 14) 16 else 14;
    const tw = ui.text.measure(font, text);
    const iw: f32 = if (icon != null) icon_size + 4 else 0;
    var x = main.x + @max(6, (main.w - tw - iw) / 2);
    if (icon) |ic| {
        dl.icon(ic, x, r.centerY() - icon_size / 2, icon_size, ink);
        x += iw;
    }
    _ = dl.textEllipsis(font, x, r.centerY(), text, @max(0, main.right() - 6 - x), ink);
    dl.icon(.chevron_down, arrow.x + (arrow.w - 14) / 2, r.centerY() - 7, 14, theme.on_accent);
    return .{ .clicked = st.clicked, .arrow = ast.clicked, .arrow_rect = arrow };
}

/// The width `button` wants for `text` (with an icon when `with_icon`).
pub fn buttonWidth(ui: *Ui, text: []const u8, with_icon: bool) f32 {
    return ui.text.measure(font_button, text) + 24 + @as(f32, if (with_icon) 20 else 0);
}

/// Up to two initials of a name ("María Lado" → "ML"), upper-cased when
/// they are plain letters.
pub fn initials(name: []const u8, buf: *[8]u8) []const u8 {
    var n: usize = 0;
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, name, " \t._-");
    while (words.next()) |w| {
        if (count == 2) break;
        const len = std.unicode.utf8ByteSequenceLength(w[0]) catch 1;
        if (len > w.len or n + len > buf.len) break;
        @memcpy(buf[n..][0..len], w[0..len]);
        if (len == 1) buf[n] = std.ascii.toUpper(buf[n]);
        n += len;
        count += 1;
    }
    return buf[0..n];
}

/// An author as a circle with their initials, centred on (cx, cy).
pub fn avatar(ui: *Ui, cx: f32, cy: f32, diameter: f32, name: []const u8) void {
    ui.dl.circle(cx, cy, diameter / 2, theme.chip_active);
    var buf: [8]u8 = undefined;
    const s = initials(name, &buf);
    const font = Font.semibold(if (diameter >= 24) 10.5 else if (diameter >= 20) 9.5 else 8.5);
    const w = ui.text.measure(font, s);
    _ = ui.dl.textCentered(font, cx - w / 2, cy, s, hueOf(name));
}

/// A name on an outlined pill (a branch, a tag, a label); returns its width.
pub fn chip(ui: *Ui, x: f32, cy: f32, text: []const u8, color: Color, max_w: f32) f32 {
    const tw = @min(ui.text.measure(font_chip, text), @max(0, max_w - 14));
    const r: Rect = .{ .x = x, .y = cy - 9, .w = tw + 14, .h = 18 };
    ui.dl.shape(r, 9, color.alpha(0.08), 1, color.alpha(0.5));
    _ = ui.dl.textEllipsis(font_chip, r.x + 7, cy, text, tw, color);
    return r.w;
}

pub fn chipWidth(ui: *Ui, text: []const u8) f32 {
    return ui.text.measure(font_chip, text) + 14;
}

/// A line of code from `x`, its tabs taken to the next stop (every four
/// cells of `font`, which is a monospaced one). Returns the width drawn;
/// the caller clips.
pub fn code(ui: *Ui, font: Font, x: f32, cy: f32, text: []const u8, color: Color) f32 {
    const stop = ui.text.cellAdvance(font) * 4;
    var pen: f32 = 0;
    var first = true;
    var parts = std.mem.splitScalar(u8, text, '\t');
    while (parts.next()) |part| {
        if (!first) pen = (@floor(pen / stop) + 1) * stop;
        first = false;
        if (part.len > 0) pen += ui.dl.textCentered(font, x + pen, cy, part, color);
    }
    return pen;
}

/// True when `needle` is in `hay`, letters compared without their case.
pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "initials" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ML", initials("María Lado", &buf));
    try std.testing.expectEqualStrings("JC", initials("jose constela vidal", &buf));
    try std.testing.expectEqualStrings("A", initials("anxo", &buf));
    // Only plain letters are upper-cased; others stay as written.
    try std.testing.expectEqualStrings("ÁR", initials("Ánxel rivas", &buf));
    try std.testing.expectEqualStrings("", initials("", &buf));
}

test "contains, whatever the case" {
    try std.testing.expect(containsIgnoreCase("feat(Webhooks): retries", "webhooks"));
    try std.testing.expect(!containsIgnoreCase("fix", "fixes"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

//! Greedy word wrapping over the text engine, shared by the views that
//! show prose the app did not lay out itself: an agent's explanation
//! under a failed block or cell, a note in a block. `ctx.line(s)` is
//! called once per visual line; the counting variants pass a no-op.
const std = @import("std");
const ui_mod = @import("ui.zig");
const gfx_text = @import("../gfx/text.zig");

const Ui = ui_mod.Ui;
const Color = ui_mod.Color;

/// Greedy word wrap of one paragraph; calls `ctx.line` per line, returns
/// the line count (at least 1).
pub fn wrapLines(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32, ctx: anytype) u32 {
    var lines: u32 = 0;
    var start: usize = 0;
    while (start < str.len) {
        var end = start;
        var last_break: ?usize = null;
        var w: f32 = 0;
        var it = gfx_text.Utf8Iter{ .bytes = str, .index = start };
        while (it.next()) |cp| {
            const adv = ui.text.advance(font, cp);
            if (w + adv > max_w and end > start) break;
            w += adv;
            end = it.index;
            if (cp == ' ') last_break = end;
        }
        if (end < str.len) {
            if (last_break) |lb| end = lb;
        }
        ctx.line(std.mem.trimEnd(u8, str[start..end], " "));
        lines += 1;
        start = end;
    }
    return @max(lines, 1);
}

/// Word wrap that keeps the text's own line breaks: every line of `str`
/// wraps on its own, an empty one stays an empty line. Returns the count.
pub fn wrapParagraphs(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32, ctx: anytype) u32 {
    const trimmed = std.mem.trim(u8, str, "\n");
    var lines: u32 = 0;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |para| {
        if (para.len == 0) {
            ctx.line("");
            lines += 1;
        } else lines += wrapLines(ui, font, para, max_w, ctx);
    }
    return @max(lines, 1);
}

const Counter = struct {
    fn line(_: @This(), _: []const u8) void {}
};

pub fn wrapParagraphCount(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32) u32 {
    return wrapParagraphs(ui, font, str, max_w, Counter{});
}

pub fn wrapCount(ui: *Ui, font: ui_mod.Font, str: []const u8, max_w: f32) u32 {
    return wrapLines(ui, font, str, max_w, Counter{});
}

const Painter = struct {
    ui: *Ui,
    font: ui_mod.Font,
    x: f32,
    y: *f32,
    lh: f32,
    color: Color,
    fn line(p: @This(), s: []const u8) void {
        if (s.len > 0) _ = p.ui.dl.textCentered(p.font, p.x, p.y.* + p.lh / 2, s, p.color);
        p.y.* += p.lh;
    }
};

/// Draws `str` wrapped to `max_w` from (x, y), `lh` per line, keeping its
/// own line breaks; returns the y below the last line.
pub fn drawWrappedParagraphs(ui: *Ui, font: ui_mod.Font, str: []const u8, x: f32, y: f32, max_w: f32, lh: f32, color: Color) f32 {
    var cy = y;
    _ = wrapParagraphs(ui, font, str, max_w, Painter{ .ui = ui, .font = font, .x = x, .y = &cy, .lh = lh, .color = color });
    return cy;
}

/// Draws one paragraph wrapped to `max_w`; returns the y below it.
pub fn drawWrapped(ui: *Ui, font: ui_mod.Font, str: []const u8, x: f32, y: f32, max_w: f32, lh: f32, color: Color) f32 {
    var cy = y;
    _ = wrapLines(ui, font, str, max_w, Painter{ .ui = ui, .font = font, .x = x, .y = &cy, .lh = lh, .color = color });
    return cy;
}

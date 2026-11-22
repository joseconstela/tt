//! The Stashes view: the changes put away, newest first, each with
//! "Apply" (bring it back and drop it from the list) and "Drop" (throw it
//! away, after asking), and above the list "Stash changes" for what the
//! working tree holds now. Nothing is run here: what was asked for comes
//! out of `takeIntent`.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const log_mod = @import("../model/log.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const pad: f32 = 16;
const bar_h: f32 = 48;
const row_h: f32 = 44;

pub const State = struct {
    stashes: []const log_mod.Stash,
    /// The working tree has something to put away.
    dirty: bool,
    busy: bool,
    cmd_label: []const u8,
    last_error: []const u8,
};

pub const Intent = union(enum) {
    stash,
    apply: []const u8,
    /// The tab asks before it throws the stash away.
    drop: []const u8,
};

pub const View = struct {
    intent: ?Intent = null,
    scroll: f32 = 0,

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    pub fn draw(self: *View, ui: *Ui, rect: Rect, state: State) void {
        const dl = ui.dl;
        dl.pushClip(rect);
        defer dl.popClip();
        {
            const bw = kit.buttonWidth(ui, "Stash changes", true);
            const br: Rect = .{ .x = rect.x + pad, .y = rect.y + (bar_h - 32) / 2, .w = bw, .h = 32 };
            if (kit.button(ui, Ui.id("repo.stash.push", 0), br, "Stash changes", .stash, .secondary, state.dirty and !state.busy)) self.intent = .stash;
            const note: []const u8 = if (state.cmd_label.len > 0) state.cmd_label else state.last_error;
            if (note.len > 0) _ = dl.textEllipsis(kit.font_small, br.right() + 14, br.centerY(), note, @max(0, rect.right() - pad - br.right() - 14), if (state.cmd_label.len > 0) theme.text_3 else theme.red);
            dl.rect(.{ .x = rect.x, .y = rect.y + bar_h - 1, .w = rect.w, .h = 1 }, theme.line);
        }
        const area: Rect = .{ .x = rect.x, .y = rect.y + bar_h, .w = rect.w, .h = @max(0, rect.h - bar_h) };
        if (state.stashes.len == 0) {
            _ = dl.textEllipsis(kit.font_text, area.x + pad, area.y + 24, "Nothing is stashed.", area.w - 2 * pad, theme.text_3);
            return;
        }
        const content_h = @as(f32, @floatFromInt(state.stashes.len)) * row_h;
        const max_scroll = @max(0, content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        for (state.stashes, 0..) |s, i| {
            const row: Rect = .{ .x = area.x, .y = area.y + @as(f32, @floatFromInt(i)) * row_h - self.scroll, .w = area.w, .h = row_h };
            if (row.bottom() < area.y or row.y > area.bottom()) continue;
            dl.rect(.{ .x = row.x, .y = row.bottom() - 1, .w = row.w, .h = 1 }, theme.line.alpha(0.6));
            var right = row.right() - pad;
            const dw = kit.buttonWidth(ui, "Drop", false);
            right -= dw;
            if (kit.button(ui, Ui.id("repo.stash.drop", i), .{ .x = right, .y = row.centerY() - 14, .w = dw, .h = 28 }, "Drop", null, .secondary, !state.busy)) self.intent = .{ .drop = s.name };
            const aw = kit.buttonWidth(ui, "Apply", false);
            right -= aw + 8;
            if (kit.button(ui, Ui.id("repo.stash.apply", i), .{ .x = right, .y = row.centerY() - 14, .w = aw, .h = 28 }, "Apply", null, .secondary, !state.busy)) self.intent = .{ .apply = s.name };
            dl.icon(.stash, row.x + pad, row.centerY() - 8, 16, theme.text_3);
            const nw = dl.textCentered(kit.font_mono, row.x + pad + 26, row.centerY(), s.name, theme.text_3);
            _ = dl.textEllipsis(kit.font_text, row.x + pad + 26 + nw + 12, row.centerY(), s.subject, @max(0, right - 12 - (row.x + pad + 26 + nw + 12)), theme.text);
        }
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, content_h);
    }
};

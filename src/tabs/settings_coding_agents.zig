//! Settings › AI › Agents: the coding agents on this Mac (Claude Code,
//! Codex, Gemini CLI …), as found by `coding_agents.zig`. One card per
//! known agent says whether it is installed and where, how "Fix with
//! agent" starts it, and which one fixes use by default; a card that is
//! not installed says how to get it. Nothing here is typed in: the page
//! reflects the machine, plus the one choice (the default) that lives in
//! `config.features.fix_agent`.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const config = @import("../config.zig");
const coding_agents = @import("../coding_agents.zig");
const sys = @import("../sys.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const card_pad: f32 = 18;
/// One line of the card's small text.
const small_h: f32 = 20;

pub const Page = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Page) void {
        _ = self;
    }

    /// Draws the page in the column at `x`, from `y0` down; returns the y
    /// where it ends.
    pub fn draw(self: *Page, ui: *Ui, x: f32, y0: f32, col_w: f32) f32 {
        _ = self;
        const scan = coding_agents.get();
        var y = drawSummary(ui, scan, x, y0, col_w);
        // Installed agents first, in the order they are known; then the rest.
        for (scan.found.items) |*f| {
            y += theme.block_gap;
            y = drawCard(ui, scan, f.known, f.path, x, y, col_w);
        }
        for (&coding_agents.known) |*k| {
            if (scan.find(k.id) != null) continue;
            y += theme.block_gap;
            y = drawCard(ui, scan, k, null, x, y, col_w);
        }
        return y;
    }

    /// The card on top: how many were found, and the button to look again.
    fn drawSummary(ui: *Ui, scan: *coding_agents.Scan, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        var title_buf: [64]u8 = undefined;
        const n = scan.found.items.len;
        const title: []const u8 = switch (n) {
            0 => "No coding agent found",
            1 => "One coding agent installed",
            else => std.fmt.bufPrint(&title_buf, "{d} coding agents installed", .{n}) catch "Coding agents installed",
        };
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, title, theme.text);
        var hint_buf: [160]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Looked for {d} known agents in your PATH and the usual install folders. Fix with agent runs the default one.", .{coding_agents.known.len}) catch "";

        const label = "Look again";
        const bw = ui.text.measure(theme.font_hint, label) + 20;
        const br: Rect = .{ .x = card.right() - card_pad - bw, .y = card.y + 28 - 13, .w = bw, .h = 26 };
        dl.border(br, 6, 1, theme.line_strong);
        if (field.textButton(ui, Ui.id("coding_agents.rescan", 0), br, label, theme.text_2)) scan.rescan();
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, hint, card.w - 2 * card_pad, theme.text_3);
        return card.bottom();
    }

    /// One known agent: installed (where, and the line that starts it) or
    /// not (how to install it). The installed one that fixes use carries a
    /// "Default" pill; the others offer "Use for fixes".
    fn drawCard(ui: *Ui, scan: *coding_agents.Scan, k: *const coding_agents.Known, path: ?[]const u8, x: f32, y0: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const f = &cfg.features;
        const installed = path != null;
        const card: Rect = .{ .x = x, .y = y0, .w = col_w, .h = card_pad + 22 + 10 + 3 * small_h + card_pad - 4 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);

        // Header: icon, name, installed pill; on the right the default pill
        // or the button that makes it the default.
        const hcy = card.y + card_pad + 11;
        dl.icon(.terminal, card.x + card_pad, hcy - 8, 16, if (installed) theme.text_2 else theme.text_3);
        var right = card.right() - card_pad;
        if (installed) {
            const is_default = if (f.fixAuto()) (if (scan.first()) |first| first.known == k else false) else std.mem.eql(u8, f.fix_agent, k.id);
            if (is_default) {
                const tag: []const u8 = if (f.fixAuto()) "Default · automatic" else "Default";
                right = pill(ui, right, hcy, tag, theme.accent, theme.on_accent) - 10;
            } else if (!f.fixOff()) {
                const label = "Use for fixes";
                const bw = ui.text.measure(theme.font_hint, label) + 20;
                const br: Rect = .{ .x = right - bw, .y = hcy - 13, .w = bw, .h = 26 };
                if (field.textButton(ui, Ui.id("coding_agents.default", @intFromPtr(k)), br, label, theme.text_2)) {
                    cfg.setString(&f.fix_agent, k.id);
                    cfg.save();
                }
                right = br.x - 10;
            }
        }
        const name_x = card.x + card_pad + 16 + 10;
        const nw = dl.textEllipsis(theme.font_ui_medium, name_x, hcy, k.label, @max(0, right - name_x - 8), if (installed) theme.text else theme.text_2);
        const status_x = name_x + nw + 10;
        if (installed) {
            _ = pillLeft(ui, status_x, hcy, "Installed", theme.teal.alpha(0.18), theme.teal);
        } else {
            _ = pillLeft(ui, status_x, hcy, "Not found", theme.chip_active, theme.text_3);
        }

        var y = card.y + card_pad + 22 + 10;
        const tx = card.x + card_pad;
        const tw = card.w - 2 * card_pad;
        _ = dl.textEllipsis(theme.font_hint, tx, y + small_h / 2, k.blurb, tw, theme.text_3);
        y += small_h;
        if (path) |p| {
            var abuf: [512]u8 = undefined;
            var buf: [512]u8 = undefined;
            const shown = std.fmt.bufPrint(&buf, "Found at {s}", .{sys.abbreviateHome(p, &abuf)}) catch "Found";
            _ = dl.textEllipsis(theme.font_row_mono, tx, y + small_h / 2, shown, tw, theme.text_2);
        } else {
            var buf: [256]u8 = undefined;
            const shown = std.fmt.bufPrint(&buf, "Install: {s}", .{k.install}) catch k.install;
            _ = dl.textEllipsis(theme.font_row_mono, tx, y + small_h / 2, shown, tw, theme.text_2);
        }
        y += small_h;
        var run_buf: [256]u8 = undefined;
        const runs = std.fmt.bufPrint(&run_buf, "Runs: {s}", .{k.template}) catch k.template;
        _ = dl.textEllipsis(theme.font_row_mono, tx, y + small_h / 2, runs, tw, theme.text_3);
        return card.bottom();
    }
};

/// A small rounded tag ending at `right`; returns its left edge.
fn pill(ui: *Ui, right: f32, cy: f32, tag: []const u8, bg: ui_mod.Color, fg: ui_mod.Color) f32 {
    const tw = ui.text.measure(theme.font_chip, tag);
    const r: Rect = .{ .x = right - tw - 16, .y = cy - 10, .w = tw + 16, .h = 20 };
    ui.dl.rrect(r, 10, bg);
    _ = ui.dl.textCentered(theme.font_chip, r.x + 8, r.centerY(), tag, fg);
    return r.x;
}

/// A small rounded tag starting at `left`; returns its right edge.
fn pillLeft(ui: *Ui, left: f32, cy: f32, tag: []const u8, bg: ui_mod.Color, fg: ui_mod.Color) f32 {
    const tw = ui.text.measure(theme.font_chip, tag);
    const r: Rect = .{ .x = left, .y = cy - 10, .w = tw + 16, .h = 20 };
    ui.dl.rrect(r, 10, bg);
    _ = ui.dl.textCentered(theme.font_chip, r.x + 8, r.centerY(), tag, fg);
    return r.right();
}

//! The Pull Requests view: the host's pull requests for this repository,
//! newest activity first. Above the list, a box that keeps the rows whose
//! title, author or branch contains what is typed, the state to list
//! (open, merged, closed), and the saved filters (everything, created by
//! me, waiting for my review). Each row shows the title, where it goes
//! (`head → base`, or that it is a draft), who opened it and when, and at
//! its right what looking at it closely found: its checks, what its
//! reviewers said, its comments and its size.
//!
//! Nothing is asked of the host here: a click on a row, a change of
//! state, scrolling to the end and the rows whose detail is still missing
//! all come out for the entry to act on.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const icons = @import("../../../gfx/icons.zig");
const pr = @import("../model/pull_request.zig");
const reltime = @import("../model/reltime.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const pad: f32 = 16;
const bar_h: f32 = 48;
const tabs_h: f32 = 42;
const row_h: f32 = 64;

pub const Row = struct {
    pull: pr.PullRequest,
    /// What looking at it closely found, once that is in.
    detail: ?*const pr.Detail,
};

/// The saved filters.
pub const Mine = enum { all, created, review };

pub const State = struct {
    rows: []const Row,
    filter: pr.Filter,
    loading: bool,
    loaded: bool,
    /// The host has more pages.
    has_more: bool,
    /// What the host said went wrong with the list.
    err: []const u8,
    /// Who the account is on the host ("" until known).
    me: []const u8,
    now: i64,
    /// "pull request" or "merge request".
    noun: []const u8,
    /// Why there is no list at all (no remote, no account for its host …).
    notice: []const u8 = "",
};

pub const Intent = union(enum) {
    open: u64,
    filter: pr.Filter,
    more,
    reload,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    intent: ?Intent = null,
    scroll: f32 = 0,
    text: std.ArrayList(u8) = .empty,
    mine: Mine = .all,
    /// Rows on show whose detail is not in yet: the entry asks for them.
    wanted: [16]u64 = undefined,
    wanted_len: usize = 0,

    pub const field_filter = Ui.id("repo.pulls.filter", 0);

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.text.deinit(self.gpa);
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    fn keeps(self: *const View, p: pr.PullRequest, me: []const u8) bool {
        switch (self.mine) {
            .all => {},
            .created => if (!std.ascii.eqlIgnoreCase(p.author, me)) return false,
            .review => {
                var asked = false;
                for (p.requested) |name| {
                    if (std.ascii.eqlIgnoreCase(name, me)) asked = true;
                }
                if (!asked) return false;
            },
        }
        const needle = self.text.items;
        if (needle.len == 0) return true;
        return kit.containsIgnoreCase(p.title, needle) or kit.containsIgnoreCase(p.author, needle) or kit.containsIgnoreCase(p.head, needle) or kit.containsIgnoreCase(p.base, needle);
    }

    pub fn draw(self: *View, ui: *Ui, focus: *field.Focus, rect: Rect, state: State) void {
        const dl = ui.dl;
        self.wanted_len = 0;
        if (focus.id == field_filter and focus.changed()) {
            self.text.clearRetainingCapacity();
            self.text.appendSlice(self.gpa, std.mem.trim(u8, focus.editor.bytes(), " ")) catch {};
            focus.markSynced();
            self.scroll = 0;
        }
        dl.pushClip(rect);
        defer dl.popClip();

        if (state.notice.len > 0) {
            _ = @import("../../../ui/wrap.zig").drawWrapped(ui, kit.font_text, state.notice, rect.x + 20, rect.y + 20, @min(560, rect.w - 40), 20, theme.text_3);
            return;
        }

        // The filter box, and how much is listed.
        {
            const fw = @min(380, rect.w - 2 * pad);
            const fr: Rect = .{ .x = rect.x + pad, .y = rect.y + (bar_h - field.height) / 2, .w = fw, .h = field.height };
            if (field.draw(ui, focus, field_filter, fr, self.text.items, .{ .placeholder = "Filter by title, author or branch", .font = kit.font_text }).clicked) focus.take(field_filter, self.text.items, ui.now);
            if (ui.pressed and focus.id == field_filter and !ui.mouseIn(fr)) focus.drop();
            var right = rect.right() - pad;
            const rr: Rect = .{ .x = right - 26, .y = fr.centerY() - 13, .w = 26, .h = 26 };
            const st = ui.button(Ui.id("repo.pulls.reload", 0), rr);
            ui.feedback(rr, 6, st);
            dl.icon(.reload, rr.x + 5, rr.y + 5, 16, if (state.loading) theme.text_3.alpha(0.5) else if (st.hover) theme.text else theme.text_3);
            if (st.clicked and !state.loading) self.intent = .reload;
            right = rr.x - 10;
            if (state.loading and fr.right() + 16 < right) _ = dl.textRight(kit.font_small, right, fr.centerY(), "Asking the host…", theme.text_3);
        }

        // Which state, then whose.
        {
            var x = rect.x + pad;
            const cy = rect.y + bar_h + tabs_h / 2 - 4;
            inline for (.{ pr.Filter.open, pr.Filter.merged, pr.Filter.closed }) |f| {
                const label: []const u8 = switch (f) {
                    .open => "Open",
                    .merged => "Merged",
                    .closed => "Closed",
                };
                const w = field.chipWidth(ui, label);
                if (field.chip(ui, Ui.id("repo.pulls.state", @backingInt(f)), .{ .x = x, .y = cy - 13, .w = w, .h = 26 }, label, state.filter == f) and state.filter != f) {
                    self.intent = .{ .filter = f };
                    self.scroll = 0;
                }
                x += w + 6;
            }
            if (state.me.len > 0) {
                x += 10;
                dl.rect(.{ .x = x, .y = cy - 9, .w = 1, .h = 18 }, theme.line);
                x += 16;
                inline for (.{ Mine.all, Mine.created, Mine.review }) |m| {
                    const label: []const u8 = switch (m) {
                        .all => "Everyone's",
                        .created => "Created by me",
                        .review => "Waiting for my review",
                    };
                    const w = field.chipWidth(ui, label);
                    if (x + w <= rect.right() - pad) {
                        if (field.chip(ui, Ui.id("repo.pulls.mine", @backingInt(m)), .{ .x = x, .y = cy - 13, .w = w, .h = 26 }, label, self.mine == m)) {
                            self.mine = m;
                            self.scroll = 0;
                        }
                    }
                    x += w + 6;
                }
            }
        }

        const area: Rect = .{ .x = rect.x, .y = rect.y + bar_h + tabs_h, .w = rect.w, .h = @max(0, rect.h - bar_h - tabs_h) };
        dl.rect(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, theme.line);
        if (state.err.len > 0) {
            _ = @import("../../../ui/wrap.zig").drawWrapped(ui, kit.font_text, state.err, area.x + 20, area.y + 18, @min(620, area.w - 40), 20, theme.red);
            return;
        }

        // Count what the filters keep, to know how far the list scrolls.
        var count: usize = 0;
        for (state.rows) |row| {
            if (self.keeps(row.pull, state.me)) count += 1;
        }
        if (count == 0) {
            var buf: [96]u8 = undefined;
            const msg: []const u8 = if (!state.loaded) "" else if (state.rows.len == 0) std.fmt.bufPrint(&buf, "No {s}s here.", .{state.noun}) catch "" else "None matches the filters.";
            _ = dl.textEllipsis(kit.font_text, area.x + 20, area.y + 28, msg, area.w - 40, theme.text_3);
            return;
        }
        const content_h = @as(f32, @floatFromInt(count)) * row_h;
        const max_scroll = @max(0, content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();

        var pos: usize = 0;
        for (state.rows) |row| {
            if (!self.keeps(row.pull, state.me)) continue;
            const r: Rect = .{ .x = area.x, .y = area.y + @as(f32, @floatFromInt(pos)) * row_h - self.scroll, .w = area.w, .h = row_h };
            pos += 1;
            if (r.bottom() < area.y or r.y > area.bottom()) continue;
            if (row.detail == null and self.wanted_len < self.wanted.len) {
                self.wanted[self.wanted_len] = row.pull.number;
                self.wanted_len += 1;
            }
            self.drawRow(ui, r, row, state);
        }
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, content_h);
        if (state.has_more and !state.loading and self.scroll + area.h > content_h - 3 * row_h) self.intent = self.intent orelse .more;
    }

    fn drawRow(self: *View, ui: *Ui, r: Rect, row: Row, state: State) void {
        const dl = ui.dl;
        const p = row.pull;
        const st = ui.button(Ui.id("repo.pulls.row", @intCast(p.number % std.math.maxInt(u32))), r);
        if (st.hover) dl.rect(r, theme.hover);
        dl.rect(.{ .x = r.x, .y = r.bottom() - 1, .w = r.w, .h = 1 }, theme.line.alpha(0.6));
        if (st.clicked) self.intent = .{ .open = p.number };

        const top_y = r.y + 22;
        const meta_y = r.y + 44;
        const state_color: Color = if (p.draft) theme.text_3 else switch (p.state) {
            .open => kit.green(),
            .merged => kit.purple(),
            .closed => theme.red,
        };
        dl.icon(if (p.state == .merged) .merge else .pull_request, r.x + pad, top_y - 9, 18, state_color);

        // The right-hand cluster, from the right: size, comments, review, checks.
        var right = r.right() - pad;
        const additions = p.additions orelse (if (row.detail) |d| d.additions else null);
        const deletions = p.deletions orelse (if (row.detail) |d| d.deletions else null);
        if (additions != null or deletions != null) {
            const w = kit.plusMinus(ui, right, top_y, additions orelse 0, deletions orelse 0, kit.font_mono);
            if (w > 0) right -= w + 14;
        }
        const comments = p.comments orelse (if (row.detail) |d| d.comments else null);
        if (comments) |n| if (n > 0) {
            var buf: [16]u8 = undefined;
            right -= dl.textRight(kit.font_small, right, top_y, std.fmt.bufPrint(&buf, "{d}", .{n}) catch "", theme.text_3) + 4;
            dl.icon(.comment, right - 14, top_y - 7, 14, theme.text_3);
            right -= 14 + 14;
        };
        if (row.detail) |d| {
            const review = reviewText(d);
            if (review.text.len > 0 and r.w > 620) {
                right -= dl.textRight(kit.font_small, right, top_y, review.text, review.color) + 4;
                dl.icon(.user, right - 14, top_y - 7, 14, review.color);
                right -= 14 + 14;
            }
            const c = d.checkSummary();
            if (c.total > 0) {
                var buf: [32]u8 = undefined;
                const icon: icons.Icon, const color: Color, const text: []const u8 = if (c.failed > 0)
                    .{ .close, theme.red, std.fmt.bufPrint(&buf, "{d}/{d}", .{ c.passed, c.total }) catch "" }
                else if (c.pending > 0)
                    .{ .history, kit.amber(), std.fmt.bufPrint(&buf, "{d}/{d} running", .{ c.passed, c.total }) catch "" }
                else
                    .{ .check, kit.green(), std.fmt.bufPrint(&buf, "{d}/{d}", .{ c.passed, c.total }) catch "" };
                right -= dl.textRight(kit.font_mono, right, top_y, text, color) + 4;
                dl.icon(icon, right - 14, top_y - 7, 14, color);
                right -= 14 + 14;
            }
        }

        // The title, then where it goes.
        const tx = r.x + pad + 30;
        const room = @max(0, right - tx);
        var buf: [200]u8 = undefined;
        const chip_text: []const u8 = if (p.draft) "Draft" else std.fmt.bufPrint(&buf, "{s} → {s}", .{ p.head, p.base }) catch "";
        const chip_w = @min(kit.chipWidth(ui, chip_text), room * 0.45);
        const tw = dl.textEllipsis(ui_mod.Font.semibold(14), tx, top_y, p.title, @max(0, room - chip_w - 10), if (p.draft) theme.text_2 else theme.text);
        _ = kit.chip(ui, tx + tw + 10, top_y, chip_text, if (p.draft) theme.text_3 else kit.hueOf(p.head), chip_w);

        // "#142 · opened 2 days ago by María · updated 1 h ago".
        var meta: [240]u8 = undefined;
        var a_buf: [32]u8 = undefined;
        var b_buf: [32]u8 = undefined;
        const line = if (p.state == .merged and p.merged_by.len > 0)
            std.fmt.bufPrint(&meta, "#{d} · merged {s} by {s}", .{ p.number, reltime.ago(&a_buf, state.now, p.updated), p.merged_by }) catch ""
        else
            std.fmt.bufPrint(&meta, "#{d} · opened {s} by {s} · updated {s}", .{ p.number, reltime.ago(&a_buf, state.now, p.created), p.author, reltime.ago(&b_buf, state.now, p.updated) }) catch "";
        _ = dl.textEllipsis(kit.font_small, tx, meta_y, line, @max(0, r.right() - pad - tx), theme.text_3);
    }
};

/// What the reviewers said, in a few words, and the colour that goes with it.
pub fn reviewText(d: *const pr.Detail) struct { text: []const u8, color: Color } {
    const r = d.reviewSummary();
    if (r.changes_requested > 0) return .{ .text = "changes requested", .color = theme.red };
    if (r.approvals > 0) {
        // Approved, but the host still wants more: not green yet.
        const enough = (d.approvals_left orelse 0) == 0;
        return .{ .text = if (r.approvals == 1) "1 approval" else "approved", .color = if (enough) kit.green() else theme.text_3 };
    }
    if (r.waiting > 0) return .{ .text = "review pending", .color = theme.text_3 };
    if (d.reviewers.len == 0) return .{ .text = "no reviewers", .color = theme.text_3 };
    return .{ .text = "", .color = theme.text_3 };
}

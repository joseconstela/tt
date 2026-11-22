//! One pull request, looked at closely. Across the top: back to the list,
//! its title, number and state, who wants to merge what into what, and
//! "Checkout" for its branch. Below, three columns: the files it changes;
//! the selected file's change as a unified diff, with the comment threads
//! on its lines right under the line each is about (a box to reply, and
//! "Resolve" where the host can); and at the right what stands between it
//! and a merge: the reviewers and what each said, its labels, the checks
//! of its head commit, and the merge box (whether it merges cleanly, the
//! button for the chosen way to merge with a menu for the others, and
//! "Update" to bring its branch up to date with its base, where the host
//! can).
//!
//! The files and the diff are read with git on this Mac; the rest is what
//! the host answered. A part the host does not have is not drawn. Nothing
//! is run or sent here: what was asked for comes out of `takeIntent`.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const wrap = @import("../../../ui/wrap.zig");
const icons = @import("../../../gfx/icons.zig");
const pr = @import("../model/pull_request.zig");
const log_mod = @import("../model/log.zig");
const patch_mod = @import("../model/patch.zig");
const status = @import("../model/status.zig");
const reltime = @import("../model/reltime.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const pad: f32 = 16;
const head_h: f32 = 92;
const files_w: f32 = 210;
const panel_w: f32 = 290;
const file_h: f32 = 28;
const line_h: f32 = 21;
const gutter_w: f32 = 46;
const marker_w: f32 = 18;
const card_inset: f32 = 56;
const body_lh: f32 = 19;

pub const FilesState = enum { fetching, ready, failed };

pub const State = struct {
    pull: pr.PullRequest,
    detail: ?*const pr.Detail,
    caps: pr.Capabilities,
    files: FilesState,
    changes: ?*const log_mod.Changes,
    commits: ?u32,
    /// The file on show, and its diff once read.
    selected: []const u8,
    patch: ?*const patch_mod.Patch,
    now: i64,
    /// Something is being sent or run: the buttons wait.
    busy: bool,
    /// What the last action that failed said.
    action_error: []const u8,
    /// The way to merge the button stands for.
    method: pr.MergeMethod,
};

pub const Intent = union(enum) {
    back,
    checkout,
    select: []const u8,
    reply: struct { thread: []const u8, text: []const u8 },
    resolve: []const u8,
    merge,
    /// The other ways to merge, as a menu at this point.
    methods: struct { x: f32, y: f32 },
    update,
    /// Its page on the host, in a browser.
    browse,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    intent: ?Intent = null,
    files_scroll: f32 = 0,
    diff_scroll: f32 = 0,
    diff_h: f32 = 0,
    panel_scroll: f32 = 0,
    panel_h: f32 = 0,
    /// What is being typed as a reply, and to which thread.
    reply: std.ArrayList(u8) = .empty,
    reply_thread: std.ArrayList(u8) = .empty,
    /// The file the diff's scroll position belongs to.
    scrolled_for: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.reply.deinit(self.gpa);
        self.reply_thread.deinit(self.gpa);
        self.scrolled_for.deinit(self.gpa);
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    fn replyId(index: usize) u64 {
        return Ui.id("repo.pull.reply", index);
    }

    /// True when the focused field is one of this view's reply boxes.
    pub fn ownsFocus(self: *const View, focus: *const field.Focus) bool {
        return focus.active() and self.reply_thread.items.len > 0;
    }

    /// ↵ in a reply box: the reply, for the thread the box belongs to.
    pub fn submit(self: *View, focus: *field.Focus) void {
        if (!self.ownsFocus(focus)) return;
        self.reply.clearRetainingCapacity();
        self.reply.appendSlice(self.gpa, std.mem.trim(u8, focus.editor.bytes(), " \t\r\n")) catch return;
        if (self.reply.items.len == 0) return;
        self.intent = .{ .reply = .{ .thread = self.reply_thread.items, .text = self.reply.items } };
        focus.drop();
    }

    /// The focus went elsewhere, or the reply was sent.
    pub fn dropReply(self: *View) void {
        self.reply_thread.clearRetainingCapacity();
    }

    pub fn draw(self: *View, ui: *Ui, focus: *field.Focus, rect: Rect, state: State) void {
        const dl = ui.dl;
        dl.pushClip(rect);
        defer dl.popClip();
        if (!focus.active()) self.dropReply();
        self.drawHead(ui, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = head_h }, state);

        const body: Rect = .{ .x = rect.x, .y = rect.y + head_h, .w = rect.w, .h = @max(0, rect.h - head_h) };
        // The columns give way as the tab narrows: the panel first, then the file list.
        const show_panel = body.w >= 760;
        const show_files = body.w >= 520;
        const pw: f32 = if (show_panel) panel_w else 0;
        const fw: f32 = if (show_files) files_w else 0;
        if (show_files) self.drawFiles(ui, .{ .x = body.x, .y = body.y, .w = fw, .h = body.h }, state);
        if (show_panel) self.drawPanel(ui, .{ .x = body.right() - pw, .y = body.y, .w = pw, .h = body.h }, state);
        self.drawDiff(ui, focus, .{ .x = body.x + fw, .y = body.y, .w = @max(0, body.w - fw - pw), .h = body.h }, state);
    }

    // ── the header ──────────────────────────────────────────────────────
    fn drawHead(self: *View, ui: *Ui, r: Rect, state: State) void {
        const dl = ui.dl;
        const p = state.pull;
        dl.rect(.{ .x = r.x, .y = r.bottom() - 1, .w = r.w, .h = 1 }, theme.line);
        const y1 = r.y + 24;
        const y2 = r.y + 54;
        const y3 = r.y + 76;

        // Back to the list, and on the right the branch and the host's page.
        var x = r.x + pad;
        {
            const label = "Pull Requests";
            const w = ui.text.measure(kit.font_small, label) + 26;
            const br: Rect = .{ .x = x - 6, .y = y1 - 13, .w = w, .h = 26 };
            const st = ui.button(Ui.id("repo.pull.back", 0), br);
            ui.feedback(br, 6, st);
            dl.icon(.arrow_left, br.x + 4, br.y + 6, 14, if (st.hover) theme.text else theme.text_3);
            _ = dl.textCentered(kit.font_small, br.x + 22, y1, label, if (st.hover) theme.text else theme.text_2);
            if (st.clicked) self.intent = .back;
            x = br.right() + 8;
            var num: [32]u8 = undefined;
            x += dl.textCentered(kit.font_small, x, y1, "/", theme.text_3.alpha(0.6)) + 8;
            _ = dl.textCentered(kit.font_mono, x, y1, std.fmt.bufPrint(&num, "#{d}", .{p.number}) catch "", theme.text_2);
        }
        var right = r.right() - pad;
        if (p.state == .open) {
            const w = kit.buttonWidth(ui, "Checkout", true);
            right -= w;
            if (kit.button(ui, Ui.id("repo.pull.checkout", 0), .{ .x = right, .y = y1 - 14, .w = w, .h = 28 }, "Checkout", .branch, .secondary, !state.busy)) self.intent = .checkout;
            right -= 8;
        }
        if (p.url.len > 0) {
            const w = kit.buttonWidth(ui, "Open on host", true);
            right -= w;
            if (kit.button(ui, Ui.id("repo.pull.browse", 0), .{ .x = right, .y = y1 - 14, .w = w, .h = 28 }, "Open on host", .globe, .secondary, true)) self.intent = .browse;
        }

        // The title and the state.
        const badge_text: []const u8, const badge_color: Color = if (p.draft and p.state == .open) .{ "Draft", theme.text_3 } else switch (p.state) {
            .open => .{ "Open", kit.green() },
            .merged => .{ "Merged", kit.purple() },
            .closed => .{ "Closed", theme.red },
        };
        const bw = kit.chipWidth(ui, badge_text);
        const tw = dl.textEllipsis(ui_mod.Font.semibold(17), r.x + pad, y2, p.title, @max(0, r.w - 2 * pad - bw - 12), theme.text);
        _ = kit.chip(ui, r.x + pad + tw + 12, y2, badge_text, badge_color, bw);

        // "María wants to merge 12 commits from feat/webhooks into main · opened 2 days ago".
        var buf: [320]u8 = undefined;
        var ago_buf: [32]u8 = undefined;
        var n_buf: [32]u8 = undefined;
        const commits: []const u8 = if (state.commits) |n| std.fmt.bufPrint(&n_buf, "{d} {s} ", .{ n, if (n == 1) "commit" else "commits" }) catch "" else "";
        const verb: []const u8 = switch (p.state) {
            .open => "wants to merge",
            .merged => "merged",
            .closed => "wanted to merge",
        };
        const line = std.fmt.bufPrint(&buf, "{s} {s} {s}from {s} into {s} · opened {s}", .{ p.author, verb, commits, p.head, p.base, reltime.ago(&ago_buf, state.now, p.created) }) catch "";
        _ = dl.textEllipsis(kit.font_small, r.x + pad, y3, line, r.w - 2 * pad, theme.text_3);
    }

    // ── the files ───────────────────────────────────────────────────────
    fn drawFiles(self: *View, ui: *Ui, r: Rect, state: State) void {
        const dl = ui.dl;
        dl.rect(r, theme.bg_side);
        dl.rect(.{ .x = r.right() - 1, .y = r.y, .w = 1, .h = r.h }, theme.line);
        const changes = state.changes orelse {
            const msg: []const u8 = switch (state.files) {
                .fetching => "Fetching its head…",
                .failed => "Its commits could not be fetched: the files are not known.",
                .ready => "",
            };
            _ = wrap.drawWrapped(ui, kit.font_small, msg, r.x + pad, r.y + 16, r.w - 2 * pad, 18, theme.text_3);
            return;
        };
        var buf: [32]u8 = undefined;
        _ = kit.label(ui, r.x + pad, r.y + 22, std.fmt.bufPrint(&buf, "{d} {s}", .{ changes.files.len, if (changes.files.len == 1) "FILE" else "FILES" }) catch "");
        _ = kit.plusMinus(ui, r.right() - pad, r.y + 22, changes.added, changes.removed, kit.font_mono_small);
        const area: Rect = .{ .x = r.x, .y = r.y + 40, .w = r.w, .h = @max(0, r.h - 40) };
        const content_h = @as(f32, @floatFromInt(changes.files.len)) * file_h + 8;
        const max_scroll = @max(0, content_h - area.h);
        self.files_scroll = std.math.clamp(self.files_scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        for (changes.files, 0..) |f, i| {
            const row: Rect = .{ .x = area.x + 8, .y = area.y + @as(f32, @floatFromInt(i)) * file_h - self.files_scroll, .w = area.w - 16, .h = file_h };
            if (row.bottom() < area.y or row.y > area.bottom()) continue;
            const current = std.mem.eql(u8, f.path, state.selected);
            const st = ui.button(Ui.id("repo.pull.file", i), row);
            if (current) dl.rrect(row, 7, theme.accent.alpha(0.14)) else ui.feedback(row, 7, st);
            kit.badge(ui, row.x + 6, row.centerY(), f.letter, 16);
            _ = dl.textEllipsis(kit.font_mono_small, row.x + 30, row.centerY(), status.baseName(f.path), row.w - 38, if (current) theme.text else theme.text_2);
            if (st.clicked and !current) self.intent = .{ .select = f.path };
        }
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.files_scroll, content_h);
    }

    // ── the diff, with its threads ──────────────────────────────────────
    fn drawDiff(self: *View, ui: *Ui, focus: *field.Focus, r: Rect, state: State) void {
        const dl = ui.dl;
        if (r.w < 80) return;
        if (state.selected.len == 0) {
            const msg: []const u8 = if (state.files == .fetching) "Fetching the pull request's commits…" else if (state.files == .failed) "The pull request's commits are not on this Mac and could not be fetched." else "Select a file to see its changes.";
            _ = wrap.drawWrapped(ui, kit.font_text, msg, r.x + 20, r.y + 20, r.w - 40, 20, theme.text_3);
            return;
        }
        if (!std.mem.eql(u8, self.scrolled_for.items, state.selected)) {
            self.scrolled_for.clearRetainingCapacity();
            self.scrolled_for.appendSlice(self.gpa, state.selected) catch {};
            self.diff_scroll = 0;
        }
        // The file's own header.
        const head: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 40 };
        dl.rect(.{ .x = head.x, .y = head.bottom() - 1, .w = head.w, .h = 1 }, theme.line);
        var right = head.right() - pad;
        if (state.patch) |p| right -= kit.plusMinus(ui, right, head.centerY(), p.added, p.removed, kit.font_mono) + 10;
        _ = dl.textEllipsis(ui_mod.Font.monoSemibold(12.5), head.x + pad, head.centerY(), state.selected, @max(0, right - head.x - pad), theme.text);

        const area: Rect = .{ .x = r.x, .y = head.bottom(), .w = r.w, .h = @max(0, r.h - 40) };
        const p = state.patch orelse {
            _ = dl.textEllipsis(kit.font_text, area.x + 20, area.y + 24, "Reading…", area.w - 40, theme.text_3);
            return;
        };
        const max_scroll = @max(0, self.diff_h - area.h);
        if (sidebar.scrollbarDrag(ui, Ui.id("repo.pull.bar", 0), .vertical, area, self.diff_scroll, self.diff_h)) |to| self.diff_scroll = to;
        self.diff_scroll = std.math.clamp(self.diff_scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();

        const font = theme.font_output;
        const text_x = area.x + gutter_w + marker_w;
        var y = area.y - self.diff_scroll;
        const top = y;
        if (p.lines.len == 0) {
            _ = dl.textEllipsis(kit.font_text, area.x + 20, y + 24, if (p.binary) "A binary file: nothing to show line by line." else "No lines changed.", area.w - 40, theme.text_3);
            y += 48;
        }
        const threads: []const pr.Thread = if (state.detail) |d| d.threads else &.{};
        for (p.lines) |line| {
            const row: Rect = .{ .x = area.x, .y = y, .w = area.w, .h = line_h };
            y += line_h;
            if (row.bottom() >= area.y and row.y <= area.bottom()) {
                const cy = row.centerY();
                switch (line.kind) {
                    .added => dl.rect(row, kit.green().alpha(0.10)),
                    .removed => dl.rect(row, theme.red.alpha(0.10)),
                    .hunk => dl.rect(row, kit.blue().alpha(0.12)),
                    .context, .note => {},
                }
                if (line.kind == .hunk) {
                    _ = dl.textEllipsis(font, area.x + gutter_w, cy, line.text, area.w - gutter_w - 12, Color.mix(kit.blue(), theme.text, 0.35));
                } else if (line.kind == .note) {
                    _ = dl.textEllipsis(kit.font_small, text_x, cy, line.text, area.w - gutter_w - marker_w - 12, theme.text_3);
                } else {
                    var buf: [16]u8 = undefined;
                    const no = if (line.kind == .removed) line.old_no else line.new_no;
                    _ = dl.textRight(kit.font_mono_small, area.x + gutter_w - 8, cy, std.fmt.bufPrint(&buf, "{d}", .{no}) catch "", theme.text_3);
                    if (line.kind == .added) _ = dl.textCentered(font, area.x + gutter_w + 4, cy, "+", kit.green());
                    if (line.kind == .removed) _ = dl.textCentered(font, area.x + gutter_w + 4, cy, "−", theme.red);
                    dl.pushClip(.{ .x = text_x, .y = row.y, .w = @max(0, area.right() - text_x - 8), .h = row.h });
                    _ = kit.code(ui, font, text_x, cy, line.text, if (line.kind == .context) theme.text_2 else theme.text);
                    dl.popClip();
                }
            }
            // The threads about this line, right under it.
            if (line.kind == .hunk or line.kind == .note) continue;
            for (threads, 0..) |t, ti| {
                if (!std.mem.eql(u8, t.path, state.selected)) continue;
                const here = if (t.line > 0) line.kind != .removed and line.new_no == t.line else line.kind == .removed and t.old_line > 0 and line.old_no == t.old_line;
                if (!here) continue;
                y = self.drawThread(ui, focus, area, y, t, ti, state);
            }
        }
        self.diff_h = (y - top) + 24;
        if (max_scroll > 0) sidebar.drawScrollbarAxis(ui, Ui.id("repo.pull.bar", 0), .vertical, area, self.diff_scroll, self.diff_h);
    }

    /// One thread as a card under its line; returns the y below it.
    fn drawThread(self: *View, ui: *Ui, focus: *field.Focus, area: Rect, y0: f32, t: pr.Thread, index: usize, state: State) f32 {
        const dl = ui.dl;
        const x = area.x + card_inset;
        const w = @min(720, area.right() - x - pad);
        if (w < 160) return y0;
        const text_w = w - 2 * 14;
        const can_reply = state.pull.state == .open and state.caps.reply;
        const can_resolve = state.caps.resolve and (t.resolved orelse true) == false;

        var h: f32 = 12;
        for (t.comments) |c| h += 26 + @as(f32, @floatFromInt(@max(1, wrap.wrapParagraphCount(ui, kit.font_text, c.body, text_w)))) * body_lh + 10;
        if (can_reply) h += field.height + 12;
        const card: Rect = .{ .x = x, .y = y0 + 6, .w = w, .h = h };
        const below = card.bottom() + 8;
        if (card.bottom() < area.y or card.y > area.bottom()) return below;
        dl.shape(card, 10, theme.bg_block, 1, theme.line);

        var y = card.y + 12;
        for (t.comments, 0..) |c, ci| {
            kit.avatar(ui, card.x + 14 + 12, y + 12, 24, c.author);
            var tx = card.x + 14 + 32;
            tx += dl.textCentered(kit.font_text_bold, tx, y + 12, c.author, theme.text) + 10;
            var meta: [80]u8 = undefined;
            var ago_buf: [32]u8 = undefined;
            const when = reltime.ago(&ago_buf, state.now, c.created);
            const m = if (ci == 0 and (t.line > 0 or t.old_line > 0)) std.fmt.bufPrint(&meta, "{s} · line {d}", .{ when, if (t.line > 0) t.line else t.old_line }) catch when else when;
            _ = dl.textCentered(kit.font_small, tx, y + 12, m, theme.text_3);
            if (ci == 0) if (t.resolved) |resolved| {
                const label: []const u8 = if (resolved) "Resolved" else "Pending";
                const cw = kit.chipWidth(ui, label);
                _ = kit.chip(ui, card.right() - 14 - cw, y + 12, label, if (resolved) kit.green() else kit.amber(), cw);
            };
            y += 26;
            y = wrap.drawWrappedParagraphs(ui, kit.font_text, c.body, card.x + 14, y, text_w, body_lh, theme.text_2) + 10;
        }

        if (can_reply) {
            const rw: f32 = if (can_resolve) kit.buttonWidth(ui, "Resolve", false) + 8 else 0;
            const fr: Rect = .{ .x = card.x + 14, .y = y, .w = text_w - rw, .h = field.height };
            const mine = focus.active() and std.mem.eql(u8, self.reply_thread.items, t.id);
            const id = replyId(index);
            if (field.draw(ui, focus, id, fr, if (mine) self.reply.items else "", .{ .placeholder = "Reply…", .font = kit.font_text }).clicked) {
                focus.take(id, "", ui.now);
                self.reply_thread.clearRetainingCapacity();
                self.reply_thread.appendSlice(self.gpa, t.id) catch {};
            }
            if (ui.pressed and mine and !ui.mouseIn(fr)) focus.drop();
            if (can_resolve) {
                if (kit.button(ui, Ui.id("repo.pull.resolve", index), .{ .x = fr.right() + 8, .y = y + 2, .w = rw - 8, .h = field.height - 4 }, "Resolve", null, .secondary, !state.busy)) self.intent = .{ .resolve = t.id };
            }
        }
        return below;
    }

    // ── what stands between it and a merge ──────────────────────────────
    fn drawPanel(self: *View, ui: *Ui, r: Rect, state: State) void {
        const dl = ui.dl;
        dl.rect(r, theme.bg_side);
        dl.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, theme.line);
        const p = state.pull;
        const x = r.x + pad;
        const w = r.w - 2 * pad;

        // The merge box, pinned to the bottom while the pull request is open.
        var box_h: f32 = 0;
        if (p.state == .open) {
            const update = state.caps.update != .none;
            box_h = 14 + 36 + 8 + 36 + (if (update) @as(f32, 32 + 8) else 0) + 22 + 12;
            var y = r.bottom() - box_h;
            dl.rect(.{ .x = r.x, .y = y, .w = r.w, .h = 1 }, theme.line);
            y += 14;
            const mergeable = if (state.detail) |d| d.mergeable orelse p.mergeable else p.mergeable;
            const checks = if (state.detail) |d| d.checkSummary() else pr.Checks{};
            var buf: [160]u8 = undefined;
            const line: []const u8, const color: Color = if (p.draft)
                .{ "A draft: not ready to merge.", theme.text_3 }
            else if (mergeable) |ok| (if (!ok)
                .{ std.fmt.bufPrint(&buf, "Conflicts with {s}.", .{p.base}) catch "Conflicts.", theme.red }
            else if (checks.failed > 0)
                .{ std.fmt.bufPrint(&buf, "No conflicts with {s}. Checks are failing.", .{p.base}) catch "", kit.amber() }
            else if (checks.pending > 0)
                .{ std.fmt.bufPrint(&buf, "No conflicts with {s}. Checks are running.", .{p.base}) catch "", theme.text_3 }
            else
                .{ std.fmt.bufPrint(&buf, "No conflicts with {s}.{s}", .{ p.base, if (checks.total > 0) " All checks passed." else "" }) catch "", kit.green() }) else .{ "The host has not said whether it merges cleanly.", theme.text_3 };
            y = wrap.drawWrapped(ui, kit.font_small, line, x, y, w, 18, color);
            y = r.bottom() - box_h + 14 + 36 + 8;

            // The button for the chosen way, and the menu for the others.
            const can = !state.busy and !p.draft and (mergeable orelse true);
            // With more than one way to merge, the arrow inside the button's right end lists them.
            const br: Rect = .{ .x = x, .y = y, .w = w, .h = 36 };
            if (state.caps.merge_methods.len > 1) {
                const split = kit.splitButton(ui, Ui.id("repo.pull.merge", 0), Ui.id("repo.pull.methods", 0), br, state.method.label(), .merge, kit.font_button, can);
                if (split.clicked) self.intent = .merge;
                if (split.arrow) self.intent = .{ .methods = .{ .x = split.arrow_rect.right() - 200, .y = br.y - 4 - 28 * @as(f32, @floatFromInt(state.caps.merge_methods.len)) - 10 } };
            } else if (kit.button(ui, Ui.id("repo.pull.merge", 0), br, state.method.label(), .merge, .primary, can)) self.intent = .merge;
            y += 36 + 8;
            if (update) {
                var ub: [120]u8 = undefined;
                const label = std.fmt.bufPrint(&ub, "Update with {s} ({s})", .{ p.base, if (state.caps.update == .rebase) "rebase" else "merge" }) catch "Update";
                if (kit.button(ui, Ui.id("repo.pull.update", 0), .{ .x = x, .y = y, .w = w, .h = 32 }, label, null, .secondary, !state.busy)) self.intent = .update;
                y += 32 + 8;
            }
            if (state.action_error.len > 0) _ = dl.textEllipsis(kit.font_small, x, y + 9, state.action_error, w, theme.red);
        }

        const area: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = @max(0, r.h - box_h) };
        const max_scroll = @max(0, self.panel_h - area.h);
        self.panel_scroll = std.math.clamp(self.panel_scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        var y = area.y + 16 - self.panel_scroll;
        const top = y;
        const d = state.detail orelse {
            _ = dl.textCentered(kit.font_small, x, y + 10, "Asking the host…", theme.text_3);
            return;
        };

        _ = kit.label(ui, x, y + 10, "REVIEWERS");
        y += 28;
        if (d.reviewers.len == 0) {
            _ = dl.textCentered(kit.font_small, x, y + 10, "No reviewers", theme.text_3);
            y += 26;
        }
        for (d.reviewers) |rv| {
            kit.avatar(ui, x + 12, y + 14, 24, rv.name);
            const icon: icons.Icon, const color: Color = switch (rv.state) {
                .approved => .{ .check, kit.green() },
                .changes_requested => .{ .close, theme.red },
                .pending => .{ .history, kit.amber() },
                .commented => .{ .comment, theme.text_3 },
            };
            dl.icon(icon, x + w - 16, y + 6, 16, color);
            _ = dl.textEllipsis(kit.font_text, x + 34, y + 14, rv.name, w - 34 - 24, if (rv.state == .pending) theme.text_3 else theme.text);
            y += 30;
        }
        if (d.approvals_left) |left| if (left > 0) {
            var buf: [64]u8 = undefined;
            _ = dl.textCentered(kit.font_small, x, y + 8, std.fmt.bufPrint(&buf, "{d} more {s} needed", .{ left, if (left == 1) "approval" else "approvals" }) catch "", theme.text_3);
            y += 22;
        };
        y += 14;

        if (state.caps.labels and p.labels.len > 0) {
            _ = kit.label(ui, x, y + 10, "LABELS");
            y += 28;
            var lx = x;
            for (p.labels) |l| {
                const lw = kit.chipWidth(ui, l.name);
                if (lx + lw > x + w and lx > x) {
                    lx = x;
                    y += 24;
                }
                const color: Color = if (l.color) |c| readable(c) else theme.text_2;
                _ = kit.chip(ui, lx, y + 9, l.name, color, w);
                lx += lw + 6;
            }
            y += 24 + 14;
        }

        const c = d.checkSummary();
        var head: [32]u8 = undefined;
        _ = kit.label(ui, x, y + 10, if (c.total > 0) std.fmt.bufPrint(&head, "CHECKS · {d}/{d}", .{ c.passed, c.total }) catch "CHECKS" else "CHECKS");
        y += 28;
        if (d.checks.len == 0) {
            _ = dl.textCentered(kit.font_small, x, y + 10, "No checks reported", theme.text_3);
            y += 26;
        }
        for (d.checks) |check| {
            const icon: icons.Icon, const color: Color = switch (check.state) {
                .passed => .{ .check, kit.green() },
                .failed => .{ .close, theme.red },
                .pending => .{ .history, kit.amber() },
                .skipped => .{ .minus, theme.text_3 },
            };
            dl.icon(icon, x, y + 4, 14, color);
            var rx = x + w;
            if (check.seconds) |s| {
                var buf: [24]u8 = undefined;
                const text = if (s >= 60) std.fmt.bufPrint(&buf, "{d}m {d:0>2}s", .{ s / 60, s % 60 }) catch "" else std.fmt.bufPrint(&buf, "{d}s", .{s}) catch "";
                rx -= dl.textRight(kit.font_mono_small, rx, y + 11, text, theme.text_3) + 8;
            }
            _ = dl.textEllipsis(kit.font_mono_small, x + 22, y + 11, check.name, @max(0, rx - x - 22), theme.text_2);
            y += 24;
        }
        self.panel_h = (y - top) + 28;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.panel_scroll, self.panel_h);
    }
};

/// A label's own colour, lifted towards the text colour when it would be
/// too dark (or too light) to read on the panel.
fn readable(rgb: u24) Color {
    const c = theme.rgb(rgb);
    const lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    const ground = 0.299 * theme.bg_side.r + 0.587 * theme.bg_side.g + 0.114 * theme.bg_side.b;
    if (@abs(lum - ground) >= 0.35) return c;
    return Color.mix(c, theme.text, 0.55);
}

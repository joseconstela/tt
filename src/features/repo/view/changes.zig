//! The Changes view: what is staged and what is not, each file with a
//! checkbox that stages or unstages it, and under the lists the commit
//! composer (a summary, an optional description, "Amend last commit", and
//! the Commit button naming the branch). Beside them, the selected file's
//! change as a unified diff: hunk headers, lines added and removed tinted,
//! one gutter of line numbers. "Split" opens the same change side by side
//! in a diff tab; "Discard" throws an unstaged change away, after asking.
//!
//! The arrow beside the Commit button opens the commit's options: Amend
//! (the same as the checkbox: the commit replaces the last one, and with
//! no summary keeps its message; ⌘⇧↵ turns it on, and commits once it
//! is), Signoff and Skip Hooks, the ones in force ticked.
//!
//! Nothing is run here: what was asked for comes out of `takeIntent`.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const status = @import("../model/status.zig");
const patch_mod = @import("../model/patch.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const pad: f32 = 14;
const row_h: f32 = 30;
const head_h: f32 = 30;
const composer_h: f32 = 222;
const diff_head_h: f32 = 44;
const line_h: f32 = 21;
const gutter_w: f32 = 46;
const marker_w: f32 = 18;

pub const Selected = struct { path: []const u8, staged: bool };

pub const State = struct {
    snapshot: *const status.Snapshot,
    staged_counts: []const patch_mod.Count,
    unstaged_counts: []const patch_mod.Count,
    selected: ?Selected,
    /// The selected file's change, once read.
    patch: ?*const patch_mod.Patch,
    busy: bool,
    cmd_label: []const u8,
    last_error: []const u8,
};

pub const Intent = union(enum) {
    select: struct { path: []const u8, staged: bool, untracked: bool },
    stage: []const u8,
    unstage: []const u8,
    stage_all,
    unstage_all,
    /// With `all`, everything is staged first. `committed` is the answer.
    /// An amend with no summary keeps the last commit's message.
    commit: struct { summary: []const u8, description: []const u8, amend: bool, all: bool, signoff: bool = false, no_verify: bool = false },
    /// The commit options, as a menu at this point (`option_rows`).
    options: struct { x: f32, y: f32 },
    /// The tab asks before it throws the change away.
    discard: struct { path: []const u8, untracked: bool },
    /// The same change side by side, in a diff tab.
    split: struct { path: []const u8, staged: bool, orig: ?[]const u8 },
};

const Section = enum { conflicts, staged, unstaged };

/// The commit options, in the menu's order (a shortcut after a tab).
pub const option_rows = [_][]const u8{ "Amend\t⌘⇧↵", "Signoff", "Skip Hooks" };

pub const View = struct {
    gpa: std.mem.Allocator,
    intent: ?Intent = null,
    summary: std.ArrayList(u8) = .empty,
    description: std.ArrayList(u8) = .empty,
    amend: bool = false,
    signoff: bool = false,
    skip_hooks: bool = false,
    /// Commit was pressed with no summary: said until typing starts.
    need_summary: bool = false,
    list_scroll: f32 = 0,
    list_h: f32 = 0,
    diff_scroll: f32 = 0,
    diff_scroll_x: f32 = 0,
    /// The file the diff's scroll position belongs to.
    scrolled_for: std.ArrayList(u8) = .empty,

    pub const field_summary = Ui.id("repo.changes.summary", 0);
    pub const field_description = Ui.id("repo.changes.description", 0);

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.summary.deinit(self.gpa);
        self.description.deinit(self.gpa);
        self.scrolled_for.deinit(self.gpa);
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    fn sync(self: *View, focus: *field.Focus) void {
        if (!focus.changed()) return;
        const into = if (focus.id == field_summary) &self.summary else if (focus.id == field_description) &self.description else return;
        into.clearRetainingCapacity();
        into.appendSlice(self.gpa, focus.editor.bytes()) catch {};
        focus.markSynced();
        if (focus.id == field_summary) self.need_summary = false;
    }

    /// ↵ in the summary: the commit, as the button would make it.
    pub fn submit(self: *View, focus: *field.Focus, s: *const status.Snapshot) void {
        self.sync(focus);
        self.commitNow(s);
    }

    fn commitNow(self: *View, s: *const status.Snapshot) void {
        const summary = std.mem.trim(u8, self.summary.items, " \t\r\n");
        if (!self.amend and s.staged_count + s.unstaged_count == 0) return;
        // An amend with nothing typed keeps the message the commit has.
        if (summary.len == 0 and !self.amend) {
            self.need_summary = true;
            return;
        }
        self.intent = .{ .commit = .{
            .summary = summary,
            .description = if (summary.len > 0) std.mem.trim(u8, self.description.items, " \t\r\n") else "",
            .amend = self.amend,
            .all = s.staged_count == 0 and s.unstaged_count > 0 and !self.amend,
            .signoff = self.signoff,
            .no_verify = self.skip_hooks,
        } };
    }

    /// Which options are in force, a bit per row of `option_rows`.
    pub fn optionChecks(self: *const View) u64 {
        var checks: u64 = 0;
        if (self.amend) checks |= 1;
        if (self.signoff) checks |= 2;
        if (self.skip_hooks) checks |= 4;
        return checks;
    }

    /// Row `i` of the options menu was picked.
    pub fn toggleOption(self: *View, i: usize) void {
        switch (i) {
            0 => self.amend = !self.amend,
            1 => self.signoff = !self.signoff,
            2 => self.skip_hooks = !self.skip_hooks,
            else => {},
        }
        if (self.amend) self.need_summary = false;
    }

    /// ⌘⇧↵: turns Amend on, and commits when it already is.
    pub fn amendKey(self: *View, focus: *field.Focus, s: *const status.Snapshot) void {
        if (!self.amend) {
            self.amend = true;
            self.need_summary = false;
            return;
        }
        self.submit(focus, s);
    }

    /// The commit asked for was made: the composer starts over.
    pub fn committed(self: *View, focus: *field.Focus) void {
        self.summary.clearRetainingCapacity();
        self.description.clearRetainingCapacity();
        self.amend = false;
        if (focus.id == field_summary or focus.id == field_description) focus.take(focus.id, "", focus.blink_t0);
    }

    fn countOf(counts: []const patch_mod.Count, path: []const u8) ?patch_mod.Count {
        for (counts) |c| if (std.mem.eql(u8, c.path, path)) return c;
        return null;
    }

    pub fn draw(self: *View, ui: *Ui, focus: *field.Focus, rect: Rect, state: State) void {
        const dl = ui.dl;
        self.sync(focus);
        const left_w = @min(rect.w, std.math.clamp(rect.w * 0.34, 280, 400));
        const left: Rect = .{ .x = rect.x, .y = rect.y, .w = left_w, .h = rect.h };
        const right: Rect = .{ .x = left.right(), .y = rect.y, .w = @max(0, rect.w - left_w), .h = rect.h };
        self.drawLists(ui, .{ .x = left.x, .y = left.y, .w = left.w, .h = @max(0, left.h - composer_h) }, state);
        self.drawComposer(ui, focus, .{ .x = left.x, .y = left.bottom() - composer_h, .w = left.w, .h = composer_h }, state);
        dl.rect(.{ .x = left.right() - 1, .y = rect.y, .w = 1, .h = rect.h }, theme.line);
        if (right.w > 80) self.drawDiff(ui, right, state);
    }

    // ── the lists ───────────────────────────────────────────────────────
    fn drawLists(self: *View, ui: *Ui, area: Rect, state: State) void {
        const dl = ui.dl;
        const s = state.snapshot;
        const max_scroll = @max(0, self.list_h - area.h);
        self.list_scroll = std.math.clamp(self.list_scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        var y = area.y + 8 - self.list_scroll;
        const top = y;
        if (s.staged_count + s.unstaged_count + s.conflict_count == 0) {
            _ = dl.textEllipsis(kit.font_text, area.x + pad, y + 20, if (s.isRepo()) "Nothing to commit: the working tree is clean." else "Not a git repository.", area.w - 2 * pad, theme.text_3);
            y += 40;
        }
        if (s.conflict_count > 0) self.drawSection(ui, area, &y, .conflicts, state);
        if (s.staged_count > 0) self.drawSection(ui, area, &y, .staged, state);
        if (s.unstaged_count > 0) self.drawSection(ui, area, &y, .unstaged, state);
        self.list_h = (y - top) + 16;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.list_scroll, self.list_h);
    }

    fn drawSection(self: *View, ui: *Ui, area: Rect, y: *f32, section: Section, state: State) void {
        const dl = ui.dl;
        const s = state.snapshot;
        var buf: [40]u8 = undefined;
        const title = switch (section) {
            .conflicts => std.fmt.bufPrint(&buf, "CONFLICTS ({d})", .{s.conflict_count}) catch "",
            .staged => std.fmt.bufPrint(&buf, "STAGED ({d})", .{s.staged_count}) catch "",
            .unstaged => std.fmt.bufPrint(&buf, "UNSTAGED ({d})", .{s.unstaged_count}) catch "",
        };
        const head: Rect = .{ .x = area.x, .y = y.*, .w = area.w, .h = head_h };
        y.* += head_h;
        _ = kit.label(ui, head.x + pad, head.centerY(), title);
        if (section != .conflicts) {
            const text: []const u8 = if (section == .staged) "Unstage all" else "Stage all";
            const tw = ui.text.measure(theme.font_hint, text) + 12;
            const br: Rect = .{ .x = head.right() - pad - tw + 6, .y = head.centerY() - 11, .w = tw, .h = 22 };
            if (field.textButton(ui, Ui.id("repo.changes.all", @backingInt(section)), br, text, theme.text_2)) {
                self.intent = if (section == .staged) .unstage_all else .stage_all;
            }
        }
        for (s.entries.items, 0..) |e, i| {
            const mine = switch (section) {
                .conflicts => e.conflict(),
                .staged => e.staged(),
                .unstaged => e.unstaged(),
            };
            if (!mine) continue;
            const row: Rect = .{ .x = area.x + 6, .y = y.*, .w = area.w - 12, .h = row_h };
            y.* += row_h;
            if (row.bottom() < area.y or row.y > area.bottom()) continue;
            const key = i * 4 + @backingInt(section);
            const staged = section == .staged;
            const selected = if (state.selected) |sel| sel.staged == staged and std.mem.eql(u8, sel.path, e.path) else false;

            // The checkbox takes its press before the row does.
            const box: Rect = .{ .x = row.x + 8, .y = row.centerY() - 7, .w = 14, .h = 14 };
            const bst = ui.button(Ui.id("repo.changes.box", key), .{ .x = box.x - 5, .y = row.y, .w = 24, .h = row.h });
            const st = ui.button(Ui.id("repo.changes.row", key), row);
            if (selected) dl.rrect(row, 8, theme.accent.alpha(0.13)) else ui.feedback(row, 8, st);
            if (staged) {
                dl.rrect(box, 3, theme.accent);
                dl.icon(.check, box.x + 1, box.y + 1, 12, theme.on_accent);
            } else {
                dl.shape(box, 3, theme.bg_inset, 1, if (bst.hover) theme.text_2 else theme.line_strong);
            }
            if (bst.clicked) self.intent = if (staged) .{ .unstage = e.path } else .{ .stage = e.path };

            const letter: u8 = switch (section) {
                .conflicts => '!',
                .staged => e.stagedLetter(),
                .unstaged => e.unstagedLetter(),
            };
            kit.badge(ui, row.x + 30, row.centerY(), letter, 18);
            var right_x = row.right() - 8;
            const counts = if (staged) state.staged_counts else state.unstaged_counts;
            if (countOf(counts, e.path)) |c| {
                if (c.binary) {
                    right_x -= dl.textRight(kit.font_mono_small, right_x, row.centerY(), "bin", theme.text_3);
                } else right_x -= kit.plusMinus(ui, right_x, row.centerY(), c.added, c.removed, kit.font_mono_small);
            }
            const name = status.baseName(e.path);
            const dir = status.dirName(e.path);
            const tx = row.x + 56;
            const room = @max(0, right_x - 8 - tx);
            const nw = dl.textEllipsis(if (selected) ui_mod.Font.monoSemibold(12) else kit.font_mono, tx, row.centerY(), name, room, if (letter == 'D') theme.text_3 else theme.text);
            if (!std.mem.eql(u8, dir, ".") and nw + 8 < room) _ = dl.textEllipsis(kit.font_mono_small, tx + nw + 8, row.centerY(), dir, room - nw - 8, theme.text_3);
            if (st.clicked and !e.is_dir) self.intent = .{ .select = .{ .path = e.path, .staged = staged, .untracked = e.untracked() } };
        }
        y.* += 6;
    }

    // ── the composer ────────────────────────────────────────────────────
    fn drawComposer(self: *View, ui: *Ui, focus: *field.Focus, area: Rect, state: State) void {
        const dl = ui.dl;
        const s = state.snapshot;
        dl.rect(area, theme.bg_side);
        dl.rect(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, theme.line);
        const x = area.x + pad;
        const w = area.w - 2 * pad;
        var y = area.y + 12;
        _ = kit.label(ui, x, y + 10, "COMMIT MESSAGE");
        y += 26;

        const sr: Rect = .{ .x = x, .y = y, .w = w, .h = field.height };
        if (field.draw(ui, focus, field_summary, sr, self.summary.items, .{ .placeholder = if (self.amend) "Summary (empty keeps the last message)" else "Summary (↵ to commit)", .font = kit.font_text }).clicked) focus.take(field_summary, self.summary.items, ui.now);
        if (self.need_summary) dl.border(sr, 8, 1, theme.red.alpha(0.8));
        y += field.height + 8;
        const dr: Rect = .{ .x = x, .y = y, .w = w, .h = field.height };
        if (field.draw(ui, focus, field_description, dr, self.description.items, .{ .placeholder = "Description (optional)", .font = kit.font_text }).clicked) focus.take(field_description, self.description.items, ui.now);
        y += field.height + 10;
        // A press anywhere else gives the focus up; what was typed stays.
        if (ui.pressed and (focus.id == field_summary or focus.id == field_description) and !ui.mouseIn(sr) and !ui.mouseIn(dr)) {
            self.sync(focus);
            focus.drop();
        }

        // "Amend last commit", and how much is staged.
        {
            const row: Rect = .{ .x = x, .y = y, .w = w, .h = 22 };
            const label = "Amend last commit";
            const lw = ui.text.measure(kit.font_small, label);
            const hit: Rect = .{ .x = row.x, .y = row.y, .w = 22 + lw, .h = row.h };
            const st = ui.button(Ui.id("repo.changes.amend", 0), hit);
            const box: Rect = .{ .x = row.x, .y = row.centerY() - 7, .w = 14, .h = 14 };
            if (self.amend) {
                dl.rrect(box, 3, theme.accent);
                dl.icon(.check, box.x + 1, box.y + 1, 12, theme.on_accent);
            } else dl.shape(box, 3, theme.bg_inset, 1, if (st.hover) theme.text_2 else theme.line_strong);
            _ = dl.textCentered(kit.font_small, row.x + 22, row.centerY(), label, if (st.hover) theme.text else theme.text_2);
            if (st.clicked and !s.unborn) self.amend = !self.amend;
            var buf: [32]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d} {s}", .{ s.staged_count, if (s.staged_count == 1) "file" else "files" }) catch "";
            _ = dl.textRight(kit.font_mono_small, row.right(), row.centerY(), n, theme.text_3);
            y += 22 + 10;
        }

        {
            const all = s.staged_count == 0 and s.unstaged_count > 0 and !self.amend;
            const can = !state.busy and (self.amend or s.staged_count + s.unstaged_count > 0);
            var buf: [160]u8 = undefined;
            const branch = if (s.branch.len > 0) s.branch else "HEAD";
            const text = std.fmt.bufPrint(&buf, "{s} on {s}", .{ if (self.amend) "Amend commit" else if (all) "Commit all" else "Commit", branch }) catch "Commit";
            // One button: the arrow inside its right end opens the commit's options, above it.
            const split = kit.splitButton(ui, Ui.id("repo.changes.commit", 0), Ui.id("repo.changes.options", 0), .{ .x = x, .y = y, .w = w, .h = 36 }, text, .check, kit.font_button, can);
            if (split.clicked) {
                self.commitNow(s);
                if (self.need_summary and focus.id != field_summary) focus.take(field_summary, self.summary.items, ui.now);
            }
            if (split.arrow) self.intent = .{ .options = .{ .x = split.arrow_rect.right() - 200, .y = split.arrow_rect.y - 4 - 28 * @as(f32, option_rows.len) - 10 } };
            y += 36 + 6;
        }

        // What is under way, or what went wrong.
        if (state.cmd_label.len > 0) {
            _ = dl.textEllipsis(theme.font_hint, x, y + 10, state.cmd_label, w, theme.text_3);
        } else {
            const err: []const u8 = if (self.need_summary) "A commit needs a summary." else state.last_error;
            if (err.len > 0) _ = dl.textEllipsis(theme.font_hint, x, y + 10, err, w, theme.red);
        }
    }

    // ── the diff ────────────────────────────────────────────────────────
    fn drawDiff(self: *View, ui: *Ui, rect: Rect, state: State) void {
        const dl = ui.dl;
        const sel = state.selected orelse {
            _ = dl.textEllipsis(kit.font_text, rect.x + 20, rect.y + 28, "Select a file to see its changes.", rect.w - 40, theme.text_3);
            return;
        };
        // A different file starts at its top.
        if (!std.mem.eql(u8, self.scrolled_for.items, sel.path)) {
            self.scrolled_for.clearRetainingCapacity();
            self.scrolled_for.appendSlice(self.gpa, sel.path) catch {};
            self.diff_scroll = 0;
            self.diff_scroll_x = 0;
        }
        var entry: ?status.Entry = null;
        for (state.snapshot.entries.items) |e| {
            if (std.mem.eql(u8, e.path, sel.path)) entry = e;
        }

        // The file, its counts, and the controls.
        const head: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = diff_head_h };
        dl.rect(.{ .x = head.x, .y = head.bottom() - 1, .w = head.w, .h = 1 }, theme.line);
        var right = head.right() - 16;
        if (!sel.staged) {
            const bw = kit.buttonWidth(ui, "Discard", false);
            right -= bw;
            if (kit.button(ui, Ui.id("repo.changes.discard", 0), .{ .x = right, .y = head.centerY() - 14, .w = bw, .h = 28 }, "Discard", null, .secondary, !state.busy)) {
                self.intent = .{ .discard = .{ .path = sel.path, .untracked = if (entry) |e| e.untracked() else false } };
            }
            right -= 10;
        }
        {
            // Unified is this view; Split is the diff tab.
            const uw = ui.text.measure(theme.font_chip, "Unified") + 22;
            const sw = ui.text.measure(theme.font_chip, "Split") + 22;
            const seg: Rect = .{ .x = right - uw - sw - 4, .y = head.centerY() - 14, .w = uw + sw + 4, .h = 28 };
            dl.shape(seg, 8, theme.bg_inset, 1, theme.line);
            const ur: Rect = .{ .x = seg.x + 2, .y = seg.y + 2, .w = uw, .h = 24 };
            dl.rrect(ur, 6, theme.chip_active);
            _ = dl.textCentered(theme.font_chip, ur.x + 11, ur.centerY(), "Unified", theme.text);
            const spr: Rect = .{ .x = ur.right(), .y = seg.y + 2, .w = sw, .h = 24 };
            const st = ui.button(Ui.id("repo.changes.split", 0), spr);
            ui.feedback(spr, 6, st);
            _ = dl.textCentered(theme.font_chip, spr.x + 11, spr.centerY(), "Split", if (st.hover) theme.text else theme.text_2);
            if (st.clicked) self.intent = .{ .split = .{ .path = sel.path, .staged = sel.staged, .orig = if (sel.staged) (if (entry) |e| e.orig else null) else null } };
            right = seg.x - 12;
        }
        var x = head.x + 16;
        if (entry) |e| {
            kit.badge(ui, x, head.centerY(), if (sel.staged) e.stagedLetter() else e.unstagedLetter(), 18);
            x += 26;
        }
        if (state.patch) |p| right -= kit.plusMinus(ui, right, head.centerY(), p.added, p.removed, kit.font_mono) + 10;
        _ = dl.textEllipsis(ui_mod.Font.monoSemibold(12.5), x, head.centerY(), sel.path, @max(0, right - x), theme.text);

        const area: Rect = .{ .x = rect.x, .y = head.bottom(), .w = rect.w, .h = @max(0, rect.h - diff_head_h) };
        const p = state.patch orelse {
            _ = dl.textEllipsis(kit.font_text, area.x + 20, area.y + 24, "Reading…", area.w - 40, theme.text_3);
            return;
        };
        if (p.lines.len == 0) {
            _ = dl.textEllipsis(kit.font_text, area.x + 20, area.y + 24, if (p.binary) "A binary file: nothing to show line by line." else "No lines changed.", area.w - 40, theme.text_3);
            return;
        }
        drawPatch(ui, area, p, &self.diff_scroll, &self.diff_scroll_x, Ui.id("repo.changes.bar", 0));
    }
};

/// A unified diff in `area`, scrolled by `scroll` (down) and `scroll_x`
/// (across); both are updated from the wheel and the scrollbar.
pub fn drawPatch(ui: *Ui, area: Rect, p: *const patch_mod.Patch, scroll: *f32, scroll_x: *f32, bar_id: u64) void {
    const dl = ui.dl;
    const font = theme.font_output;
    const content_h = @as(f32, @floatFromInt(p.lines.len)) * line_h + 12;
    const max_scroll = @max(0, content_h - area.h);
    if (sidebar.scrollbarDrag(ui, bar_id, .vertical, area, scroll.*, content_h)) |to| scroll.* = to;
    if (ui.mouseIn(area) and ui.scroll_x != 0) {
        scroll_x.* = @max(0, scroll_x.* - ui.scroll_x);
        ui.scroll_x = 0;
    }
    scroll.* = std.math.clamp(scroll.* - ui.takeScroll(area), 0, max_scroll);
    dl.pushClip(area);
    defer dl.popClip();

    const text_x = area.x + gutter_w + marker_w;
    const first: usize = @intFromFloat(@floor(scroll.* / line_h));
    const visible: usize = @as(usize, @intFromFloat(@ceil(area.h / line_h))) + 1;
    var widest: f32 = 0;
    var i = first;
    while (i < p.lines.len and i < first + visible) : (i += 1) {
        const line = p.lines[i];
        const row: Rect = .{ .x = area.x, .y = area.y + @as(f32, @floatFromInt(i)) * line_h - scroll.*, .w = area.w, .h = line_h };
        const cy = row.centerY();
        switch (line.kind) {
            .added => dl.rect(row, kit.green().alpha(0.10)),
            .removed => dl.rect(row, theme.red.alpha(0.10)),
            .hunk => dl.rect(row, kit.blue().alpha(0.12)),
            .context, .note => {},
        }
        if (line.kind == .hunk) {
            _ = dl.textEllipsis(font, area.x + gutter_w, cy, line.text, area.w - gutter_w - 12, Color.mix(kit.blue(), theme.text, 0.35));
            continue;
        }
        if (line.kind == .note) {
            _ = dl.textEllipsis(kit.font_small, text_x, cy, line.text, area.w - gutter_w - marker_w - 12, theme.text_3);
            continue;
        }
        var buf: [16]u8 = undefined;
        const no = if (line.kind == .removed) line.old_no else line.new_no;
        _ = dl.textRight(kit.font_mono_small, area.x + gutter_w - 8, cy, std.fmt.bufPrint(&buf, "{d}", .{no}) catch "", theme.text_3);
        if (line.kind == .added) _ = dl.textCentered(font, area.x + gutter_w + 4, cy, "+", kit.green());
        if (line.kind == .removed) _ = dl.textCentered(font, area.x + gutter_w + 4, cy, "−", theme.red);

        dl.pushClip(.{ .x = text_x, .y = row.y, .w = @max(0, area.right() - text_x), .h = row.h });
        const pen = kit.code(ui, font, text_x - scroll_x.*, cy, line.text, if (line.kind == .context) theme.text_2 else theme.text);
        dl.popClip();
        widest = @max(widest, pen);
    }
    // No further across than the longest line on show needs.
    scroll_x.* = @min(scroll_x.*, @max(0, widest + 40 - (area.right() - text_x)));
    if (max_scroll > 0) sidebar.drawScrollbarAxis(ui, bar_id, .vertical, area, scroll.*, content_h);
}

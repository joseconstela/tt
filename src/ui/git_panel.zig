//! The Git view of the files panel: a source-control client in the idiom
//! of VS Code's — the branch, a message box, a Commit button, and the
//! changes in lists (merge conflicts, staged, not yet) with stage /
//! unstage / discard buttons on each row and each list. A row opens its
//! file. Discards ask first: the panel hands the app a question, the app
//! shows the box and calls `discardConfirmed` when it is accepted.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const field = @import("field.zig");
const sidebar = @import("sidebar.zig");
const git = @import("../git.zig");
const sys = @import("../sys.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

const row_h: f32 = 26;
const pad: f32 = 12;
const button_h: f32 = 32;
const small: f32 = 22;
/// The message field, in the panel's own numbering of fields (there is one).
const field_id: u64 = 1;
pub const font_badge = Font.medium(12);

/// What a discard needs the user to agree to (strings live in the panel
/// until the next frame).
pub const Confirm = struct { heading: []const u8, reason: []const u8 };

pub const Result = struct {
    /// A row was clicked: the file's absolute path (valid this frame).
    open_file: ?[]const u8 = null,
    /// A discard was asked for: the app shows this and confirms it back.
    confirm: ?Confirm = null,
};

/// The colour a path with `kind` gets, in the tree and here.
pub fn kindColor(kind: git.Kind) Color {
    return switch (kind) {
        .untracked, .added => theme.ansi[2],
        .modified => theme.ansi[3],
        .deleted, .conflict => theme.red,
        .ignored => theme.text_3,
        .none => theme.text_2,
    };
}

/// The badge letter of a path with `kind` (VS Code's).
pub fn kindLetter(kind: git.Kind) []const u8 {
    return switch (kind) {
        .untracked => "U",
        .added => "A",
        .modified => "M",
        .deleted => "D",
        .conflict => "!",
        .ignored, .none => "",
    };
}

fn letterColor(letter: u8) Color {
    return switch (letter) {
        'U', 'A' => theme.ansi[2],
        'D', '!' => theme.red,
        else => theme.ansi[3],
    };
}

const Section = enum { merge, staged, changes };

pub const Panel = struct {
    gpa: std.mem.Allocator,
    repo: git.Repo,
    /// The commit message as last typed.
    message: std.ArrayList(u8) = .empty,
    focus: field.Focus,
    scroll: f32 = 0,
    content_h: f32 = 0,
    merge_open: bool = true,
    staged_open: bool = true,
    changes_open: bool = true,
    /// A discard waiting for its confirmation: a root-relative path, or
    /// everything when `pending_all`.
    pending: std.ArrayList(u8) = .empty,
    pending_untracked: bool = false,
    pending_all: bool = false,
    heading_buf: [160]u8 = undefined,
    reason_buf: [200]u8 = undefined,
    /// The absolute path of the row acted on this frame.
    out_path: std.ArrayList(u8) = .empty,
    /// Commit was pressed with no message: said until typing starts.
    need_message: bool = false,

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{ .gpa = gpa, .repo = git.Repo.init(gpa), .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *Panel) void {
        self.repo.deinit();
        self.focus.deinit();
        self.message.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.out_path.deinit(self.gpa);
    }

    pub fn setDir(self: *Panel, dir: []const u8) void {
        self.repo.setDir(dir);
    }

    /// Whether `dir` is inside the repository last read.
    pub fn isRepoFor(self: *const Panel, dir: []const u8) bool {
        return self.repo.isRepoFor(dir);
    }

    /// Everything the lists would show.
    pub fn changeCount(self: *const Panel) u32 {
        const s = &self.repo.snapshot;
        return s.staged_count + s.unstaged_count + s.conflict_count;
    }

    /// Background readings and the caret blink; true when a redraw is needed.
    pub fn tick(self: *Panel, now: f64) bool {
        const fresh = self.repo.tick(now);
        const blink = self.focus.tick(now);
        return fresh or blink;
    }

    // ── keyboard, routed by the app while the message field is focused ──
    pub fn hasFocus(self: *const Panel) bool {
        return self.focus.active();
    }

    pub fn onText(self: *Panel, utf8: []const u8) void {
        self.focus.onText(utf8);
        self.need_message = false;
    }

    pub fn onMarkedText(self: *Panel, utf8: []const u8) void {
        self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *Panel, utf8: []const u8) void {
        self.focus.paste(utf8);
        self.need_message = false;
    }

    /// ↵ commits; the rest edits the message (Esc gives the focus up).
    pub fn onEdit(self: *Panel, cmd: EditCommand) void {
        switch (cmd) {
            .insert_newline, .insert_line_break => {
                self.syncMessage();
                self.commitNow();
            },
            else => _ = self.focus.onEdit(cmd),
        }
    }

    pub fn onCtrl(self: *Panel, key: u8) void {
        _ = self.focus.onCtrl(key);
    }

    pub fn copy(self: *Panel, out: *std.ArrayList(u8), cut: bool) bool {
        return self.focus.copy(out, cut);
    }

    pub fn hasMarkedText(self: *const Panel) bool {
        return self.focus.hasMarkedText();
    }

    pub fn caretRect(self: *const Panel) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    fn syncMessage(self: *Panel) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        self.message.clearRetainingCapacity();
        self.message.appendSlice(self.gpa, self.focus.editor.bytes()) catch {};
        self.focus.markSynced();
    }

    fn takeFocus(self: *Panel, now: f64) void {
        self.focus.take(field_id, self.message.items, now);
        // Typing carries on at the end rather than replacing the message.
        self.focus.editor.setCursor(self.message.items.len, false);
    }

    // ── commands ────────────────────────────────────────────────────────
    fn commitNow(self: *Panel) void {
        const s = &self.repo.snapshot;
        const msg = std.mem.trim(u8, self.message.items, " \t\r\n");
        if (s.staged_count + s.unstaged_count == 0) return;
        if (msg.len == 0) {
            self.need_message = true;
            return;
        }
        if (self.repo.commit(msg, s.staged_count == 0)) {
            self.message.clearRetainingCapacity();
            if (self.focus.active()) self.focus.take(field_id, "", self.focus.blink_t0);
        }
    }

    /// The box was accepted: runs the discard that waited for it.
    pub fn discardConfirmed(self: *Panel) void {
        if (self.pending_all) {
            _ = self.repo.discardAll();
        } else if (self.pending.items.len > 0) {
            _ = self.repo.discard(self.pending.items, self.pending_untracked);
        }
        self.pending.clearRetainingCapacity();
        self.pending_all = false;
    }

    fn askDiscard(self: *Panel, e: git.Entry) Confirm {
        self.pending.clearRetainingCapacity();
        self.pending.appendSlice(self.gpa, e.path) catch {};
        self.pending_untracked = e.untracked();
        self.pending_all = false;
        const name = sys.basename(e.path);
        const heading = std.fmt.bufPrint(&self.heading_buf, "Discard changes in “{s}”?", .{name}) catch "Discard changes?";
        const reason = if (e.untracked())
            "The file is not in git yet: it is deleted. This cannot be undone."
        else if (e.y == 'D')
            "The file comes back as the index has it."
        else
            "The file goes back to what the index has. This cannot be undone.";
        return .{ .heading = heading, .reason = reason };
    }

    fn askDiscardAll(self: *Panel) Confirm {
        const s = &self.repo.snapshot;
        self.pending.clearRetainingCapacity();
        self.pending_all = true;
        var untracked: u32 = 0;
        for (s.entries.items) |e| {
            if (e.untracked()) untracked += 1;
        }
        const heading = std.fmt.bufPrint(&self.heading_buf, "Discard all {d} changes?", .{s.unstaged_count}) catch "Discard all changes?";
        const reason = if (untracked > 0)
            std.fmt.bufPrint(&self.reason_buf, "Files go back to the index and {d} new {s} deleted. This cannot be undone.", .{ untracked, if (untracked == 1) "file is" else "files are" }) catch "This cannot be undone."
        else
            "Files go back to what the index has. This cannot be undone.";
        return .{ .heading = heading, .reason = reason };
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws the view in `rect` (under the panel's Files / Git strip).
    pub fn draw(self: *Panel, ui: *Ui, rect: Rect) Result {
        var res: Result = .{};
        const dl = ui.dl;
        const s = &self.repo.snapshot;
        self.syncMessage();

        var y = rect.y;
        const x = rect.x + pad;
        const w = rect.w - 2 * pad;

        // The branch, and a refresh button.
        {
            const row: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = 28 };
            var right = row.right() - pad;
            const rr: Rect = .{ .x = right - small, .y = row.centerY() - small / 2, .w = small, .h = small };
            const st = ui.button(Ui.id("git.refresh", 0), rr);
            ui.feedback(rr, 6, st);
            dl.icon(.reload, rr.x + 4, rr.y + 4, 14, if (self.repo.busy()) theme.text_3.alpha(0.5) else if (st.hover) theme.text else theme.text_3);
            if (st.clicked) self.repo.refreshSoon();
            right = rr.x - 8;

            dl.icon(.branch, x, row.centerY() - 8, 16, theme.text_3);
            var lx = x + 22;
            const branch = if (s.branch.len > 0) s.branch else "no branch";
            const bw = dl.textEllipsis(theme.font_side_medium, lx, row.centerY(), branch, @max(0, right - lx - 4), theme.text);
            lx += bw + 8;
            var hint_buf: [48]u8 = undefined;
            const hint: []const u8 = if (s.unborn)
                "no commits yet"
            else if (s.ahead > 0 and s.behind > 0)
                std.fmt.bufPrint(&hint_buf, "↑{d} ↓{d}", .{ s.ahead, s.behind }) catch ""
            else if (s.ahead > 0)
                std.fmt.bufPrint(&hint_buf, "↑{d}", .{s.ahead}) catch ""
            else if (s.behind > 0)
                std.fmt.bufPrint(&hint_buf, "↓{d}", .{s.behind}) catch ""
            else
                "";
            if (hint.len > 0 and lx < right) _ = dl.textEllipsis(theme.font_hint, lx, row.centerY(), hint, right - lx, theme.text_3);
            y += 28 + 4;
        }

        // The message.
        {
            const fr: Rect = .{ .x = x, .y = y, .w = w, .h = field.height };
            var ph_buf: [96]u8 = undefined;
            const ph = std.fmt.bufPrint(&ph_buf, "Message (↵ to commit on “{s}”)", .{if (s.branch.len > 0) s.branch else "HEAD"}) catch "Message";
            const fres = field.draw(ui, &self.focus, field_id, fr, self.message.items, .{ .placeholder = ph, .font = theme.font_side });
            if (fres.clicked) self.takeFocus(ui.now);
            // A press anywhere else gives the focus up.
            if (ui.pressed and self.focus.active() and !ui.mouseIn(fr)) {
                self.syncMessage();
                self.focus.drop();
            }
            if (self.need_message) dl.border(fr, 8, 1, theme.red.alpha(0.8));
            y += field.height + 8;
        }

        // Commit.
        {
            const can = s.staged_count + s.unstaged_count > 0;
            const label: []const u8 = if (s.staged_count == 0 and s.unstaged_count > 0) "Commit All" else "Commit";
            const br: Rect = .{ .x = x, .y = y, .w = w, .h = button_h };
            const st = ui.button(Ui.id("git.commit", 0), br);
            const fill = if (!can) theme.accent.alpha(0.35) else if (st.held) Color.mix(theme.accent, theme.on_accent, 0.15) else if (st.hover) Color.mix(theme.accent, theme.text, 0.12) else theme.accent;
            dl.rrect(br, 8, fill);
            const lw = ui.text.measure(theme.font_ui_medium, label);
            const cx = br.x + (br.w - lw - 20) / 2;
            const ink = if (can) theme.on_accent else theme.on_accent.alpha(0.7);
            dl.icon(.check, cx, br.centerY() - 8, 16, ink);
            _ = dl.textCentered(theme.font_ui_medium, cx + 20, br.centerY(), label, ink);
            if (st.clicked and can) {
                self.commitNow();
                if (self.need_message and !self.focus.active()) self.takeFocus(ui.now);
            }
            y += button_h + 6;
        }

        // What went wrong, if something did.
        {
            const err: []const u8 = if (self.need_message) "A commit message is needed." else self.repo.last_error.items;
            if (err.len > 0) {
                _ = dl.textEllipsis(theme.font_hint, x, y + 10, err, w, theme.red);
                y += 20;
            }
        }
        y += 4;

        // The lists.
        const area: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(0, rect.bottom() - y) };
        const max_scroll = @max(0, self.content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        var cy = area.y - self.scroll;
        const top = cy;
        if (self.changeCount() == 0) {
            _ = dl.textEllipsis(theme.font_hint, x, cy + 14, if (s.isRepo()) "No changes" else "Not a git repository", w, theme.text_3);
            cy += 28;
        } else {
            if (s.conflict_count > 0) self.drawSection(ui, rect, .merge, &cy, &res);
            if (s.staged_count > 0) self.drawSection(ui, rect, .staged, &cy, &res);
            if (s.unstaged_count > 0) self.drawSection(ui, rect, .changes, &cy, &res);
        }
        self.content_h = (cy - top) + 12;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);
        return res;
    }

    fn drawSection(self: *Panel, ui: *Ui, panel: Rect, section: Section, y: *f32, res: *Result) void {
        const dl = ui.dl;
        const s = &self.repo.snapshot;
        const open = switch (section) {
            .merge => &self.merge_open,
            .staged => &self.staged_open,
            .changes => &self.changes_open,
        };
        const count = switch (section) {
            .merge => s.conflict_count,
            .staged => s.staged_count,
            .changes => s.unstaged_count,
        };
        const title: []const u8 = switch (section) {
            .merge => "Merge Changes",
            .staged => "Staged Changes",
            .changes => "Changes",
        };
        const sid: usize = @intFromEnum(section);

        // The header: chevron, title, the count, and on hover what applies to the whole list.
        const row: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
        y.* += row_h;
        const hovered = ui.mouseIn(row);
        var right = row.right() - 8;
        {
            var buf: [16]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "?";
            const nw = ui.text.measure(font_badge, n);
            const pill: Rect = .{ .x = right - (nw + 12), .y = row.centerY() - 9, .w = nw + 12, .h = 18 };
            dl.rrect(pill, 9, theme.accent);
            _ = dl.textCentered(font_badge, pill.x + 6, pill.centerY(), n, theme.on_accent);
            right = pill.x - 6;
        }
        if (hovered) {
            switch (section) {
                .staged => if (self.smallButton(ui, Ui.id("git.unstage_all", sid), &right, row, .minus)) {
                    _ = self.repo.unstageAll();
                },
                .changes => {
                    if (self.smallButton(ui, Ui.id("git.stage_all", sid), &right, row, .plus)) _ = self.repo.stageAll();
                    if (self.smallButton(ui, Ui.id("git.discard_all", sid), &right, row, .undo)) res.confirm = self.askDiscardAll();
                },
                .merge => if (self.smallButton(ui, Ui.id("git.stage_all", sid), &right, row, .plus)) {
                    _ = self.repo.stageAll();
                },
            }
        }
        const st = ui.button(Ui.id("git.section", sid), row);
        ui.feedback(row, 6, st);
        dl.icon(if (open.*) .chevron_down else .chevron_right, row.x + 8, row.centerY() - 7, 14, theme.text_3);
        _ = dl.textEllipsis(theme.font_side_medium, row.x + 28, row.centerY(), title, @max(0, right - row.x - 32), theme.text);
        if (st.clicked) open.* = !open.*;
        if (!open.*) return;

        for (s.entries.items, 0..) |e, i| {
            const in_section = switch (section) {
                .merge => e.conflict(),
                .staged => e.staged(),
                .changes => e.unstaged(),
            };
            if (!in_section) continue;
            self.drawRow(ui, panel, section, e, i, y, res);
        }
    }

    fn drawRow(self: *Panel, ui: *Ui, panel: Rect, section: Section, e: git.Entry, i: usize, y: *f32, res: *Result) void {
        const dl = ui.dl;
        const clip = dl.currentClip();
        const row: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
        y.* += row_h;
        if (row.bottom() <= clip.y or row.y >= clip.bottom()) return;
        const key = i * 4 + @intFromEnum(section);
        const hovered = ui.mouseIn(row);
        var right = row.right() - 8;

        const letter: u8 = switch (section) {
            .merge => '!',
            .staged => e.stagedLetter(),
            .changes => e.unstagedLetter(),
        };
        const lcolor = letterColor(letter);
        right -= dl.textRight(font_badge, right, row.centerY(), &[_]u8{letter}, lcolor) + 6;

        if (hovered) {
            switch (section) {
                .staged => if (self.smallButton(ui, Ui.id("git.unstage", key), &right, row, .minus)) {
                    _ = self.repo.unstage(e.path);
                },
                .changes => {
                    if (self.smallButton(ui, Ui.id("git.stage", key), &right, row, .plus)) _ = self.repo.stage(e.path);
                    if (self.smallButton(ui, Ui.id("git.discard", key), &right, row, .undo)) res.confirm = self.askDiscard(e);
                },
                .merge => if (self.smallButton(ui, Ui.id("git.stage", key), &right, row, .plus)) {
                    _ = self.repo.stage(e.path);
                },
            }
        }
        const st = ui.button(Ui.id("git.row", key), row);
        ui.feedback(row, 6, st);

        // The name, then where it is.
        const name = sys.basename(e.path);
        const dir = sys.dirname(e.path);
        var lx = row.x + 28;
        const name_color = if (letter == 'D') theme.text_3 else theme.text;
        const nw = dl.textEllipsis(theme.font_side, lx, row.centerY(), name, @max(0, right - lx), name_color);
        lx += nw + 8;
        if (!std.mem.eql(u8, dir, ".") and lx < right) _ = dl.textEllipsis(theme.font_hint, lx, row.centerY(), dir, right - lx, theme.text_3);

        if (st.clicked and letter != 'D' and self.repo.snapshot.isRepo()) {
            self.out_path.clearRetainingCapacity();
            self.out_path.appendSlice(self.gpa, self.repo.snapshot.root) catch return;
            self.out_path.append(self.gpa, '/') catch return;
            self.out_path.appendSlice(self.gpa, e.path) catch return;
            res.open_file = self.out_path.items;
        }
    }

    /// A 22pt icon button at the right end of a row; moves `right` past it.
    fn smallButton(_: *Panel, ui: *Ui, wid: u64, right: *f32, row: Rect, icon: @import("../gfx/icons.zig").Icon) bool {
        const r: Rect = .{ .x = right.* - small, .y = row.centerY() - small / 2, .w = small, .h = small };
        const st = ui.button(wid, r);
        ui.feedback(r, 6, st);
        ui.dl.icon(icon, r.x + 4, r.y + 4, 14, if (st.hover) theme.text else theme.text_3);
        right.* = r.x - 2;
        return st.clicked;
    }
};

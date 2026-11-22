//! The Git view of the files panel, drawn: a source-control client in the
//! idiom of VS Code's — the branch, a message box, a Commit button, and
//! the changes in lists (merge conflicts, staged, not yet) with stage /
//! unstage / discard buttons on each row and each list. A row opens its
//! change as a side-by-side comparison (the `diff` feature): what is
//! staged against the last commit, what is not against the index.
//!
//! This file only draws and keeps what the view itself remembers (the
//! message being typed, the scroll, which lists are open). It is shown a
//! reading of the repository (`State`) and runs nothing: what the user
//! asked for comes out as one `Intent` (`takeIntent`), which
//! `entry/panel.zig` hands to the git client, and as a `Result` for what
//! only the app can do (open a comparison, a menu, a confirmation box).
//! Discards ask first: the app shows the box and `discardConfirmed` turns
//! the answer into the intent.
//!
//! The arrow beside Commit opens the commit's options: Amend (the next
//! commit replaces the last one, and with no message keeps its own;
//! ⌘⇧↵ does the same, and commits once it is on), Signoff and Skip Hooks.
//! The ones in force are ticked; Amend goes off again once it is done.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const icons = @import("../../../gfx/icons.zig");
const status = @import("../model/status.zig");
const kit = @import("kit.zig");
const EditCommand = @import("../../../events.zig").EditCommand;

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

/// The branch menu, for the app to open (rows valid until the next click
/// on the branch): "Fetch All", then the branches, the current one ticked.
pub const Menu = struct {
    items: []const []const u8,
    checked: ?usize,
    /// Rows ticked besides `checked`, a bit each (the commit options in force).
    checks: u64 = 0,
    sep_after: ?usize,
    x: f32,
    y: f32,
};

pub const Result = struct {
    /// A row was clicked: the change to show side by side (valid this frame).
    open_diff: ?Diff = null,
    /// A discard was asked for: the app shows this and confirms it back.
    confirm: ?Confirm = null,
    /// The branch button was clicked: the app opens this menu and hands
    /// the picked row back to `menuPicked`.
    menu: ?Menu = null,
};

/// A row's change: the file's absolute path, which half of it the row
/// stands for, and where a staged rename came from (root-relative).
pub const Diff = struct { path: []const u8, staged: bool, orig: ?[]const u8 = null };

const MenuKind = enum { fetch, local, remote };

/// The commit options, in the menu's order (a shortcut after a tab).
const commit_rows = [_][]const u8{ "Amend\t⌘⇧↵", "Signoff", "Skip Hooks" };

/// The repository as the view is shown it this frame.
pub const State = struct {
    snapshot: *const status.Snapshot,
    /// A reading is on its way.
    busy: bool = false,
    /// A pull, push, fetch or switch is running, and what to call it.
    cmd_running: bool = false,
    cmd_label: []const u8 = "",
    /// What the last failed command said.
    last_error: []const u8 = "",
};

/// What the user asked git for. Paths are root-relative; every slice is
/// valid until the view is next drawn or handed input.
pub const Intent = union(enum) {
    refresh,
    fetch_all,
    push,
    pull,
    switch_branch: []const u8,
    switch_remote: []const u8,
    stage: []const u8,
    stage_all,
    unstage: []const u8,
    unstage_all,
    discard: struct { rel: []const u8, untracked: bool },
    discard_all,
    /// With `all`, everything is staged first. `committed` is the answer,
    /// once the commit is made. An amend with no message keeps the last
    /// commit's own.
    commit: struct { message: []const u8, all: bool, amend: bool = false, signoff: bool = false, no_verify: bool = false },
};

/// The colour a path with `kind` gets, in the tree and here.
pub fn kindColor(kind: status.Kind) Color {
    return switch (kind) {
        .untracked, .added => theme.ansi[2],
        .modified => theme.ansi[3],
        .deleted, .conflict => theme.red,
        .ignored => theme.text_3,
        .none => theme.text_2,
    };
}

/// The badge letter of a path with `kind` (VS Code's).
pub fn kindLetter(kind: status.Kind) []const u8 {
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

fn dl_text(ui: *Ui, x: f32, cy: f32, s: []const u8, color: Color) f32 {
    return ui.dl.textCentered(font_badge, x, cy, s, color);
}

pub const View = struct {
    gpa: std.mem.Allocator,
    /// What was asked for and not yet taken (`takeIntent`).
    intent: ?Intent = null,
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
    /// A question is out: `discardConfirmed` has something to answer.
    pending_asked: bool = false,
    heading_buf: [160]u8 = undefined,
    reason_buf: [200]u8 = undefined,
    /// The absolute path of the row acted on this frame.
    out_path: std.ArrayList(u8) = .empty,
    /// Commit was pressed with no message: said until typing starts.
    need_message: bool = false,
    /// The commit options in force.
    amend: bool = false,
    signoff: bool = false,
    skip_hooks: bool = false,
    /// Which menu the app has open for this view.
    menu_for: enum { branch, commit } = .branch,
    /// The rows of the branch menu last opened, and what each one is.
    menu_items: std.ArrayList([]const u8) = .empty,
    menu_kinds: std.ArrayList(MenuKind) = .empty,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *View) void {
        self.focus.deinit();
        self.message.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.out_path.deinit(self.gpa);
        self.clearMenu();
        self.menu_items.deinit(self.gpa);
        self.menu_kinds.deinit(self.gpa);
    }

    fn clearMenu(self: *View) void {
        for (self.menu_items.items) |s| self.gpa.free(s);
        self.menu_items.clearRetainingCapacity();
        self.menu_kinds.clearRetainingCapacity();
    }

    fn addMenuRow(self: *View, label: []const u8, kind: MenuKind) void {
        const owned = self.gpa.dupe(u8, label) catch return;
        self.menu_items.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        self.menu_kinds.append(self.gpa, kind) catch {
            _ = self.menu_items.pop();
            self.gpa.free(owned);
        };
    }

    /// Builds the branch menu: "Fetch All", the local branches (the
    /// current one ticked), then the remote branches with no local one.
    fn openBranchMenu(self: *View, s: *const status.Snapshot, x: f32, y: f32) Menu {
        self.menu_for = .branch;
        self.clearMenu();
        self.addMenuRow("Fetch All", .fetch);
        var checked: ?usize = null;
        for (s.branches.items) |b| {
            if (std.mem.eql(u8, b, s.branch)) checked = self.menu_items.items.len;
            self.addMenuRow(b, .local);
        }
        for (s.remotes.items) |r| {
            const slash = std.mem.indexOfScalar(u8, r, '/') orelse continue;
            if (s.hasBranch(r[slash + 1 ..])) continue;
            self.addMenuRow(r, .remote);
        }
        return .{ .items = self.menu_items.items, .checked = checked, .sep_after = 0, .x = x, .y = y };
    }

    /// The commit options as a menu, the ones in force ticked.
    fn openCommitMenu(self: *View, x: f32, y: f32) Menu {
        self.menu_for = .commit;
        var checks: u64 = 0;
        if (self.amend) checks |= 1;
        if (self.signoff) checks |= 2;
        if (self.skip_hooks) checks |= 4;
        return .{ .items = &commit_rows, .checked = null, .checks = checks, .sep_after = null, .x = x, .y = y };
    }

    /// ⌘⇧↵: turns Amend on, and commits when it already is.
    pub fn amendKey(self: *View, s: *const status.Snapshot) void {
        if (!self.amend) {
            self.amend = true;
            self.need_message = false;
            return;
        }
        self.syncMessage();
        self.commitNow(s);
    }

    /// Row `i` of the menu the app opened for this view was picked.
    pub fn menuPicked(self: *View, i: usize) void {
        if (self.menu_for == .commit) {
            switch (i) {
                0 => self.amend = !self.amend,
                1 => self.signoff = !self.signoff,
                2 => self.skip_hooks = !self.skip_hooks,
                else => {},
            }
            if (self.amend) self.need_message = false;
            return;
        }
        if (i >= self.menu_kinds.items.len) return;
        self.intent = switch (self.menu_kinds.items[i]) {
            .fetch => .fetch_all,
            .local => .{ .switch_branch = self.menu_items.items[i] },
            .remote => .{ .switch_remote = self.menu_items.items[i] },
        };
    }

    /// What was asked for since the last call, once.
    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    /// The caret blink; true when a redraw is needed.
    pub fn tick(self: *View, now: f64) bool {
        return self.focus.tick(now);
    }

    // ── keyboard, routed by the app while the message field is focused ──
    pub fn hasFocus(self: *const View) bool {
        return self.focus.active();
    }

    pub fn onText(self: *View, utf8: []const u8) void {
        self.focus.onText(utf8);
        self.need_message = false;
    }

    pub fn onMarkedText(self: *View, utf8: []const u8) void {
        self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *View, utf8: []const u8) void {
        self.focus.paste(utf8);
        self.need_message = false;
    }

    /// ↵ commits; the rest edits the message (Esc gives the focus up).
    pub fn onEdit(self: *View, cmd: EditCommand, s: *const status.Snapshot) void {
        switch (cmd) {
            .insert_newline, .insert_line_break => {
                self.syncMessage();
                self.commitNow(s);
            },
            else => _ = self.focus.onEdit(cmd),
        }
    }

    pub fn onCtrl(self: *View, key: u8) void {
        _ = self.focus.onCtrl(key);
    }

    pub fn copy(self: *View, out: *std.ArrayList(u8), cut: bool) bool {
        return self.focus.copy(out, cut);
    }

    pub fn hasMarkedText(self: *const View) bool {
        return self.focus.hasMarkedText();
    }

    /// Gives the keyboard up (the message typed so far is kept).
    pub fn dropFocus(self: *View) void {
        self.syncMessage();
        self.focus.drop();
    }

    pub fn caretRect(self: *const View) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    fn syncMessage(self: *View) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        self.message.clearRetainingCapacity();
        self.message.appendSlice(self.gpa, self.focus.editor.bytes()) catch {};
        self.focus.markSynced();
    }

    fn takeFocus(self: *View, now: f64) void {
        self.focus.take(field_id, self.message.items, now);
        // Typing carries on at the end rather than replacing the message.
        self.focus.editor.setCursor(self.message.items.len, false);
    }

    // ── commands ────────────────────────────────────────────────────────
    fn commitNow(self: *View, s: *const status.Snapshot) void {
        const msg = std.mem.trim(u8, self.message.items, " \t\r\n");
        // An amend needs neither a change nor a message: it can be for the message alone.
        if (!self.amend and s.staged_count + s.unstaged_count == 0) return;
        if (msg.len == 0 and !self.amend) {
            self.need_message = true;
            return;
        }
        self.intent = .{ .commit = .{
            .message = msg,
            .all = !self.amend and s.staged_count == 0,
            .amend = self.amend,
            .signoff = self.signoff,
            .no_verify = self.skip_hooks,
        } };
    }

    /// The commit asked for was made: the message has done its job, and
    /// so has Amend.
    pub fn committed(self: *View) void {
        self.amend = false;
        self.message.clearRetainingCapacity();
        if (self.focus.active()) self.focus.take(field_id, "", self.focus.blink_t0);
    }

    /// The box was accepted: asks for the discard that waited for it.
    pub fn discardConfirmed(self: *View) void {
        if (!self.pending_asked) return;
        self.pending_asked = false;
        if (self.pending_all) {
            self.intent = .discard_all;
        } else if (self.pending.items.len > 0) {
            self.intent = .{ .discard = .{ .rel = self.pending.items, .untracked = self.pending_untracked } };
        }
        self.pending_all = false;
    }

    fn askDiscard(self: *View, e: status.Entry) Confirm {
        self.pending.clearRetainingCapacity();
        self.pending.appendSlice(self.gpa, e.path) catch {};
        self.pending_untracked = e.untracked();
        self.pending_all = false;
        self.pending_asked = true;
        const name = status.baseName(e.path);
        const heading = std.fmt.bufPrint(&self.heading_buf, "Discard changes in “{s}”?", .{name}) catch "Discard changes?";
        const reason = if (e.untracked())
            "The file is not in git yet: it is deleted. This cannot be undone."
        else if (e.y == 'D')
            "The file comes back as the index has it."
        else
            "The file goes back to what the index has. This cannot be undone.";
        return .{ .heading = heading, .reason = reason };
    }

    fn askDiscardAll(self: *View, s: *const status.Snapshot) Confirm {
        self.pending.clearRetainingCapacity();
        self.pending_all = true;
        self.pending_asked = true;
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
    pub fn draw(self: *View, ui: *Ui, rect: Rect, state: State) Result {
        var res: Result = .{};
        const dl = ui.dl;
        const s = state.snapshot;
        self.syncMessage();

        var y = rect.y;
        const x = rect.x + pad;
        const w = rect.w - 2 * pad;

        // The branch; refresh, push and pull at the right (push and pull
        // carry how many commits are ahead / behind).
        {
            const row: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = 28 };
            var right = row.right() - pad;
            const rr: Rect = .{ .x = right - small, .y = row.centerY() - small / 2, .w = small, .h = small };
            const st = ui.button(Ui.id("git.refresh", 0), rr);
            ui.feedback(rr, 6, st);
            dl.icon(.reload, rr.x + 4, rr.y + 4, 14, if (state.busy) theme.text_3.alpha(0.5) else if (st.hover) theme.text else theme.text_3);
            if (st.clicked) self.intent = .refresh;
            right = rr.x - 6;
            const can_push = s.isRepo() and !s.unborn and !s.detached and !state.cmd_running;
            if (self.countButton(ui, Ui.id("git.push", 0), &right, row, .push, s.ahead, can_push)) self.intent = .push;
            const can_pull = s.isRepo() and s.upstream.len > 0 and !state.cmd_running;
            if (self.countButton(ui, Ui.id("git.pull", 0), &right, row, .pull, s.behind, can_pull)) self.intent = .pull;
            right -= 4;

            // The branch is a button: its menu fetches and switches.
            const branch = if (s.branch.len > 0) s.branch else "no branch";
            const name_w = @min(ui.text.measure(theme.font_side_medium, branch), @max(0, right - x - 60));
            const br: Rect = .{ .x = x - 6, .y = row.centerY() - 12, .w = 6 + 22 + name_w + 4 + 14 + 6, .h = 24 };
            const bst = ui.button(Ui.id("git.branch", 0), br);
            ui.feedback(br, 6, bst);
            dl.icon(.branch, x, row.centerY() - 8, 16, if (bst.hover) theme.text else theme.text_3);
            var lx = x + 22;
            _ = dl.textEllipsis(theme.font_side_medium, lx, row.centerY(), branch, name_w, theme.text);
            lx += name_w + 4;
            dl.icon(.chevron_down, lx, row.centerY() - 7, 14, if (bst.hover) theme.text else theme.text_3);
            lx += 14 + 10;
            if (bst.clicked and s.isRepo()) res.menu = self.openBranchMenu(s, br.x, br.bottom() + 4);
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
            const fres = field.draw(ui, &self.focus, field_id, fr, self.message.items, .{ .placeholder = if (self.amend) "Empty keeps the last message" else "Message (↵ to commit)", .font = theme.font_side });
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
            const can = self.amend or s.staged_count + s.unstaged_count > 0;
            const label: []const u8 = if (self.amend) "Amend" else if (s.staged_count == 0 and s.unstaged_count > 0) "Commit All" else "Commit";
            // One button: the arrow inside its right end opens the commit's options.
            const split = kit.splitButton(ui, Ui.id("git.commit", 0), Ui.id("git.commit_options", 0), .{ .x = x, .y = y, .w = w, .h = button_h }, label, .check, theme.font_ui_medium, can);
            if (split.arrow) res.menu = self.openCommitMenu(split.arrow_rect.right() - 200, split.arrow_rect.bottom() + 4);
            if (split.clicked) {
                self.commitNow(s);
                if (self.need_message and !self.focus.active()) self.takeFocus(ui.now);
            }
            y += button_h + 6;
        }

        // What is under way, or what went wrong.
        {
            if (state.cmd_label.len > 0) {
                _ = dl.textEllipsis(theme.font_hint, x, y + 10, state.cmd_label, w, theme.text_3);
                y += 20;
            } else {
                const err: []const u8 = if (self.need_message) "A commit message is needed." else state.last_error;
                if (err.len > 0) {
                    _ = dl.textEllipsis(theme.font_hint, x, y + 10, err, w, theme.red);
                    y += 20;
                }
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
        if (s.staged_count + s.unstaged_count + s.conflict_count == 0) {
            _ = dl.textEllipsis(theme.font_hint, x, cy + 14, if (s.isRepo()) "No changes" else "Not a git repository", w, theme.text_3);
            cy += 28;
        } else {
            if (s.conflict_count > 0) self.drawSection(ui, rect, s, .merge, &cy, &res);
            if (s.staged_count > 0) self.drawSection(ui, rect, s, .staged, &cy, &res);
            if (s.unstaged_count > 0) self.drawSection(ui, rect, s, .changes, &cy, &res);
        }
        self.content_h = (cy - top) + 12;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);
        return res;
    }

    fn drawSection(self: *View, ui: *Ui, panel: Rect, s: *const status.Snapshot, section: Section, y: *f32, res: *Result) void {
        const dl = ui.dl;
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
        const sid: usize = @backingInt(section);

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
                    self.intent = .unstage_all;
                },
                .changes => {
                    if (self.smallButton(ui, Ui.id("git.stage_all", sid), &right, row, .plus)) self.intent = .stage_all;
                    if (self.smallButton(ui, Ui.id("git.discard_all", sid), &right, row, .undo)) res.confirm = self.askDiscardAll(s);
                },
                .merge => if (self.smallButton(ui, Ui.id("git.stage_all", sid), &right, row, .plus)) {
                    self.intent = .stage_all;
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
            self.drawRow(ui, panel, s, section, e, i, y, res);
        }
    }

    fn drawRow(self: *View, ui: *Ui, panel: Rect, s: *const status.Snapshot, section: Section, e: status.Entry, i: usize, y: *f32, res: *Result) void {
        const dl = ui.dl;
        const clip = dl.currentClip();
        const row: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
        y.* += row_h;
        if (row.bottom() <= clip.y or row.y >= clip.bottom()) return;
        const key = i * 4 + @backingInt(section);
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
                    self.intent = .{ .unstage = e.path };
                },
                .changes => {
                    if (self.smallButton(ui, Ui.id("git.stage", key), &right, row, .plus)) self.intent = .{ .stage = e.path };
                    if (self.smallButton(ui, Ui.id("git.discard", key), &right, row, .undo)) res.confirm = self.askDiscard(e);
                },
                .merge => if (self.smallButton(ui, Ui.id("git.stage", key), &right, row, .plus)) {
                    self.intent = .{ .stage = e.path };
                },
            }
        }
        const st = ui.button(Ui.id("git.row", key), row);
        ui.feedback(row, 6, st);

        // The name, then where it is.
        const name = status.baseName(e.path);
        const dir = status.dirName(e.path);
        var lx = row.x + 28;
        const name_color = if (letter == 'D') theme.text_3 else theme.text;
        const nw = dl.textEllipsis(theme.font_side, lx, row.centerY(), name, @max(0, right - lx), name_color);
        lx += nw + 8;
        if (!std.mem.eql(u8, dir, ".") and lx < right) _ = dl.textEllipsis(theme.font_hint, lx, row.centerY(), dir, right - lx, theme.text_3);

        // A folder git lists as one row (all of it new) has no two sides.
        if (st.clicked and !e.is_dir and s.isRepo()) {
            self.out_path.clearRetainingCapacity();
            self.out_path.appendSlice(self.gpa, s.root) catch return;
            self.out_path.append(self.gpa, '/') catch return;
            self.out_path.appendSlice(self.gpa, e.path) catch return;
            res.open_diff = .{ .path = self.out_path.items, .staged = section == .staged, .orig = if (section == .staged) e.orig else null };
        }
    }

    /// An icon button with a count beside it (push: commits ahead, pull:
    /// behind); dim and inert when `enabled` is false. Moves `right` past it.
    fn countButton(_: *View, ui: *Ui, wid: u64, right: *f32, row: Rect, icon: icons.Icon, count: u32, enabled: bool) bool {
        var buf: [16]u8 = undefined;
        const n: []const u8 = if (count > 0) std.fmt.bufPrint(&buf, "{d}", .{count}) catch "" else "";
        const nw: f32 = if (n.len > 0) ui.text.measure(font_badge, n) + 2 else 0;
        const r: Rect = .{ .x = right.* - small - nw, .y = row.centerY() - small / 2, .w = small + nw, .h = small };
        var clicked = false;
        var color = theme.text_3.alpha(0.5);
        if (enabled) {
            const st = ui.button(wid, r);
            ui.feedback(r, 6, st);
            color = if (st.hover) theme.text else theme.text_3;
            clicked = st.clicked;
        }
        ui.dl.icon(icon, r.x + 4, r.y + 4, 14, color);
        if (n.len > 0) _ = dl_text(ui, r.x + small - 1, r.centerY(), n, if (enabled) theme.accent else color);
        right.* = r.x - 2;
        return clicked;
    }

    /// A 22pt icon button at the right end of a row; moves `right` past it.
    fn smallButton(_: *View, ui: *Ui, wid: u64, right: *f32, row: Rect, icon: icons.Icon) bool {
        const r: Rect = .{ .x = right.* - small, .y = row.centerY() - small / 2, .w = small, .h = small };
        const st = ui.button(wid, r);
        ui.feedback(r, 6, st);
        ui.dl.icon(icon, r.x + 4, r.y + 4, 14, if (st.hover) theme.text else theme.text_3);
        right.* = r.x - 2;
        return st.clicked;
    }
};

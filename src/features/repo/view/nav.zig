//! The repository tab's own navigation, down its left side: the views of
//! the workspace (Changes, History, Pull Requests, Stashes) with their
//! counts, then the branches (the one checked out ticked, "+" for a new
//! one), the remotes and the newest tags. A click on a view shows it; a
//! double click on a branch checks it out.
//!
//! The network's three verbs sit on the rows they are about: Pull and
//! Push on the branch checked out (each with how many commits it would
//! move), Fetch on each remote. What is under way ("Pulling…") and what
//! the last command that failed said show at the foot of the column.
//! Nothing is run here: what was asked for comes out of `takeIntent`.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const wrap = @import("../../../ui/wrap.zig");
const icons = @import("../../../gfx/icons.zig");
const status = @import("../model/status.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const width: f32 = 210;
const pad: f32 = 10;
const item_h: f32 = 30;
const branch_h: f32 = 27;
const head_h: f32 = 26;
const gap: f32 = 14;

pub const Section = enum { changes, history, pulls, stashes };

pub const State = struct {
    snapshot: *const status.Snapshot,
    section: Section,
    tags: []const []const u8,
    stashes: usize,
    /// How many pull requests are open, when a hosting account says.
    pulls: ?usize = null,
    /// A command is running: Fetch, Pull and Push wait.
    busy: bool = false,
    /// What it is called meanwhile ("Pulling…"), and what the last one
    /// that failed said: shown at the foot of the column.
    cmd_label: []const u8 = "",
    last_error: []const u8 = "",
};

pub const Intent = union(enum) {
    show: Section,
    /// A local branch, or a remote one (`origin/x`) to check out as local.
    switch_branch: []const u8,
    switch_remote: []const u8,
    new_branch: []const u8,
    /// The branch checked out: bring its upstream's commits in, send its own.
    pull,
    push,
    /// One remote, by name.
    fetch: []const u8,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    intent: ?Intent = null,
    scroll: f32 = 0,
    content_h: f32 = 0,
    /// The field for a new branch's name is open.
    naming: bool = false,
    name: std.ArrayList(u8) = .empty,

    pub const field_name = Ui.id("repo.nav.new_branch", 0);

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.name.deinit(self.gpa);
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    /// ↵ in the name field: asks for the branch and closes the field.
    pub fn submitName(self: *View, focus: *field.Focus) void {
        if (focus.id != field_name) return;
        self.name.clearRetainingCapacity();
        self.name.appendSlice(self.gpa, std.mem.trim(u8, focus.editor.bytes(), " \t")) catch {};
        focus.drop();
        self.naming = false;
        if (self.name.items.len > 0) self.intent = .{ .new_branch = self.name.items };
    }

    pub fn cancelName(self: *View, focus: *field.Focus) void {
        if (focus.id == field_name) focus.drop();
        self.naming = false;
    }

    pub fn draw(self: *View, ui: *Ui, focus: *field.Focus, rect: Rect, state: State) void {
        const dl = ui.dl;
        const s = state.snapshot;
        dl.rect(rect, theme.bg_side);
        dl.rect(.{ .x = rect.right() - 1, .y = rect.y, .w = 1, .h = rect.h }, theme.line);

        // What is under way, or what went wrong, at the foot of the column.
        var list = rect;
        const note: []const u8 = if (state.cmd_label.len > 0) state.cmd_label else state.last_error;
        if (note.len > 0) {
            const failed = state.cmd_label.len == 0;
            const lines: f32 = @floatFromInt(@min(4, @max(1, wrap.wrapCount(ui, kit.font_small, note, rect.w - 2 * pad - 12))));
            const foot_h = lines * 17 + 18;
            const foot: Rect = .{ .x = rect.x, .y = rect.bottom() - foot_h, .w = rect.w - 1, .h = foot_h };
            dl.rect(.{ .x = foot.x, .y = foot.y, .w = foot.w, .h = 1 }, theme.line);
            dl.pushClip(foot);
            _ = wrap.drawWrapped(ui, kit.font_small, note, foot.x + pad + 6, foot.y + 9, foot.w - 2 * pad - 12, 17, if (failed) theme.red else theme.text_3);
            dl.popClip();
            list.h = @max(0, rect.h - foot_h);
        }
        const max_scroll = @max(0, self.content_h - list.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(list), 0, max_scroll);
        dl.pushClip(list);
        defer dl.popClip();
        const x = rect.x + pad;
        const w = rect.w - 2 * pad;
        var y = rect.y + 14 - self.scroll;
        const top = y;

        _ = kit.label(ui, x + 6, y + head_h / 2, "WORKSPACE");
        y += head_h;
        const changes = s.staged_count + s.unstaged_count + s.conflict_count;
        self.viewItem(ui, .{ .x = x, .y = y, .w = w, .h = item_h }, .changes, "Changes", .document, changes, state.section);
        y += item_h + 2;
        self.viewItem(ui, .{ .x = x, .y = y, .w = w, .h = item_h }, .history, "History", .history, 0, state.section);
        y += item_h + 2;
        self.viewItem(ui, .{ .x = x, .y = y, .w = w, .h = item_h }, .pulls, "Pull Requests", .pull_request, state.pulls orelse 0, state.section);
        y += item_h + 2;
        self.viewItem(ui, .{ .x = x, .y = y, .w = w, .h = item_h }, .stashes, "Stashes", .stash, state.stashes, state.section);
        y += item_h + gap;

        // Branches, with "+" for a new one.
        {
            _ = kit.label(ui, x + 6, y + head_h / 2, "BRANCHES");
            const br: Rect = .{ .x = x + w - 24, .y = y + (head_h - 22) / 2, .w = 22, .h = 22 };
            if (s.isRepo() and !s.unborn) {
                const st = ui.button(Ui.id("repo.nav.plus", 0), br);
                ui.feedback(br, 6, st);
                dl.icon(.plus, br.x + 4, br.y + 4, 14, if (st.hover) theme.text else theme.text_3);
                if (st.clicked) {
                    self.naming = true;
                    focus.take(field_name, "", ui.now);
                }
            }
            y += head_h;
        }
        if (self.naming) {
            const fr: Rect = .{ .x = x, .y = y, .w = w, .h = field.height };
            _ = field.draw(ui, focus, field_name, fr, "", .{ .placeholder = "New branch name", .font = kit.font_mono });
            // A press anywhere else closes it without making a branch.
            if (ui.pressed and !ui.mouseIn(fr)) self.cancelName(focus);
            y += field.height + 6;
        }
        for (s.branches.items, 0..) |b, i| {
            const row: Rect = .{ .x = x, .y = y, .w = w, .h = branch_h };
            y += branch_h;
            if (row.bottom() < rect.y or row.y > rect.bottom()) continue;
            const current = std.mem.eql(u8, b, s.branch) and !s.detached;
            var right = row.right() - 4;
            // Push and Pull for the branch checked out. They come before
            // the row's own button: whoever is registered first takes the press.
            if (current) {
                if (rowButton(ui, Ui.id("repo.nav.push", 0), &right, row, .push, s.ahead, !state.busy and !s.unborn)) self.intent = .push;
                if (rowButton(ui, Ui.id("repo.nav.pull", 0), &right, row, .pull, s.behind, !state.busy and s.upstream.len > 0)) self.intent = .pull;
                right -= 2;
            }
            const st = ui.button(Ui.id("repo.nav.branch", i), row);
            ui.feedback(row, 8, st);
            dl.icon(if (current) .check else .branch, row.x + 8, row.centerY() - 7, 14, if (current) theme.accent else theme.text_3);
            _ = dl.textEllipsis(if (current) ui_mod.Font.monoSemibold(12) else kit.font_mono, row.x + 30, row.centerY(), b, @max(0, right - row.x - 30), if (current) theme.text else theme.text_2);
            if (st.double_clicked and !current) self.intent = .{ .switch_branch = b };
        }
        if (s.detached) {
            const row: Rect = .{ .x = x, .y = y, .w = w, .h = branch_h };
            y += branch_h;
            dl.icon(.check, row.x + 8, row.centerY() - 7, 14, theme.accent);
            _ = dl.textEllipsis(kit.font_small, row.x + 30, row.centerY(), "detached HEAD", row.w - 38, theme.text_2);
        }
        if (s.branches.items.len == 0 and !s.detached) {
            _ = dl.textEllipsis(kit.font_small, x + 8, y + branch_h / 2, if (s.isRepo()) "No commits yet" else "Not a git repository", w - 16, theme.text_3);
            y += branch_h;
        }
        y += gap;

        // Remote-tracking branches with no local one, under their remote.
        if (s.remote_names.items.len > 0) {
            _ = kit.label(ui, x + 6, y + head_h / 2, "REMOTES");
            y += head_h;
            for (s.remote_names.items) |remote| {
                const row: Rect = .{ .x = x, .y = y, .w = w, .h = branch_h };
                y += branch_h;
                dl.icon(.cloud, row.x + 8, row.centerY() - 7, 14, theme.text_3);
                var remote_right = row.right() - 4;
                if (rowButton(ui, Ui.id("repo.nav.fetch", std.hash.Wyhash.hash(0, remote) % 4096), &remote_right, row, .reload, 0, !state.busy)) self.intent = .{ .fetch = remote };
                _ = dl.textEllipsis(kit.font_text, row.x + 30, row.centerY(), remote, @max(0, remote_right - 4 - (row.x + 30)), theme.text_2);
                for (s.remotes.items, 0..) |r, i| {
                    if (!std.mem.startsWith(u8, r, remote) or r.len <= remote.len or r[remote.len] != '/') continue;
                    const short = r[remote.len + 1 ..];
                    if (s.hasBranch(short)) continue;
                    const sub: Rect = .{ .x = x, .y = y, .w = w, .h = branch_h };
                    y += branch_h;
                    if (sub.bottom() < rect.y or sub.y > rect.bottom()) continue;
                    const st = ui.button(Ui.id("repo.nav.remote", i), sub);
                    ui.feedback(sub, 8, st);
                    _ = dl.textEllipsis(kit.font_mono, sub.x + 30, sub.centerY(), short, sub.w - 38, theme.text_3);
                    if (st.double_clicked) self.intent = .{ .switch_remote = r };
                }
            }
            y += gap;
        }

        if (state.tags.len > 0) {
            _ = kit.label(ui, x + 6, y + head_h / 2, "TAGS");
            y += head_h;
            for (state.tags) |tag| {
                const row: Rect = .{ .x = x, .y = y, .w = w, .h = branch_h };
                y += branch_h;
                if (row.bottom() < rect.y or row.y > rect.bottom()) continue;
                dl.icon(.tag, row.x + 8, row.centerY() - 7, 14, theme.text_3);
                _ = dl.textEllipsis(kit.font_mono, row.x + 30, row.centerY(), tag, row.w - 38, theme.text_2);
            }
            y += gap;
        }

        self.content_h = (y - top) + 14;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, list, self.scroll, self.content_h);
    }

    fn viewItem(self: *View, ui: *Ui, row: Rect, which: Section, text: []const u8, icon: icons.Icon, count: usize, shown: Section) void {
        const dl = ui.dl;
        const active = which == shown;
        const st = ui.button(Ui.id("repo.nav.view", @backingInt(which)), row);
        if (active) dl.rrect(row, 8, theme.accent.alpha(0.16)) else ui.feedback(row, 8, st);
        dl.icon(icon, row.x + 8, row.centerY() - 8, 16, if (active) theme.accent else theme.text_3);
        var right = row.right() - 8;
        if (count > 0) right -= kit.countPill(ui, right, row.centerY(), count) + 6;
        _ = dl.textEllipsis(if (active) kit.font_text_bold else kit.font_text, row.x + 32, row.centerY(), text, @max(0, right - row.x - 32), if (active) theme.text else theme.text_2);
        if (st.clicked and !active) self.intent = .{ .show = which };
    }
};

/// A small icon button at the right end of a row, with a count beside
/// the icon when there is one (commits to push, to pull); dim and inert
/// when `enabled` is false. Moves `right` past it. True when clicked.
fn rowButton(ui: *Ui, wid: u64, right: *f32, row: Rect, icon: icons.Icon, count: u32, enabled: bool) bool {
    const size: f32 = 22;
    var buf: [16]u8 = undefined;
    const n: []const u8 = if (count > 0) std.fmt.bufPrint(&buf, "{d}", .{count}) catch "" else "";
    const nw: f32 = if (n.len > 0) ui.text.measure(kit.font_chip, n) + 3 else 0;
    const r: Rect = .{ .x = right.* - size - nw, .y = row.centerY() - size / 2, .w = size + nw, .h = size };
    right.* = r.x - 2;
    var clicked = false;
    var color = theme.text_3.alpha(0.45);
    if (enabled) {
        const st = ui.button(wid, r);
        ui.feedback(r, 6, st);
        // Something to move: the accent says so.
        color = if (st.hover) theme.text else if (count > 0) theme.accent else theme.text_3;
        clicked = st.clicked;
    }
    ui.dl.icon(icon, r.x + 4, r.y + 4, 14, color);
    if (n.len > 0) _ = ui.dl.textCentered(kit.font_chip, r.x + size - 2, r.centerY(), n, color);
    return clicked;
}

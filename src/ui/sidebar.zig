//! Sidebar: the user's projects and nothing else, as one tree under the
//! header (whose "+" adds a folder). A project is a folder with tabs of its
//! own; under it sit its *resources* — groups of shells and files worth
//! keeping at hand — each with its own set of tabs, and the row whose tabs
//! are in the strip is the shown one. First in the tree, drawn like any
//! project, is the *default project*: the tabs (and resources) that belong
//! to no folder. Projects and resources can carry an icon of the user's
//! choosing (a symbol or a coloured dot, `icon_spec.zig`). The chrome is
//! live: rows select, projects fold, the edge drags to resize and the whole
//! thing collapses to an icon rail. Rows carry no buttons apart from a
//! project's "new tab" terminal on hover: new shell groups, removing,
//! renaming and the icon live in the context menu a right-click asks for
//! (`Result.menu`; the app opens it, see `overlay.zig`). While the Settings
//! tab is in front the same sidebar is that tab's navigation menu instead.
const std = @import("std");
const DrawList = @import("../gfx/draw.zig").DrawList;
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const icons = @import("../gfx/icons.zig");
const projects_mod = @import("../projects.zig");
const tab_mod = @import("../tabs/tab.zig");
const settings_mod = @import("../tabs/settings_tab.zig");
const icon_spec = @import("icon_spec.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Project = projects_mod.Project;
const Resource = projects_mod.Resource;

pub const Chrome = struct {
    /// Right edge of the window's traffic lights (0 in full screen).
    inset_left: f32 = 0,
    /// Draw stand-in traffic lights (headless snapshots only).
    fake_lights: bool = false,
    window_focused: bool = true,
};

/// What the sidebar needs to know about the rest of the app while drawing.
pub const Context = struct {
    projects: *projects_mod.Projects,
    /// Its group on show is the selected resource; groups give the counts.
    tabs: *tab_mod.TabManager,
    /// Project whose folder contains the current shell's directory.
    current_project: ?u32 = null,
    /// A file from the files panel is being dragged: the rows take it
    /// (it is pinned to the project it lands on, see `Result.drop_file`).
    dragging_file: bool = false,

    /// The Settings tab, when it is the one in front.
    fn settings(self: Context) ?*settings_mod.SettingsTab {
        const t = self.tabs.current() orelse return null;
        return settings_mod.SettingsTab.fromTab(t);
    }
};

pub const MenuTarget = enum { project, default_project, resource };

/// A secondary click on a row: which one and where its menu should open.
pub const MenuRequest = struct { target: MenuTarget, id: u32, x: f32, y: f32 };

/// Where a dragged file was let go: on a project's row or one of its
/// resources' (`gid`, 0 for the default project), or on the sidebar with
/// no row under the pointer (null: the app picks the selected project).
pub const FileDrop = struct { gid: ?u32 };

/// Everything the user asked for this frame; the app carries it out.
pub const Result = struct {
    add_project: bool = false,
    select_project: ?u32 = null,
    /// Group id (a project's or the default project's): its tabs in the
    /// strip (a shell in its folder if it has none).
    open_group: ?u32 = null,
    /// Group id (a row's hover terminal): one more shell among its tabs.
    new_tab_in: ?u32 = null,
    /// Resource id: its tabs in the strip (opening the file / a shell if it has none).
    open_resource: ?u32 = null,
    /// Right-click on a row: the app opens its context menu.
    menu: ?MenuRequest = null,
    /// A file dragged from the files panel was let go here.
    drop_file: ?FileDrop = null,
    /// A project folded or unfolded (worth persisting).
    changed: bool = false,
};

pub const Sidebar = struct {
    width: f32 = theme.sidebar_default_w,
    collapsed: bool = false,
    /// Whether the default project's resources are listed (not persisted).
    default_open: bool = true,
    scroll: f32 = 0,
    content_h: f32 = 0,
    drag_dx: f32 = 0,

    pub fn currentWidth(self: *const Sidebar) f32 {
        return if (self.collapsed) theme.sidebar_rail_w else self.width;
    }

    pub fn toggle(self: *Sidebar) void {
        self.collapsed = !self.collapsed;
    }

    pub fn draw(self: *Sidebar, ui: *Ui, height: f32, chrome: Chrome, ctx: Context) Result {
        var res: Result = .{};
        // The splitter is handled first so it wins over the rows beneath it.
        const edge = self.currentWidth();
        const grip: Rect = .{ .x = edge - 4, .y = theme.header_h, .w = 8, .h = height - theme.header_h };
        const d = ui.drag(Ui.id("sidebar.split", 0), grip);
        if (d.started) self.drag_dx = edge - ui.mx;
        if (d.double_clicked) {
            self.collapsed = false;
            self.width = theme.sidebar_default_w;
        } else if (d.dragging) {
            const want = ui.mx + self.drag_dx;
            if (want < 132) {
                self.collapsed = true;
            } else {
                self.collapsed = false;
                self.width = std.math.clamp(want, theme.sidebar_min_w, theme.sidebar_max_w);
            }
        }
        if (d.hover or d.dragging) ui.cursor = .resize_lr;

        if (self.collapsed) self.drawRail(ui, height, ctx) else self.drawFull(ui, height, chrome, ctx, &res);
        // A file let go over the sidebar but not over a row still lands
        // (on the selected project); the rail takes it the same way.
        if (ctx.dragging_file and ui.released and res.drop_file == null) {
            const mine: Rect = .{ .x = 0, .y = theme.header_h, .w = self.currentWidth(), .h = height - theme.header_h };
            if (ui.mouseIn(mine)) res.drop_file = .{ .gid = null };
        }

        if (d.hover or d.dragging) {
            const w = self.currentWidth();
            ui.dl.rect(.{ .x = w - 2, .y = theme.header_h, .w = 2, .h = height - theme.header_h }, theme.accent.alpha(if (d.dragging) 0.9 else 0.55));
        }
        return res;
    }

    // ── expanded ────────────────────────────────────────────────────────
    fn drawFull(self: *Sidebar, ui: *Ui, height: f32, chrome: Chrome, ctx: Context, res: *Result) void {
        const dl = ui.dl;
        const w = self.width;
        dl.rect(.{ .x = 0, .y = 0, .w = w, .h = height }, theme.bg_side);
        dl.rect(.{ .x = w - 1, .y = 0, .w = 1, .h = height }, theme.line);
        dl.pushClip(.{ .x = 0, .y = 0, .w = w - 1, .h = height });
        defer dl.popClip();

        // Header: brand + collapse button.
        const brand_x = @max(18, chrome.inset_left + 14);
        _ = dl.textCentered(theme.font_brand, brand_x, theme.header_h / 2, "tt", theme.accent);
        const toggle_r: Rect = .{ .x = w - 10 - 36, .y = 8, .w = 36, .h = 36 };
        const tb = ui.button(Ui.id("sidebar.toggle", 0), toggle_r);
        ui.feedback(toggle_r, 8, tb);
        dl.icon(.sidebar, toggle_r.x + 9, toggle_r.y + 9, 18, theme.text_2);
        if (tb.clicked) self.collapsed = true;

        if (ctx.settings()) |s| return drawSettingsMenu(ui, w, s);

        // "+": add a folder as a project.
        const plus_r: Rect = .{ .x = toggle_r.x - 4 - 36, .y = 8, .w = 36, .h = 36 };
        const pb = ui.button(Ui.id("sidebar.add", 0), plus_r);
        ui.feedback(plus_r, 8, pb);
        dl.icon(.plus, plus_r.x + 9, plus_r.y + 9, 18, if (pb.hover) theme.text else theme.text_2);
        if (pb.clicked) res.add_project = true;

        const y: f32 = theme.header_h;

        // Scrollable: the projects.
        const area: Rect = .{ .x = 0, .y = y, .w = w - 1, .h = height - y };
        const max_scroll = @max(0, self.content_h - area.h);
        const bar = Ui.id("sidebar.vbar", 0);
        if (scrollbarDrag(ui, bar, .vertical, area, self.scroll, self.content_h)) |s| self.scroll = s;
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();

        var cy = y + 10 - self.scroll;
        const top = cy;
        const default_group = tab_mod.TabManager.default_group;
        cy = groupRow(ui, cy, w, ctx, res, .{ .gid = default_group, .name = "Default project", .icon = ctx.projects.default_icon, .open = &self.default_open, .target = .default_project, .id = 0 });
        if (self.default_open) {
            for (ctx.projects.default_resources.items) |*r| cy = resourceRow(ui, cy, w, r, default_group, ctx, res);
        }
        if (ctx.projects.items.items.len == 0) {
            _ = dl.textEllipsis(theme.font_hint, 18, cy + 12, "No projects yet.", w - 36, theme.text_3);
            _ = dl.textEllipsis(theme.font_hint, 18, cy + 32, "Press + to add a folder.", w - 36, theme.text_3);
            cy += 48;
        }
        for (ctx.projects.items.items) |*p| {
            cy = groupRow(ui, cy, w, ctx, res, .{ .gid = p.id, .name = p.name, .icon = p.icon, .open = &p.open, .current = ctx.current_project == p.id, .target = .project, .id = p.id });
            if (p.open) {
                for (p.resources.items) |*r| cy = resourceRow(ui, cy, w, r, p.id, ctx, res);
            }
        }
        self.content_h = (cy - top) + 20;

        if (max_scroll > 0) drawScrollbarAxis(ui, bar, .vertical, area, self.scroll, self.content_h);
    }

    /// A small icon button that only shows while its row is hovered.
    fn hoverButton(ui: *Ui, wid: u64, right: f32, cy: f32, icon: icons.Icon, size: f32) ui_mod.ButtonState {
        const r: Rect = .{ .x = right - 24, .y = cy - 12, .w = 24, .h = 24 };
        const st = ui.button(wid, r);
        ui.feedback(r, 6, st);
        ui.dl.icon(icon, r.x + (24 - size) / 2, r.y + (24 - size) / 2, size, if (st.hover) theme.text else theme.text_3);
        return st;
    }

    /// What a project-style row stands for: the default project or a real one.
    const RowSpec = struct {
        /// The tab group listed under the row.
        gid: u32,
        name: []const u8,
        icon: ?[]const u8,
        open: *bool,
        /// The folder contains the current shell's directory.
        current: bool = false,
        target: MenuTarget,
        id: u32,
    };

    /// A project row: fold chevron (its own target), icon, name and how
    /// many tabs of its own it holds. Clicking the row shows those tabs,
    /// its hover terminal opens one more shell among them; everything else
    /// (new shell groups, rename, icon, remove) is in the context menu.
    /// Returns the y under the row.
    fn groupRow(ui: *Ui, y: f32, w: f32, ctx: Context, res: *Result, spec: RowSpec) f32 {
        const dl = ui.dl;
        const r: Rect = .{ .x = 8, .y = y, .w = w - 16, .h = 32 };
        const hovered = ui.mouseIn(r);
        var right = r.right() - 6;
        var shell_st: ui_mod.ButtonState = .{};
        if (hovered) {
            shell_st = hoverButton(ui, Ui.id("sidebar.group.shell", spec.gid), right, r.centerY(), .terminal, 15);
            right -= 26;
        }
        const chev: Rect = .{ .x = r.x, .y = r.y, .w = 24, .h = r.h };
        const cs = ui.button(Ui.id("sidebar.group.fold", spec.gid), chev);
        const st = ui.button(Ui.id("sidebar.group", spec.gid), r);
        if (ui.rightClicked(r)) res.menu = .{ .target = spec.target, .id = spec.id, .x = ui.mx, .y = ui.my };
        const shown = ctx.tabs.groupId() == spec.gid;
        if (shown) dl.rrect(r, 8, theme.accent.alpha(0.14)) else ui.feedback(r, 8, st);
        if (dropTarget(ui, ctx, r)) res.drop_file = .{ .gid = spec.gid };
        if (spec.current) dl.rrect(.{ .x = r.x + 2, .y = r.centerY() - 8, .w = 3, .h = 16 }, 1.5, theme.accent);
        _ = dl.textCentered(theme.font_section, r.x + 10, r.centerY(), if (spec.open.*) "▾" else "▸", if (cs.hover) theme.text else theme.text_3);
        const color = if (shown or spec.current or hovered) theme.text else theme.text_2;
        const lx = drawRowIcon(dl, spec.icon, r.x + 28, r.centerY(), color);
        if (!hovered) right = tabsBadge(ui, ctx, spec.gid, 1, lx, right, r.centerY());
        _ = dl.textEllipsis(theme.font_side_medium, lx, r.centerY(), spec.name, right - 4 - lx, color);

        if (shell_st.clicked) {
            res.new_tab_in = spec.gid;
        } else if (cs.clicked) {
            spec.open.* = !spec.open.*;
            if (spec.target == .project) {
                res.changed = true;
                res.select_project = spec.id;
            }
        } else if (st.clicked) res.open_group = spec.gid;
        return y + 32 + 2;
    }

    /// While a file is being dragged, the row under the pointer shows it
    /// would take it; true on the frame the file is let go over it.
    fn dropTarget(ui: *Ui, ctx: Context, r: Rect) bool {
        if (!ctx.dragging_file or !ui.mouseIn(r)) return false;
        ui.dl.rrect(r, 8, theme.accent.alpha(0.12));
        ui.dl.border(r, 8, 1, theme.accent.alpha(0.7));
        return ui.released;
    }

    /// A project's or resource's own icon at `x` (14pt, centred on `cy`),
    /// when it has one; returns where the label starts.
    fn drawRowIcon(dl: *DrawList, icon: ?[]const u8, x: f32, cy: f32, color: Color) f32 {
        const spec = icon_spec.parse(icon) orelse return x;
        icon_spec.drawSpec(dl, spec, x, cy, 14, color);
        return x + 14 + 8;
    }

    /// A resource under its project: a group of shells or a file, with its
    /// own set of tabs. Selected while those are in the strip; a click
    /// shows them, a right-click asks for its menu (rename, icon, remove).
    fn resourceRow(ui: *Ui, y: f32, w: f32, r: *Resource, owner: u32, ctx: Context, res: *Result) f32 {
        const dl = ui.dl;
        const row: Rect = .{ .x = 8, .y = y, .w = w - 16, .h = 30 };
        // No buttons: a new tab comes from the strip (or ⌘T) while the
        // resource is on show.
        const st = ui.button(Ui.id("sidebar.res", r.id), row);
        if (ui.rightClicked(row)) res.menu = .{ .target = .resource, .id = r.id, .x = ui.mx, .y = ui.my };
        const selected = ctx.tabs.groupId() == r.id;
        if (selected) dl.rrect(row, 8, theme.accent.alpha(0.14)) else ui.feedback(row, 8, st);
        // A file dropped on a resource joins the resource's project.
        if (dropTarget(ui, ctx, row)) res.drop_file = .{ .gid = owner };

        // The user's icon, else the kind's.
        const ix = row.x + 30;
        const icon_color = if (selected) theme.text else theme.text_3;
        if (icon_spec.parse(r.icon)) |spec| {
            icon_spec.drawSpec(dl, spec, ix, row.centerY(), 14, icon_color);
        } else dl.icon(if (r.kind == .file) .file else .terminal, ix, row.centerY() - 7, 14, icon_color);
        const lx = ix + 14 + 8;
        // Tab count: a group's shells; for a file only once it has more than its viewer.
        const right = tabsBadge(ui, ctx, r.id, if (r.kind == .shells) 1 else 2, lx, row.right() - 6, row.centerY());
        _ = dl.textEllipsis(theme.font_side, lx, row.centerY(), r.name, right - 4 - lx, if (selected or st.hover) theme.text else theme.text_2);

        if (st.clicked) res.open_resource = r.id;
        return y + 30 + 2;
    }

    /// A group's tab count ("3 tabs") and a dot while one of them runs,
    /// right-aligned at `right` when the row has room for it next to a
    /// label starting at `lx`. Nothing below `min_live` tabs. Returns where
    /// the label must stop.
    fn tabsBadge(ui: *Ui, ctx: Context, gid: u32, min_live: usize, lx: f32, right_in: f32, cy: f32) f32 {
        const dl = ui.dl;
        var right = right_in;
        const g = ctx.tabs.findGroup(gid) orelse return right;
        const live = g.count();
        if (live < min_live) return right;
        var running = false;
        for (g.layout.owned.items) |pane| {
            for (pane.tabs.items) |t| {
                if (t.vtable.status(t.ptr) == .running) running = true;
            }
        }
        var buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d} {s}", .{ live, if (live == 1) "tab" else "tabs" }) catch "";
        const bw = ui.text.measure(theme.font_status, label);
        if (right - bw - 8 - lx < 72) return right;
        _ = dl.textCentered(theme.font_status, right - bw - 4, cy, label, theme.text_3);
        right -= bw + 12;
        if (running) {
            dl.circle(right - 3.5, cy, 3.5, theme.teal);
            right -= 14;
        }
        return right;
    }

    // ── settings menu ───────────────────────────────────────────────────
    /// The Settings tab's table of contents: its sections as headers, one
    /// row per page, the selected page highlighted like a selected resource.
    /// Pages without content yet carry a "Soon" tag.
    fn drawSettingsMenu(ui: *Ui, w: f32, s: *settings_mod.SettingsTab) void {
        const dl = ui.dl;
        var y: f32 = theme.header_h;

        // Title where the project row usually sits.
        {
            const r: Rect = .{ .x = 8, .y = y, .w = w - 16, .h = 36 };
            dl.icon(.settings, r.x + 10, r.y + 9.5, 17, theme.text_2);
            const lx = r.x + 10 + 17 + 10;
            _ = dl.textEllipsis(theme.font_ui_medium, lx, r.centerY(), "Settings", r.right() - 10 - lx, theme.text);
            y += 36 + 10;
        }
        dl.rect(.{ .x = 0, .y = y, .w = w, .h = 1 }, theme.line);
        y += 1 + 10;

        for (settings_mod.sections) |sec| {
            const head: Rect = .{ .x = 8, .y = y, .w = w - 16, .h = 32 };
            _ = dl.textEllipsis(theme.font_section, head.x + 10, head.centerY(), sec.title, head.w - 20, theme.text_3);
            y += 32 + 2;
            for (sec.pages) |page| {
                const row: Rect = .{ .x = 8, .y = y, .w = w - 16, .h = 30 };
                const st = ui.button(Ui.id("sidebar.settings.page", @intFromEnum(page)), row);
                const selected = s.page == page;
                if (selected) dl.rrect(row, 8, theme.accent.alpha(0.14)) else ui.feedback(row, 8, st);

                const ix = row.x + 14;
                dl.icon(page.icon(), ix, row.centerY() - 7, 14, if (selected) theme.text else theme.text_3);
                const lx = ix + 14 + 8;
                var right = row.right() - 10;
                if (!page.ready() and right - lx > 110) right = settings_mod.drawSoonPill(ui, right, row.centerY()) - 8;
                _ = dl.textEllipsis(theme.font_side, lx, row.centerY(), page.label(), right - 4 - lx, if (selected or st.hover) theme.text else theme.text_2);
                if (st.clicked) s.page = page;
                y += 30 + 2;
            }
            y += 8;
        }
    }

    // ── collapsed rail ──────────────────────────────────────────────────
    fn drawRail(self: *Sidebar, ui: *Ui, height: f32, ctx: Context) void {
        const dl = ui.dl;
        const w = theme.sidebar_rail_w;
        dl.rect(.{ .x = 0, .y = theme.header_h, .w = w, .h = height - theme.header_h }, theme.bg_side);
        dl.rect(.{ .x = w - 1, .y = theme.header_h, .w = 1, .h = height - theme.header_h }, theme.line);

        if (ctx.settings()) |s| return self.drawSettingsRail(ui, s);

        // Just the expand button and the projects folder: both open the sidebar.
        const Entry = struct { icon: icons.Icon, divider_before: bool = false };
        const entries = [_]Entry{
            .{ .icon = .sidebar },
            .{ .icon = .folder, .divider_before = true },
        };
        var y: f32 = theme.header_h + 8;
        for (entries, 0..) |e, i| {
            if (e.divider_before) {
                dl.rect(.{ .x = (w - 28) / 2, .y = y + 6, .w = 28, .h = 1 }, theme.line);
                y += 13 + 4;
            }
            const r: Rect = .{ .x = (w - 44) / 2, .y = y, .w = 44, .h = 44 };
            const st = ui.button(Ui.id("sidebar.rail", i), r);
            ui.feedback(r, 8, st);
            dl.icon(e.icon, r.x + 13, r.y + 13, 18, theme.text_2);
            if (st.clicked) self.collapsed = false;
            y += 44 + 4;
        }
    }

    /// The menu folded to icons: the expand button, then one icon per page.
    fn drawSettingsRail(self: *Sidebar, ui: *Ui, s: *settings_mod.SettingsTab) void {
        const dl = ui.dl;
        const w = theme.sidebar_rail_w;
        var y: f32 = theme.header_h + 8;
        {
            const r: Rect = .{ .x = (w - 44) / 2, .y = y, .w = 44, .h = 44 };
            const st = ui.button(Ui.id("sidebar.rail", 0), r);
            ui.feedback(r, 8, st);
            dl.icon(.sidebar, r.x + 13, r.y + 13, 18, theme.text_2);
            if (st.clicked) self.collapsed = false;
            y += 44 + 4;
        }
        dl.rect(.{ .x = (w - 28) / 2, .y = y + 6, .w = 28, .h = 1 }, theme.line);
        y += 13 + 4;
        for (settings_mod.sections) |sec| {
            for (sec.pages) |page| {
                const r: Rect = .{ .x = (w - 44) / 2, .y = y, .w = 44, .h = 44 };
                const st = ui.button(Ui.id("sidebar.settings.rail", @intFromEnum(page)), r);
                const selected = s.page == page;
                if (selected) dl.rrect(r, 8, theme.accent.alpha(0.14)) else ui.feedback(r, 8, st);
                dl.icon(page.icon(), r.x + 13, r.y + 13, 18, if (selected) theme.text else theme.text_2);
                if (st.clicked) s.page = page;
                y += 44 + 4;
            }
        }
    }
};

// ── scrollbars ──────────────────────────────────────────────────────────
// A thin thumb along the right (vertical) or bottom (horizontal) edge of a
// scrolling area. The thumb drags, and a press on the track jumps there. A
// view calls `scrollbarDrag` before its own mouse handling, so a press on
// the bar never reaches the content, and `drawScrollbarAxis` last, so the
// thumb is on top of it.

pub const Axis = enum { vertical, horizontal };

/// Points along the edge that take the mouse; the thumb itself is thinner.
const bar_grip: f32 = 14;
const bar_min_thumb: f32 = 28;

const Thumb = struct { start: f32, len: f32, track_start: f32, track_len: f32, view: f32 };

/// Thumb geometry along `axis`, or null when the content fits.
fn thumbOf(axis: Axis, area: Rect, scroll: f32, content: f32) ?Thumb {
    const view = if (axis == .vertical) area.h else area.w;
    if (content <= view or view <= 0) return null;
    const track_start = (if (axis == .vertical) area.y else area.x) + 4;
    const track_len = view - 8;
    const len = @max(bar_min_thumb, track_len * view / content);
    const t = std.math.clamp(scroll / (content - view), 0, 1);
    return .{ .start = track_start + (track_len - len) * t, .len = len, .track_start = track_start, .track_len = track_len, .view = view };
}

fn gripRect(axis: Axis, area: Rect) Rect {
    return switch (axis) {
        .vertical => .{ .x = area.right() - bar_grip, .y = area.y, .w = bar_grip, .h = area.h },
        .horizontal => .{ .x = area.x, .y = area.bottom() - bar_grip, .w = area.w, .h = bar_grip },
    };
}

/// The mouse half of a scrollbar: dragging the thumb, or pressing the
/// track to jump there. `scroll` is from the top (left); returns the new
/// value while the bar owns the mouse, null otherwise.
pub fn scrollbarDrag(ui: *Ui, wid: u64, axis: Axis, area: Rect, scroll: f32, content: f32) ?f32 {
    const th = thumbOf(axis, area, scroll, content) orelse return null;
    const d = ui.drag(wid, gripRect(axis, area));
    if (!d.started and !d.dragging) return null;
    const m = if (axis == .vertical) ui.my else ui.mx;
    if (d.started) {
        // Grab the thumb where it was hit; a press on the track centres it there.
        ui.drag_grab = if (m >= th.start and m < th.start + th.len) m - th.start else th.len / 2;
    }
    const room = th.track_len - th.len;
    const t = if (room > 0) std.math.clamp((m - ui.drag_grab - th.track_start) / room, 0, 1) else 0;
    return t * (content - th.view);
}

/// The drawing half: the thumb, a little bolder while hovered or dragged.
/// `wid` 0 draws a passive bar (no hover feedback).
pub fn drawScrollbarAxis(ui: *Ui, wid: u64, axis: Axis, area: Rect, scroll: f32, content: f32) void {
    const th = thumbOf(axis, area, scroll, content) orelse return;
    const hot = wid != 0 and (ui.active == wid or (ui.active == 0 and ui.mouseIn(gripRect(axis, area))));
    if (hot) ui.cursor = .arrow;
    const thick: f32 = if (hot) 7 else 4;
    const r: Rect = switch (axis) {
        .vertical => .{ .x = area.right() - 3 - thick, .y = th.start, .w = thick, .h = th.len },
        .horizontal => .{ .x = th.start, .y = area.bottom() - 3 - thick, .w = th.len, .h = thick },
    };
    ui.dl.rrect(r, thick / 2, theme.text.alpha(if (hot) 0.32 else 0.16));
}

/// A vertical scrollbar that only shows where the view is (nothing to drag).
pub fn drawScrollbar(ui: *Ui, area: Rect, scroll_from_top: f32, content_h: f32) void {
    drawScrollbarAxis(ui, 0, .vertical, area, scroll_from_top, content_h);
}

//! Tab strips. With a single pane the strip lives in the titlebar band next
//! to the sidebar header; with split panes every pane has its own — still in
//! the band for the panes along the top, at the top of the pane for the
//! others (`panes.zig` decides). The right cluster (the files toggle) stays
//! at the band's right edge, in front of whatever strip runs under it;
//! Settings has no button, it is ⌘, (and the palette).
//!
//! Tabs have no close button: a right-click opens their menu (close, close
//! others / to the right, rename, copy path, reveal, split; see overlay.zig).
//! Pressing a tab and moving it starts a *drag*: the pane view draws
//! the ghost, and the strip or pane under the mouse says where the tab would
//! land (`Drag.target`). `left_inset` keeps the first tab clear of the
//! traffic lights when the sidebar is collapsed; empty space in the band
//! drags the window (see the platform layer).
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const tab_mod = @import("../tabs/tab.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Pane = tab_mod.Pane;
const Side = tab_mod.Side;

/// A secondary click on a tab: which one and where its menu should open.
pub const MenuRequest = struct { uid: u32, x: f32, y: f32 };

pub const Result = struct {
    activate: ?usize = null,
    /// Right-click (or ⌃-click) on a tab: the app opens its context menu.
    menu: ?MenuRequest = null,
    new_tab: bool = false,
    /// The globe next to "+": a website tab.
    new_web_tab: bool = false,
};

/// The band's right cluster.
pub const Cluster = struct {
    toggle_files: bool = false,
    /// Where strips in the band must stop.
    right: f32,
};

pub const StripOpts = struct {
    /// Space before the first tab.
    left_inset: f32 = 12,
    /// The focused pane's active tab gets the accent underline; other
    /// panes show theirs muted.
    focused: bool = true,
    /// The context line ("~/code · on main") when there is room for it.
    show_info: bool = true,
};

/// Into a pane's content: on a side (a new pane there) or in the middle
/// (the end of that pane's strip). `rect` is what gets highlighted.
pub const Zone = struct { pane: u32, side: ?Side, rect: Rect };

/// Where a dragged tab would land, set each frame by what is under the mouse.
pub const DropTarget = union(enum) {
    /// Into a strip, before tab `index`; the marker is drawn at `x`.
    strip: struct { pane: u32, index: usize, x: f32, y: f32, h: f32 },
    zone: Zone,
};

/// What is on the move: a tab (by its title), or a file the files panel
/// handed over — not a tab yet, it becomes one where it is dropped.
pub const DragKind = enum { tab, file };

/// A tab being dragged by its title (or a file, see `fileDrag`).
pub const Drag = struct {
    kind: DragKind = .tab,
    /// The tab (0 for a file: no tab has that uid).
    uid: u32,
    from_pane: u32,
    title: [tab_mod.TabManager.max_title_len]u8 = undefined,
    title_len: usize = 0,
    /// Where in the tab it was grabbed, and the tab's width, so the ghost
    /// stays under the pointer the way the tab was.
    grab_dx: f32,
    w: f32,
    has_dot: bool,
    target: ?DropTarget = null,

    pub fn titleText(self: *const Drag) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// A drag of a file from the files panel: the ghost shows `name` the way
/// a tab would, and the strips and panes say where it would land.
pub fn fileDrag(ui: *Ui, name: []const u8) Drag {
    var d: Drag = .{ .kind = .file, .uid = 0, .from_pane = 0, .grab_dx = 0, .w = 0, .has_dot = false };
    d.title_len = @min(name.len, d.title.len);
    @memcpy(d.title[0..d.title_len], name[0..d.title_len]);
    d.w = tabWidth(@min(max_title_w, ui.text.measure(theme.font_tab_active, d.titleText())), false);
    d.grab_dx = d.w / 2;
    return d;
}

pub const tab_pad: f32 = 12;
const tab_gap: f32 = 4;
const max_title_w: f32 = 220;
const min_title_w: f32 = 36;
/// The hover pill behind a tab and the ghost that follows a drag.
const pill_h: f32 = 34;
/// Moving this far (points) from the press turns a click into a drag.
const drag_threshold: f32 = 5;

/// The band's bottom line and its right cluster: the files toggle.
pub fn drawCluster(ui: *Ui, band: Rect, files_visible: bool) Cluster {
    const dl = ui.dl;
    dl.rect(.{ .x = band.x, .y = band.bottom() - 1, .w = band.w, .h = 1 }, theme.line);
    var right = band.right() - 16;
    var res: Cluster = .{ .right = right };
    {
        const r: Rect = .{ .x = right - 34, .y = band.y + (band.h - 34) / 2, .w = 34, .h = 34 };
        const st = ui.button(Ui.id("tabbar.files", 0), r);
        ui.feedback(r, 8, st);
        dl.icon(.folder, r.x + 8, r.y + 8, 18, if (files_visible or st.hover) theme.text else theme.text_3);
        if (st.clicked) res.toggle_files = true;
        right = r.x - 12;
    }
    res.right = right;
    return res;
}

/// One pane's strip in `rect`: its tabs, "+", the active tab's own
/// controls and the context line.
pub fn drawStrip(ui: *Ui, rect: Rect, pane: *Pane, opts: StripOpts, drag: *?Drag) Result {
    var res: Result = .{};
    if (rect.w < 40 or rect.h < 20) return res;
    const dl = ui.dl;
    dl.rect(.{ .x = rect.x, .y = rect.bottom() - 1, .w = rect.w, .h = 1 }, theme.line);
    dl.pushClip(rect);
    defer dl.popClip();

    const tabs = pane.tabs.items;
    const left = rect.x + opts.left_inset;
    const right = rect.right() - 12;
    const plus_w: f32 = 17 * 0.6 + 2 * tab_pad;

    // Measure titles; shrink evenly if they do not fit.
    var title_bufs: [64][96]u8 = undefined;
    var titles: [64][]const u8 = undefined;
    var widths: [64]f32 = undefined;
    const count = @min(tabs.len, 64);
    var total: f32 = 0;
    for (0..count) |i| {
        const t = tabs[i];
        titles[i] = t.title(&title_bufs[i]);
        const font = if (i == pane.active) theme.font_tab_active else theme.font_tab;
        widths[i] = @min(max_title_w, ui.text.measure(font, titles[i]));
        total += tabWidth(widths[i], t.vtable.status(t.ptr) != .none) + tab_gap;
    }
    var info_buf: [256]u8 = undefined;
    var info: []const u8 = "";
    if (opts.show_info) {
        if (pane.current()) |cur| info = cur.vtable.info(cur.ptr, &info_buf);
    }
    const info_w = if (info.len > 0) ui.text.measure(theme.font_hint, info) else 0;

    const avail_tabs = right - left - 2 * plus_w;
    if (total > avail_tabs and count > 0) {
        const fixed = total - sum(widths[0..count]);
        const per = @max(min_title_w, (avail_tabs - fixed) / @as(f32, @floatFromInt(count)));
        for (0..count) |i| widths[i] = @min(widths[i], per);
    }

    const pill_y = rect.y + (rect.h - pill_h) / 2;
    var x = left;
    // Where a dragged tab would be inserted: before the first tab whose
    // middle is right of the pointer, else after the last one.
    var insert_at: usize = count;
    var marker_x: f32 = left;
    for (0..count) |i| {
        const t = tabs[i];
        const status = t.vtable.status(t.ptr);
        const tw = tabWidth(widths[i], status != .none);
        const r: Rect = .{ .x = x, .y = rect.y, .w = tw, .h = rect.h };
        const active = i == pane.active;
        const being_dragged = if (drag.*) |d| d.uid == t.uid else false;

        // No close button: closing and renaming live in the tab's context menu.
        const st = ui.button(Ui.id("tabbar.tab", t.uid), r);
        if (ui.rightClicked(r)) res.menu = .{ .uid = t.uid, .x = ui.mx, .y = ui.my };
        // A press that travels becomes a drag; a release before that is a click.
        if (st.held and drag.* == null) {
            const dx = ui.mx - ui.press_x;
            const dy = ui.my - ui.press_y;
            if (dx * dx + dy * dy >= drag_threshold * drag_threshold) {
                var d: Drag = .{
                    .uid = t.uid,
                    .from_pane = pane.id,
                    .grab_dx = std.math.clamp(ui.press_x - r.x, 0, tw),
                    .w = tw,
                    .has_dot = status != .none,
                };
                d.title_len = @min(titles[i].len, d.title.len);
                @memcpy(d.title[0..d.title_len], titles[i][0..d.title_len]);
                drag.* = d;
            }
        }
        if (st.clicked and drag.* == null) res.activate = i;

        const fade: f32 = if (being_dragged) 0.3 else 1;
        if (st.hover and !active and drag.* == null) dl.rrect(.{ .x = r.x, .y = pill_y, .w = r.w, .h = pill_h }, 8, theme.hover);
        var tx = r.x + tab_pad;
        if (status != .none) {
            const c = switch (status) {
                .running => theme.teal,
                .attention => theme.accent,
                .failed => theme.red,
                .none => unreachable,
            };
            dl.circle(tx + 3.5, r.centerY(), 3.5, c.alpha(fade));
            tx += 7 + 8;
        }
        const font = if (active) theme.font_tab_active else theme.font_tab;
        const color = if (active and opts.focused) theme.text else theme.text_2;
        _ = dl.textEllipsis(font, tx, r.centerY(), titles[i], widths[i] + 0.5, color.alpha(fade));
        if (active) {
            const underline = if (opts.focused) theme.accent else theme.accent.alpha(0.35);
            dl.rect(.{ .x = r.x, .y = r.bottom() - 2, .w = r.w, .h = 2 }, underline.alpha(fade));
        }
        if (drag.* != null and insert_at == count and ui.mx < r.x + r.w / 2) {
            insert_at = i;
            marker_x = r.x - tab_gap / 2;
        }
        x += tw + tab_gap;
    }
    if (insert_at == count) marker_x = if (count == 0) left else x - tab_gap / 2;
    if (drag.*) |*d| {
        if (ui.mouseIn(rect)) d.target = .{ .strip = .{ .pane = pane.id, .index = insert_at, .x = marker_x, .y = pill_y + 4, .h = pill_h - 8 } };
    }

    // "+" new tab.
    {
        const r: Rect = .{ .x = x, .y = rect.y, .w = plus_w, .h = rect.h };
        const st = ui.button(Ui.id("tabbar.new", pane.id), r);
        if (st.hover) dl.rrect(.{ .x = r.x, .y = pill_y, .w = r.w, .h = pill_h }, 8, theme.hover);
        dl.icon(.plus, r.x + (r.w - 15) / 2, r.centerY() - 7.5, 15, if (st.hover) theme.text else theme.text_3);
        if (st.clicked) res.new_tab = true;
        x += plus_w;
    }

    // Globe: a website tab.
    {
        const r: Rect = .{ .x = x, .y = rect.y, .w = plus_w, .h = rect.h };
        const st = ui.button(Ui.id("tabbar.web", pane.id), r);
        if (st.hover) dl.rrect(.{ .x = r.x, .y = pill_y, .w = r.w, .h = pill_h }, 8, theme.hover);
        dl.icon(.globe, r.x + (r.w - 15) / 2, r.centerY() - 7.5, 15, if (st.hover) theme.text else theme.text_3);
        if (st.clicked) res.new_web_tab = true;
        x += plus_w;
    }

    // The active tab's own controls take the right end; the context line
    // sits to their left.
    var info_right = right;
    if (pane.current()) |cur| {
        const room: Rect = .{ .x = x + 16, .y = rect.y, .w = @max(0, right - x - 16), .h = rect.h };
        const used = cur.vtable.strip(cur.ptr, ui, room);
        if (used > 0) info_right = right - used - 14;
    }
    if (info.len > 0 and info_right - info_w > x + 16) {
        _ = dl.textCentered(theme.font_hint, info_right - info_w, rect.centerY(), info, theme.text_3);
    } else if (info.len > 0 and info_right - x > 120) {
        _ = dl.textEllipsis(theme.font_hint, x + 16, rect.centerY(), info, info_right - x - 16, theme.text_3);
    }
    return res;
}

/// The insertion bar or the highlighted drop zone, then the tab's ghost
/// under the pointer. Drawn after everything else so nothing covers them.
pub fn drawDrag(ui: *Ui, d: *const Drag) void {
    const dl = ui.dl;
    if (d.target) |target| switch (target) {
        .strip => |s| dl.rrect(.{ .x = s.x - 1, .y = s.y, .w = 2, .h = s.h }, 1, theme.accent),
        .zone => |z| {
            const r = z.rect.inset(3, 3);
            dl.rrect(r, 8, theme.accent.alpha(0.1));
            dl.border(r, 8, 1, theme.accent.alpha(0.55));
        },
    };
    const r: Rect = .{ .x = ui.mx - d.grab_dx, .y = ui.my - pill_h / 2, .w = d.w, .h = pill_h };
    dl.rrect(.{ .x = r.x + 1, .y = r.y + 2, .w = r.w, .h = r.h }, 8, theme.bg.alpha(0.5));
    dl.shape(r, 8, theme.bg_panel, 1, theme.line_strong);
    var tx = r.x + tab_pad;
    var title_w = d.w - 2 * tab_pad;
    if (d.has_dot) {
        dl.circle(tx + 3.5, r.centerY(), 3.5, theme.text_3);
        tx += 15;
        title_w -= 15;
    }
    _ = dl.textEllipsis(theme.font_tab_active, tx, r.centerY(), d.titleText(), @max(0, title_w + 0.5), theme.text);
}

fn tabWidth(title_w: f32, has_dot: bool) f32 {
    return tab_pad * 2 + title_w + (if (has_dot) @as(f32, 15) else 0);
}

fn sum(values: []const f32) f32 {
    var s: f32 = 0;
    for (values) |v| s += v;
    return s;
}

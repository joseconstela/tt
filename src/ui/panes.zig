//! The content area as split panes, VS Code style. Draws the group on show:
//! every pane's tab strip (in the titlebar band for the panes along the top,
//! at the pane's own top otherwise), the active tab of each pane, the
//! dividers between them (drag to resize) and, while a tab is being dragged
//! by its title, the drop hint and the ghost. A press inside a pane focuses
//! it. The tree itself lives in `tabs/layout.zig`; the moves it takes are
//! applied straight to the tab manager, the app only learns that
//! something changed.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const tabbar = @import("tabbar.zig");
const tab_mod = @import("../tabs/tab.zig");
const layout_mod = @import("../tabs/layout.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Side = layout_mod.Side;
const Divider = layout_mod.Divider;

pub const Result = struct {
    /// Right-click on a tab: the app opens its context menu.
    menu: ?tabbar.MenuRequest = null,
    /// "+" in a pane's strip: a new tab in that pane.
    new_tab: ?u32 = null,
    /// The globe next to "+": a website tab in that pane.
    new_web_tab: ?u32 = null,
    toggle_files: bool = false,
    /// Focus, a divider or a tab moved.
    changed: bool = false,
    /// A file dragged from the files panel was let go over a strip or a
    /// pane: where. The app opens it there.
    file_drop: ?tabbar.DropTarget = null,
};

pub const PaneView = struct {
    /// The tab being dragged by its title, if any.
    drag: ?tabbar.Drag = null,

    /// `band_inset`: where the first strip may start (past the traffic
    /// lights and the sidebar's toggle while the sidebar is collapsed).
    pub fn draw(self: *PaneView, ui: *Ui, tabs: *tab_mod.TabManager, band: Rect, content: Rect, band_inset: f32, files_visible: bool, window_focused: bool) Result {
        const dl = ui.dl;
        var res: Result = .{};
        const cluster = tabbar.drawCluster(ui, band, files_visible);
        res.toggle_files = cluster.toggle_files;

        const g = tabs.group();
        const l = &g.layout;
        if (self.drag) |*d| d.target = null;

        // Dividers first: they own the mouse before anything under them.
        var geo = l.geometry(content, theme.divider_w);
        var divider_held = false;
        for (geo.dividers[0..geo.nd]) |d| {
            const st = ui.drag(dividerId(d), grabRect(d));
            if (st.hover or st.dragging) ui.cursor = if (d.dir == .horizontal) .resize_lr else .resize_ud;
            if (!st.dragging or d.span <= 0) continue;
            divider_held = true;
            const centre = if (d.dir == .horizontal) d.rect.x + d.rect.w / 2 else d.rect.y + d.rect.h / 2;
            const mouse = if (d.dir == .horizontal) ui.mx else ui.my;
            layout_mod.Layout.resize(d.split, d.index, (mouse - centre) / d.span, theme.pane_min / d.span);
            res.changed = true;
        }
        if (res.changed) geo = l.geometry(content, theme.divider_w);

        // Where each pane's strip and content go: the strip is in the band
        // for the panes along the top (stopping short of the right cluster)
        // and at the pane's own top otherwise.
        var parts: [layout_mod.max_panes]Parts = undefined;
        for (geo.panes[0..geo.n], 0..) |pr, i| {
            const along_top = pr.rect.y <= content.y + 0.5;
            var strip: Rect = undefined;
            var body = pr.rect;
            if (along_top) {
                strip = .{ .x = pr.rect.x, .y = band.y, .w = pr.rect.w, .h = band.h };
                if (strip.right() > cluster.right) strip.w = @max(0, cluster.right - strip.x);
            } else {
                strip = .{ .x = pr.rect.x, .y = pr.rect.y, .w = pr.rect.w, .h = theme.pane_strip_h };
                body.y += theme.pane_strip_h;
                body.h = @max(0, body.h - theme.pane_strip_h);
            }
            parts[i] = .{ .strip = strip, .body = body, .first = along_top and pr.rect.x <= content.x + 0.5 };
        }

        // A press on a pane's strip or content focuses it (unless a divider
        // took the press), and so does a right-click on its content: the
        // edit menu acts on what has the keyboard.
        if ((ui.pressed and !divider_held) or ui.right_pressed) {
            for (geo.panes[0..geo.n], 0..) |pr, i| {
                const hit = if (ui.pressed) ui.mouseIn(parts[i].strip) or ui.mouseIn(parts[i].body) else ui.mouseIn(parts[i].body);
                if (!hit) continue;
                if (l.focused != pr.pane.id) {
                    l.focused = pr.pane.id;
                    res.changed = true;
                }
            }
        }

        const focused_id = l.focused;
        for (geo.panes[0..geo.n], 0..) |pr, i| {
            const p = pr.pane;
            const strip = parts[i].strip;
            const body = parts[i].body;
            const focused = p.id == focused_id;
            const sr = tabbar.drawStrip(ui, strip, p, .{
                .left_inset = if (parts[i].first) @max(16, band_inset) else 12,
                .focused = focused,
                .show_info = focused,
            }, &self.drag);
            if (sr.activate) |j| {
                p.active = j;
                res.changed = true;
            }
            if (sr.menu) |m| res.menu = m;
            if (sr.new_tab) res.new_tab = p.id;
            if (sr.new_web_tab) res.new_web_tab = p.id;

            if (p.current()) |t| {
                dl.pushClip(body);
                t.vtable.draw(t.ptr, ui, body, window_focused and focused);
                dl.popClip();
            }
            if (self.drag) |*d| {
                if (ui.mouseIn(body)) d.target = .{ .zone = zoneFor(p.id, body, ui.mx, ui.my) };
            }
        }

        for (geo.dividers[0..geo.nd]) |d| {
            var r = d.rect;
            // A line between panes along the top runs up through the band,
            // separating their strips too.
            if (d.dir == .horizontal and r.y <= content.y + 0.5) {
                r.h += r.y - band.y;
                r.y = band.y;
            }
            const hot = ui.active == dividerId(d) or (ui.active == 0 and ui.mouseIn(grabRect(d)));
            dl.rect(r, if (hot) theme.line_strong else theme.line);
        }

        if (self.drag) |*d| {
            if (ui.released) {
                if (d.kind == .file) res.file_drop = d.target else applyDrop(tabs, d);
                self.drag = null;
                res.changed = true;
            } else if (!ui.down) {
                // The button went up where we could not see it.
                self.drag = null;
            } else tabbar.drawDrag(ui, d);
        }
        return res;
    }

    fn applyDrop(tabs: *tab_mod.TabManager, d: *const tabbar.Drag) void {
        const target = d.target orelse return;
        switch (target) {
            .strip => |s| _ = tabs.moveTab(d.uid, s.pane, s.index),
            .zone => |z| if (z.side) |side| {
                _ = tabs.moveTabToNewPane(d.uid, z.pane, side);
            } else if (z.pane != d.from_pane) {
                const to = tabs.paneById(z.pane) orelse return;
                _ = tabs.moveTab(d.uid, z.pane, to.tabs.items.len);
            },
        }
    }
};

/// A pane's strip and content rectangles for one frame.
const Parts = struct { strip: Rect, body: Rect, first: bool };

fn dividerId(d: Divider) u64 {
    return Ui.id("panes.divider", @intFromPtr(d.split) +% d.index);
}

/// The line plus a few points either side, so it can be grabbed.
fn grabRect(d: Divider) Rect {
    const g = theme.divider_grab;
    return if (d.dir == .horizontal)
        .{ .x = d.rect.x - g, .y = d.rect.y, .w = d.rect.w + 2 * g, .h = d.rect.h }
    else
        .{ .x = d.rect.x, .y = d.rect.y - g, .w = d.rect.w, .h = d.rect.h + 2 * g };
}

/// Which drop zone of a pane's content the pointer is in: a side band
/// (a new pane there) or the middle (this pane).
fn zoneFor(pane: u32, body: Rect, mx: f32, my: f32) tabbar.Zone {
    const band_x = @max(1, @min(body.w * 0.3, 200));
    const band_y = @max(1, @min(body.h * 0.3, 160));
    var side: ?Side = null;
    var best: f32 = 1;
    const candidates = [_]struct { d: f32, s: Side }{
        .{ .d = (mx - body.x) / band_x, .s = .left },
        .{ .d = (body.right() - mx) / band_x, .s = .right },
        .{ .d = (my - body.y) / band_y, .s = .top },
        .{ .d = (body.bottom() - my) / band_y, .s = .bottom },
    };
    for (candidates) |c| {
        if (c.d < best) {
            best = c.d;
            side = c.s;
        }
    }
    const rect: Rect = if (side) |s| switch (s) {
        .left => .{ .x = body.x, .y = body.y, .w = body.w / 2, .h = body.h },
        .right => .{ .x = body.x + body.w / 2, .y = body.y, .w = body.w / 2, .h = body.h },
        .top => .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h / 2 },
        .bottom => .{ .x = body.x, .y = body.y + body.h / 2, .w = body.w, .h = body.h / 2 },
    } else body;
    return .{ .pane = pane, .side = side, .rect = rect };
}

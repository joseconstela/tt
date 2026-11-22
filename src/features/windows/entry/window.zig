//! A separate window: what the app keeps for a tab that was dragged out of
//! the main window (or sent out from its menu). It shows one tab group of
//! its own, a *window group* (`TabManager.window_group_base`), as the main
//! window shows a sidebar row's: the strip in the titlebar band, the active
//! tab under it, splits. No sidebar, no files panel.
//!
//! Each window draws into a draw list of its own with its own input state
//! (`Ui`) and pane view, at its own size and backing scale; the app builds
//! its frame (`App.buildWindowFrame`) and the platform layer presents it to
//! the window's Metal layer. Fonts, the glyph atlas and image textures are
//! the app's, shared by every window. Nothing here knows AppKit: `native`
//! is the platform layer's own record, and headless runs have none.
const std = @import("std");
const draw = @import("../../../gfx/draw.zig");
const text_mod = @import("../../../gfx/text.zig");
const ui_mod = @import("../../../ui/ui.zig");
const panes_mod = @import("../../../ui/panes.zig");
const Chrome = @import("../../../ui/sidebar.zig").Chrome;
const frames = @import("../model/frames.zig");

pub const TabWindow = struct {
    gpa: std.mem.Allocator,
    /// The window group it shows; also what names the window.
    group: u32,
    dl: draw.DrawList,
    ui: ui_mod.Ui,
    /// Its split panes and a tab being dragged in it.
    panes: panes_mod.PaneView = .{},
    /// Where its traffic lights end, and whether it is the key window.
    chrome: Chrome = .{},

    /// The size and scale its frame is drawn with (the app's zoom folded
    /// in), and what the platform gave before that.
    width: f32,
    height: f32,
    scale: f32,
    raw_width: f32,
    raw_height: f32,
    raw_scale: f32,

    /// Where it is on screen (`frames.Frame`): what the app asked for
    /// until the platform says where it really is. Null: nowhere asked.
    frame: ?frames.Frame = null,
    /// Where the app wants it: the platform puts it there (on a visible
    /// screen) and clears this. A new window, or one moved by its only tab.
    place: ?frames.Frame = null,
    /// The platform layer's record of the real window, once it has one.
    native: ?*anyopaque = null,

    /// Space between the traffic lights and the first tab.
    pub const strip_gap: f32 = 14;

    /// A window for the group `group`, `width` × `height` points at the
    /// display's `scale`, drawn at the app's `zoom`.
    pub fn create(gpa: std.mem.Allocator, text: *text_mod.TextEngine, group: u32, width: f32, height: f32, scale: f32, zoom: f32) !*TabWindow {
        const self = try gpa.create(TabWindow);
        self.* = .{
            .gpa = gpa,
            .group = group,
            .dl = draw.DrawList.init(gpa, text),
            .ui = undefined,
            .width = width,
            .height = height,
            .scale = scale,
            .raw_width = width,
            .raw_height = height,
            .raw_scale = scale,
        };
        // The draw list is where it will stay: the input state points at it.
        self.ui = ui_mod.Ui.init(gpa, &self.dl, text);
        self.applyZoom(zoom);
        return self;
    }

    pub fn destroy(self: *TabWindow) void {
        self.ui.deinit();
        self.dl.deinit();
        self.gpa.destroy(self);
    }

    /// The platform's size for it (points and backing scale); false when
    /// nothing changed.
    pub fn resize(self: *TabWindow, width: f32, height: f32, scale: f32, zoom: f32) bool {
        if (width == self.raw_width and height == self.raw_height and scale == self.raw_scale) return false;
        self.raw_width = width;
        self.raw_height = height;
        self.raw_scale = scale;
        self.applyZoom(zoom);
        return true;
    }

    /// Folds the app's zoom into the size and scale, as the main window does.
    pub fn applyZoom(self: *TabWindow, zoom: f32) void {
        self.width = self.raw_width / zoom;
        self.height = self.raw_height / zoom;
        self.scale = self.raw_scale * zoom;
    }

    /// True if (x, y) hits a widget of the last frame (so a press in the
    /// titlebar band must not drag the window).
    pub fn isInteractiveAt(self: *const TabWindow, x: f32, y: f32) bool {
        for (self.ui.interactive.items) |r| {
            if (r.contains(x, y)) return true;
        }
        return false;
    }
};

test "a window folds the zoom into its size like the main one" {
    var text: text_mod.TextEngine = .{ .gpa = std.testing.allocator };
    const w = try TabWindow.create(std.testing.allocator, &text, 7, 900, 600, 2, 1.5);
    defer w.destroy();
    try std.testing.expectEqual(@as(f32, 600), w.width);
    try std.testing.expectEqual(@as(f32, 400), w.height);
    try std.testing.expectEqual(@as(f32, 3), w.scale);
    try std.testing.expect(!w.resize(900, 600, 2, 1.5));
    try std.testing.expect(w.resize(1200, 600, 1, 1));
    try std.testing.expectEqual(@as(f32, 1200), w.width);
    try std.testing.expectEqual(@as(f32, 1), w.scale);
    try std.testing.expect(!w.isInteractiveAt(10, 10));
}

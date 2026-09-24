//! Tiny immediate-mode UI core: input state, hit testing, hover/active
//! tracking. Widgets live next to the views that use them.
const std = @import("std");
const draw = @import("../gfx/draw.zig");
const text_mod = @import("../gfx/text.zig");
const theme = @import("theme.zig");

pub const Rect = draw.Rect;
pub const Color = draw.Color;
pub const Font = draw.Font;

pub const Cursor = enum { arrow, ibeam, pointer, resize_lr, resize_ud };

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
};

/// A text surface was right-clicked: the app opens the edit menu (Cut /
/// Copy / Paste) with its top-left corner at (x, y), the rows that do not
/// apply greyed out. What the rows act on is whatever has the keyboard,
/// so the surface takes the focus when it asks.
pub const EditMenu = struct {
    x: f32,
    y: f32,
    /// Something is selected: Copy, and Cut when the text is editable.
    has_selection: bool,
    /// The text can change: Cut and Paste.
    editable: bool,
};

pub const ButtonState = struct {
    hover: bool = false,
    held: bool = false,
    clicked: bool = false,
    double_clicked: bool = false,
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    dl: *draw.DrawList,
    text: *text_mod.TextEngine,
    now: f64 = 0,

    // Mouse state (points, top-left origin).
    mx: f32 = -1,
    my: f32 = -1,
    mouse_inside: bool = false,
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    click_count: u32 = 0,
    press_x: f32 = 0,
    press_y: f32 = 0,
    /// A secondary click (right button or ⌃-click) landed this frame.
    right_pressed: bool = false,
    /// That secondary click was a ⌃-click: over a link it opens the link
    /// instead of a menu (see `link`).
    ctrl_click: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    mods: Mods = .{},

    /// Widget that captured the mouse on press.
    active: u64 = 0,
    /// Where inside itself the active widget was grabbed (a scrollbar
    /// thumb keeps that offset under the pointer while it is dragged).
    drag_grab: f32 = 0,
    cursor: Cursor = .arrow,
    /// Hit regions registered this frame. Used by the platform layer to decide
    /// whether a titlebar click drags the window or belongs to a widget.
    interactive: std.ArrayList(Rect) = .empty,
    /// Set by widgets that animate; asks for another frame.
    wants_frame: bool = false,
    /// Set by a text surface that took a secondary click this frame (see
    /// `EditMenu`); the app opens the menu once the frame is drawn.
    edit_menu: ?EditMenu = null,
    /// The link under the pointer this frame (its address), recorded by the
    /// view that drew it; the app shows where it goes and opens it when
    /// `link_open` says it was ⌘- or ⌃-clicked.
    link_buf: [2048]u8 = undefined,
    link_len: usize = 0,
    link_open: bool = false,
    /// Where the view showing that link is (its clip when it recorded the
    /// link): the bubble with the address sits at its bottom.
    link_area: Rect = .{},

    pub fn init(gpa: std.mem.Allocator, dl: *draw.DrawList, text: *text_mod.TextEngine) Ui {
        return .{ .gpa = gpa, .dl = dl, .text = text };
    }

    pub fn deinit(self: *Ui) void {
        self.interactive.deinit(self.gpa);
    }

    pub fn beginFrame(self: *Ui, now: f64) void {
        self.now = now;
        self.cursor = .arrow;
        self.wants_frame = false;
        self.edit_menu = null;
        self.link_len = 0;
        self.link_open = false;
        self.interactive.clearRetainingCapacity();
    }

    pub fn endFrame(self: *Ui) void {
        if (self.released or !self.down) {
            if (!self.down) self.active = 0;
        }
        self.pressed = false;
        self.released = false;
        self.right_pressed = false;
        self.ctrl_click = false;
        self.scroll_x = 0;
        self.scroll_y = 0;
    }

    pub fn id(comptime src: []const u8, n: usize) u64 {
        const base = comptime std.hash.Wyhash.hash(0, src);
        return base +% (@as(u64, n) *% 0x9E3779B97F4A7C15) | 1;
    }

    pub fn mouseIn(self: *const Ui, r: Rect) bool {
        if (!self.mouse_inside) return false;
        return r.contains(self.mx, self.my) and self.dl.currentClip().contains(self.mx, self.my);
    }

    /// True once per secondary click over `r`; the click is consumed.
    pub fn rightClicked(self: *Ui, r: Rect) bool {
        if (!self.right_pressed or !self.mouseIn(r)) return false;
        self.right_pressed = false;
        return true;
    }

    /// ⌘ or ⌃ is held: the modifier that makes a click follow a link.
    pub fn linkModifier(self: *const Ui) bool {
        return (self.mods.cmd or self.mods.ctrl) and !self.mods.alt;
    }

    /// The pointer is over a link to `url` (the caller hit-tested its
    /// text, before anything under it took the press). Records it for the
    /// app, which shows where it goes and the pointing hand while ⌘ or ⌃ is
    /// held. True when the link was ⌘- or ⌃-clicked this frame: the press
    /// (or the secondary click) is consumed, so no selection or menu comes
    /// of it, and the app opens the address.
    pub fn link(self: *Ui, url: []const u8) bool {
        if (url.len == 0 or url.len > self.link_buf.len or !self.mouse_inside) return false;
        @memcpy(self.link_buf[0..url.len], url);
        self.link_len = url.len;
        self.link_area = self.dl.currentClip();
        const clicked = self.ctrl_click or (self.pressed and self.mods.cmd and !self.mods.alt and self.active == 0);
        if (!clicked) return false;
        self.ctrl_click = false;
        self.right_pressed = false;
        self.pressed = false;
        self.link_open = true;
        return true;
    }

    /// The address `link` recorded this frame ("" when none).
    pub fn hoveredLink(self: *const Ui) []const u8 {
        return self.link_buf[0..self.link_len];
    }

    /// Asks for the edit menu at the pointer (see `EditMenu`).
    pub fn askEditMenu(self: *Ui, has_selection: bool, editable: bool) void {
        self.edit_menu = .{ .x = self.mx, .y = self.my, .has_selection = has_selection, .editable = editable };
    }

    /// Core press/release behaviour shared by every clickable thing.
    pub fn button(self: *Ui, wid: u64, r: Rect) ButtonState {
        self.interactive.append(self.gpa, self.dl.currentClip().intersect(r)) catch {};
        const inside = self.mouseIn(r);
        var st: ButtonState = .{};
        if (self.pressed and inside and self.active == 0) self.active = wid;
        if (self.active == wid) {
            if (self.released) {
                if (inside) {
                    st.clicked = true;
                    st.double_clicked = self.click_count >= 2;
                }
                self.active = 0;
            } else st.held = true;
        }
        st.hover = inside and (self.active == 0 or self.active == wid);
        if (st.hover) self.cursor = .pointer;
        return st;
    }

    /// Drag behaviour: returns true while the widget owns the mouse.
    pub fn drag(self: *Ui, wid: u64, r: Rect) struct { hover: bool, dragging: bool, started: bool, double_clicked: bool } {
        self.interactive.append(self.gpa, self.dl.currentClip().intersect(r)) catch {};
        const inside = self.mouseIn(r);
        var started = false;
        var dbl = false;
        if (self.pressed and inside and self.active == 0) {
            self.active = wid;
            started = true;
            dbl = self.click_count >= 2;
        }
        var dragging = self.active == wid;
        if (dragging and self.released) {
            self.active = 0;
            dragging = false;
        }
        return .{
            .hover = inside and (self.active == 0 or self.active == wid),
            .dragging = dragging,
            .started = started,
            .double_clicked = dbl,
        };
    }

    /// Takes the vertical scroll delta if the mouse is over `r`.
    pub fn takeScroll(self: *Ui, r: Rect) f32 {
        if (self.scroll_y == 0 or !self.mouseIn(r)) return 0;
        const dy = self.scroll_y;
        self.scroll_y = 0;
        return dy;
    }

    /// Standard row/button background for hover & press feedback.
    pub fn feedback(self: *Ui, r: Rect, radius: f32, st: ButtonState) void {
        if (st.held) {
            self.dl.rrect(r, radius, theme.pressed);
        } else if (st.hover) {
            self.dl.rrect(r, radius, theme.hover);
        }
    }
};

//! Draw list: the UI emits shapes/text in *points*; we convert to device
//! pixels, snap to the pixel grid and produce one instance per quad.
const std = @import("std");
const text_mod = @import("text.zig");
const icons = @import("icons.zig");
const texture_mod = @import("texture.zig");

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn hex(comptime rgb: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        };
    }

    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }

    pub fn alpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a * a };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
    pub fn inset(self: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = @max(0, self.w - 2 * dx), .h = @max(0, self.h - 2 * dy) };
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
    pub fn centerY(self: Rect) f32 {
        return self.y + self.h * 0.5;
    }
};

/// GPU instance; layout mirrors `Instance` in shaders.metal.
pub const Instance = extern struct {
    rect: [4]f32,
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    params: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32,
};

pub const Font = text_mod.Font;
pub const Texture = texture_mod.Texture;

/// A run of consecutive instances drawn with one image texture bound (or
/// none). Shapes and glyphs never sample it, so they join whatever batch is
/// current; only an image with a *different* texture starts a new one.
pub const Batch = struct {
    first: u32,
    count: u32 = 0,
    texture: ?*anyopaque = null,
};

pub const DrawList = struct {
    gpa: std.mem.Allocator,
    instances: std.ArrayList(Instance) = .empty,
    /// Never empty between `begin` and the render: at least one batch.
    batches: std.ArrayList(Batch) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,
    text: *text_mod.TextEngine,
    scale: f32 = 2,
    /// Size of the surface in points.
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, text: *text_mod.TextEngine) DrawList {
        return .{ .gpa = gpa, .text = text };
    }

    pub fn deinit(self: *DrawList) void {
        self.instances.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.clip_stack.deinit(self.gpa);
    }

    pub fn begin(self: *DrawList, width: f32, height: f32, scale: f32) void {
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.batches.append(self.gpa, .{ .first = 0 }) catch {};
        self.clip_stack.clearRetainingCapacity();
        self.width = width;
        self.height = height;
        self.scale = scale;
    }

    // ── clipping ────────────────────────────────────────────────────────
    pub fn currentClip(self: *const DrawList) Rect {
        if (self.clip_stack.items.len == 0) return .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }

    pub fn pushClip(self: *DrawList, r: Rect) void {
        const c = self.currentClip().intersect(r);
        self.clip_stack.append(self.gpa, c) catch {};
    }

    pub fn popClip(self: *DrawList) void {
        if (self.clip_stack.items.len > 0) self.clip_stack.items.len -= 1;
    }

    fn clipPx(self: *const DrawList) [4]f32 {
        const c = self.currentClip();
        const s = self.scale;
        return .{ @round(c.x * s), @round(c.y * s), @round(c.right() * s), @round(c.bottom() * s) };
    }

    fn visible(self: *const DrawList, r: Rect) bool {
        const c = self.currentClip();
        return !(r.right() <= c.x or r.bottom() <= c.y or r.x >= c.right() or r.y >= c.bottom());
    }

    // ── shapes ──────────────────────────────────────────────────────────
    pub fn rect(self: *DrawList, r: Rect, color: Color) void {
        self.shape(r, 0, color, 0, Color.transparent);
    }

    pub fn rrect(self: *DrawList, r: Rect, radius: f32, color: Color) void {
        self.shape(r, radius, color, 0, Color.transparent);
    }

    pub fn border(self: *DrawList, r: Rect, radius: f32, width: f32, color: Color) void {
        self.shape(r, radius, Color.transparent, width, color);
    }

    pub fn shape(self: *DrawList, r: Rect, radius: f32, fill: Color, border_w: f32, border_color: Color) void {
        if (r.w <= 0 or r.h <= 0) return;
        if (!self.visible(r)) return;
        const s = self.scale;
        const x0 = @round(r.x * s);
        const y0 = @round(r.y * s);
        const x1 = @max(x0 + 1, @round(r.right() * s));
        const y1 = @max(y0 + 1, @round(r.bottom() * s));
        const bw: f32 = if (border_w > 0) @max(1, @round(border_w * s)) else 0;
        self.push(.{
            .rect = .{ x0, y0, x1 - x0, y1 - y0 },
            .color = .{ fill.r, fill.g, fill.b, fill.a },
            .border_color = .{ border_color.r, border_color.g, border_color.b, border_color.a },
            .params = .{ radius * s, bw, 0, 0 },
            .clip = self.clipPx(),
        }, null);
    }

    pub fn circle(self: *DrawList, cx: f32, cy: f32, radius: f32, color: Color) void {
        self.shape(.{ .x = cx - radius, .y = cy - radius, .w = radius * 2, .h = radius * 2 }, radius, color, 0, Color.transparent);
    }

    // ── text ────────────────────────────────────────────────────────────
    /// Draws `str` with its baseline at `baseline_y`. Returns the advance in points.
    pub fn textAt(self: *DrawList, font: Font, x: f32, baseline_y: f32, str: []const u8, color: Color) f32 {
        const s = self.scale;
        var pen: f32 = x * s;
        const by = @round(baseline_y * s);
        const clip = self.clipPx();
        var it = text_mod.Utf8Iter{ .bytes = str };
        while (it.next()) |cp| {
            pen += self.glyph(font, cp, pen, by, color, clip);
        }
        return pen / s - x;
    }

    /// Draws a single code point at pen position (device pixels). Returns advance in px.
    pub fn glyph(self: *DrawList, font: Font, cp: u21, pen_px: f32, baseline_px: f32, color: Color, clip: [4]f32) f32 {
        const gi = self.text.glyphFor(font, cp);
        if (self.text.atlasEntry(gi)) |e| {
            if (e.w > 0 and e.h > 0) {
                const gx = @round(pen_px) + e.bearing_x;
                const gy = baseline_px - e.bearing_y;
                const w: f32 = @floatFromInt(e.w);
                const h: f32 = @floatFromInt(e.h);
                if (!(gx + w <= clip[0] or gy + h <= clip[1] or gx >= clip[2] or gy >= clip[3])) {
                    const ux: f32 = @floatFromInt(e.x);
                    const uy: f32 = @floatFromInt(e.y);
                    self.push(.{
                        .rect = .{ gx, gy, w, h },
                        .uv = .{ ux, uy, ux + w, uy + h },
                        .color = .{ color.r, color.g, color.b, color.a },
                        .params = .{ 0, 0, 1, 0 },
                        .clip = clip,
                    }, null);
                }
            }
        }
        return gi.advance;
    }

    /// Text vertically centred on `center_y` (like a CSS flex row with align-items:center).
    pub fn textCentered(self: *DrawList, font: Font, x: f32, center_y: f32, str: []const u8, color: Color) f32 {
        return self.textAt(font, x, self.text.baselineForCenter(font, center_y), str, color);
    }

    /// Like `textCentered`, truncating with an ellipsis if wider than `max_w`.
    pub fn textEllipsis(self: *DrawList, font: Font, x: f32, center_y: f32, str: []const u8, max_w: f32, color: Color) f32 {
        if (max_w <= 0) return 0;
        const full = self.text.measure(font, str);
        if (full <= max_w) return self.textCentered(font, x, center_y, str, color);
        const ell = "…";
        const ell_w = self.text.measure(font, ell);
        var it = text_mod.Utf8Iter{ .bytes = str };
        var w: f32 = 0;
        var end: usize = 0;
        while (it.next()) |cp| {
            const adv = self.text.advance(font, cp);
            if (w + adv + ell_w > max_w) break;
            w += adv;
            end = it.index;
        }
        // Trim trailing spaces before the ellipsis.
        while (end > 0 and str[end - 1] == ' ') end -= 1;
        const used = self.textCentered(font, x, center_y, str[0..end], color);
        return used + self.textCentered(font, x + used, center_y, ell, color);
    }

    pub fn textRight(self: *DrawList, font: Font, right_x: f32, center_y: f32, str: []const u8, color: Color) f32 {
        const w = self.text.measure(font, str);
        _ = self.textCentered(font, right_x - w, center_y, str, color);
        return w;
    }

    // ── icons ───────────────────────────────────────────────────────────
    /// Draws a stroked icon in a `size`×`size` point box at (x, y).
    pub fn icon(self: *DrawList, which: icons.Icon, x: f32, y: f32, size: f32, color: Color) void {
        const e = self.text.iconEntry(which, size) orelse return;
        const s = self.scale;
        const gx = @round(x * s) - @as(f32, @floatFromInt(icons.pad_px));
        const gy = @round(y * s) - @as(f32, @floatFromInt(icons.pad_px));
        const w: f32 = @floatFromInt(e.w);
        const h: f32 = @floatFromInt(e.h);
        const ux: f32 = @floatFromInt(e.x);
        const uy: f32 = @floatFromInt(e.y);
        self.push(.{
            .rect = .{ gx, gy, w, h },
            .uv = .{ ux, uy, ux + w, uy + h },
            .color = .{ color.r, color.g, color.b, color.a },
            .params = .{ 0, 0, 1, 0 },
            .clip = self.clipPx(),
        }, null);
    }

    // ── images ──────────────────────────────────────────────────────────
    /// Draws a texture (see `texture.zig`) stretched over `r`, tinted by
    /// `tint` (white = as is). `uv` selects a normalised sub-rectangle.
    pub fn imageUv(self: *DrawList, r: Rect, tex: Texture, uv: [4]f32, tint: Color) void {
        if (!tex.valid() or r.w <= 0 or r.h <= 0) return;
        if (!self.visible(r)) return;
        const s = self.scale;
        const x0 = @round(r.x * s);
        const y0 = @round(r.y * s);
        const x1 = @max(x0 + 1, @round(r.right() * s));
        const y1 = @max(y0 + 1, @round(r.bottom() * s));
        self.push(.{
            .rect = .{ x0, y0, x1 - x0, y1 - y0 },
            .uv = uv,
            .color = .{ tint.r, tint.g, tint.b, tint.a },
            .params = .{ 0, 0, 2, 0 },
            .clip = self.clipPx(),
        }, tex.handle);
    }

    pub fn image(self: *DrawList, r: Rect, tex: Texture, tint: Color) void {
        self.imageUv(r, tex, .{ 0, 0, 1, 1 }, tint);
    }

    /// Appends an instance, opening a new batch when it needs an image
    /// texture other than the current batch's.
    fn push(self: *DrawList, inst: Instance, texture: ?*anyopaque) void {
        if (self.batches.items.len == 0) self.batches.append(self.gpa, .{ .first = 0 }) catch return;
        var b = &self.batches.items[self.batches.items.len - 1];
        if (texture) |t| {
            if (b.texture == null) {
                b.texture = t;
            } else if (b.texture != t) {
                self.batches.append(self.gpa, .{ .first = @intCast(self.instances.items.len), .texture = t }) catch return;
                b = &self.batches.items[self.batches.items.len - 1];
            }
        }
        self.instances.append(self.gpa, inst) catch return;
        b.count += 1;
    }
};

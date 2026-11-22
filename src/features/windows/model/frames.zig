//! Where windows are on screen, as plain numbers: no AppKit here. A `Frame`
//! is a window's rectangle in screen points with the origin at the top-left
//! of the main display and y growing downwards (the platform layer flips
//! AppKit's), so a point inside a window, in the window's own coordinates,
//! becomes a point on screen by adding the frame's corner. That is all it
//! takes to say what a tab let go outside its window landed on: another
//! window (it joins that one's tabs), or nothing (it gets a window of its
//! own, placed so the tab stays under the pointer).
//!
//! A frame is kept in the workspace file as four numbers, `x y w h`,
//! separated by tabs (`format` / `parse`).
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };

pub const Frame = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Frame, p: Point) bool {
        return p.x >= self.x and p.x < self.x + self.w and p.y >= self.y and p.y < self.y + self.h;
    }

    /// A point of the window (its own coordinates, in points) on screen.
    pub fn toScreen(self: Frame, x: f32, y: f32) Point {
        return .{ .x = self.x + x, .y = self.y + y };
    }

    /// A point on screen in the window's own coordinates.
    pub fn toLocal(self: Frame, p: Point) Point {
        return .{ .x = p.x - self.x, .y = p.y - self.y };
    }

    pub fn eql(self: Frame, other: Frame) bool {
        return self.x == other.x and self.y == other.y and self.w == other.w and self.h == other.h;
    }
};

/// The size a window made for a dragged-out tab starts with, and the least
/// one may be resized to.
pub const default_w: f32 = 900;
pub const default_h: f32 = 620;
pub const min_w: f32 = 380;
pub const min_h: f32 = 240;

/// Whether a point in a window's own coordinates is outside a window of
/// that size: where letting go of a tab takes it out of the window.
pub fn outside(width: f32, height: f32, x: f32, y: f32) bool {
    return x < 0 or y < 0 or x >= width or y >= height;
}

/// The first of `frames` (given front to back) that `p` is in.
pub fn hit(frames: []const ?Frame, p: Point) ?usize {
    for (frames, 0..) |frame, i| {
        const f = frame orelse continue;
        if (f.contains(p)) return i;
    }
    return null;
}

/// The frame of a new window for a tab let go at `p`: the tab's place in
/// the new strip (`tab_x`, `tab_y` from the window's corner) ends up under
/// the pointer. As large as the window the tab came from, up to the default.
pub fn spawnAt(p: Point, tab_x: f32, tab_y: f32, from_w: f32, from_h: f32) Frame {
    return .{
        .x = @round(p.x - tab_x),
        .y = @round(p.y - tab_y),
        .w = std.math.clamp(from_w, min_w, default_w),
        .h = std.math.clamp(from_h, min_h, default_h),
    };
}

/// `f` brought onto a screen: inside the one of `screens` it overlaps
/// most (the first when it overlaps none: a display that is gone), no
/// larger than it, its titlebar reachable. Unchanged without screens.
pub fn clamp(f: Frame, screens: []const Frame) Frame {
    if (screens.len == 0) return f;
    var best: usize = 0;
    var best_area: f32 = 0;
    for (screens, 0..) |s, i| {
        const ow = @min(f.x + f.w, s.x + s.w) - @max(f.x, s.x);
        const oh = @min(f.y + f.h, s.y + s.h) - @max(f.y, s.y);
        const area = if (ow > 0 and oh > 0) ow * oh else 0;
        if (area > best_area) {
            best_area = area;
            best = i;
        }
    }
    const s = screens[best];
    var out = f;
    out.w = @min(@max(out.w, min_w), s.w);
    out.h = @min(@max(out.h, min_h), s.h);
    out.x = std.math.clamp(out.x, s.x, s.x + s.w - out.w);
    out.y = std.math.clamp(out.y, s.y, s.y + s.h - out.h);
    return out;
}

/// `x <tab> y <tab> w <tab> h`, whole points.
pub fn format(f: Frame, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}\t{d}\t{d}\t{d}", .{
        @as(i32, @intFromFloat(@round(f.x))),
        @as(i32, @intFromFloat(@round(f.y))),
        @as(i32, @intFromFloat(@round(f.w))),
        @as(i32, @intFromFloat(@round(f.h))),
    }) catch "";
}

/// What `format` wrote; null for anything else (a frame with no size too).
pub fn parse(text: []const u8) ?Frame {
    var it = std.mem.splitScalar(u8, text, '\t');
    var v: [4]f32 = undefined;
    for (&v) |*slot| {
        const field = it.next() orelse return null;
        slot.* = @floatFromInt(std.fmt.parseInt(i32, field, 10) catch return null);
    }
    if (v[2] <= 0 or v[3] <= 0) return null;
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

test "a point leaves its window and lands on another, or on none" {
    const main: Frame = .{ .x = 100, .y = 50, .w = 1200, .h = 800 };
    const other: Frame = .{ .x = 1400, .y = 200, .w = 600, .h = 400 };
    try std.testing.expect(!outside(1200, 800, 10, 10));
    try std.testing.expect(outside(1200, 800, -1, 10));
    try std.testing.expect(outside(1200, 800, 10, 800));

    // Let go 300 points right of the main window's edge: on the other one.
    const p = main.toScreen(1500, 300);
    try std.testing.expectEqual(@as(f32, 1600), p.x);
    try std.testing.expectEqual(@as(?usize, 1), hit(&.{ null, other, main }, p));
    try std.testing.expectEqual(@as(f32, 200), other.toLocal(p).x);
    // Windows that overlap: the one in front (listed first) wins; a
    // window whose frame is not known yet is passed over.
    try std.testing.expectEqual(@as(?usize, 0), hit(&.{ main, other }, main.toScreen(5, 5)));
    try std.testing.expectEqual(@as(?usize, null), hit(&.{ main, other }, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(?usize, null), hit(&.{null}, p));
}

test "a new window opens with its tab under the pointer and stays on a screen" {
    const f = spawnAt(.{ .x = 2000, .y = 400 }, 120, 26, 1440, 900);
    try std.testing.expectEqual(@as(f32, 1880), f.x);
    try std.testing.expectEqual(@as(f32, 374), f.y);
    try std.testing.expectEqual(default_w, f.w);
    try std.testing.expectEqual(default_h, f.h);
    // From a small window: no larger than it was.
    try std.testing.expectEqual(@as(f32, 500), spawnAt(.{ .x = 0, .y = 0 }, 0, 0, 500, 300).w);

    const laptop: Frame = .{ .x = 0, .y = 0, .w = 1512, .h = 982 };
    const desk: Frame = .{ .x = 1512, .y = -200, .w = 2560, .h = 1440 };
    // Mostly on the second display: kept there, pulled inside its edges.
    const kept = clamp(.{ .x = 3800, .y = 1100, .w = 900, .h = 620 }, &.{ laptop, desk });
    try std.testing.expectEqual(@as(f32, 1512 + 2560 - 900), kept.x);
    try std.testing.expectEqual(@as(f32, -200 + 1440 - 620), kept.y);
    // On a display that is gone: onto the first one, no larger than it.
    const moved = clamp(.{ .x = 9000, .y = 9000, .w = 4000, .h = 620 }, &.{laptop});
    try std.testing.expectEqual(@as(f32, 0), moved.x);
    try std.testing.expectEqual(@as(f32, 1512), moved.w);
    try std.testing.expectEqual(@as(f32, 982 - 620), moved.y);
    try std.testing.expect(clamp(f, &.{}).eql(f));
}

test "a frame is four numbers in the workspace file" {
    var buf: [64]u8 = undefined;
    const text = format(.{ .x = -120.4, .y = 38, .w = 900, .h = 620.6 }, &buf);
    try std.testing.expectEqualStrings("-120\t38\t900\t621", text);
    const back = parse(text).?;
    try std.testing.expectEqual(@as(f32, -120), back.x);
    try std.testing.expectEqual(@as(f32, 621), back.h);
    try std.testing.expect(parse("1\t2\t3") == null);
    try std.testing.expect(parse("1\t2\t0\t4") == null);
    try std.testing.expect(parse("a\tb\tc\td") == null);
}

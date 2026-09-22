//! Box-drawing (U+2500–U+257F) and block-element (U+2580–U+259F) glyphs
//! drawn as rectangles that fill their cell exactly, so lines join across
//! cells and rows whatever the line height. Font glyphs leave gaps.
const std = @import("std");
const draw_mod = @import("draw.zig");

const DrawList = draw_mod.DrawList;
const Rect = draw_mod.Rect;
const Color = draw_mod.Color;

/// Per code point: arms left/up/right/down as 2-bit weights (0 none,
/// 1 light, 2 heavy, 3 double), bit 8 = rounded corner, bits 9–10 = dashes
/// (0 none, then 2/3/4), bit 11 = leave it to the font (diagonals).
const box = [128]u16{
    0x011, // U+2500 LIGHT HORIZONTAL
    0x022, // U+2501 HEAVY HORIZONTAL
    0x044, // U+2502 LIGHT VERTICAL
    0x088, // U+2503 HEAVY VERTICAL
    0x411, // U+2504 LIGHT TRIPLE DASH HORIZONTAL
    0x422, // U+2505 HEAVY TRIPLE DASH HORIZONTAL
    0x444, // U+2506 LIGHT TRIPLE DASH VERTICAL
    0x488, // U+2507 HEAVY TRIPLE DASH VERTICAL
    0x611, // U+2508 LIGHT QUADRUPLE DASH HORIZONTAL
    0x622, // U+2509 HEAVY QUADRUPLE DASH HORIZONTAL
    0x644, // U+250A LIGHT QUADRUPLE DASH VERTICAL
    0x688, // U+250B HEAVY QUADRUPLE DASH VERTICAL
    0x050, // U+250C LIGHT DOWN AND RIGHT
    0x060, // U+250D DOWN LIGHT AND RIGHT HEAVY
    0x090, // U+250E DOWN HEAVY AND RIGHT LIGHT
    0x0A0, // U+250F HEAVY DOWN AND RIGHT
    0x041, // U+2510 LIGHT DOWN AND LEFT
    0x042, // U+2511 DOWN LIGHT AND LEFT HEAVY
    0x081, // U+2512 DOWN HEAVY AND LEFT LIGHT
    0x082, // U+2513 HEAVY DOWN AND LEFT
    0x014, // U+2514 LIGHT UP AND RIGHT
    0x024, // U+2515 UP LIGHT AND RIGHT HEAVY
    0x018, // U+2516 UP HEAVY AND RIGHT LIGHT
    0x028, // U+2517 HEAVY UP AND RIGHT
    0x005, // U+2518 LIGHT UP AND LEFT
    0x006, // U+2519 UP LIGHT AND LEFT HEAVY
    0x009, // U+251A UP HEAVY AND LEFT LIGHT
    0x00A, // U+251B HEAVY UP AND LEFT
    0x054, // U+251C LIGHT VERTICAL AND RIGHT
    0x064, // U+251D VERTICAL LIGHT AND RIGHT HEAVY
    0x058, // U+251E UP HEAVY AND RIGHT DOWN LIGHT
    0x094, // U+251F DOWN HEAVY AND RIGHT UP LIGHT
    0x098, // U+2520 VERTICAL HEAVY AND RIGHT LIGHT
    0x068, // U+2521 DOWN LIGHT AND RIGHT UP HEAVY
    0x0A4, // U+2522 UP LIGHT AND RIGHT DOWN HEAVY
    0x0A8, // U+2523 HEAVY VERTICAL AND RIGHT
    0x045, // U+2524 LIGHT VERTICAL AND LEFT
    0x046, // U+2525 VERTICAL LIGHT AND LEFT HEAVY
    0x049, // U+2526 UP HEAVY AND LEFT DOWN LIGHT
    0x085, // U+2527 DOWN HEAVY AND LEFT UP LIGHT
    0x089, // U+2528 VERTICAL HEAVY AND LEFT LIGHT
    0x04A, // U+2529 DOWN LIGHT AND LEFT UP HEAVY
    0x086, // U+252A UP LIGHT AND LEFT DOWN HEAVY
    0x08A, // U+252B HEAVY VERTICAL AND LEFT
    0x051, // U+252C LIGHT DOWN AND HORIZONTAL
    0x052, // U+252D LEFT HEAVY AND RIGHT DOWN LIGHT
    0x061, // U+252E RIGHT HEAVY AND LEFT DOWN LIGHT
    0x062, // U+252F DOWN LIGHT AND HORIZONTAL HEAVY
    0x091, // U+2530 DOWN HEAVY AND HORIZONTAL LIGHT
    0x092, // U+2531 RIGHT LIGHT AND LEFT DOWN HEAVY
    0x0A1, // U+2532 LEFT LIGHT AND RIGHT DOWN HEAVY
    0x0A2, // U+2533 HEAVY DOWN AND HORIZONTAL
    0x015, // U+2534 LIGHT UP AND HORIZONTAL
    0x016, // U+2535 LEFT HEAVY AND RIGHT UP LIGHT
    0x025, // U+2536 RIGHT HEAVY AND LEFT UP LIGHT
    0x026, // U+2537 UP LIGHT AND HORIZONTAL HEAVY
    0x019, // U+2538 UP HEAVY AND HORIZONTAL LIGHT
    0x01A, // U+2539 RIGHT LIGHT AND LEFT UP HEAVY
    0x029, // U+253A LEFT LIGHT AND RIGHT UP HEAVY
    0x02A, // U+253B HEAVY UP AND HORIZONTAL
    0x055, // U+253C LIGHT VERTICAL AND HORIZONTAL
    0x056, // U+253D LEFT HEAVY AND RIGHT VERTICAL LIGHT
    0x065, // U+253E RIGHT HEAVY AND LEFT VERTICAL LIGHT
    0x066, // U+253F VERTICAL LIGHT AND HORIZONTAL HEAVY
    0x059, // U+2540 UP HEAVY AND DOWN HORIZONTAL LIGHT
    0x095, // U+2541 DOWN HEAVY AND UP HORIZONTAL LIGHT
    0x099, // U+2542 VERTICAL HEAVY AND HORIZONTAL LIGHT
    0x05A, // U+2543 LEFT UP HEAVY AND RIGHT DOWN LIGHT
    0x069, // U+2544 RIGHT UP HEAVY AND LEFT DOWN LIGHT
    0x096, // U+2545 LEFT DOWN HEAVY AND RIGHT UP LIGHT
    0x0A5, // U+2546 RIGHT DOWN HEAVY AND LEFT UP LIGHT
    0x06A, // U+2547 DOWN LIGHT AND UP HORIZONTAL HEAVY
    0x0A6, // U+2548 UP LIGHT AND DOWN HORIZONTAL HEAVY
    0x09A, // U+2549 RIGHT LIGHT AND LEFT VERTICAL HEAVY
    0x0A9, // U+254A LEFT LIGHT AND RIGHT VERTICAL HEAVY
    0x0AA, // U+254B HEAVY VERTICAL AND HORIZONTAL
    0x211, // U+254C LIGHT DOUBLE DASH HORIZONTAL
    0x222, // U+254D HEAVY DOUBLE DASH HORIZONTAL
    0x244, // U+254E LIGHT DOUBLE DASH VERTICAL
    0x288, // U+254F HEAVY DOUBLE DASH VERTICAL
    0x033, // U+2550 DOUBLE HORIZONTAL
    0x0CC, // U+2551 DOUBLE VERTICAL
    0x070, // U+2552 DOWN SINGLE AND RIGHT DOUBLE
    0x0D0, // U+2553 DOWN DOUBLE AND RIGHT SINGLE
    0x0F0, // U+2554 DOUBLE DOWN AND RIGHT
    0x043, // U+2555 DOWN SINGLE AND LEFT DOUBLE
    0x0C1, // U+2556 DOWN DOUBLE AND LEFT SINGLE
    0x0C3, // U+2557 DOUBLE DOWN AND LEFT
    0x034, // U+2558 UP SINGLE AND RIGHT DOUBLE
    0x01C, // U+2559 UP DOUBLE AND RIGHT SINGLE
    0x03C, // U+255A DOUBLE UP AND RIGHT
    0x007, // U+255B UP SINGLE AND LEFT DOUBLE
    0x00D, // U+255C UP DOUBLE AND LEFT SINGLE
    0x00F, // U+255D DOUBLE UP AND LEFT
    0x074, // U+255E VERTICAL SINGLE AND RIGHT DOUBLE
    0x0DC, // U+255F VERTICAL DOUBLE AND RIGHT SINGLE
    0x0FC, // U+2560 DOUBLE VERTICAL AND RIGHT
    0x047, // U+2561 VERTICAL SINGLE AND LEFT DOUBLE
    0x0CD, // U+2562 VERTICAL DOUBLE AND LEFT SINGLE
    0x0CF, // U+2563 DOUBLE VERTICAL AND LEFT
    0x073, // U+2564 DOWN SINGLE AND HORIZONTAL DOUBLE
    0x0D1, // U+2565 DOWN DOUBLE AND HORIZONTAL SINGLE
    0x0F3, // U+2566 DOUBLE DOWN AND HORIZONTAL
    0x037, // U+2567 UP SINGLE AND HORIZONTAL DOUBLE
    0x01D, // U+2568 UP DOUBLE AND HORIZONTAL SINGLE
    0x03F, // U+2569 DOUBLE UP AND HORIZONTAL
    0x077, // U+256A VERTICAL SINGLE AND HORIZONTAL DOUBLE
    0x0DD, // U+256B VERTICAL DOUBLE AND HORIZONTAL SINGLE
    0x0FF, // U+256C DOUBLE VERTICAL AND HORIZONTAL
    0x150, // U+256D LIGHT ARC DOWN AND RIGHT
    0x141, // U+256E LIGHT ARC DOWN AND LEFT
    0x105, // U+256F LIGHT ARC UP AND LEFT
    0x114, // U+2570 LIGHT ARC UP AND RIGHT
    0x800, // U+2571 LIGHT DIAGONAL UPPER RIGHT TO LOWER LEFT
    0x800, // U+2572 LIGHT DIAGONAL UPPER LEFT TO LOWER RIGHT
    0x800, // U+2573 LIGHT DIAGONAL CROSS
    0x001, // U+2574 LIGHT LEFT
    0x004, // U+2575 LIGHT UP
    0x010, // U+2576 LIGHT RIGHT
    0x040, // U+2577 LIGHT DOWN
    0x002, // U+2578 HEAVY LEFT
    0x008, // U+2579 HEAVY UP
    0x020, // U+257A HEAVY RIGHT
    0x080, // U+257B HEAVY DOWN
    0x021, // U+257C LIGHT LEFT AND HEAVY RIGHT
    0x084, // U+257D LIGHT UP AND HEAVY DOWN
    0x012, // U+257E HEAVY LEFT AND LIGHT RIGHT
    0x048, // U+257F HEAVY UP AND LIGHT DOWN
};

/// Draws `cp` filling `r`; false when it is not a box or block character.
pub fn draw(dl: *DrawList, r: Rect, cp: u21, color: Color) bool {
    if (cp >= 0x2500 and cp <= 0x257F) return drawBox(dl, r, box[cp - 0x2500], color);
    if (cp >= 0x2580 and cp <= 0x259F) return drawBlock(dl, r, cp, color);
    return false;
}

const Px = struct {
    dl: *DrawList,
    s: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    cx: f32,
    cy: f32,
    /// Light stroke thickness in device pixels.
    t: f32,

    fn init(dl: *DrawList, r: Rect) Px {
        const s = dl.scale;
        const x0 = @round(r.x * s);
        const y0 = @round(r.y * s);
        const x1 = @max(x0 + 1, @round(r.right() * s));
        const y1 = @max(y0 + 1, @round(r.bottom() * s));
        return .{
            .dl = dl,
            .s = s,
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .cx = x0 + @floor((x1 - x0) / 2),
            .cy = y0 + @floor((y1 - y0) / 2),
            .t = @max(1, @round((x1 - x0) / 8)),
        };
    }

    fn fill(p: Px, ax: f32, ay: f32, bx: f32, by: f32, color: Color) void {
        const x0 = @max(p.x0, @min(ax, bx));
        const y0 = @max(p.y0, @min(ay, by));
        const x1 = @min(p.x1, @max(ax, bx));
        const y1 = @min(p.y1, @max(ay, by));
        if (x1 <= x0 or y1 <= y0) return;
        p.dl.rect(.{ .x = x0 / p.s, .y = y0 / p.s, .w = (x1 - x0) / p.s, .h = (y1 - y0) / p.s }, color);
    }

    /// Fraction of the cell: (fx0, fy0)–(fx1, fy1) in [0, 1].
    fn frac(p: Px, fx0: f32, fy0: f32, fx1: f32, fy1: f32, color: Color) void {
        const w = p.x1 - p.x0;
        const h = p.y1 - p.y0;
        p.fill(p.x0 + @round(w * fx0), p.y0 + @round(h * fy0), p.x0 + @round(w * fx1), p.y0 + @round(h * fy1), color);
    }
};

fn thickness(p: Px, weight: u16) f32 {
    return if (weight == 2) p.t * 2 else p.t;
}

fn drawBox(dl: *DrawList, r: Rect, v: u16, color: Color) bool {
    if (v & 0x800 != 0) return false;
    const p = Px.init(dl, r);
    const arms = [4]u16{ v & 3, (v >> 2) & 3, (v >> 4) & 3, (v >> 6) & 3 };
    const dashes: u16 = switch ((v >> 9) & 3) {
        1 => 2,
        2 => 3,
        3 => 4,
        else => 0,
    };
    if (v & 0x100 != 0) {
        drawArc(p, arms, color);
        return true;
    }
    if (dashes > 0) {
        drawDashes(p, arms, dashes, color);
        return true;
    }
    for (arms, 0..) |w, dir| {
        if (w == 0) continue;
        if (w == 3) {
            drawDoubleArm(p, dir, color);
            continue;
        }
        const t = thickness(p, w);
        const half = @floor(t / 2);
        switch (dir) {
            0 => p.fill(p.x0, p.cy - half, p.cx + (t - half), p.cy - half + t, color),
            2 => p.fill(p.cx - half, p.cy - half, p.x1, p.cy - half + t, color),
            1 => p.fill(p.cx - half, p.y0, p.cx - half + t, p.cy + (t - half), color),
            else => p.fill(p.cx - half, p.cy - half, p.cx - half + t, p.y1, color),
        }
    }
    return true;
}

/// Two parallel light strokes, `t` apart, overlapping at the centre so
/// junctions close (corners are squared off rather than nested).
fn drawDoubleArm(p: Px, dir: usize, color: Color) void {
    const t = p.t;
    const half = @floor(t / 2);
    const reach = t + half; // to the outer edge of a crossing double stroke
    const offs = [2]f32{ -t, t };
    for (offs) |o| switch (dir) {
        0 => p.fill(p.x0, p.cy + o - half, p.cx + reach, p.cy + o - half + t, color),
        2 => p.fill(p.cx - reach, p.cy + o - half, p.x1, p.cy + o - half + t, color),
        1 => p.fill(p.cx + o - half, p.y0, p.cx + o - half + t, p.cy + reach, color),
        else => p.fill(p.cx + o - half, p.cy - reach, p.cx + o - half + t, p.y1, color),
    };
}

fn drawDashes(p: Px, arms: [4]u16, n: u16, color: Color) void {
    const horizontal = arms[0] != 0;
    const t = thickness(p, if (horizontal) arms[0] else arms[1]);
    const half = @floor(t / 2);
    const len = if (horizontal) p.x1 - p.x0 else p.y1 - p.y0;
    const seg = len / @as(f32, @floatFromInt(n));
    const gap = @max(1, @round(seg / 3));
    var i: f32 = 0;
    while (i < @as(f32, @floatFromInt(n))) : (i += 1) {
        const a = @round(i * seg + gap / 2);
        const b = @round((i + 1) * seg - gap / 2);
        if (horizontal) {
            p.fill(p.x0 + a, p.cy - half, p.x0 + b, p.cy - half + t, color);
        } else p.fill(p.cx - half, p.y0 + a, p.cx - half + t, p.y0 + b, color);
    }
}

/// A rounded corner: one bordered rounded rectangle, clipped to the
/// quadrant that holds the arc and its two straight arms.
fn drawArc(p: Px, arms: [4]u16, color: Color) void {
    const t = p.t;
    const half = @floor(t / 2);
    const right = arms[2] != 0;
    const down = arms[3] != 0;
    const rad = @min((p.x1 - p.x0) / 2, (p.y1 - p.y0) / 2);
    const big = 4 * @max(p.x1 - p.x0, p.y1 - p.y0);
    const edge_x = if (right) p.cx - half else p.cx - half + t; // where the stroke's outer edge sits
    const edge_y = if (down) p.cy - half else p.cy - half + t;
    const rx = if (right) edge_x else edge_x - big;
    const ry = if (down) edge_y else edge_y - big;
    const clip: Rect = .{
        .x = (if (right) edge_x else p.x0) / p.s,
        .y = (if (down) edge_y else p.y0) / p.s,
        .w = (if (right) p.x1 - edge_x else edge_x - p.x0) / p.s,
        .h = (if (down) p.y1 - edge_y else edge_y - p.y0) / p.s,
    };
    p.dl.pushClip(clip);
    defer p.dl.popClip();
    p.dl.border(.{ .x = rx / p.s, .y = ry / p.s, .w = big / p.s, .h = big / p.s }, (rad + half) / p.s, t / p.s, color);
}

fn drawBlock(dl: *DrawList, r: Rect, cp: u21, color: Color) bool {
    const p = Px.init(dl, r);
    switch (cp) {
        0x2580 => p.frac(0, 0, 1, 0.5, color),
        0x2581...0x2588 => {
            const eighths: f32 = @floatFromInt(cp - 0x2580);
            p.frac(0, 1 - eighths / 8, 1, 1, color);
        },
        0x2589...0x258F => {
            const eighths: f32 = @floatFromInt(0x2590 - cp);
            p.frac(0, 0, eighths / 8, 1, color);
        },
        0x2590 => p.frac(0.5, 0, 1, 1, color),
        0x2591 => p.frac(0, 0, 1, 1, color.alpha(0.25)),
        0x2592 => p.frac(0, 0, 1, 1, color.alpha(0.5)),
        0x2593 => p.frac(0, 0, 1, 1, color.alpha(0.75)),
        0x2594 => p.frac(0, 0, 1, 0.125, color),
        0x2595 => p.frac(0.875, 0, 1, 1, color),
        0x2596...0x259F => {
            // Quadrants: bit 0 upper-left, 1 upper-right, 2 lower-left, 3 lower-right.
            const q: u8 = switch (cp) {
                0x2596 => 0b0100,
                0x2597 => 0b1000,
                0x2598 => 0b0001,
                0x2599 => 0b1101,
                0x259A => 0b1001,
                0x259B => 0b0111,
                0x259C => 0b1011,
                0x259D => 0b0010,
                0x259E => 0b0110,
                else => 0b1110,
            };
            if (q & 1 != 0) p.frac(0, 0, 0.5, 0.5, color);
            if (q & 2 != 0) p.frac(0.5, 0, 1, 0.5, color);
            if (q & 4 != 0) p.frac(0, 0.5, 0.5, 1, color);
            if (q & 8 != 0) p.frac(0.5, 0.5, 1, 1, color);
        },
        else => return false,
    }
    return true;
}

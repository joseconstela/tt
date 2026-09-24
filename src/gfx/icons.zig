//! Stroke icons from the design, stored as SVG path data (24×24 viewBox) and
//! rasterised with CoreGraphics into the shared alpha atlas.
const std = @import("std");
const apple = @import("../apple.zig");

pub const Icon = enum(u8) {
    sidebar,
    plus,
    search,
    bell,
    notebook,
    agent,
    folder,
    settings,
    close,
    terminal,
    file,
    chevron_right,
    chevron_down,
    image,
    document,
    // Settings pages.
    sun,
    /// Settings › Mode: rows pressed together.
    compact,
    drop,
    cloud,
    plug,
    sparkle,
    // Website tabs.
    globe,
    arrow_left,
    arrow_right,
    reload,
    lock,
    // Website permissions (camera, microphone).
    camera,
    mic,
    // Settings › Physical interactions.
    eye,
    // Git panel.
    check,
    minus,
    undo,
    branch,
    pull,
    push,
    // Search view.
    ellipsis,
    replace,
    collapse_all,
    expand_all,
    clear_all,
};

/// Transparent padding (device px) around every rasterised icon.
pub const pad_px: u32 = 2;
const stroke_width: f64 = 1.6;

fn pathData(icon: Icon) []const u8 {
    return switch (icon) {
        .sidebar => "M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M9 4v16",
        .plus => "M12 5v14M5 12h14",
        .search => "M4.5 11a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0-13 0 M20 20l-4.2-4.2",
        .bell => "M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z M10 21h4",
        .notebook => "M7 3h11a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H7z M4 7h3M4 12h3M4 17h3 M11 8h5M11 12h5",
        .agent => "M6 9h12a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-6a2 2 0 0 1 2-2z M12 9V5.5 M9.5 13.5v1.5M14.5 13.5v1.5 M11 4.5a1 1 0 1 0 2 0a1 1 0 1 0-2 0",
        .folder => "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
        .settings => "M4 7h9M17 7h3M4 17h3M11 17h9 M13 7a2 2 0 1 0 4 0a2 2 0 1 0-4 0 M7 17a2 2 0 1 0 4 0a2 2 0 1 0-4 0",
        .close => "M7 7l10 10M17 7L7 17",
        .terminal => "M5 7l5 5-5 5M12 17h7",
        .file => "M7 3h7l5 5v13H7z M14 3v5h5",
        .chevron_right => "M9 6l6 6-6 6",
        .chevron_down => "M6 9l6 6 6-6",
        .image => "M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M3 17l5-5 4 4 3-3 6 6 M15 9.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0",
        .document => "M7 3h7l5 5v13H7z M14 3v5h5 M10 13h6M10 16.5h6",
        .sun => "M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4l1.4-1.4M17 7l1.4-1.4 M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8",
        .compact => "M4 4h16 M4 20h16 M4 12h16 M12 6.5v3l-2-2M12 9.5l2-2 M12 17.5v-3l-2 2M12 14.5l2 2",
        .drop => "M12 3.5c0 0 6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z",
        .cloud => "M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z",
        .plug => "M9 3v4M15 3v4 M6 7h12v3a6 6 0 0 1-12 0z M12 16v5",
        .sparkle => "M11 3l1.9 5.6L18.5 10.5l-5.6 1.9L11 18l-1.9-5.6L3.5 10.5l5.6-1.9z M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z",
        .globe => "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M3 12h18 M12 3a14 14 0 0 0 0 18 M12 3a14 14 0 0 1 0 18",
        .arrow_left => "M19 12H5 M11 18l-6-6 6-6",
        .arrow_right => "M5 12h14 M13 6l6 6-6 6",
        .reload => "M20.5 12a8.5 8.5 0 1 1-2.5-6 M20.5 3.5V9h-5.5",
        .lock => "M6 11h12v9H6z M9 11V7.5a3 3 0 0 1 6 0V11",
        .camera => "M4.5 7h9a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2z M15.5 10.5L21 7.5v9l-5.5-3",
        .mic => "M9 6a3 3 0 0 1 6 0v5a3 3 0 0 1-6 0z M5.5 11a6.5 6.5 0 0 0 13 0 M12 17.5V21 M9 21h6",
        .eye => "M2.5 12C5.5 7.3 8.6 5.5 12 5.5C15.4 5.5 18.5 7.3 21.5 12C18.5 16.7 15.4 18.5 12 18.5C8.6 18.5 5.5 16.7 2.5 12z M9 12a3 3 0 1 0 6 0a3 3 0 1 0-6 0",
        .check => "M5 12.5l4.5 4.5L19 7",
        .minus => "M5 12h14",
        .undo => "M9 14L4 9l5-5 M4 9h10a6 6 0 0 1 0 12h-3",
        .branch => "M6 3v12 M18 9a3 3 0 1 0 0-6a3 3 0 1 0 0 6 M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6 M18 9a9 9 0 0 1-9 9",
        .pull => "M12 4v11 M7.5 10.5L12 15l4.5-4.5 M4 19.5h16",
        .push => "M12 15V4 M7.5 8.5L12 4l4.5 4.5 M4 19.5h16",
        .ellipsis => "M4 12a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0 M10.8 12a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0 M17.6 12a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0",
        .replace => "M4 8h11 M12 4.5L15.5 8 12 11.5 M20 16H9 M12 12.5L8.5 16l3.5 3.5",
        .collapse_all => "M5 5h14v14H5z M9 12h6",
        .expand_all => "M5 5h14v14H5z M9 12h6 M12 9v6",
        .clear_all => "M4 6h11 M4 11h8 M4 16h6 M14 14l6 6 M20 14l-6 6",
    };
}

/// Strokes `icon` into `ctx`. The caller has set up the CTM so that SVG user
/// space (y down, 24 units) maps onto the target box.
pub fn stroke(ctx: apple.CGContextRef, icon: Icon) void {
    apple.CGContextSetLineWidth(ctx, stroke_width);
    apple.CGContextSetLineCap(ctx, apple.kCGLineCapRound);
    apple.CGContextSetLineJoin(ctx, apple.kCGLineJoinRound);
    apple.CGContextSetGrayStrokeColor(ctx, 1, 1);
    apple.CGContextBeginPath(ctx);
    var p = PathParser{ .src = pathData(icon), .ctx = ctx };
    p.run();
    apple.CGContextStrokePath(ctx);
}

const PathParser = struct {
    src: []const u8,
    ctx: apple.CGContextRef,
    i: usize = 0,
    cx: f64 = 0,
    cy: f64 = 0,
    sx: f64 = 0,
    sy: f64 = 0,

    fn skipSep(self: *PathParser) void {
        while (self.i < self.src.len and (self.src[self.i] == ' ' or self.src[self.i] == ',' or self.src[self.i] == '\n')) self.i += 1;
    }

    fn hasNumber(self: *PathParser) bool {
        self.skipSep();
        if (self.i >= self.src.len) return false;
        const c = self.src[self.i];
        return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
    }

    fn number(self: *PathParser) f64 {
        self.skipSep();
        const start = self.i;
        if (self.i < self.src.len and (self.src[self.i] == '-' or self.src[self.i] == '+')) self.i += 1;
        var seen_dot = false;
        while (self.i < self.src.len) : (self.i += 1) {
            const c = self.src[self.i];
            if (c >= '0' and c <= '9') continue;
            if (c == '.' and !seen_dot) {
                seen_dot = true;
                continue;
            }
            break;
        }
        return std.fmt.parseFloat(f64, self.src[start..self.i]) catch 0;
    }

    fn moveTo(self: *PathParser, x: f64, y: f64) void {
        apple.CGContextMoveToPoint(self.ctx, x, y);
        self.cx = x;
        self.cy = y;
        self.sx = x;
        self.sy = y;
    }

    fn lineTo(self: *PathParser, x: f64, y: f64) void {
        apple.CGContextAddLineToPoint(self.ctx, x, y);
        self.cx = x;
        self.cy = y;
    }

    fn run(self: *PathParser) void {
        var cmd: u8 = 0;
        while (true) {
            self.skipSep();
            if (self.i >= self.src.len) break;
            const c = self.src[self.i];
            if (std.ascii.isAlphabetic(c)) {
                cmd = c;
                self.i += 1;
            } else if (cmd == 0) break;
            const rel = std.ascii.isLower(cmd);
            switch (std.ascii.toUpper(cmd)) {
                'M' => {
                    var x = self.number();
                    var y = self.number();
                    if (rel) {
                        x += self.cx;
                        y += self.cy;
                    }
                    self.moveTo(x, y);
                    // Subsequent pairs are implicit line-tos.
                    cmd = if (rel) 'l' else 'L';
                },
                'L' => {
                    var x = self.number();
                    var y = self.number();
                    if (rel) {
                        x += self.cx;
                        y += self.cy;
                    }
                    self.lineTo(x, y);
                },
                'H' => {
                    var x = self.number();
                    if (rel) x += self.cx;
                    self.lineTo(x, self.cy);
                },
                'V' => {
                    var y = self.number();
                    if (rel) y += self.cy;
                    self.lineTo(self.cx, y);
                },
                'C' => {
                    var v: [6]f64 = undefined;
                    for (&v) |*n| n.* = self.number();
                    if (rel) {
                        v[0] += self.cx;
                        v[2] += self.cx;
                        v[4] += self.cx;
                        v[1] += self.cy;
                        v[3] += self.cy;
                        v[5] += self.cy;
                    }
                    apple.CGContextAddCurveToPoint(self.ctx, v[0], v[1], v[2], v[3], v[4], v[5]);
                    self.cx = v[4];
                    self.cy = v[5];
                },
                'A' => {
                    const rx = self.number();
                    const ry = self.number();
                    const rot = self.number();
                    const large = self.number() != 0;
                    const sweep = self.number() != 0;
                    var x = self.number();
                    var y = self.number();
                    if (rel) {
                        x += self.cx;
                        y += self.cy;
                    }
                    self.arcTo(rx, ry, rot, large, sweep, x, y);
                },
                'Z' => {
                    apple.CGContextClosePath(self.ctx);
                    self.cx = self.sx;
                    self.cy = self.sy;
                    // A command letter must follow; avoid looping on stray numbers.
                    if (self.hasNumber()) break;
                },
                else => break,
            }
        }
    }

    /// SVG endpoint-parameterised arc → cubic Béziers (SVG 1.1 appendix F.6).
    fn arcTo(self: *PathParser, rx_in: f64, ry_in: f64, rot_deg: f64, large: bool, sweep: bool, x2: f64, y2: f64) void {
        const x1 = self.cx;
        const y1 = self.cy;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0 or (x1 == x2 and y1 == y2)) {
            self.lineTo(x2, y2);
            return;
        }
        const phi = rot_deg * std.math.pi / 180.0;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);
        const dx = (x1 - x2) / 2;
        const dy = (y1 - y2) / 2;
        const x1p = cos_phi * dx + sin_phi * dy;
        const y1p = -sin_phi * dx + cos_phi * dy;
        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1) {
            const s = @sqrt(lambda);
            rx *= s;
            ry *= s;
        }
        const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        var coef = @sqrt(@max(0, num / den));
        if (large == sweep) coef = -coef;
        const cxp = coef * (rx * y1p / ry);
        const cyp = coef * -(ry * x1p / rx);
        const ccx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2;
        const ccy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2;

        const theta1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
        var dtheta = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - theta1;
        if (sweep and dtheta < 0) dtheta += 2 * std.math.pi;
        if (!sweep and dtheta > 0) dtheta -= 2 * std.math.pi;

        const segs: usize = @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 2.0) - 1e-9));
        const n = @max(segs, 1);
        const delta = dtheta / @as(f64, @floatFromInt(n));
        const t = 4.0 / 3.0 * @tan(delta / 4);
        var th = theta1;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const c1 = @cos(th);
            const s1 = @sin(th);
            const c2 = @cos(th + delta);
            const s2 = @sin(th + delta);
            // Points on the unit circle, scaled/rotated into place.
            const p1x = c1 - t * s1;
            const p1y = s1 + t * c1;
            const p2x = c2 + t * s2;
            const p2y = s2 - t * c2;
            const pts = [_][2]f64{ .{ p1x, p1y }, .{ p2x, p2y }, .{ c2, s2 } };
            var out: [3][2]f64 = undefined;
            for (pts, 0..) |pt, idx| {
                const ex = pt[0] * rx;
                const ey = pt[1] * ry;
                out[idx] = .{ cos_phi * ex - sin_phi * ey + ccx, sin_phi * ex + cos_phi * ey + ccy };
            }
            apple.CGContextAddCurveToPoint(self.ctx, out[0][0], out[0][1], out[1][0], out[1][1], out[2][0], out[2][1]);
            th += delta;
        }
        self.cx = x2;
        self.cy = y2;
    }
};

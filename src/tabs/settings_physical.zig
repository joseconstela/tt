//! Settings › Physical interactions › Camera & posture: the camera tt
//! watches with (which one, and whether macOS lets it), a live preview of
//! what it recognises — the face with its landmarks and head pose, the
//! body's skeleton, and what they add up to — and what tt does with it:
//! for now, blurring the window while nobody looks at it. The decisions are
//! physical/camera_controller.zig's; this page shows them and sets them.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const icons = @import("../gfx/icons.zig");
const image = @import("../gfx/image.zig");
const texture = @import("../gfx/texture.zig");
const config = @import("../config.zig");
const media = @import("../platform/media.zig");
const camera_controller = @import("../physical/camera_controller.zig");
const posture = @import("../physical/posture.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const row_h: f32 = 40;
const card_pad: f32 = 18; // the regular block padding, in compact mode too
/// Height of a card's title and hint lines.
const card_head: f32 = 70;
const dd_w: f32 = 280;
const dd_h: f32 = 32;
/// The preview is at most this tall; narrower when that is what fits.
const preview_max_h: f32 = 360;
const white = Color.hex(0xffffff);

/// The delays the blur can wait, in seconds.
const delays = [_]f32{ 1, 3, 5, 10 };
const delay_labels = [_][]const u8{ "1 s", "3 s", "5 s", "10 s" };

pub const Page = struct {
    gpa: std.mem.Allocator,
    /// Null without a renderer (tests): the preview then shows no picture.
    textures: ?*texture.Textures,
    cameras: []media.Device = &.{},
    /// When the camera list and macOS's answer were last read.
    polled: f64 = -1000,
    access: media.Access = .not_determined,
    /// The latest preview frame and its texture.
    frame: image.Bitmap = .{ .width = 0, .height = 0, .pixels = &.{} },
    frame_seq: u64 = 0,
    tex: texture.Texture = .{},
    /// "Calibrate" was pressed: what came of it, shown for a moment.
    calibrated_at: f64 = -1000,
    calibrate_ok: bool = false,
    /// The source dropdown's generated labels (its menu borrows them).
    auto_buf: [300]u8 = undefined,
    missing_buf: [300]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, textures: ?*texture.Textures) Page {
        return .{ .gpa = gpa, .textures = textures };
    }

    pub fn deinit(self: *Page) void {
        media.freeDevices(self.gpa, self.cameras);
        self.frame.deinit(self.gpa);
        if (self.textures) |t| t.release(&self.tex);
    }

    /// While the page is on show: keeps the preview coming, and reads the
    /// cameras and macOS's answer again every few seconds (a USB camera
    /// comes and goes, the answer changes in System Settings). Not while
    /// the source menu is open: it borrows the names. True when something
    /// changed.
    pub fn tick(self: *Page, now: f64, menu_open: bool) bool {
        camera_controller.get().requestPreview(now);
        if (now - self.polled < 2.5) return false;
        self.polled = now;
        const acc = media.access(.camera);
        var changed = acc != self.access;
        self.access = acc;
        if (!menu_open) {
            const cams = media.devices(self.gpa, .camera);
            if (!sameDevices(cams, self.cameras)) changed = true;
            media.freeDevices(self.gpa, self.cameras);
            self.cameras = cams;
        }
        return changed;
    }

    pub fn draw(self: *Page, ui: *Ui, dd: *field.Dropdown, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        if (self.polled < 0) _ = self.tick(now, dd.isOpen());
        self.pullFrame();
        var y = y0;
        y = self.drawSource(ui, dd, x, y, col_w);
        y += theme.block_gap;
        y = self.drawPreview(ui, x, y, col_w, now);
        y += theme.block_gap;
        y = drawBlur(ui, x, y, col_w, now);
        return y;
    }

    /// Takes the newest preview frame into the texture.
    fn pullFrame(self: *Page) void {
        const ctl = camera_controller.get();
        const textures = self.textures orelse return;
        if (ctl.status != .running) {
            // The last picture belongs to a capture that ended.
            textures.release(&self.tex);
            return;
        }
        const seq = ctl.takePreview(self.gpa, &self.frame, self.frame_seq) orelse return;
        self.frame_seq = seq;
        textures.release(&self.tex);
        self.tex = textures.upload(self.frame) catch .{};
    }

    // ── the camera ──────────────────────────────────────────────────────
    fn drawSource(self: *Page, ui: *Ui, dd: *field.Dropdown, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const ctl = camera_controller.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 2 * row_h + card_pad - 6 };
        cardHead(ui, card, "Camera", "The camera tt watches with. Its frames are analysed on this Mac by macOS's Vision and never kept.");

        // Source: automatic (the macOS default), or one camera by name.
        var cy = card.y + card_head + row_h / 2;
        dl.icon(.camera, card.x + card_pad, cy - 8, 16, theme.text_2);
        _ = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Source", theme.text);
        var choices: [field.Dropdown.max_choices]field.Choice = undefined;
        const default_name = for (self.cameras) |d| {
            if (d.is_default) break d.name;
        } else "";
        choices[0] = .{ .label = if (default_name.len > 0) (std.fmt.bufPrint(&self.auto_buf, "Automatic · {s}", .{default_name}) catch "Automatic") else "Automatic" };
        var n: usize = 1;
        var selected: usize = 0;
        for (self.cameras) |d| {
            if (n >= choices.len - 1) break;
            choices[n] = .{ .label = d.name, .sep_before = n == 1 };
            if (std.mem.eql(u8, cfg.physical.camera, d.name)) selected = n;
            n += 1;
        }
        // A camera picked before and not connected now keeps its row.
        if (cfg.physical.camera.len > 0 and selected == 0) {
            choices[n] = .{ .label = std.fmt.bufPrint(&self.missing_buf, "{s} · not connected", .{cfg.physical.camera}) catch cfg.physical.camera, .sep_before = true };
            selected = n;
            n += 1;
        }
        const r: Rect = .{ .x = card.right() - card_pad - dd_w, .y = cy - dd_h / 2, .w = dd_w, .h = dd_h };
        if (field.dropdown(ui, dd, Ui.id("settings.physical.source", 0), r, choices[0..n], selected)) |i| {
            if (i == 0) {
                cfg.setString(&cfg.physical.camera, "");
            } else if (i - 1 < self.cameras.len) {
                cfg.setString(&cfg.physical.camera, self.cameras[i - 1].name);
            }
            cfg.save();
        }

        // macOS's permission, and what can be done about it.
        cy += row_h;
        dl.icon(.lock, card.x + card_pad, cy - 8, 16, theme.text_2);
        const lw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "macOS access", theme.text);
        const px = card.x + card_pad + 26 + lw + 10;
        if (ctl.usesStillImage()) {
            _ = pill(ui, px, cy, "A still image stands in (TT_CAMERA_MOCK)", .neutral);
        } else {
            _ = pill(ui, px, cy, self.access.label(), switch (self.access) {
                .authorized => .good,
                .denied, .restricted => .bad,
                .not_determined => .neutral,
            });
            const label: ?[]const u8 = switch (self.access) {
                .not_determined => "Ask macOS",
                .denied => "Open System Settings",
                .authorized, .restricted => null,
            };
            if (label) |l| {
                if (button(ui, Ui.id("settings.physical.access", 0), card.right() - card_pad, cy, l)) self.askMacos();
            }
        }
        return card.bottom();
    }

    fn askMacos(self: *Page) void {
        if (self.access == .not_determined) media.requestAccess(.camera) else media.openPrivacySettings(.camera);
        // Read the answer again soon.
        self.polled = -1000;
        camera_controller.get().recheckAccess();
    }

    // ── what the camera sees ────────────────────────────────────────────
    fn drawPreview(self: *Page, ui: *Ui, x: f32, y: f32, col_w: f32, now: f64) f32 {
        const dl = ui.dl;
        const ctl = camera_controller.get();
        const inner_w = col_w - 2 * card_pad;
        const aspect: f32 = if (self.frame.width > 0 and self.frame.height > 0)
            @as(f32, @floatFromInt(self.frame.width)) / @as(f32, @floatFromInt(self.frame.height))
        else
            4.0 / 3.0;
        var pw = inner_w;
        var ph = pw / aspect;
        if (ph > preview_max_h) {
            ph = preview_max_h;
            pw = ph * aspect;
        }
        const status_h: f32 = 74;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + ph + status_h };
        cardHead(ui, card, "What tt sees", "Mirrored, like a mirror: the face with its landmarks, the skeleton, and what they add up to.");

        const box: Rect = .{ .x = card.x + card_pad, .y = card.y + card_head, .w = inner_w, .h = ph };
        dl.rrect(box, 8, theme.bg_inset);
        const img: Rect = .{ .x = box.x + (inner_w - pw) / 2, .y = box.y, .w = pw, .h = ph };
        if (self.tex.valid() and ctl.status == .running) {
            dl.imageUv(img, self.tex, .{ 1, 0, 0, 1 }, white);
            dl.pushClip(img);
            drawOverlay(ui, img, &ctl.obs, ctl.posture);
            dl.popClip();
        } else {
            self.drawPlaceholder(ui, box);
        }

        // What it adds up to, and the calibration.
        const cfg = config.get();
        const live = ctl.live(now);
        var cy = box.bottom() + 24;
        var tx = card.x + card_pad;
        if (live) {
            const p = ctl.posture;
            tx = pill(ui, tx, cy, p.gaze.label(), switch (p.gaze) {
                .looking => .good,
                .away => .bad,
                .absent => .neutral,
            }) + 10;
            if (p.stance != .absent) _ = dl.textCentered(theme.font_ui, tx, cy, p.stance.label(), theme.text);
        } else {
            _ = dl.textCentered(theme.font_ui, tx, cy, "Nothing recognised yet.", theme.text_3);
        }
        // Right to left: Calibrate, then Reset when there is a calibration.
        if (live) {
            const cal_label = if (now - self.calibrated_at < 3) (if (self.calibrate_ok) "Calibrated" else "No face in view") else "Calibrate";
            const right = card.right() - card_pad;
            if (button(ui, Ui.id("settings.physical.calibrate", 0), right, cy, cal_label)) {
                self.calibrate_ok = ctl.calibrate();
                self.calibrated_at = now;
            }
            if (cfg.physical.calibration.isSet()) {
                const rx = right - (ui.text.measure(theme.font_hint, cal_label) + 24) - 8;
                const rw = ui.text.measure(theme.font_hint, "Reset") + 20;
                if (field.textButton(ui, Ui.id("settings.physical.calibrate", 1), .{ .x = rx - rw, .y = cy - 12, .w = rw, .h = 24 }, "Reset", theme.text_2)) ctl.resetCalibration();
            }
        }

        cy += 28;
        var detail_buf: [200]u8 = undefined;
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, cy, detailLine(&detail_buf, ctl, cfg, live), card.w - 2 * card_pad, theme.text_3);
        return card.bottom();
    }

    fn drawPlaceholder(self: *Page, ui: *Ui, box: Rect) void {
        const dl = ui.dl;
        const ctl = camera_controller.get();
        const text: []const u8 = if (!ctl.allow_device and !ctl.usesStillImage())
            "No camera in headless runs: TT_CAMERA_MOCK sets a picture."
        else switch (ctl.status) {
            .no_access => switch (self.access) {
                .denied, .restricted => "macOS does not let tt use the camera.",
                else => "tt needs macOS's permission to use the camera.",
            },
            .no_camera => "No camera is connected.",
            .failed => "The camera could not be started. Another app may be holding it.",
            .starting => "Starting the camera…",
            .running => "Waiting for the first picture…",
            .off => "The camera is off.",
        };
        const cy = box.y + box.h / 2;
        dl.icon(.camera, box.x + box.w / 2 - 12, cy - 44, 24, theme.text_3);
        const tw = ui.text.measure(theme.font_ui, text);
        _ = dl.textCentered(theme.font_ui, box.x + (box.w - tw) / 2, cy, text, theme.text_2);
        if (ctl.status == .no_access and !ctl.usesStillImage() and ctl.allow_device) {
            const label = if (self.access == .not_determined) "Ask macOS" else "Open System Settings";
            const bw = ui.text.measure(theme.font_hint, label) + 24;
            if (button(ui, Ui.id("settings.physical.access", 1), box.x + (box.w + bw) / 2, cy + 36, label)) self.askMacos();
        }
    }

};

// ── blur when away ──────────────────────────────────────────────────────
fn drawBlur(ui: *Ui, x: f32, y: f32, col_w: f32, now: f64) f32 {
    const dl = ui.dl;
    const cfg = config.get();
    const ph = &cfg.physical;
    const ctl = camera_controller.get();
    const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 3 * row_h + card_pad - 6 };
    cardHead(ui, card, "Blur when you look away", "The window blurs while nobody looks at it, and clears the moment you look back.");
    var cy = card.y + card_head + row_h / 2;

    if (switchRow(ui, Ui.id("settings.physical.blur", 0), card, cy, .eye, "Blur the window", "Typing or moving the pointer counts as looking.", ph.blur_when_away)) {
        ph.blur_when_away = !ph.blur_when_away;
        // Turning it on is the moment to ask macOS, if it never was.
        if (ph.blur_when_away and !ctl.usesStillImage() and media.access(.camera) == .not_determined) media.requestAccess(.camera);
        ctl.recheckAccess();
        cfg.save();
    }

    cy += row_h;
    dl.icon(.reload, card.x + card_pad, cy - 8, 16, theme.text_2);
    _ = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "After", theme.text);
    {
        var w: f32 = 0;
        for (delay_labels) |l| w += field.chipWidth(ui, l) + 6;
        var cx = card.right() - card_pad - w + 6;
        for (delays, delay_labels, 0..) |d, l, k| {
            const cw = field.chipWidth(ui, l);
            if (field.chip(ui, Ui.id("settings.physical.delay", k), .{ .x = cx, .y = cy - 13, .w = cw, .h = 26 }, l, @abs(ph.blur_after - d) < 0.01)) {
                ph.blur_after = d;
                cfg.save();
            }
            cx += cw + 6;
        }
    }

    cy += row_h;
    dl.icon(.sparkle, card.x + card_pad, cy - 8, 16, theme.text_2);
    const sw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Sensitivity", theme.text);
    {
        const values = std.enums.values(posture.Sensitivity);
        var w: f32 = 0;
        for (values) |v| w += field.chipWidth(ui, v.label()) + 6;
        var cx = card.right() - card_pad - w + 6;
        var hint_buf: [96]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Away past {d:.0}° turned or {d:.0}° nodding.", .{ ph.sensitivity.yawLimit(), ph.sensitivity.pitchLimit() }) catch "";
        const hx = card.x + card_pad + 26 + sw + 12;
        _ = dl.textEllipsis(theme.font_hint, hx, cy, hint, cx - 12 - hx, theme.text_3);
        for (values, 0..) |v, k| {
            const cw = field.chipWidth(ui, v.label());
            if (field.chip(ui, Ui.id("settings.physical.sensitivity", k), .{ .x = cx, .y = cy - 13, .w = cw, .h = 26 }, v.label(), ph.sensitivity == v)) {
                ph.sensitivity = v;
                cfg.save();
                ctl.reanalyse();
            }
            cx += cw + 6;
        }
    }

    // What the blur is doing right now.
    const note: []const u8 = if (!ph.blur_when_away)
        "Off: the camera only runs while this page is on show."
    else if (ctl.blurred)
        "Blurred now: nobody is looking."
    else if (ctl.live(now))
        (if (ctl.posture.gaze == .looking) "On: you are looking, so the window is clear." else "On: the window blurs if nobody looks for a moment.")
    else switch (ctl.status) {
        .no_access => "On, but macOS has not let tt use the camera yet.",
        .no_camera => "On, but no camera is connected.",
        .failed => "On, but the camera could not be started.",
        else => "On: starting the camera…",
    };
    _ = dl.textCentered(theme.font_hint, card.x + card_pad, card.bottom() + 20, note, theme.text_3);
    return card.bottom() + 30;
}

// ── the preview's drawing ───────────────────────────────────────────────

/// A normalised frame point on the mirrored picture.
fn onPicture(img: Rect, p: posture.Point) struct { x: f32, y: f32 } {
    return .{ .x = img.x + (1 - p.x) * img.w, .y = img.y + p.y * img.h };
}

/// The skeleton, the face's box (accent while looking, red away) and its
/// landmarks, over the picture.
fn drawOverlay(ui: *Ui, img: Rect, obs: *const posture.Observation, p: posture.Posture) void {
    const dl = ui.dl;
    for (posture.bones) |b| {
        const a = obs.joint(b[0]);
        const c = obs.joint(b[1]);
        if (!a.seen() or !c.seen()) continue;
        const pa = onPicture(img, a);
        const pc = onPicture(img, c);
        dottedLine(ui, pa.x, pa.y, pc.x, pc.y, theme.teal);
    }
    for (std.enums.values(posture.Joint)) |j| {
        const q = obs.joint(j);
        if (!q.seen()) continue;
        const s = onPicture(img, q);
        dl.circle(s.x, s.y, 4.5, theme.teal);
        dl.circle(s.x, s.y, 2, white);
    }
    const f = obs.face orelse return;
    const color = if (p.gaze == .looking) theme.accent else theme.red;
    const box: Rect = .{ .x = img.x + (1 - f.x - f.w) * img.w, .y = img.y + f.y * img.h, .w = f.w * img.w, .h = f.h * img.h };
    dl.border(box, 10, 2, color);
    for (f.landmarks[0..f.landmark_count]) |m| {
        const s = onPicture(img, m);
        dl.circle(s.x, s.y, 1.4, white.alpha(0.9));
    }
    // The head's angles on a tag above the box.
    var buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "{s} · yaw {d:.0}° · pitch {d:.0}°", .{
        if (p.gaze == .looking) "Looking" else "Away",
        whole(p.yaw),
        whole(p.pitch),
    }) catch "";
    const tw = ui.text.measure(theme.font_chip, tag);
    // Over the box's left edge, kept inside the picture.
    const tag_x = std.math.clamp(box.x, img.x + 4, @max(img.x + 4, img.right() - tw - 14 - 4));
    const t: Rect = .{ .x = tag_x, .y = @max(img.y + 4, box.y - 26), .w = tw + 14, .h = 20 };
    dl.rrect(t, 6, color);
    _ = dl.textCentered(theme.font_chip, t.x + 7, t.centerY(), tag, theme.on_accent);
}

/// DrawList has no lines: a row of dots does for a bone.
fn dottedLine(ui: *Ui, x0: f32, y0: f32, x1: f32, y1: f32, color: Color) void {
    const len = @sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
    const steps: usize = @max(1, @as(usize, @intFromFloat(len / 4)));
    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        ui.dl.circle(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 1.6, color);
    }
}

/// The numbers under the preview: the head's angles against the
/// calibration and the shoulders, or how to calibrate.
fn detailLine(buf: []u8, ctl: *const camera_controller.Controller, cfg: *const config.Config, live: bool) []const u8 {
    const cal = cfg.physical.calibration;
    const how = "Look at the middle of the screen and press Calibrate: that becomes \"looking\".";
    if (!live) return how;
    const p = ctl.posture;
    var w: std.Io.Writer = .fixed(buf);
    if (p.yaw != null or p.pitch != null) {
        w.print("Head: yaw {d:.0}°, pitch {d:.0}°, roll {d:.0}°", .{ whole(p.yaw), whole(p.pitch), whole(p.roll) }) catch {};
    } else w.writeAll("No face") catch {};
    if (p.shoulder_tilt) |t| w.print(" · shoulders {d:.0}°", .{whole(t)}) catch {};
    if (p.distance) |d| w.print(" · {d:.0}% of the calibrated size", .{d * 100}) catch {};
    w.writeAll(if (cal.isSet()) " · calibrated" else " · not calibrated: straight at the camera is looking") catch {};
    return w.buffered();
}

// ── small parts ─────────────────────────────────────────────────────────

/// Degrees to show: rounded, and never "-0".
fn whole(deg: ?f32) f32 {
    return @round(deg orelse 0) + 0.0;
}

fn cardHead(ui: *Ui, card: Rect, title: []const u8, hint: []const u8) void {
    const dl = ui.dl;
    dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
    _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, title, theme.text);
    _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, hint, card.w - 2 * card_pad, theme.text_3);
}

const Tone = enum { good, bad, neutral };

/// A small rounded tag; returns its right edge.
fn pill(ui: *Ui, x: f32, cy: f32, text: []const u8, tone: Tone) f32 {
    const tw = ui.text.measure(theme.font_chip, text);
    const r: Rect = .{ .x = x, .y = cy - 9, .w = tw + 14, .h = 18 };
    const bg: Color = switch (tone) {
        .good => theme.accent.alpha(0.16),
        .bad => theme.red.alpha(0.16),
        .neutral => theme.chip_active,
    };
    ui.dl.rrect(r, 9, bg);
    _ = ui.dl.textCentered(theme.font_chip, r.x + 7, cy, text, if (tone == .neutral) theme.text_3 else theme.text);
    return r.right();
}

/// An outlined button ending at `right`, centred on `cy`. True when clicked.
fn button(ui: *Ui, wid: u64, right: f32, cy: f32, label: []const u8) bool {
    const bw = ui.text.measure(theme.font_hint, label) + 24;
    const r: Rect = .{ .x = right - bw, .y = cy - 13, .w = bw, .h = 26 };
    ui.dl.shape(r, 7, theme.bg_block, 1, theme.line_strong);
    return field.textButton(ui, wid, r, label, theme.text);
}

/// An on/off row: an icon, the label and a dim detail, a switch at the
/// right. True when clicked.
fn switchRow(ui: *Ui, wid: u64, card: Rect, cy: f32, icon: icons.Icon, label: []const u8, detail: []const u8, on: bool) bool {
    const dl = ui.dl;
    const r: Rect = .{ .x = card.x + 8, .y = cy - row_h / 2, .w = card.w - 16, .h = row_h };
    const st = ui.button(wid, r);
    ui.feedback(r, 6, st);
    dl.icon(icon, card.x + card_pad, cy - 8, 16, theme.text_2);
    const toggle: Rect = .{ .x = card.right() - card_pad - 36, .y = cy - 10, .w = 36, .h = 20 };
    dl.rrect(toggle, 10, if (on) theme.accent else theme.line_strong);
    const knob_x = if (on) toggle.right() - 18 else toggle.x + 2;
    dl.rrect(.{ .x = knob_x, .y = toggle.y + 2, .w = 16, .h = 16 }, 8, if (on) theme.on_accent else theme.text_2);
    const lx = card.x + card_pad + 26;
    const lw = dl.textCentered(theme.font_ui, lx, cy, label, theme.text);
    _ = dl.textEllipsis(theme.font_hint, lx + lw + 12, cy, detail, toggle.x - 12 - (lx + lw + 12), theme.text_3);
    return st.clicked;
}

fn sameDevices(a: []const media.Device, b: []const media.Device) bool {
    if (a.len != b.len) return false;
    for (a, b) |p, q| {
        if (p.is_default != q.is_default or !std.mem.eql(u8, p.name, q.name)) return false;
    }
    return true;
}

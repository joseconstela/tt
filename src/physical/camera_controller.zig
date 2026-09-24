//! The camera controller: the one place that decides when tt's camera runs
//! and what the app gets out of it. Consumers ask for the camera — today
//! the away blur (`physical.blur_when_away` in the config) and the live
//! preview in Settings › Physical interactions — and the controller runs the
//! camera picked in Settings while any of them needs it, stops it when none
//! does, turns what Vision recognises into a `Posture`, and keeps the away
//! blur's decision (`blurred`). Later interactions (gestures, posture
//! reminders …) become consumers the same way and read `posture`.
//!
//! One instance for the whole app (`get()`): `App.update` ticks it, the
//! app's input reports activity (using the Mac counts as looking at it),
//! and the platform layer shows `blurred` over the window.
const std = @import("std");
const config = @import("../config.zig");
const camera = @import("../platform/camera.zig");
const media = @import("../platform/media.zig");
const posture = @import("posture.zig");
const image = @import("../gfx/image.zig");

pub const Status = camera.Status;

/// Seconds between two analyses: often enough to notice a look within a
/// frame or two, rare enough to leave the Mac alone.
const interval_blur: f64 = 1.0 / 8.0;
/// Livelier while the Settings page shows what is recognised.
const interval_preview: f64 = 1.0 / 12.0;
/// The preview is wanted this long after the Settings page last asked.
const preview_grace: f64 = 1.0;
/// A capture without a frame for this long is started again: the Mac
/// slept, or another app took the camera for a while.
const restart_after: f64 = 6;

pub const Controller = struct {
    /// Whether a real camera may be used. Headless scripts turn it off so
    /// a test never lights the camera; a mock image still runs.
    allow_device: bool = true,
    /// Until when the Settings page wants the preview (renewed while it is
    /// on show).
    preview_until: f64 = 0,
    running: bool = false,
    /// The camera name the running capture was started with ("" = default).
    running_name: [256]u8 = undefined,
    running_len: usize = 0,
    status: Status = .off,
    obs: posture.Observation = .{},
    posture: posture.Posture = .{},
    attention: posture.Attention = .{},
    /// The window should be blurred now (the away blur's decision).
    blurred: bool = false,
    /// macOS's answer about the camera, read again every few seconds.
    access_checked: f64 = -1000,
    access_ok: bool = false,
    preview_seq: u64 = 0,
    /// When the running capture was started (the last time, if restarted).
    started_at: f64 = 0,

    /// The Settings page is showing the preview (call on each of its ticks).
    pub fn requestPreview(self: *Controller, now: f64) void {
        self.preview_until = now + preview_grace;
    }

    pub fn previewWanted(self: *const Controller, now: f64) bool {
        return now < self.preview_until;
    }

    /// Keyboard or mouse input: someone is at the Mac, whatever the camera says.
    pub fn noteActivity(self: *Controller, now: f64) void {
        self.attention.activity(now);
    }

    /// Read macOS's answer again on the next tick (after asking it).
    pub fn recheckAccess(self: *Controller) void {
        self.access_checked = -1000;
    }

    /// Whether any consumer wants the camera now.
    fn wanted(self: *const Controller, now: f64) bool {
        return config.get().physical.blur_when_away or self.previewWanted(now);
    }

    fn mayRun(self: *const Controller) bool {
        if (camera.mocking()) return true;
        return self.allow_device and media.access(.camera) == .authorized;
    }

    fn runningName(self: *const Controller) []const u8 {
        return self.running_name[0..self.running_len];
    }

    /// Starts, switches and stops the camera for its consumers, reads what
    /// it recognised and decides the blur. True when the preview (or what
    /// the Settings page says about it) changed.
    pub fn tick(self: *Controller, now: f64) bool {
        const cfg = config.get();
        if (now - self.access_checked >= 2) {
            self.access_checked = now;
            self.access_ok = self.mayRun();
        }
        const want = self.wanted(now);
        const name = cfg.physical.camera;
        var changed = false;
        if (want and self.access_ok) {
            const stalled = self.running and now - @max(self.started_at, self.attention.seen_at) > restart_after;
            if (!self.running or stalled or !std.mem.eql(u8, name, self.runningName())) {
                self.startCamera(name, now);
                changed = true;
            }
        } else if (self.running) {
            self.stopCamera();
            changed = true;
        }

        const st: Status = if (self.running) camera.status() else if (want and !self.access_ok) .no_access else .off;
        if (st != self.status) {
            self.status = st;
            changed = true;
        }
        if (self.running) {
            const preview = self.previewWanted(now);
            camera.setWantPreview(preview);
            camera.setInterval(if (preview) interval_preview else interval_blur);
            const ps = camera.previewSeq();
            if (preview and ps != self.preview_seq) {
                self.preview_seq = ps;
                changed = true;
            }
            const obs = camera.latest();
            if (obs.seq != 0 and obs.seq != self.obs.seq) {
                self.obs = obs;
                self.posture = posture.analyze(&self.obs, cfg.physical.calibration, cfg.physical.sensitivity, self.posture.gaze);
                self.attention.observe(now, self.posture.gaze);
                changed = true;
            }
        }

        const blur = self.running and cfg.physical.blur_when_away and self.attention.update(now, cfg.physical.blur_after);
        if (blur != self.blurred) {
            self.blurred = blur;
            changed = true;
        }
        return changed and self.previewWanted(now);
    }

    fn startCamera(self: *Controller, name: []const u8, now: f64) void {
        camera.start(name);
        self.running = true;
        self.started_at = now;
        self.running_len = @min(name.len, self.running_name.len);
        @memcpy(self.running_name[0..self.running_len], name[0..self.running_len]);
        self.forget();
    }

    fn stopCamera(self: *Controller) void {
        camera.stop();
        self.running = false;
        self.running_len = 0;
        self.forget();
    }

    /// What was seen belongs to the capture that ended; the input stays.
    fn forget(self: *Controller) void {
        self.obs = .{};
        self.posture = .{};
        self.attention = .{ .active_at = self.attention.active_at };
    }

    /// Frames are coming in (the camera is not only switched on).
    pub fn live(self: *const Controller, now: f64) bool {
        return self.running and self.obs.seq != 0 and self.attention.fresh(now);
    }

    /// What the camera sees now is "looking at the screen": the zero for
    /// the head's angles, its size and the shoulders. False without a face.
    pub fn calibrate(self: *Controller) bool {
        const cal = posture.calibrationFrom(&self.obs) orelse return false;
        const cfg = config.get();
        cfg.physical.calibration = cal;
        cfg.save();
        self.reanalyse();
        return true;
    }

    pub fn resetCalibration(self: *Controller) void {
        const cfg = config.get();
        cfg.physical.calibration = .{};
        cfg.save();
        self.reanalyse();
    }

    /// The settings changed (sensitivity, calibration): judge the last
    /// frame again rather than wait for the next.
    pub fn reanalyse(self: *Controller) void {
        if (self.obs.seq == 0) return;
        const cfg = config.get();
        self.posture = posture.analyze(&self.obs, cfg.physical.calibration, cfg.physical.sensitivity, self.posture.gaze);
    }

    /// The newest preview frame, when newer than `seq` (see `camera.takePreview`).
    pub fn takePreview(_: *Controller, gpa: std.mem.Allocator, out: *image.Bitmap, seq: u64) ?u64 {
        return camera.takePreview(gpa, out, seq);
    }

    /// The camera running, by name ("" when none is).
    pub fn cameraName(_: *const Controller, buf: []u8) []const u8 {
        return camera.runningName(buf);
    }

    /// True when a still image stands in for the camera (TT_CAMERA_MOCK).
    pub fn usesStillImage(_: *const Controller) bool {
        return camera.mocking();
    }

    /// Stops the camera (quitting).
    pub fn shutdown(self: *Controller) void {
        if (self.running) self.stopCamera();
    }
};

var instance: Controller = .{};

pub fn get() *Controller {
    return &instance;
}

//! What the camera sees, reduced to what tt reacts to. `platform/camera.zig`
//! fills an `Observation` from macOS's Vision framework (the nearest face
//! with its head pose and landmarks, a body's joints); `analyze` turns it
//! into a `Posture` — is someone looking at the screen, and how are they
//! sitting — measured against the user's own calibration; `Attention`
//! smooths that over time into the one decision the away blur needs.
//! Pure logic, no frameworks: unit-tested by `zig build test`.
const std = @import("std");

/// A point in the camera's frame, normalised to 0…1 from the frame's
/// top-left corner (Vision counts from the bottom-left; the camera code
/// flips it). The frame is as the camera sends it, not mirrored.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Vision's confidence; 0 = not seen.
    conf: f32 = 0,

    pub fn seen(self: Point) bool {
        return self.conf >= min_conf;
    }
};

/// Below this a joint is treated as not seen.
const min_conf: f32 = 0.3;

/// The body's joints tt reads, named from the person's own side: their
/// left shoulder is on the frame's right, as the camera faces them.
pub const Joint = enum(u8) {
    nose,
    left_eye,
    right_eye,
    left_ear,
    right_ear,
    neck,
    left_shoulder,
    right_shoulder,
    left_elbow,
    right_elbow,
    left_wrist,
    right_wrist,
    left_hip,
    right_hip,
    root,
};
pub const joint_count = @typeInfo(Joint).@"enum".fields.len;

/// The skeleton the preview draws, as pairs of joints.
pub const bones = [_][2]Joint{
    .{ .left_ear, .left_eye },
    .{ .left_eye, .nose },
    .{ .nose, .right_eye },
    .{ .right_eye, .right_ear },
    .{ .nose, .neck },
    .{ .neck, .left_shoulder },
    .{ .neck, .right_shoulder },
    .{ .left_shoulder, .left_elbow },
    .{ .left_elbow, .left_wrist },
    .{ .right_shoulder, .right_elbow },
    .{ .right_elbow, .right_wrist },
    .{ .neck, .root },
    .{ .root, .left_hip },
    .{ .root, .right_hip },
};

pub const max_landmarks = 96;

pub const Face = struct {
    /// The face's box, normalised like `Point`.
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// Head pose in degrees: yaw = turned to a side, pitch = nodding
    /// (positive = head down), roll = tilted toward a shoulder. Null when
    /// Vision could not tell.
    yaw: ?f32 = null,
    pitch: ?f32 = null,
    roll: ?f32 = null,
    confidence: f32 = 0,
    /// The outline, eyes, brows, nose and lips (Vision's `allPoints`),
    /// normalised like `Point`.
    landmarks: [max_landmarks]Point = [_]Point{.{}} ** max_landmarks,
    landmark_count: u8 = 0,
};

/// One analysed camera frame.
pub const Observation = struct {
    /// Counts the frames analysed; 0 = none yet.
    seq: u64 = 0,
    /// Faces in the frame; `face` is the biggest one (the nearest person).
    faces: u8 = 0,
    face: ?Face = null,
    /// The joints of the most confident body, by `Joint`.
    body: [joint_count]Point = [_]Point{.{}} ** joint_count,
    /// The frame's size in pixels (its aspect matters for angles).
    frame_w: u32 = 0,
    frame_h: u32 = 0,

    pub fn joint(self: *const Observation, j: Joint) Point {
        return self.body[@intFromEnum(j)];
    }

    /// Frame width over height (4:3 when unknown).
    fn aspect(self: *const Observation) f32 {
        if (self.frame_w == 0 or self.frame_h == 0) return 4.0 / 3.0;
        return @as(f32, @floatFromInt(self.frame_w)) / @as(f32, @floatFromInt(self.frame_h));
    }
};

/// How far the head may turn or nod from where it is while looking at
/// the screen before it counts as looking away.
pub const Sensitivity = enum {
    relaxed,
    normal,
    strict,

    pub fn label(self: Sensitivity) []const u8 {
        return switch (self) {
            .relaxed => "Relaxed",
            .normal => "Normal",
            .strict => "Strict",
        };
    }

    pub fn parse(s: []const u8) ?Sensitivity {
        for (std.enums.values(Sensitivity)) |v| {
            if (std.ascii.eqlIgnoreCase(s, @tagName(v))) return v;
        }
        return null;
    }

    /// Degrees of turn to either side.
    pub fn yawLimit(self: Sensitivity) f32 {
        return switch (self) {
            .relaxed => 38,
            .normal => 28,
            .strict => 18,
        };
    }

    /// Degrees of nod, up or down.
    pub fn pitchLimit(self: Sensitivity) f32 {
        return switch (self) {
            .relaxed => 32,
            .normal => 24,
            .strict => 16,
        };
    }
};

/// The head and shoulders while looking at the screen (Settings'
/// "Calibrate"). A camera above or beside the screen sees a head that looks
/// at the screen as nodding or turned a little; this is the zero.
pub const Calibration = struct {
    yaw: f32 = 0,
    pitch: f32 = 0,
    /// The face's width in the frame; 0 = not calibrated, and nearness is
    /// not judged.
    face_size: f32 = 0,
    /// How high the nose sits above the shoulders, in shoulder widths;
    /// 0 = unknown, and slouching is not judged.
    neck: f32 = 0,

    pub fn isSet(self: Calibration) bool {
        return self.face_size > 0;
    }
};

/// The calibration from what the camera sees now; null without a face.
pub fn calibrationFrom(obs: *const Observation) ?Calibration {
    const f = obs.face orelse return null;
    if (f.w <= 0) return null;
    return .{
        .yaw = f.yaw orelse 0,
        .pitch = f.pitch orelse 0,
        .face_size = f.w,
        .neck = neckRatio(obs) orelse 0,
    };
}

pub const Gaze = enum {
    /// A face, turned toward the screen.
    looking,
    /// Someone there, but turned or nodding away (or only their body seen).
    away,
    /// No one in view.
    absent,

    pub fn label(self: Gaze) []const u8 {
        return switch (self) {
            .looking => "Looking at the screen",
            .away => "Looking away",
            .absent => "No one in view",
        };
    }
};

/// How the person sits, as far as the camera can tell.
pub const Stance = enum {
    upright,
    turned_away,
    head_down,
    looking_up,
    leaning_in,
    leaning_back,
    slouching,
    leaning_left,
    leaning_right,
    head_tilted,
    absent,

    pub fn label(self: Stance) []const u8 {
        return switch (self) {
            .upright => "Sitting upright",
            .turned_away => "Turned away",
            .head_down => "Head down",
            .looking_up => "Looking up",
            .leaning_in => "Leaning in",
            .leaning_back => "Leaning back",
            .slouching => "Slouching",
            .leaning_left => "Leaning left",
            .leaning_right => "Leaning right",
            .head_tilted => "Head tilted",
            .absent => "Nobody there",
        };
    }
};

pub const Posture = struct {
    gaze: Gaze = .absent,
    stance: Stance = .absent,
    /// Head pose against the calibration, in degrees (see `Face`).
    yaw: ?f32 = null,
    pitch: ?f32 = null,
    roll: ?f32 = null,
    /// The shoulder line against the horizontal, in degrees; positive when
    /// the person's left shoulder is the lower one.
    shoulder_tilt: ?f32 = null,
    /// The face's size against the calibrated one (1 = as calibrated,
    /// more = nearer); null when not calibrated.
    distance: ?f32 = null,
};

/// Leaning in or back: the face this much bigger or smaller than calibrated.
const nearer: f32 = 1.3;
const farther: f32 = 0.75;
/// The nose this much lower over the shoulders than calibrated.
const slouch: f32 = 0.7;
/// Degrees of shoulder line or head tilt worth a word.
const lean_deg: f32 = 9;
const tilt_deg: f32 = 18;
/// Once looking, the limits widen by this much, so a head right at the
/// edge does not flicker between looking and away.
const hysteresis_deg: f32 = 4;

/// What `obs` means. `was` is the previous frame's gaze (for hysteresis).
pub fn analyze(obs: *const Observation, cal: Calibration, sens: Sensitivity, was: Gaze) Posture {
    var p: Posture = .{ .shoulder_tilt = shoulderTilt(obs) };
    const face = obs.face orelse {
        // A body without a face is someone turned away; nothing at all, gone.
        if (bodySeen(obs)) {
            p.gaze = .away;
            p.stance = .turned_away;
        }
        return p;
    };
    if (face.yaw) |y| p.yaw = y - cal.yaw;
    if (face.pitch) |v| p.pitch = v - cal.pitch;
    p.roll = face.roll;
    if (cal.face_size > 0 and face.w > 0) p.distance = face.w / cal.face_size;

    const margin: f32 = if (was == .looking) hysteresis_deg else 0;
    const turned = if (p.yaw) |y| @abs(y) > sens.yawLimit() + margin else false;
    const nodding = if (p.pitch) |v| @abs(v) > sens.pitchLimit() + margin else false;
    p.gaze = if (turned or nodding) .away else .looking;
    p.stance = if (turned)
        .turned_away
    else if (nodding)
        (if (p.pitch.? > 0) .head_down else .looking_up)
    else
        stanceOf(obs, &p, cal);
    return p;
}

/// The stance of someone facing the screen, the most telling thing first.
fn stanceOf(obs: *const Observation, p: *const Posture, cal: Calibration) Stance {
    if (p.distance) |d| {
        if (d > nearer) return .leaning_in;
        if (d < farther) return .leaning_back;
    }
    if (cal.neck > 0) {
        if (neckRatio(obs)) |n| if (n < cal.neck * slouch) return .slouching;
    }
    if (p.shoulder_tilt) |t| {
        if (t > lean_deg) return .leaning_left;
        if (t < -lean_deg) return .leaning_right;
    }
    if (p.roll) |r| if (@abs(r) > tilt_deg) return .head_tilted;
    return .upright;
}

/// Enough of a body (head and shoulders) to say someone is there.
fn bodySeen(obs: *const Observation) bool {
    var n: usize = 0;
    for ([_]Joint{ .nose, .left_eye, .right_eye, .left_ear, .right_ear, .neck, .left_shoulder, .right_shoulder }) |j| {
        if (obs.joint(j).seen()) n += 1;
    }
    return n >= 2;
}

/// The shoulder line's angle; null unless both shoulders are seen with
/// the person facing the camera (their left shoulder on the frame's right).
fn shoulderTilt(obs: *const Observation) ?f32 {
    const l = obs.joint(.left_shoulder);
    const r = obs.joint(.right_shoulder);
    if (!l.seen() or !r.seen()) return null;
    // In frame-height units on both axes, so the angle is true.
    const dx = (l.x - r.x) * obs.aspect();
    const dy = l.y - r.y;
    if (dx < 0.02) return null;
    return std.math.radiansToDegrees(std.math.atan2(dy, dx));
}

/// How high the nose is above the middle of the shoulders, in shoulder
/// widths (it drops as the person slouches).
fn neckRatio(obs: *const Observation) ?f32 {
    const n = obs.joint(.nose);
    const l = obs.joint(.left_shoulder);
    const r = obs.joint(.right_shoulder);
    if (!n.seen() or !l.seen() or !r.seen()) return null;
    const width = @abs(l.x - r.x) * obs.aspect();
    if (width < 0.05) return null;
    return ((l.y + r.y) / 2 - n.y) / width;
}

/// Turns frame-by-frame gazes into the away blur: it comes once nobody
/// has looked at the screen for `delay` seconds — typing or moving the
/// pointer counts as looking — and goes as soon as someone looks again.
/// Without fresh frames (the camera stalled or stopped) it never blurs: a
/// broken camera must not hide the work.
pub const Attention = struct {
    /// Since when nobody has looked; null while someone is looking.
    away_since: ?f64 = null,
    /// The last keyboard or mouse input.
    active_at: f64 = -1e9,
    /// When the last frame was analysed.
    seen_at: f64 = -1e9,
    blurred: bool = false,

    /// Seconds without a frame after which the camera is taken as gone.
    pub const stale_after: f64 = 3;

    pub fn observe(self: *Attention, now: f64, gaze: Gaze) void {
        self.seen_at = now;
        if (gaze == .looking) {
            self.away_since = null;
        } else if (self.away_since == null) {
            self.away_since = now;
        }
    }

    pub fn activity(self: *Attention, now: f64) void {
        self.active_at = now;
    }

    /// True while frames keep coming.
    pub fn fresh(self: *const Attention, now: f64) bool {
        return now - self.seen_at < stale_after;
    }

    /// Whether the window should be blurred now.
    pub fn update(self: *Attention, now: f64, delay: f64) bool {
        const since = self.away_since orelse {
            self.blurred = false;
            return false;
        };
        const from = @max(since, self.active_at);
        self.blurred = self.fresh(now) and now - from >= delay;
        return self.blurred;
    }
};

// ── tests ───────────────────────────────────────────────────────────────

fn faceObs(yaw: f32, pitch: f32, roll: f32, w: f32) Observation {
    return .{ .seq = 1, .faces = 1, .face = .{ .x = 0.4, .y = 0.3, .w = w, .h = w, .yaw = yaw, .pitch = pitch, .roll = roll, .confidence = 0.9 }, .frame_w = 640, .frame_h = 480 };
}

fn setJoint(obs: *Observation, j: Joint, x: f32, y: f32) void {
    obs.body[@intFromEnum(j)] = .{ .x = x, .y = y, .conf = 0.9 };
}

test "posture: a face turned toward the camera is looking; turned or nodding far enough is away" {
    const none: Calibration = .{};
    const front = faceObs(4, -3, 1, 0.25);
    const p = analyze(&front, none, .normal, .absent);
    try std.testing.expectEqual(Gaze.looking, p.gaze);
    try std.testing.expectEqual(Stance.upright, p.stance);

    const turned = faceObs(-55, 5, 0, 0.2);
    try std.testing.expectEqual(Stance.turned_away, analyze(&turned, none, .normal, .looking).stance);
    try std.testing.expectEqual(Gaze.away, analyze(&turned, none, .relaxed, .looking).gaze);

    // Positive pitch is a head nodding down (at the keyboard, a phone).
    const down = faceObs(0, 35, 0, 0.25);
    try std.testing.expectEqual(Stance.head_down, analyze(&down, none, .normal, .looking).stance);
    const up = faceObs(0, -35, 0, 0.25);
    try std.testing.expectEqual(Stance.looking_up, analyze(&up, none, .normal, .looking).stance);

    // The sensitivity moves the limit.
    const half = faceObs(22, 0, 0, 0.25);
    try std.testing.expectEqual(Gaze.looking, analyze(&half, none, .normal, .absent).gaze);
    try std.testing.expectEqual(Gaze.away, analyze(&half, none, .strict, .absent).gaze);
}

test "posture: the limits widen once looking, so the edge does not flicker" {
    const edge = faceObs(30, 0, 0, 0.25);
    try std.testing.expectEqual(Gaze.looking, analyze(&edge, .{}, .normal, .looking).gaze);
    try std.testing.expectEqual(Gaze.away, analyze(&edge, .{}, .normal, .away).gaze);
}

test "posture: the calibration is the zero for the head and the size" {
    // A camera beside the screen: looking at the screen reads as 25° turned.
    const cal: Calibration = .{ .yaw = 25, .pitch = 12, .face_size = 0.2 };
    const at_screen = faceObs(27, 10, 0, 0.21);
    const p = analyze(&at_screen, cal, .normal, .absent);
    try std.testing.expectEqual(Gaze.looking, p.gaze);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p.yaw.?, 0.001);
    try std.testing.expectEqual(Stance.upright, p.stance);
    // … so looking straight at the camera is away, and a bigger face is nearer.
    try std.testing.expectEqual(Gaze.away, analyze(&faceObs(-10, 10, 0, 0.2), cal, .normal, .absent).gaze);
    try std.testing.expectEqual(Stance.leaning_in, analyze(&faceObs(25, 12, 0, 0.3), cal, .normal, .absent).stance);
    try std.testing.expectEqual(Stance.leaning_back, analyze(&faceObs(25, 12, 0, 0.12), cal, .normal, .absent).stance);
}

test "posture: shoulders, slouching and a tilted head" {
    var obs = faceObs(0, 0, 0, 0.25);
    // The person's left shoulder is on the frame's right; lower = bigger y.
    setJoint(&obs, .nose, 0.5, 0.35);
    setJoint(&obs, .left_shoulder, 0.7, 0.8);
    setJoint(&obs, .right_shoulder, 0.3, 0.7);
    const p = analyze(&obs, .{}, .normal, .absent);
    try std.testing.expect(p.shoulder_tilt.? > 9);
    try std.testing.expectEqual(Stance.leaning_left, p.stance);

    // Calibrated upright, then the nose sinks toward the shoulders.
    setJoint(&obs, .left_shoulder, 0.7, 0.75);
    setJoint(&obs, .right_shoulder, 0.3, 0.75);
    const cal = calibrationFrom(&obs).?;
    try std.testing.expect(cal.neck > 0.5);
    try std.testing.expectEqual(Stance.upright, analyze(&obs, cal, .normal, .absent).stance);
    setJoint(&obs, .nose, 0.5, 0.6);
    try std.testing.expectEqual(Stance.slouching, analyze(&obs, cal, .normal, .absent).stance);

    const tilted = faceObs(0, 0, 25, 0.25);
    try std.testing.expectEqual(Stance.head_tilted, analyze(&tilted, .{}, .normal, .absent).stance);
}

test "posture: a body without a face is turned away; an empty frame is nobody" {
    var back: Observation = .{ .seq = 1, .frame_w = 640, .frame_h = 480 };
    setJoint(&back, .left_shoulder, 0.3, 0.8);
    setJoint(&back, .right_shoulder, 0.7, 0.8);
    const p = analyze(&back, .{}, .normal, .looking);
    try std.testing.expectEqual(Gaze.away, p.gaze);
    try std.testing.expectEqual(Stance.turned_away, p.stance);
    // Back to the camera: the shoulders are the wrong way round, no tilt is read.
    try std.testing.expect(p.shoulder_tilt == null);

    const empty: Observation = .{ .seq = 2 };
    try std.testing.expectEqual(Gaze.absent, analyze(&empty, .{}, .normal, .looking).gaze);
    try std.testing.expect(calibrationFrom(&empty) == null);
}

test "attention: blurs after the delay away, not while typing, not without frames; clears at a look" {
    var a: Attention = .{};
    a.observe(10, .looking);
    try std.testing.expect(!a.update(10, 3));
    a.observe(11, .away);
    try std.testing.expect(!a.update(13.9, 3));
    a.observe(14, .away);
    try std.testing.expect(a.update(14.1, 3));

    // Input counts as looking: the delay starts again from it.
    a.activity(14.5);
    try std.testing.expect(!a.update(14.6, 3));
    a.observe(17.4, .absent);
    try std.testing.expect(!a.update(17.4, 3));
    try std.testing.expect(a.update(17.6, 3));

    // One look and it is gone.
    a.observe(17.7, .looking);
    try std.testing.expect(!a.update(17.7, 3));

    // Away, but then the camera went quiet: never blur on stale news.
    a.observe(20, .away);
    a.observe(23, .away);
    try std.testing.expect(a.update(23.1, 3));
    try std.testing.expect(!a.update(23.1 + Attention.stale_after, 3));
}

//! The camera for tt's own use (Settings › Physical interactions): frames
//! from AVFoundation, taken on a serial GCD queue, and what macOS's Vision
//! framework recognises in them — the nearest face with its head pose and
//! landmarks, a body's joints (`physical/posture.zig` says what they mean).
//! Everything happens on this Mac: frames are analysed in memory and never
//! kept or sent anywhere.
//!
//! The main thread starts and stops the capture and takes copies of the
//! latest observation and preview frame; the queue does the rest. Every
//! start or stop bumps a generation, and work queued for an older one is
//! dropped, so a quick stop-start never mixes two sessions.
//!
//! `TT_CAMERA_MOCK=/path/to/image` (or the script command `camera PATH`)
//! makes the camera a still image, analysed the same way: tests and
//! headless scripts run without a device and without macOS asking.
const std = @import("std");
const objc = @import("../objc.zig");
const apple = @import("../apple.zig");
const sys = @import("../sys.zig");
const media = @import("media.zig");
const posture = @import("../physical/posture.zig");
const image = @import("../gfx/image.zig");

const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSUInteger = objc.NSUInteger;
const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;

// ── GCD, CoreMedia, CoreVideo, Vision ───────────────────────────────────
const Queue = ?*anyopaque;
const Work = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: Work) void;
extern "c" fn dispatch_after_f(when: u64, queue: Queue, context: ?*anyopaque, work: Work) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;

extern "c" fn CMSampleBufferGetImageBuffer(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CVPixelBufferLockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: ?*anyopaque) ?[*]const u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetWidth(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetHeight(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetPixelFormatType(pb: ?*anyopaque) u32;
extern "c" const kCVPixelBufferPixelFormatTypeKey: id;
extern "c" const AVCaptureSessionPreset640x480: id;

extern "c" const VNHumanBodyPoseObservationJointNameNose: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftEye: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightEye: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftEar: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightEar: id;
extern "c" const VNHumanBodyPoseObservationJointNameNeck: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftShoulder: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightShoulder: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftElbow: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightElbow: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftWrist: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightWrist: id;
extern "c" const VNHumanBodyPoseObservationJointNameLeftHip: id;
extern "c" const VNHumanBodyPoseObservationJointNameRightHip: id;
extern "c" const VNHumanBodyPoseObservationJointNameRoot: id;

/// Vision's name for each `posture.Joint`, in the enum's order.
fn jointName(j: posture.Joint) id {
    return switch (j) {
        .nose => VNHumanBodyPoseObservationJointNameNose,
        .left_eye => VNHumanBodyPoseObservationJointNameLeftEye,
        .right_eye => VNHumanBodyPoseObservationJointNameRightEye,
        .left_ear => VNHumanBodyPoseObservationJointNameLeftEar,
        .right_ear => VNHumanBodyPoseObservationJointNameRightEar,
        .neck => VNHumanBodyPoseObservationJointNameNeck,
        .left_shoulder => VNHumanBodyPoseObservationJointNameLeftShoulder,
        .right_shoulder => VNHumanBodyPoseObservationJointNameRightShoulder,
        .left_elbow => VNHumanBodyPoseObservationJointNameLeftElbow,
        .right_elbow => VNHumanBodyPoseObservationJointNameRightElbow,
        .left_wrist => VNHumanBodyPoseObservationJointNameLeftWrist,
        .right_wrist => VNHumanBodyPoseObservationJointNameRightWrist,
        .left_hip => VNHumanBodyPoseObservationJointNameLeftHip,
        .right_hip => VNHumanBodyPoseObservationJointNameRightHip,
        .root => VNHumanBodyPoseObservationJointNameRoot,
    };
}

/// kCVPixelFormatType_32BGRA: what Metal's BGRA8Unorm textures take.
const pixel_format_bgra: u32 = 0x42475241;
const lock_read_only: u64 = 1;

pub const Status = enum {
    off,
    starting,
    running,
    /// macOS has not let tt use the camera (or not been asked yet).
    no_access,
    /// No camera connected.
    no_camera,
    failed,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .off => "Off",
            .starting => "Starting",
            .running => "On",
            .no_access => "Not allowed",
            .no_camera => "No camera",
            .failed => "Failed",
        };
    }
};

/// The preview frame is at most this size (the camera runs at 640×480).
pub const preview_max_w = 640;
pub const preview_max_h = 480;

/// What the main thread and the queue share, under `lock`.
const Shared = struct {
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    status: Status = .off,
    obs: posture.Observation = .{},
    /// BGRA, row 0 on top, `preview_w * preview_h * 4` bytes in use.
    preview: [preview_max_w * preview_max_h * 4]u8 = undefined,
    preview_w: u32 = 0,
    preview_h: u32 = 0,
    preview_seq: u64 = 0,
    want_preview: bool = false,
    /// Seconds between two analyses (frames in between only feed the preview).
    interval: f64 = 0.125,
    /// Bumped by every start and stop.
    generation: u64 = 0,
    /// The camera asked for, by name ("" = the macOS default).
    name: [256]u8 = undefined,
    name_len: usize = 0,
    /// The camera running, by name (the default resolved).
    running: [256]u8 = undefined,
    running_len: usize = 0,
    /// A still image stands in for the camera (see the top of the file).
    mock: bool = false,
    mock_path: [1024]u8 = undefined,
    mock_len: usize = 0,
};
var shared: Shared = .{};

fn lock() void {
    _ = std.c.pthread_mutex_lock(&shared.lock);
}

fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&shared.lock);
}

/// What only the queue touches.
const Worker = struct {
    queue: Queue = null,
    delegate: id = null,
    session: id = null,
    output: id = null,
    generation: u64 = 0,
    last_analysis: f64 = 0,
    seq: u64 = 0,
    rect_req: id = null,
    face_req: id = null,
    body_req: id = null,
    mocking: bool = false,
    mock_path: [1024]u8 = undefined,
    mock_len: usize = 0,
    mock_url: id = null,
    mock_bitmap: ?image.Bitmap = null,
    /// The mock's picture was put in the preview since it last changed.
    mock_shown: bool = false,
};
var worker: Worker = .{};

var env_checked = false;

/// Picks up TT_CAMERA_MOCK once.
fn checkEnv() void {
    if (env_checked) return;
    env_checked = true;
    if (sys.getenv("TT_CAMERA_MOCK")) |path| setMock(path);
}

// ── the main thread's side ──────────────────────────────────────────────

/// A still image stands in for the camera from now on (a script's
/// `camera PATH`); an empty path gives no frames at all, like a camera
/// that stalled.
pub fn setMock(path: []const u8) void {
    env_checked = true;
    lock();
    defer unlock();
    shared.mock = true;
    shared.mock_len = @min(path.len, shared.mock_path.len);
    @memcpy(shared.mock_path[0..shared.mock_len], path[0..shared.mock_len]);
}

/// True when a still image stands in for the camera.
pub fn mocking() bool {
    checkEnv();
    lock();
    defer unlock();
    return shared.mock;
}

/// Whether the camera may run: macOS said yes (or a mock stands in).
/// Never asks macOS; `media.requestAccess` does.
pub fn allowed() bool {
    return mocking() or media.access(.camera) == .authorized;
}

/// Starts the camera called `name` ("" = the macOS default), stopping any
/// other first. Returns at once; `status` follows.
pub fn start(name: []const u8) void {
    checkEnv();
    if (worker.queue == null) {
        registerDelegate();
        worker.queue = dispatch_queue_create("es.lab34.tt.camera", null);
        worker.delegate = objc.new("TTCameraDelegate");
    }
    lock();
    shared.generation += 1;
    const gen = shared.generation;
    shared.name_len = @min(name.len, shared.name.len);
    @memcpy(shared.name[0..shared.name_len], name[0..shared.name_len]);
    shared.status = .starting;
    shared.obs = .{};
    shared.preview_w = 0;
    shared.running_len = 0;
    unlock();
    dispatch_async_f(worker.queue, @ptrFromInt(gen), workStart);
}

pub fn stop() void {
    if (worker.queue == null) return;
    lock();
    shared.generation += 1;
    const gen = shared.generation;
    shared.status = .off;
    shared.obs = .{};
    shared.preview_w = 0;
    shared.running_len = 0;
    unlock();
    dispatch_async_f(worker.queue, @ptrFromInt(gen), workStop);
}

pub fn status() Status {
    lock();
    defer unlock();
    return shared.status;
}

/// The camera running, by the name macOS gives it ("" when none).
pub fn runningName(buf: []u8) []const u8 {
    lock();
    defer unlock();
    const n = @min(buf.len, shared.running_len);
    @memcpy(buf[0..n], shared.running[0..n]);
    return buf[0..n];
}

/// The latest analysed frame (`seq` 0 = none yet).
pub fn latest() posture.Observation {
    lock();
    defer unlock();
    return shared.obs;
}

/// Bumped by every new preview frame.
pub fn previewSeq() u64 {
    lock();
    defer unlock();
    return shared.preview_seq;
}

/// Whether frames should also be copied for the preview.
pub fn setWantPreview(on: bool) void {
    lock();
    defer unlock();
    shared.want_preview = on;
}

/// Seconds between two analyses.
pub fn setInterval(seconds: f64) void {
    lock();
    defer unlock();
    shared.interval = seconds;
}

/// Copies the newest preview frame into `out` (reallocated to fit) when it
/// is newer than `seq`; returns its sequence number then.
pub fn takePreview(gpa: std.mem.Allocator, out: *image.Bitmap, seq: u64) ?u64 {
    lock();
    defer unlock();
    if (shared.preview_w == 0 or shared.preview_seq == seq) return null;
    const len = @as(usize, shared.preview_w) * shared.preview_h * 4;
    if (out.pixels.len != len) {
        if (out.pixels.len > 0) gpa.free(out.pixels);
        out.pixels = gpa.alloc(u8, len) catch {
            out.* = .{ .width = 0, .height = 0, .pixels = &.{} };
            return null;
        };
    }
    @memcpy(out.pixels, shared.preview[0..len]);
    out.width = shared.preview_w;
    out.height = shared.preview_h;
    return shared.preview_seq;
}

// ── the queue's side ────────────────────────────────────────────────────

fn currentGeneration() u64 {
    lock();
    defer unlock();
    return shared.generation;
}

/// Sets the status, unless a later start or stop has taken over.
fn setStatus(gen: u64, st: Status) void {
    lock();
    defer unlock();
    if (shared.generation == gen) shared.status = st;
}

fn workStop(_: ?*anyopaque) callconv(.c) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    teardown();
}

fn workStart(ctx: ?*anyopaque) callconv(.c) void {
    const gen: u64 = @intFromPtr(ctx);
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    teardown();
    if (gen != currentGeneration()) return;
    worker.generation = gen;
    worker.last_analysis = 0;

    lock();
    const mock = shared.mock;
    var name_buf: [256]u8 = undefined;
    const name = name_buf[0..shared.name_len];
    @memcpy(name, shared.name[0..shared.name_len]);
    unlock();

    if (mock) {
        worker.mocking = true;
        worker.mock_len = 0;
        setRunning(gen, "Still image (TT_CAMERA_MOCK)");
        setStatus(gen, .running);
        mockTick(ctx);
        return;
    }
    // Only ever with macOS's yes: this must not be what makes macOS ask.
    if (media.access(.camera) != .authorized) return setStatus(gen, .no_access);

    // The camera by its name; the default when it is gone (unplugged), so
    // what depends on it keeps working.
    var dev: id = if (name.len > 0) media.findDevice(.camera, name) else null;
    if (dev == null) dev = media.defaultDevice(.camera);
    if (dev == null) return setStatus(gen, .no_camera);

    const session = objc.new("AVCaptureSession");
    msg(void, session, "beginConfiguration", .{});
    if (msg(bool, session, "canSetSessionPreset:", .{AVCaptureSessionPreset640x480}))
        msg(void, session, "setSessionPreset:", .{AVCaptureSessionPreset640x480});
    var err: id = null;
    const input = msg(id, objc.class("AVCaptureDeviceInput"), "deviceInputWithDevice:error:", .{ dev, @as(*id, &err) });
    if (input == null or !msg(bool, session, "canAddInput:", .{input})) {
        objc.release(session);
        return setStatus(gen, .failed);
    }
    msg(void, session, "addInput:", .{input});

    const output = objc.new("AVCaptureVideoDataOutput");
    const format = msg(id, objc.class("NSNumber"), "numberWithUnsignedInt:", .{@as(c_uint, pixel_format_bgra)});
    const settings = msg(id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ format, kCVPixelBufferPixelFormatTypeKey });
    msg(void, output, "setVideoSettings:", .{settings});
    msg(void, output, "setAlwaysDiscardsLateVideoFrames:", .{true});
    msg(void, output, "setSampleBufferDelegate:queue:", .{ worker.delegate, worker.queue });
    if (!msg(bool, session, "canAddOutput:", .{output})) {
        objc.release(output);
        objc.release(session);
        return setStatus(gen, .failed);
    }
    msg(void, session, "addOutput:", .{output});
    msg(void, session, "commitConfiguration", .{});
    worker.session = session;
    worker.output = output;
    // Blocks until the camera runs; this is the camera's own queue.
    msg(void, session, "startRunning", .{});
    if (!msg(bool, session, "isRunning", .{})) {
        teardown();
        return setStatus(gen, .failed);
    }
    setRunning(gen, objc.utf8(msg(id, dev, "localizedName", .{})));
    setStatus(gen, .running);
}

fn setRunning(gen: u64, name: []const u8) void {
    lock();
    defer unlock();
    if (shared.generation != gen) return;
    shared.running_len = @min(name.len, shared.running.len);
    @memcpy(shared.running[0..shared.running_len], name[0..shared.running_len]);
}

fn teardown() void {
    worker.mocking = false;
    if (worker.session != null) {
        msg(void, worker.output, "setSampleBufferDelegate:queue:", .{ @as(id, null), @as(Queue, null) });
        msg(void, worker.session, "stopRunning", .{});
        objc.release(worker.output);
        objc.release(worker.session);
        worker.session = null;
        worker.output = null;
    }
}

/// `captureOutput:didOutputSampleBuffer:fromConnection:` — each frame, on
/// the queue.
fn didOutput(_: id, _: SEL, output: id, sbuf: ?*anyopaque, _: id) callconv(.c) void {
    // A frame queued before its session was torn down.
    if (worker.session == null or output != worker.output) return;
    const now = apple.CACurrentMediaTime();
    lock();
    const want_preview = shared.want_preview;
    const interval = shared.interval;
    unlock();
    const analyse_now = now - worker.last_analysis >= interval;
    if (!want_preview and !analyse_now) return;

    const pb = CMSampleBufferGetImageBuffer(sbuf) orelse return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const w = CVPixelBufferGetWidth(pb);
    const h = CVPixelBufferGetHeight(pb);
    if (want_preview and CVPixelBufferGetPixelFormatType(pb) == pixel_format_bgra) {
        if (CVPixelBufferLockBaseAddress(pb, lock_read_only) == 0) {
            if (CVPixelBufferGetBaseAddress(pb)) |base| copyPreview(base, w, h, CVPixelBufferGetBytesPerRow(pb));
            _ = CVPixelBufferUnlockBaseAddress(pb, lock_read_only);
        }
    }
    if (analyse_now) {
        worker.last_analysis = now;
        const handler = msg(id, objc.alloc("VNImageRequestHandler"), "initWithCVPixelBuffer:options:", .{ pb, emptyDict() });
        if (handler == null) return;
        defer objc.release(handler);
        analyse(handler, @intCast(w), @intCast(h));
    }
}

fn emptyDict() id {
    return msg(id, objc.class("NSDictionary"), "dictionary", .{});
}

/// Puts a BGRA frame in the preview, halved (or more) to fit.
fn copyPreview(base: [*]const u8, w: usize, h: usize, bytes_per_row: usize) void {
    if (w == 0 or h == 0) return;
    const step = @max(1, @max(std.math.divCeil(usize, w, preview_max_w) catch 1, std.math.divCeil(usize, h, preview_max_h) catch 1));
    const ow = w / step;
    const oh = h / step;
    lock();
    defer unlock();
    for (0..oh) |y| {
        const src = base + y * step * bytes_per_row;
        const dst = shared.preview[y * ow * 4 ..][0 .. ow * 4];
        if (step == 1) {
            @memcpy(dst, src[0 .. ow * 4]);
        } else for (0..ow) |x| {
            @memcpy(dst[x * 4 ..][0..4], src[x * step * 4 ..][0..4]);
        }
    }
    shared.preview_w = @intCast(ow);
    shared.preview_h = @intCast(oh);
    shared.preview_seq +%= 1;
}

/// The still image in place of the camera, analysed like a frame; runs
/// again after the interval until its session ends.
fn mockTick(ctx: ?*anyopaque) callconv(.c) void {
    const gen: u64 = @intFromPtr(ctx);
    if (!worker.mocking or gen != worker.generation) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();

    lock();
    var path_buf: [1024]u8 = undefined;
    const path = path_buf[0..shared.mock_len];
    @memcpy(path, shared.mock_path[0..shared.mock_len]);
    const want_preview = shared.want_preview;
    const interval = shared.interval;
    unlock();

    if (!std.mem.eql(u8, path, worker.mock_path[0..worker.mock_len])) {
        @memcpy(worker.mock_path[0..path.len], path);
        worker.mock_len = path.len;
        if (worker.mock_bitmap) |*bm| bm.deinit(std.heap.c_allocator);
        worker.mock_bitmap = null;
        objc.release(worker.mock_url);
        worker.mock_url = null;
        worker.mock_shown = false;
        if (path.len > 0) {
            if (image.decodeImage(std.heap.c_allocator, path, preview_max_h)) |img| {
                worker.mock_bitmap = img.bitmap;
                worker.mock_url = objc.retain(msg(id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}));
            } else |_| {}
        }
    }
    if (worker.mock_bitmap) |bm| {
        if (want_preview and !worker.mock_shown) {
            copyPreview(bm.pixels.ptr, bm.width, bm.height, @as(usize, bm.width) * 4);
            worker.mock_shown = true;
        }
        if (!want_preview) worker.mock_shown = false;
        const handler = msg(id, objc.alloc("VNImageRequestHandler"), "initWithURL:options:", .{ worker.mock_url, emptyDict() });
        if (handler != null) {
            analyse(handler, bm.width, bm.height);
            objc.release(handler);
        }
    }
    const ns: i64 = @intFromFloat(interval * 1e9);
    dispatch_after_f(dispatch_time(0, ns), worker.queue, ctx, mockTick);
}

// ── Vision ──────────────────────────────────────────────────────────────

/// Finds the faces (with their head pose) and the body in one frame, then
/// the landmarks of the biggest face, and publishes what was found.
fn analyse(handler: id, w: u32, h: u32) void {
    if (worker.rect_req == null) {
        // Revision 3 is the one that measures the head's yaw, pitch and
        // roll; Vision picks older defaults for a binary without a recent
        // SDK stamp, so it is asked for by number.
        worker.rect_req = objc.new("VNDetectFaceRectanglesRequest");
        msg(void, worker.rect_req, "setRevision:", .{@as(NSUInteger, 3)});
        worker.face_req = objc.new("VNDetectFaceLandmarksRequest");
        msg(void, worker.face_req, "setRevision:", .{@as(NSUInteger, 3)});
        worker.body_req = objc.new("VNDetectHumanBodyPoseRequest");
    }
    const reqs = [_]id{ worker.rect_req, worker.body_req };
    var err: id = null;
    // One request failing still leaves the other's results.
    _ = msg(bool, handler, "performRequests:error:", .{ array(&reqs), @as(*id, &err) });

    var obs: posture.Observation = .{ .frame_w = w, .frame_h = h };
    if (readFaces(&obs)) |face| {
        // The landmarks of that face only: no second search for faces.
        const faces = [_]id{face};
        msg(void, worker.face_req, "setInputFaceObservations:", .{array(&faces)});
        const marks = [_]id{worker.face_req};
        if (msg(bool, handler, "performRequests:error:", .{ array(&marks), @as(*id, &err) })) readLandmarks(&obs);
    }
    readBody(&obs);
    worker.seq += 1;
    obs.seq = worker.seq;
    lock();
    defer unlock();
    if (shared.generation == worker.generation) shared.obs = obs;
}

fn array(items: []const id) id {
    return msg(id, objc.class("NSArray"), "arrayWithObjects:count:", .{ @as([*]const id, items.ptr), @as(NSUInteger, items.len) });
}

fn degrees(number: id) ?f32 {
    if (number == null) return null;
    return @floatCast(std.math.radiansToDegrees(msg(f64, number, "doubleValue", .{})));
}

/// The biggest face: its box and head pose. Returns its observation.
fn readFaces(obs: *posture.Observation) id {
    const results = msg(id, worker.rect_req, "results", .{});
    if (results == null) return null;
    const n: usize = @intCast(msg(NSUInteger, results, "count", .{}));
    obs.faces = @intCast(@min(n, 255));
    var best: id = null;
    var best_area: f64 = 0;
    for (0..n) |i| {
        const o = msg(id, results, "objectAtIndex:", .{@as(NSUInteger, i)});
        const bb = msg(CGRect, o, "boundingBox", .{});
        const area = bb.size.width * bb.size.height;
        if (best == null or area > best_area) {
            best = o;
            best_area = area;
        }
    }
    const o = best orelse return null;
    const bb = msg(CGRect, o, "boundingBox", .{});
    var face: posture.Face = .{
        .x = @floatCast(bb.origin.x),
        .y = @floatCast(1 - (bb.origin.y + bb.size.height)),
        .w = @floatCast(bb.size.width),
        .h = @floatCast(bb.size.height),
        .confidence = msg(f32, o, "confidence", .{}),
        .yaw = degrees(msg(id, o, "yaw", .{})),
        .roll = degrees(msg(id, o, "roll", .{})),
    };
    if (msg(bool, o, "respondsToSelector:", .{objc.sel("pitch")})) face.pitch = degrees(msg(id, o, "pitch", .{}));
    obs.face = face;
    return o;
}

/// The outline, eyes, brows, nose and lips of the face `readFaces` chose.
fn readLandmarks(obs: *posture.Observation) void {
    if (obs.face == null) return;
    const face = &obs.face.?;
    const results = msg(id, worker.face_req, "results", .{});
    if (results == null or msg(NSUInteger, results, "count", .{}) == 0) return;
    const o = msg(id, results, "objectAtIndex:", .{@as(NSUInteger, 0)});
    const bb = msg(CGRect, o, "boundingBox", .{});
    const marks = msg(id, o, "landmarks", .{});
    const all = if (marks != null) msg(id, marks, "allPoints", .{}) else null;
    if (all == null) return;
    const count = @min(@as(usize, @intCast(msg(NSUInteger, all, "pointCount", .{}))), posture.max_landmarks);
    const pts = msg(?[*]const CGPoint, all, "normalizedPoints", .{}) orelse return;
    for (0..count) |i| {
        // Normalised to the face's box, from its bottom-left.
        face.landmarks[i] = .{
            .x = @floatCast(bb.origin.x + pts[i].x * bb.size.width),
            .y = @floatCast(1 - (bb.origin.y + pts[i].y * bb.size.height)),
            .conf = 1,
        };
    }
    face.landmark_count = @intCast(count);
}

/// The joints of the most confident body.
fn readBody(obs: *posture.Observation) void {
    const results = msg(id, worker.body_req, "results", .{});
    if (results == null) return;
    const n: usize = @intCast(msg(NSUInteger, results, "count", .{}));
    var best: id = null;
    var best_conf: f32 = -1;
    for (0..n) |i| {
        const o = msg(id, results, "objectAtIndex:", .{@as(NSUInteger, i)});
        const c = msg(f32, o, "confidence", .{});
        if (c > best_conf) {
            best = o;
            best_conf = c;
        }
    }
    const o = best orelse return;
    for (std.enums.values(posture.Joint)) |j| {
        var err: id = null;
        const pt = msg(id, o, "recognizedPointForJointName:error:", .{ jointName(j), @as(*id, &err) });
        if (pt == null) continue;
        const loc = msg(CGPoint, pt, "location", .{});
        obs.body[@intFromEnum(j)] = .{
            .x = @floatCast(loc.x),
            .y = @floatCast(1 - loc.y),
            .conf = msg(f32, pt, "confidence", .{}),
        };
    }
}

// ── the delegate class ──────────────────────────────────────────────────

/// Registers `TTCameraDelegate` (once: the first `start`).
fn registerDelegate() void {
    const b = objc.ClassBuilder.begin("TTCameraDelegate", "NSObject");
    b.method("captureOutput:didOutputSampleBuffer:fromConnection:", didOutput, "v@:@^v@");
    b.protocol("AVCaptureVideoDataOutputSampleBufferDelegate");
    _ = b.register();
}

//! The microphone for tt's own use (Settings › Physical interactions ›
//! Voice): sound from AVFoundation, taken on a serial GCD queue, and what
//! macOS's Speech framework makes of it. Recognition is on-device only
//! (`requiresOnDeviceRecognition`): nothing is sent anywhere, and a Mac
//! without the on-device model for the language says so instead of
//! falling back to Apple's servers.
//!
//! Recognition runs as a chain of tasks: one lasts until the speaker pauses
//! (or a minute at most), then the next takes over, so each transcript is
//! one utterance. The main thread starts and stops the whole thing and
//! takes copies of the latest transcript and the input level; the queue and
//! the recogniser's callbacks do the rest. Every start or stop bumps a
//! generation, and work queued for an older one is dropped.
//!
//! `TT_VOICE_MOCK=/path/to/audio` makes the microphone a sound file, played
//! into the recogniser in real time and then again after a pause (`say -o
//! x.aiff "tt, open the files"` makes one); it still needs macOS's yes for
//! speech recognition, but no microphone.
const std = @import("std");
const objc = @import("../objc.zig");
const apple = @import("../apple.zig");
const sys = @import("../sys.zig");
const media = @import("media.zig");
const trigger_mod = @import("../physical/trigger.zig");

const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;

// ── GCD ─────────────────────────────────────────────────────────────────
const Queue = ?*anyopaque;
const Work = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: Work) void;
extern "c" fn dispatch_after_f(when: u64, queue: Queue, context: ?*anyopaque, work: Work) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) Queue;

// ── CoreMedia: sound as the capture hands it over ───────────────────────
const CMTime = extern struct { value: i64, timescale: i32, flags: u32, epoch: i64 };
const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};
extern "c" fn CMSampleBufferGetFormatDescription(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CMAudioFormatDescriptionGetStreamBasicDescription(desc: ?*anyopaque) ?*const AudioStreamBasicDescription;
extern "c" fn CMSampleBufferGetNumSamples(sbuf: ?*anyopaque) isize;
extern "c" fn CMSampleBufferCopyPCMDataIntoAudioBufferList(sbuf: ?*anyopaque, frame_offset: i32, frames: i32, list: ?*anyopaque) i32;
extern "c" fn CMAudioFormatDescriptionCreate(allocator: ?*anyopaque, asbd: *const AudioStreamBasicDescription, layout_size: usize, layout: ?*const anyopaque, cookie_size: usize, cookie: ?*const anyopaque, extensions: ?*anyopaque, out: *?*anyopaque) i32;
extern "c" fn CMAudioSampleBufferCreateWithPacketDescriptions(allocator: ?*anyopaque, data: ?*anyopaque, data_ready: u8, make_ready: ?*anyopaque, refcon: ?*anyopaque, desc: ?*anyopaque, samples: isize, pts: CMTime, packets: ?*const anyopaque, out: *?*anyopaque) i32;
extern "c" fn CMSampleBufferSetDataBufferFromAudioBufferList(sbuf: ?*anyopaque, struct_alloc: ?*anyopaque, memory_alloc: ?*anyopaque, flags: u32, list: ?*const anyopaque) i32;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

/// kAudioFormatLinearPCM ('lpcm').
const format_lpcm: u32 = 0x6C70636D;

pub const Status = enum {
    off,
    starting,
    running,
    /// macOS has not let tt use the microphone (or not been asked yet).
    no_mic_access,
    /// … or speech recognition.
    no_speech_access,
    /// A bare binary: macOS only lets an app with a bundle recognise speech.
    needs_app,
    /// No recogniser for the Mac's language, or not one that runs on it.
    unavailable,
    no_microphone,
    failed,
};

/// How many input levels the preview's meter shows, one per 50 ms.
pub const level_count = 64;
const level_interval: f64 = 0.05;
/// A task ends this long after the last new words (the utterance is over) …
const pause_ends_task: f64 = 1.6;
/// … or at this age at the latest.
const max_task_age: f64 = 50;

pub const max_transcript = 1024;

/// A copy of what the recogniser has heard, for the main thread.
pub const Heard = struct {
    /// The current task's transcript so far.
    text: [max_transcript]u8 = undefined,
    text_len: usize = 0,
    /// Bumped whenever the transcript changes.
    seq: u64 = 0,
    /// Bumped by every new task: a new utterance starts empty.
    task: u64 = 0,
    /// The input level, oldest first, 0 … 1.
    levels: [level_count]f32 = @splat(0),
    level_seq: u64 = 0,
    /// The recogniser's last complaint ("" when none).
    err: [160]u8 = undefined,
    err_len: usize = 0,

    pub fn transcript(self: *const Heard) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn errorText(self: *const Heard) []const u8 {
        return self.err[0..self.err_len];
    }
};

/// What the main thread and the queue share, under `lock`.
const Shared = struct {
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    status: Status = .off,
    generation: u64 = 0,
    /// The microphone asked for, by name ("" = the macOS default).
    name: [256]u8 = undefined,
    name_len: usize = 0,
    /// The language to recognise ("" = the Mac's).
    language: [64]u8 = undefined,
    language_len: usize = 0,
    /// The microphone running, by name (the default resolved).
    running: [256]u8 = undefined,
    running_len: usize = 0,
    /// The trigger, given to the recogniser as a phrase to expect.
    trigger: [64]u8 = undefined,
    trigger_len: usize = 0,
    heard: Heard = .{},
    /// Where the next level goes in `heard.levels` (a ring).
    level_head: usize = 0,
    /// The task whose callbacks count (the others ended or were replaced).
    current_task: usize = 0,
    task_started: f64 = 0,
    /// When the current task last heard new words (0 = none yet).
    last_words: f64 = 0,
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
    audio_delegate: id = null,
    task_delegate: id = null,
    /// The recogniser's callbacks arrive on this operation queue.
    callbacks: id = null,
    session: id = null,
    output: id = null,
    recognizer: id = null,
    request: id = null,
    task: id = null,
    /// The task replaced last, kept until the next one is (it may still be
    /// delivering its last callbacks).
    old_request: id = null,
    old_task: id = null,
    generation: u64 = 0,
    /// The loudest level since `level_since`.
    level_max: f32 = 0,
    level_since: f64 = 0,
    /// Tasks that ended in an error in a row (a restart loop is throttled).
    failures: u32 = 0,
    // The sound file standing in for the microphone.
    mocking: bool = false,
    mock_file: id = null,
    mock_buffer: id = null,
    /// Chunks of silence still to play before the file starts again.
    mock_silence: u32 = 0,
    /// Frames played so far (the chunks' time stamps).
    mock_frames: i64 = 0,
};
var worker: Worker = .{};

var env_checked = false;

fn checkEnv() void {
    if (env_checked) return;
    env_checked = true;
    if (sys.getenv("TT_VOICE_MOCK")) |path| {
        shared.mock = true;
        shared.mock_len = @min(path.len, shared.mock_path.len);
        @memcpy(shared.mock_path[0..shared.mock_len], path[0..shared.mock_len]);
    }
}

// ── the main thread's side ──────────────────────────────────────────────

/// True when a sound file stands in for the microphone (TT_VOICE_MOCK).
pub fn mocking() bool {
    checkEnv();
    lock();
    defer unlock();
    return shared.mock;
}

/// Whether this process may ask for speech recognition at all: macOS ends
/// an app that does without saying why in its Info.plist, and a bare
/// binary has none (tt.app does).
var described: ?bool = null;

pub fn usageDescribed() bool {
    if (described) |d| return d;
    described = lookUpDescription();
    return described.?;
}

fn lookUpDescription() bool {
    const bundle = msg(id, objc.class("NSBundle"), "mainBundle", .{});
    if (bundle == null) return false;
    return msg(id, bundle, "objectForInfoDictionaryKey:", .{objc.nsString("NSSpeechRecognitionUsageDescription")}) != null;
}

/// macOS's answer about speech recognition (SFSpeechRecognizerAuthorizationStatus).
pub fn speechAccess() media.Access {
    const cls = objc.objc_getClass("SFSpeechRecognizer");
    if (cls == null) return .restricted;
    return switch (msg(NSInteger, cls, "authorizationStatus", .{})) {
        0 => .not_determined,
        1 => .denied,
        2 => .restricted,
        else => .authorized,
    };
}

/// Has macOS ask the user about speech recognition (once per app). Never
/// without a usage description (see `usageDescribed`).
pub fn requestSpeechAccess() void {
    if (!usageDescribed()) return;
    const cls = objc.objc_getClass("SFSpeechRecognizer");
    if (cls == null) return;
    const S = struct {
        var block: objc.Block = undefined;
        fn answered(_: *objc.Block, _: NSInteger) callconv(.c) void {}
    };
    S.block = objc.Block.global(@ptrCast(&S.answered), @sizeOf(objc.Block));
    msg(void, cls, "requestAuthorization:", .{@as(?*anyopaque, &S.block)});
}

/// System Settings › Privacy & Security › Speech Recognition.
pub fn openSpeechPrivacySettings() void {
    const url = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")});
    if (url == null) return;
    _ = msg(bool, msg(id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{url});
}

/// What the Mac can recognise in a language: whether there is a
/// recogniser for it, whether that runs on this Mac, and the language's
/// name (in the Mac's own language).
pub const Recognition = struct {
    supported: bool = false,
    on_device: bool = false,
    language: []const u8 = "",
};

/// A recogniser for the language `ident` ("en-US"; blank = the Mac's
/// language). Owned; null when there is none for it.
fn makeRecognizer(ident: []const u8) id {
    if (objc.objc_getClass("SFSpeechRecognizer") == null) return null;
    if (ident.len == 0) return objc.new("SFSpeechRecognizer");
    const locale = msg(id, objc.class("NSLocale"), "localeWithLocaleIdentifier:", .{objc.nsString(ident)});
    return msg(id, objc.alloc("SFSpeechRecognizer"), "initWithLocale:", .{locale});
}

/// The name of a language, in the Mac's own language ("español (España)").
fn languageName(ident: id) []const u8 {
    const current = msg(id, objc.class("NSLocale"), "currentLocale", .{});
    const name = objc.utf8(msg(id, current, "localizedStringForLocaleIdentifier:", .{ident}));
    return if (name.len > 0) name else objc.utf8(ident);
}

var recognition_ident: [64]u8 = undefined;
var recognition_ident_len: usize = 0;
var recognition_cache: ?Recognition = null;
var language_buf: [96]u8 = undefined;

/// Looked up again only when the language changes.
pub fn recognition(ident: []const u8) Recognition {
    if (recognition_cache) |r| {
        if (std.mem.eql(u8, ident, recognition_ident[0..recognition_ident_len])) return r;
    }
    var r: Recognition = .{};
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const rec = makeRecognizer(ident);
    if (rec != null) {
        defer objc.release(rec);
        r.supported = true;
        r.on_device = msg(bool, rec, "supportsOnDeviceRecognition", .{});
        const name = languageName(msg(id, msg(id, rec, "locale", .{}), "localeIdentifier", .{}));
        const n = @min(name.len, language_buf.len);
        @memcpy(language_buf[0..n], name[0..n]);
        r.language = language_buf[0..n];
    } else {
        const n = @min(ident.len, language_buf.len);
        @memcpy(language_buf[0..n], ident[0..n]);
        r.language = language_buf[0..n];
    }
    recognition_ident_len = @min(ident.len, recognition_ident.len);
    @memcpy(recognition_ident[0..recognition_ident_len], ident[0..recognition_ident_len]);
    recognition_cache = r;
    return r;
}

/// A language the Mac recognises on its own.
pub const Language = struct {
    /// Its code, as the recogniser gives it ("en-US").
    ident: []const u8,
    /// Its name in the Mac's own language.
    name: []const u8,
};

var languages_cache: ?[]Language = null;
var languages_loading = false;

/// The languages this Mac recognises on its own, by name; empty until they
/// are known. Looked up once, in the background: that takes a recogniser
/// per language macOS knows (some 50, a fifth of a second).
pub fn languages() []const Language {
    lock();
    defer unlock();
    if (languages_cache) |l| return l;
    if (!languages_loading) {
        languages_loading = true;
        dispatch_async_f(dispatch_get_global_queue(0, 0), null, loadLanguages);
    }
    return &.{};
}

fn loadLanguages(_: ?*anyopaque) callconv(.c) void {
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(Language) = .empty;
    const cls = objc.objc_getClass("SFSpeechRecognizer");
    if (cls != null) {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const all = msg(id, msg(id, cls, "supportedLocales", .{}), "allObjects", .{});
        const n: usize = if (all != null) @intCast(msg(NSUInteger, all, "count", .{})) else 0;
        for (0..n) |i| {
            const locale = msg(id, all, "objectAtIndex:", .{@as(NSUInteger, i)});
            const rec = msg(id, objc.alloc("SFSpeechRecognizer"), "initWithLocale:", .{locale});
            if (rec == null) continue;
            defer objc.release(rec);
            if (!msg(bool, rec, "supportsOnDeviceRecognition", .{})) continue;
            const ident_ns = msg(id, locale, "localeIdentifier", .{});
            const ident = gpa.dupe(u8, objc.utf8(ident_ns)) catch continue;
            const name = gpa.dupe(u8, languageName(ident_ns)) catch {
                gpa.free(ident);
                continue;
            };
            out.append(gpa, .{ .ident = ident, .name = name }) catch {};
        }
    }
    std.mem.sort(Language, out.items, {}, struct {
        fn lt(_: void, a: Language, b: Language) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lt);
    const list: []Language = out.toOwnedSlice(gpa) catch &.{};
    lock();
    defer unlock();
    languages_cache = list;
}

/// Starts listening with the microphone called `name` ("" = the macOS
/// default) in the language `language` ("" = the Mac's), stopping any
/// other first. Returns at once; `status` follows.
pub fn start(name: []const u8, language: []const u8, trigger: []const u8) void {
    checkEnv();
    if (worker.queue == null) {
        registerDelegates();
        worker.queue = dispatch_queue_create("es.lab34.tt.voice", null);
        worker.audio_delegate = objc.new("TTVoiceAudioDelegate");
        worker.task_delegate = objc.new("TTVoiceTaskDelegate");
        worker.callbacks = objc.new("NSOperationQueue");
        msg(void, worker.callbacks, "setMaxConcurrentOperationCount:", .{@as(NSInteger, 1)});
    }
    lock();
    shared.generation += 1;
    const gen = shared.generation;
    shared.name_len = @min(name.len, shared.name.len);
    @memcpy(shared.name[0..shared.name_len], name[0..shared.name_len]);
    shared.language_len = @min(language.len, shared.language.len);
    @memcpy(shared.language[0..shared.language_len], language[0..shared.language_len]);
    setTriggerLocked(trigger);
    shared.status = .starting;
    shared.running_len = 0;
    clearHeardLocked();
    unlock();
    dispatch_async_f(worker.queue, @ptrFromInt(gen), workStart);
}

pub fn stop() void {
    if (worker.queue == null) return;
    lock();
    shared.generation += 1;
    const gen = shared.generation;
    shared.status = .off;
    shared.running_len = 0;
    clearHeardLocked();
    unlock();
    dispatch_async_f(worker.queue, @ptrFromInt(gen), workStop);
}

/// The phrase the recogniser is told to expect; used from the next task on.
pub fn setTrigger(trigger: []const u8) void {
    lock();
    defer unlock();
    setTriggerLocked(trigger);
}

fn setTriggerLocked(trigger: []const u8) void {
    shared.trigger_len = @min(trigger.len, shared.trigger.len);
    @memcpy(shared.trigger[0..shared.trigger_len], trigger[0..shared.trigger_len]);
}

fn clearHeardLocked() void {
    const task = shared.heard.task;
    const seq = shared.heard.seq;
    shared.heard = .{ .task = task +% 1, .seq = seq +% 1 };
    shared.level_head = 0;
    shared.current_task = 0;
}

pub fn status() Status {
    lock();
    defer unlock();
    return shared.status;
}

/// Copies what was heard into `out` when anything changed since it was
/// last copied there; true then.
pub fn take(out: *Heard) bool {
    lock();
    defer unlock();
    const h = &shared.heard;
    if (h.seq == out.seq and h.level_seq == out.level_seq and h.task == out.task) return false;
    out.text_len = h.text_len;
    @memcpy(out.text[0..h.text_len], h.text[0..h.text_len]);
    out.seq = h.seq;
    out.task = h.task;
    out.level_seq = h.level_seq;
    out.err_len = h.err_len;
    @memcpy(out.err[0..h.err_len], h.err[0..h.err_len]);
    // The ring, oldest first.
    for (0..level_count) |i| out.levels[i] = h.levels[(shared.level_head + i) % level_count];
    return true;
}

/// The microphone running, by the name macOS gives it ("" when none).
pub fn runningName(buf: []u8) []const u8 {
    lock();
    defer unlock();
    const n = @min(buf.len, shared.running_len);
    @memcpy(buf[0..n], shared.running[0..n]);
    return buf[0..n];
}

// ── the queue's side ────────────────────────────────────────────────────

fn currentGeneration() u64 {
    lock();
    defer unlock();
    return shared.generation;
}

fn setStatus(gen: u64, st: Status) void {
    lock();
    defer unlock();
    if (shared.generation == gen) shared.status = st;
}

fn setRunning(gen: u64, name: []const u8) void {
    lock();
    defer unlock();
    if (shared.generation != gen) return;
    shared.running_len = @min(name.len, shared.running.len);
    @memcpy(shared.running[0..shared.running_len], name[0..shared.running_len]);
}

fn setError(text: []const u8) void {
    lock();
    defer unlock();
    const h = &shared.heard;
    h.err_len = @min(text.len, h.err.len);
    @memcpy(h.err[0..h.err_len], text[0..h.err_len]);
    h.seq +%= 1;
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
    worker.failures = 0;

    lock();
    const mock = shared.mock;
    var name_buf: [256]u8 = undefined;
    const name = name_buf[0..shared.name_len];
    @memcpy(name, shared.name[0..shared.name_len]);
    var path_buf: [1024]u8 = undefined;
    const path = path_buf[0..shared.mock_len];
    @memcpy(path, shared.mock_path[0..shared.mock_len]);
    var lang_buf: [64]u8 = undefined;
    const lang = lang_buf[0..shared.language_len];
    @memcpy(lang, shared.language[0..shared.language_len]);
    unlock();

    // Only ever with macOS's yes: this must not be what makes macOS ask.
    if (!usageDescribed()) return setStatus(gen, .needs_app);
    if (speechAccess() != .authorized) return setStatus(gen, .no_speech_access);
    if (!mock and media.access(.microphone) != .authorized) return setStatus(gen, .no_mic_access);

    const rec = makeRecognizer(lang);
    if (rec == null or !msg(bool, rec, "supportsOnDeviceRecognition", .{})) {
        objc.release(rec);
        return setStatus(gen, .unavailable);
    }
    msg(void, rec, "setQueue:", .{worker.callbacks});
    worker.recognizer = rec;

    if (mock) {
        const url = msg(id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
        var err: id = null;
        const file = msg(id, objc.alloc("AVAudioFile"), "initForReading:error:", .{ url, @as(*id, &err) });
        if (file == null) {
            teardown();
            return setStatus(gen, .failed);
        }
        worker.mock_file = file;
        const format = msg(id, file, "processingFormat", .{});
        const rate = msg(f64, format, "sampleRate", .{});
        worker.mock_buffer = msg(id, objc.alloc("AVAudioPCMBuffer"), "initWithPCMFormat:frameCapacity:", .{ format, @as(u32, @intFromFloat(rate * 0.1)) });
        worker.mocking = true;
        worker.mock_silence = 0;
        worker.mock_frames = 0;
        startTask(gen);
        setRunning(gen, "Sound file (TT_VOICE_MOCK)");
        setStatus(gen, .running);
        mockTick(ctx);
        return;
    }

    // The microphone by its name; the default when it is gone (unplugged).
    var dev: id = if (name.len > 0) media.findDevice(.microphone, name) else null;
    if (dev == null) dev = media.defaultDevice(.microphone);
    if (dev == null) {
        teardown();
        return setStatus(gen, .no_microphone);
    }

    const session = objc.new("AVCaptureSession");
    msg(void, session, "beginConfiguration", .{});
    var err: id = null;
    const input = msg(id, objc.class("AVCaptureDeviceInput"), "deviceInputWithDevice:error:", .{ dev, @as(*id, &err) });
    if (input == null or !msg(bool, session, "canAddInput:", .{input})) {
        objc.release(session);
        teardown();
        return setStatus(gen, .failed);
    }
    msg(void, session, "addInput:", .{input});

    // 16 kHz mono 16-bit PCM: what the recogniser works in.
    const output = objc.new("AVCaptureAudioDataOutput");
    msg(void, output, "setAudioSettings:", .{audioSettings()});
    msg(void, output, "setSampleBufferDelegate:queue:", .{ worker.audio_delegate, worker.queue });
    if (!msg(bool, session, "canAddOutput:", .{output})) {
        objc.release(output);
        objc.release(session);
        teardown();
        return setStatus(gen, .failed);
    }
    msg(void, session, "addOutput:", .{output});
    msg(void, session, "commitConfiguration", .{});
    worker.session = session;
    worker.output = output;
    startTask(gen);
    // Blocks until the microphone runs; this is the voice's own queue.
    msg(void, session, "startRunning", .{});
    if (!msg(bool, session, "isRunning", .{})) {
        teardown();
        return setStatus(gen, .failed);
    }
    setRunning(gen, objc.utf8(msg(id, dev, "localizedName", .{})));
    setStatus(gen, .running);
}

fn audioSettings() id {
    const num = objc.class("NSNumber");
    const keys = [_]id{
        objc.nsString("AVFormatIDKey"),
        objc.nsString("AVSampleRateKey"),
        objc.nsString("AVNumberOfChannelsKey"),
        objc.nsString("AVLinearPCMBitDepthKey"),
        objc.nsString("AVLinearPCMIsFloatKey"),
        objc.nsString("AVLinearPCMIsNonInterleaved"),
    };
    const values = [_]id{
        msg(id, num, "numberWithUnsignedInt:", .{@as(c_uint, format_lpcm)}),
        msg(id, num, "numberWithDouble:", .{@as(f64, 16000)}),
        msg(id, num, "numberWithInt:", .{@as(c_int, 1)}),
        msg(id, num, "numberWithInt:", .{@as(c_int, 16)}),
        msg(id, num, "numberWithBool:", .{false}),
        msg(id, num, "numberWithBool:", .{false}),
    };
    return msg(id, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{
        @as([*]const id, &values), @as([*]const id, &keys), @as(NSUInteger, values.len),
    });
}

/// A fresh request and task; the one before ends (its audio is complete)
/// and is kept one more round while its callbacks drain.
fn startTask(gen: u64) void {
    retireTask();
    const req = objc.new("SFSpeechAudioBufferRecognitionRequest");
    msg(void, req, "setShouldReportPartialResults:", .{true});
    msg(void, req, "setRequiresOnDeviceRecognition:", .{true});
    lock();
    var trig_buf: [64]u8 = undefined;
    const trig = trig_buf[0..shared.trigger_len];
    @memcpy(trig, shared.trigger[0..shared.trigger_len]);
    unlock();
    if (trig.len > 0) {
        // The trigger, and "T T" for a short word of letters: how it is said.
        var phrases: [2]id = .{ objc.nsString(trig), null };
        var count: NSUInteger = 1;
        var spelled_buf: [16]u8 = undefined;
        if (trigger_mod.spelled(&spelled_buf, trig)) |sp| {
            phrases[1] = objc.nsString(sp);
            count = 2;
        }
        msg(void, req, "setContextualStrings:", .{msg(id, objc.class("NSArray"), "arrayWithObjects:count:", .{ @as([*]const id, &phrases), count })});
    }
    const task = msg(id, worker.recognizer, "recognitionTaskWithRequest:delegate:", .{ req, worker.task_delegate });
    worker.request = req;
    worker.task = objc.retain(task);
    const now = apple.CACurrentMediaTime();
    lock();
    defer unlock();
    if (shared.generation != gen) return;
    shared.current_task = @intFromPtr(task);
    shared.task_started = now;
    shared.last_words = 0;
    shared.heard.task +%= 1;
    shared.heard.text_len = 0;
    shared.heard.seq +%= 1;
}

fn retireTask() void {
    if (worker.old_task != null) msg(void, worker.old_task, "cancel", .{});
    objc.release(worker.old_task);
    objc.release(worker.old_request);
    worker.old_task = worker.task;
    worker.old_request = worker.request;
    worker.task = null;
    worker.request = null;
    if (worker.old_request != null) msg(void, worker.old_request, "endAudio", .{});
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
    retireTask();
    retireTask();
    objc.release(worker.recognizer);
    worker.recognizer = null;
    objc.release(worker.mock_file);
    objc.release(worker.mock_buffer);
    worker.mock_file = null;
    worker.mock_buffer = null;
    lock();
    shared.current_task = 0;
    unlock();
}

/// Called on the queue with each chunk of sound: the level for the meter,
/// and a new task once the utterance is over.
fn afterAudio(level: f32) void {
    const now = apple.CACurrentMediaTime();
    worker.level_max = @max(worker.level_max, level);
    const push_level = now - worker.level_since >= level_interval;
    lock();
    if (push_level) {
        shared.heard.levels[shared.level_head] = worker.level_max;
        shared.level_head = (shared.level_head + 1) % level_count;
        shared.heard.level_seq +%= 1;
    }
    const pause = shared.last_words > 0 and now - shared.last_words > pause_ends_task;
    const old = now - shared.task_started > max_task_age;
    const gen = shared.generation;
    unlock();
    if (push_level) {
        worker.level_max = 0;
        worker.level_since = now;
    }
    if (pause or old) startTask(gen);
}

/// `captureOutput:didOutputSampleBuffer:fromConnection:` — each chunk of
/// sound from the microphone, on the queue.
fn didOutput(_: id, _: SEL, output: id, sbuf: ?*anyopaque, _: id) callconv(.c) void {
    if (worker.session == null or output != worker.output) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    feed(sbuf);
}

/// A chunk of sound (the microphone's, or the file's standing in): to the
/// recogniser as PCM in whatever format it came — the recogniser converts
/// that itself, where it would not a sample buffer in a format it does
/// not expect — and its level to the meter.
fn feed(sbuf: ?*anyopaque) void {
    const buf = pcmBufferFrom(sbuf);
    if (buf != null and worker.request != null) msg(void, worker.request, "appendAudioPCMBuffer:", .{buf});
    afterAudio(if (buf != null) levelOf(buf) else 0);
}

/// The sound of a sample buffer as an AVAudioPCMBuffer of the same format
/// (autoreleased); null when it is not linear PCM.
fn pcmBufferFrom(sbuf: ?*anyopaque) id {
    const desc = CMSampleBufferGetFormatDescription(sbuf) orelse return null;
    const asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) orelse return null;
    if (asbd.mFormatID != format_lpcm) return null;
    const frames = CMSampleBufferGetNumSamples(sbuf);
    if (frames <= 0 or frames > std.math.maxInt(i32)) return null;
    const format = msg(id, objc.alloc("AVAudioFormat"), "initWithStreamDescription:", .{asbd});
    if (format == null) return null;
    defer objc.release(format);
    const buf = msg(id, objc.alloc("AVAudioPCMBuffer"), "initWithPCMFormat:frameCapacity:", .{ format, @as(u32, @intCast(frames)) });
    if (buf == null) return null;
    _ = objc.autorelease(buf);
    msg(void, buf, "setFrameLength:", .{@as(u32, @intCast(frames))});
    const list = msg(?*anyopaque, buf, "mutableAudioBufferList", .{});
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sbuf, 0, @intCast(frames), list) != 0) return null;
    return buf;
}

/// A PCM buffer wrapped as a sample buffer, as the capture hands sound over
/// (owned: CFRelease it). The sound file goes through the microphone's path
/// this way.
fn sampleBufferFrom(pcm: id, pts: i64) ?*anyopaque {
    const format = msg(id, pcm, "format", .{});
    const asbd = msg(?*const AudioStreamBasicDescription, format, "streamDescription", .{}) orelse return null;
    var desc: ?*anyopaque = null;
    if (CMAudioFormatDescriptionCreate(null, asbd, 0, null, 0, null, null, &desc) != 0) return null;
    defer CFRelease(desc);
    const frames = msg(u32, pcm, "frameLength", .{});
    const time: CMTime = .{ .value = pts, .timescale = @intFromFloat(@max(1, asbd.mSampleRate)), .flags = 1, .epoch = 0 };
    var sbuf: ?*anyopaque = null;
    if (CMAudioSampleBufferCreateWithPacketDescriptions(null, null, 0, null, null, desc, frames, time, null, &sbuf) != 0) return null;
    if (CMSampleBufferSetDataBufferFromAudioBufferList(sbuf, null, null, 0, msg(?*const anyopaque, pcm, "audioBufferList", .{})) != 0) {
        CFRelease(sbuf);
        return null;
    }
    return sbuf;
}

/// How loud a PCM buffer is, 0 … 1: its first channel's RMS, from -55 dBFS
/// (a quiet room) to -5 dBFS (speaking close).
fn levelOf(buf: id) f32 {
    const n: usize = msg(u32, buf, "frameLength", .{});
    if (n == 0) return 0;
    const stride: usize = @max(1, msg(NSUInteger, buf, "stride", .{}));
    const common = msg(NSUInteger, msg(id, buf, "format", .{}), "commonFormat", .{});
    var sum: f64 = 0;
    switch (common) {
        // AVAudioPCMFormatFloat32
        1 => {
            const data = msg(?[*]const [*]const f32, buf, "floatChannelData", .{}) orelse return 0;
            for (0..n) |i| sum += @as(f64, data[0][i * stride]) * data[0][i * stride];
        },
        // AVAudioPCMFormatInt16
        3 => {
            const data = msg(?[*]const [*]const i16, buf, "int16ChannelData", .{}) orelse return 0;
            for (0..n) |i| {
                const v = @as(f64, @floatFromInt(data[0][i * stride])) / 32768.0;
                sum += v * v;
            }
        },
        else => return 0,
    }
    const rms = @sqrt(sum / @as(f64, @floatFromInt(n)));
    const db: f32 = @floatCast(20 * std.math.log10(@max(rms, 1e-9)));
    return std.math.clamp((db + 55) / 50, 0, 1);
}

/// The sound file in place of the microphone: 100 ms of it every 100 ms,
/// then 3 s of silence, then again — each chunk wrapped as the capture
/// would hand it over, so it takes the microphone's path.
fn mockTick(ctx: ?*anyopaque) callconv(.c) void {
    const gen: u64 = @intFromPtr(ctx);
    if (!worker.mocking or gen != worker.generation) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const buf = worker.mock_buffer;
    const cap = msg(u32, buf, "frameCapacity", .{});
    if (worker.mock_silence > 0) {
        worker.mock_silence -= 1;
        const data = msg(?[*]const [*]f32, buf, "floatChannelData", .{});
        if (data) |d| @memset(d[0][0..cap], 0);
        msg(void, buf, "setFrameLength:", .{cap});
        if (worker.mock_silence == 0) msg(void, worker.mock_file, "setFramePosition:", .{@as(i64, 0)});
    } else {
        var err: id = null;
        const ok = msg(bool, worker.mock_file, "readIntoBuffer:frameCount:error:", .{ buf, cap, @as(*id, &err) });
        if (!ok or msg(u32, buf, "frameLength", .{}) == 0) {
            worker.mock_silence = 30;
            msg(void, buf, "setFrameLength:", .{@as(u32, 0)});
        }
    }
    if (msg(u32, buf, "frameLength", .{}) > 0) {
        if (sampleBufferFrom(buf, worker.mock_frames)) |sbuf| {
            defer CFRelease(sbuf);
            feed(sbuf);
        }
        worker.mock_frames += msg(u32, buf, "frameLength", .{});
    }
    dispatch_after_f(dispatch_time(0, 100 * std.time.ns_per_ms), worker.queue, ctx, mockTick);
}

// ── the recogniser's callbacks (on `worker.callbacks`) ──────────────────

fn isCurrent(task: id) bool {
    lock();
    defer unlock();
    return shared.current_task != 0 and shared.current_task == @intFromPtr(task);
}

fn publish(task: id, transcription: id) void {
    const text = objc.utf8(msg(id, transcription, "formattedString", .{}));
    const now = apple.CACurrentMediaTime();
    lock();
    defer unlock();
    if (shared.current_task == 0 or shared.current_task != @intFromPtr(task)) return;
    const h = &shared.heard;
    // The tail, when an utterance outgrows the buffer.
    const t = if (text.len > h.text.len) text[text.len - h.text.len ..] else text;
    if (std.mem.eql(u8, t, h.text[0..h.text_len])) return;
    @memcpy(h.text[0..t.len], t);
    h.text_len = t.len;
    h.seq +%= 1;
    h.err_len = 0;
    shared.last_words = now;
}

/// `speechRecognitionTask:didHypothesizeTranscription:` — the words so far.
fn didHypothesize(_: id, _: SEL, task: id, transcription: id) callconv(.c) void {
    publish(task, transcription);
    worker.failures = 0;
}

/// `speechRecognitionTask:didFinishRecognition:` — the final words.
fn didFinishRecognition(_: id, _: SEL, task: id, result: id) callconv(.c) void {
    if (result == null) return;
    publish(task, msg(id, result, "bestTranscription", .{}));
}

/// `speechRecognitionTask:didFinishSuccessfully:` — a task ended by
/// itself (not replaced): the next one takes over, after a moment when
/// it ended in an error.
fn didFinish(_: id, _: SEL, task: id, ok: bool) callconv(.c) void {
    if (!isCurrent(task)) return;
    var delay_ms: i64 = 0;
    if (!ok) {
        const err = msg(id, task, "error", .{});
        // 1110 "No speech detected" and 216/301 "cancelled" are routine.
        const code: NSInteger = if (err != null) msg(NSInteger, err, "code", .{}) else 0;
        if (err != null and code != 1110 and code != 216 and code != 301) {
            setError(objc.utf8(msg(id, err, "localizedDescription", .{})));
        }
        worker.failures +|= 1;
        delay_ms = @min(5000, 250 * @as(i64, worker.failures));
    }
    const gen = currentGeneration();
    dispatch_after_f(dispatch_time(0, delay_ms * std.time.ns_per_ms), worker.queue, @ptrFromInt(gen), workNextTask);
}

fn workNextTask(ctx: ?*anyopaque) callconv(.c) void {
    const gen: u64 = @intFromPtr(ctx);
    if (gen != worker.generation or gen != currentGeneration() or worker.recognizer == null) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    startTask(gen);
}

// ── the delegate classes ────────────────────────────────────────────────

fn registerDelegates() void {
    const a = objc.ClassBuilder.begin("TTVoiceAudioDelegate", "NSObject");
    a.method("captureOutput:didOutputSampleBuffer:fromConnection:", didOutput, "v@:@^v@");
    a.protocol("AVCaptureAudioDataOutputSampleBufferDelegate");
    _ = a.register();

    const t = objc.ClassBuilder.begin("TTVoiceTaskDelegate", "NSObject");
    t.method("speechRecognitionTask:didHypothesizeTranscription:", didHypothesize, "v@:@@");
    t.method("speechRecognitionTask:didFinishRecognition:", didFinishRecognition, "v@:@@");
    t.method("speechRecognitionTask:didFinishSuccessfully:", didFinish, "v@:@B");
    t.protocol("SFSpeechRecognitionTaskDelegate");
    _ = t.register();
}

test "speech: sound from the capture reaches the recogniser as PCM with the same samples" {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    // 16 kHz mono Int16, like the microphone's: a loud ramp.
    const format = msg(id, objc.alloc("AVAudioFormat"), "initWithCommonFormat:sampleRate:channels:interleaved:", .{ @as(NSUInteger, 3), @as(f64, 16000), @as(u32, 1), true });
    defer objc.release(format);
    const src = msg(id, objc.alloc("AVAudioPCMBuffer"), "initWithPCMFormat:frameCapacity:", .{ format, @as(u32, 160) });
    defer objc.release(src);
    msg(void, src, "setFrameLength:", .{@as(u32, 160)});
    const data = msg(?[*]const [*]i16, src, "int16ChannelData", .{}).?;
    for (0..160) |i| data[0][i] = @intCast(@as(i32, @intCast(i)) * 200 - 16000);

    const sbuf = sampleBufferFrom(src, 0) orelse return error.NoSampleBuffer;
    defer CFRelease(sbuf);
    const out = pcmBufferFrom(sbuf);
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 160), msg(u32, out, "frameLength", .{}));
    const got = msg(?[*]const [*]const i16, out, "int16ChannelData", .{}).?;
    try std.testing.expectEqualSlices(i16, data[0][0..160], got[0][0..160]);
    try std.testing.expect(levelOf(out) > 0.5);

    // Silence is at the bottom of the meter; float sound is measured too.
    @memset(data[0][0..160], 0);
    try std.testing.expectEqual(@as(f32, 0), levelOf(src));
    const f32_format = msg(id, objc.alloc("AVAudioFormat"), "initStandardFormatWithSampleRate:channels:", .{ @as(f64, 22050), @as(u32, 1) });
    defer objc.release(f32_format);
    const fbuf = msg(id, objc.alloc("AVAudioPCMBuffer"), "initWithPCMFormat:frameCapacity:", .{ f32_format, @as(u32, 64) });
    defer objc.release(fbuf);
    msg(void, fbuf, "setFrameLength:", .{@as(u32, 64)});
    const fdata = msg(?[*]const [*]f32, fbuf, "floatChannelData", .{}).?;
    for (0..64) |i| fdata[0][i] = if (i % 2 == 0) 0.5 else -0.5;
    try std.testing.expect(levelOf(fbuf) > 0.8);
}

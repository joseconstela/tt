//! The voice controller: the one place that decides when tt listens and
//! what it makes of what it hears. Consumers ask for the microphone — the
//! voice commands (`voice.enabled` in the config) and the live preview in
//! Settings › Physical interactions › Voice — and the controller runs the
//! microphone picked there while any of them needs it, stops it when none
//! does, and watches each transcript for the trigger word (`trigger.zig`).
//!
//! What follows a trigger is kept as `command`: the commands themselves
//! come later and will read it (with `trigger_seq` to notice a new one).
//!
//! One instance for the whole app (`get()`); `App.update` ticks it.
//!
//! `TT_DEBUG_VOICE=1` prints what happens (status, each transcript, each
//! trigger) to stderr; `TT_DEBUG_VOICE=ask` also has macOS ask for the
//! microphone and speech recognition at launch, when it never has;
//! `TT_DEBUG_VOICE=quiet` prints no words, only how many there were and
//! the input level (a check of the microphone that keeps what is said);
//! `ask,quiet` does both.
const std = @import("std");
const config = @import("../config.zig");
const sys = @import("../sys.zig");
const speech = @import("../platform/speech.zig");
const media = @import("../platform/media.zig");
const trigger = @import("trigger.zig");

pub const Status = speech.Status;

/// The preview is wanted this long after the Settings page last asked.
const preview_grace: f64 = 1.0;
/// How many finished utterances the preview keeps above the current one.
pub const history_len = 3;

/// A finished utterance, for the preview.
pub const Line = struct {
    text: [speech.max_transcript]u8 = undefined,
    len: usize = 0,
    /// It held the trigger.
    triggered: bool = false,

    pub fn slice(self: *const Line) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Controller = struct {
    /// Whether a real microphone may be used. Headless scripts turn it off
    /// so a test never listens; `hear` stands in for speech there.
    allow_device: bool = true,
    preview_until: f64 = 0,
    running: bool = false,
    /// What the running listener was started with.
    running_name: [256]u8 = undefined,
    running_len: usize = 0,
    running_lang: [64]u8 = undefined,
    running_lang_len: usize = 0,
    trigger_buf: [64]u8 = undefined,
    trigger_len: usize = 0,
    status: Status = .off,
    access_checked: f64 = -1000,
    /// Why the listener cannot run, from the last check (null = it can).
    blocked: ?Status = .off,
    /// What was heard, as the recogniser last reported it.
    heard: speech.Heard = .{},
    /// Earlier utterances, oldest first.
    history: [history_len]Line = @splat(.{}),
    history_count: usize = 0,
    /// The trigger's places in the current transcript.
    matches: trigger.Matches = .{},
    /// Bumped each time the trigger is heard, and when.
    trigger_seq: u64 = 0,
    triggered_at: f64 = -1000,
    /// What was said after the latest trigger.
    command_buf: [256]u8 = undefined,
    command_len: usize = 0,
    /// The utterance in progress (it joins the history when the next starts).
    current: Line = .{},
    current_task: u64 = 0,
    /// Scripts: text standing in for the recogniser (`hear`).
    fake: bool = false,
    /// TT_DEBUG_VOICE: print what happens (null = not looked up yet) …
    debug: ?bool = null,
    /// … without the words.
    debug_quiet: bool = false,
    debug_level_at: f64 = 0,

    pub fn requestPreview(self: *Controller, now: f64) void {
        self.preview_until = now + preview_grace;
    }

    pub fn previewWanted(self: *const Controller, now: f64) bool {
        return now < self.preview_until;
    }

    /// Read macOS's answers again on the next tick (after asking it).
    pub fn recheckAccess(self: *Controller) void {
        self.access_checked = -1000;
    }

    fn wanted(self: *const Controller, now: f64) bool {
        return config.get().voice.enabled or self.previewWanted(now);
    }

    /// Everything macOS has to allow first; the reason when something is
    /// missing (as the status the listener would end up in).
    pub fn blocker(self: *const Controller) ?Status {
        if (self.fake) return null;
        if (!self.allow_device and !speech.mocking()) return .off;
        if (!speech.usageDescribed()) return .needs_app;
        if (speech.speechAccess() != .authorized) return .no_speech_access;
        if (!speech.mocking() and media.access(.microphone) != .authorized) return .no_mic_access;
        const rec = speech.recognition(config.get().voice.language);
        if (!rec.supported or !rec.on_device) return .unavailable;
        return null;
    }

    /// The trigger as set, or the default word when blank.
    pub fn triggerWord(_: *const Controller) []const u8 {
        const t = std.mem.trim(u8, config.get().voice.trigger, " \t");
        return if (t.len == 0) trigger.default_word else t;
    }

    /// Starts, switches and stops the listener for its consumers and
    /// watches what it hears. True when the preview has something new.
    pub fn tick(self: *Controller, now: f64) bool {
        const cfg = config.get();
        if (self.debug == null) self.startDebug();
        if (self.fake) return false;
        var changed = false;
        if (now - self.access_checked >= 2) {
            self.access_checked = now;
            self.blocked = self.blocker();
        }
        const want = self.wanted(now);
        const name = cfg.voice.microphone;
        const lang = cfg.voice.language;
        const word = self.triggerWord();
        if (want and self.blocked == null) {
            if (!self.running or !std.mem.eql(u8, name, self.running_name[0..self.running_len]) or !std.mem.eql(u8, lang, self.running_lang[0..self.running_lang_len])) {
                self.startListening(name, lang, word);
                changed = true;
            } else if (!std.mem.eql(u8, word, self.trigger_buf[0..self.trigger_len])) {
                // The recogniser is told from its next utterance on; the
                // current transcript is searched again now.
                self.setTrigger(word);
                speech.setTrigger(word);
                self.rematch(now, false);
                changed = true;
            }
        } else if (self.running) {
            self.stopListening();
            changed = true;
        }

        const st: Status = if (self.running) speech.status() else if (want) (self.blocked orelse .off) else .off;
        if (st != self.status) {
            self.status = st;
            changed = true;
            if (self.debug.?) std.debug.print("voice: status {s}\n", .{@tagName(st)});
        }
        if (self.running and speech.take(&self.heard)) {
            self.takeHeard(now);
            changed = true;
        }
        if (self.debug.? and self.running and now - self.debug_level_at >= 2) {
            self.debug_level_at = now;
            var peak: f32 = 0;
            for (self.heard.levels) |l| peak = @max(peak, l);
            std.debug.print("voice: level peak {d:.2} (updates {d})\n", .{ peak, self.heard.level_seq });
        }
        return changed and self.previewWanted(now);
    }

    fn startDebug(self: *Controller) void {
        const v = sys.getenv("TT_DEBUG_VOICE") orelse {
            self.debug = false;
            return;
        };
        self.debug = true;
        self.debug_quiet = std.mem.indexOf(u8, v, "quiet") != null;
        const rec = speech.recognition(config.get().voice.language);
        std.debug.print("voice: debug on · app bundle {} · speech {s} · microphone {s} · {s}, on this Mac {} · file {}\n", .{
            speech.usageDescribed(),            @tagName(speech.speechAccess()), @tagName(media.access(.microphone)),
            rec.language,                       rec.on_device,                   speech.mocking(),
        });
        if (std.mem.indexOf(u8, v, "ask") != null and speech.usageDescribed()) {
            if (!speech.mocking() and media.access(.microphone) == .not_determined) media.requestAccess(.microphone);
            if (speech.speechAccess() == .not_determined) speech.requestSpeechAccess();
        }
    }

    fn setTrigger(self: *Controller, word: []const u8) void {
        self.trigger_len = @min(word.len, self.trigger_buf.len);
        @memcpy(self.trigger_buf[0..self.trigger_len], word[0..self.trigger_len]);
    }

    fn startListening(self: *Controller, name: []const u8, lang: []const u8, word: []const u8) void {
        speech.start(name, lang, word);
        self.running = true;
        self.running_len = @min(name.len, self.running_name.len);
        @memcpy(self.running_name[0..self.running_len], name[0..self.running_len]);
        self.running_lang_len = @min(lang.len, self.running_lang.len);
        @memcpy(self.running_lang[0..self.running_lang_len], lang[0..self.running_lang_len]);
        self.setTrigger(word);
        self.forget();
    }

    fn stopListening(self: *Controller) void {
        speech.stop();
        self.running = false;
        self.running_len = 0;
        self.forget();
    }

    fn forget(self: *Controller) void {
        self.heard = .{ .task = self.heard.task, .seq = self.heard.seq };
        self.history_count = 0;
        self.current.len = 0;
        self.matches = .{};
        self.command_len = 0;
    }

    /// A new transcript or task arrived in `heard`: an utterance that
    /// ended goes to the history, the trigger is looked for.
    fn takeHeard(self: *Controller, now: f64) void {
        if (self.heard.task != self.current_task) {
            if (self.current.len > 0) self.pushHistory(&self.current);
            self.current_task = self.heard.task;
            self.current.len = 0;
            self.matches = .{};
        }
        const t = self.heard.transcript();
        const same = std.mem.eql(u8, t, self.current.slice());
        self.current.len = t.len;
        @memcpy(self.current.text[0..t.len], t);
        if (same) return;
        if (self.debug orelse false) {
            if (self.debug_quiet) {
                std.debug.print("voice: heard {d} words\n", .{std.mem.count(u8, std.mem.trim(u8, t, " "), " ") + @intFromBool(t.len > 0)});
            } else std.debug.print("voice: heard '{s}'\n", .{t});
        }
        self.rematch(now, true);
        self.current.triggered = self.matches.len > 0;
    }

    /// Looks for the trigger in the current transcript; a trigger more
    /// than before (when `count` is set) is a new one.
    fn rematch(self: *Controller, now: f64, count: bool) void {
        var buf: [64]u8 = undefined;
        const norm = trigger.normalize(&buf, self.triggerWord());
        const t = self.heard.transcript();
        const before = self.matches.len;
        self.matches = trigger.find(t, norm);
        const new_trigger = count and self.matches.len > before;
        if (new_trigger) {
            self.trigger_seq +%= 1;
            self.triggered_at = now;
        }
        if (self.matches.len > 0) {
            const cmd = trigger.afterLast(t, &self.matches);
            self.command_len = @min(cmd.len, self.command_buf.len);
            @memcpy(self.command_buf[0..self.command_len], cmd[0..self.command_len]);
        }
        if (self.debug orelse false) {
            if (new_trigger) std.debug.print("voice: trigger '{s}' #{d}, after it: '{s}'\n", .{ self.triggerWord(), self.trigger_seq, if (self.debug_quiet) "…" else self.command() });
            const err = self.heard.errorText();
            if (err.len > 0) std.debug.print("voice: recogniser says '{s}'\n", .{err});
        }
    }

    fn pushHistory(self: *Controller, line: *const Line) void {
        if (self.history_count == history_len) {
            std.mem.copyForwards(Line, self.history[0 .. history_len - 1], self.history[1..history_len]);
            self.history_count -= 1;
        }
        self.history[self.history_count] = line.*;
        self.history_count += 1;
    }

    pub fn historyLines(self: *const Controller) []const Line {
        return self.history[0..self.history_count];
    }

    /// What was said after the latest trigger.
    pub fn command(self: *const Controller) []const u8 {
        return self.command_buf[0..self.command_len];
    }

    /// The listener runs and sound comes in.
    pub fn live(self: *const Controller) bool {
        return self.status == .running;
    }

    /// Scripts: `text` is heard as one utterance (a new one each call), as
    /// if the recogniser had said so; no microphone, no macOS.
    pub fn hear(self: *Controller, text: []const u8, now: f64) void {
        if (!self.fake) {
            self.fake = true;
            self.forget();
        }
        self.status = .running;
        const h = &self.heard;
        h.task +%= 1;
        h.seq +%= 1;
        h.text_len = @min(text.len, h.text.len);
        @memcpy(h.text[0..h.text_len], text[0..h.text_len]);
        // A voice's rise and fall on the meter.
        for (0..speech.level_count) |i| {
            const x: f32 = @floatFromInt(i);
            h.levels[i] = if (i < speech.level_count / 3) 0.04 else 0.25 + 0.6 * @abs(@sin(x * 0.7)) * @abs(@sin(x * 0.13));
        }
        h.level_seq +%= 1;
        self.takeHeard(now);
    }

    /// Stops listening (quitting).
    pub fn shutdown(self: *Controller) void {
        if (self.running) self.stopListening();
    }
};

var instance: Controller = .{};

pub fn get() *Controller {
    return &instance;
}

//! Settings › Physical interactions › Voice: voice commands. The microphone
//! tt listens with (which one, and whether macOS lets it recognise speech),
//! the switch and the trigger word, and a live preview of what tt hears —
//! the input level, the words as they are recognised, and the trigger lit
//! up when tt understood it. The commands themselves come later; the
//! preview shows what would be taken as one. The decisions are
//! physical/voice_controller.zig's; this page shows them and sets them.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const icons = @import("../gfx/icons.zig");
const config = @import("../config.zig");
const media = @import("../platform/media.zig");
const speech = @import("../platform/speech.zig");
const voice_controller = @import("../physical/voice_controller.zig");
const trigger = @import("../physical/trigger.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

const row_h: f32 = 40;
const card_pad: f32 = 18; // the regular block padding, in compact mode too
/// Height of a card's title and hint lines.
const card_head: f32 = 70;
const dd_w: f32 = 280;
const dd_h: f32 = 32;
const trigger_w: f32 = 200;
/// The preview: the transcript lines over the level meter.
const meter_h: f32 = 48;
const line_h: f32 = 28;
/// The trigger stays lit this long after it was heard.
const heard_for: f64 = 2.5;

/// The one text field on the page: the trigger word.
const trigger_field = Ui.id("settings.voice.trigger", 1);

pub const Page = struct {
    gpa: std.mem.Allocator,
    focus: field.Focus,
    mics: []media.Device = &.{},
    /// When the microphones and macOS's answers were last read.
    polled: f64 = -1000,
    mic_access: media.Access = .not_determined,
    speech_access: media.Access = .not_determined,
    /// The source dropdown's generated labels (its menu borrows them).
    auto_buf: [300]u8 = undefined,
    missing_buf: [300]u8 = undefined,
    language_count: usize = 0,
    lang_auto_buf: [160]u8 = undefined,
    lang_missing_buf: [160]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *Page) void {
        self.flush();
        self.focus.deinit();
        media.freeDevices(self.gpa, self.mics);
    }

    /// Copies the focused field's text into the config.
    fn flush(self: *Page) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        const cfg = config.get();
        cfg.setString(&cfg.voice.trigger, std.mem.trim(u8, self.focus.editor.bytes(), " \t"));
        self.focus.markSynced();
    }

    /// While the page is on show: keeps the preview coming, and reads the
    /// microphones and macOS's answers again every few seconds. Not while
    /// the source menu is open: it borrows the names. True when something
    /// changed.
    pub fn tick(self: *Page, now: f64, menu_open: bool) bool {
        voice_controller.get().requestPreview(now);
        var changed = self.focus.tick(now);
        // The languages arrive once, a moment after the page first asks.
        const nl = speech.languages().len;
        if (nl != self.language_count) changed = true;
        self.language_count = nl;
        if (now - self.polled < 2.5) return changed;
        self.polled = now;
        const mic = media.access(.microphone);
        const sp = speech.speechAccess();
        if (mic != self.mic_access or sp != self.speech_access) changed = true;
        self.mic_access = mic;
        self.speech_access = sp;
        if (!menu_open) {
            const list = media.devices(self.gpa, .microphone);
            if (!sameDevices(list, self.mics)) changed = true;
            media.freeDevices(self.gpa, self.mics);
            self.mics = list;
        }
        return changed;
    }

    // ── keyboard (routed by the settings tab) ───────────────────────────
    pub fn onText(self: *Page, utf8: []const u8) void {
        self.focus.onText(utf8);
        self.flush();
    }

    pub fn onMarkedText(self: *Page, utf8: []const u8) void {
        self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *Page, utf8: []const u8) void {
        self.focus.paste(utf8);
        self.flush();
    }

    /// True when the field used the command.
    pub fn onEdit(self: *Page, cmd: EditCommand) bool {
        if (!self.focus.active()) return false;
        const used = self.focus.onEdit(cmd);
        self.flush();
        return used;
    }

    pub fn onCtrl(self: *Page, key: u8) bool {
        const used = self.focus.onCtrl(key);
        self.flush();
        return used;
    }

    pub fn copy(self: *Page, out: *std.ArrayList(u8), cut: bool) bool {
        const ok = self.focus.copy(out, cut);
        self.flush();
        return ok;
    }

    pub fn hasMarkedText(self: *const Page) bool {
        return self.focus.hasMarkedText();
    }

    pub fn caretRect(self: *const Page) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    /// Gives the keyboard up (the tab switched page).
    pub fn blur(self: *Page) void {
        self.flush();
        self.focus.drop();
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *Page, ui: *Ui, dd: *field.Dropdown, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        if (self.polled < 0) _ = self.tick(now, dd.isOpen());
        var press_outside = ui.pressed;
        var y = y0;
        y = self.drawMicrophone(ui, dd, x, y, col_w);
        y += theme.block_gap;
        y = self.drawCommands(ui, x, y, col_w, now, &press_outside);
        y += theme.block_gap;
        y = self.drawHearing(ui, x, y, col_w, now);
        // A click anywhere but on the field gives the focus up.
        if (press_outside and self.focus.active()) self.blur();
        self.flush();
        return y;
    }

    // ── the microphone ──────────────────────────────────────────────────
    fn drawMicrophone(self: *Page, ui: *Ui, dd: *field.Dropdown, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 3 * row_h + card_pad - 6 };
        cardHead(ui, card, "Microphone", "The microphone tt listens with. What it hears is recognised on this Mac by macOS and never recorded or sent.");

        // Source: automatic (the macOS default), or one microphone by name.
        var cy = card.y + card_head + row_h / 2;
        dl.icon(.mic, card.x + card_pad, cy - 8, 16, theme.text_2);
        _ = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Source", theme.text);
        var choices: [field.Dropdown.max_choices]field.Choice = undefined;
        const default_name = for (self.mics) |d| {
            if (d.is_default) break d.name;
        } else "";
        choices[0] = .{ .label = if (default_name.len > 0) (std.fmt.bufPrint(&self.auto_buf, "Automatic · {s}", .{default_name}) catch "Automatic") else "Automatic" };
        var n: usize = 1;
        var selected: usize = 0;
        for (self.mics) |d| {
            if (n >= choices.len - 1) break;
            choices[n] = .{ .label = d.name, .sep_before = n == 1 };
            if (std.mem.eql(u8, cfg.voice.microphone, d.name)) selected = n;
            n += 1;
        }
        // A microphone picked before and not connected now keeps its row.
        if (cfg.voice.microphone.len > 0 and selected == 0) {
            choices[n] = .{ .label = std.fmt.bufPrint(&self.missing_buf, "{s} · not connected", .{cfg.voice.microphone}) catch cfg.voice.microphone, .sep_before = true };
            selected = n;
            n += 1;
        }
        const r: Rect = .{ .x = card.right() - card_pad - dd_w, .y = cy - dd_h / 2, .w = dd_w, .h = dd_h };
        if (field.dropdown(ui, dd, Ui.id("settings.voice.source", 0), r, choices[0..n], selected)) |i| {
            if (i == 0) {
                cfg.setString(&cfg.voice.microphone, "");
            } else if (i - 1 < self.mics.len) {
                cfg.setString(&cfg.voice.microphone, self.mics[i - 1].name);
            }
            cfg.save();
        }

        // macOS's two permissions, and what can be done about them.
        cy += row_h;
        dl.icon(.lock, card.x + card_pad, cy - 8, 16, theme.text_2);
        const lw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "macOS access", theme.text);
        var px = card.x + card_pad + 26 + lw + 10;
        if (!speech.usageDescribed()) {
            _ = pill(ui, px, cy, "Speech recognition needs tt.app (zig build app)", .neutral);
        } else {
            var buf: [64]u8 = undefined;
            if (!speech.mocking()) {
                const t = std.fmt.bufPrint(&buf, "Microphone: {s}", .{self.mic_access.label()}) catch "";
                px = pill(ui, px, cy, t, toneOf(self.mic_access)) + 6;
            }
            const t2 = std.fmt.bufPrint(&buf, "Speech recognition: {s}", .{self.speech_access.label()}) catch "";
            _ = pill(ui, px, cy, t2, toneOf(self.speech_access));
            if (self.accessAction()) |label| {
                if (button(ui, Ui.id("settings.voice.access", 0), card.right() - card_pad, cy, label)) self.askMacos();
            }
        }

        // The language spoken: the Mac's, or one it recognises on its own.
        cy += row_h;
        dl.icon(.globe, card.x + card_pad, cy - 8, 16, theme.text_2);
        const gw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Language", theme.text);
        const rec = speech.recognition(cfg.voice.language);
        const gx = card.x + card_pad + 26 + gw + 10;
        if (!rec.supported) {
            _ = pill(ui, gx, cy, "No speech recogniser for it", .bad);
        } else if (!rec.on_device) {
            _ = pill(ui, gx, cy, "Not on this Mac: tt sends no voice elsewhere", .bad);
        } else {
            _ = pill(ui, gx, cy, "Recognised on this Mac", .good);
        }
        const langs = speech.languages();
        const mac = speech.recognition("");
        choices[0] = .{ .label = std.fmt.bufPrint(&self.lang_auto_buf, "Automatic · {s}", .{mac.language}) catch "Automatic" };
        n = 1;
        selected = 0;
        for (langs) |l| {
            if (n >= choices.len - 1) break;
            choices[n] = .{ .label = l.name, .sep_before = n == 1 };
            if (std.mem.eql(u8, cfg.voice.language, l.ident)) selected = n;
            n += 1;
        }
        // A language set by hand that this Mac cannot recognise keeps its row.
        if (cfg.voice.language.len > 0 and selected == 0) {
            choices[n] = .{ .label = std.fmt.bufPrint(&self.lang_missing_buf, "{s} · not on this Mac", .{rec.language}) catch cfg.voice.language, .sep_before = true };
            selected = n;
            n += 1;
        }
        const lr: Rect = .{ .x = card.right() - card_pad - dd_w, .y = cy - dd_h / 2, .w = dd_w, .h = dd_h };
        if (field.dropdown(ui, dd, Ui.id("settings.voice.language", 0), lr, choices[0..n], selected)) |i| {
            if (i == 0) {
                cfg.setString(&cfg.voice.language, "");
            } else if (i - 1 < langs.len) {
                cfg.setString(&cfg.voice.language, langs[i - 1].ident);
            }
            cfg.save();
            voice_controller.get().recheckAccess();
        }
        return card.bottom();
    }

    /// What the access button says, when there is something to do.
    fn accessAction(self: *const Page) ?[]const u8 {
        const mic = if (speech.mocking()) media.Access.authorized else self.mic_access;
        if (mic == .not_determined or self.speech_access == .not_determined) return "Ask macOS";
        if (mic == .denied or self.speech_access == .denied) return "Open System Settings";
        return null;
    }

    fn askMacos(self: *Page) void {
        const mic = if (speech.mocking()) media.Access.authorized else self.mic_access;
        if (mic == .not_determined or self.speech_access == .not_determined) {
            if (mic == .not_determined) media.requestAccess(.microphone);
            if (self.speech_access == .not_determined) speech.requestSpeechAccess();
        } else if (mic == .denied) {
            media.openPrivacySettings(.microphone);
        } else {
            speech.openSpeechPrivacySettings();
        }
        // Read the answers again soon.
        self.polled = -1000;
        voice_controller.get().recheckAccess();
    }

    // ── the switch and the trigger word ─────────────────────────────────
    fn drawCommands(self: *Page, ui: *Ui, x: f32, y: f32, col_w: f32, now: f64, press_outside: *bool) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const vo = &cfg.voice;
        const ctl = voice_controller.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 2 * row_h + card_pad - 6 };
        cardHead(ui, card, "Voice commands", "Say the trigger word, then what tt should do. The commands themselves are coming; for now the preview shows what tt understood.");
        var cy = card.y + card_head + row_h / 2;

        if (switchRow(ui, Ui.id("settings.voice.enabled", 0), card, cy, .mic, "Listen for voice commands", "The microphone stays on while tt is open.", vo.enabled)) {
            vo.enabled = !vo.enabled;
            // Turning it on is the moment to ask macOS, if it never was
            // (only an app can recognise speech: a bare binary never asks).
            if (vo.enabled and speech.usageDescribed()) {
                if (!speech.mocking() and media.access(.microphone) == .not_determined) media.requestAccess(.microphone);
                if (speech.speechAccess() == .not_determined) speech.requestSpeechAccess();
                self.polled = -1000;
            }
            ctl.recheckAccess();
            cfg.save();
        }

        cy += row_h;
        dl.icon(.sparkle, card.x + card_pad, cy - 8, 16, theme.text_2);
        const lw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Trigger word", theme.text);
        const fr: Rect = .{ .x = card.right() - card_pad - trigger_w, .y = cy - field.height / 2, .w = trigger_w, .h = field.height };
        var hint_buf: [96]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Like \u{201c}{s}, open the files\u{201d}.", .{ctl.triggerWord()}) catch "";
        const hx = card.x + card_pad + 26 + lw + 12;
        _ = dl.textEllipsis(theme.font_hint, hx, cy, hint, fr.x - 12 - hx, theme.text_3);
        const res = field.draw(ui, &self.focus, trigger_field, fr, vo.trigger, .{ .placeholder = trigger.default_word });
        if (res.clicked) {
            self.focus.take(trigger_field, vo.trigger, now);
            press_outside.* = false;
        }
        if (ui.pressed and ui.mouseIn(fr)) press_outside.* = false;

        // What the voice commands are doing right now.
        var note_buf: [128]u8 = undefined;
        const note: []const u8 = if (!vo.enabled)
            "Off: the microphone only listens while this page is on show."
        else switch (ctl.status) {
            .running => std.fmt.bufPrint(&note_buf, "On: listening for \u{201c}{s}\u{201d}.", .{ctl.triggerWord()}) catch "On.",
            .no_mic_access => "On, but macOS has not let tt use the microphone yet.",
            .no_speech_access => "On, but macOS has not let tt recognise speech yet.",
            .needs_app => "On, but speech recognition only works in tt.app.",
            .unavailable => "On, but this Mac cannot recognise its language on its own.",
            .no_microphone => "On, but no microphone is connected.",
            .failed => "On, but the microphone could not be started.",
            .starting, .off => "On: starting the microphone…",
        };
        _ = dl.textCentered(theme.font_hint, card.x + card_pad, card.bottom() + 20, note, theme.text_3);
        return card.bottom() + 30;
    }

    // ── what tt hears ───────────────────────────────────────────────────
    fn drawHearing(self: *Page, ui: *Ui, x: f32, y: f32, col_w: f32, now: f64) f32 {
        const dl = ui.dl;
        const ctl = voice_controller.get();
        const inner_w = col_w - 2 * card_pad;
        const lines = voice_controller.history_len + 1;
        const box_h = 14 + lines * line_h + 8 + meter_h + 12;
        const status_h: f32 = 74;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + box_h + status_h };
        cardHead(ui, card, "What tt hears", "Live, as it is recognised. The trigger word lights up when tt understands it.");

        const box: Rect = .{ .x = card.x + card_pad, .y = card.y + card_head, .w = inner_w, .h = box_h };
        dl.rrect(box, 8, theme.bg_inset);
        const heard_now = now - ctl.triggered_at < heard_for;
        if (!ctl.live()) {
            self.drawPlaceholder(ui, box);
        } else {
            // The words on top, newest last, right above the level meter.
            var buf: [64]u8 = undefined;
            const norm = trigger.normalize(&buf, ctl.triggerWord());
            const tw = box.w - 28;
            const hist = ctl.historyLines();
            var ly = box.y + 14 + line_h / 2 + @as(f32, @floatFromInt(voice_controller.history_len - hist.len)) * line_h;
            for (hist) |*l| {
                const m = trigger.find(l.slice(), norm);
                drawHighlighted(ui, box.x + 14, ly, l.slice(), &m, tw, theme.text_3, false);
                ly += line_h;
            }
            const cur = ctl.current.slice();
            if (cur.len > 0) {
                drawHighlighted(ui, box.x + 14, ly, cur, &ctl.matches, tw, theme.text, true);
            } else {
                var say_buf: [96]u8 = undefined;
                const say = std.fmt.bufPrint(&say_buf, "Listening… say \u{201c}{s}\u{201d}.", .{ctl.triggerWord()}) catch "Listening…";
                _ = dl.textCentered(theme.font_ui, box.x + 14, ly, say, theme.text_3);
            }
            drawMeter(ui, .{ .x = box.x + 14, .y = box.bottom() - 12 - meter_h, .w = box.w - 28, .h = meter_h }, &ctl.heard.levels, heard_now);
        }

        // Whether the trigger was understood, and what followed it.
        var cy = box.bottom() + 24;
        const tx = card.x + card_pad;
        var buf: [128]u8 = undefined;
        if (ctl.live()) {
            if (heard_now) {
                const t = std.fmt.bufPrint(&buf, "Heard \u{201c}{s}\u{201d}", .{ctl.triggerWord()}) catch "Heard";
                _ = pill(ui, tx, cy, t, .good);
            } else {
                const t = std.fmt.bufPrint(&buf, "Waiting for \u{201c}{s}\u{201d}", .{ctl.triggerWord()}) catch "Waiting";
                _ = pill(ui, tx, cy, t, .neutral);
            }
            if (ctl.trigger_seq > 0) {
                var count_buf: [48]u8 = undefined;
                const count = std.fmt.bufPrint(&count_buf, "Heard {d} time{s}", .{ ctl.trigger_seq, if (ctl.trigger_seq == 1) "" else "s" }) catch "";
                const cw = ui.text.measure(theme.font_hint, count);
                _ = dl.textCentered(theme.font_hint, card.right() - card_pad - cw, cy, count, theme.text_3);
            }
        } else {
            _ = dl.textCentered(theme.font_ui, tx, cy, "Not listening.", theme.text_3);
        }

        cy += 28;
        var detail_buf: [320]u8 = undefined;
        _ = dl.textEllipsis(theme.font_hint, tx, cy, detailLine(&detail_buf, ctl), card.w - 2 * card_pad, theme.text_3);
        return card.bottom();
    }

    fn drawPlaceholder(self: *Page, ui: *Ui, box: Rect) void {
        const dl = ui.dl;
        const ctl = voice_controller.get();
        const text: []const u8 = if (!ctl.allow_device and !speech.mocking())
            "No microphone in headless runs: the script command hear stands in."
        else switch (ctl.status) {
            .needs_app => "macOS only lets an app recognise speech: open tt.app.",
            .no_speech_access => switch (self.speech_access) {
                .denied, .restricted => "macOS does not let tt recognise speech.",
                else => "tt needs macOS's permission to recognise speech.",
            },
            .no_mic_access => switch (self.mic_access) {
                .denied, .restricted => "macOS does not let tt use the microphone.",
                else => "tt needs macOS's permission to use the microphone.",
            },
            .unavailable => "This Mac cannot recognise its language on its own.",
            .no_microphone => "No microphone is connected.",
            .failed => "The microphone could not be started. Another app may be holding it.",
            .starting => "Starting the microphone…",
            .running => "Listening…",
            .off => "The microphone is off.",
        };
        const cy = box.y + box.h / 2;
        dl.icon(.mic, box.x + box.w / 2 - 12, cy - 44, 24, theme.text_3);
        const tw = ui.text.measure(theme.font_ui, text);
        _ = dl.textCentered(theme.font_ui, box.x + (box.w - tw) / 2, cy, text, theme.text_2);
        if ((ctl.status == .no_mic_access or ctl.status == .no_speech_access) and ctl.allow_device) {
            if (self.accessAction()) |label| {
                const bw = ui.text.measure(theme.font_hint, label) + 24;
                if (button(ui, Ui.id("settings.voice.access", 1), box.x + (box.w + bw) / 2, cy + 36, label)) self.askMacos();
            }
        }
    }
};

// ── the preview's drawing ───────────────────────────────────────────────

/// The input level as bars, oldest at the left; accent while the trigger
/// is lit.
fn drawMeter(ui: *Ui, r: Rect, levels: *const [speech.level_count]f32, lit: bool) void {
    const dl = ui.dl;
    const n: f32 = @floatFromInt(speech.level_count);
    const step = r.w / n;
    const bar_w = @max(2, step * 0.55);
    const color = if (lit) theme.accent else theme.text_3;
    for (levels, 0..) |lv, i| {
        const h = @max(3, lv * r.h);
        const bx = r.x + @as(f32, @floatFromInt(i)) * step + (step - bar_w) / 2;
        dl.rrect(.{ .x = bx, .y = r.y + (r.h - h) / 2, .w = bar_w, .h = h }, bar_w / 2, color.alpha(0.35 + 0.65 * std.math.clamp(lv * 1.4, 0, 1)));
    }
}

/// One line of transcript with its trigger words marked; when it is too
/// wide, its end shows (after "…"). `strong`: the current line, marked in
/// the accent; the history's marks are fainter.
fn drawHighlighted(ui: *Ui, x: f32, cy: f32, text: []const u8, matches: *const trigger.Matches, max_w: f32, color: Color, strong: bool) void {
    const dl = ui.dl;
    const font = theme.font_ui;
    const ell = "\u{2026} ";
    var start: usize = 0;
    if (ui.text.measure(font, text) > max_w) {
        const room = max_w - ui.text.measure(font, ell) - 8;
        // Drop words from the front until the rest fits.
        while (start < text.len and ui.text.measure(font, text[start..]) > room) {
            start = if (std.mem.indexOfScalarPos(u8, text, start + 1, ' ')) |sp| sp + 1 else text.len;
        }
    }
    var cx = x;
    if (start > 0) cx += dl.textCentered(font, cx, cy, ell, theme.text_3);
    var pos = start;
    for (matches.slice()) |m| {
        if (m.end <= pos) continue;
        const ms = @max(m.start, pos);
        if (ms > pos) cx += dl.textCentered(font, cx, cy, text[pos..ms], color);
        // The mark is padded on both sides, and the words around it make room.
        const word = text[ms..m.end];
        const ww = ui.text.measure(font, word);
        const hl: Rect = .{ .x = cx, .y = cy - 11, .w = ww + 10, .h = 22 };
        dl.rrect(hl, 6, if (strong) theme.accent else theme.accent.alpha(0.22));
        _ = dl.textCentered(font, cx + 5, cy, word, if (strong) theme.on_accent else theme.text_2);
        cx += ww + 10;
        pos = m.end;
    }
    if (pos < text.len) _ = dl.textCentered(font, cx, cy, text[pos..], color);
}

/// The line under the preview: the microphone, the recogniser, what
/// followed the trigger, or the recogniser's complaint.
fn detailLine(buf: []u8, ctl: *const voice_controller.Controller) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const err = ctl.heard.errorText();
    if (err.len > 0) {
        w.print("The recogniser says: {s}", .{err}) catch {};
        return w.buffered();
    }
    const cmd = ctl.command();
    if (ctl.matches.len > 0 and cmd.len > 0) {
        w.print("After the trigger: \u{201c}{s}\u{201d} (not acted on yet)", .{cmd}) catch {};
        return w.buffered();
    }
    var name_buf: [256]u8 = undefined;
    const name = if (ctl.fake) "Text from the script (hear)" else speech.runningName(&name_buf);
    const rec = speech.recognition(config.get().voice.language);
    if (name.len > 0) w.print("{s} · ", .{name}) catch {};
    if (rec.supported) w.print("recognised on this Mac in {s}", .{rec.language}) catch {} else w.writeAll("no recogniser for this Mac's language") catch {};
    return w.buffered();
}

// ── small parts (as on the camera page) ─────────────────────────────────

fn cardHead(ui: *Ui, card: Rect, title: []const u8, hint: []const u8) void {
    const dl = ui.dl;
    dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
    _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, title, theme.text);
    _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, hint, card.w - 2 * card_pad, theme.text_3);
}

const Tone = enum { good, bad, neutral };

fn toneOf(a: media.Access) Tone {
    return switch (a) {
        .authorized => .good,
        .denied, .restricted => .bad,
        .not_determined => .neutral,
    };
}

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

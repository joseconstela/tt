//! Settings › Permissions: what websites in tabs may use. Two pages —
//! Camera & microphone, Notifications — each with the same three parts:
//! what macOS lets tt do (every app needs its own yes from macOS first),
//! what a website gets when it asks (Ask / Allow / Block, config.browser),
//! and the answers kept for each site (config.sites), which can be changed
//! or forgotten here. The asking itself happens in the website tab, in the
//! bar under the address bar (tabs/web_tab.zig).
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const icons = @import("../gfx/icons.zig");
const config = @import("../config.zig");
const media = @import("../platform/media.zig");
const notify = @import("../platform/notify.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const row_h: f32 = 40;
const card_pad = theme.block_pad_x;
/// Height of a card's title and hint lines.
const card_head: f32 = 70;

/// Camera & microphone.
pub const MediaPage = struct {
    gpa: std.mem.Allocator,
    cameras: []media.Device = &.{},
    mics: []media.Device = &.{},
    /// When the device lists and macOS's answers were last read.
    polled: f64 = -1000,
    access_cam: media.Access = .not_determined,
    access_mic: media.Access = .not_determined,

    pub fn init(gpa: std.mem.Allocator) MediaPage {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MediaPage) void {
        media.freeDevices(self.gpa, self.cameras);
        media.freeDevices(self.gpa, self.mics);
    }

    /// Devices come and go (a USB camera, AirPods) and macOS's answer can
    /// change in System Settings: read again every few seconds while the
    /// page is on show. True when something changed.
    pub fn tick(self: *MediaPage, now: f64) bool {
        if (now - self.polled < 2.5) return false;
        self.polled = now;
        const cam = media.access(.camera);
        const mic = media.access(.microphone);
        var changed = cam != self.access_cam or mic != self.access_mic;
        self.access_cam = cam;
        self.access_mic = mic;
        const cameras = media.devices(self.gpa, .camera);
        const mics = media.devices(self.gpa, .microphone);
        if (!sameDevices(cameras, self.cameras) or !sameDevices(mics, self.mics)) changed = true;
        media.freeDevices(self.gpa, self.cameras);
        media.freeDevices(self.gpa, self.mics);
        self.cameras = cameras;
        self.mics = mics;
        return changed;
    }

    pub fn draw(self: *MediaPage, ui: *Ui, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        if (self.polled < 0) _ = self.tick(now);
        const cfg = config.get();
        var y = y0;
        y = self.drawAccess(ui, x, y, col_w);
        y += theme.block_gap;
        y = drawDefaults(ui, cfg, x, y, col_w, &.{ .camera, .microphone }, "When a website asks", "Ask shows a bar under the address bar; the answer is kept for that site.");
        y += theme.block_gap;
        y = drawSites(ui, cfg, x, y, col_w, &.{ .camera, .microphone }, "No website has asked for the camera or the microphone yet.");
        y += theme.block_gap;
        y = self.drawDevices(ui, x, y, col_w);
        return y;
    }

    /// macOS's switch for tt, per device kind, and what can be done about it.
    fn drawAccess(self: *MediaPage, ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 2 * row_h + card_pad - 6 };
        cardHead(ui, card, "macOS access", "macOS must let tt use them before any website can, whatever is set below.");
        var ry = card.y + card_head;
        for ([_]media.Kind{ .camera, .microphone }, 0..) |kind, i| {
            const acc = if (kind == .camera) self.access_cam else self.access_mic;
            const cy = ry + row_h / 2;
            dl.icon(if (kind == .camera) .camera else .mic, card.x + card_pad, cy - 8, 16, theme.text_2);
            const name = if (kind == .camera) "Camera" else "Microphone";
            const nw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, name, theme.text);
            _ = statusPill(ui, card.x + card_pad + 26 + nw + 10, cy, acc.label(), switch (acc) {
                .authorized => .good,
                .denied, .restricted => .bad,
                .not_determined => .neutral,
            });
            const label: ?[]const u8 = switch (acc) {
                .not_determined => "Ask macOS",
                .denied => "Open System Settings",
                .authorized, .restricted => null,
            };
            if (label) |l| {
                const bw = ui.text.measure(theme.font_hint, l) + 24;
                const br: Rect = .{ .x = card.right() - card_pad - bw, .y = cy - 13, .w = bw, .h = 26 };
                dl.shape(br, 7, theme.bg_block, 1, theme.line_strong);
                if (field.textButton(ui, Ui.id("settings.perm.access", i), br, l, theme.text)) {
                    if (acc == .not_determined) media.requestAccess(kind) else media.openPrivacySettings(kind);
                    self.polled = -1000; // read the answer again soon
                }
            }
            ry += row_h;
        }
        return card.bottom();
    }

    /// The devices macOS has, the default marked. Informational: the site
    /// picks among them (Teams, say, in its own device settings).
    fn drawDevices(self: *MediaPage, ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const rows = @max(self.cameras.len, 1) + @max(self.mics.len, 1);
        const small_h: f32 = 32;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + @as(f32, @floatFromInt(rows)) * small_h + card_pad - 4 };
        cardHead(ui, card, "Devices", "What this Mac has; websites start on the macOS default and let you switch in their own settings.");
        var ry = card.y + card_head;
        for ([_]media.Kind{ .camera, .microphone }) |kind| {
            const list = if (kind == .camera) self.cameras else self.mics;
            const icon: icons.Icon = if (kind == .camera) .camera else .mic;
            if (list.len == 0) {
                const cy = ry + small_h / 2;
                dl.icon(icon, card.x + card_pad, cy - 7, 14, theme.text_3);
                _ = dl.textCentered(theme.font_hint, card.x + card_pad + 26, cy, if (kind == .camera) "No camera found." else "No microphone found.", theme.text_3);
                ry += small_h;
                continue;
            }
            for (list) |d| {
                const cy = ry + small_h / 2;
                dl.icon(icon, card.x + card_pad, cy - 7, 14, theme.text_3);
                const nw = @min(ui.text.measure(theme.font_ui, d.name), card.w - 2 * card_pad - 26 - 110);
                _ = dl.textEllipsis(theme.font_ui, card.x + card_pad + 26, cy, d.name, nw + 1, theme.text);
                if (d.is_default) _ = statusPill(ui, card.x + card_pad + 26 + nw + 10, cy, "Default", .neutral);
                ry += small_h;
            }
        }
        return card.bottom();
    }
};

fn sameDevices(a: []const media.Device, b: []const media.Device) bool {
    if (a.len != b.len) return false;
    for (a, b) |p, q| {
        if (p.is_default != q.is_default or !std.mem.eql(u8, p.name, q.name)) return false;
    }
    return true;
}

/// Notifications.
pub const NotificationsPage = struct {
    polled: f64 = -1000,
    auth_seen: notify.Auth = .unknown,
    /// "Send a test" was pressed: say where to look.
    test_sent_at: f64 = -1000,

    pub fn init() NotificationsPage {
        return .{};
    }

    /// macOS's answer can change in System Settings (and arrives a moment
    /// after it is asked for): ask again every few seconds while on show.
    pub fn tick(self: *NotificationsPage, now: f64) bool {
        if (now - self.polled >= 2.5) {
            self.polled = now;
            notify.refreshAuth();
        }
        const a = notify.auth();
        if (a == self.auth_seen) return false;
        self.auth_seen = a;
        return true;
    }

    pub fn draw(self: *NotificationsPage, ui: *Ui, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        const cfg = config.get();
        var y = y0;
        y = self.drawMacos(ui, x, y, col_w, now);
        y += theme.block_gap;
        y = drawDefaults(ui, cfg, x, y, col_w, &.{.notifications}, "When a website asks", "Ask shows a bar under the address bar; the answer is kept for that site.");
        y += theme.block_gap;
        y = drawSites(ui, cfg, x, y, col_w, &.{.notifications}, "No website has asked to show notifications yet.");
        return y;
    }

    fn drawMacos(self: *NotificationsPage, ui: *Ui, x: f32, y: f32, col_w: f32, now: f64) f32 {
        const dl = ui.dl;
        const a = notify.auth();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + row_h + card_pad - 6 };
        cardHead(ui, card, "macOS", "Notifications show the site's name and icon, and bring its tab back when clicked.");
        const cy = card.y + card_head + row_h / 2;
        dl.icon(.bell, card.x + card_pad, cy - 8, 16, theme.text_2);
        const nw = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, "Notifications from tt", theme.text);
        _ = statusPill(ui, card.x + card_pad + 26 + nw + 10, cy, a.label(), switch (a) {
            .authorized => .good,
            .denied, .unavailable => .bad,
            .unknown, .not_determined => .neutral,
        });

        var bx = card.right() - card_pad;
        if (a == .unavailable) {
            const hint = "Build and open zig-out/tt.app (zig build app): macOS only notifies from an app bundle.";
            _ = dl.textRightEllipsis(theme.font_hint, bx, cy, hint, bx - (card.x + card_pad + 26 + nw + 120), theme.text_3);
            return card.bottom();
        }
        // Right to left: Send a test, then Ask macOS / Open System Settings.
        const test_label = if (now - self.test_sent_at < 4) "Sent — look top right" else "Send a test";
        const tw = ui.text.measure(theme.font_hint, test_label) + 24;
        bx -= tw;
        const tr: Rect = .{ .x = bx, .y = cy - 13, .w = tw, .h = 26 };
        dl.shape(tr, 7, theme.bg_block, 1, theme.line_strong);
        if (field.textButton(ui, Ui.id("settings.notify.test", 0), tr, test_label, theme.text)) {
            notify.sendTest();
            self.test_sent_at = now;
        }
        const other = if (a == .not_determined) "Ask macOS" else "Open System Settings";
        const ow = ui.text.measure(theme.font_hint, other) + 24;
        bx -= 8 + ow;
        const orr: Rect = .{ .x = bx, .y = cy - 13, .w = ow, .h = 26 };
        dl.shape(orr, 7, theme.bg_block, 1, theme.line_strong);
        if (field.textButton(ui, Ui.id("settings.notify.macos", 0), orr, other, theme.text)) {
            if (a == .not_determined) notify.requestAuth() else notify.openSystemSettings();
            self.polled = -1000;
        }
        return card.bottom();
    }
};

// ── shared parts ────────────────────────────────────────────────────────

fn cardHead(ui: *Ui, card: Rect, title: []const u8, hint: []const u8) void {
    const dl = ui.dl;
    dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
    _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, title, theme.text);
    _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, hint, card.w - 2 * card_pad, theme.text_3);
}

const Tone = enum { good, bad, neutral };

/// A small rounded tag ("Allowed", "Off", "Default"); returns its right edge.
fn statusPill(ui: *Ui, x: f32, cy: f32, text: []const u8, tone: Tone) f32 {
    const tw = ui.text.measure(theme.font_chip, text);
    const pill: Rect = .{ .x = x, .y = cy - 9, .w = tw + 14, .h = 18 };
    const bg: Color = switch (tone) {
        .good => theme.accent.alpha(0.16),
        .bad => theme.red.alpha(0.16),
        .neutral => theme.chip_active,
    };
    ui.dl.rrect(pill, 9, bg);
    _ = ui.dl.textCentered(theme.font_chip, pill.x + 7, cy, text, if (tone == .neutral) theme.text_3 else theme.text);
    return pill.right();
}

/// The Ask / Allow / Block choice per feature: what a site without an
/// answer of its own gets.
fn drawDefaults(ui: *Ui, cfg: *config.Config, x: f32, y: f32, col_w: f32, features: []const config.SiteFeature, title: []const u8, hint: []const u8) f32 {
    const dl = ui.dl;
    const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + @as(f32, @floatFromInt(features.len)) * row_h + card_pad - 6 };
    cardHead(ui, card, title, hint);
    var ry = card.y + card_head;
    const choices = [_]config.Permission{ .ask, .allow, .block };
    for (features) |f| {
        const cy = ry + row_h / 2;
        dl.icon(featureIcon(f), card.x + card_pad, cy - 8, 16, theme.text_2);
        _ = dl.textCentered(theme.font_ui, card.x + card_pad + 26, cy, f.label(), theme.text);
        var w: f32 = 0;
        for (choices) |c| w += field.chipWidth(ui, c.label()) + 6;
        var cx = card.right() - card_pad - w + 6;
        const current = cfg.browser.default(f);
        for (choices, 0..) |c, k| {
            const cw = field.chipWidth(ui, c.label());
            if (field.chip(ui, Ui.id("settings.perm.default", @as(usize, @intFromEnum(f)) * 4 + k), .{ .x = cx, .y = cy - 13, .w = cw, .h = 26 }, c.label(), current == c)) {
                cfg.setDefaultPermission(f, c);
                cfg.save();
            }
            cx += cw + 6;
        }
        ry += row_h;
    }
    return card.bottom();
}

/// The sites that have an answer for any of `features`: the answer per
/// feature (Allow / Block, changeable) and Remove, which takes the answers
/// back so the site asks again; Remove all does that for every site.
fn drawSites(ui: *Ui, cfg: *config.Config, x: f32, y: f32, col_w: f32, features: []const config.SiteFeature, empty: []const u8) f32 {
    const dl = ui.dl;
    // The sites to list, by index (the list may change under a click).
    var idx_buf: [64]usize = undefined;
    var n: usize = 0;
    for (cfg.sites.items, 0..) |st, i| {
        var any = false;
        for (features) |f| {
            if (st.get(f) != .ask) any = true;
        }
        if (any and n < idx_buf.len) {
            idx_buf[n] = i;
            n += 1;
        }
    }
    const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + @as(f32, @floatFromInt(@max(n, 1))) * row_h + card_pad - 6 };
    cardHead(ui, card, "Websites", "The answers kept per site. Remove one and the site has to ask again.");
    var ry = card.y + card_head;
    if (n == 0) {
        _ = dl.textCentered(theme.font_hint, card.x + card_pad, ry + row_h / 2, empty, theme.text_3);
        return card.bottom();
    }
    {
        const label = "Remove all";
        const w = ui.text.measure(theme.font_hint, label) + 20;
        const r: Rect = .{ .x = card.right() - card_pad - w, .y = card.y + 16, .w = w, .h = 24 };
        if (field.textButton(ui, Ui.id("settings.perm.remove_all", @intFromEnum(features[0])), r, label, theme.text_2)) {
            cfg.removeAllSitePermissions(features);
            cfg.save();
            return card.bottom();
        }
    }
    const choices = [_]config.Permission{ .allow, .block };
    for (idx_buf[0..n], 0..) |si, row| {
        if (si >= cfg.sites.items.len) break;
        const st = cfg.sites.items[si];
        const cy = ry + row_h / 2;

        // Right to left: Remove, then per feature its chips and a label.
        var rx = card.right() - card_pad;
        const fw = ui.text.measure(theme.font_hint, "Remove") + 20;
        rx -= fw;
        const remove: Rect = .{ .x = rx, .y = cy - 12, .w = fw, .h = 24 };
        var remove_clicked = false;
        if (field.textButton(ui, Ui.id("settings.perm.remove", row * 8 + @as(usize, @intFromEnum(features[0]))), remove, "Remove", theme.text_2)) remove_clicked = true;
        rx -= 14;
        var set: ?struct { f: config.SiteFeature, p: config.Permission } = null;
        var fi = features.len;
        while (fi > 0) {
            fi -= 1;
            const f = features[fi];
            var cw_total: f32 = 0;
            for (choices) |c| cw_total += field.chipWidth(ui, c.label()) + 6;
            var cx = rx - cw_total + 6;
            const chips_x = cx;
            for (choices, 0..) |c, k| {
                const cw = field.chipWidth(ui, c.label());
                if (field.chip(ui, Ui.id("settings.perm.site", (row * 4 + @as(usize, @intFromEnum(f))) * 4 + k), .{ .x = cx, .y = cy - 13, .w = cw, .h = 26 }, c.label(), st.get(f) == c)) set = .{ .f = f, .p = c };
                cx += cw + 6;
            }
            rx = chips_x - 6;
            if (features.len > 1) {
                dl.icon(featureIcon(f), rx - 16, cy - 7, 14, theme.text_3);
                rx -= 16 + 14;
            }
        }
        _ = dl.textEllipsis(theme.font_ui, card.x + card_pad, cy, notify.siteName(st.origin), @max(0, rx - card.x - card_pad - 8), theme.text);

        if (set) |s| {
            cfg.setSitePermission(st.origin, s.f, s.p);
            cfg.save();
        } else if (remove_clicked) {
            cfg.removeSitePermissions(st.origin, features);
            cfg.save();
            // The list changed under the loop.
            break;
        }
        ry += row_h;
    }
    return card.bottom();
}

fn featureIcon(f: config.SiteFeature) icons.Icon {
    return switch (f) {
        .camera => .camera,
        .microphone => .mic,
        .notifications => .bell,
    };
}

//! The Settings tab. Its pages are grouped in sections; while the tab is in
//! front the sidebar shows them as the navigation menu (see `sidebar.zig`)
//! and this file draws the selected page. What the pages change lives in
//! `config.zig` and is written to `~/.tt/config.yml`.
const std = @import("std");
const tab_mod = @import("tab.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const themes = @import("../ui/themes.zig");
const field = @import("../ui/field.zig");
const icons = @import("../gfx/icons.zig");
const config = @import("../config.zig");
const appearance = @import("../appearance.zig");
const apis_mod = @import("settings_apis.zig");
const coding_mod = @import("settings_coding_agents.zig");
const features_mod = @import("settings_features.zig");
const browser_mod = @import("settings_browser.zig");
const perms_mod = @import("settings_permissions.zig");
const physical_mod = @import("settings_physical.zig");
const voice_mod = @import("settings_voice.zig");
const mode_mod = @import("settings_mode.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Font = ui_mod.Font;

/// A page of the settings, in menu order.
pub const Page = enum {
    /// The colours: tt's own, e-ink, or a terminal theme; per display too.
    style,
    /// How much room the UI takes: compact mode, NT mode.
    mode,
    /// The model APIs (a model at a provider, with its key).
    apis,
    /// The coding agents installed on this Mac.
    agents,
    mcps,
    features,
    /// How website tabs behave: where links open, the homepage.
    browser,
    /// What website tabs keep and ask: cookies, Do Not Track.
    privacy,
    /// What websites may use: the camera and the microphone …
    media,
    /// … and desktop notifications.
    notifications,
    /// The camera tt watches with, what it recognises, and the away blur.
    physical,
    /// Voice commands: the microphone, the trigger word, what tt hears.
    voice,

    pub fn label(self: Page) []const u8 {
        return switch (self) {
            .style => "Style",
            .mode => "Mode",
            .apis => "APIs",
            .agents => "Agents",
            .mcps => "MCPs",
            .features => "Features",
            .browser => "Website tabs",
            .privacy => "Privacy",
            .media => "Camera & microphone",
            .notifications => "Notifications",
            .physical => "Camera & posture",
            .voice => "Voice",
        };
    }

    pub fn icon(self: Page) icons.Icon {
        return switch (self) {
            .style => .drop,
            .mode => .compact,
            .apis => .cloud,
            .agents => .agent,
            .mcps => .plug,
            .features => .sparkle,
            .browser => .globe,
            .privacy => .lock,
            .media => .camera,
            .notifications => .bell,
            .physical => .eye,
            .voice => .mic,
        };
    }

    /// One line under the page title.
    pub fn blurb(self: Page) []const u8 {
        return switch (self) {
            .style => "Colours for the workspace: tt's own, e-ink, or a classic terminal theme.",
            .mode => "How much room tt's interface takes, and who it is shaped for.",
            .apis => "The models tt can talk to: hosted providers, or Ollama on this Mac.",
            .agents => "The coding agents installed on this Mac, for fixing what fails.",
            .mcps => "Model Context Protocol servers your agents can use.",
            .features => "What your APIs and agents are used for.",
            .browser => "Where links open and what a new website tab starts on.",
            .privacy => "What websites may keep, and what tt asks of them.",
            .media => "Which websites may use the camera and the microphone, for calls in a tab.",
            .notifications => "Desktop notifications from websites, with each site's icon.",
            .physical => "What the camera sees, recognised on this Mac, and what tt does about it.",
            .voice => "Voice commands: what the microphone hears, recognised on this Mac, and the word that starts one.",
        };
    }

    /// False while the page only says "coming up soon".
    pub fn ready(self: Page) bool {
        return switch (self) {
            .style, .mode, .apis, .agents, .features, .browser, .privacy, .media, .notifications, .physical, .voice => true,
            .mcps => false,
        };
    }

    pub fn section(self: Page) *const Section {
        for (&sections) |*s| {
            for (s.pages) |p| {
                if (p == self) return s;
            }
        }
        unreachable;
    }
};

/// A group of pages under one heading of the menu.
pub const Section = struct {
    title: []const u8,
    pages: []const Page,
};

pub const sections = [_]Section{
    .{ .title = "UI", .pages = &.{ .style, .mode } },
    .{ .title = "AI", .pages = &.{ .apis, .agents, .mcps, .features } },
    .{ .title = "Browser", .pages = &.{ .browser, .privacy, .media, .notifications } },
    .{ .title = "Physical interactions", .pages = &.{ .physical, .voice } },
};

pub const SettingsTab = struct {
    pub const kind_label = "Settings";
    /// Name the kind is registered under (`app.zig`); how `fromTab` tells
    /// this tab from the others.
    pub const kind_name = "settings";

    gpa: std.mem.Allocator,
    page: Page = .style,
    apis: apis_mod.Page,
    agents: coding_mod.Page,
    features: features_mod.Page,
    browser: browser_mod.Page,
    media: perms_mod.MediaPage,
    notifications: perms_mod.NotificationsPage,
    physical: physical_mod.Page,
    voice: voice_mod.Page,
    /// The page drawn last frame: a switch resets the scroll and the focus.
    shown: Page = .style,
    /// The Style page's dropdowns.
    dd: field.Dropdown = .{},
    scroll: f32 = 0,
    /// Height of the page content and of the view, from the last frame.
    content_h: f32 = 0,
    view_h: f32 = 0,

    pub fn create(env: *tab_mod.Env, _: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(SettingsTab);
        self.* = .{ .gpa = env.gpa, .apis = apis_mod.Page.init(env.gpa), .agents = coding_mod.Page.init(env.gpa), .features = features_mod.Page.init(env.gpa), .browser = browser_mod.Page.init(env.gpa), .media = perms_mod.MediaPage.init(env.gpa), .notifications = perms_mod.NotificationsPage.init(), .physical = physical_mod.Page.init(env.gpa, env.textures), .voice = voice_mod.Page.init(env.gpa) };
        return tab_mod.Tab.from(SettingsTab, self);
    }

    pub fn deinit(self: *SettingsTab) void {
        self.apis.deinit();
        self.agents.deinit();
        self.features.deinit();
        self.browser.deinit();
        self.media.deinit();
        self.physical.deinit();
        self.voice.deinit();
        self.gpa.destroy(self);
    }

    /// The settings tab behind a generic tab, when that is what it is.
    pub fn fromTab(t: tab_mod.Tab) ?*SettingsTab {
        if (!std.mem.eql(u8, t.kind, kind_name)) return null;
        return @ptrCast(@alignCast(t.ptr));
    }

    /// Context line in the tab strip: where in the settings we are.
    pub fn info(self: *SettingsTab, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} › {s}", .{ self.page.section().title, self.page.label() }) catch "";
    }

    pub fn tick(self: *SettingsTab, now: f64, active: bool) bool {
        return switch (self.page) {
            .apis => self.apis.tick(now),
            .features => self.features.tick(now, active),
            .browser => self.browser.tick(now),
            // Only while on show: these ask macOS about devices and access.
            .media => active and self.media.tick(now),
            .notifications => active and self.notifications.tick(now),
            // Only while on show: it keeps the camera's preview coming.
            .physical => active and self.physical.tick(now, self.dd.isOpen()),
            // Only while on show: it keeps the microphone's preview coming.
            .voice => active and self.voice.tick(now, self.dd.isOpen()),
            else => false,
        };
    }

    // ── keyboard: to the page with a focused field, else page scrolling ──
    pub fn onText(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.onText(utf8),
            .features => self.features.onText(utf8),
            .browser => self.browser.onText(utf8),
            .voice => self.voice.onText(utf8),
            else => {},
        }
    }

    pub fn onMarkedText(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.onMarkedText(utf8),
            .features => self.features.onMarkedText(utf8),
            .browser => self.browser.onMarkedText(utf8),
            .voice => self.voice.onMarkedText(utf8),
            else => {},
        }
    }

    pub fn onEdit(self: *SettingsTab, cmd: EditCommand) void {
        if (self.dd.onEdit(cmd)) return;
        const used = switch (self.page) {
            .apis => self.apis.onEdit(cmd),
            .features => self.features.onEdit(cmd),
            .browser => self.browser.onEdit(cmd),
            .voice => self.voice.onEdit(cmd),
            else => false,
        };
        if (used) return;
        const max = @max(0, self.content_h - self.view_h);
        self.scroll = std.math.clamp(switch (cmd) {
            .move_up => self.scroll - 40,
            .move_down => self.scroll + 40,
            .page_up => self.scroll - self.view_h * 0.9,
            .page_down => self.scroll + self.view_h * 0.9,
            .scroll_to_top, .move_doc_start => 0,
            .scroll_to_bottom, .move_doc_end => max,
            else => self.scroll,
        }, 0, max);
    }

    pub fn onCtrl(self: *SettingsTab, key: u8) void {
        switch (self.page) {
            .apis => _ = self.apis.onCtrl(key),
            .browser => _ = self.browser.onCtrl(key),
            .voice => _ = self.voice.onCtrl(key),
            else => {},
        }
    }

    pub fn paste(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.paste(utf8),
            .features => self.features.paste(utf8),
            .browser => self.browser.paste(utf8),
            .voice => self.voice.paste(utf8),
            else => {},
        }
    }

    pub fn copy(self: *SettingsTab, out: *std.ArrayList(u8), cut: bool) bool {
        return switch (self.page) {
            .apis => self.apis.copy(out, cut),
            .features => self.features.copy(out, cut),
            .browser => self.browser.copy(out, cut),
            .voice => self.voice.copy(out, cut),
            else => false,
        };
    }

    pub fn hasMarkedText(self: *SettingsTab) bool {
        return switch (self.page) {
            .apis => self.apis.hasMarkedText(),
            .features => self.features.hasMarkedText(),
            .browser => self.browser.hasMarkedText(),
            .voice => self.voice.hasMarkedText(),
            else => false,
        };
    }

    pub fn caretRect(self: *SettingsTab) Rect {
        return switch (self.page) {
            .apis => self.apis.caretRect(),
            .features => self.features.caretRect(),
            .browser => self.browser.caretRect(),
            .voice => self.voice.caretRect(),
            else => .{},
        };
    }

    /// ⌘Z / ⇧⌘Z go to the page with a focused field.
    pub fn command(self: *SettingsTab, cmd: tab_mod.Command) bool {
        return switch (self.page) {
            .features => self.features.command(cmd),
            else => false,
        };
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *SettingsTab, ui: *Ui, rect: Rect, focused: bool) void {
        const dl = ui.dl;
        if (self.page != self.shown) {
            if (self.shown == .apis) self.apis.blur();
            if (self.shown == .features) self.features.blur();
            if (self.shown == .browser) self.browser.blur();
            if (self.shown == .voice) self.voice.blur();
            self.shown = self.page;
            self.scroll = 0;
            self.dd.close();
        }
        self.view_h = rect.h;
        const max_scroll = @max(0, self.content_h - rect.h);
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);

        dl.pushClip(rect);
        defer dl.popClip();
        const col_w = @max(240, @min(theme.content_max_w, rect.w - 2 * theme.content_pad));
        const x = rect.x + (rect.w - col_w) / 2;
        const top = rect.y - self.scroll;
        var y = top + 40;

        // An open dropdown menu is modal within the page.
        const mouse_inside = ui.mouse_inside;
        if (self.dd.isOpen()) ui.mouse_inside = false;

        const page = self.page;
        var crumb_buf: [64]u8 = undefined;
        const crumb = std.fmt.bufPrint(&crumb_buf, "Settings › {s}", .{page.section().title}) catch "Settings";
        _ = dl.textCentered(theme.font_section, x, y, crumb, theme.text_3);
        y += 24;
        _ = dl.textCentered(Font.semibold(22), x, y, page.label(), theme.text);
        y += 30;
        _ = dl.textCentered(theme.font_ui, x, y, page.blurb(), theme.text_3);
        y += 40;

        y = switch (page) {
            .style => self.drawStyle(ui, x, y, col_w),
            .mode => mode_mod.draw(ui, x, y, col_w),
            .apis => self.apis.draw(ui, x, y, col_w, ui.now),
            .agents => self.agents.draw(ui, x, y, col_w),
            .features => self.features.draw(ui, x, y, col_w, focused),
            .browser => self.browser.draw(ui, x, y, col_w, ui.now),
            .privacy => browser_mod.drawPrivacyPage(ui, x, y, col_w),
            .media => self.media.draw(ui, x, y, col_w, ui.now),
            .notifications => self.notifications.draw(ui, x, y, col_w, ui.now),
            .physical => self.physical.draw(ui, &self.dd, x, y, col_w, ui.now),
            .voice => self.voice.draw(ui, &self.dd, x, y, col_w, ui.now),
            else => drawSoon(ui, x, y, col_w),
        };

        // Where all of this is kept.
        y += 22;
        _ = dl.textCentered(theme.font_hint, x, y, "Saved in ~/.tt/config.yml, which can be edited by hand.", theme.text_3);
        y += 24;
        self.content_h = y - top;

        ui.mouse_inside = mouse_inside;
        if (self.dd.isOpen()) {
            self.dd.drawMenu(ui, rect);
            return;
        }

        // The wheel scrolls the page with whatever a widget inside (the
        // prompt box) has not taken; the pages drew with the old offset,
        // so ask for a frame.
        const dy = ui.takeScroll(rect);
        if (dy != 0) {
            self.scroll = std.math.clamp(self.scroll - dy, 0, @max(0, self.content_h - rect.h));
            ui.wants_frame = true;
        }
    }

    /// Size of a dropdown at the right of a card.
    const dd_w: f32 = 250;
    const dd_h: f32 = 32;
    /// Every style, in the order the dropdowns list them: macOS's choice,
    /// tt's own two, the e-ink pair, then the terminal themes (dark ones,
    /// then light ones).
    const style_count = 5 + themes.all.len;

    fn styleAt(i: usize) config.Mode {
        return switch (i) {
            0 => .system,
            1 => .dark,
            2 => .light,
            3 => .eink,
            4 => .eink_color,
            else => .{ .theme = @intCast(i - 5) },
        };
    }

    fn styleIndex(m: config.Mode) usize {
        for (0..style_count) |i| {
            if (styleAt(i).eql(m)) return i;
        }
        return 0;
    }

    /// A style in miniature: its background with its red, green, yellow
    /// and blue; macOS's choice is tt's dark and light side by side.
    fn styleSwatch(m: config.Mode) field.Swatch {
        const scheme: theme.Scheme = switch (m) {
            .system => return .{ .split = .{ .left = theme.dark_palette.bg, .right = theme.light_palette.bg } },
            .dark => .dark,
            .light => .light,
            .eink => .eink,
            .eink_color => .eink_color,
            .theme => |i| {
                const t = &themes.all[i];
                return .{ .theme = .{ .bg = theme.rgb(t.background), .dots = .{ theme.rgb(t.ansi[1]), theme.rgb(t.ansi[2]), theme.rgb(t.ansi[3]), theme.rgb(t.ansi[4]) } } };
            },
        };
        const p = theme.palette(scheme);
        return .{ .theme = .{ .bg = p.bg, .dots = .{ p.ansi[1], p.ansi[2], p.ansi[3], p.ansi[4] } } };
    }

    /// The styles as dropdown rows; `as_above` puts "As above" first (a
    /// display that follows the general style). A line sets off the dark
    /// themes and the light ones.
    fn styleChoices(buf: *[style_count + 1]field.Choice, as_above: bool) []field.Choice {
        var n: usize = 0;
        if (as_above) {
            buf[0] = .{ .label = "As above" };
            n = 1;
        }
        const first_light = 5 + themes.ofKind(.dark).len;
        for (0..style_count) |i| {
            const m = styleAt(i);
            buf[n] = .{ .label = m.label(), .swatch = styleSwatch(m), .sep_before = (as_above and i == 0) or i == 5 or i == first_light };
            n += 1;
        }
        return buf[0..n];
    }

    /// The style — tt's own, e-ink, or a classic terminal theme — then a
    /// style per display, then the accent.
    fn drawStyle(self: *SettingsTab, ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Appearance", theme.text);
        _ = dl.textEllipsis(theme.font_hint, card.x + 18, card.y + 52, "tt's own colours, e-ink, or a classic terminal theme.", card.w - 36 - dd_w - 16, theme.text_3);

        var buf: [style_count + 1]field.Choice = undefined;
        const r: Rect = .{ .x = card.right() - 18 - dd_w, .y = card.centerY() - dd_h / 2, .w = dd_w, .h = dd_h };
        if (field.dropdown(ui, &self.dd, Ui.id("settings.style", 0), r, styleChoices(&buf, false), styleIndex(cfg.mode))) |i| {
            cfg.setMode(styleAt(i));
            _ = appearance.sync();
            cfg.save();
        }

        var note_buf: [200]u8 = undefined;
        const here = appearance.currentScreen();
        const own: ?config.Mode = if (here) |h| cfg.screenMode(h) else null;
        const note: []const u8 = if (own) |m|
            std.fmt.bufPrint(&note_buf, "Not in use right now: this window is on {s}, which is set to {s} below.", .{ here.?, m.label() }) catch ""
        else switch (cfg.mode) {
            .system => std.fmt.bufPrint(&note_buf, "Following macOS, which is {s} right now: tt {s}.", .{ if (theme.scheme == .dark) "dark" else "light", if (theme.scheme == .dark) "Dark" else "Light" }) catch "",
            .dark => "tt's own dark colours, whatever macOS is set to.",
            .light => "tt's own light colours, whatever macOS is set to.",
            .eink => "Ink on paper, for e-ink panels: black and white, no blinking, no hover, no shadows.",
            .eink_color => "Muted colour on paper, for colour e-ink panels: no blinking, no hover, no shadows.",
            .theme => |i| std.fmt.bufPrint(&note_buf, "{s}, with its exact colours from terminalcolors.com.", .{themes.all[i].name}) catch "",
        };
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.bottom() + 20, note, theme.text_3);
        const screens_end = self.drawScreens(ui, x, card.bottom() + 44, col_w);
        return self.drawAccent(ui, x, screens_end + 24, col_w);
    }

    /// One row per display: the style the window takes while it is on that
    /// display, or "As above" for the general one. Displays that were set
    /// up but are not connected right now can be forgotten.
    fn drawScreens(self: *SettingsTab, ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const connected = appearance.screenNames();
        const here = appearance.currentScreen();

        // Remembered displays that are not connected, after the connected ones.
        var absent_buf: [32][]const u8 = undefined;
        var absent: usize = 0;
        for (cfg.screens.items) |sc| {
            var listed = false;
            for (connected) |name| {
                if (std.mem.eql(u8, name, sc.name)) listed = true;
            }
            if (!listed and absent < absent_buf.len) {
                absent_buf[absent] = sc.name;
                absent += 1;
            }
        }
        const rows = connected.len + absent;
        const row_h: f32 = 44;
        const head_h: f32 = 72;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = head_h + @as(f32, @floatFromInt(@max(rows, 1))) * row_h + 10 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Per screen", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.y + 52, "A display can have a style of its own: the window switches when it moves there. Only tt changes, never macOS.", theme.text_3);

        var ry = card.y + head_h;
        if (rows == 0) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, ry + row_h / 2, "No display is known yet.", theme.text_3);
            ry += row_h;
        }
        var buf: [style_count + 1]field.Choice = undefined;
        const choices = styleChoices(&buf, true);
        for (connected, 0..) |name, i| {
            const cy = ry + row_h / 2;
            const on_it = here != null and std.mem.eql(u8, here.?, name);
            const r: Rect = .{ .x = card.right() - 18 - dd_w, .y = cy - dd_h / 2, .w = dd_w, .h = dd_h };
            // The name, tagged when the window is on it.
            const name_w = dl.textEllipsis(theme.font_ui, card.x + 18, cy, name, r.x - 16 - card.x - 18, theme.text);
            if (on_it) {
                const tag = "window is here";
                const tw = ui.text.measure(theme.font_chip, tag);
                const pill: Rect = .{ .x = card.x + 18 + name_w + 10, .y = cy - 9, .w = tw + 14, .h = 18 };
                if (pill.right() < r.x - 12) {
                    dl.rrect(pill, 9, theme.accent.alpha(0.16));
                    _ = dl.textCentered(theme.font_chip, pill.x + 7, cy, tag, theme.text);
                }
            }
            const sel: usize = if (cfg.screenMode(name)) |m| styleIndex(m) + 1 else 0;
            if (field.dropdown(ui, &self.dd, Ui.id("settings.screen", i), r, choices, sel)) |k| {
                cfg.setScreenMode(name, if (k == 0) null else styleAt(k - 1));
                _ = appearance.sync();
                cfg.save();
            }
            ry += row_h;
        }
        for (absent_buf[0..absent], 0..) |name, i| {
            const cy = ry + row_h / 2;
            _ = dl.textCentered(theme.font_ui, card.x + 18, cy, name, theme.text_2);
            var what_buf: [96]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "Not connected · {s}", .{(cfg.screenMode(name) orelse cfg.mode).label()}) catch "Not connected";
            const fw = ui.text.measure(theme.font_hint, "Forget") + 20;
            const forget: Rect = .{ .x = card.right() - 18 - fw, .y = cy - 12, .w = fw, .h = 24 };
            const ww = ui.text.measure(theme.font_hint, what);
            _ = dl.textCentered(theme.font_hint, forget.x - 12 - ww, cy, what, theme.text_3);
            if (field.textButton(ui, Ui.id("settings.screen.forget", i), forget, "Forget", theme.text_2)) {
                cfg.setScreenMode(name, null);
                cfg.save();
            }
            ry += row_h;
        }
        return card.bottom();
    }

    /// The accent options of the style in force.
    fn drawAccent(self: *SettingsTab, ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Accent colour", theme.text);
        _ = dl.textEllipsis(theme.font_hint, card.x + 18, card.y + 52, "Used for the prompt, focus ring and highlights.", card.w - 36 - dd_w - 16, theme.text_3);

        // On e-ink everything is ink black; the choice waits for another style.
        if (theme.scheme == .eink) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, card.bottom() + 20, "E-ink draws everything in ink black; the accent chosen here is used by the other styles.", theme.text_3);
            return card.bottom() + 30;
        }
        var abuf: [theme.accent_options.len + 1]field.Choice = undefined;
        var n: usize = 0;
        for (theme.accent_options, theme.accent_labels) |c, label| {
            abuf[n] = .{ .label = label, .swatch = .{ .dot = c } };
            n += 1;
        }
        // A colour from config.yml shows as a row of its own.
        if (theme.accent_choice == null) {
            abuf[n] = .{ .label = "Custom, from config.yml", .swatch = .{ .dot = theme.accent }, .sep_before = true };
            n += 1;
        }
        const r: Rect = .{ .x = card.right() - 18 - dd_w, .y = card.centerY() - dd_h / 2, .w = dd_w, .h = dd_h };
        if (field.dropdown(ui, &self.dd, Ui.id("settings.accent", 0), r, abuf[0..n], theme.accent_choice orelse n - 1)) |i| {
            if (i < theme.accent_options.len) {
                theme.setAccent(i);
                cfg.setAccent(.{ .named = @intCast(i) });
                cfg.save();
            }
        }
        var end = card.bottom();
        if (theme.accent_choice == null) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, end + 20, "A custom colour from config.yml is in use; pick one above to go back to the style's.", theme.text_3);
            end += 30;
        }
        return end;
    }

    /// A page that is not there yet.
    fn drawSoon(ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Coming up soon", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.y + 52, "Nothing to set here yet.", theme.text_3);
        _ = drawSoonPill(ui, card.right() - 18, card.y + 28);
        return card.bottom();
    }
};

/// The small "Soon" tag pages without content carry, right-aligned at `right`.
pub fn drawSoonPill(ui: *Ui, right: f32, cy: f32) f32 {
    const tag = "Soon";
    const tw = ui.text.measure(theme.font_chip, tag);
    const pill: Rect = .{ .x = right - tw - 14, .y = cy - 9, .w = tw + 14, .h = 18 };
    ui.dl.rrect(pill, 9, theme.chip_active);
    _ = ui.dl.textCentered(theme.font_chip, pill.x + 7, pill.centerY(), tag, theme.text_3);
    return pill.x;
}

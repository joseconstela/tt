//! The Settings tab. Its pages are grouped in sections; while the tab is in
//! front the sidebar shows them as the navigation menu (see `sidebar.zig`)
//! and this file draws the selected page. What the pages change lives in
//! `config.zig` and is written to `~/.tt/config.yml`.
const std = @import("std");
const tab_mod = @import("tab.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const icons = @import("../gfx/icons.zig");
const config = @import("../config.zig");
const appearance = @import("../appearance.zig");
const apis_mod = @import("settings_apis.zig");
const coding_mod = @import("settings_coding_agents.zig");
const features_mod = @import("settings_features.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Font = ui_mod.Font;

/// A page of the settings, in menu order.
pub const Page = enum {
    mode,
    theme,
    /// The model APIs (a model at a provider, with its key).
    apis,
    /// The coding agents installed on this Mac.
    agents,
    mcps,
    features,

    pub fn label(self: Page) []const u8 {
        return switch (self) {
            .mode => "Mode",
            .theme => "Theme",
            .apis => "APIs",
            .agents => "Agents",
            .mcps => "MCPs",
            .features => "Features",
        };
    }

    pub fn icon(self: Page) icons.Icon {
        return switch (self) {
            .mode => .sun,
            .theme => .drop,
            .apis => .cloud,
            .agents => .agent,
            .mcps => .plug,
            .features => .sparkle,
        };
    }

    /// One line under the page title.
    pub fn blurb(self: Page) []const u8 {
        return switch (self) {
            .mode => "Light, dark, e-ink, or follow the system.",
            .theme => "Colours for the workspace.",
            .apis => "The models tt can talk to: hosted providers, or Ollama on this Mac.",
            .agents => "The coding agents installed on this Mac, for fixing what fails.",
            .mcps => "Model Context Protocol servers your agents can use.",
            .features => "What your APIs and agents are used for.",
        };
    }

    /// False while the page only says "coming up soon".
    pub fn ready(self: Page) bool {
        return switch (self) {
            .mode, .theme, .apis, .agents, .features => true,
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
    .{ .title = "UI", .pages = &.{ .mode, .theme } },
    .{ .title = "AI", .pages = &.{ .apis, .agents, .mcps, .features } },
};

pub const SettingsTab = struct {
    pub const kind_label = "Settings";
    /// Name the kind is registered under (`app.zig`); how `fromTab` tells
    /// this tab from the others.
    pub const kind_name = "settings";

    gpa: std.mem.Allocator,
    page: Page = .mode,
    apis: apis_mod.Page,
    agents: coding_mod.Page,
    features: features_mod.Page,
    /// The page drawn last frame: a switch resets the scroll and the focus.
    shown: Page = .mode,
    scroll: f32 = 0,
    /// Height of the page content and of the view, from the last frame.
    content_h: f32 = 0,
    view_h: f32 = 0,

    pub fn create(env: *tab_mod.Env, _: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(SettingsTab);
        self.* = .{ .gpa = env.gpa, .apis = apis_mod.Page.init(env.gpa), .agents = coding_mod.Page.init(env.gpa), .features = features_mod.Page.init(env.gpa) };
        return tab_mod.Tab.from(SettingsTab, self);
    }

    pub fn deinit(self: *SettingsTab) void {
        self.apis.deinit();
        self.agents.deinit();
        self.features.deinit();
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
            else => false,
        };
    }

    // ── keyboard: to the page with a focused field, else page scrolling ──
    pub fn onText(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.onText(utf8),
            .features => self.features.onText(utf8),
            else => {},
        }
    }

    pub fn onMarkedText(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.onMarkedText(utf8),
            .features => self.features.onMarkedText(utf8),
            else => {},
        }
    }

    pub fn onEdit(self: *SettingsTab, cmd: EditCommand) void {
        const used = switch (self.page) {
            .apis => self.apis.onEdit(cmd),
            .features => self.features.onEdit(cmd),
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
            else => {},
        }
    }

    pub fn paste(self: *SettingsTab, utf8: []const u8) void {
        switch (self.page) {
            .apis => self.apis.paste(utf8),
            .features => self.features.paste(utf8),
            else => {},
        }
    }

    pub fn copy(self: *SettingsTab, out: *std.ArrayList(u8), cut: bool) bool {
        return switch (self.page) {
            .apis => self.apis.copy(out, cut),
            .features => self.features.copy(out, cut),
            else => false,
        };
    }

    pub fn hasMarkedText(self: *SettingsTab) bool {
        return switch (self.page) {
            .apis => self.apis.hasMarkedText(),
            .features => self.features.hasMarkedText(),
            else => false,
        };
    }

    pub fn caretRect(self: *SettingsTab) Rect {
        return switch (self.page) {
            .apis => self.apis.caretRect(),
            .features => self.features.caretRect(),
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
            self.shown = self.page;
            self.scroll = 0;
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
            .mode => drawMode(ui, x, y, col_w),
            .theme => drawTheme(ui, x, y, col_w),
            .apis => self.apis.draw(ui, x, y, col_w, ui.now),
            .agents => self.agents.draw(ui, x, y, col_w),
            .features => self.features.draw(ui, x, y, col_w, focused),
            else => drawSoon(ui, x, y, col_w),
        };

        // Where all of this is kept.
        y += 22;
        _ = dl.textCentered(theme.font_hint, x, y, "Saved in ~/.tt/config.yml, which can be edited by hand.", theme.text_3);
        y += 24;
        self.content_h = y - top;

        // The wheel scrolls the page with whatever a widget inside (the
        // prompt box) has not taken; the pages drew with the old offset,
        // so ask for a frame.
        const dy = ui.takeScroll(rect);
        if (dy != 0) {
            self.scroll = std.math.clamp(self.scroll - dy, 0, @max(0, self.content_h - rect.h));
            ui.wants_frame = true;
        }
    }

    /// The modes a chip row offers, in order.
    const mode_choices = [_]config.Mode{ .dark, .light, .system, .eink };

    /// Dark, light, or macOS's choice — and, under it, a mode per display.
    fn drawMode(ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Appearance", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.y + 52, "Dark, light, e-ink, or whatever macOS is using.", theme.text_3);

        var w: f32 = 0;
        for (mode_choices) |m| w += field.chipWidth(ui, m.label()) + 6;
        var cx = card.right() - 18 - w + 6;
        for (mode_choices, 0..) |m, i| {
            const cw = field.chipWidth(ui, m.label());
            if (field.chip(ui, Ui.id("settings.mode", i), .{ .x = cx, .y = card.centerY() - 13, .w = cw, .h = 26 }, m.label(), cfg.mode == m)) {
                cfg.setMode(m);
                _ = appearance.sync();
                cfg.save();
            }
            cx += cw + 6;
        }

        var note_buf: [160]u8 = undefined;
        const here = appearance.currentScreen();
        const own: ?config.Mode = if (here) |h| cfg.screenMode(h) else null;
        const note: []const u8 = if (own) |m|
            std.fmt.bufPrint(&note_buf, "Not in use right now: this window is on {s}, which is set to {s} below.", .{ here.?, m.label() }) catch ""
        else switch (cfg.mode) {
            .system => std.fmt.bufPrint(&note_buf, "Following macOS, which is {s} right now.", .{if (theme.scheme == .dark) "dark" else "light"}) catch "",
            .dark => "Always dark, whatever macOS is set to.",
            .light => "Always light, whatever macOS is set to.",
            .eink => "Ink on paper, for e-ink panels: black and white, no blinking, no hover, no shadows.",
        };
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.bottom() + 20, note, theme.text_3);
        return drawScreens(ui, x, card.bottom() + 44, col_w);
    }

    /// One row per display: the mode the window takes while it is on that
    /// display, or "As above" for the general one. Displays that were set
    /// up but are not connected right now can be forgotten.
    fn drawScreens(ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
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
        const row_h: f32 = 38;
        const head_h: f32 = 72;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = head_h + @as(f32, @floatFromInt(@max(rows, 1))) * row_h + 12 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Per screen", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.y + 52, "A display can have a mode of its own: the window switches when it moves there. Only tt changes, never macOS.", theme.text_3);

        var ry = card.y + head_h;
        if (rows == 0) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, ry + row_h / 2, "No display is known yet.", theme.text_3);
            ry += row_h;
        }
        for (connected, 0..) |name, i| {
            const cy = ry + row_h / 2;
            const on_it = here != null and std.mem.eql(u8, here.?, name);
            // The name, tagged when the window is on it.
            const name_w = ui.text.measure(theme.font_ui, name);
            _ = dl.textCentered(theme.font_ui, card.x + 18, cy, name, theme.text);
            if (on_it) {
                const tag = "window is here";
                const tw = ui.text.measure(theme.font_chip, tag);
                const pill: Rect = .{ .x = card.x + 18 + name_w + 10, .y = cy - 9, .w = tw + 14, .h = 18 };
                dl.rrect(pill, 9, theme.accent.alpha(0.16));
                _ = dl.textCentered(theme.font_chip, pill.x + 7, cy, tag, theme.text);
            }
            // As above | Dark | Light | System | E-ink, right-aligned.
            const own = cfg.screenMode(name);
            var w: f32 = field.chipWidth(ui, "As above") + 6;
            for (mode_choices) |m| w += field.chipWidth(ui, m.label()) + 6;
            var cx = card.right() - 18 - w + 6;
            const aw = field.chipWidth(ui, "As above");
            if (field.chip(ui, Ui.id("settings.screen", i * 8), .{ .x = cx, .y = cy - 13, .w = aw, .h = 26 }, "As above", own == null)) {
                cfg.setScreenMode(name, null);
                _ = appearance.sync();
                cfg.save();
            }
            cx += aw + 6;
            for (mode_choices, 1..) |m, k| {
                const cw = field.chipWidth(ui, m.label());
                if (field.chip(ui, Ui.id("settings.screen", i * 8 + k), .{ .x = cx, .y = cy - 13, .w = cw, .h = 26 }, m.label(), own == m)) {
                    cfg.setScreenMode(name, m);
                    _ = appearance.sync();
                    cfg.save();
                }
                cx += cw + 6;
            }
            ry += row_h;
        }
        for (absent_buf[0..absent], 0..) |name, i| {
            const cy = ry + row_h / 2;
            _ = dl.textCentered(theme.font_ui, card.x + 18, cy, name, theme.text_2);
            var buf: [64]u8 = undefined;
            const what = std.fmt.bufPrint(&buf, "Not connected · {s}", .{(cfg.screenMode(name) orelse cfg.mode).label()}) catch "Not connected";
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

    /// The accent colour options declared by the design.
    fn drawTheme(ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = 92 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + 18, card.y + 28, "Accent colour", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + 18, card.y + 52, "Used for the prompt, focus ring and highlights.", theme.text_3);

        // On e-ink everything is ink black; the choice waits for Dark or Light.
        if (theme.scheme == .eink) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, card.bottom() + 20, "E-ink draws everything in ink black; the accent chosen here is used by Dark and Light.", theme.text_3);
            return card.bottom() + 30;
        }

        var sx = card.right() - 18 - @as(f32, @floatFromInt(theme.accent_options.len)) * 40 + 8;
        for (theme.accent_options, 0..) |c, i| {
            const r: Rect = .{ .x = sx, .y = card.centerY() - 16, .w = 32, .h = 32 };
            const st = ui.button(Ui.id("settings.accent", i), r);
            const selected = theme.accent_choice == i;
            if (selected or st.hover) dl.border(.{ .x = r.x - 3, .y = r.y - 3, .w = 38, .h = 38 }, 19, 1.5, if (selected) theme.text else theme.line_strong);
            dl.circle(r.x + 16, r.y + 16, 13, c);
            if (st.clicked) {
                theme.setAccent(i);
                cfg.setAccent(.{ .named = @intCast(i) });
                cfg.save();
            }
            sx += 40;
        }
        var end = card.bottom();
        if (theme.accent_choice == null) {
            _ = dl.textCentered(theme.font_hint, card.x + 18, end + 20, "A custom colour from config.yml is in use; pick one above to go back to the design's.", theme.text_3);
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

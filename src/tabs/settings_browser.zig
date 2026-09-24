//! Settings › Browser: how website tabs (tabs/web_tab.zig) behave. Three
//! cards — Cookies, Homepage, Privacy — each editing `config.browser` in
//! place. Homepage's "Custom address" holds a single text field, so this
//! page owns one keyboard focus like the APIs page does.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const config = @import("../config.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const font = theme.font_ui;
const row_h: f32 = 36;
const card_pad = theme.block_pad_x;
/// Height of a card's title and hint lines.
const card_head: f32 = 70;

/// The one text field on the page: the custom homepage address.
const homepage_field = Ui.id("settings.browser.homepage", 1);

pub const Page = struct {
    gpa: std.mem.Allocator,
    focus: field.Focus,
    /// "Custom address" is chosen: the URL field shows even while blank.
    /// Loaded from the config the first time the page is drawn.
    want_custom: bool = false,
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *Page) void {
        self.flush();
        self.focus.deinit();
    }

    /// Copies the focused field's text into the config.
    fn flush(self: *Page) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        const cfg = config.get();
        cfg.setString(&cfg.browser.homepage, self.focus.editor.bytes());
        self.focus.markSynced();
    }

    // ── per-tick / keyboard (routed by the settings tab) ────────────────
    pub fn tick(self: *Page, now: f64) bool {
        return self.focus.tick(now);
    }

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
    /// Draws the page in the column at `x`, from `y0` down; returns the y
    /// where it ends.
    pub fn draw(self: *Page, ui: *Ui, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        const cfg = config.get();
        if (!self.loaded) {
            self.loaded = true;
            self.want_custom = cfg.browser.homepage.len > 0;
        }
        var press_outside = ui.pressed;
        var y = y0;

        y = self.drawCookies(ui, cfg, x, y, col_w);
        y += theme.block_gap;
        y = self.drawHomepage(ui, cfg, x, y, col_w, now, &press_outside);
        y += theme.block_gap;
        y = self.drawPrivacy(ui, cfg, x, y, col_w);

        // A click anywhere but on the field gives the focus up.
        if (press_outside and self.focus.active()) self.blur();
        self.flush();
        return y;
    }

    /// Cookies: cleared on close (the default) or kept between launches.
    fn drawCookies(self: *Page, ui: *Ui, cfg: *config.Config, x: f32, y: f32, col_w: f32) f32 {
        _ = self;
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 2 * row_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, "Cookies", theme.text);
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, "Whether sites keep cookies and other data past this session.", card.w - 2 * card_pad, theme.text_3);

        var ry = card.y + card_head;
        if (radioRow(ui, Ui.id("settings.browser.cookies", 0), card, ry, "Remove after close", "Cookies and site data are dropped when tt quits.", !cfg.browser.keep_cookies)) {
            cfg.browser.keep_cookies = false;
            cfg.touch();
        }
        ry += row_h;
        if (radioRow(ui, Ui.id("settings.browser.cookies", 1), card, ry, "Keep them stored", "Cookies and site data stay between launches.", cfg.browser.keep_cookies)) {
            cfg.browser.keep_cookies = true;
            cfg.touch();
        }
        return card.bottom();
    }

    /// Homepage: a white page (the default) or a custom address, whose URL
    /// field appears below the choice.
    fn drawHomepage(self: *Page, ui: *Ui, cfg: *config.Config, x: f32, y: f32, col_w: f32, now: f64, press_outside: *bool) f32 {
        const dl = ui.dl;
        const field_h: f32 = if (self.want_custom) field.height + 12 else 0;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + 2 * row_h + field_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, "Homepage", theme.text);
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, "What a new website tab opens on.", card.w - 2 * card_pad, theme.text_3);

        var ry = card.y + card_head;
        if (radioRow(ui, Ui.id("settings.browser.home", 0), card, ry, "Start white", "New tabs open on a blank page, address bar ready.", !self.want_custom)) {
            self.want_custom = false;
            cfg.setString(&cfg.browser.homepage, "");
            cfg.touch();
            self.focus.drop();
        }
        ry += row_h;
        if (radioRow(ui, Ui.id("settings.browser.home", 1), card, ry, "Custom URL", "New tabs open the address below.", self.want_custom)) {
            if (!self.want_custom) {
                self.want_custom = true;
                self.focus.take(homepage_field, cfg.browser.homepage, now);
                press_outside.* = false;
            }
        }
        ry += row_h;

        if (self.want_custom) {
            ry += 6;
            const fr: Rect = .{ .x = card.x + card_pad, .y = ry, .w = card.w - 2 * card_pad, .h = field.height };
            const res = field.draw(ui, &self.focus, homepage_field, fr, cfg.browser.homepage, .{
                .placeholder = "https://example.com",
            });
            if (res.clicked) {
                self.focus.take(homepage_field, cfg.browser.homepage, now);
                press_outside.* = false;
            }
            // A press inside the field is not a press "outside".
            if (ui.pressed and ui.mouseIn(fr)) press_outside.* = false;
        }
        return card.bottom();
    }

    /// Privacy: the Do Not Track request header.
    fn drawPrivacy(self: *Page, ui: *Ui, cfg: *config.Config, x: f32, y: f32, col_w: f32) f32 {
        _ = self;
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + row_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, "Privacy", theme.text);
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, "What tt asks of the sites you visit.", card.w - 2 * card_pad, theme.text_3);

        const ry = card.y + card_head;
        if (switchRow(ui, Ui.id("settings.browser.dnt", 0), card, ry, "Request Do Not Track", "Sends the DNT header; sites may still ignore it.", cfg.browser.do_not_track)) {
            cfg.browser.do_not_track = !cfg.browser.do_not_track;
            cfg.touch();
        }
        return card.bottom();
    }
};

/// A pick-one row: a ring with a dot when selected, the label, and a dim
/// detail at the right. True when clicked.
fn radioRow(ui: *Ui, wid: u64, card: Rect, y: f32, label: []const u8, detail: []const u8, selected: bool) bool {
    const dl = ui.dl;
    const r: Rect = .{ .x = card.x + 8, .y = y, .w = card.w - 16, .h = row_h };
    const st = ui.button(wid, r);
    ui.feedback(r, 6, st);
    const cy = r.centerY();
    const ring: Rect = .{ .x = r.x + 10, .y = cy - 8, .w = 16, .h = 16 };
    dl.border(ring, 8, 1.5, if (selected) theme.accent else theme.line_strong);
    if (selected) dl.circle(ring.x + 8, cy, 4, theme.accent);
    const detail_w = if (detail.len > 0) dl.textRight(theme.font_hint, r.right() - 12, cy, detail, theme.text_3) else 0;
    _ = dl.textEllipsis(font, r.x + 38, cy, label, r.w - 38 - detail_w - 24, theme.text);
    return st.clicked;
}

/// An on/off row: the label and a dim detail, a switch at the right.
/// True when clicked.
fn switchRow(ui: *Ui, wid: u64, card: Rect, y: f32, label: []const u8, detail: []const u8, on: bool) bool {
    const dl = ui.dl;
    const r: Rect = .{ .x = card.x + 8, .y = y, .w = card.w - 16, .h = row_h };
    const st = ui.button(wid, r);
    ui.feedback(r, 6, st);
    const cy = r.centerY();
    const toggle: Rect = .{ .x = r.right() - 12 - 36, .y = cy - 10, .w = 36, .h = 20 };
    dl.rrect(toggle, 10, if (on) theme.accent else theme.line_strong);
    const knob_x = if (on) toggle.right() - 18 else toggle.x + 2;
    dl.rrect(.{ .x = knob_x, .y = toggle.y + 2, .w = 16, .h = 16 }, 8, if (on) theme.on_accent else theme.text_2);
    const lw = dl.textCentered(font, r.x + 38, cy, label, theme.text);
    _ = dl.textEllipsis(theme.font_hint, r.x + 38 + lw + 12, cy, detail, toggle.x - 12 - (r.x + 38 + lw + 12), theme.text_3);
    return st.clicked;
}

//! Website tabs. The page is a WKWebView — the system WebKit, the engine
//! behind Safari — that the platform layer hosts over the Metal layer, so
//! the app draws nothing of the page itself. The browser chrome is the
//! app's own: back, forward, reload and the address bar, drawn like the
//! rest of the UI in one row, under which the page fills the tab edge to
//! edge.
//!
//! WebKit is driven through the Objective-C runtime like AppKit is. Without
//! a window (headless scripts, tests) there is no web view: the chrome still
//! works and the body says so.
//!
//! The app runs JavaScript of its own in every page and hears back from it
//! (web_bridge.zig); the first use is the context menu, which offers what
//! the app can do with the text selected in the page (web_menu.zig).
const std = @import("std");
const records = @import("../records.zig");
const tab_mod = @import("tab.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const gfx_text = @import("../gfx/text.zig");
const icons = @import("../gfx/icons.zig");
const objc = @import("../objc.zig");
const web_bridge = @import("web_bridge.zig");
const web_menu = @import("web_menu.zig");
const Editor = @import("../input/editor.zig").Editor;
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Font = ui_mod.Font;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSInteger = objc.NSInteger;
const CGRect = objc.CGRect;

/// The chrome row above the page (points).
pub const bar_h: f32 = 44;
/// Where something typed that is not an address goes.
const search_url = "https://duckduckgo.com/?q=";
const placeholder = "Search or enter a website address";
/// WebKit's own user agent lacks the Safari token, and some sites serve
/// their fallback pages without it.
const ua_suffix = "Version/17.4 Safari/605.1.15";

pub const WebTab = struct {
    pub const kind_label = "Website";
    pub const kind_name = "web";

    gpa: std.mem.Allocator,
    /// The shared services; `env.host` may appear after the tab does (the
    /// workspace restores tabs before the window exists), so the web view
    /// is made on the first tick that finds a host.
    env: *tab_mod.Env,
    /// The WKWebView and the object WebKit reports to; null without a host.
    view: id = null,
    delegate: id = null,
    /// Live tabs, so a delegate callback finds its tab by web view.
    next_live: ?*WebTab = null,

    // What the web view says, polled every tick.
    url: std.ArrayList(u8) = .empty,
    page_title: std.ArrayList(u8) = .empty,
    loading: bool = false,
    progress: f32 = 0,
    can_back: bool = false,
    can_forward: bool = false,
    /// A load that failed: what WebKit said, and the address for "Try again".
    error_text: ?[]u8 = null,
    error_url: ?[]u8 = null,
    /// What the page says is selected, and the link under the pointer when
    /// its context menu last opened — from the `selection` bridge.
    selection: std.ArrayList(u8) = .empty,
    link_url: std.ArrayList(u8) = .empty,

    // The address bar.
    editor: Editor,
    bar_focused: bool = false,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    seen_version: u64 = 0,
    caret: Rect = .{},
    /// Horizontal scroll of the address text while editing, so the caret stays in view.
    scroll_x: f32 = 0,
    scheme_seen: theme.Scheme = .dark,

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const self = try env.gpa.create(WebTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .env = env, .editor = Editor.init(env.gpa) };
        self.link();
        if (env.host != null) self.createView();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(env.gpa);
        if (args.url) |u| {
            self.navigate(u, true);
        } else if (keptUrl(&scratch, env.gpa, args.saved)) |u| {
            // Kept from the last run: comes back quietly, without the keyboard.
            self.navigate(u, false);
        } else {
            self.focusBar(true);
        }
        return tab_mod.Tab.from(WebTab, self);
    }

    pub fn deinit(self: *WebTab) void {
        self.unlink();
        if (self.view) |v| {
            if (self.env.host) |h| h.detach(v);
            msg(void, v, "stopLoading", .{});
            msg(void, v, "setNavigationDelegate:", .{@as(id, null)});
            msg(void, v, "setUIDelegate:", .{@as(id, null)});
            objc.release(v);
        }
        objc.release(self.delegate);
        self.clearError();
        self.selection.deinit(self.gpa);
        self.link_url.deinit(self.gpa);
        self.url.deinit(self.gpa);
        self.page_title.deinit(self.gpa);
        self.editor.deinit();
        self.gpa.destroy(self);
    }

    /// The website tab behind a generic tab, when that is what it is.
    pub fn fromTab(t: tab_mod.Tab) ?*WebTab {
        if (!std.mem.eql(u8, t.kind, kind_name)) return null;
        return @ptrCast(@alignCast(t.ptr));
    }

    /// The tab whose web view this is (WebKit callbacks name the view).
    pub fn fromView(view: id) ?*WebTab {
        if (view == null) return null;
        var t = live_head;
        while (t) |tab| : (t = tab.next_live) {
            if (tab.view == view) return tab;
        }
        return null;
    }

    // ── the page's side ─────────────────────────────────────────────────
    /// The `selection` bridge reports what the page has selected and, when
    /// it knows (the context menu is opening), the link under the pointer.
    pub fn setSelection(self: *WebTab, text: []const u8, href: ?[]const u8) void {
        _ = self.setText(&self.selection, text);
        if (href) |h| _ = self.setText(&self.link_url, h);
    }

    /// Runs JavaScript in the page, in the bridges' world (web_bridge.zig);
    /// nothing without a web view.
    pub fn eval(self: *WebTab, js: []const u8) void {
        const v = self.view orelse return;
        web_bridge.eval(v, js);
    }

    // ── the web view ────────────────────────────────────────────────────
    fn createView(self: *WebTab) void {
        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);
        msg(void, config, "setApplicationNameForUserAgent:", .{objc.nsString(ua_suffix)});
        web_bridge.install(config);
        // "Inspect Element" in the page's context menu.
        const prefs = msg(id, config, "preferences", .{});
        const yes = msg(id, objc.class("NSNumber"), "numberWithBool:", .{true});
        msg(void, prefs, "setValue:forKey:", .{ yes, objc.nsString("developerExtrasEnabled") });

        const view = msg(id, msg(id, webViewClass(), "alloc", .{}), "initWithFrame:configuration:", .{ CGRect.make(0, 0, 200, 200), config });
        self.view = view;
        if (msg(bool, view, "respondsToSelector:", .{objc.sel("setInspectable:")})) msg(void, view, "setInspectable:", .{true});
        self.syncBackground();
        msg(void, view, "setAllowsBackForwardNavigationGestures:", .{true});
        msg(void, view, "setAllowsMagnification:", .{true});

        self.delegate = msg(id, msg(id, delegateClass(), "alloc", .{}), "init", .{});
        msg(void, view, "setNavigationDelegate:", .{self.delegate});
        msg(void, view, "setUIDelegate:", .{self.delegate});
        self.env.host.?.attach(view.?);
    }

    /// Around and beyond the page (overscroll) the app's background shows,
    /// not white; it follows the colour scheme.
    fn syncBackground(self: *WebTab) void {
        const v = self.view orelse return;
        self.scheme_seen = theme.scheme;
        if (!msg(bool, v, "respondsToSelector:", .{objc.sel("setUnderPageBackgroundColor:")})) return;
        const bg = msg(id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
            @as(f64, theme.bg.r), @as(f64, theme.bg.g), @as(f64, theme.bg.b), @as(f64, 1),
        });
        msg(void, v, "setUnderPageBackgroundColor:", .{bg});
    }

    /// Loads what the user typed: an address as is, a host with https://
    /// in front, anything else as a web search. With `focus` the page gets
    /// the keyboard.
    fn navigate(self: *WebTab, typed: []const u8, focus: bool) void {
        const url = resolve(self.gpa, typed) catch return;
        defer self.gpa.free(url);
        if (url.len == 0) return;
        self.clearError();
        _ = self.setText(&self.url, url);
        self.editor.setText(url);
        self.bar_focused = false;
        self.load(focus);
    }

    /// Loads the address on show in the web view, when there is one.
    fn load(self: *WebTab, focus: bool) void {
        const v = self.view orelse return;
        const nsurl = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(self.url.items)});
        if (nsurl == null) {
            self.setError("That is not a valid address.", self.url.items);
            return;
        }
        const req = msg(id, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        _ = msg(id, v, "loadRequest:", .{req});
        self.loading = true;
        self.progress = 0;
        if (focus) if (self.env.host) |h| h.focusView(v);
    }

    fn goBack(self: *WebTab) void {
        const v = self.view orelse return;
        if (self.error_text != null) self.clearError();
        _ = msg(id, v, "goBack", .{});
    }

    fn goForward(self: *WebTab) void {
        const v = self.view orelse return;
        if (self.error_text != null) self.clearError();
        _ = msg(id, v, "goForward", .{});
    }

    /// Reload — or, after a failure, try that address again; while a page
    /// is loading, stop instead (the button shows × then).
    fn reload(self: *WebTab) void {
        if (self.error_url) |u| {
            const again = self.gpa.dupe(u8, u) catch return;
            defer self.gpa.free(again);
            self.navigate(again, true);
            return;
        }
        const v = self.view orelse return;
        if (self.loading) {
            msg(void, v, "stopLoading", .{});
        } else {
            _ = msg(id, v, "reload", .{});
        }
    }

    fn setError(self: *WebTab, text: []const u8, url: []const u8) void {
        self.clearError();
        self.error_text = self.gpa.dupe(u8, text) catch null;
        self.error_url = self.gpa.dupe(u8, url) catch null;
        self.loading = false;
    }

    fn clearError(self: *WebTab) void {
        if (self.error_text) |t| self.gpa.free(t);
        if (self.error_url) |u| self.gpa.free(u);
        self.error_text = null;
        self.error_url = null;
    }

    fn setText(self: *WebTab, list: *std.ArrayList(u8), s: []const u8) bool {
        if (std.mem.eql(u8, list.items, s)) return false;
        list.clearRetainingCapacity();
        list.appendSlice(self.gpa, s) catch {};
        return true;
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *WebTab, buf: []u8) []const u8 {
        const src = if (self.page_title.items.len > 0) self.page_title.items else hostOf(self.url.items);
        if (src.len == 0) return "New Website";
        var n = @min(src.len, buf.len);
        // Never cut a UTF-8 sequence in half.
        while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }

    pub fn status(self: *WebTab) tab_mod.Status {
        return if (self.loading) .running else .none;
    }

    pub fn info(self: *WebTab, _: []u8) []const u8 {
        return self.url.items;
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// The address, so the page loads again; an empty tab is not kept.
    pub fn save(self: *WebTab, out: *std.ArrayList(u8)) bool {
        if (self.url.items.len == 0) return false;
        out.appendSlice(self.gpa, "url\t") catch return false;
        records.escape(out, self.gpa, self.url.items) catch return false;
        out.append(self.gpa, '\n') catch return false;
        return true;
    }

    pub fn saveVersion(self: *WebTab) u64 {
        return std.hash.Wyhash.hash(0, self.url.items);
    }

    /// Polls the web view; true when something the chrome shows changed.
    pub fn tick(self: *WebTab, now: f64, active: bool) bool {
        var changed = false;
        // The window (and with it the host) came after this tab — the
        // workspace restores tabs before there is one: make the web view
        // now and bring up the address it holds.
        if (self.view == null and self.env.host != null) {
            self.createView();
            if (self.url.items.len > 0 and self.error_text == null) self.load(false);
            changed = true;
        }
        if (self.view) |v| {
            if (theme.scheme != self.scheme_seen) self.syncBackground();
            const loading = msg(bool, v, "isLoading", .{});
            const progress: f32 = @floatCast(msg(f64, v, "estimatedProgress", .{}));
            const back = msg(bool, v, "canGoBack", .{});
            const forward = msg(bool, v, "canGoForward", .{});
            if (loading != self.loading or back != self.can_back or forward != self.can_forward) changed = true;
            if (loading and progress != self.progress) changed = true;
            self.loading = loading;
            self.progress = progress;
            self.can_back = back;
            self.can_forward = forward;

            const nsurl = msg(id, v, "URL", .{});
            const url = if (nsurl != null) objc.utf8(msg(id, nsurl, "absoluteString", .{})) else "";
            if (url.len > 0 and self.setText(&self.url, url)) {
                changed = true;
                if (!self.bar_focused) self.editor.setText(url);
                // Another page: what was selected on the last one is gone.
                self.selection.clearRetainingCapacity();
                self.link_url.clearRetainingCapacity();
            }
            if (self.setText(&self.page_title, objc.utf8(msg(id, v, "title", .{})))) changed = true;

            // The keyboard moved into the page: the address bar lets go.
            if (self.bar_focused and self.env.host.?.hasFocus(v)) {
                self.bar_focused = false;
                changed = true;
            }
        }
        if (self.editor.version != self.seen_version) {
            self.seen_version = self.editor.version;
            self.blink_t0 = now;
            self.blink_on = true;
            changed = true;
        }
        if (self.bar_focused and active) {
            const on = theme.caretOn(now, self.blink_t0);
            if (on != self.blink_on) {
                self.blink_on = on;
                changed = true;
            }
        }
        return changed;
    }

    pub fn onText(self: *WebTab, utf8: []const u8) void {
        if (!self.bar_focused) return;
        self.insertOneLine(utf8);
    }

    pub fn onMarkedText(self: *WebTab, utf8: []const u8) void {
        if (!self.bar_focused) return;
        self.editor.setMarked(utf8);
    }

    pub fn onEdit(self: *WebTab, cmd: EditCommand) void {
        if (!self.bar_focused) return;
        switch (cmd) {
            .insert_newline, .insert_line_break => {
                const typed = self.gpa.dupe(u8, self.editor.bytes()) catch return;
                defer self.gpa.free(typed);
                self.navigate(typed, true);
            },
            .cancel => {
                // Back to the address on show; the page keeps the keyboard.
                self.editor.setText(self.url.items);
                self.bar_focused = false;
                if (self.view) |v| if (self.env.host) |h| h.focusView(v);
            },
            .insert_tab, .insert_backtab, .page_up, .page_down, .scroll_to_top, .scroll_to_bottom => {},
            .move_up => _ = self.editor.apply(.move_line_start),
            .move_down => _ = self.editor.apply(.move_line_end),
            else => _ = self.editor.apply(cmd),
        }
    }

    pub fn copy(self: *WebTab, out: *std.ArrayList(u8), cut: bool) bool {
        if (!self.bar_focused) return false;
        const sel = self.editor.selectedText();
        if (sel.len == 0) return false;
        out.appendSlice(self.gpa, sel) catch return false;
        if (cut) _ = self.editor.deleteSelection();
        return true;
    }

    pub fn paste(self: *WebTab, utf8: []const u8) void {
        if (!self.bar_focused) return;
        self.insertOneLine(utf8);
    }

    pub fn hasMarkedText(self: *WebTab) bool {
        return self.bar_focused and self.editor.marked.items.len > 0;
    }

    pub fn caretRect(self: *WebTab) Rect {
        return self.caret;
    }

    pub fn command(self: *WebTab, cmd: tab_mod.Command) bool {
        switch (cmd) {
            .back => self.goBack(),
            .forward => self.goForward(),
            .reload => self.reload(),
            .open_location => self.focusBar(true),
            else => return false,
        }
        return true;
    }

    /// Address bars are one line: pasted newlines become spaces.
    fn insertOneLine(self: *WebTab, utf8: []const u8) void {
        var buf: [1024]u8 = undefined;
        var rest = utf8;
        while (rest.len > 0) {
            const n = @min(rest.len, buf.len);
            const chunk = rest[0..n];
            rest = rest[n..];
            @memcpy(buf[0..n], chunk);
            for (buf[0..n]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            self.editor.insert(buf[0..n]);
        }
    }

    fn focusBar(self: *WebTab, select_all: bool) void {
        self.bar_focused = true;
        self.blink_on = true;
        if (self.env.host) |h| h.focusApp();
        if (select_all) {
            _ = self.editor.apply(.select_all);
        } else {
            self.editor.anchor = null;
        }
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *WebTab, ui: *Ui, rect: Rect, focused: bool) void {
        const bar: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @min(bar_h, rect.h) };
        const body: Rect = .{ .x = rect.x, .y = rect.y + bar.h, .w = rect.w, .h = @max(0, rect.h - bar.h) };
        self.drawBar(ui, bar, focused);

        if (self.error_text) |text| {
            self.drawError(ui, body, text);
        } else if (self.view) |v| {
            if (body.w >= 1 and body.h >= 1) {
                if (self.env.host) |h| h.place(v, body);
            }
        } else {
            drawNoWindow(ui, body, self.url.items);
        }
    }

    fn drawBar(self: *WebTab, ui: *Ui, bar: Rect, focused: bool) void {
        const dl = ui.dl;
        dl.rect(.{ .x = bar.x, .y = bar.bottom() - 1, .w = bar.w, .h = 1 }, theme.line);
        const cy = bar.centerY();
        const key = @intFromPtr(self);

        // Navigation buttons.
        var x = bar.x + 10;
        if (self.navButton(ui, .{ .x = x, .y = cy - 14, .w = 28, .h = 28 }, .arrow_left, self.can_back, Ui.id("web.back", key))) self.goBack();
        x += 30;
        if (self.navButton(ui, .{ .x = x, .y = cy - 14, .w = 28, .h = 28 }, .arrow_right, self.can_forward, Ui.id("web.forward", key))) self.goForward();
        x += 30;
        if (self.navButton(ui, .{ .x = x, .y = cy - 14, .w = 28, .h = 28 }, if (self.loading) .close else .reload, self.view != null or self.error_url != null, Ui.id("web.reload", key))) self.reload();
        x += 30 + 6;

        // The address field.
        const field: Rect = .{ .x = x, .y = cy - 15, .w = @max(40, bar.right() - 10 - x), .h = 30 };
        const border = if (self.bar_focused and focused) theme.accent.alpha(0.8) else theme.line_strong;
        dl.shape(field, 8, theme.bg_inset, 1, border);
        if (self.loading) {
            dl.rrect(.{ .x = field.x + 1, .y = field.bottom() - 3, .w = @max(0, (field.w - 2) * self.progress), .h = 2 }, 1, theme.accent.alpha(0.85));
        }
        var tx = field.x + 11;
        const shown = self.editor.bytes();
        if (!self.bar_focused and std.mem.startsWith(u8, self.url.items, "https://")) {
            dl.icon(.lock, tx - 1, cy - 6.5, 13, theme.text_3);
            tx += 18;
        }
        const text_rect: Rect = .{ .x = tx, .y = field.y + 1, .w = @max(0, field.right() - 10 - tx), .h = field.h - 2 };
        const d = ui.drag(Ui.id("web.field", key), field);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (d.started and !self.bar_focused) self.focusBar(false);

        dl.pushClip(text_rect);
        defer dl.popClip();
        const font = theme.font_ui;
        if (!self.bar_focused) {
            const at_rest = if (shown.len > 0) shown else self.url.items;
            if (at_rest.len == 0) {
                _ = dl.textEllipsis(font, tx, cy, placeholder, text_rect.w, theme.text_3);
            } else {
                _ = dl.textEllipsis(font, tx, cy, at_rest, text_rect.w, theme.text);
            }
            self.scroll_x = 0;
            return;
        }
        if (shown.len == 0 and self.editor.marked.items.len == 0) {
            _ = dl.textEllipsis(font, tx, cy, placeholder, text_rect.w, theme.text_3);
        }

        // Measure first so the caret can be kept in view while editing.
        const e = &self.editor;
        var total: f32 = 0;
        var caret_off: f32 = total;
        {
            var it = gfx_text.Utf8Iter{ .bytes = shown };
            while (true) {
                if (it.index == e.cursor) caret_off = total;
                const cp = it.next() orelse break;
                total += ui.text.advance(font, cp);
            }
        }
        const avail = @max(0, text_rect.w - 2);
        if (caret_off - self.scroll_x > avail) self.scroll_x = caret_off - avail;
        if (caret_off - self.scroll_x < 0) self.scroll_x = caret_off;
        if (total - self.scroll_x < avail) self.scroll_x = @max(0, total - avail);

        // Text with selection, then the caret — glyph by glyph so a click
        // lands between the right characters.
        const scale = dl.scale;
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const sel = e.selection();
        var pen = (tx - self.scroll_x) * scale;
        var caret_px = pen;
        var it = gfx_text.Utf8Iter{ .bytes = shown };
        var hit_offset: ?usize = null;
        const baseline_px = @round(ui.text.baselineForCenter(font, cy) * scale);
        while (true) {
            const at = it.index;
            if (at == e.cursor) caret_px = pen;
            const cp = it.next() orelse break;
            const adv = ui.text.advance(font, cp) * scale;
            if ((d.started or d.dragging) and hit_offset == null and ui.mx * scale < pen + adv / 2) hit_offset = at;
            if (sel) |s| if (at >= s[0] and at < s[1]) {
                dl.rect(.{ .x = pen / scale, .y = cy - 9, .w = adv / scale, .h = 18 }, theme.selection());
            };
            _ = dl.glyph(font, cp, pen, baseline_px, theme.text, clip);
            pen += adv;
        }
        if (d.started or d.dragging) {
            const off = hit_offset orelse shown.len;
            if (d.started and d.double_clicked) {
                e.selectWordAt(off);
            } else if (d.started) {
                e.setCursor(off, ui.mods.shift);
            } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                e.setCursor(off, true);
            }
        }
        var cx = caret_px / scale;
        if (e.marked.items.len > 0) {
            const w = dl.textCentered(font, cx, cy, e.marked.items, theme.text);
            dl.rect(.{ .x = cx, .y = cy + 8, .w = w, .h = 1 }, theme.text_2);
            cx += w;
        }
        self.caret = .{ .x = cx, .y = cy - 9, .w = 2, .h = 18 };
        if (focused and (self.blink_on or ui.down)) dl.rect(self.caret, theme.accent);
    }

    /// A round icon button; true when clicked. Disabled ones are dimmed and inert.
    fn navButton(self: *WebTab, ui: *Ui, r: Rect, icon: icons.Icon, enabled: bool, wid: u64) bool {
        _ = self;
        const dl = ui.dl;
        if (!enabled) {
            dl.icon(icon, r.x + 6, r.y + 6, 16, theme.text_3.alpha(0.45));
            return false;
        }
        const st = ui.button(wid, r);
        ui.feedback(r, 7, st);
        dl.icon(icon, r.x + 6, r.y + 6, 16, if (st.hover) theme.text else theme.text_2);
        return st.clicked;
    }

    fn drawError(self: *WebTab, ui: *Ui, body: Rect, text: []const u8) void {
        const dl = ui.dl;
        dl.pushClip(body);
        defer dl.popClip();
        const col_w = @max(200, @min(520, body.w - 2 * theme.content_pad));
        const x = body.x + (body.w - col_w) / 2;
        var y = body.y + @max(48, body.h * 0.28);
        _ = dl.textCentered(Font.semibold(18), x, y, "The page could not be opened", theme.text);
        y += 32;
        _ = dl.textEllipsis(theme.font_ui, x, y, text, col_w, theme.text_2);
        y += 24;
        if (self.error_url) |u| {
            _ = dl.textEllipsis(theme.font_row_mono, x, y, u, col_w, theme.text_3);
            y += 34;
        } else y += 10;
        const label = "Try Again";
        const lw = ui.text.measure(theme.font_ui_medium, label);
        const r: Rect = .{ .x = x, .y = y, .w = lw + 28, .h = 30 };
        const st = ui.button(Ui.id("web.retry", @intFromPtr(self)), r);
        dl.shape(r, 8, if (st.held) theme.pressed else if (st.hover) theme.hover else theme.bg_block, 1, theme.line_strong);
        _ = dl.textCentered(theme.font_ui_medium, r.x + 14, r.centerY(), label, theme.text);
        if (st.clicked) self.reload();
    }

    /// Headless runs have no window to hang a web view in.
    fn drawNoWindow(ui: *Ui, body: Rect, url: []const u8) void {
        const dl = ui.dl;
        dl.pushClip(body);
        defer dl.popClip();
        const col_w = @max(200, @min(520, body.w - 2 * theme.content_pad));
        const x = body.x + (body.w - col_w) / 2;
        var y = body.y + @max(48, body.h * 0.28);
        _ = dl.textCentered(Font.semibold(18), x, y, "No window for the page", theme.text);
        y += 32;
        _ = dl.textEllipsis(theme.font_ui, x, y, "The web view needs a real window; this is a headless run.", col_w, theme.text_2);
        y += 24;
        if (url.len > 0) _ = dl.textEllipsis(theme.font_row_mono, x, y, url, col_w, theme.text_3);
    }

    // ── live tabs, for the delegate callbacks ───────────────────────────
    fn link(self: *WebTab) void {
        self.next_live = live_head;
        live_head = self;
    }

    fn unlink(self: *WebTab) void {
        var p = &live_head;
        while (p.*) |t| {
            if (t == self) {
                p.* = t.next_live;
                return;
            }
            p = &t.next_live;
        }
    }
};

var live_head: ?*WebTab = null;

const fromView = WebTab.fromView;

// ── the view class ──────────────────────────────────────────────────────
// A WKWebView that is first responder claims every ⌘ chord for the page and
// only hands the unhandled ones on later, if at all — so ⌘K, ⌘T, ⌘W … would
// die in the page. This subclass gives the app's menu first call; the edit
// shortcuts still reach the page, since their actions (copy:, paste:,
// selectAll: …) resolve to the first responder, and chords the menu does
// not know (⌘F …) go to the page as before.
var web_view_class: objc.Class = null;

fn webViewClass() objc.Class {
    if (web_view_class == null) {
        const b = objc.ClassBuilder.begin("TTWebView", "WKWebView");
        b.method("performKeyEquivalent:", performKeyEquivalent, "B@:@");
        b.method("willOpenMenu:withEvent:", willOpenMenu, "v@:@@");
        b.method("ttMenuAction:", menuAction, "v@:@");
        web_view_class = b.register();
    }
    return web_view_class;
}

/// The page's context menu is about to open, WebKit's items already in
/// it: the app's entries go in front (web_menu.zig).
fn willOpenMenu(self: id, _: SEL, menu: id, event: id) callconv(.c) void {
    objc.msgSuper(void, self, objc.class("WKWebView"), "willOpenMenu:withEvent:", .{ menu, event });
    const tab = fromView(self) orelse return;
    web_menu.fill(tab, self, menu);
}

/// One of those entries was picked; its tag says which.
fn menuAction(self: id, _: SEL, sender: id) callconv(.c) void {
    const tab = fromView(self) orelse return;
    web_menu.perform(tab, msg(NSInteger, sender, "tag", .{}));
}

fn performKeyEquivalent(self: id, _: SEL, event: id) callconv(.c) bool {
    // A menu action may close this very tab (⌘W): keep the view alive
    // until the current event is over.
    _ = objc.autorelease(objc.retain(self));
    const nsapp = msg(id, objc.class("NSApplication"), "sharedApplication", .{});
    const menu = msg(id, nsapp, "mainMenu", .{});
    const by_menu = menu != null and msg(bool, menu, "performKeyEquivalent:", .{event});
    if (@import("../sys.zig").getenv("TT_DEBUG_EVENTS") != null) {
        std.debug.print("web performKeyEquivalent '{s}' menu_took_it={}\n", .{ objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{})), by_menu });
    }
    if (by_menu) return true;
    return objc.msgSuper(bool, self, objc.class("WKWebView"), "performKeyEquivalent:", .{event});
}

// ── WebKit delegate ─────────────────────────────────────────────────────
// One class, registered on first use; every tab gets its own instance.
// Callbacks that end in a completion block are left to WebKit's defaults
// (blocks are awkward from Zig and the defaults — allow the navigation,
// dismiss the dialog — are what a browser tab wants anyway).
var delegate_class: objc.Class = null;

fn delegateClass() objc.Class {
    if (delegate_class == null) {
        const b = objc.ClassBuilder.begin("TTWebDelegate", "NSObject");
        b.protocol("WKNavigationDelegate");
        b.protocol("WKUIDelegate");
        b.method("webView:didFailProvisionalNavigation:withError:", didFail, "v@:@@@");
        b.method("webView:didFailNavigation:withError:", didFail, "v@:@@@");
        b.method("webViewWebContentProcessDidTerminate:", processDied, "v@:@");
        b.method("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", createWebView, "@@:@@@@");
        delegate_class = b.register();
    }
    return delegate_class;
}

fn didFail(_: id, _: SEL, web_view: id, _: id, err: id) callconv(.c) void {
    const self = fromView(web_view) orelse return;
    const code = msg(NSInteger, err, "code", .{});
    const domain = objc.utf8(msg(id, err, "domain", .{}));
    // A load the user or a redirect replaced is not a failure.
    if (std.mem.eql(u8, domain, "NSURLErrorDomain") and code == -999) return;
    if (std.mem.eql(u8, domain, "WebKitErrorDomain") and code == 102) return;
    const desc = objc.utf8(msg(id, err, "localizedDescription", .{}));
    const info = msg(id, err, "userInfo", .{});
    const failing = if (info != null) msg(id, info, "objectForKey:", .{objc.nsString("NSErrorFailingURLStringKey")}) else null;
    const url = if (failing != null) objc.utf8(failing) else self.url.items;
    self.setError(desc, url);
}

fn processDied(_: id, _: SEL, web_view: id) callconv(.c) void {
    const self = fromView(web_view) orelse return;
    self.setError("The web content process stopped.", self.url.items);
}

/// target=_blank links and window.open: the same tab, since the app has no
/// separate window to give them.
fn createWebView(_: id, _: SEL, web_view: id, _: id, action: id, _: id) callconv(.c) id {
    const req = msg(id, action, "request", .{});
    if (req != null) _ = msg(id, web_view, "loadRequest:", .{req});
    return null;
}

// ── addresses ───────────────────────────────────────────────────────────
/// The address a typed string means: as is with a scheme, https:// (http://
/// for local hosts) in front of something host-like, else a web search.
/// Caller frees.
pub fn resolve(gpa: std.mem.Allocator, typed: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const t = std.mem.trim(u8, typed, " \t\r\n");
    if (t.len == 0) return out.toOwnedSlice(gpa);
    if (hasScheme(t)) {
        try out.appendSlice(gpa, t);
    } else if (looksLikeHost(t)) {
        try out.appendSlice(gpa, if (isLocal(t)) "http://" else "https://");
        try out.appendSlice(gpa, t);
    } else {
        try out.appendSlice(gpa, search_url);
        for (t) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try out.append(gpa, c);
            } else if (c == ' ') {
                try out.append(gpa, '+');
            } else {
                var hex: [3]u8 = undefined;
                _ = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{c});
                try out.appendSlice(gpa, &hex);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// True when `resolve` would take `t` as an address rather than search for it.
pub fn isAddress(t: []const u8) bool {
    const trimmed = std.mem.trim(u8, t, " \t\r\n");
    return trimmed.len > 0 and (hasScheme(trimmed) or looksLikeHost(trimmed));
}

fn hasScheme(t: []const u8) bool {
    if (std.mem.indexOf(u8, t, "://") != null) return true;
    const bare = [_][]const u8{ "about:", "file:", "data:", "mailto:" };
    for (bare) |s| if (std.ascii.startsWithIgnoreCase(t, s)) return true;
    return false;
}

fn looksLikeHost(t: []const u8) bool {
    if (std.mem.indexOfAny(u8, t, " \t") != null) return false;
    const end = std.mem.indexOfAny(u8, t, "/?#") orelse t.len;
    const authority = t[0..end];
    const host = authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len];
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    // A dot somewhere and a plausible last label: "zig.news", "10.0.0.1".
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    const tld = host[dot + 1 ..];
    if (tld.len == 0) return false;
    for (tld) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn isLocal(t: []const u8) bool {
    const local = [_][]const u8{ "localhost", "127.", "0.0.0.0", "10.", "192.168." };
    for (local) |p| if (std.ascii.startsWithIgnoreCase(t, p)) return true;
    return false;
}

/// "https://zig.news/foo" → "zig.news".
pub fn hostOf(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const rest = url[start..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.startsWith(u8, host, "www.")) host = host[4..];
    return host;
}

test "resolve: scheme, host, search" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "https://ziglang.org/", "https://ziglang.org/" },
        .{ "  ziglang.org/download  ", "https://ziglang.org/download" },
        .{ "localhost:8080/x", "http://localhost:8080/x" },
        .{ "about:blank", "about:blank" },
        .{ "zig comptime tricks", "https://duckduckgo.com/?q=zig+comptime+tricks" },
        .{ "what is 2+2?", "https://duckduckgo.com/?q=what+is+2%2B2%3F" },
        .{ "", "" },
    };
    for (cases) |c| {
        const got = try resolve(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "isAddress" {
    try std.testing.expect(isAddress("https://ziglang.org/"));
    try std.testing.expect(isAddress(" ziglang.org/download "));
    try std.testing.expect(isAddress("localhost:8080"));
    try std.testing.expect(!isAddress("zig comptime tricks"));
    try std.testing.expect(!isAddress("what is 2+2?"));
    try std.testing.expect(!isAddress(""));
}

test "hostOf" {
    try std.testing.expectEqualStrings("zig.news", hostOf("https://www.zig.news/a/b?c"));
    try std.testing.expectEqualStrings("", hostOf(""));
}

/// The address a saved website tab was showing (see `save`).
fn keptUrl(out: *std.ArrayList(u8), gpa: std.mem.Allocator, saved: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, saved orelse return null, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "url\t")) continue;
        return records.unescape(out, gpa, line[4..]) catch null;
    }
    return null;
}

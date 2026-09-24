//! The bridge between the app and the pages in website tabs: JavaScript
//! the app runs in every page, and the messages that JavaScript sends back.
//!
//! A *bridge* is one channel of that: a script WebKit injects into each
//! page as it starts loading (a WKUserScript) and a handler in the app for
//! whatever the script posts (a WKScriptMessageHandler under the bridge's
//! name). The scripts run in a JavaScript world of their own — the page's
//! own code cannot see them, call them or post on their channel — and they
//! share that world with each other, so the `__tt` helper in `preamble` is
//! there for all of them. Payloads travel as JSON text, decoded here with
//! `std.json` into a struct the bridge declares.
//!
//! Adding a bridge:
//!
//!   1. a namespace like `selection` below: a `pub const bridge: Bridge`
//!      with the channel name, the script (which calls `__tt.post(name,
//!      {…})`) and an `onMessage` that `decode`s the payload and acts on
//!      the tab,
//!   2. one entry in `all`.
//!
//! The app side reaches into a page with `WebTab.eval`, which runs
//! JavaScript in the same world, so it can call what a script defined.
//! Nothing comes back from `eval` (WebKit reports results through a block,
//! which the Objective-C bridge does not do): a script that has something
//! to say posts it on its channel.
//!
//! A bridge can instead live in the page's own world (`page_world`): that
//! is for scripts whose job is to change what the page itself sees, like
//! the Notification API the `notifications` bridge puts in. The page can
//! then post on that channel too, so its handler checks what it is told
//! against the origin WebKit reports, never the payload's word.
//!
//! TT_DEBUG_EVENTS prints every message as it arrives, channel and JSON;
//! `TT_SELFTEST_WEBMENU=1` with `TT_SELFTEST_URL` (cocoa.zig) drives the
//! selection bridge and the context menu in a real window, and
//! `TT_SELFTEST_PERMISSIONS=1` the notifications bridge and the prompt bar.
const std = @import("std");
const objc = @import("../objc.zig");
const web_tab = @import("web_tab.zig");
const config = @import("../config.zig");

const WebTab = web_tab.WebTab;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSInteger = objc.NSInteger;

pub const Bridge = struct {
    /// The channel: `__tt.post("<name>", …)` in the page reaches `onMessage`.
    name: [:0]const u8,
    /// Run in every page as it starts loading, before the page's own scripts.
    script: []const u8,
    /// Only in the top document, or in its frames too (each posts for itself).
    main_frame_only: bool = true,
    /// In the page's own JavaScript world rather than the bridges' private
    /// one; such a script has no `__tt` and posts on its channel itself.
    page_world: bool = false,
    /// JavaScript made as the scripts go in, run just before `script` in
    /// the same world: what the app knows at that moment (see
    /// `refreshScripts`). Null = none.
    prelude: ?*const fn (gpa: std.mem.Allocator) ?[]u8 = null,
    /// The payload as the script posted it (JSON text) and the origin of
    /// the frame that posted it, as WebKit reports it; on the main thread,
    /// between frames, so the tab may be changed freely.
    onMessage: *const fn (tab: *WebTab, body: []const u8, origin: []const u8) void,
};

/// Every bridge. The scripts go into the page in this order, after `preamble`.
pub const all = [_]Bridge{
    selection.bridge,
    notifications.bridge,
};

/// Shared by every bridge's script (in every frame, so scripts that run in
/// frames have it too).
const preamble =
    \\window.__tt = {
    \\  post(channel, payload) {
    \\    try { window.webkit.messageHandlers[channel].postMessage(JSON.stringify(payload)); } catch (e) {}
    \\  }
    \\};
;

/// Puts the scripts and the message handlers into a web view's configuration.
pub fn install(configuration: id) void {
    const controller = msg(id, configuration, "userContentController", .{});
    addScripts(controller);
    for (all) |b| {
        msg(void, controller, "addScriptMessageHandler:contentWorld:name:", .{ handler(), worldOf(b), objc.nsString(b.name) });
    }
}

/// Makes the scripts again, so pages loaded from now on get what the
/// preludes say now (the page on show is told separately, by `eval`).
pub fn refreshScripts(view: id) void {
    const configuration = msg(id, view, "configuration", .{});
    const controller = msg(id, configuration, "userContentController", .{});
    msg(void, controller, "removeAllUserScripts", .{});
    addScripts(controller);
}

fn addScripts(controller: id) void {
    addScript(controller, contentWorld(), preamble, false);
    for (all) |b| {
        if (b.prelude) |make| if (make(std.heap.c_allocator)) |js| {
            defer std.heap.c_allocator.free(js);
            addScript(controller, worldOf(b), js, b.main_frame_only);
        };
        addScript(controller, worldOf(b), b.script, b.main_frame_only);
    }
}

/// Runs JavaScript in the page's main frame, in the bridges' world.
pub fn eval(view: id, js: []const u8) void {
    evalIn(view, js, contentWorld());
}

/// Runs JavaScript in the page's main frame, in the page's own world
/// (where the page-world bridges' scripts are).
pub fn evalPage(view: id, js: []const u8) void {
    evalIn(view, js, msg(id, objc.class("WKContentWorld"), "pageWorld", .{}));
}

fn evalIn(view: id, js: []const u8, world: id) void {
    msg(void, view, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString(js), @as(id, null), world, @as(?*const anyopaque, null),
    });
}

fn worldOf(b: Bridge) id {
    return if (b.page_world) msg(id, objc.class("WKContentWorld"), "pageWorld", .{}) else contentWorld();
}

/// "https://teams.microsoft.com" — scheme://host[:port] — of a WebKit
/// WKSecurityOrigin, in `buf`. Empty when there is none.
pub fn originOf(buf: []u8, sec: id) []const u8 {
    if (sec == null) return "";
    const proto = objc.utf8(msg(id, sec, "protocol", .{}));
    const host = objc.utf8(msg(id, sec, "host", .{}));
    const port = msg(NSInteger, sec, "port", .{});
    return formatOrigin(buf, proto, host, port);
}

pub fn formatOrigin(buf: []u8, proto: []const u8, host: []const u8, port: NSInteger) []const u8 {
    if (proto.len == 0) return "";
    const default_port = (std.mem.eql(u8, proto, "https") and port == 443) or (std.mem.eql(u8, proto, "http") and port == 80);
    if (port > 0 and !default_port) return std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ proto, host, port }) catch "";
    return std.fmt.bufPrint(buf, "{s}://{s}", .{ proto, host }) catch "";
}

/// The payload as `T`: fields the script did not send keep their defaults,
/// fields `T` does not know are skipped. Null when the text is not JSON of
/// that shape — a script bug, never a crash. Free with `deinit`.
pub fn decode(comptime T: type, gpa: std.mem.Allocator, body: []const u8) ?std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn addScript(controller: id, world: id, source: []const u8, main_frame_only: bool) void {
    // WKUserScriptInjectionTimeAtDocumentStart = 0.
    const script = msg(id, objc.alloc("WKUserScript"), "initWithSource:injectionTime:forMainFrameOnly:inContentWorld:", .{
        objc.nsString(source), @as(NSInteger, 0), main_frame_only, world,
    });
    defer objc.release(script);
    msg(void, controller, "addUserScript:", .{script});
}

/// The world the scripts run in: the app's own, apart from the page's.
fn contentWorld() id {
    return msg(id, objc.class("WKContentWorld"), "defaultClientWorld", .{});
}

// ── the message handler ─────────────────────────────────────────────────
// One object for every web view and channel: WebKit says which web view a
// message came from and on which channel, which is all the dispatch needs.
// It lives for the whole run (the content controllers hold it anyway).
var handler_obj: id = null;

fn handler() id {
    if (handler_obj == null) {
        const b = objc.ClassBuilder.begin("TTWebBridge", "NSObject");
        b.protocol("WKScriptMessageHandler");
        b.method("userContentController:didReceiveScriptMessage:", didReceive, "v@:@@");
        handler_obj = msg(id, msg(id, b.register(), "alloc", .{}), "init", .{});
    }
    return handler_obj;
}

fn didReceive(_: id, _: SEL, _: id, message: id) callconv(.c) void {
    const tab = WebTab.fromView(msg(id, message, "webView", .{})) orelse return;
    const body = msg(id, message, "body", .{});
    if (body == null or !msg(bool, body, "isKindOfClass:", .{objc.class("NSString")})) return;
    const name = objc.utf8(msg(id, message, "name", .{}));
    const frame = msg(id, message, "frameInfo", .{});
    var origin_buf: [512]u8 = undefined;
    const origin = if (frame != null) originOf(&origin_buf, msg(id, frame, "securityOrigin", .{})) else "";
    if (@import("../sys.zig").getenv("TT_DEBUG_EVENTS") != null) {
        std.debug.print("web bridge {s} ({s}): {s}\n", .{ name, origin, objc.utf8(body) });
    }
    for (all) |b| {
        if (!std.mem.eql(u8, b.name, name)) continue;
        // A page-world channel is within reach of every frame's scripts: a
        // bridge meant for the top document does not take a frame's word
        // (an embedded ad asking for notifications as itself).
        if (b.main_frame_only and frame != null and !msg(bool, frame, "isMainFrame", .{})) return;
        return b.onMessage(tab, objc.utf8(body), origin);
    }
}

// ── bridges ─────────────────────────────────────────────────────────────

/// What the user has selected in the page, and the link under the pointer
/// when the context menu opens. The tab keeps the latest for its context
/// menu (web_menu.zig). Selection changes are posted after a short pause,
/// so a drag does not post on every pixel; the context menu posts at once,
/// and that message reaches the app before WebKit asks for the menu.
pub const selection = struct {
    pub const bridge: Bridge = .{ .name = "selection", .script = script, .onMessage = onMessage };

    pub const Message = struct {
        /// "selectionchange" as it changes, "contextmenu" as the menu opens.
        why: []const u8 = "",
        text: []const u8 = "",
        /// The link under the pointer (context menu only), as an absolute address.
        link: []const u8 = "",
        url: []const u8 = "",
    };

    const script =
        \\(() => {
        \\  let last = "";
        \\  let timer = 0;
        \\  const current = () => {
        \\    const el = document.activeElement;
        \\    if (el && (el.tagName === "TEXTAREA" || el.tagName === "INPUT") && typeof el.selectionStart === "number") {
        \\      return el.value.slice(el.selectionStart, el.selectionEnd).trim();
        \\    }
        \\    const s = window.getSelection();
        \\    return s ? String(s).trim() : "";
        \\  };
        \\  const post = (why, link) => {
        \\    const text = current();
        \\    if (why === "selectionchange" && text === last) return;
        \\    last = text;
        \\    __tt.post("selection", { why, text, link, url: location.href });
        \\  };
        \\  document.addEventListener("selectionchange", () => {
        \\    clearTimeout(timer);
        \\    timer = setTimeout(() => post("selectionchange", ""), 60);
        \\  });
        \\  document.addEventListener("contextmenu", (e) => {
        \\    clearTimeout(timer);
        \\    const a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
        \\    post("contextmenu", a ? a.href : "");
        \\  }, true);
        \\})();
    ;

    fn onMessage(tab: *WebTab, body: []const u8, _: []const u8) void {
        var parsed = decode(Message, tab.gpa, body) orelse return;
        defer parsed.deinit();
        const m = parsed.value;
        // Only the context menu knows what is under the pointer.
        tab.setSelection(m.text, if (std.mem.eql(u8, m.why, "contextmenu")) m.link else null);
    }
};

/// The web Notification API, for pages in website tabs. WebKit does not
/// give pages in an app's web view notifications of their own, so this puts
/// a `Notification` in the page's world that behaves like the browser's —
/// `permission`, `requestPermission()`, `new Notification(title, options)`,
/// `close()`, click/show/close/error events, `navigator.permissions` for
/// "notifications" — and hands the real work to the app: asking the user
/// (the bar under the address bar), and posting to Notification Center with
/// the site's favicon (platform/notify.zig). What each site was answered
/// comes in with the prelude, so `Notification.permission` is right from
/// the first line of the page's own code.
pub const notifications = struct {
    pub const bridge: Bridge = .{
        .name = "ttNotify",
        .script = script,
        .page_world = true,
        .prelude = prelude,
        .onMessage = onMessage,
    };

    pub const Message = struct {
        /// "request" (Notification.requestPermission), "show", "close".
        op: []const u8 = "",
        id: u32 = 0,
        title: []const u8 = "",
        body: []const u8 = "",
        tag: []const u8 = "",
        silent: bool = false,
        /// Where the site's icon may be, best first.
        icons: []const []const u8 = &.{},
    };

    /// `window.__ttNotifyStates = {"default":"default","sites":{…}}`: the
    /// permission every site starts with, and the sites with an answer.
    fn prelude(gpa: std.mem.Allocator) ?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        out.appendSlice(gpa, "window.__ttNotifyStates = ") catch return null;
        states(gpa, config.get(), &out) catch {
            out.deinit(gpa);
            return null;
        };
        out.appendSlice(gpa, ";") catch return null;
        return out.toOwnedSlice(gpa) catch null;
    }

    /// The permissions as JSON (see `prelude`).
    pub fn states(gpa: std.mem.Allocator, cfg: *const config.Config, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "{\"default\":\"");
        try out.appendSlice(gpa, stateName(cfg.browser.notifications));
        try out.appendSlice(gpa, "\",\"sites\":{");
        var first = true;
        for (cfg.sites.items) |st| {
            if (st.notifications == .ask) continue;
            if (!first) try out.append(gpa, ',');
            first = false;
            try jsonString(gpa, out, st.origin);
            try out.append(gpa, ':');
            try out.append(gpa, '"');
            try out.appendSlice(gpa, stateName(st.notifications));
            try out.append(gpa, '"');
        }
        try out.appendSlice(gpa, "}}");
    }

    /// The web's name for a permission: "default" is "not asked yet".
    pub fn stateName(p: config.Permission) []const u8 {
        return switch (p) {
            .ask => "default",
            .allow => "granted",
            .block => "denied",
        };
    }

    fn jsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        try out.append(gpa, '"');
        for (s) |c| switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0...0x1f, '<', '>' => try out.print(gpa, "\\u{x:0>4}", .{c}),
            else => try out.append(gpa, c),
        };
        try out.append(gpa, '"');
    }

    const script =
        \\(() => {
        \\  const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ttNotify;
        \\  const given = window.__ttNotifyStates || { default: "default", sites: {} };
        \\  try { delete window.__ttNotifyStates; } catch (e) {}
        \\  if (!channel) return;
        \\  const send = (m) => { try { channel.postMessage(JSON.stringify(m)); } catch (e) {} };
        \\  const stateFor = (s) => (s.sites && s.sites[location.origin]) || s.default || "default";
        \\  let permission = stateFor(given);
        \\  const live = new Map();
        \\  let waiting = [];
        \\  const statuses = new Set();
        \\  let next = 1;
        \\  // Where the site's icon is, best first: its <link rel=icon> entries
        \\  // (largest first; SVG last, macOS may not read it), then the
        \\  // apple-touch icons, then /favicon.ico.
        \\  const icons = () => {
        \\    const rank = (l) => {
        \\      const rel = (l.getAttribute("rel") || "").toLowerCase().split(/\s+/);
        \\      const icon = rel.includes("icon");
        \\      const touch = rel.some((r) => r.startsWith("apple-touch-icon"));
        \\      if (!icon && !touch) return -1;
        \\      let size = 0;
        \\      for (const s of (l.getAttribute("sizes") || "").toLowerCase().split(/\s+/)) {
        \\        if (s === "any") size = Math.max(size, 256);
        \\        const n = parseInt(s, 10);
        \\        if (n > size) size = n;
        \\      }
        \\      if (!size) size = touch ? 180 : 32;
        \\      if (/svg/i.test(l.type || "") || /\.svg([?#]|$)/i.test(l.href)) size = 1;
        \\      return (icon ? 1000 : 0) + Math.min(size, 256);
        \\    };
        \\    const out = [];
        \\    const add = (u) => { if (u && !out.includes(u)) out.push(u); };
        \\    Array.from(document.querySelectorAll("link[rel][href]"))
        \\      .map((l) => [rank(l), l.href]).filter((e) => e[0] >= 0)
        \\      .sort((a, b) => b[0] - a[0]).forEach((e) => add(e[1]));
        \\    if (/^https?:$/.test(location.protocol)) add(location.origin + "/favicon.ico");
        \\    return out.slice(0, 4);
        \\  };
        \\  const fire = (n, type) => {
        \\    const ev = new Event(type, { cancelable: type === "click" });
        \\    const h = n["on" + type];
        \\    if (typeof h === "function") { try { h.call(n, ev); } catch (e) { setTimeout(() => { throw e; }); } }
        \\    n.dispatchEvent(ev);
        \\  };
        \\  class Notification extends EventTarget {
        \\    constructor(title, options) {
        \\      super();
        \\      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
        \\      const o = options || {};
        \\      const id = next++;
        \\      Object.defineProperty(this, "__ttId", { value: id });
        \\      this.title = String(title);
        \\      this.body = o.body === undefined ? "" : String(o.body);
        \\      this.tag = o.tag === undefined ? "" : String(o.tag);
        \\      this.icon = o.icon === undefined ? "" : String(o.icon);
        \\      this.image = o.image === undefined ? "" : String(o.image);
        \\      this.badge = o.badge === undefined ? "" : String(o.badge);
        \\      this.data = o.data === undefined ? null : o.data;
        \\      this.dir = o.dir || "auto";
        \\      this.lang = o.lang || "";
        \\      this.silent = !!o.silent;
        \\      this.renotify = !!o.renotify;
        \\      this.requireInteraction = !!o.requireInteraction;
        \\      this.timestamp = typeof o.timestamp === "number" ? o.timestamp : Date.now();
        \\      this.actions = [];
        \\      this.onclick = this.onshow = this.onclose = this.onerror = null;
        \\      if (permission !== "granted") { setTimeout(() => fire(this, "error"), 0); return; }
        \\      if (this.tag) for (const [k, n] of live) if (n.tag === this.tag) live.delete(k);
        \\      live.set(id, this);
        \\      send({ op: "show", id, title: this.title, body: this.body, tag: this.tag, silent: this.silent, icons: icons() });
        \\      setTimeout(() => fire(this, "show"), 0);
        \\    }
        \\    close() {
        \\      if (!live.delete(this.__ttId)) return;
        \\      send({ op: "close", id: this.__ttId, tag: this.tag });
        \\      fire(this, "close");
        \\    }
        \\    static get permission() { return permission; }
        \\    static get maxActions() { return 0; }
        \\    static requestPermission(callback) {
        \\      return new Promise((resolve) => {
        \\        const done = (p) => { if (typeof callback === "function") { try { callback(p); } catch (e) {} } resolve(p); };
        \\        if (permission !== "default") return done(permission);
        \\        waiting.push(done);
        \\        if (waiting.length === 1) send({ op: "request" });
        \\      });
        \\    }
        \\  }
        \\  Object.defineProperty(window, "Notification", { value: Notification, writable: true, configurable: true, enumerable: false });
        \\  // navigator.permissions.query({ name: "notifications" }) tells the same story.
        \\  const perms = navigator.permissions;
        \\  if (perms && typeof perms.query === "function") {
        \\    const query = perms.query.bind(perms);
        \\    const webName = () => (permission === "default" ? "prompt" : permission);
        \\    perms.query = function (desc) {
        \\      if (desc && (desc.name === "notifications" || desc.name === "push")) {
        \\        const status = new EventTarget();
        \\        Object.defineProperty(status, "state", { get: webName });
        \\        Object.defineProperty(status, "name", { value: desc.name });
        \\        status.onchange = null;
        \\        statuses.add(status);
        \\        return Promise.resolve(status);
        \\      }
        \\      return query(desc);
        \\    };
        \\  }
        \\  // Registrations shown from the page itself (not from the worker).
        \\  if (window.ServiceWorkerRegistration) {
        \\    ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
        \\      if (permission !== "granted") return Promise.reject(new TypeError("No notification permission has been granted for this origin."));
        \\      new Notification(title, options);
        \\      return Promise.resolve();
        \\    };
        \\    ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
        \\  }
        \\  const settle = (p) => {
        \\    const changed = p !== permission;
        \\    permission = p;
        \\    const w = waiting;
        \\    waiting = [];
        \\    for (const f of w) f(p);
        \\    if (changed) for (const s of statuses) {
        \\      const ev = new Event("change");
        \\      if (typeof s.onchange === "function") { try { s.onchange(ev); } catch (e) {} }
        \\      s.dispatchEvent(ev);
        \\    }
        \\  };
        \\  // The app's side: answers, new settings, clicks.
        \\  Object.defineProperty(window, "__ttNotifications", { enumerable: false, value: Object.freeze({
        \\    answer(p) { settle(p === "granted" || p === "denied" ? p : permission); },
        \\    states(s) { settle(stateFor(s)); },
        \\    click(id) {
        \\      const n = live.get(id);
        \\      if (!n) return;
        \\      try { window.focus(); } catch (e) {}
        \\      fire(n, "click");
        \\    },
        \\  }) });
        \\})();
    ;

    fn onMessage(tab: *WebTab, body: []const u8, origin: []const u8) void {
        var parsed = decode(Message, tab.gpa, body) orelse return;
        defer parsed.deinit();
        tab.onNotifyMessage(parsed.value, origin);
    }
};

test "decode: defaults for what is missing, unknown fields skipped, junk is null" {
    const gpa = std.testing.allocator;
    var p = decode(selection.Message, gpa, "{\"why\":\"contextmenu\",\"text\":\"hi there\",\"extra\":[1,2]}") orelse return error.TestUnexpectedResult;
    defer p.deinit();
    try std.testing.expectEqualStrings("contextmenu", p.value.why);
    try std.testing.expectEqualStrings("hi there", p.value.text);
    try std.testing.expectEqualStrings("", p.value.link);
    try std.testing.expect(decode(selection.Message, gpa, "not json") == null);
    try std.testing.expect(decode(selection.Message, gpa, "{\"text\":42}") == null);
}

test "notifications: the states JSON has the default and the answered sites" {
    const gpa = std.testing.allocator;
    var cfg = config.Config.init(gpa);
    defer cfg.deinit();
    cfg.setSitePermission("https://teams.microsoft.com", .notifications, .allow);
    cfg.setSitePermission("https://spam.example", .notifications, .block);
    cfg.setSitePermission("https://cam.example", .camera, .allow);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try notifications.states(gpa, &cfg, &out);
    try std.testing.expectEqualStrings("{\"default\":\"default\",\"sites\":{\"https://teams.microsoft.com\":\"granted\",\"https://spam.example\":\"denied\"}}", out.items);
    var p = decode(struct { default: []const u8 = "" }, gpa, out.items) orelse return error.TestUnexpectedResult;
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.value.default);
}

test "formatOrigin: default ports are left out" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://teams.microsoft.com", formatOrigin(&buf, "https", "teams.microsoft.com", 0));
    try std.testing.expectEqualStrings("https://a.example", formatOrigin(&buf, "https", "a.example", 443));
    try std.testing.expectEqualStrings("http://localhost:8080", formatOrigin(&buf, "http", "localhost", 8080));
    try std.testing.expectEqualStrings("file://", formatOrigin(&buf, "file", "", 0));
    try std.testing.expectEqualStrings("", formatOrigin(&buf, "", "", 0));
}

test "notifications: the message decodes, icons and all" {
    const gpa = std.testing.allocator;
    var p = decode(notifications.Message, gpa, "{\"op\":\"show\",\"id\":3,\"title\":\"Ana\",\"body\":\"hi\",\"tag\":\"\",\"silent\":false,\"icons\":[\"https://a.example/i.png\",\"https://a.example/favicon.ico\"]}") orelse return error.TestUnexpectedResult;
    defer p.deinit();
    try std.testing.expectEqualStrings("show", p.value.op);
    try std.testing.expectEqual(@as(u32, 3), p.value.id);
    try std.testing.expectEqual(@as(usize, 2), p.value.icons.len);
}

test "bridges: distinct channels, scripts that post on them" {
    for (all, 0..) |a, i| {
        try std.testing.expect(a.script.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, a.script, a.name) != null);
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}

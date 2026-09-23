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
//! TT_DEBUG_EVENTS prints every message as it arrives, channel and JSON;
//! `TT_SELFTEST_WEBMENU=1` with `TT_SELFTEST_URL` (cocoa.zig) drives the
//! selection bridge and the context menu in a real window.
const std = @import("std");
const objc = @import("../objc.zig");
const web_tab = @import("web_tab.zig");

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
    /// The payload as the script posted it (JSON text); on the main thread,
    /// between frames, so the tab may be changed freely.
    onMessage: *const fn (tab: *WebTab, body: []const u8) void,
};

/// Every bridge. The scripts go into the page in this order, after `preamble`.
pub const all = [_]Bridge{
    selection.bridge,
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
pub fn install(config: id) void {
    const controller = msg(id, config, "userContentController", .{});
    const world = contentWorld();
    addScript(controller, world, preamble, false);
    for (all) |b| {
        addScript(controller, world, b.script, b.main_frame_only);
        msg(void, controller, "addScriptMessageHandler:contentWorld:name:", .{ handler(), world, objc.nsString(b.name) });
    }
}

/// Runs JavaScript in the page's main frame, in the bridges' world.
pub fn eval(view: id, js: []const u8) void {
    msg(void, view, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString(js), @as(id, null), contentWorld(), @as(?*const anyopaque, null),
    });
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
    if (@import("../sys.zig").getenv("TT_DEBUG_EVENTS") != null) {
        std.debug.print("web bridge {s}: {s}\n", .{ name, objc.utf8(body) });
    }
    for (all) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.onMessage(tab, objc.utf8(body));
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

    fn onMessage(tab: *WebTab, body: []const u8) void {
        var parsed = decode(Message, tab.gpa, body) orelse return;
        defer parsed.deinit();
        const m = parsed.value;
        // Only the context menu knows what is under the pointer.
        tab.setSelection(m.text, if (std.mem.eql(u8, m.why, "contextmenu")) m.link else null);
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

test "bridges: distinct channels, scripts that post on them" {
    for (all, 0..) |a, i| {
        try std.testing.expect(a.script.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, a.script, a.name) != null);
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}

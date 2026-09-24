//! Desktop notifications for website tabs. What a page shows with the web
//! Notification API (the `notifications` bridge in tabs/web_bridge.zig) is
//! posted to macOS's Notification Center through UserNotifications, with the
//! site's icon — its favicon, fetched once per site and kept for the run —
//! attached as the notification's picture. A click on one brings its tab
//! back (`on_click`, set by the website tabs).
//!
//! macOS only delivers notifications to an app bundle (zig-out/tt.app); the
//! bare binary (zig-out/bin/tt) has no bundle identifier, so there
//! `available()` is false and nothing is posted. `TT_NOTIFY_DRYRUN=1` prints
//! what would be posted instead and leaves the icon file in place — how the
//! selftest checks the whole path without touching Notification Center.
//!
//! Favicons are fetched by an NSURLSession whose delegate runs on the main
//! queue, so every part of this file runs on the main thread; only the
//! authorization answers arrive elsewhere, and they only store a number.
const std = @import("std");
const objc = @import("../objc.zig");
const sys = @import("../sys.zig");

const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;
const CGRect = objc.CGRect;
const CGSize = objc.CGSize;

/// A notification a page asked for.
pub const Note = struct {
    /// The website tab (`WebTab.serial`) and the page's own number for the
    /// notification, handed back by `on_click`.
    tab: u32,
    nid: u32,
    /// "https://teams.microsoft.com": the site, whose icon goes with it.
    origin: []const u8,
    title: []const u8,
    body: []const u8 = "",
    /// A non-empty tag replaces the site's earlier notification with that tag.
    tag: []const u8 = "",
    silent: bool = false,
    /// Where the site's icon may be, best first (the page's <link rel=icon>
    /// entries, then /favicon.ico).
    icons: []const []const u8 = &.{},
};

/// Whether macOS lets tt show notifications.
pub const Auth = enum(u8) {
    /// Not known yet (the answer is on its way), or never asked for.
    unknown,
    not_determined,
    denied,
    authorized,
    /// No app bundle: macOS will not deliver anything.
    unavailable,

    pub fn label(self: Auth) []const u8 {
        return switch (self) {
            .unknown => "Checking…",
            .not_determined => "Not asked yet",
            .denied => "Off",
            .authorized => "Allowed",
            .unavailable => "Needs tt.app",
        };
    }
};

/// A notification was clicked: which tab, which of its notifications, and
/// the site (to open again when the tab is gone). On the main thread.
pub var on_click: ?*const fn (tab: u32, nid: u32, origin: []const u8) void = null;

const gpa = std.heap.c_allocator;

/// Posting is possible: a bundle with an identifier, or a dry run.
pub fn available() bool {
    if (dryRun()) return true;
    const S = struct {
        var checked = false;
        var ok = false;
    };
    if (!S.checked) {
        S.checked = true;
        const bundle = msg(id, objc.class("NSBundle"), "mainBundle", .{});
        const bid = msg(id, bundle, "bundleIdentifier", .{});
        S.ok = bid != null and objc.objc_getClass("UNUserNotificationCenter") != null;
    }
    return S.ok;
}

fn dryRun() bool {
    return sys.getenv("TT_NOTIFY_DRYRUN") != null;
}

fn center() id {
    return msg(id, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
}

/// At launch, before the app has finished launching (so a click that
/// started tt is delivered): who hears about clicks, and what macOS says
/// about tt's notifications.
pub fn setup() void {
    if (!available() or dryRun()) return;
    msg(void, center(), "setDelegate:", .{delegate()});
    refreshAuth();
}

// ── posting ─────────────────────────────────────────────────────────────

/// Posts `note`, with the site's icon when it can be had. The first
/// notification of a site waits for its icon (a few seconds at most).
pub fn show(note: Note) void {
    if (!available()) return;
    const job = Job.create(note) catch return;
    if (icon_cache.get(job.origin)) |png| {
        job.post(if (png.len > 0) png else null);
        job.destroy();
        return;
    }
    job.fetchNext();
}

/// Takes a notification of `tab` back out of Notification Center (the page
/// called `close()` on it).
pub fn remove(tab: u32, nid: u32, origin: []const u8, tag: []const u8) void {
    if (!available()) return;
    var buf: [512]u8 = undefined;
    const ident = identFor(&buf, tab, nid, origin, tag);
    if (dryRun()) {
        std.debug.print("notify: remove {s}\n", .{ident});
        return;
    }
    const list = msg(id, objc.class("NSArray"), "arrayWithObject:", .{objc.nsString(ident)});
    msg(void, center(), "removeDeliveredNotificationsWithIdentifiers:", .{list});
    msg(void, center(), "removePendingNotificationRequestsWithIdentifiers:", .{list});
}

/// A notification from tt itself, to check that macOS shows them
/// (Settings › Notifications).
pub fn sendTest() void {
    if (!available()) return;
    requestAuth();
    const job = Job.create(.{
        .tab = 0,
        .nid = 0,
        .origin = "",
        .title = "tt",
        .body = "Notifications from websites will look like this, with the site's icon.",
        .tag = "tt-test",
    }) catch return;
    job.post(null);
    job.destroy();
}

/// The identifier Notification Center knows a notification by: a tagged
/// one is the site's with that tag (a new one replaces it), else the tab's
/// numbered one.
pub fn identFor(buf: []u8, tab: u32, nid: u32, origin: []const u8, tag: []const u8) []const u8 {
    if (tag.len > 0) return std.fmt.bufPrint(buf, "tt|{s}|tag|{s}", .{ origin, tag }) catch "tt";
    return std.fmt.bufPrint(buf, "tt|{d}|{d}", .{ tab, nid }) catch "tt";
}

/// "https://teams.microsoft.com" → "teams.microsoft.com"; other schemes
/// (http, a port) are kept so the user sees what it is.
pub fn siteName(origin: []const u8) []const u8 {
    if (std.mem.startsWith(u8, origin, "https://")) return origin["https://".len..];
    return origin;
}

/// A site's icon, as PNG bytes; "" = none could be had.
var icon_cache: std.StringHashMapUnmanaged([]u8) = .empty;

const Job = struct {
    tab: u32,
    nid: u32,
    ident: []u8,
    origin: []u8,
    title: []u8,
    body: []u8,
    silent: bool,
    icons: [][]u8,
    next: usize = 0,
    /// The fetch under way (retained) and what it has brought so far.
    task: id = null,
    data: id = null,

    fn create(note: Note) !*Job {
        const self = try gpa.create(Job);
        errdefer gpa.destroy(self);
        var buf: [512]u8 = undefined;
        const icons = try gpa.alloc([]u8, @min(note.icons.len, 4));
        for (icons, 0..) |*slot, i| slot.* = try gpa.dupe(u8, note.icons[i]);
        self.* = .{
            .tab = note.tab,
            .nid = note.nid,
            .ident = try gpa.dupe(u8, identFor(&buf, note.tab, note.nid, note.origin, note.tag)),
            .origin = try gpa.dupe(u8, note.origin),
            .title = try gpa.dupe(u8, note.title),
            .body = try gpa.dupe(u8, note.body),
            .silent = note.silent,
            .icons = icons,
        };
        return self;
    }

    fn destroy(self: *Job) void {
        objc.release(self.task);
        objc.release(self.data);
        for (self.icons) |s| gpa.free(s);
        gpa.free(self.icons);
        gpa.free(self.ident);
        gpa.free(self.origin);
        gpa.free(self.title);
        gpa.free(self.body);
        gpa.destroy(self);
    }

    /// Starts on the next place the icon may be; when there is none left,
    /// the site has no icon we can use and the notification goes without.
    fn fetchNext(self: *Job) void {
        objc.release(self.task);
        objc.release(self.data);
        self.task = null;
        self.data = null;
        while (self.next < self.icons.len) {
            const url_text = self.icons[self.next];
            self.next += 1;
            const url = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url_text)});
            if (url == null) continue;
            // NSURLRequestUseProtocolCachePolicy, a short wait.
            const req = msg(id, objc.class("NSURLRequest"), "requestWithURL:cachePolicy:timeoutInterval:", .{ url, @as(NSUInteger, 0), @as(f64, 5) });
            const task = msg(id, session(), "dataTaskWithRequest:", .{req});
            if (task == null) continue;
            self.task = objc.retain(task);
            self.data = objc.new("NSMutableData");
            jobs.append(gpa, self) catch {
                self.finish(null);
                return;
            };
            msg(void, task, "resume", .{});
            return;
        }
        // Nothing usable: remember that, so the site's next ones do not wait.
        self.cacheIcon(null);
        self.finish(null);
    }

    /// The fetch ended: an image makes the icon, anything else moves on.
    fn fetched(self: *Job, err: id) void {
        var ok = err == null;
        if (ok) {
            const resp = msg(id, self.task, "response", .{});
            if (resp != null and msg(bool, resp, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")})) {
                const code = msg(NSInteger, resp, "statusCode", .{});
                ok = code >= 200 and code < 300;
            }
        }
        if (ok) if (rasterize(self.data)) |png| {
            self.cacheIcon(png);
            self.finish(png);
            return;
        };
        self.fetchNext();
    }

    fn cacheIcon(self: *Job, png: ?[]u8) void {
        if (self.origin.len == 0 or icon_cache.contains(self.origin)) return;
        const key = gpa.dupe(u8, self.origin) catch return;
        const val = gpa.dupe(u8, png orelse "") catch {
            gpa.free(key);
            return;
        };
        icon_cache.put(gpa, key, val) catch {
            gpa.free(key);
            gpa.free(val);
        };
    }

    fn finish(self: *Job, png: ?[]u8) void {
        self.post(png);
        if (png) |p| gpa.free(p);
        for (jobs.items, 0..) |j, i| {
            if (j == self) {
                _ = jobs.swapRemove(i);
                break;
            }
        }
        self.destroy();
    }

    /// Hands the notification to Notification Center (or prints it, in a
    /// dry run), the icon as its attachment.
    fn post(self: *Job, png: ?[]const u8) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const subtitle = siteName(self.origin);
        const icon_path = if (png) |p| writeIcon(p) else null;
        if (dryRun()) {
            std.debug.print("notify: post ident='{s}' title='{s}' subtitle='{s}' body='{s}' sound={} icon={s} icon_bytes={d}\n", .{
                self.ident, self.title, subtitle, self.body, !self.silent, if (icon_path) |ip| objc.utf8(ip) else "none", if (png) |p| p.len else 0,
            });
            return;
        }
        const content = objc.autorelease(objc.new("UNMutableNotificationContent"));
        msg(void, content, "setTitle:", .{objc.nsString(self.title)});
        if (subtitle.len > 0) msg(void, content, "setSubtitle:", .{objc.nsString(subtitle)});
        msg(void, content, "setBody:", .{objc.nsString(self.body)});
        // One stack per site in Notification Center.
        if (self.origin.len > 0) msg(void, content, "setThreadIdentifier:", .{objc.nsString(self.origin)});
        if (!self.silent) msg(void, content, "setSound:", .{msg(id, objc.class("UNNotificationSound"), "defaultSound", .{})});

        const info = msg(id, objc.class("NSMutableDictionary"), "dictionary", .{});
        msg(void, info, "setObject:forKey:", .{ msg(id, objc.class("NSNumber"), "numberWithUnsignedInt:", .{@as(c_uint, self.tab)}), objc.nsString("tab") });
        msg(void, info, "setObject:forKey:", .{ msg(id, objc.class("NSNumber"), "numberWithUnsignedInt:", .{@as(c_uint, self.nid)}), objc.nsString("nid") });
        msg(void, info, "setObject:forKey:", .{ objc.nsString(self.origin), objc.nsString("origin") });
        msg(void, content, "setUserInfo:", .{info});

        if (icon_path) |ip| {
            const url = msg(id, objc.class("NSURL"), "fileURLWithPath:", .{ip});
            const att = msg(id, objc.class("UNNotificationAttachment"), "attachmentWithIdentifier:URL:options:error:", .{
                objc.nsString("icon"), url, @as(id, null), @as(?*id, null),
            });
            if (att != null) msg(void, content, "setAttachments:", .{msg(id, objc.class("NSArray"), "arrayWithObject:", .{att})});
        }
        const req = msg(id, objc.class("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", .{ objc.nsString(self.ident), content, @as(id, null) });
        msg(void, center(), "addNotificationRequest:withCompletionHandler:", .{ req, @as(?*anyopaque, null) });
    }
};

/// Fetches under way, found again by their task when the session reports.
var jobs: std.ArrayList(*Job) = .empty;

/// The icon as a file of its own for the attachment (Notification Center
/// moves the file into its store, so every notification needs a copy).
/// An autoreleased NSString path, null when it could not be written.
fn writeIcon(png: []const u8) id {
    const S = struct {
        var n: u32 = 0;
    };
    S.n += 1;
    const fm = msg(id, objc.class("NSFileManager"), "defaultManager", .{});
    const tmp = msg(id, msg(id, fm, "temporaryDirectory", .{}), "path", .{});
    const dir_ns = msg(id, tmp, "stringByAppendingPathComponent:", .{objc.nsString("tt-notify")});
    _ = msg(bool, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ dir_ns, true, @as(id, null), @as(?*id, null) });
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "icon-{d}-{d}.png", .{ std.c.getpid(), S.n }) catch return null;
    const path = msg(id, dir_ns, "stringByAppendingPathComponent:", .{objc.nsString(name)});
    const data = msg(id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, png.ptr), @as(NSUInteger, png.len) });
    if (!msg(bool, data, "writeToFile:atomically:", .{ path, true })) return null;
    return path;
}


/// Any image macOS can read (PNG, ICO, JPEG, GIF, SVG where supported …),
/// drawn into a square PNG: 128 px, or up to 256 when the image has more.
/// Null when the bytes are not an image. The caller frees the result.
fn rasterize(data: id) ?[]u8 {
    if (data == null or msg(NSUInteger, data, "length", .{}) == 0) return null;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const img = objc.autorelease(msg(id, objc.alloc("NSImage"), "initWithData:", .{data}));
    if (img == null) return null;
    const size = msg(CGSize, img, "size", .{});
    if (size.width < 1 or size.height < 1) return null;

    var best: NSInteger = 0;
    const reps = msg(id, img, "representations", .{});
    const n = msg(NSUInteger, reps, "count", .{});
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) {
        const rep = msg(id, reps, "objectAtIndex:", .{i});
        best = @max(best, @max(msg(NSInteger, rep, "pixelsWide", .{}), msg(NSInteger, rep, "pixelsHigh", .{})));
    }
    // Vector images report no pixels: draw them large.
    const px: NSInteger = if (best <= 0) 256 else std.math.clamp(best, 128, 256);
    const pxf: f64 = @floatFromInt(px);

    const bitmap = objc.autorelease(msg(id, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), px, px, @as(NSInteger, 8), @as(NSInteger, 4), true, false, objc.nsString("NSDeviceRGBColorSpace"), @as(NSInteger, 0), @as(NSInteger, 0),
    }));
    if (bitmap == null) return null;
    const ctx = msg(id, objc.class("NSGraphicsContext"), "graphicsContextWithBitmapImageRep:", .{bitmap});
    if (ctx == null) return null;
    const gc = objc.class("NSGraphicsContext");
    msg(void, gc, "saveGraphicsState", .{});
    msg(void, gc, "setCurrentContext:", .{ctx});
    msg(void, ctx, "setImageInterpolation:", .{@as(NSUInteger, 3)}); // high
    const scale = @min(pxf / size.width, pxf / size.height);
    const w = size.width * scale;
    const h = size.height * scale;
    // NSCompositingOperationSourceOver = 2; a zero source rect = the whole image.
    msg(void, img, "drawInRect:fromRect:operation:fraction:", .{ CGRect.make((pxf - w) / 2, (pxf - h) / 2, w, h), CGRect{}, @as(NSUInteger, 2), @as(f64, 1) });
    msg(void, gc, "restoreGraphicsState", .{});

    // NSBitmapImageFileTypePNG = 4.
    const png = msg(id, bitmap, "representationUsingType:properties:", .{ @as(NSUInteger, 4), msg(id, objc.class("NSDictionary"), "dictionary", .{}) });
    if (png == null) return null;
    const len = msg(NSUInteger, png, "length", .{});
    const bytes = msg(?[*]const u8, png, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

// ── the favicon session ─────────────────────────────────────────────────
var session_obj: id = null;

fn session() id {
    if (session_obj == null) {
        const cfg = msg(id, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
        msg(void, cfg, "setTimeoutIntervalForRequest:", .{@as(f64, 5)});
        msg(void, cfg, "setTimeoutIntervalForResource:", .{@as(f64, 8)});
        const b = objc.ClassBuilder.begin("TTFaviconLoader", "NSObject");
        b.protocol("NSURLSessionDataDelegate");
        b.method("URLSession:dataTask:didReceiveData:", didReceiveData, "v@:@@@");
        b.method("URLSession:task:didCompleteWithError:", didComplete, "v@:@@@");
        const loader = msg(id, msg(id, b.register(), "alloc", .{}), "init", .{});
        const main_queue = msg(id, objc.class("NSOperationQueue"), "mainQueue", .{});
        session_obj = objc.retain(msg(id, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ cfg, loader, main_queue }));
        objc.release(loader);
    }
    return session_obj;
}

fn jobFor(task: id) ?*Job {
    for (jobs.items) |j| if (j.task == task) return j;
    return null;
}

fn didReceiveData(_: id, _: SEL, _: id, task: id, data: id) callconv(.c) void {
    const job = jobFor(task) orelse return;
    msg(void, job.data, "appendData:", .{data});
}

fn didComplete(_: id, _: SEL, _: id, task: id, err: id) callconv(.c) void {
    const job = jobFor(task) orelse return;
    // Out of the list first: `fetched` may start the next fetch.
    for (jobs.items, 0..) |j, i| {
        if (j == job) {
            _ = jobs.swapRemove(i);
            break;
        }
    }
    job.fetched(err);
}

// ── authorization ───────────────────────────────────────────────────────
var auth_state = std.atomic.Value(u8).init(@intFromEnum(Auth.unknown));
var auth_block: objc.Block = undefined;
var settings_block: objc.Block = undefined;

/// What macOS last said (see `refreshAuth`).
pub fn auth() Auth {
    if (dryRun()) return .authorized;
    if (!available()) return .unavailable;
    return @enumFromInt(auth_state.load(.acquire));
}

/// Asks macOS again what it lets tt do; the answer lands in `auth()` a
/// moment later.
pub fn refreshAuth() void {
    if (!available() or dryRun()) return;
    settings_block = objc.Block.global(@ptrCast(&settingsArrived), @sizeOf(objc.Block));
    msg(void, center(), "getNotificationSettingsWithCompletionHandler:", .{@as(?*anyopaque, &settings_block)});
}

/// Asks the user (through macOS, once) to let tt show notifications.
pub fn requestAuth() void {
    if (!available() or dryRun()) return;
    auth_block = objc.Block.global(@ptrCast(&authAnswered), @sizeOf(objc.Block));
    // UNAuthorizationOptionBadge | Sound | Alert.
    msg(void, center(), "requestAuthorizationWithOptions:completionHandler:", .{ @as(NSUInteger, 7), @as(?*anyopaque, &auth_block) });
}

fn settingsArrived(_: *objc.Block, settings: id) callconv(.c) void {
    // UNAuthorizationStatus: 0 not determined, 1 denied, 2 authorized,
    // 3 provisional, 4 ephemeral.
    const status = msg(NSInteger, settings, "authorizationStatus", .{});
    const a: Auth = switch (status) {
        0 => .not_determined,
        1 => .denied,
        else => .authorized,
    };
    auth_state.store(@intFromEnum(a), .release);
}

fn authAnswered(_: *objc.Block, granted: bool, _: id) callconv(.c) void {
    auth_state.store(@intFromEnum(if (granted) Auth.authorized else Auth.denied), .release);
}

/// System Settings › Notifications, at tt's entry when macOS knows it.
pub fn openSystemSettings() void {
    openUrl("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=es.lab34.tt");
}

pub fn openUrl(text: []const u8) void {
    const url = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(text)});
    if (url == null) return;
    const ws = msg(id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    _ = msg(bool, ws, "openURL:", .{url});
}

// ── clicks ──────────────────────────────────────────────────────────────
var delegate_obj: id = null;

fn delegate() id {
    if (delegate_obj == null) {
        const b = objc.ClassBuilder.begin("TTNotifyDelegate", "NSObject");
        b.protocol("UNUserNotificationCenterDelegate");
        b.method("userNotificationCenter:willPresentNotification:withCompletionHandler:", willPresent, "v@:@@@?");
        b.method("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", didReceiveResponse, "v@:@@@?");
        b.method("ttClicked:", clickedOnMain, "v@:@");
        delegate_obj = msg(id, msg(id, b.register(), "alloc", .{}), "init", .{});
    }
    return delegate_obj;
}

/// While tt is in front, notifications still show: the page decides when
/// to post one (Teams, say, only does for chats not on screen).
fn willPresent(_: id, _: SEL, _: id, _: id, handler: ?*anyopaque) callconv(.c) void {
    // UNNotificationPresentationOptionSound | List | Banner.
    objc.invokeBlock(handler, .{@as(NSUInteger, (1 << 1) | (1 << 3) | (1 << 4))});
}

fn didReceiveResponse(self: id, _: SEL, _: id, response: id, handler: ?*anyopaque) callconv(.c) void {
    const action = objc.utf8(msg(id, response, "actionIdentifier", .{}));
    if (!std.mem.eql(u8, action, "com.apple.UNNotificationDismissActionIdentifier")) {
        const note = msg(id, response, "notification", .{});
        const info = msg(id, msg(id, msg(id, note, "request", .{}), "content", .{}), "userInfo", .{});
        // The tabs live on the main thread; macOS may call from another.
        msg(void, self, "performSelectorOnMainThread:withObject:waitUntilDone:", .{ objc.sel("ttClicked:"), info, false });
    }
    objc.invokeBlock(handler, .{});
}

fn clickedOnMain(_: id, _: SEL, info: id) callconv(.c) void {
    if (info == null) return;
    const tab_n = msg(id, info, "objectForKey:", .{objc.nsString("tab")});
    const nid_n = msg(id, info, "objectForKey:", .{objc.nsString("nid")});
    const origin = msg(id, info, "objectForKey:", .{objc.nsString("origin")});
    const tab: u32 = if (tab_n != null) msg(c_uint, tab_n, "unsignedIntValue", .{}) else 0;
    const nid: u32 = if (nid_n != null) msg(c_uint, nid_n, "unsignedIntValue", .{}) else 0;
    if (on_click) |f| f(tab, nid, if (origin != null) objc.utf8(origin) else "");
}

/// For the selftest: what a click on a posted notification does, without
/// Notification Center.
pub fn simulateClick(tab: u32, nid: u32, origin: []const u8) void {
    if (on_click) |f| f(tab, nid, origin);
}

test "identFor: tagged notifications are the site's, others the tab's" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("tt|https://a.example|tag|chat-1", identFor(&buf, 3, 9, "https://a.example", "chat-1"));
    try std.testing.expectEqualStrings("tt|3|9", identFor(&buf, 3, 9, "https://a.example", ""));
    try std.testing.expectEqualStrings("teams.microsoft.com", siteName("https://teams.microsoft.com"));
    try std.testing.expectEqualStrings("http://localhost:8080", siteName("http://localhost:8080"));
}

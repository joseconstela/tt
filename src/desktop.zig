//! The desktop's services, through AppKit: opening a file in the
//! application the system would use (or one of the user's choosing),
//! showing it in Finder, and the Trash. None of it needs a window, so it
//! works from headless scripts too — the calls just talk to Launch
//! Services and Finder.
const std = @import("std");
const objc = @import("objc.zig");
const sys = @import("sys.zig");

const id = objc.id;
const msg = objc.msg;

/// An application that can open a file: its display name and bundle path.
pub const App = struct { name: []u8, path: []u8 };

fn fileUrl(path: []const u8) id {
    return msg(id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

fn workspace() id {
    return msg(id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
}

fn fileManager() id {
    return msg(id, objc.class("NSFileManager"), "defaultManager", .{});
}

/// Opens `path` with the application the system would use for it (a
/// folder opens in Finder).
pub fn openExternally(path: []const u8) bool {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    return msg(bool, workspace(), "openURL:", .{fileUrl(path)});
}

/// Opens a web address (or a mailto:, ftp: … one) in the application the
/// system uses for it: the default browser for http and https.
pub fn openUrl(url: []const u8) bool {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const u = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)});
    if (u == null) return false;
    return msg(bool, workspace(), "openURL:", .{u});
}

/// The name of the default web browser ("Safari", "Google Chrome"), into
/// `buf`; "" when the system has none.
pub fn defaultBrowserName(buf: []u8) []const u8 {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const probe = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString("https://example.com")});
    const app = msg(id, workspace(), "URLForApplicationToOpenURL:", .{probe});
    if (app == null) return "";
    const path = objc.utf8(msg(id, app, "path", .{}));
    var name = objc.utf8(msg(id, fileManager(), "displayNameAtPath:", .{objc.nsString(path)}));
    if (name.len == 0) name = sys.basename(path);
    if (std.mem.endsWith(u8, name, ".app")) name = name[0 .. name.len - 4];
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

/// Opens `path` with the application bundle at `app`.
pub fn openWith(app: []const u8, path: []const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const urls = msg(id, objc.class("NSArray"), "arrayWithObject:", .{fileUrl(path)});
    const conf = msg(id, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    msg(void, workspace(), "openURLs:withApplicationAtURL:configuration:completionHandler:", .{ urls, fileUrl(app), conf, @as(?*anyopaque, null) });
}

/// Shows `path` selected in a Finder window.
pub fn revealInFinder(path: []const u8) bool {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    return msg(bool, workspace(), "selectFile:inFileViewerRootedAtPath:", .{ objc.nsString(path), objc.nsString("") });
}

/// Moves `path` (a file or a folder with everything in it) to the Trash.
pub fn trash(path: []const u8) !void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    var err: id = null;
    const ok = msg(bool, fileManager(), "trashItemAtURL:resultingItemURL:error:", .{ fileUrl(path), @as(?*id, null), @as(?*id, &err) });
    if (!ok) return error.TrashFailed;
}

/// The applications that can open `path`, the system's default first
/// (marked "(default)"), the rest by name. Free with `freeApps`.
pub fn appsFor(gpa: std.mem.Allocator, path: []const u8) ![]App {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    var out: std.ArrayList(App) = .empty;
    errdefer {
        for (out.items) |a| freeApp(gpa, a);
        out.deinit(gpa);
    }
    const url = fileUrl(path);
    const ws = workspace();
    var default_path: []const u8 = "";
    const default_url = msg(id, ws, "URLForApplicationToOpenURL:", .{url});
    if (default_url != null) default_path = objc.utf8(msg(id, default_url, "path", .{}));
    if (default_path.len > 0) try out.append(gpa, try appAt(gpa, default_path, true));

    const list = msg(id, ws, "URLsForApplicationsToOpenURL:", .{url});
    const n: usize = if (list != null) @intCast(msg(objc.NSUInteger, list, "count", .{})) else 0;
    for (0..n) |i| {
        const u = msg(id, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const p = objc.utf8(msg(id, u, "path", .{}));
        if (p.len == 0 or std.mem.eql(u8, p, default_path)) continue;
        var seen = false;
        for (out.items) |a| {
            if (std.mem.eql(u8, a.path, p)) seen = true;
        }
        if (seen) continue;
        try out.append(gpa, try appAt(gpa, p, false));
    }
    const first: usize = if (default_path.len > 0) 1 else 0;
    if (out.items.len > first) std.mem.sort(App, out.items[first..], {}, appLessThan);
    return out.toOwnedSlice(gpa);
}

fn appAt(gpa: std.mem.Allocator, path: []const u8, is_default: bool) !App {
    // Finder's name for the bundle ("Visual Studio Code", no ".app").
    var display = objc.utf8(msg(id, fileManager(), "displayNameAtPath:", .{objc.nsString(path)}));
    if (display.len == 0) {
        display = sys.basename(path);
        if (std.mem.endsWith(u8, display, ".app")) display = display[0 .. display.len - 4];
    }
    const name = if (is_default) try std.fmt.allocPrint(gpa, "{s} (default)", .{display}) else try gpa.dupe(u8, display);
    errdefer gpa.free(name);
    return .{ .name = name, .path = try gpa.dupe(u8, path) };
}

fn appLessThan(_: void, a: App, b: App) bool {
    const n = @min(a.name.len, b.name.len);
    for (a.name[0..n], b.name[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.name.len < b.name.len;
}

fn freeApp(gpa: std.mem.Allocator, a: App) void {
    gpa.free(a.name);
    gpa.free(a.path);
}

pub fn freeApps(gpa: std.mem.Allocator, apps: []const App) void {
    for (apps) |a| freeApp(gpa, a);
    gpa.free(apps);
}

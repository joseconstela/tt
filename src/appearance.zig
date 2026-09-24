//! Which colour scheme the window should be in: the style the user chose in
//! Settings › Style (tt's dark or light, e-ink, or a terminal theme, whose
//! kind is the scheme), or macOS's own when the style is "system". The system setting is read from the global defaults through
//! CoreFoundation, so it works the same with a window and headless.
//!
//! A display can have a style of its own (Settings › Style › Per screen, kept
//! as `screens:` in the config): the platform layer tells this module which
//! displays are connected and which one the window is on (`setScreens`),
//! and `effectiveMode` is what the window should be in right now. Only tt's
//! window follows; macOS's own appearance is never changed.
const std = @import("std");
const config = @import("config.zig");
const theme = @import("ui/theme.zig");
const themes = @import("ui/themes.zig");

/// The connected displays, by the names macOS gives them (System Settings
/// › Displays), with duplicates told apart by a " (2)" suffix. Empty when
/// nothing is known (headless, before the window exists).
var screens: std.ArrayList([]u8) = .empty;
/// Index into `screens` of the display the window is on.
var current: ?usize = null;

/// Records the connected displays and which one the window sits on. Names
/// are copied; a name given twice (two identical monitors) gets " (2)",
/// " (3)" … so each can be set on its own.
pub fn setScreens(gpa: std.mem.Allocator, names: []const []const u8, on: ?usize) void {
    clearScreens(gpa);
    for (names) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        var owned = gpa.dupe(u8, name) catch continue;
        var n: u32 = 2;
        while (isListed(owned)) : (n += 1) {
            const next = std.fmt.allocPrint(gpa, "{s} ({d})", .{ name, n }) catch break;
            gpa.free(owned);
            owned = next;
        }
        screens.append(gpa, owned) catch gpa.free(owned);
    }
    current = if (on) |i| (if (i < screens.items.len) i else null) else null;
}

fn isListed(name: []const u8) bool {
    for (screens.items) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn clearScreens(gpa: std.mem.Allocator) void {
    for (screens.items) |s| gpa.free(s);
    screens.clearRetainingCapacity();
    current = null;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    clearScreens(gpa);
    screens.deinit(gpa);
}

/// The connected displays' names, in macOS's order (the main one first).
pub fn screenNames() []const []u8 {
    return screens.items;
}

/// Name of the display the window is on, null when unknown.
pub fn currentScreen() ?[]const u8 {
    const i = current orelse return null;
    return screens.items[i];
}

/// The mode the window should be in now: the current display's own
/// setting, else the general one.
pub fn effectiveMode() config.Mode {
    return config.get().modeOn(currentScreen());
}

/// Puts the tokens in the scheme the window should be in now (see
/// `effectiveMode`); true when they changed.
pub fn sync() bool {
    return apply(effectiveMode());
}

const CFStringRef = ?*const anyopaque;
const CFPropertyListRef = ?*const anyopaque;
extern "c" const kCFPreferencesAnyApplication: CFStringRef;
extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, app_id: CFStringRef) CFPropertyListRef;
extern "c" fn CFPreferencesAppSynchronize(app_id: CFStringRef) bool;
extern "c" fn CFStringCreateWithBytes(alloc: ?*const anyopaque, bytes: [*]const u8, len: isize, encoding: u32, external: bool) CFStringRef;
extern "c" fn CFStringCompare(a: CFStringRef, b: CFStringRef, options: usize) isize;
extern "c" fn CFGetTypeID(cf: ?*const anyopaque) usize;
extern "c" fn CFStringGetTypeID() usize;
extern "c" fn CFRelease(cf: ?*const anyopaque) void;

/// True when macOS is in dark mode ("AppleInterfaceStyle" = "Dark" in the
/// global domain; the key is absent in light mode).
pub fn systemIsDark() bool {
    const key = CFStringCreateWithBytes(null, "AppleInterfaceStyle", 19, 0x08000100, false) orelse return true;
    defer CFRelease(key);
    _ = CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    const value = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) orelse return false;
    defer CFRelease(value);
    if (CFGetTypeID(value) != CFStringGetTypeID()) return false;
    const dark = CFStringCreateWithBytes(null, "Dark", 4, 0x08000100, false) orelse return false;
    defer CFRelease(dark);
    return CFStringCompare(value, dark, 1) == 0; // kCFCompareCaseInsensitive
}

/// The scheme a style resolves to right now (a theme's is its kind).
pub fn resolve(mode: config.Mode) theme.Scheme {
    return switch (mode) {
        .dark => .dark,
        .light => .light,
        .eink => .eink,
        .eink_color => .eink_color,
        .system => if (systemIsDark()) .dark else .light,
        .theme => |i| if (themes.all[i].kind == .dark) .dark else .light,
    };
}

/// The terminal theme a style is, if it is one.
pub fn themeOf(mode: config.Mode) ?*const themes.Theme {
    return switch (mode) {
        .theme => |i| &themes.all[i],
        else => null,
    };
}

/// Puts the tokens in the style `mode` resolves to; true when it changed.
pub fn apply(mode: config.Mode) bool {
    const s = resolve(mode);
    const t = themeOf(mode);
    if (s == theme.scheme and t == theme.active_theme) return false;
    theme.setScheme(s, t);
    return true;
}

/// Puts the config's accent into the theme (a named option follows the
/// scheme's tuning; a custom colour is used as written).
pub fn applyAccent(accent: config.Accent) void {
    switch (accent) {
        .named => |i| theme.setAccent(i),
        .custom => |rgb| theme.setCustomAccent(rgb),
    }
}

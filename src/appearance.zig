//! Which colour scheme the window should be in: the one the user chose in
//! Settings › Mode (dark, light or e-ink), or macOS's own when the mode is
//! "system". The system setting is read from the global defaults through
//! CoreFoundation, so it works the same with a window and headless.
const config = @import("config.zig");
const theme = @import("ui/theme.zig");

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

/// The scheme a mode resolves to right now.
pub fn resolve(mode: config.Mode) theme.Scheme {
    return switch (mode) {
        .dark => .dark,
        .light => .light,
        .eink => .eink,
        .system => if (systemIsDark()) .dark else .light,
    };
}

/// Puts the tokens in the scheme `mode` resolves to; true when it changed.
pub fn apply(mode: config.Mode) bool {
    const s = resolve(mode);
    if (s == theme.scheme) return false;
    theme.setScheme(s);
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

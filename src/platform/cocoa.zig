//! macOS shell of the app, written against the Objective-C runtime directly:
//! NSApplication + NSWindow + one CAMetalLayer-backed NSView. The view class
//! is registered at runtime and forwards input to the platform-neutral `App`.
const std = @import("std");
const objc = @import("../objc.zig");
const apple = @import("../apple.zig");
const app_mod = @import("../app.zig");
const events = @import("../events.zig");
const theme = @import("../ui/theme.zig");
const ui_mod = @import("../ui/ui.zig");
const sys = @import("../sys.zig");
const tab_mod = @import("../tabs/tab.zig");
const WebTab = @import("../tabs/web_tab.zig").WebTab;

const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;
const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;
const CGSize = objc.CGSize;
const NSRange = objc.NSRange;

extern "c" const NSRunLoopCommonModes: id;
extern "c" const NSPasteboardTypeString: id;

const mod_shift: NSUInteger = 1 << 17;
const mod_ctrl: NSUInteger = 1 << 18;
const mod_alt: NSUInteger = 1 << 19;
const mod_cmd: NSUInteger = 1 << 20;
const style_fullscreen: NSUInteger = 1 << 14;

const Globals = struct {
    gpa: std.mem.Allocator = undefined,
    opts: app_mod.LaunchOptions = .{},
    app: ?*app_mod.App = null,
    nsapp: id = null,
    window: id = null,
    view: id = null,
    toolbar: id = null,
    view_class: objc.Class = null,
    cursor: ui_mod.Cursor = .arrow,
    /// Ticks left on which the traffic-light inset is re-read: AppKit moves
    /// the buttons a little after the toolbar is put back.
    chrome_recheck: u8 = 0,
    /// The scheme the window's own appearance (titlebar, native panels)
    /// was last matched to.
    applied_scheme: ?theme.Scheme = null,
    debug_events: bool = false,
    selftest: bool = false,
    selftest_step: u32 = 0,
    selftest_fs_phase: u32 = 0,
    selftest_palette_seen: bool = false,
};
var g: Globals = .{};

pub fn run(gpa: std.mem.Allocator, opts: app_mod.LaunchOptions) !void {
    g.gpa = gpa;
    g.opts = opts;
    g.debug_events = sys.getenv("CONCH_DEBUG_EVENTS") != null;
    g.selftest = sys.getenv("CONCH_SELFTEST") != null;

    const pool = objc.AutoreleasePool.push();
    defer pool.pop();

    g.nsapp = msg(id, objc.class("NSApplication"), "sharedApplication", .{});
    msg(void, g.nsapp, "setActivationPolicy:", .{@as(NSInteger, 0)});
    g.view_class = registerViewClass();
    const delegate = msg(id, msg(id, registerDelegateClass(), "alloc", .{}), "init", .{});
    msg(void, g.nsapp, "setDelegate:", .{delegate});
    msg(void, g.nsapp, "run", .{});
}

// ── application delegate ─────────────────────────────────────────────────
fn registerDelegateClass() objc.Class {
    const b = objc.ClassBuilder.begin("ConchAppDelegate", "NSObject");
    b.method("applicationDidFinishLaunching:", didFinishLaunching, "v@:@");
    b.method("applicationShouldTerminateAfterLastWindowClosed:", shouldTerminateAfterLastWindow, "B@:@");
    b.method("applicationShouldTerminate:", shouldTerminate, "Q@:@");
    b.method("applicationWillTerminate:", willTerminate, "v@:@");
    b.method("windowDidBecomeKey:", windowFocusChanged, "v@:@");
    b.method("windowDidResignKey:", windowFocusChanged, "v@:@");
    b.method("windowWillEnterFullScreen:", windowWillEnterFullScreen, "v@:@");
    b.method("windowDidEnterFullScreen:", windowChromeChanged, "v@:@");
    b.method("windowDidExitFullScreen:", windowDidExitFullScreen, "v@:@");
    b.method("windowDidResize:", windowChromeChanged, "v@:@");
    return b.register();
}

fn shouldTerminateAfterLastWindow(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

/// NSTerminateCancel (0) while a tab holds unsaved work, else NSTerminateNow (1).
fn shouldTerminate(_: id, _: SEL, _: id) callconv(.c) NSUInteger {
    if (g.app) |app| {
        if (app.confirmUnsaved()) return 0;
    }
    return 1;
}

fn willTerminate(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| {
        g.app = null;
        app.destroy(); // hangs up the shells
    }
}

fn windowFocusChanged(_: id, _: SEL, _: id) callconv(.c) void {
    const app = g.app orelse return;
    app.chrome.window_focused = msg(bool, g.window, "isKeyWindow", .{});
    app.invalidate();
}

fn windowChromeChanged(_: id, _: SEL, _: id) callconv(.c) void {
    updateChrome();
}

/// In full screen AppKit hosts the toolbar in a window of its own pinned
/// across the top of the screen (NSToolbarFullScreenWindow): an opaque band
/// that would hide the tab strip, and merely hiding the toolbar still leaves
/// a 32pt strip. The toolbar only exists to size the titlebar, so it is
/// detached for the stay and put back once the window is normal again (a
/// toolbar attached while still full screen is never laid out, leaving a
/// standard-height titlebar).
fn windowWillEnterFullScreen(_: id, _: SEL, _: id) callconv(.c) void {
    msg(void, g.window, "setToolbar:", .{@as(id, null)});
}

fn windowDidExitFullScreen(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.toolbar != null) msg(void, g.window, "setToolbar:", .{g.toolbar});
    updateChrome();
    g.chrome_recheck = 60;
}

fn didFinishLaunching(self: id, _: SEL, _: id) callconv(.c) void {
    buildMenu();

    const frame = CGRect.make(0, 0, g.opts.width, g.opts.height);
    const style: NSUInteger = 1 | 2 | 4 | 8 | (1 << 15); // titled, closable, miniaturizable, resizable, fullSizeContentView
    const window = msg(id, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{ frame, style, @as(NSUInteger, 2), false });
    g.window = window;
    msg(void, window, "setReleasedWhenClosed:", .{false});
    msg(void, window, "setTitle:", .{objc.nsString("conch")});
    msg(void, window, "setTitlebarAppearsTransparent:", .{true});
    msg(void, window, "setTitleVisibility:", .{@as(NSInteger, 1)}); // hidden
    msg(void, window, "setTabbingMode:", .{@as(NSInteger, 2)}); // we have our own tabs
    msg(void, window, "setMinSize:", .{CGSize{ .width = 760, .height = 480 }});
    msg(void, window, "setDelegate:", .{self});

    // An empty unified toolbar makes the titlebar 52pt tall — the height of the
    // design's header row — and centres the traffic lights in it.
    const toolbar = msg(id, objc.alloc("NSToolbar"), "initWithIdentifier:", .{objc.nsString("conch.toolbar")});
    msg(void, toolbar, "setShowsBaselineSeparator:", .{false});
    msg(void, window, "setToolbar:", .{toolbar});
    msg(void, window, "setToolbarStyle:", .{@as(NSInteger, 3)}); // unified
    g.toolbar = toolbar;

    const view = msg(id, msg(id, g.view_class, "alloc", .{}), "initWithFrame:", .{frame});
    g.view = view;
    msg(void, view, "setWantsLayer:", .{true});
    const layer = msg(id, view, "layer", .{});

    g.app = app_mod.App.create(g.gpa, g.opts, layer, setClipboard) catch |err| {
        std.debug.print("conch: failed to start: {s}\n", .{@errorName(err)});
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
        return;
    };
    if (g.app) |app| app.env.host = &host_impl;
    // The app has read the settings by now: dress the window to match.
    syncWindowAppearance();

    const tracking = msg(id, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        frame,
        @as(NSUInteger, 0x01 | 0x02 | 0x80 | 0x200), // enter/exit, moved, always active, in visible rect
        view,
        @as(id, null),
    });
    msg(void, view, "addTrackingArea:", .{tracking});

    msg(void, window, "setContentView:", .{view});
    _ = msg(bool, window, "makeFirstResponder:", .{view});
    msg(void, window, "center", .{});
    _ = msg(bool, window, "setFrameAutosaveName:", .{objc.nsString("conch.main")});
    msg(void, window, "makeKeyAndOrderFront:", .{@as(id, null)});
    msg(void, g.nsapp, "activateIgnoringOtherApps:", .{true});
    updateGeometry();

    const timer = msg(id, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{
        @as(f64, 1.0 / 120.0), view, objc.sel("tick:"), @as(id, null), true,
    });
    msg(void, timer, "setTolerance:", .{@as(f64, 0.002)});
    const run_loop = msg(id, objc.class("NSRunLoop"), "currentRunLoop", .{});
    // Common modes keep the app live during window resizes and menu tracking.
    msg(void, run_loop, "addTimer:forMode:", .{ timer, NSRunLoopCommonModes });
}

fn setClipboard(text: []const u8) void {
    const pb = msg(id, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = msg(NSInteger, pb, "clearContents", .{});
    _ = msg(bool, pb, "setString:forType:", .{ objc.nsString(text), NSPasteboardTypeString });
}

// ── menu ─────────────────────────────────────────────────────────────────
fn addItem(menu: id, title: []const u8, action: ?[*:0]const u8, key: []const u8, mods: ?NSUInteger) id {
    const sel: SEL = if (action) |a| objc.sel_registerName(a) else null;
    const item = msg(id, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{ objc.nsString(title), sel, objc.nsString(key) });
    if (mods) |m| msg(void, item, "setKeyEquivalentModifierMask:", .{m});
    msg(void, menu, "addItem:", .{item});
    return item;
}

fn addSeparator(menu: id) void {
    msg(void, menu, "addItem:", .{msg(id, objc.class("NSMenuItem"), "separatorItem", .{})});
}

fn addMenu(bar: id, title: []const u8) id {
    const item = objc.new("NSMenuItem");
    const menu = msg(id, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString(title)});
    msg(void, item, "setSubmenu:", .{menu});
    msg(void, bar, "addItem:", .{item});
    return menu;
}

fn buildMenu() void {
    const bar = objc.new("NSMenu");

    const app_menu = addMenu(bar, "conch");
    _ = addItem(app_menu, "About conch", "orderFrontStandardAboutPanel:", "", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Settings…", "openSettings:", ",", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Hide conch", "hide:", "h", null);
    _ = addItem(app_menu, "Hide Others", "hideOtherApplications:", "h", mod_cmd | mod_alt);
    _ = addItem(app_menu, "Show All", "unhideAllApplications:", "", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Quit conch", "terminate:", "q", null);

    const file_menu = addMenu(bar, "File");
    _ = addItem(file_menu, "Save", "saveDocument:", "s", null);

    const shell = addMenu(bar, "Shell");
    _ = addItem(shell, "New Tab", "newEmptyTab:", "n", null);
    _ = addItem(shell, "New Terminal Tab", "newTab:", "t", null);
    _ = addItem(shell, "New Website Tab", "newWebTab:", "n", mod_cmd | mod_shift);
    _ = addItem(shell, "Close Tab", "closeTab:", "w", null);
    addSeparator(shell);
    _ = addItem(shell, "Add Project Folder…", "addProjectFolder:", "o", mod_cmd | mod_shift);
    addSeparator(shell);
    _ = addItem(shell, "Clear Blocks", "clearBlocks:", "l", mod_ctrl);

    const edit = addMenu(bar, "Edit");
    _ = addItem(edit, "Undo", "undo:", "z", null);
    _ = addItem(edit, "Redo", "redo:", "z", mod_cmd | mod_shift);
    addSeparator(edit);
    _ = addItem(edit, "Cut", "cut:", "x", null);
    _ = addItem(edit, "Copy", "copy:", "c", null);
    _ = addItem(edit, "Paste", "paste:", "v", null);
    _ = addItem(edit, "Select All", "selectAll:", "a", null);

    const view_menu = addMenu(bar, "View");
    _ = addItem(view_menu, "Command Palette…", "commandPalette:", "k", null);
    _ = addItem(view_menu, "Markdown: Preview / Source", "toggleView:", "e", null);
    _ = addItem(view_menu, "Toggle Sidebar", "toggleSidebar:", "b", null);
    _ = addItem(view_menu, "Toggle Files Panel", "toggleFiles:", "e", mod_cmd | mod_shift);
    addSeparator(view_menu);
    _ = addItem(view_menu, "Split Right", "splitRight:", "d", null);
    _ = addItem(view_menu, "Split Down", "splitDown:", "d", mod_cmd | mod_shift);
    _ = addItem(view_menu, "Focus Next Pane", "nextPane:", "]", null);
    _ = addItem(view_menu, "Focus Previous Pane", "prevPane:", "[", null);
    addSeparator(view_menu);
    _ = addItem(view_menu, "Enter Full Screen", "toggleFullScreen:", "f", mod_cmd | mod_ctrl);

    const page = addMenu(bar, "Page");
    _ = addItem(page, "Open Location…", "openLocation:", "l", null);
    _ = addItem(page, "Reload Page", "reloadPage:", "r", null);
    addSeparator(page);
    _ = addItem(page, "Back", "goBack:", "\u{F702}", mod_cmd | mod_alt);
    _ = addItem(page, "Forward", "goForward:", "\u{F703}", mod_cmd | mod_alt);

    const window_menu = addMenu(bar, "Window");
    _ = addItem(window_menu, "Minimize", "performMiniaturize:", "m", null);
    _ = addItem(window_menu, "Zoom", "performZoom:", "", null);
    addSeparator(window_menu);
    _ = addItem(window_menu, "Show Next Tab", "nextTab:", "}", null);
    _ = addItem(window_menu, "Show Previous Tab", "prevTab:", "{", null);

    msg(void, g.nsapp, "setMainMenu:", .{bar});
    msg(void, g.nsapp, "setWindowsMenu:", .{window_menu});
}

// ── the view ─────────────────────────────────────────────────────────────
fn registerViewClass() objc.Class {
    const b = objc.ClassBuilder.begin("ConchView", "NSView");
    b.protocol("NSTextInputClient");

    b.method("makeBackingLayer", makeBackingLayer, "@@:");
    b.method("isFlipped", yes, "B@:");
    b.method("isOpaque", yes, "B@:");
    b.method("acceptsFirstResponder", yes, "B@:");
    b.method("acceptsFirstMouse:", yesWithArg, "B@:@");
    b.method("mouseDownCanMoveWindow", no, "B@:");
    b.method("setFrameSize:", setFrameSize, "v@:{CGSize=dd}");
    b.method("viewDidChangeBackingProperties", viewDidChangeBackingProperties, "v@:");
    b.method("resetCursorRects", resetCursorRects, "v@:");
    b.method("tick:", tick, "v@:@");

    b.method("mouseDown:", mouseDown, "v@:@");
    b.method("mouseUp:", mouseUp, "v@:@");
    b.method("mouseDragged:", mouseMoved, "v@:@");
    b.method("mouseMoved:", mouseMoved, "v@:@");
    b.method("mouseExited:", mouseExited, "v@:@");
    b.method("rightMouseDown:", rightMouseDown, "v@:@");
    b.method("scrollWheel:", scrollWheel, "v@:@");
    b.method("keyDown:", keyDown, "v@:@");
    b.method("performKeyEquivalent:", performKeyEquivalent, "B@:@");

    // Menu actions (found through the responder chain).
    b.method("newTab:", actionNewTab, "v@:@");
    b.method("newEmptyTab:", actionNewEmptyTab, "v@:@");
    b.method("newWebTab:", actionNewWebTab, "v@:@");
    b.method("openLocation:", actionOpenLocation, "v@:@");
    b.method("reloadPage:", actionReloadPage, "v@:@");
    b.method("goBack:", actionGoBack, "v@:@");
    b.method("goForward:", actionGoForward, "v@:@");
    b.method("addProjectFolder:", actionAddProjectFolder, "v@:@");
    b.method("toggleFiles:", actionToggleFiles, "v@:@");
    b.method("closeTab:", actionCloseTab, "v@:@");
    b.method("nextTab:", actionNextTab, "v@:@");
    b.method("prevTab:", actionPrevTab, "v@:@");
    b.method("toggleSidebar:", actionToggleSidebar, "v@:@");
    b.method("commandPalette:", actionCommandPalette, "v@:@");
    b.method("openSettings:", actionOpenSettings, "v@:@");
    b.method("clearBlocks:", actionClear, "v@:@");
    b.method("saveDocument:", actionSave, "v@:@");
    b.method("undo:", actionUndo, "v@:@");
    b.method("redo:", actionRedo, "v@:@");
    b.method("toggleView:", actionToggleView, "v@:@");
    b.method("splitRight:", actionSplitRight, "v@:@");
    b.method("splitDown:", actionSplitDown, "v@:@");
    b.method("nextPane:", actionNextPane, "v@:@");
    b.method("prevPane:", actionPrevPane, "v@:@");
    b.method("copy:", actionCopy, "v@:@");
    b.method("cut:", actionCut, "v@:@");
    b.method("paste:", actionPaste, "v@:@");
    b.method("selectAll:", actionSelectAll, "v@:@");

    // NSTextInputClient — gives us dead keys, IME and the user's key bindings.
    b.method("insertText:replacementRange:", insertText, "v@:@{_NSRange=QQ}");
    b.method("doCommandBySelector:", doCommandBySelector, "v@::");
    b.method("setMarkedText:selectedRange:replacementRange:", setMarkedText, "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    b.method("unmarkText", unmarkText, "v@:");
    b.method("selectedRange", selectedRange, "{_NSRange=QQ}@:");
    b.method("markedRange", markedRange, "{_NSRange=QQ}@:");
    b.method("hasMarkedText", hasMarkedText, "B@:");
    b.method("attributedSubstringForProposedRange:actualRange:", attributedSubstring, "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    b.method("validAttributesForMarkedText", validAttributes, "@@:");
    b.method("firstRectForCharacterRange:actualRange:", firstRect, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    b.method("characterIndexForPoint:", characterIndex, "Q@:{CGPoint=dd}");
    return b.register();
}

fn yes(_: id, _: SEL) callconv(.c) bool {
    return true;
}
fn no(_: id, _: SEL) callconv(.c) bool {
    return false;
}
fn yesWithArg(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

fn makeBackingLayer(_: id, _: SEL) callconv(.c) id {
    return msg(id, objc.class("CAMetalLayer"), "layer", .{});
}

fn setFrameSize(self: id, _: SEL, size: CGSize) callconv(.c) void {
    objc.msgSuper(void, self, objc.class("NSView"), "setFrameSize:", .{size});
    updateGeometry();
    // Draw right away so live resizing never shows a stretched frame.
    if (g.app) |app| {
        _ = app.update(apple.CACurrentMediaTime());
        app.buildFrame();
        hostSync();
        app.present();
    }
}

fn viewDidChangeBackingProperties(self: id, _: SEL) callconv(.c) void {
    objc.msgSuper(void, self, objc.class("NSView"), "viewDidChangeBackingProperties", .{});
    updateGeometry();
}

fn updateGeometry() void {
    const app = g.app orelse return;
    if (g.view == null or g.window == null) return;
    const bounds = msg(CGRect, g.view, "bounds", .{});
    var scale = msg(f64, g.window, "backingScaleFactor", .{});
    if (scale <= 0) scale = 2;
    app.resize(@floatCast(bounds.size.width), @floatCast(bounds.size.height), @floatCast(scale));
    app.renderer.setDrawableSize(@round(bounds.size.width * scale), @round(bounds.size.height * scale), scale);
    updateChrome();
}

fn isFullScreen() bool {
    return msg(NSUInteger, g.window, "styleMask", .{}) & style_fullscreen != 0;
}

/// Where the traffic lights end, so the header can flow around them.
fn updateChrome() void {
    const app = g.app orelse return;
    var inset: f32 = 0;
    if (!isFullScreen()) {
        const zoom = msg(id, g.window, "standardWindowButton:", .{@as(NSUInteger, 2)});
        if (zoom != null) {
            const b = msg(CGRect, zoom, "bounds", .{});
            const in_window = msg(CGRect, zoom, "convertRect:toView:", .{ b, @as(id, null) });
            inset = @floatCast(in_window.origin.x + in_window.size.width);
        }
    }
    if (inset != app.chrome.inset_left) {
        app.chrome.inset_left = inset;
        app.invalidate();
    }
}

/// The window's appearance (titlebar, traffic lights, native panels) and
/// background follow the theme's scheme.
fn syncWindowAppearance() void {
    if (g.window == null) return;
    const name = switch (theme.scheme) {
        .dark => "NSAppearanceNameDarkAqua",
        .light, .eink => "NSAppearanceNameAqua",
    };
    const appearance = msg(id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString(name)});
    msg(void, g.window, "setAppearance:", .{appearance});
    const bg = msg(id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, theme.bg.r), @as(f64, theme.bg.g), @as(f64, theme.bg.b), @as(f64, 1),
    });
    msg(void, g.window, "setBackgroundColor:", .{bg});
    g.applied_scheme = theme.scheme;
    if (g.app) |app| app.invalidate();
}

fn tick(_: id, _: SEL, _: id) callconv(.c) void {
    const app = g.app orelse return;
    const now = apple.CACurrentMediaTime();
    if (g.chrome_recheck > 0) {
        g.chrome_recheck -= 1;
        updateChrome();
    }
    if (g.selftest) selftestStep(now);
    if (g.applied_scheme != theme.scheme) syncWindowAppearance();
    // Runs between frames: the picker's modal loop keeps ticking this timer.
    if (app.folder_pick_requested) {
        app.folder_pick_requested = false;
        pickProjectFolder();
    }
    if (!app.update(now)) return;
    // nextDrawable blocks when the window is not on screen; skip drawing then.
    const occlusion = msg(NSUInteger, g.window, "occlusionState", .{});
    if (occlusion & (1 << 1) == 0) return;
    app.buildFrame();
    hostSync();
    app.present();
    syncCursor();
}

// ── native views hosted over the Metal layer (website tabs) ──────────────
// A tab attaches its view once and places it on every frame it draws; after
// the frame the views placed are shown where they were put, the rest are
// hidden — all of them while the palette or a box covers the window, since
// a native view would sit on top of the dimming and the panel.
const Hosted = struct { view: id, frame: CGRect = .{}, placed: bool = false, shown: bool = false };
var hosted: std.ArrayList(Hosted) = .empty;

fn hostAttach(view: *anyopaque) void {
    const v: id = view;
    msg(void, v, "setHidden:", .{true});
    msg(void, g.view, "addSubview:", .{v});
    hosted.append(g.gpa, .{ .view = v }) catch {};
}

fn hostPlace(view: *anyopaque, rect: ui_mod.Rect) void {
    const v: id = view;
    for (hosted.items) |*h| {
        if (h.view != v) continue;
        h.frame = CGRect.make(rect.x, rect.y, rect.w, rect.h);
        h.placed = true;
    }
}

fn hostDetach(view: *anyopaque) void {
    const v: id = view;
    msg(void, v, "removeFromSuperview", .{});
    var i: usize = 0;
    while (i < hosted.items.len) {
        if (hosted.items[i].view == v) {
            _ = hosted.orderedRemove(i);
        } else i += 1;
    }
    if (g.window != null) msg(void, g.window, "invalidateCursorRectsForView:", .{g.view});
}

fn hostHasFocus(view: *anyopaque) bool {
    const v: id = view;
    if (g.window == null) return false;
    const fr = msg(id, g.window, "firstResponder", .{});
    if (fr == null) return false;
    if (!msg(bool, fr, "isKindOfClass:", .{objc.class("NSView")})) return false;
    return msg(bool, fr, "isDescendantOf:", .{v});
}

/// True while the keyboard is in one of the hosted views.
fn hostedHasKeyboard() bool {
    for (hosted.items) |h| {
        if (h.shown and hostHasFocus(h.view.?)) return true;
    }
    return false;
}

fn hostFocusView(view: *anyopaque) void {
    const v: id = view;
    if (g.window != null) _ = msg(bool, g.window, "makeFirstResponder:", .{v});
}

fn hostFocusApp() void {
    if (g.window != null) _ = msg(bool, g.window, "makeFirstResponder:", .{g.view});
}

const host_impl: tab_mod.Host = .{
    .attach = hostAttach,
    .place = hostPlace,
    .detach = hostDetach,
    .hasFocus = hostHasFocus,
    .focusView = hostFocusView,
    .focusApp = hostFocusApp,
};

fn rectEql(a: CGRect, b: CGRect) bool {
    return a.origin.x == b.origin.x and a.origin.y == b.origin.y and a.size.width == b.size.width and a.size.height == b.size.height;
}

/// After a frame: the views it placed go where it put them, the others hide.
fn hostSync() void {
    const app = g.app orelse return;
    const covered = app.palette.open or app.overlay.isOpen();
    // What covers the window (the palette, a box) is typed into through the
    // app's own view: take the keyboard back from the page.
    if (covered and hostedHasKeyboard()) hostFocusApp();
    var changed = false;
    for (hosted.items) |*h| {
        const show = h.placed and !covered;
        if (show and !rectEql(msg(CGRect, h.view, "frame", .{}), h.frame)) {
            msg(void, h.view, "setFrame:", .{h.frame});
            changed = true;
        }
        if (show != h.shown) {
            msg(void, h.view, "setHidden:", .{!show});
            h.shown = show;
            changed = true;
        }
        h.placed = false;
    }
    // The cursor rects leave the hosted views' frames out (they set their own).
    if (changed and g.window != null) msg(void, g.window, "invalidateCursorRectsForView:", .{g.view});
}

/// `rects[0..n]` minus `cut`, as up to four pieces per rect; the new count.
fn subtractRect(rects: *[32]CGRect, n: usize, cut: CGRect) usize {
    var out: [32]CGRect = undefined;
    var m: usize = 0;
    const cx0 = cut.origin.x;
    const cy0 = cut.origin.y;
    const cx1 = cx0 + cut.size.width;
    const cy1 = cy0 + cut.size.height;
    for (rects[0..n]) |r| {
        const rx0 = r.origin.x;
        const ry0 = r.origin.y;
        const rx1 = rx0 + r.size.width;
        const ry1 = ry0 + r.size.height;
        const pieces = [_]CGRect{
            if (cx1 <= rx0 or cx0 >= rx1 or cy1 <= ry0 or cy0 >= ry1) r else .{},
            if (cy0 > ry0 and cy0 < ry1 and cx0 < rx1 and cx1 > rx0) CGRect.make(rx0, ry0, rx1 - rx0, cy0 - ry0) else .{},
            if (cy1 < ry1 and cy1 > ry0 and cx0 < rx1 and cx1 > rx0) CGRect.make(rx0, cy1, rx1 - rx0, ry1 - cy1) else .{},
            if (cx0 > rx0 and cx0 < rx1 and cy0 < ry1 and cy1 > ry0) CGRect.make(rx0, @max(ry0, cy0), cx0 - rx0, @min(ry1, cy1) - @max(ry0, cy0)) else .{},
            if (cx1 < rx1 and cx1 > rx0 and cy0 < ry1 and cy1 > ry0) CGRect.make(cx1, @max(ry0, cy0), rx1 - cx1, @min(ry1, cy1) - @max(ry0, cy0)) else .{},
        };
        for (pieces) |p| {
            if (p.size.width <= 0 or p.size.height <= 0) continue;
            if (m < out.len) {
                out[m] = p;
                m += 1;
            }
        }
    }
    @memcpy(rects[0..m], out[0..m]);
    return m;
}

// ── cursor ───────────────────────────────────────────────────────────────
fn nsCursor(c: ui_mod.Cursor) id {
    const cls = objc.class("NSCursor");
    return switch (c) {
        .arrow => msg(id, cls, "arrowCursor", .{}),
        .ibeam => msg(id, cls, "IBeamCursor", .{}),
        .pointer => msg(id, cls, "pointingHandCursor", .{}),
        .resize_lr => msg(id, cls, "resizeLeftRightCursor", .{}),
        .resize_ud => msg(id, cls, "resizeUpDownCursor", .{}),
    };
}

fn syncCursor() void {
    const app = g.app orelse return;
    if (app.ui.cursor == g.cursor) return;
    g.cursor = app.ui.cursor;
    msg(void, g.window, "invalidateCursorRectsForView:", .{g.view});
    msg(void, nsCursor(g.cursor), "set", .{});
}

fn resetCursorRects(self: id, _: SEL) callconv(.c) void {
    const bounds = msg(CGRect, self, "bounds", .{});
    var rects: [32]CGRect = undefined;
    rects[0] = bounds;
    var n: usize = 1;
    for (hosted.items) |h| {
        if (h.shown) n = subtractRect(&rects, n, h.frame);
    }
    for (rects[0..n]) |r| msg(void, self, "addCursorRect:cursor:", .{ r, nsCursor(g.cursor) });
}

// ── mouse ────────────────────────────────────────────────────────────────
fn eventPoint(event: id) CGPoint {
    const p = msg(CGPoint, event, "locationInWindow", .{});
    return msg(CGPoint, g.view, "convertPoint:fromView:", .{ p, @as(id, null) });
}

fn eventMods(event: id) ui_mod.Mods {
    const flags = msg(NSUInteger, event, "modifierFlags", .{});
    return .{
        .shift = flags & mod_shift != 0,
        .ctrl = flags & mod_ctrl != 0,
        .alt = flags & mod_alt != 0,
        .cmd = flags & mod_cmd != 0,
    };
}

fn mouseDown(_: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const p = eventPoint(event);
    const x: f32 = @floatCast(p.x);
    const y: f32 = @floatCast(p.y);
    const clicks: u32 = @intCast(@max(1, msg(NSInteger, event, "clickCount", .{})));
    const interactive = app.isInteractiveAt(x, y);
    if (g.debug_events) std.debug.print("mouseDown {d:.0},{d:.0} clicks={d} interactive={}\n", .{ x, y, clicks, interactive });

    // Empty parts of the header behave like a titlebar (not in full screen:
    // nothing to drag or zoom there).
    if (y < theme.header_h and !interactive and !isFullScreen()) {
        if (clicks == 2) {
            msg(void, g.window, "performZoom:", .{@as(id, null)});
        } else msg(void, g.window, "performWindowDragWithEvent:", .{event});
        return;
    }
    app.onMouseDown(x, y, clicks, eventMods(event));
}

fn mouseUp(_: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const p = eventPoint(event);
    if (g.debug_events) std.debug.print("mouseUp {d:.0},{d:.0}\n", .{ p.x, p.y });
    app.onMouseUp(@floatCast(p.x), @floatCast(p.y));
}

/// Secondary click: context menus. Never a window drag, even in the titlebar band.
fn rightMouseDown(_: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const p = eventPoint(event);
    if (g.debug_events) std.debug.print("rightMouseDown {d:.0},{d:.0}\n", .{ p.x, p.y });
    app.onRightMouseDown(@floatCast(p.x), @floatCast(p.y), eventMods(event));
}

fn mouseMoved(_: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const p = eventPoint(event);
    app.onMouseMove(@floatCast(p.x), @floatCast(p.y));
}

fn mouseExited(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.onMouseLeave();
}

fn scrollWheel(_: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const p = eventPoint(event);
    var dx = msg(f64, event, "scrollingDeltaX", .{});
    var dy = msg(f64, event, "scrollingDeltaY", .{});
    if (!msg(bool, event, "hasPreciseScrollingDeltas", .{})) {
        dx *= 16;
        dy *= 16;
    }
    app.onScroll(@floatCast(p.x), @floatCast(p.y), @floatCast(dx), @floatCast(dy));
}

// ── keyboard ─────────────────────────────────────────────────────────────
fn keyDown(self: id, _: SEL, event: id) callconv(.c) void {
    const app = g.app orelse return;
    const mods = eventMods(event);
    app.ui.mods = mods;
    if (mods.ctrl and !mods.cmd) {
        // Control chords are terminal business (^C, ^D, ^L …), not text input.
        const chars = objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{}));
        if (chars.len == 1) {
            const c = std.ascii.toLower(chars[0]);
            if (g.debug_events) std.debug.print("ctrl+{c}\n", .{c});
            if ((c >= 'a' and c <= 'z') or c == '\\' or c == '\t') {
                app.onCtrl(c);
                return;
            }
            if (c == 0x19) { // ⌃⇧Tab arrives as a back-tab character
                app.onCtrl('\t');
                return;
            }
        }
    }
    const list = msg(id, objc.class("NSArray"), "arrayWithObject:", .{event});
    msg(void, self, "interpretKeyEvents:", .{list});
}

fn performKeyEquivalent(self: id, _: SEL, event: id) callconv(.c) bool {
    const app = g.app orelse return false;
    const mods = eventMods(event);
    if (g.debug_events) std.debug.print("performKeyEquivalent '{s}' cmd={}\n", .{ objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{})), mods.cmd });
    if (mods.cmd and !mods.ctrl and !mods.alt) {
        const chars = objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{}));
        if (chars.len == 1 and chars[0] >= '1' and chars[0] <= '9') {
            app.selectTab(chars[0] - '1');
            return true;
        }
    }
    return objc.msgSuper(bool, self, objc.class("NSView"), "performKeyEquivalent:", .{event});
}

fn insertText(_: id, _: SEL, text: id, _: NSRange) callconv(.c) void {
    const app = g.app orelse return;
    var str = text;
    if (msg(bool, text, "isKindOfClass:", .{objc.class("NSAttributedString")})) str = msg(id, text, "string", .{});
    const s = objc.utf8(str);
    if (g.debug_events) std.debug.print("insertText '{s}'\n", .{s});
    app.onMarkedText("");
    // Keys like ⌥-arrows can arrive as private-use function characters; drop them.
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0xF700 and cp <= 0xF8FF) return;
        if (cp < 0x20 and cp != '\n' and cp != '\t') return;
    }
    app.onText(s);
}

fn doCommandBySelector(_: id, _: SEL, sel: SEL) callconv(.c) void {
    const app = g.app orelse return;
    const name = std.mem.span(objc.sel_getName(sel));
    if (g.debug_events) std.debug.print("doCommand {s}\n", .{name});
    var cmd = events.commandForSelector(name) orelse return;
    if (cmd == .insert_newline) {
        const current = msg(id, g.nsapp, "currentEvent", .{});
        if (current != null and eventMods(current).shift) cmd = .insert_line_break;
    }
    app.onEdit(cmd);
}

fn setMarkedText(_: id, _: SEL, text: id, _: NSRange, _: NSRange) callconv(.c) void {
    const app = g.app orelse return;
    var str = text;
    if (msg(bool, text, "isKindOfClass:", .{objc.class("NSAttributedString")})) str = msg(id, text, "string", .{});
    app.onMarkedText(objc.utf8(str));
}

fn unmarkText(_: id, _: SEL) callconv(.c) void {
    if (g.app) |app| app.onMarkedText("");
}

fn selectedRange(_: id, _: SEL) callconv(.c) NSRange {
    return .{ .location = 0, .length = 0 };
}

fn markedRange(_: id, _: SEL) callconv(.c) NSRange {
    if (g.app) |app| {
        if (app.hasMarkedText()) return .{ .location = 0, .length = 1 };
    }
    return .{ .location = objc.NSNotFound, .length = 0 };
}

fn hasMarkedText(_: id, _: SEL) callconv(.c) bool {
    if (g.app) |app| return app.hasMarkedText();
    return false;
}

fn attributedSubstring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) id {
    return null;
}

fn validAttributes(_: id, _: SEL) callconv(.c) id {
    return msg(id, objc.class("NSArray"), "array", .{});
}

fn firstRect(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) CGRect {
    const app = g.app orelse return .{};
    const c = app.caretRect();
    const in_view = CGRect.make(c.x, c.y, c.w, c.h);
    const in_window = msg(CGRect, g.view, "convertRect:toView:", .{ in_view, @as(id, null) });
    return msg(CGRect, g.window, "convertRectToScreen:", .{in_window});
}

fn characterIndex(_: id, _: SEL, _: CGPoint) callconv(.c) NSUInteger {
    return objc.NSNotFound;
}

// ── menu actions ─────────────────────────────────────────────────────────
fn actionNewTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.new_tab);
}
fn actionNewEmptyTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.new_empty_tab);
}
fn actionNewWebTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.new_web_tab);
}
fn actionOpenLocation(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.open_location);
}
fn actionReloadPage(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.web_reload);
}
fn actionGoBack(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.web_back);
}
fn actionGoForward(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.web_forward);
}
fn actionAddProjectFolder(_: id, _: SEL, _: id) callconv(.c) void {
    pickProjectFolder();
}
fn actionToggleFiles(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.toggle_files);
}

/// Native folder picker → a new project.
fn pickProjectFolder() void {
    if (g.app == null) return;
    const panel = msg(id, objc.class("NSOpenPanel"), "openPanel", .{});
    msg(void, panel, "setCanChooseDirectories:", .{true});
    msg(void, panel, "setCanChooseFiles:", .{false});
    msg(void, panel, "setAllowsMultipleSelection:", .{false});
    msg(void, panel, "setCanCreateDirectories:", .{true});
    msg(void, panel, "setMessage:", .{objc.nsString("Choose a folder to add as a project")});
    msg(void, panel, "setPrompt:", .{objc.nsString("Add Project")});
    const response = msg(NSInteger, panel, "runModal", .{});
    if (response != 1) return; // NSModalResponseOK
    const url = msg(id, panel, "URL", .{});
    if (url == null) return;
    const path = objc.utf8(msg(id, url, "path", .{}));
    if (g.app) |app| app.addProject(path);
}
fn actionCloseTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.close_tab);
}
fn actionNextTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.next_tab);
}
fn actionPrevTab(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.prev_tab);
}
fn actionToggleSidebar(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.toggle_sidebar);
}
fn actionCommandPalette(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.command_palette);
}
fn actionOpenSettings(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.open_settings);
}
fn actionClear(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.clear);
}
fn actionSave(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.save);
}
fn actionUndo(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.undo);
}
fn actionRedo(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.redo);
}
fn actionToggleView(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.toggle_view);
}
fn actionSplitRight(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.split_right);
}
fn actionSplitDown(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.split_down);
}
fn actionNextPane(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.next_pane);
}
fn actionPrevPane(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.prev_pane);
}
fn actionSelectAll(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.onEdit(.select_all);
}

fn copyOrCut(cut: bool) void {
    const app = g.app orelse return;
    const text = app.onCopy(cut) orelse return;
    defer g.gpa.free(text);
    setClipboard(text);
}
fn actionCopy(_: id, _: SEL, _: id) callconv(.c) void {
    copyOrCut(false);
}
fn actionCut(_: id, _: SEL, _: id) callconv(.c) void {
    copyOrCut(true);
}
fn actionPaste(_: id, _: SEL, _: id) callconv(.c) void {
    const app = g.app orelse return;
    const pb = msg(id, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const str = msg(id, pb, "stringForType:", .{NSPasteboardTypeString});
    if (str != null) app.onPaste(objc.utf8(str));
}

// ── self test (CONCH_SELFTEST=1) ─────────────────────────────────────────
// Posts real NSEvents through the window so the AppKit plumbing (hit testing
// under the transparent titlebar, first responder, key routing) is exercised.
var selftest_t0: f64 = 0;

fn postMouse(kind: NSUInteger, x: f64, y_from_top: f64) void {
    const bounds = msg(CGRect, g.view, "bounds", .{});
    const in_view = CGPoint{ .x = x, .y = y_from_top };
    const in_window = msg(CGPoint, g.view, "convertPoint:toView:", .{ in_view, @as(id, null) });
    _ = bounds;
    const ev = msg(id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
        kind,
        in_window,
        @as(NSUInteger, 0),
        apple.CACurrentMediaTime(),
        msg(NSInteger, g.window, "windowNumber", .{}),
        @as(id, null),
        @as(NSInteger, 0),
        @as(NSInteger, 1),
        @as(f32, 1.0),
    });
    msg(void, g.nsapp, "postEvent:atStart:", .{ ev, false });
}

fn postKey(ch: u8) void {
    postKeyWithMods(ch, 0);
}

fn postKeyWithMods(ch: u8, flags: NSUInteger) void {
    const s = objc.nsString(&[_]u8{ch});
    const ev = msg(id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(NSUInteger, 10), // key down
        CGPoint{},
        flags,
        apple.CACurrentMediaTime(),
        msg(NSInteger, g.window, "windowNumber", .{}),
        @as(id, null),
        s,
        s,
        false,
        @as(c_ushort, if (ch == '\r') 36 else 0),
    });
    msg(void, g.nsapp, "postEvent:atStart:", .{ ev, false });
}

fn selftestStep(now: f64) void {
    const app = g.app orelse return;
    if (selftest_t0 == 0) {
        selftest_t0 = now;
        std.debug.print("selftest: windowNumber={d}\n", .{msg(NSInteger, g.window, "windowNumber", .{})});
    }
    const t = now - selftest_t0;
    if (app.palette.open) g.selftest_palette_seen = true;
    const Step = struct { at: f64, x: f64 = 0, y: f64 = 0, keys: []const u8 = "", cmd_key: u8 = 0, what: []const u8 };
    // Collapse button and the "+" of the tab strip (both in the titlebar
    // band), ⌘K as a real key equivalent through the menu, then key events
    // through interpretKeyEvents / NSTextInputClient (Escape closes the
    // palette via cancelOperation:).
    const steps = [_]Step{
        .{ .at = 1.5, .x = 272, .y = 26, .what = "collapse sidebar (titlebar band)" },
        .{ .at = 2.0, .x = 30, .y = 82, .what = "expand sidebar (rail)" },
        .{ .at = 2.5, .x = 416, .y = 26, .what = "new tab (+ in the tab strip, titlebar band)" },
        .{ .at = 3.0, .cmd_key = 'k', .what = "open palette (⌘K menu key equivalent)" },
        .{ .at = 3.4, .keys = "\x1b", .what = "Escape closes the palette" },
        .{ .at = 3.8, .keys = "echo selftest-ok\r", .what = "type a command + Return" },
    };
    if (g.selftest_step < steps.len) {
        const s = steps[g.selftest_step];
        if (t >= s.at) {
            std.debug.print("selftest: {s}\n", .{s.what});
            if (s.cmd_key != 0) {
                postKeyWithMods(s.cmd_key, mod_cmd);
            } else if (s.keys.len > 0) {
                for (s.keys) |ch| postKey(ch);
            } else {
                postMouse(1, s.x, s.y);
                postMouse(2, s.x, s.y);
            }
            g.selftest_step += 1;
        }
    } else if (sys.getenv("CONCH_SELFTEST_URL")) |url| {
        selftestWeb(t, url);
    } else if (sys.getenv("CONCH_SELFTEST_FULLSCREEN") != null) {
        selftestFullScreen(t);
    } else if (t >= 5.5) {
        std.debug.print("selftest: sidebar collapsed={} tabs={d} palette_opened={} palette_open={} inset_left={d:.0} focused={}\n", .{
            app.sidebar.collapsed, app.tabs.count(), g.selftest_palette_seen, app.palette.open, app.chrome.inset_left, app.chrome.window_focused,
        });
        if (sys.getenv("CONCH_SELFTEST_SNAP")) |path| app.snapshot(path) catch {};
        if (sys.getenv("CONCH_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        selftestReportButtons();
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

/// CONCH_SELFTEST_URL=https://…: after the regular steps, a website tab on
/// that address; the page gets a few seconds, the palette is opened over it
/// (the hosted view must hide under the scrim; CONCH_SELFTEST_WINDOW_PNG
/// gets a "-palette" capture) and closed again, then the window is captured
/// with the page and the hosted view's state is printed.
var selftest_web_step: u8 = 0;

fn selftestWeb(t: f64, url: []const u8) void {
    const app = g.app orelse return;
    if (selftest_web_step == 0) {
        selftest_web_step = 1;
        if (std.mem.eql(u8, url, "restored")) {
            // The tab the workspace brought back (CONCH_WORKSPACE names the
            // file): find it in the pane on show, say what it holds, show it.
            var found = false;
            for (app.tabs.items(), 0..) |tab, i| {
                const w = WebTab.fromTab(tab) orelse continue;
                std.debug.print("selftest: restored website tab url='{s}' view={} error={s}\n", .{ w.url.items, w.view != null, w.error_text orelse "none" });
                app.tabs.activate(i);
                found = true;
                break;
            }
            if (!found) std.debug.print("selftest: no restored website tab in the pane on show\n", .{});
        } else {
            std.debug.print("selftest: website tab {s}\n", .{url});
            _ = app.tabs.openWith("web", .{ .url = url }) catch |err| {
                std.debug.print("selftest: could not open a website tab: {s}\n", .{@errorName(err)});
            };
        }
        app.invalidate();
    } else if (selftest_web_step == 1 and t >= 8.5) {
        selftest_web_step = 2;
        const fr = msg(id, g.window, "firstResponder", .{});
        const fr_class = if (fr != null) objc.utf8(msg(id, msg(id, fr, "class", .{}), "description", .{})) else "(none)";
        std.debug.print("selftest: ⌘K over the page (key_window={} app_active={} first_responder={s})\n", .{
            msg(bool, g.window, "isKeyWindow", .{}), msg(bool, g.nsapp, "isActive", .{}), fr_class,
        });
        postKeyWithMods('k', mod_cmd);
    } else if (selftest_web_step == 2 and t >= 9.5) {
        selftest_web_step = 3;
        const fr = msg(id, g.window, "firstResponder", .{});
        const fr_class = if (fr != null) objc.utf8(msg(id, msg(id, fr, "class", .{}), "description", .{})) else "(none)";
        for (hosted.items) |h| {
            std.debug.print("selftest: palette_open={} palette_seen={} hosted view hidden={} first_responder={s}\n", .{ app.palette.open, g.selftest_palette_seen, msg(bool, h.view, "isHidden", .{}), fr_class });
        }
        if (sys.getenv("CONCH_SELFTEST_WINDOW_PNG")) |path| {
            var buf: [1024]u8 = undefined;
            const stem = if (std.mem.endsWith(u8, path, ".png")) path[0 .. path.len - 4] else path;
            if (std.fmt.bufPrint(&buf, "{s}-palette.png", .{stem})) |p| captureOwnWindow(p, 1 << 3) else |_| {}
        }
        postKey(0x1b);
    } else if (selftest_web_step == 3 and t >= 11) {
        var buf: [96]u8 = undefined;
        const title = if (app.tabs.current()) |c| c.title(&buf) else "(none)";
        std.debug.print("selftest: web title='{s}' hosted={d}\n", .{ title, hosted.items.len });
        for (hosted.items) |h| {
            const f = msg(CGRect, h.view, "frame", .{});
            const hidden = msg(bool, h.view, "isHidden", .{});
            std.debug.print("selftest: hosted view shown={} hidden={} frame=({d:.0},{d:.0} {d:.0}x{d:.0}) loading={}\n", .{
                h.shown, hidden, f.origin.x, f.origin.y, f.size.width, f.size.height, msg(bool, h.view, "isLoading", .{}),
            });
        }
        if (sys.getenv("CONCH_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

fn selftestReportButtons() void {
    for ([_]NSUInteger{ 0, 1, 2 }) |which| {
        const btn = msg(id, g.window, "standardWindowButton:", .{which});
        if (btn == null) continue;
        const r = msg(CGRect, btn, "convertRect:toView:", .{ msg(CGRect, btn, "bounds", .{}), @as(id, null) });
        const wf = msg(CGRect, g.window, "frame", .{});
        std.debug.print("selftest: button {d}: x={d:.1} w={d:.1} top={d:.1} h={d:.1}\n", .{ which, r.origin.x, r.size.width, wf.size.height - (r.origin.y + r.size.height), r.size.height });
    }
}

/// CONCH_SELFTEST_FULLSCREEN=1: after the regular steps, a round trip through
/// full screen. While there, every window of the process is listed (the
/// toolbar must not show up as its own window over the tab strip) and the
/// view is captured at screen size.
fn selftestFullScreen(t: f64) void {
    const app = g.app orelse return;
    const Phase = struct { at: f64, what: []const u8 };
    const phases = [_]Phase{
        .{ .at = 5.5, .what = "enter full screen" },
        .{ .at = 8.0, .what = "report + capture in full screen" },
        .{ .at = 8.5, .what = "exit full screen" },
        .{ .at = 11.0, .what = "report after full screen" },
    };
    if (g.selftest_fs_phase >= phases.len) return;
    const p = phases[g.selftest_fs_phase];
    if (t < p.at) return;
    std.debug.print("selftest: {s}\n", .{p.what});
    switch (g.selftest_fs_phase) {
        0, 2 => msg(void, g.window, "toggleFullScreen:", .{@as(id, null)}),
        1 => {
            selftestReportWindows();
            if (sys.getenv("CONCH_SELFTEST_SNAP")) |path| app.snapshot(path) catch {};
            // Anything AppKit layers above the view (a toolbar window) must
            // show in the picture, so windows above ours are included.
            if (sys.getenv("CONCH_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, (1 << 3) | (1 << 1));
        },
        else => {
            selftestReportWindows();
            selftestReportButtons();
            msg(void, g.nsapp, "terminate:", .{@as(id, null)});
        },
    }
    g.selftest_fs_phase += 1;
}

fn selftestReportWindows() void {
    const app = g.app orelse return;
    const bounds = msg(CGRect, g.view, "bounds", .{});
    std.debug.print("selftest: fullscreen={} toolbar_attached={} view={d:.0}x{d:.0} inset_left={d:.0} tabs={d}\n", .{
        isFullScreen(), msg(id, g.window, "toolbar", .{}) != null, bounds.size.width, bounds.size.height, app.chrome.inset_left, app.tabs.count(),
    });
    const windows = msg(id, g.nsapp, "windows", .{});
    const n = msg(NSUInteger, windows, "count", .{});
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) {
        const w = msg(id, windows, "objectAtIndex:", .{i});
        const f = msg(CGRect, w, "frame", .{});
        std.debug.print("selftest:   window {s} visible={} frame={d:.0},{d:.0} {d:.0}x{d:.0}\n", .{
            objc.utf8(msg(id, w, "className", .{})), msg(bool, w, "isVisible", .{}), f.origin.x, f.origin.y, f.size.width, f.size.height,
        });
    }
    const children = msg(id, g.window, "childWindows", .{});
    if (children != null) {
        const nc = msg(NSUInteger, children, "count", .{});
        var j: NSUInteger = 0;
        while (j < nc) : (j += 1) {
            const w = msg(id, children, "objectAtIndex:", .{j});
            const f = msg(CGRect, w, "frame", .{});
            std.debug.print("selftest:   child {s} visible={} frame={d:.0},{d:.0} {d:.0}x{d:.0}\n", .{
                objc.utf8(msg(id, w, "className", .{})), msg(bool, w, "isVisible", .{}), f.origin.x, f.origin.y, f.size.width, f.size.height,
            });
        }
    }
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// A process may capture its own windows without the Screen Recording
/// permission. The API is resolved at runtime because newer SDKs hide it.
/// `list_options` are CGWindowListOption bits (1 << 3 = just our window,
/// | 1 << 1 also the windows on screen above it).
fn captureOwnWindow(path: []const u8, list_options: u32) void {
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const sym = dlsym(rtld_default, "CGWindowListCreateImage") orelse {
        std.debug.print("selftest: CGWindowListCreateImage unavailable\n", .{});
        return;
    };
    const Fn = *const fn (CGRect, u32, u32, u32) callconv(.c) apple.CGImageRef;
    const create: Fn = @ptrCast(@alignCast(sym));
    // CG coordinates: origin at the top-left of the primary display.
    const screens = msg(id, objc.class("NSScreen"), "screens", .{});
    const primary = msg(id, screens, "objectAtIndex:", .{@as(NSUInteger, 0)});
    const sf = msg(CGRect, primary, "frame", .{});
    const wf = msg(CGRect, g.window, "frame", .{});
    const bounds = CGRect.make(wf.origin.x, sf.size.height - (wf.origin.y + wf.size.height), wf.size.width, wf.size.height);
    const wid: u32 = @intCast(msg(NSInteger, g.window, "windowNumber", .{}));
    const image = create(bounds, list_options, wid, 1 << 0);
    if (image == null) {
        std.debug.print("selftest: window capture returned null\n", .{});
        return;
    }
    defer apple.CGImageRelease(image);
    const url = apple.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false);
    defer apple.CFRelease(url);
    const uti = apple.cfString("public.png");
    defer apple.CFRelease(uti);
    const dest = apple.CGImageDestinationCreateWithURL(url, uti, 1, null);
    if (dest == null) return;
    defer apple.CFRelease(dest);
    apple.CGImageDestinationAddImage(dest, image, null);
    _ = apple.CGImageDestinationFinalize(dest);
    std.debug.print("selftest: window captured → {s}\n", .{path});
}

//! macOS shell of the app, written against the Objective-C runtime directly:
//! NSApplication + NSWindow + one CAMetalLayer-backed NSView. The view class
//! is registered at runtime and forwards input to the platform-neutral `App`.
const std = @import("std");
const objc = @import("../objc.zig");
const apple = @import("../apple.zig");
const app_mod = @import("../app.zig");
const events = @import("../events.zig");
const theme = @import("../ui/theme.zig");
const appearance = @import("../appearance.zig");
const ui_mod = @import("../ui/ui.zig");
const sys = @import("../sys.zig");
const tab_mod = @import("../tabs/tab.zig");
const WebTab = @import("../tabs/web_tab.zig").WebTab;
const TerminalTab = @import("../tabs/terminal_tab.zig").TerminalTab;
const NotebookTab = @import("../tabs/notebook_tab.zig").NotebookTab;
const notify = @import("notify.zig");
const cfg_mod = @import("../config.zig");
const camera = @import("camera.zig");
const camera_controller = @import("../physical/camera_controller.zig");

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
    /// `theme.generation` when the window last followed the tokens.
    applied_generation: u32 = 0,
    /// Whether the titlebar was last sized for compact mode.
    applied_compact: bool = false,
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
    g.debug_events = sys.getenv("TT_DEBUG_EVENTS") != null;
    g.selftest = sys.getenv("TT_SELFTEST") != null;

    const pool = objc.AutoreleasePool.push();
    defer pool.pop();

    g.nsapp = msg(id, objc.class("NSApplication"), "sharedApplication", .{});
    msg(void, g.nsapp, "setActivationPolicy:", .{@as(NSInteger, 0)});
    g.view_class = registerViewClass();
    blur_class = registerBlurViewClass();
    const delegate = msg(id, msg(id, registerDelegateClass(), "alloc", .{}), "init", .{});
    msg(void, g.nsapp, "setDelegate:", .{delegate});
    msg(void, g.nsapp, "run", .{});
}

// ── application delegate ─────────────────────────────────────────────────
fn registerDelegateClass() objc.Class {
    const b = objc.ClassBuilder.begin("TTAppDelegate", "NSObject");
    b.method("applicationWillFinishLaunching:", willFinishLaunching, "v@:@");
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
    // The window moved to another display, or displays were plugged in /
    // out: the theme may have to change with it (Settings › Mode › Per screen).
    b.method("windowDidChangeScreen:", screensChanged, "v@:@");
    b.method("applicationDidChangeScreenParameters:", screensChanged, "v@:@");
    return b.register();
}

/// Before launching is over, so a notification click that started tt
/// reaches the website tabs (platform/notify.zig).
fn willFinishLaunching(_: id, _: SEL, _: id) callconv(.c) void {
    notify.setup();
}

fn screensChanged(_: id, _: SEL, _: id) callconv(.c) void {
    syncScreens();
}

/// Tells the app which displays are connected and which one the window is
/// on, by the names System Settings shows. The app's next update applies
/// the mode set for that display.
fn syncScreens() void {
    const app = g.app orelse return;
    if (g.window == null) return;
    const list = msg(id, objc.class("NSScreen"), "screens", .{});
    const n: usize = @intCast(msg(NSUInteger, list, "count", .{}));
    const on = msg(id, g.window, "screen", .{});
    var names_buf: [16][]const u8 = undefined;
    var names: []const []const u8 = names_buf[0..0];
    var current: ?usize = null;
    var i: usize = 0;
    while (i < n and i < names_buf.len) : (i += 1) {
        const screen = msg(id, list, "objectAtIndex:", .{@as(NSUInteger, i)});
        names_buf[i] = objc.utf8(msg(id, screen, "localizedName", .{}));
        if (on != null and msg(bool, screen, "isEqual:", .{on})) current = i;
        names = names_buf[0 .. i + 1];
    }
    appearance.setScreens(g.gpa, names, current);
    if (g.debug_events or g.selftest) {
        std.debug.print("screens:", .{});
        for (appearance.screenNames(), 0..) |name, k| std.debug.print(" [{s}]{s}", .{ name, if (current == k) "*" else "" });
        std.debug.print(" → mode {s}\n", .{appearance.effectiveMode().configName()});
    }
    app.invalidate();
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
    msg(void, window, "setTitle:", .{objc.nsString("tt")});
    msg(void, window, "setTitlebarAppearsTransparent:", .{true});
    msg(void, window, "setTitleVisibility:", .{@as(NSInteger, 1)}); // hidden
    msg(void, window, "setTabbingMode:", .{@as(NSInteger, 2)}); // we have our own tabs
    msg(void, window, "setMinSize:", .{CGSize{ .width = 760, .height = 480 }});
    msg(void, window, "setDelegate:", .{self});

    // An empty unified toolbar makes the titlebar 52pt tall — the height of the
    // design's header row — and centres the traffic lights in it; in compact
    // mode the unified-compact style makes it `theme.header_h` (38pt).
    const toolbar = msg(id, objc.alloc("NSToolbar"), "initWithIdentifier:", .{objc.nsString("tt.toolbar")});
    msg(void, toolbar, "setShowsBaselineSeparator:", .{false});
    msg(void, window, "setToolbar:", .{toolbar});
    g.toolbar = toolbar;
    syncToolbarStyle();

    const view = msg(id, msg(id, g.view_class, "alloc", .{}), "initWithFrame:", .{frame});
    g.view = view;
    msg(void, view, "setWantsLayer:", .{true});
    const layer = msg(id, view, "layer", .{});

    g.app = app_mod.App.create(g.gpa, g.opts, layer, setClipboard) catch |err| {
        std.debug.print("tt: failed to start: {s}\n", .{@errorName(err)});
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
        return;
    };
    if (g.app) |app| {
        app.env.host = &host_impl;
        app.env.getClipboard = getClipboard;
    }
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
    _ = msg(bool, window, "setFrameAutosaveName:", .{objc.nsString("tt.main")});
    msg(void, window, "makeKeyAndOrderFront:", .{@as(id, null)});
    msg(void, g.nsapp, "activateIgnoringOtherApps:", .{true});
    updateGeometry();
    syncScreens();

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

/// The pasteboard's text (caller frees), null when it holds none.
fn getClipboard(gpa: std.mem.Allocator) ?[]u8 {
    const pb = msg(id, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const str = msg(id, pb, "stringForType:", .{NSPasteboardTypeString});
    if (str == null) return null;
    return gpa.dupe(u8, objc.utf8(str)) catch null;
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

    const app_menu = addMenu(bar, "tt");
    _ = addItem(app_menu, "About tt", "orderFrontStandardAboutPanel:", "", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Settings…", "openSettings:", ",", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Hide tt", "hide:", "h", null);
    _ = addItem(app_menu, "Hide Others", "hideOtherApplications:", "h", mod_cmd | mod_alt);
    _ = addItem(app_menu, "Show All", "unhideAllApplications:", "", null);
    addSeparator(app_menu);
    _ = addItem(app_menu, "Quit tt", "terminate:", "q", null);

    const file_menu = addMenu(bar, "File");
    _ = addItem(file_menu, "Save", "saveDocument:", "s", null);
    addSeparator(file_menu);
    _ = addItem(file_menu, "Go to File…", "quickOpen:", "p", null);
    _ = addItem(file_menu, "Go to Line…", "goToLine:", "", null);

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
    _ = addItem(view_menu, "Find in Files…", "findInFiles:", "f", mod_cmd | mod_shift);
    addSeparator(view_menu);
    _ = addItem(view_menu, "Split Right", "splitRight:", "d", null);
    _ = addItem(view_menu, "Split Down", "splitDown:", "d", mod_cmd | mod_shift);
    _ = addItem(view_menu, "Focus Next Pane", "nextPane:", "]", null);
    _ = addItem(view_menu, "Focus Previous Pane", "prevPane:", "[", null);
    addSeparator(view_menu);
    // ⌘= (unshifted) is caught in performKeyEquivalent; the item shows ⌘+.
    _ = addItem(view_menu, "Zoom In", "zoomIn:", "+", null);
    _ = addItem(view_menu, "Zoom Out", "zoomOut:", "-", null);
    _ = addItem(view_menu, "Actual Size", "actualSize:", "0", null);
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
    const b = objc.ClassBuilder.begin("TTView", "NSView");
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
    b.method("flagsChanged:", flagsChanged, "v@:@");
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
    b.method("findInFiles:", actionFindInFiles, "v@:@");
    b.method("closeTab:", actionCloseTab, "v@:@");
    b.method("nextTab:", actionNextTab, "v@:@");
    b.method("prevTab:", actionPrevTab, "v@:@");
    b.method("toggleSidebar:", actionToggleSidebar, "v@:@");
    b.method("commandPalette:", actionCommandPalette, "v@:@");
    b.method("quickOpen:", actionQuickOpen, "v@:@");
    b.method("goToLine:", actionGoToLine, "v@:@");
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
    b.method("zoomIn:", actionZoomIn, "v@:@");
    b.method("zoomOut:", actionZoomOut, "v@:@");
    b.method("actualSize:", actionActualSize, "v@:@");
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
/// background follow the theme's scheme (and its terminal theme's background).
fn syncWindowAppearance() void {
    if (g.window == null) return;
    const name = switch (theme.scheme) {
        .dark => "NSAppearanceNameDarkAqua",
        .light, .eink, .eink_color => "NSAppearanceNameAqua",
    };
    const ns_appearance = msg(id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString(name)});
    msg(void, g.window, "setAppearance:", .{ns_appearance});
    const bg = msg(id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, theme.bg.r), @as(f64, theme.bg.g), @as(f64, theme.bg.b), @as(f64, 1),
    });
    msg(void, g.window, "setBackgroundColor:", .{bg});
    g.applied_scheme = theme.scheme;
    g.applied_generation = theme.generation;
    if (g.app) |app| app.invalidate();
}

/// The titlebar's height follows compact mode: unified (52pt) or unified
/// compact (38pt), the two heights `theme.header_h` takes. The traffic
/// lights move with it, so their inset is read again.
fn syncToolbarStyle() void {
    if (g.window == null) return;
    const style: NSInteger = if (theme.compact) 4 else 3; // unifiedCompact : unified
    msg(void, g.window, "setToolbarStyle:", .{style});
    g.applied_compact = theme.compact;
    g.chrome_recheck = 60;
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
    if (g.applied_scheme != theme.scheme or g.applied_generation != theme.generation) syncWindowAppearance();
    if (g.applied_compact != theme.compact) syncToolbarStyle();
    // Runs between frames: the picker's modal loop keeps ticking this timer.
    if (app.folder_pick_requested) {
        app.folder_pick_requested = false;
        pickProjectFolder();
    }
    const dirty = app.update(now);
    syncBlur(now);
    if (!dirty) return;
    // nextDrawable blocks when the window is not on screen; skip drawing
    // then. The self test still lays the frame out so the hosted views get
    // placed: its checks must not depend on what happens to cover the screen.
    if (!windowOnScreen()) {
        if (g.selftest) {
            app.buildFrame();
            hostSync();
        }
        return;
    }
    app.buildFrame();
    hostSync();
    app.present();
    syncCursor();
}

fn windowOnScreen() bool {
    const occlusion = msg(NSUInteger, g.window, "occlusionState", .{});
    return occlusion & (1 << 1) != 0;
}

// ── the away blur (Settings › Physical interactions) ─────────────────────
// A blurring view over the whole window — the Metal view and the web
// views hosted on it — fades in while the camera controller says nobody is
// looking, and out the moment someone looks again (or types, or clicks).
// It takes the clicks made on it, so nothing hidden under it is clicked by
// accident: a click only counts as activity, which clears the blur. Keys
// still reach the app underneath (and clear it too).
var blur_class: objc.Class = null;
var blur_view: id = null;
var blur_on: bool = false;
/// When the fade-out is over and the view hides: at alpha 0 it would still
/// take the clicks.
var blur_hide_at: f64 = 0;

fn registerBlurViewClass() objc.Class {
    const b = objc.ClassBuilder.begin("TTBlurView", "NSView");
    b.method("mouseDown:", blurClicked, "v@:@");
    b.method("rightMouseDown:", blurClicked, "v@:@");
    b.method("otherMouseDown:", blurClicked, "v@:@");
    b.method("scrollWheel:", blurClicked, "v@:@");
    // The rest of a click stays here too: the app never saw its press.
    for ([_][:0]const u8{ "mouseUp:", "rightMouseUp:", "otherMouseUp:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:" }) |name| {
        _ = objc.class_addMethod(b.cls, objc.sel_registerName(name.ptr), @ptrCast(&blurSwallow), "v@:@");
    }
    b.method("acceptsFirstMouse:", yesWithArg, "B@:@");
    return b.register();
}

fn blurClicked(_: id, _: SEL, _: id) callconv(.c) void {
    camera_controller.get().noteActivity(apple.CACurrentMediaTime());
}

fn blurSwallow(_: id, _: SEL, _: id) callconv(.c) void {}

/// Shows or hides the blur as the camera controller decided; after each update.
fn syncBlur(now: f64) void {
    const want = camera_controller.get().blurred;
    if (want != blur_on) {
        blur_on = want;
        if (blur_view == null) makeBlurView();
        if (g.debug_events or g.selftest) std.debug.print("blur: {s}\n", .{if (want) "on" else "off"});
        if (want) {
            blur_hide_at = 0;
            raiseBlur();
            msg(void, blur_view, "setHidden:", .{false});
            fadeBlur(1, 0.45);
        } else {
            fadeBlur(0, 0.18);
            blur_hide_at = now + 0.25;
        }
    }
    if (blur_on) {
        // A web view attached since goes on top of it: back under the blur.
        raiseBlur();
    } else if (blur_hide_at > 0 and now >= blur_hide_at) {
        blur_hide_at = 0;
        msg(void, blur_view, "setHidden:", .{true});
    }
}

fn raiseBlur() void {
    const top = msg(id, msg(id, g.view, "subviews", .{}), "lastObject", .{});
    // NSWindowAbove, relative to nothing: the front of the subviews.
    if (top != blur_view) msg(void, g.view, "addSubview:positioned:relativeTo:", .{ blur_view, @as(NSInteger, 1), @as(id, null) });
}

fn fadeBlur(alpha: f64, seconds: f64) void {
    const ctx = objc.class("NSAnimationContext");
    msg(void, ctx, "beginGrouping", .{});
    msg(void, msg(id, ctx, "currentContext", .{}), "setDuration:", .{seconds});
    msg(void, msg(id, blur_view, "animator", .{}), "setAlphaValue:", .{alpha});
    msg(void, ctx, "endGrouping", .{});
}

fn makeBlurView() void {
    const bounds = msg(CGRect, g.view, "bounds", .{});
    const v = msg(id, msg(id, blur_class, "alloc", .{}), "initWithFrame:", .{bounds});
    msg(void, v, "setWantsLayer:", .{true});
    // A Gaussian blur of whatever is behind the view: the window's own
    // content in its own colours, shapes left and words gone. (A visual-
    // effect material tints it to a flat grey instead.)
    msg(void, v, "setLayerUsesCoreImageFilters:", .{true});
    const layer = msg(id, v, "layer", .{});
    const blur = msg(id, objc.class("CIFilter"), "filterWithName:", .{objc.nsString("CIGaussianBlur")});
    if (blur != null) {
        msg(void, blur, "setDefaults", .{});
        msg(void, blur, "setValue:forKey:", .{ msg(id, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 24)}), objc.nsString("inputRadius") });
        msg(void, layer, "setBackgroundFilters:", .{msg(id, objc.class("NSArray"), "arrayWithObject:", .{blur})});
    } else {
        // No Core Image: cover the window instead.
        const bg = msg(id, objc.class("NSColor"), "windowBackgroundColor", .{});
        msg(void, layer, "setBackgroundColor:", .{msg(?*anyopaque, bg, "CGColor", .{})});
    }
    msg(void, v, "setAutoresizingMask:", .{follows_box});
    msg(void, v, "setAlphaValue:", .{@as(f64, 0)});
    msg(void, v, "setHidden:", .{true});

    // An eye with a slash and a line under it, in the middle. The view is
    // not flipped: y counts up, so the symbol sits above the line.
    const tint = msg(id, objc.class("NSColor"), "secondaryLabelColor", .{});
    const flexible_margins: NSUInteger = 1 | 4 | 8 | 32;
    const mid_x = bounds.size.width / 2;
    const mid_y = bounds.size.height / 2;
    const symbol = msg(id, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.nsString("eye.slash"), objc.nsString("Blurred") });
    if (symbol != null) {
        const sym_cfg = msg(id, objc.class("NSImageSymbolConfiguration"), "configurationWithPointSize:weight:", .{ @as(f64, 30), @as(f64, 0) });
        const img = msg(id, symbol, "imageWithSymbolConfiguration:", .{sym_cfg});
        const iv = msg(id, objc.class("NSImageView"), "imageViewWithImage:", .{img});
        msg(void, iv, "setContentTintColor:", .{tint});
        const size = msg(CGSize, img, "size", .{});
        msg(void, iv, "setFrame:", .{CGRect.make(mid_x - size.width / 2, mid_y + 10, size.width, size.height)});
        msg(void, iv, "setAutoresizingMask:", .{flexible_margins});
        msg(void, v, "addSubview:", .{iv});
    }
    const label = msg(id, objc.class("NSTextField"), "labelWithString:", .{objc.nsString("Blurred while you look away")});
    msg(void, label, "setFont:", .{msg(id, objc.class("NSFont"), "systemFontOfSize:weight:", .{ @as(f64, 15), @as(f64, 0.23) })});
    msg(void, label, "setTextColor:", .{tint});
    msg(void, label, "sizeToFit", .{});
    const ls = msg(CGRect, label, "frame", .{}).size;
    msg(void, label, "setFrame:", .{CGRect.make(mid_x - ls.width / 2, mid_y - ls.height - 2, ls.width, ls.height)});
    msg(void, label, "setAutoresizingMask:", .{flexible_margins});
    msg(void, v, "addSubview:", .{label});

    msg(void, g.view, "addSubview:", .{v});
    blur_view = v;
}

// ── native views hosted over the Metal layer (website tabs) ──────────────
// A tab attaches its view once and places it on every frame it draws; after
// the frame the views placed are shown where they were put, the rest are
// hidden — all of them while the palette or a box covers the window, since
// a native view would sit on top of the dimming and the panel.
//
// Each view sits in a box of its own, a plain NSView, and the box is what
// the tab's rect places: whatever the view's framework docks beside it lays
// itself out in the view's *superview* — WebKit's Web Inspector ("Inspect
// Element") adds its own view there and gives the page the superview's
// full width, which was the whole window. In the box the two share the
// page's rect, and the view follows the box (autoresizing) so that layout
// survives the window resizing.
const Hosted = struct {
    view: id,
    box: id,
    frame: CGRect = .{},
    /// The view's own frame inside the box when it scrolls under a clip
    /// (`placeClipped`); null when it just fills the box (`place`).
    inner: ?CGRect = null,
    placed: bool = false,
    shown: bool = false,
};
var hosted: std.ArrayList(Hosted) = .empty;

/// NSViewWidthSizable | NSViewHeightSizable.
const follows_box: NSUInteger = 2 | 16;

fn hostAttach(view: *anyopaque) void {
    const v: id = view;
    const box = msg(id, objc.alloc("NSView"), "initWithFrame:", .{msg(CGRect, v, "frame", .{})});
    msg(void, box, "setHidden:", .{true});
    // Clip whatever the box holds to its bounds, so a view scrolling under a
    // notebook's viewport (`placeClipped`) does not overhang it.
    msg(void, box, "setWantsLayer:", .{true});
    if (msg(bool, box, "respondsToSelector:", .{objc.sel("setClipsToBounds:")})) msg(void, box, "setClipsToBounds:", .{true});
    if (msg(id, box, "layer", .{})) |layer| msg(void, layer, "setMasksToBounds:", .{true});
    msg(void, v, "setFrame:", .{msg(CGRect, box, "bounds", .{})});
    msg(void, v, "setAutoresizingMask:", .{follows_box});
    msg(void, box, "addSubview:", .{v});
    msg(void, g.view, "addSubview:", .{box});
    hosted.append(g.gpa, .{ .view = v, .box = box }) catch {};
}

/// The box around a hosted view (the view itself when it has none).
fn hostBox(view: id) id {
    for (hosted.items) |h| {
        if (h.view == view) return h.box;
    }
    return view;
}

fn hostPlace(view: *anyopaque, rect: ui_mod.Rect) void {
    const v: id = view;
    // `rect` is in the app's zoomed logical space; the box is a plain subview
    // of the content view, whose coordinates are window points — scale up by
    // the zoom so the native view keeps covering its pane at any zoom.
    const z: f64 = if (g.app) |app| app.zoom else 1;
    for (hosted.items) |*h| {
        if (h.view != v) continue;
        h.frame = CGRect.make(rect.x * z, rect.y * z, rect.w * z, rect.h * z);
        h.inner = null;
        h.placed = true;
    }
}

/// Places a view that scrolls inside a viewport: the box takes the visible
/// `clip`, the view keeps `content`'s full size shifted into it (so it is not
/// squashed as it scrolls). See `tab_mod.Host.placeClipped`.
fn hostPlaceClipped(view: *anyopaque, content: ui_mod.Rect, clip: ui_mod.Rect) void {
    const v: id = view;
    const z: f64 = if (g.app) |app| app.zoom else 1;
    for (hosted.items) |*h| {
        if (h.view != v) continue;
        h.frame = CGRect.make(clip.x * z, clip.y * z, clip.w * z, clip.h * z);
        // The box is a plain NSView, not flipped: a subview's y counts up
        // from the box's bottom edge, so the view's offset is how far its
        // bottom hangs below the clip's (zero or negative).
        const below = (clip.y + clip.h) - (content.y + content.h);
        h.inner = CGRect.make((content.x - clip.x) * z, below * z, content.w * z, content.h * z);
        h.placed = true;
    }
}

fn hostDetach(view: *anyopaque) void {
    const v: id = view;
    var i: usize = 0;
    while (i < hosted.items.len) {
        if (hosted.items[i].view == v) {
            const box = hosted.items[i].box;
            msg(void, v, "removeFromSuperview", .{});
            msg(void, box, "removeFromSuperview", .{});
            objc.release(box);
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
    // The box, so what is docked beside the view (the inspector) counts.
    return msg(bool, fr, "isDescendantOf:", .{hostBox(v)});
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

/// A bare WKWebView (no navigation delegate, no bridges): a notebook cell's
/// web output loads local HTML into it. The caller attaches, loads, places
/// and finally detaches + destroys it.
fn hostCreateWebView() ?*anyopaque {
    const config = objc.new("WKWebViewConfiguration");
    defer objc.release(config);
    const prefs = msg(id, config, "preferences", .{});
    const truth = msg(id, objc.class("NSNumber"), "numberWithBool:", .{true});
    msg(void, prefs, "setValue:forKey:", .{ truth, objc.nsString("developerExtrasEnabled") });
    // The page is loaded from a file:// URL and pulls in a sibling script
    // (the Plotly library); let file pages read other file resources.
    msg(void, prefs, "setValue:forKey:", .{ truth, objc.nsString("allowFileAccessFromFileURLs") });
    const view = msg(id, msg(id, objc.class("WKWebView"), "alloc", .{}), "initWithFrame:configuration:", .{ CGRect.make(0, 0, 200, 200), config });
    if (view == null) return null;
    if (msg(bool, view, "respondsToSelector:", .{objc.sel("setInspectable:")})) msg(void, view, "setInspectable:", .{true});
    msg(void, view, "setAllowsMagnification:", .{true});
    return view;
}

fn hostDestroyWebView(view: *anyopaque) void {
    const v: id = view;
    msg(void, v, "stopLoading", .{});
    objc.release(v);
}

fn hostLoadHtmlFile(view: *anyopaque, file_path: []const u8, read_dir: []const u8) void {
    const v: id = view;
    const file_url = msg(id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file_path)});
    const dir_url = msg(id, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ objc.nsString(read_dir), true });
    if (file_url == null or dir_url == null) return;
    _ = msg(id, v, "loadFileURL:allowingReadAccessToURL:", .{ file_url, dir_url });
}

const host_impl: tab_mod.Host = .{
    .attach = hostAttach,
    .place = hostPlace,
    .placeClipped = hostPlaceClipped,
    .detach = hostDetach,
    .hasFocus = hostHasFocus,
    .focusView = hostFocusView,
    .focusApp = hostFocusApp,
    .createWebView = hostCreateWebView,
    .destroyWebView = hostDestroyWebView,
    .loadHtmlFile = hostLoadHtmlFile,
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
        if (show) {
            if (!rectEql(msg(CGRect, h.box, "frame", .{}), h.frame)) {
                msg(void, h.box, "setFrame:", .{h.frame});
                changed = true;
            }
            if (h.inner) |inner| {
                // The view is sized on its own (it scrolls under the box's
                // clip); the autoresize that fills the box would fight it.
                msg(void, h.view, "setAutoresizingMask:", .{@as(NSUInteger, 0)});
                if (!rectEql(msg(CGRect, h.view, "frame", .{}), inner)) {
                    msg(void, h.view, "setFrame:", .{inner});
                    changed = true;
                }
            } else {
                msg(void, h.view, "setAutoresizingMask:", .{follows_box});
            }
        }
        if (show != h.shown) {
            msg(void, h.box, "setHidden:", .{!show});
            h.shown = show;
            changed = true;
        }
        h.placed = false;
        h.inner = null;
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
    const v = msg(CGPoint, g.view, "convertPoint:fromView:", .{ p, @as(id, null) });
    // The app draws in a logical space shrunk by its zoom, so map the pointer
    // into that same space; everything downstream compares against it.
    const z: f64 = if (g.app) |app| app.zoom else 1;
    return .{ .x = v.x / z, .y = v.y / z };
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
    // The modifiers too: a key released while a web view had the keyboard
    // never reached `flagsChanged:`.
    app.onFlags(eventMods(event));
    const p = eventPoint(event);
    app.onMouseMove(@floatCast(p.x), @floatCast(p.y));
}

/// A modifier key went down or up (⌘ / ⌃ over a link shows it can be followed).
fn flagsChanged(_: id, _: SEL, event: id) callconv(.c) void {
    if (g.app) |app| app.onFlags(eventMods(event));
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
    // Deltas are physical too; scale them into the zoomed logical space so the
    // scroll distance per gesture feels the same at any zoom.
    const z: f64 = app.zoom;
    app.onScroll(@floatCast(p.x), @floatCast(p.y), @floatCast(dx / z), @floatCast(dy / z));
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
        // Zoom: ⌘+ arrives as '=' unshifted or '+' shifted; ⌘− as '-'; ⌘0 resets.
        if (chars.len == 1) switch (chars[0]) {
            '=', '+' => {
                app.perform(.zoom_in);
                return true;
            },
            '-', '_' => {
                app.perform(.zoom_out);
                return true;
            },
            '0' => {
                app.perform(.zoom_reset);
                return true;
            },
            else => {},
        };
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
    // The caret is in the app's zoomed logical space; the view wants window
    // points, so scale up by the zoom before converting to screen.
    const z: f64 = app.zoom;
    const in_view = CGRect.make(c.x * z, c.y * z, c.w * z, c.h * z);
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
fn actionFindInFiles(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.find_in_files);
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
fn actionQuickOpen(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.quick_open);
}
fn actionGoToLine(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.go_to_line);
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
fn actionZoomIn(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.zoom_in);
}
fn actionZoomOut(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.zoom_out);
}
fn actionActualSize(_: id, _: SEL, _: id) callconv(.c) void {
    if (g.app) |app| app.perform(.zoom_reset);
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

// ── self test (TT_SELFTEST=1) ─────────────────────────────────────────
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
    // Collapse button, the toggle that reopens the sidebar (in the band
    // right of the traffic lights: 79 + 8, 36 wide) and the "+" of the tab
    // strip, ⌘K as a real key equivalent through the menu, then key events
    // through interpretKeyEvents / NSTextInputClient (Escape closes the
    // palette via cancelOperation:).
    const steps = [_]Step{
        .{ .at = 1.5, .x = 272, .y = 26, .what = "collapse sidebar (titlebar band)" },
        .{ .at = 2.0, .x = 105, .y = 26, .what = "expand sidebar (toggle in the titlebar band)" },
        .{ .at = 2.5, .x = 416, .y = 26, .what = "new tab (+ in the tab strip, titlebar band)" },
        .{ .at = 3.0, .cmd_key = 'k', .what = "open palette (⌘K menu key equivalent)" },
        .{ .at = 3.4, .keys = "\x1b", .what = "Escape closes the palette" },
        .{ .at = 3.8, .keys = "echo selftest-ok\r", .what = "type a command + Return" },
    };
    // The notebook leg skips the regular steps: their typing would land in
    // the restored notebook's focused cell, and its unsaved edit would then
    // hold up the quit.
    if (sys.getenv("TT_SELFTEST_NOTEBOOK") != null) {
        selftestNotebook(t);
    } else if (sys.getenv("TT_SELFTEST_BLUR") != null) {
        // No regular steps either: their clicks and keys count as activity.
        selftestBlur(t);
    } else if (g.selftest_step < steps.len) {
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
    } else if (sys.getenv("TT_SELFTEST_URL")) |url| {
        selftestWeb(t, url);
    } else if (sys.getenv("TT_SELFTEST_FULLSCREEN") != null) {
        selftestFullScreen(t);
    } else if (t >= 5.5) {
        std.debug.print("selftest: sidebar collapsed={} tabs={d} palette_opened={} palette_open={} inset_left={d:.0} focused={}\n", .{
            app.sidebar.collapsed, app.tabs.count(), g.selftest_palette_seen, app.palette.open, app.chrome.inset_left, app.chrome.window_focused,
        });
        if (sys.getenv("TT_SELFTEST_SNAP")) |path| app.snapshot(path) catch {};
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        selftestReportButtons();
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

/// TT_SELFTEST_NOTEBOOK=1, with TT_WORKSPACE naming a workspace that holds a
/// notebook tab: instead of the regular steps, the restored notebook is shown
/// with its first web output (a Plotly figure, an HTML repr) in view; the web
/// views get a few seconds to load, the counts are printed and the window is
/// captured (TT_SELFTEST_WINDOW_PNG). Then the notebook scrolls so the figure
/// goes under the toolbar ("-scrolled": the host must clip it), and another
/// tab is shown ("-othertab": every hosted view must hide).
var selftest_nb_step: u8 = 0;

fn selftestNotebook(t: f64) void {
    const app = g.app orelse return;
    if (selftest_nb_step == 0) {
        selftest_nb_step = 1;
        var found = false;
        for (app.tabs.items(), 0..) |tab, i| {
            const nb = NotebookTab.fromTab(tab) orelse continue;
            app.tabs.activate(i);
            // No focused cell: its caret would pull the scroll back to it.
            nb.focus_cell = null;
            const r = nb.selftestWeb();
            std.debug.print("selftest: restored notebook, web outputs={d}\n", .{r.outputs});
            found = true;
            break;
        }
        if (!found) std.debug.print("selftest: no restored notebook tab in the pane on show\n", .{});
        app.invalidate();
    } else if (selftest_nb_step == 1 and t >= 12) {
        // The figure in view, loaded.
        selftest_nb_step = 2;
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        for (app.tabs.items()) |tab| {
            const nb = NotebookTab.fromTab(tab) orelse continue;
            const r = nb.selftestWeb();
            var why: [160]u8 = undefined;
            std.debug.print("selftest: notebook web outputs={d} live views={d} close_warning='{s}'\n", .{ r.outputs, r.live, tab.vtable.closeWarning(tab.ptr, &why) orelse "none" });
            // Scroll on so the figure's top goes under the toolbar: the host
            // must clip the view to the cells, not let it overhang.
            nb.focus_cell = null;
            nb.reveal = null;
            nb.scroll += 300;
            break;
        }
        app.invalidate();
    } else if (selftest_nb_step == 2 and t >= 13.5) {
        selftest_nb_step = 3;
        // Where each shown view really is, next to its box: a view clipped
        // at the top must start above its box and keep its full height.
        // (A capture of an occluded window shows a stale Metal frame, so
        // the numbers are the check; the capture is for looking.)
        for (hosted.items) |h| {
            if (!h.shown) continue;
            const box = msg(CGRect, h.box, "frame", .{});
            const seen = msg(CGRect, h.view, "convertRect:toView:", .{ msg(CGRect, h.view, "bounds", .{}), g.view });
            std.debug.print("selftest: hosted box y={d:.0}..{d:.0} view y={d:.0}..{d:.0} (h={d:.0})\n", .{
                box.origin.y, box.origin.y + box.size.height, seen.origin.y, seen.origin.y + seen.size.height, seen.size.height,
            });
        }
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-scrolled");
        // Another tab on show: the notebook's views must all hide.
        for (app.tabs.items(), 0..) |tab, i| {
            if (NotebookTab.fromTab(tab) != null) continue;
            app.tabs.activate(i);
            break;
        }
        app.invalidate();
    } else if (selftest_nb_step == 3 and t >= 15) {
        selftest_nb_step = 4;
        var shown: usize = 0;
        for (hosted.items) |h| {
            if (h.shown) shown += 1;
        }
        std.debug.print("selftest: another tab on show, hosted views shown={d}\n", .{shown});
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-othertab");
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

/// Captures the window to `path` with `suffix` before its extension.
/// TT_SELFTEST_BLUR=1 with TT_CAMERA_MOCK=<a picture without a face>,
/// TT_SELFTEST_BLUR_FACE=<a picture of a face looking at the camera> and a
/// config.yml with `physical: blur_when_away: true, blur_after: 1`: nobody
/// in view → the window blurs ("-blurred" capture); the face → it clears
/// ("-clear"); nobody again → blurred; a click on the blur → clear at once
/// ("-clicked"). The state is printed at each step. With TT_SELFTEST_URL a
/// website tab is shown first, to see its web view blur too.
var selftest_blur_step: u8 = 0;
var selftest_blur_web = false;

fn selftestBlur(t: f64) void {
    const ctl = camera_controller.get();
    // With TT_SELFTEST_URL, a website tab is on show: its web view has to
    // blur like the rest.
    if (!selftest_blur_web) {
        selftest_blur_web = true;
        if (sys.getenv("TT_SELFTEST_URL")) |url| {
            if (g.app) |app| _ = app.tabs.openWith("web", .{ .url = url }) catch {};
        }
    }
    const Step = struct { at: f64, what: []const u8 };
    const steps = [_]Step{
        .{ .at = 4.0, .what = "nobody in view" },
        .{ .at = 4.1, .what = "a face looks at the screen" },
        .{ .at = 6.0, .what = "looking" },
        .{ .at = 6.1, .what = "nobody again" },
        .{ .at = 8.5, .what = "nobody, blurred again" },
        .{ .at = 8.6, .what = "click on the blur" },
        .{ .at = 9.0, .what = "after the click" },
    };
    if (selftest_blur_step >= steps.len) {
        if (t >= 9.5) msg(void, g.nsapp, "terminate:", .{@as(id, null)});
        return;
    }
    const s = steps[selftest_blur_step];
    if (t < s.at) return;
    selftest_blur_step += 1;
    std.debug.print("selftest: blur leg: {s}: blurred={} gaze={s} stance={s} frames={d} view_alpha={d:.2} hidden={}\n", .{
        s.what,
        ctl.blurred,
        @tagName(ctl.posture.gaze),
        @tagName(ctl.posture.stance),
        ctl.obs.seq,
        if (blur_view != null) msg(f64, blur_view, "alphaValue", .{}) else -1,
        blur_view == null or msg(bool, blur_view, "isHidden", .{}),
    });
    const png = sys.getenv("TT_SELFTEST_WINDOW_PNG");
    switch (selftest_blur_step) {
        1 => if (png) |path| selftestCaptureSuffixed(path, "-blurred"),
        2 => camera.setMock(sys.getenv("TT_SELFTEST_BLUR_FACE") orelse ""),
        3 => if (png) |path| selftestCaptureSuffixed(path, "-clear"),
        4 => camera.setMock(sys.getenv("TT_CAMERA_MOCK") orelse ""),
        6 => {
            postMouse(1, 700, 450);
            postMouse(2, 700, 450);
        },
        7 => if (png) |path| selftestCaptureSuffixed(path, "-clicked"),
        else => {},
    }
}

fn selftestCaptureSuffixed(path: []const u8, suffix: []const u8) void {
    var buf: [1024]u8 = undefined;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const out = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ path[0..dot], suffix, path[dot..] }) catch return;
    captureOwnWindow(out, 1 << 3);
}

/// TT_SELFTEST_URL=https://…: after the regular steps, a website tab on
/// that address; the page gets a few seconds, the palette is opened over it
/// (the hosted view must hide under the scrim; TT_SELFTEST_WINDOW_PNG
/// gets a "-palette" capture) and closed again, then the window is captured
/// with the page and the hosted view's state is printed.
var selftest_web_step: u8 = 0;

fn selftestWeb(t: f64, url: []const u8) void {
    const app = g.app orelse return;
    if (selftest_web_step == 0) {
        selftest_web_step = 1;
        if (std.mem.eql(u8, url, "restored")) {
            // The tab the workspace brought back (TT_WORKSPACE names the
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
    } else if (selftest_web_step == 1 and sys.getenv("TT_SELFTEST_EVAL") != null) {
        selftestEval(app, t, sys.getenv("TT_SELFTEST_EVAL").?);
    } else if (selftest_web_step == 1 and sys.getenv("TT_SELFTEST_PERMISSIONS") != null) {
        selftestPermissions(app, t);
    } else if (selftest_web_step == 1 and t >= 8.5 and sys.getenv("TT_SELFTEST_WEBMENU") != null) {
        // The page's context menu, without the menu (which is modal): the
        // entries the app adds for the selection and the link the page
        // reported, the first one picked as a user would. While the page
        // is on show — hiding the web view (the palette step) empties the
        // selection, as it would for a user.
        selftest_web_step = 4;
        selftestWebMenu(app);
    } else if (selftest_web_step == 4 and t >= 9.5) {
        selftest_web_step = 5;
        const cur = app.tabs.current();
        const kind = if (cur) |c| c.kind else "(none)";
        const input = if (cur) |c| (if (TerminalTab.fromTab(c)) |term| term.editor.bytes() else "") else "";
        std.debug.print("selftest: after the menu: current tab kind='{s}' input='{s}' tabs={d}\n", .{ kind, input, app.tabs.items().len });
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    } else if (selftest_web_step == 1 and t >= 8.5 and sys.getenv("TT_SELFTEST_INSPECTOR") != null) {
        // The Web Inspector docked to the page, as "Inspect Element" does
        // it, must stay inside the page's rect: the box the host keeps the
        // web view in, not the window.
        selftest_web_step = 6;
        selftestInspector(app, .open);
    } else if (selftest_web_step == 6 and t >= 10) {
        selftest_web_step = 7;
        selftestInspector(app, .dock);
    } else if (selftest_web_step == 7 and t >= 12.5) {
        selftest_web_step = 8;
        selftestInspector(app, .report);
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
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
            std.debug.print("selftest: palette_open={} palette_seen={} hosted view hidden={} first_responder={s}\n", .{ app.palette.open, g.selftest_palette_seen, msg(bool, h.box, "isHidden", .{}), fr_class });
        }
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| {
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
            const f = msg(CGRect, h.box, "frame", .{});
            const hidden = msg(bool, h.box, "isHidden", .{});
            std.debug.print("selftest: hosted view shown={} hidden={} frame=({d:.0},{d:.0} {d:.0}x{d:.0}) loading={}\n", .{
                h.shown, hidden, f.origin.x, f.origin.y, f.size.width, f.size.height, msg(bool, h.view, "isLoading", .{}),
            });
        }
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

/// TT_SELFTEST_EVAL='js' (with TT_SELFTEST_URL): the JavaScript runs in the
/// page's own world once it has loaded, and whatever it puts in
/// document.title is printed a moment later — a quick probe of what the
/// page sees (`navigator.mediaDevices`, `isSecureContext` …).
var selftest_eval_step: u8 = 0;

fn selftestEval(app: *app_mod.App, t: f64, js: []const u8) void {
    var page: ?*WebTab = null;
    for (app.tabs.items()) |tab| {
        if (WebTab.fromTab(tab)) |w| {
            page = w;
            break;
        }
    }
    const w = page orelse return;
    if (selftest_eval_step == 0 and t >= 8.5) {
        selftest_eval_step = 1;
        w.evalPage(js);
    } else if (selftest_eval_step == 1 and t >= 10) {
        selftest_eval_step = 2;
        std.debug.print("selftest: eval url='{s}' title={s}\n", .{ w.url.items, w.page_title.items });
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

/// TT_SELFTEST_PERMISSIONS=1 (with TT_SELFTEST_URL on a page that asks to
/// show notifications as it loads and defines `startGum()`; TT_NOTIFY_DRYRUN=1
/// so nothing reaches Notification Center; TT_SELFTEST_MOCK_CAPTURE=1 for
/// stand-in cameras, as a real getUserMedia would raise macOS's privacy
/// prompt; a throwaway HOME, as answers are saved): replaces the palette
/// steps of the website leg. The page's report (its title, JSON) is printed
/// at each step. In order: the notification question is on show in the bar
/// ("-ask" capture) and is answered Allow — the page's promise resolves and
/// its `new Notification` goes to notify.zig with the site's favicon (the
/// dry run prints it); a click on the notification brings the page's tab
/// back and reaches its onclick; the camera/microphone answers reach a
/// stand-in decision block; the page's own getUserMedia goes through
/// WebKit's block to the bar ("-callask"), is allowed, and the indicators
/// show the capture (muting the camera from them); last, `window.open`
/// makes a new tab that keeps its opener, closes itself, and hands the
/// front back to the page.
var selftest_perm_step: u8 = 0;
var selftest_perm_tab: ?*WebTab = null;
var selftest_perm_origin_buf: [256]u8 = undefined;
var selftest_perm_origin: []const u8 = "";

const PermProbe = struct {
    var block: objc.Block = undefined;
    var got: [4]NSInteger = .{ -1, -1, -1, -1 };
    var n: usize = 0;
    fn decided(_: *objc.Block, decision: NSInteger) callconv(.c) void {
        if (n < got.len) {
            got[n] = decision;
            n += 1;
        }
    }
};

/// The fixture's own tab, while it is still open (a popup may be in front,
/// and tabs close under the test).
fn selftestPermTab(app: *app_mod.App) ?*WebTab {
    const want = selftest_perm_tab orelse return null;
    for (app.tabs.items()) |tab| {
        if (tab.ptr == @as(*anyopaque, want)) return want;
    }
    std.debug.print("selftest: the fixture's tab is gone\n", .{});
    return null;
}

fn selftestPermissions(app: *app_mod.App, t: f64) void {
    if (selftest_perm_step == 0 and t >= 8.5) {
        selftest_perm_step = 1;
        selftestListWebTabs(app, "at the start");
        const url = sys.getenv("TT_SELFTEST_URL") orelse return;
        for (app.tabs.items()) |tab| {
            const w = WebTab.fromTab(tab) orelse continue;
            if (std.mem.eql(u8, w.url.items, url)) selftest_perm_tab = w;
        }
        const w = selftest_perm_tab orelse {
            std.debug.print("selftest: no website tab on {s}\n", .{url});
            return;
        };
        std.debug.print("selftest: page report {s}\n", .{w.page_title.items});
        const media_sel = msg(bool, w.delegate, "respondsToSelector:", .{objc.sel("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")});
        std.debug.print("selftest: media delegate method={} waiting={d} status={s}\n", .{ media_sel, w.prompts.items.len, @tagName(w.status()) });
        if (w.prompts.items.len > 0) {
            const p = w.prompts.items[0];
            const n = @min(p.origin.len, selftest_perm_origin_buf.len);
            @memcpy(selftest_perm_origin_buf[0..n], p.origin[0..n]);
            selftest_perm_origin = selftest_perm_origin_buf[0..n];
            std.debug.print("selftest: bar asks: '{s}' {s}\n", .{ p.origin, p.question() });
        }
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-ask");
        std.debug.print("selftest: Allow\n", .{});
        w.answer(true, true);
    } else if (selftest_perm_step == 1 and t >= 10) {
        selftest_perm_step = 2;
        const w = selftestPermTab(app) orelse return;
        std.debug.print("selftest: page report {s}\n", .{w.page_title.items});
        std.debug.print("selftest: kept for the site: notifications={s}\n", .{@tagName(cfg_mod.get().siteDecision(selftest_perm_origin, .notifications))});
        std.debug.print("selftest: clicking the notification\n", .{});
        // Show another tab first: the click must bring the page's tab back.
        _ = app.tabs.openWith("terminal", .{}) catch {};
        notify.simulateClick(w.serial, 1, selftest_perm_origin);
    } else if (selftest_perm_step == 2 and t >= 11) {
        selftest_perm_step = 3;
        const w = selftestPermTab(app) orelse return;
        const cur = app.tabs.current();
        std.debug.print("selftest: page report {s}\n", .{w.page_title.items});
        std.debug.print("selftest: after the click the tab in front is the page's: {}\n", .{cur != null and cur.?.ptr == @as(*anyopaque, w)});

        // Camera and microphone: WebKit's decision block, answered by the bar.
        PermProbe.block = objc.Block.global(@ptrCast(&PermProbe.decided), @sizeOf(objc.Block));
        const blk: ?*anyopaque = @ptrCast(&PermProbe.block);
        w.ask("https://cam.selftest.example", .{ .camera = true, .microphone = true }, blk);
        std.debug.print("selftest: media asked → waiting={d} question='{s}'\n", .{ w.prompts.items.len, if (w.prompts.items.len > 0) w.prompts.items[0].question() else "" });
        w.answer(true, true);
        w.ask("https://cam.selftest.example", .{ .camera = true }, blk);
        w.ask("https://blocked.selftest.example", .{ .microphone = true }, blk);
        w.answer(false, true);
        w.ask("https://blocked.selftest.example", .{ .camera = true, .microphone = true }, blk);
        std.debug.print("selftest: media decisions (1 grant, 2 deny) = {d} {d} {d} {d} waiting={d}\n", .{ PermProbe.got[0], PermProbe.got[1], PermProbe.got[2], PermProbe.got[3], w.prompts.items.len });
        // A real getUserMedia (stand-in devices: TT_SELFTEST_MOCK_CAPTURE).
        if (sys.getenv("TT_SELFTEST_MOCK_CAPTURE") != null) w.evalPage("window.startGum && startGum()");
    } else if (selftest_perm_step == 3 and t >= 12.5) {
        selftest_perm_step = 4;
        const w = selftestPermTab(app) orelse return;
        std.debug.print("selftest: after getUserMedia: waiting={d}\n", .{w.prompts.items.len});
        if (w.prompts.items.len > 0) {
            const p = w.prompts.items[0];
            std.debug.print("selftest: bar asks: '{s}' {s} (WebKit's block: {})\n", .{ p.origin, p.question(), p.decide != null });
            if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-callask");
            w.answer(true, true);
        }
    } else if (selftest_perm_step == 4 and t >= 14) {
        selftest_perm_step = 5;
        const w = selftestPermTab(app) orelse return;
        std.debug.print("selftest: page report {s}\n", .{w.page_title.items});
        std.debug.print("selftest: capture state camera={d} microphone={d} (1 live, 2 muted)\n", .{ w.camera_state, w.mic_state });
        w.toggleCapture(true);
    } else if (selftest_perm_step == 5 and t >= 15) {
        selftest_perm_step = 6;
        const w = selftestPermTab(app) orelse return;
        std.debug.print("selftest: after muting the camera: camera={d} microphone={d}\n", .{ w.camera_state, w.mic_state });
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-call");
        // window.open from the page: a new tab that keeps its opener. Pages
        // may only do that from a click; the selftest lets this one.
        const view = w.view orelse return;
        const prefs = msg(id, msg(id, view, "configuration", .{}), "preferences", .{});
        msg(void, prefs, "setJavaScriptCanOpenWindowsAutomatically:", .{true});
        w.evalPage("window.open('/popup.html')");
    } else if (selftest_perm_step == 6 and t >= 16.5) {
        selftest_perm_step = 7;
        selftestListWebTabs(app, "after window.open");
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| selftestCaptureSuffixed(path, "-popup");
    } else if (selftest_perm_step == 7 and t >= 20) {
        selftest_perm_step = 8;
        selftestListWebTabs(app, "after window.close()");
        if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, 1 << 3);
        msg(void, g.nsapp, "terminate:", .{@as(id, null)});
    }
}

fn selftestListWebTabs(app: *app_mod.App, when: []const u8) void {
    var n: usize = 0;
    const cur = app.tabs.current();
    for (app.tabs.items()) |tab| {
        const w = WebTab.fromTab(tab) orelse continue;
        n += 1;
        std.debug.print("selftest: {s}: website tab url='{s}' title='{s}' front={}\n", .{ when, w.url.items, w.page_title.items, cur != null and cur.?.ptr == tab.ptr });
    }
    std.debug.print("selftest: {s}: website tabs={d}\n", .{ when, n });
}

/// TT_SELFTEST_WEBMENU=1 (with TT_SELFTEST_URL): what the website tab's
/// context menu would offer for the selection and link the page reported
/// (web_menu.zig), obtained by calling the view's menu hook on an empty
/// menu — the real menu is modal and would stall this timer. The first
/// entry is then picked the way a click would (its action on its target),
/// and the bridge's other direction is tried: `eval` posts back on the
/// selection channel, which shows under TT_DEBUG_EVENTS. Replaces the
/// palette steps; the report a second later says which tab is in front
/// and what its input box holds.
fn selftestWebMenu(app: *app_mod.App) void {
    const cur = app.tabs.current() orelse return;
    const w = WebTab.fromTab(cur) orelse {
        std.debug.print("selftest: the current tab is not a website tab\n", .{});
        return;
    };
    const view = w.view orelse return;
    std.debug.print("selftest: web selection='{s}' link='{s}'\n", .{ w.selection.items, w.link_url.items });
    const menu = objc.autorelease(msg(id, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString("")}));
    msg(void, view, "willOpenMenu:withEvent:", .{ menu, @as(id, null) });
    const n = msg(NSInteger, menu, "numberOfItems", .{});
    var i: NSInteger = 0;
    while (i < n) : (i += 1) {
        const item = msg(id, menu, "itemAtIndex:", .{i});
        const sep = msg(bool, item, "isSeparatorItem", .{});
        std.debug.print("selftest: menu[{d}] '{s}' tag={d}{s}\n", .{ i, objc.utf8(msg(id, item, "title", .{})), msg(NSInteger, item, "tag", .{}), if (sep) " (separator)" else "" });
    }
    if (n > 0) msg(void, view, "ttMenuAction:", .{msg(id, menu, "itemAtIndex:", .{@as(NSInteger, 0)})});
    w.eval("__tt.post('selection', { why: 'eval', text: 'posted from eval', link: '' })");
}

/// TT_SELFTEST_INSPECTOR=1 (with TT_SELFTEST_URL): the Web Inspector on
/// the page, opened through WebKit's private `_inspector` handle since the
/// context menu that offers "Inspect Element" is modal — `open` shows it,
/// `dock` attaches it below the page once its frontend is up, and `report`
/// lists what is in the hosted view's box: the page and the inspector, both
/// inside the box's bounds, the page shorter than the box. The frames are
/// in the box's own (bottom-left) coordinates. (`_WKInspector` has no
/// `isAttached`: whether it is docked shows in the box's subviews.)
const InspectorStep = enum { open, dock, report };

fn selftestInspector(app: *app_mod.App, step: InspectorStep) void {
    const cur = app.tabs.current() orelse return;
    const w = WebTab.fromTab(cur) orelse {
        std.debug.print("selftest: the current tab is not a website tab\n", .{});
        return;
    };
    const view = w.view orelse return;
    if (!msg(bool, view, "respondsToSelector:", .{objc.sel("_inspector")})) {
        std.debug.print("selftest: this WebKit has no _inspector\n", .{});
        return;
    }
    const inspector = msg(id, view, "_inspector", .{});
    if (inspector == null) {
        std.debug.print("selftest: _inspector is nil\n", .{});
        return;
    }
    switch (step) {
        .open => msg(void, inspector, "show", .{}),
        .dock => msg(void, inspector, "attach", .{}),
        .report => {},
    }
    std.debug.print("selftest: inspector {s}: connected={} visible={}\n", .{
        @tagName(step), msg(bool, inspector, "isConnected", .{}), msg(bool, inspector, "isVisible", .{}),
    });
    if (step != .report) return;
    const box = hostBox(view);
    const bounds = msg(CGRect, box, "bounds", .{});
    const box_frame = msg(CGRect, box, "frame", .{});
    std.debug.print("selftest: box frame=({d:.0},{d:.0} {d:.0}x{d:.0}) superview={s} window_on_screen={}\n", .{
        box_frame.origin.x, box_frame.origin.y, box_frame.size.width, box_frame.size.height,
        objc.utf8(msg(id, msg(id, msg(id, box, "superview", .{}), "class", .{}), "description", .{})), windowOnScreen(),
    });
    const subviews = msg(id, box, "subviews", .{});
    const n = msg(NSUInteger, subviews, "count", .{});
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) {
        const sub = msg(id, subviews, "objectAtIndex:", .{i});
        const f = msg(CGRect, sub, "frame", .{});
        const inside = f.origin.x >= 0 and f.origin.y >= 0 and f.origin.x + f.size.width <= bounds.size.width + 0.5 and f.origin.y + f.size.height <= bounds.size.height + 0.5;
        std.debug.print("selftest: box[{d}] {s} frame=({d:.0},{d:.0} {d:.0}x{d:.0}) inside={}{s}\n", .{
            i, objc.utf8(msg(id, msg(id, sub, "class", .{}), "description", .{})),
            f.origin.x, f.origin.y, f.size.width, f.size.height, inside, if (sub == view) " (the page)" else "",
        });
    }
    // Nothing of the inspector's may have landed in the window's own view.
    const top = msg(id, g.view, "subviews", .{});
    const m = msg(NSUInteger, top, "count", .{});
    std.debug.print("selftest: window view subviews={d} (boxes={d})\n", .{ m, hosted.items.len });
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

/// TT_SELFTEST_FULLSCREEN=1: after the regular steps, a round trip through
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
            if (sys.getenv("TT_SELFTEST_SNAP")) |path| app.snapshot(path) catch {};
            // Anything AppKit layers above the view (a toolbar window) must
            // show in the picture, so windows above ours are included.
            if (sys.getenv("TT_SELFTEST_WINDOW_PNG")) |path| captureOwnWindow(path, (1 << 3) | (1 << 1));
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

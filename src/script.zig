//! Headless UI driver used for testing: runs the real app core (real shell,
//! real layout, real Metal rendering into an offscreen texture) from a small
//! script and writes PNG snapshots. No window is created.
//!
//!   size 1440 900          set the surface size in points
//!   wait 300               pump the app for N ms
//!   settle 5000            pump until the active tab is idle (max N ms)
//!   type echo hello        insert text
//!   key enter              enter, tab, up, down, left, right, backspace, escape,
//!                          home, end, shift-enter, backtab, word-left, word-right,
//!                          select-all
//!   ctrl c                 control chord
//!   move 100 200 / click 100 200 [count] [cmd|ctrl|shift|alt …] / down X Y / up X Y
//!                          (`click X Y ctrl` is a ⌃-click: a secondary click, or a
//!                          link's; a link opened in the default browser prints
//!                          `browser → …`)
//!   mods cmd               hold modifiers from now on (none: `mods`), as a
//!                          flagsChanged would: ⌘ / ⌃ over a link shows the hand
//!   alt c 2 3              hold ⌥ and press these keys (a ⌥ jump, `jump.zig`;
//!                          `-` is a key that is neither letter nor digit);
//!                          ⌥ stays down until `mods`. Prints what each key did
//!                          and the row on show: `alt c → jump group=3 tab='zsh'`
//!   rclick 100 200         secondary click (opens context menus)
//!   drag 300 400 420 400   press, move in steps, release
//!   scroll 700 400 -120 0  wheel delta at a position (vertical, then horizontal)
//!   action new_tab         any App.Action
//!   project /path          add a folder as a project
//!   open /path/file        open a file in a viewer tab
//!   cli /path              what `tt /path` does (`App.openPath`): a folder or a
//!                          file, in the default project. Paths after the script
//!                          on the command line open the same way before line 1,
//!                          and with `TT_SOCKET=<file>` set the run also takes the
//!                          paths of a `tt <path>` started with the same variable
//!   web https://…          open a website tab (no web view headless: the chrome only)
//!   web_ask camera https://meet.example   the website tab on show asks (camera,
//!                          microphone, both, notifications): the bar under the
//!                          address bar appears unless the settings answer it
//!   web_capture 1 2        the page's camera / microphone state (0 off, 1 live,
//!                          2 muted): the indicators in the address field
//!   screen Paper | Desk    the connected displays, by name; the window is on the
//!                          first one (Settings › Style › Per screen). No name = none known
//!   paste some text        (as ⌘V would; what the app copies is printed as
//!                          `clipboard → …` and is what the edit menu's Paste gives)
//!   files                  print the folder the files panel shows
//!   tabs                   print every group that has tabs, one per line, its tabs
//!                          pane by pane (`*` is the one in front of its pane):
//!                          `tabs: group=3 shown: 'zsh' *'notes.md'`. A separate
//!                          window's reads `tabs: window=1 key at 1500,200 900x620: …`
//!                          (`key`: the window with the keyboard)
//!   window 1               the pointer commands, `snap` and the keyboard go to
//!                          separate window 1 from now on (0: the main window).
//!                          Windows are numbered as they are made. A tab dragged
//!                          to a point outside the window (`drag 355 26 1500 300`)
//!                          gets one; `window → 1` is printed when it does, and
//!                          `key → window 1` / `key → main` when the app moves
//!                          the keyboard on its own
//!   close_window           what the close button of the separate window chosen
//!                          with `window N` does: its tabs close with it, after
//!                          a question when one of them is busy
//!   frame 0 100 50 1200 700   where a window is on screen (0: the main one):
//!                          x y of its top-left corner, then its size. What a
//!                          tab let go outside its window lands on goes by these
//!   snap /path/out.png
const std = @import("std");
const app_mod = @import("app.zig");
const appearance = @import("appearance.zig");
const apple = @import("apple.zig");
const sys = @import("sys.zig");
const EditCommand = @import("events.zig").EditCommand;
const ui_mod = @import("ui/ui.zig");
const WebTab = @import("tabs/web_tab.zig").WebTab;

/// What the app puts on the clipboard is printed instead (there is no
/// pasteboard to check headless), and kept for the edit menu's Paste.
var clipboard: std.ArrayList(u8) = .empty;

fn printClipboard(text: []const u8) void {
    std.debug.print("clipboard → {s}\n", .{text});
    clipboard.clearRetainingCapacity();
    clipboard.appendSlice(std.heap.page_allocator, text) catch {};
}

/// A link opened in the default browser is printed instead.
fn printBrowser(url: []const u8) bool {
    std.debug.print("browser → {s}\n", .{url});
    return true;
}

fn scriptClipboard(gpa: std.mem.Allocator) ?[]u8 {
    if (clipboard.items.len == 0) return null;
    return gpa.dupe(u8, clipboard.items) catch null;
}

fn pump(app: *app_mod.App, ms: f64) void {
    const t0 = apple.CACurrentMediaTime();
    while ((apple.CACurrentMediaTime() - t0) * 1000 < ms) {
        if (app.update(apple.CACurrentMediaTime())) {
            app.buildFrame();
            // By index: a frame can open a window (a tab let go outside).
            var i: usize = 0;
            while (i < app.windows.items.len) : (i += 1) app.buildWindowFrame(app.windows.items[i]);
        }
        standInForPlatform(app);
        _ = sys.usleep(4000);
    }
}

/// The separate window the pointer commands and `snap` address (`window N`);
/// 0 is the main window.
var target_window: u32 = 0;
/// Separate windows seen so far, to say when one opens.
var windows_seen: u32 = 0;

const TabManager = @TypeOf(@as(app_mod.App, undefined).tabs);

/// A separate window's number: 1 for the first one made.
fn windowNumber(group: u32) u32 {
    return group - TabManager.window_group_base + 1;
}

/// The window `window N` chose, while it exists (null: the main one).
fn targetWindow(app: *app_mod.App) ?*@TypeOf(app.windows.items[0].*) {
    if (target_window == 0) return null;
    return app.windowByGroup(TabManager.window_group_base + target_window - 1);
}

/// What the platform layer does for the app's windows, as far as a run
/// with no real ones can: a new window is where the app asked, and a
/// window the app wants in front gets the keyboard.
fn standInForPlatform(app: *app_mod.App) void {
    for (app.windows.items) |w| {
        w.place = null;
        const n = windowNumber(w.group);
        if (n > windows_seen) {
            windows_seen = n;
            std.debug.print("window → {d}\n", .{n});
        }
    }
    if (app.takeRaise()) |r| switch (r) {
        .main => {
            app.onWindowKey(null);
            std.debug.print("key → main\n", .{});
        },
        .window => |w| {
            app.onWindowKey(w.group);
            std.debug.print("key → window {d}\n", .{windowNumber(w.group)});
        },
    };
}

fn settle(app: *app_mod.App, max_ms: f64) void {
    const t0 = apple.CACurrentMediaTime();
    pump(app, 120);
    while ((apple.CACurrentMediaTime() - t0) * 1000 < max_ms) {
        const t = app.tabs.current() orelse break;
        if (t.vtable.status(t.ptr) != .running) break;
        pump(app, 30);
    }
    pump(app, 80);
}

/// Modifier words ("cmd", "ctrl", "shift", "alt") among the rest of a command.
fn modsOf(it: *std.mem.TokenIterator(u8, .scalar), count: *u32) ui_mod.Mods {
    var m: ui_mod.Mods = .{};
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "cmd")) m.cmd = true else if (std.mem.eql(u8, w, "ctrl")) m.ctrl = true else if (std.mem.eql(u8, w, "shift")) m.shift = true else if (std.mem.eql(u8, w, "alt")) m.alt = true else if (std.fmt.parseInt(u32, w, 10)) |n| {
            count.* = @max(1, n);
        } else |_| {}
    }
    return m;
}

fn num(it: *std.mem.TokenIterator(u8, .scalar)) f32 {
    return std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
}

/// `tabs`: where every tab is.
fn printTabs(app: *app_mod.App) void {
    for (app.tabs.groups.items) |*g| {
        if (g.count() == 0) continue;
        const key = if (app.tabs.groupId() == g.id) " key" else "";
        if (TabManager.isWindowGroup(g.id)) {
            std.debug.print("tabs: window={d}{s}", .{ windowNumber(g.id), key });
            if (app.windowByGroup(g.id)) |w| if (w.frame) |f| {
                std.debug.print(" at {d},{d} {d}x{d}", .{ f.x, f.y, f.w, f.h });
            };
            std.debug.print(":", .{});
        } else {
            std.debug.print("tabs: group={d}{s}{s}:", .{ g.id, if (g.id == app.tabs.shown) " shown" else "", key });
        }
        const panes = g.layout.panes();
        for (panes.slice(), 0..) |p, pi| {
            if (pi > 0) std.debug.print(" |", .{});
            for (p.tabs.items, 0..) |t, i| {
                var buf: [96]u8 = undefined;
                std.debug.print(" {s}'{s}'", .{ if (i == p.active) "*" else "", t.title(&buf) });
            }
        }
        std.debug.print("\n", .{});
    }
}

pub fn runHeadless(gpa: std.mem.Allocator, opts: app_mod.LaunchOptions) !void {
    const path = opts.script_path orelse return error.NoScript;
    const source = try sys.readFileTail(gpa, path, 1 << 20);
    defer gpa.free(source);

    const app = try app_mod.App.create(gpa, opts, null, printClipboard);
    defer app.destroy();
    app.env.getClipboard = scriptClipboard;
    app.open_external = printBrowser;
    app.chrome = .{ .inset_left = 79, .fake_lights = true };
    pump(app, 50);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const cmd = line[0..sp];
        const rest = std.mem.trim(u8, line[sp..], " ");
        var args = std.mem.tokenizeScalar(u8, rest, ' ');

        if (std.mem.eql(u8, cmd, "size")) {
            const w = num(&args);
            const h = num(&args);
            app.resize(w, h, opts.scale);
        } else if (std.mem.eql(u8, cmd, "wait")) {
            pump(app, num(&args));
        } else if (std.mem.eql(u8, cmd, "settle")) {
            settle(app, num(&args));
        } else if (std.mem.eql(u8, cmd, "type")) {
            app.onText(rest);
        } else if (std.mem.eql(u8, cmd, "paste")) {
            app.onPaste(rest);
        } else if (std.mem.eql(u8, cmd, "key")) {
            const map = [_]struct { n: []const u8, c: EditCommand }{
                .{ .n = "enter", .c = .insert_newline },              .{ .n = "tab", .c = .insert_tab },
                .{ .n = "up", .c = .move_up },                        .{ .n = "down", .c = .move_down },
                .{ .n = "left", .c = .move_left },                    .{ .n = "right", .c = .move_right },
                .{ .n = "backspace", .c = .delete_backward },         .{ .n = "escape", .c = .cancel },
                .{ .n = "home", .c = .move_line_start },              .{ .n = "end", .c = .move_line_end },
                .{ .n = "shift-enter", .c = .insert_line_break },     .{ .n = "word-left", .c = .move_word_left },
                .{ .n = "word-right", .c = .move_word_right },        .{ .n = "select-all", .c = .select_all },
                .{ .n = "select-word-left", .c = .select_word_left }, .{ .n = "backtab", .c = .insert_backtab },
            };
            for (map) |m| {
                if (std.mem.eql(u8, m.n, rest)) app.onEdit(m.c);
            }
        } else if (std.mem.eql(u8, cmd, "ctrl")) {
            if (rest.len > 0) app.onCtrl(rest[0]);
        } else if (std.mem.eql(u8, cmd, "move")) {
            const x = num(&args);
            const y = num(&args);
            app.pointerMove(targetWindow(app), x, y);
        } else if (std.mem.eql(u8, cmd, "down")) {
            const x = num(&args);
            const y = num(&args);
            app.pointerDown(targetWindow(app), x, y, 1, .{});
        } else if (std.mem.eql(u8, cmd, "up")) {
            const x = num(&args);
            const y = num(&args);
            app.pointerUp(targetWindow(app), x, y);
        } else if (std.mem.eql(u8, cmd, "click")) {
            const x = num(&args);
            const y = num(&args);
            var count: u32 = 1;
            const mods = modsOf(&args, &count);
            app.pointerMove(targetWindow(app), x, y);
            pump(app, 30);
            app.pointerDown(targetWindow(app), x, y, count, mods);
            pump(app, 30);
            app.pointerUp(targetWindow(app), x, y);
        } else if (std.mem.eql(u8, cmd, "mods")) {
            var count: u32 = 1;
            app.onFlags(modsOf(&args, &count));
        } else if (std.mem.eql(u8, cmd, "alt")) {
            if (!app.ui.mods.alt) app.onFlags(.{ .alt = true });
            while (args.next()) |k| {
                const c: u8 = if (k.len == 1 and std.ascii.isAlphanumeric(k[0])) k[0] else 0;
                const took = app.onAltKey(c);
                pump(app, 30);
                var title_buf: [96]u8 = undefined;
                const cur = app.tabs.current();
                std.debug.print("alt {s} → {s} group={d} tab='{s}'\n", .{
                    k,                  if (took) "jump" else "typed",
                    app.tabs.groupId(), if (cur) |t| t.title(&title_buf) else "(none)",
                });
            }
        } else if (std.mem.eql(u8, cmd, "rclick")) {
            const x = num(&args);
            const y = num(&args);
            app.pointerMove(targetWindow(app), x, y);
            pump(app, 30);
            app.pointerRightDown(targetWindow(app), x, y, .{});
        } else if (std.mem.eql(u8, cmd, "drag")) {
            const x0 = num(&args);
            const y0 = num(&args);
            const x1 = num(&args);
            const y1 = num(&args);
            app.pointerMove(targetWindow(app), x0, y0);
            pump(app, 30);
            app.pointerDown(targetWindow(app), x0, y0, 1, .{});
            pump(app, 30);
            var i: f32 = 1;
            while (i <= 8) : (i += 1) {
                app.pointerMove(targetWindow(app), x0 + (x1 - x0) * i / 8, y0 + (y1 - y0) * i / 8);
                pump(app, 20);
            }
            app.pointerUp(targetWindow(app), x1, y1);
        } else if (std.mem.eql(u8, cmd, "scroll")) {
            const x = num(&args);
            const y = num(&args);
            const dy = num(&args);
            const dx = num(&args);
            app.pointerScroll(targetWindow(app), x, y, dx, dy);
        } else if (std.mem.eql(u8, cmd, "copy")) {
            if (app.onCopy(false)) |copied| {
                defer gpa.free(copied);
                std.debug.print("copied: «{s}»\n", .{copied});
            } else std.debug.print("copied: (nothing)\n", .{});
        } else if (std.mem.eql(u8, cmd, "action")) {
            if (std.meta.stringToEnum(app_mod.Action, rest)) |a| app.perform(a);
        } else if (std.mem.eql(u8, cmd, "project")) {
            app.addProject(rest);
        } else if (std.mem.eql(u8, cmd, "open")) {
            app.openFile(rest);
        } else if (std.mem.eql(u8, cmd, "cli")) {
            app.openPath(rest);
        } else if (std.mem.eql(u8, cmd, "web")) {
            _ = app.tabs.openWith("web", .{ .url = if (rest.len > 0) rest else null }) catch |err| {
                std.debug.print("script: could not open a website tab: {s}\n", .{@errorName(err)});
            };
        } else if (std.mem.eql(u8, cmd, "web_ask") or std.mem.eql(u8, cmd, "web_capture")) {
            const cur = app.tabs.current() orelse continue;
            const w = WebTab.fromTab(cur) orelse {
                std.debug.print("script: {s}: the tab on show is not a website tab\n", .{cmd});
                continue;
            };
            var words = std.mem.tokenizeScalar(u8, rest, ' ');
            const a = words.next() orelse "";
            const b = words.next() orelse "";
            if (std.mem.eql(u8, cmd, "web_ask")) {
                const both = std.mem.eql(u8, a, "both");
                w.ask(b, .{
                    .camera = both or std.mem.eql(u8, a, "camera"),
                    .microphone = both or std.mem.eql(u8, a, "microphone"),
                    .notifications = std.mem.eql(u8, a, "notifications"),
                }, null);
                std.debug.print("script: web_ask {s} {s} → {d} waiting\n", .{ a, b, w.prompts.items.len });
            } else {
                w.camera_state = std.fmt.parseInt(c_long, a, 10) catch 0;
                w.mic_state = std.fmt.parseInt(c_long, b, 10) catch 0;
            }
            app.invalidate();
        } else if (std.mem.eql(u8, cmd, "screen")) {
            var names_buf: [16][]const u8 = undefined;
            var n: usize = 0;
            var parts = std.mem.splitSequence(u8, rest, "|");
            while (parts.next()) |part| {
                const name = std.mem.trim(u8, part, " \t");
                if (name.len == 0 or n == names_buf.len) continue;
                names_buf[n] = name;
                n += 1;
            }
            appearance.setScreens(gpa, names_buf[0..n], if (n > 0) 0 else null);
            app.invalidate();
        } else if (std.mem.eql(u8, cmd, "files")) {
            std.debug.print("files: root={s}\n", .{app.files.rootPath()});
        } else if (std.mem.eql(u8, cmd, "tabs")) {
            printTabs(app);
        } else if (std.mem.eql(u8, cmd, "window")) {
            target_window = @intFromFloat(num(&args));
            if (targetWindow(app)) |w| {
                app.onWindowKey(w.group);
            } else {
                if (target_window != 0) std.debug.print("script: no window {d}\n", .{target_window});
                target_window = 0;
                app.onWindowKey(null);
            }
        } else if (std.mem.eql(u8, cmd, "close_window")) {
            if (targetWindow(app)) |w| app.closeWindow(w) else std.debug.print("script: the main window does not close\n", .{});
        } else if (std.mem.eql(u8, cmd, "frame")) {
            const n: u32 = @intFromFloat(num(&args));
            const f: @TypeOf(app.main_frame.?) = .{ .x = num(&args), .y = num(&args), .w = num(&args), .h = num(&args) };
            if (n == 0) {
                app.main_frame = f;
            } else if (app.windowByGroup(TabManager.window_group_base + n - 1)) |w| {
                w.frame = f;
                _ = w.resize(f.w, f.h, w.raw_scale, app.zoom);
            } else std.debug.print("script: no window {d}\n", .{n});
            app.invalidate();
        } else if (std.mem.eql(u8, cmd, "snap")) {
            pump(app, 40);
            (if (targetWindow(app)) |w| app.snapshotWindow(w, rest) else app.snapshot(rest)) catch |err| std.debug.print("snap failed: {s}\n", .{@errorName(err)});
            std.debug.print("snapshot → {s}\n", .{rest});
        } else {
            std.debug.print("script: unknown command '{s}'\n", .{cmd});
        }
        pump(app, 30);
    }
}

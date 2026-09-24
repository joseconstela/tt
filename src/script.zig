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
//!   rclick 100 200         secondary click (opens context menus)
//!   drag 300 400 420 400   press, move in steps, release
//!   scroll 700 400 -120 0  wheel delta at a position (vertical, then horizontal)
//!   action new_tab         any App.Action
//!   project /path          add a folder as a project
//!   open /path/file        open a file in a viewer tab
//!   web https://…          open a website tab (no web view headless: the chrome only)
//!   web_ask camera https://meet.example   the website tab on show asks (camera,
//!                          microphone, both, notifications): the bar under the
//!                          address bar appears unless the settings answer it
//!   web_capture 1 2        the page's camera / microphone state (0 off, 1 live,
//!                          2 muted): the indicators in the address field
//!   screen Paper | Desk    the connected displays, by name; the window is on the
//!                          first one (Settings › Style › Per screen). No name = none known
//!   camera /path/face.jpg  a still image stands in for the camera from now on (as
//!                          TT_CAMERA_MOCK does; headless runs never use a real one);
//!                          no path = no frames. The away blur prints `blur → on|off`
//!   posture                print what the camera controller recognises now
//!   hear tt, open the files   one utterance, as if the speech recogniser had
//!                          heard it (headless runs never listen); the voice
//!                          page shows it and the trigger is looked for
//!   voice                  print what the voice controller heard and understood
//!   paste some text        (as ⌘V would; what the app copies is printed as
//!                          `clipboard → …` and is what the edit menu's Paste gives)
//!   snap /path/out.png
const std = @import("std");
const app_mod = @import("app.zig");
const appearance = @import("appearance.zig");
const apple = @import("apple.zig");
const sys = @import("sys.zig");
const EditCommand = @import("events.zig").EditCommand;
const ui_mod = @import("ui/ui.zig");
const WebTab = @import("tabs/web_tab.zig").WebTab;
const camera = @import("platform/camera.zig");
const camera_controller = @import("physical/camera_controller.zig");
const voice_controller = @import("physical/voice_controller.zig");

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

/// The away blur as last printed (there is no window to blur headless).
var blur_printed = false;

fn pump(app: *app_mod.App, ms: f64) void {
    const t0 = apple.CACurrentMediaTime();
    while ((apple.CACurrentMediaTime() - t0) * 1000 < ms) {
        if (app.update(apple.CACurrentMediaTime())) app.buildFrame();
        const blurred = camera_controller.get().blurred;
        if (blurred != blur_printed) {
            blur_printed = blurred;
            std.debug.print("blur → {s}\n", .{if (blurred) "on" else "off"});
        }
        _ = sys.usleep(4000);
    }
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

pub fn runHeadless(gpa: std.mem.Allocator, opts: app_mod.LaunchOptions) !void {
    const path = opts.script_path orelse return error.NoScript;
    const source = try sys.readFileTail(gpa, path, 1 << 20);
    defer gpa.free(source);

    // Tests never light the camera: only a still image stands in (`camera`).
    camera_controller.get().allow_device = false;
    // … nor listen: `hear` stands in for the recogniser.
    voice_controller.get().allow_device = false;
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
            app.onMouseMove(x, y);
        } else if (std.mem.eql(u8, cmd, "down")) {
            const x = num(&args);
            const y = num(&args);
            app.onMouseDown(x, y, 1, .{});
        } else if (std.mem.eql(u8, cmd, "up")) {
            const x = num(&args);
            const y = num(&args);
            app.onMouseUp(x, y);
        } else if (std.mem.eql(u8, cmd, "click")) {
            const x = num(&args);
            const y = num(&args);
            var count: u32 = 1;
            const mods = modsOf(&args, &count);
            app.onMouseMove(x, y);
            pump(app, 30);
            app.onMouseDown(x, y, count, mods);
            pump(app, 30);
            app.onMouseUp(x, y);
        } else if (std.mem.eql(u8, cmd, "mods")) {
            var count: u32 = 1;
            app.onFlags(modsOf(&args, &count));
        } else if (std.mem.eql(u8, cmd, "rclick")) {
            const x = num(&args);
            const y = num(&args);
            app.onMouseMove(x, y);
            pump(app, 30);
            app.onRightMouseDown(x, y, .{});
        } else if (std.mem.eql(u8, cmd, "drag")) {
            const x0 = num(&args);
            const y0 = num(&args);
            const x1 = num(&args);
            const y1 = num(&args);
            app.onMouseMove(x0, y0);
            pump(app, 30);
            app.onMouseDown(x0, y0, 1, .{});
            pump(app, 30);
            var i: f32 = 1;
            while (i <= 8) : (i += 1) {
                app.onMouseMove(x0 + (x1 - x0) * i / 8, y0 + (y1 - y0) * i / 8);
                pump(app, 20);
            }
            app.onMouseUp(x1, y1);
        } else if (std.mem.eql(u8, cmd, "scroll")) {
            const x = num(&args);
            const y = num(&args);
            const dy = num(&args);
            const dx = num(&args);
            app.onScroll(x, y, dx, dy);
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
        } else if (std.mem.eql(u8, cmd, "camera")) {
            camera.setMock(rest);
            std.debug.print("script: camera → {s}\n", .{if (rest.len > 0) rest else "(no frames)"});
        } else if (std.mem.eql(u8, cmd, "posture")) {
            const ctl = camera_controller.get();
            const p = ctl.posture;
            std.debug.print("posture: status={s} frames={d} faces={d} gaze={s} stance={s} yaw={d:.1} pitch={d:.1} roll={d:.1} blurred={}\n", .{
                @tagName(ctl.status), ctl.obs.seq, ctl.obs.faces, @tagName(p.gaze), @tagName(p.stance),
                p.yaw orelse 0, p.pitch orelse 0, p.roll orelse 0, ctl.blurred,
            });
        } else if (std.mem.eql(u8, cmd, "hear")) {
            voice_controller.get().hear(rest, apple.CACurrentMediaTime());
            app.invalidate();
        } else if (std.mem.eql(u8, cmd, "voice")) {
            const vc = voice_controller.get();
            std.debug.print("voice: status={s} trigger='{s}' heard='{s}' matches={d} triggers={d} command='{s}' history={d}\n", .{
                @tagName(vc.status), vc.triggerWord(), vc.current.slice(), vc.matches.len, vc.trigger_seq, vc.command(), vc.history_count,
            });
        } else if (std.mem.eql(u8, cmd, "snap")) {
            pump(app, 40);
            app.snapshot(rest) catch |err| std.debug.print("snap failed: {s}\n", .{@errorName(err)});
            std.debug.print("snapshot → {s}\n", .{rest});
        } else {
            std.debug.print("script: unknown command '{s}'\n", .{cmd});
        }
        pump(app, 30);
    }
}

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
//!   move 100 200 / click 100 200 [count] / down X Y / up X Y
//!   rclick 100 200         secondary click (opens context menus)
//!   drag 300 400 420 400   press, move in steps, release
//!   scroll 700 400 -120 0  wheel delta at a position (vertical, then horizontal)
//!   action new_tab         any App.Action
//!   project /path          add a folder as a project
//!   open /path/file        open a file in a viewer tab
//!   web https://…          open a website tab (no web view headless: the chrome only)
//!   paste some text
//!   snap /path/out.png
const std = @import("std");
const app_mod = @import("app.zig");
const apple = @import("apple.zig");
const sys = @import("sys.zig");
const EditCommand = @import("events.zig").EditCommand;

/// What the app puts on the clipboard is printed instead (there is no
/// pasteboard to check headless).
fn printClipboard(text: []const u8) void {
    std.debug.print("clipboard → {s}\n", .{text});
}

fn pump(app: *app_mod.App, ms: f64) void {
    const t0 = apple.CACurrentMediaTime();
    while ((apple.CACurrentMediaTime() - t0) * 1000 < ms) {
        if (app.update(apple.CACurrentMediaTime())) app.buildFrame();
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

fn num(it: *std.mem.TokenIterator(u8, .scalar)) f32 {
    return std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
}

pub fn runHeadless(gpa: std.mem.Allocator, opts: app_mod.LaunchOptions) !void {
    const path = opts.script_path orelse return error.NoScript;
    const source = try sys.readFileTail(gpa, path, 1 << 20);
    defer gpa.free(source);

    const app = try app_mod.App.create(gpa, opts, null, printClipboard);
    defer app.destroy();
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
            const count: u32 = @intFromFloat(@max(1, num(&args)));
            app.onMouseMove(x, y);
            pump(app, 30);
            app.onMouseDown(x, y, count, .{});
            pump(app, 30);
            app.onMouseUp(x, y);
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

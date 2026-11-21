const std = @import("std");
const sys = @import("sys.zig");
const apple = @import("apple.zig");
const cli = @import("cli.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\tt — a calm, block-based terminal for macOS (Zig + Metal)
    \\
    \\usage: tt [options] [path...]
    \\  <path>                  open a folder (a shell in it) or a file in the default
    \\                          project; a tt that is already running takes it over
    \\  --foreground            be the app in this process: hand nothing to a running
    \\                          tt and stay attached to the terminal
    \\  --probe <cmd>...        run commands headlessly and print the captured blocks
    \\  --script <file>         drive the UI from a script (testing; see src/script.zig)
    \\  --size <W>x<H>          window / snapshot size in points (default 1440x900)
    \\  --scale <n>             snapshot backing scale (default 2)
    \\  --help
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var probe_cmds: std.ArrayList([]const u8) = .empty;
    var opts: @import("app.zig").LaunchOptions = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var foreground = false;
    var only_paths = false;
    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (std.c.getcwd(&cwd_buf, cwd_buf.len) != null) std.mem.sliceTo(&cwd_buf, 0) else "/";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (only_paths or a.len == 0 or a[0] != '-') {
            try paths.append(gpa, try cli.absolute(gpa, cwd, a));
        } else if (std.mem.eql(u8, a, "--")) {
            only_paths = true;
        } else if (std.mem.eql(u8, a, "--foreground")) {
            foreground = true;
        } else if (std.mem.startsWith(u8, a, "-NS") or std.mem.startsWith(u8, a, "-Apple")) {
            // A Cocoa default (`-NSApplicationShowExceptions YES`): AppKit
            // reads it, and its value is not a path.
            i += 1;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, a, "--probe")) {
            while (i + 1 < args.len) {
                i += 1;
                try probe_cmds.append(gpa, args[i]);
            }
        } else if (std.mem.eql(u8, a, "--script") and i + 1 < args.len) {
            i += 1;
            opts.script_path = args[i];
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], 'x');
            opts.width = std.fmt.parseFloat(f32, it.next() orelse "1440") catch 1440;
            opts.height = std.fmt.parseFloat(f32, it.next() orelse "900") catch 900;
        } else if (std.mem.eql(u8, a, "--scale") and i + 1 < args.len) {
            i += 1;
            opts.scale = std.fmt.parseFloat(f32, args[i]) catch 2;
        }
    }

    if (probe_cmds.items.len > 0) return probe(gpa, probe_cmds.items);

    opts.open_paths = paths.items;
    if (opts.script_path != null) {
        return @import("script.zig").runHeadless(gpa, opts);
    }
    if (paths.items.len > 0 and !foreground) {
        var sock_buf: [256]u8 = undefined;
        if (cli.socketPath(&sock_buf)) |sock| {
            if (cli.send(sock, paths.items)) return;
        }
        // Nobody to hand them to: become the app, away from the terminal.
        cli.detach(gpa, args[1..]);
    }
    return @import("platform/cocoa.zig").run(gpa, opts);
}

/// Headless smoke test for the PTY + shell-integration pipeline.
fn probe(gpa: std.mem.Allocator, cmds: []const []const u8) !void {
    const Session = @import("term/session.zig").Session;
    const integration = @import("term/shell_integration.zig");

    const dir = try integration.install(gpa);
    defer gpa.free(dir);
    var cwd_buf: [4096]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) return error.NoCwd;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);

    const s = try Session.start(gpa, .{
        .integration_dir = dir,
        .user_zdotdir = sys.getenv("ZDOTDIR") orelse sys.home(),
        .cwd = cwd,
    });
    defer s.deinit();
    for (cmds) |c| s.submit(c);

    const t0 = apple.CACurrentMediaTime();
    while (apple.CACurrentMediaTime() - t0 < 20) {
        _ = s.poll(apple.CACurrentMediaTime());
        const all_done = s.phase == .idle and !s.working();
        if (all_done or s.phase == .exited) break;
        _ = sys.usleep(5_000);
    }

    std.debug.print("phase={s} cwd={s} branch={s}\n", .{ @tagName(s.phase), s.cwd.items, s.branch.items });
    for (s.blocks.items) |b| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try b.buf.appendText(&out, gpa);
        std.debug.print("── $ {s}  [{s} exit={d} {d:.2}s alt={}]\n{s}\n", .{
            b.command, @tagName(b.state), b.exit_code, b.duration(s.now), b.used_alt_screen, out.items,
        });
    }
}

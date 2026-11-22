//! The architecture check: reads every `@import` under `src/` and fails
//! when one crosses a boundary the directory tree stands for. `zig build
//! test` (and `zig build arch`) runs it, so a wrong import never lands.
//! Each failure says which file to import instead, or where the code
//! belongs: the message is the instruction.
//!
//! The rules, for a feature `features/X/`:
//!   1. From outside it, only `features/X/X.zig` (its public surface) may
//!      be imported; that covers another feature reaching into it too.
//!   2. Framework code (`framework_dirs`, `framework_files`) imports no
//!      feature and not `app.zig`.
//!   3. `model/` imports `std` and its own `model/` only.
//!   4. `view/` imports neither `sys.zig`, `http.zig` nor its `client/`.
//!   5. `client/` imports its own `model/`, `client/` and `hosts.zig` only.
//! `entry/` and the files at a feature's root are where the layers meet
//! and may import any of them.
//!
//!   arch_check <path to src>
const std = @import("std");
const sys = @import("sys");

/// Folders whose every file is framework: what features are built on.
const framework_dirs = [_][]const u8{ "gfx/", "input/", "term/", "syntax/" };
/// Framework files in folders that also hold app-level code. The panels
/// and bars in `ui/` (files, sidebar, palette, tab bar …) are not listed:
/// they are app code that mounts features.
const framework_files = [_][]const u8{
    "sys.zig",
    "objc.zig",
    "apple.zig",
    "http.zig",
    "tabs/tab.zig",
    "ui/ui.zig",
    "ui/theme.zig",
    "ui/themes.zig",
    "ui/field.zig",
    "ui/wrap.zig",
    "ui/overlay.zig",
    "ui/icon_spec.zig",
};

const Layer = enum { model, view, client, entry, root };

/// Where a `src`-relative path sits inside a feature.
const Place = struct { feature: []const u8, layer: Layer };

fn place(path: []const u8) ?Place {
    const prefix = "features/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const inside = rest[slash + 1 ..];
    const layer: Layer = if (std.mem.startsWith(u8, inside, "model/"))
        .model
    else if (std.mem.startsWith(u8, inside, "view/"))
        .view
    else if (std.mem.startsWith(u8, inside, "client/"))
        .client
    else if (std.mem.startsWith(u8, inside, "entry/"))
        .entry
    else
        .root;
    return .{ .feature = rest[0..slash], .layer = layer };
}

fn isFramework(path: []const u8) bool {
    for (framework_dirs) |d| if (std.mem.startsWith(u8, path, d)) return true;
    for (framework_files) |f| if (std.mem.eql(u8, path, f)) return true;
    return false;
}

/// The `src`-relative path an import written in `importer` names; null
/// when it leaves `src`.
fn resolve(importer: []const u8, import: []const u8, buf: []u8) ?[]const u8 {
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    const dir_end = std.mem.lastIndexOfScalar(u8, importer, '/') orelse 0;
    var own = std.mem.tokenizeScalar(u8, importer[0..dir_end], '/');
    while (own.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    var theirs = std.mem.tokenizeScalar(u8, import, '/');
    while (theirs.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (n == 0) return null;
            n -= 1;
            continue;
        }
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    var len: usize = 0;
    for (parts[0..n], 0..) |p, i| {
        const sep: usize = if (i > 0) 1 else 0;
        if (len + sep + p.len > buf.len) return null;
        if (sep == 1) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    return buf[0..len];
}

/// What is wrong with `importer` (a `src`-relative path) importing
/// `import` (the string as written), or null when nothing is. The message
/// is owned by the caller.
pub fn check(gpa: std.mem.Allocator, importer: []const u8, import: []const u8) !?[]u8 {
    const from = place(importer);

    if (!std.mem.endsWith(u8, import, ".zig")) {
        const f = from orelse return null;
        if (f.layer != .model) return null;
        if (std.mem.eql(u8, import, "std") or std.mem.eql(u8, import, "builtin")) return null;
        return try std.fmt.allocPrint(gpa,
            \\imports the module "{s}"
            \\  model/ is data and parsing only: it imports `std` and files of its own model/ folder.
            \\  Move what needs "{s}" to client/ (if it reaches outside) or view/ (if it draws), and keep the data here.
        , .{ import, import });
    }

    var buf: [1024]u8 = undefined;
    const target = resolve(importer, import, &buf) orelse return null;
    const to = place(target);
    const same_feature = if (from) |f| (if (to) |t| std.mem.eql(u8, f.feature, t.feature) else false) else false;

    if (to) |t| {
        if (!same_feature) {
            var public_buf: [256]u8 = undefined;
            const public = std.fmt.bufPrint(&public_buf, "features/{s}/{s}.zig", .{ t.feature, t.feature }) catch return null;
            if (!std.mem.eql(u8, target, public)) {
                return try std.fmt.allocPrint(gpa,
                    \\imports {s}
                    \\  Code outside features/{s}/ may only import its public file.
                    \\  Import {s} and use what it exports; if what you need is not there, export it there.
                , .{ target, t.feature, public });
            }
        }
    }

    if (isFramework(importer) and (to != null or std.mem.eql(u8, target, "app.zig"))) {
        return try std.fmt.allocPrint(gpa,
            \\imports {s}
            \\  {s} is framework code: features and the app are built on it, so it cannot depend on them.
            \\  Take what it needs as an argument or an interface (as `Env` does in tabs/tab.zig), or move this code into the feature that needs it.
        , .{ target, importer });
    }

    const f = from orelse return null;
    switch (f.layer) {
        .model => {
            if (same_feature and to.?.layer == .model) return null;
            return try std.fmt.allocPrint(gpa,
                \\imports {s}
                \\  model/ is data and parsing only: it imports `std` and files of its own model/ folder.
                \\  Keep the data and the parsing here and move the part that needs {s} to client/ or view/.
            , .{ target, target });
        },
        .view => {
            const io = std.mem.eql(u8, target, "sys.zig") or std.mem.eql(u8, target, "http.zig");
            const client = same_feature and to.?.layer == .client;
            if (!io and !client) return null;
            return try std.fmt.allocPrint(gpa,
                \\imports {s}
                \\  view/ only draws: nothing that runs a command, reads a file or talks to the network belongs in a frame.
                \\  Read what you draw from model/ data the entry passes in, and return what the user asked for (an intent) for features/{s}/entry/ to run.
            , .{ target, f.feature });
        },
        .client => {
            if (same_feature) {
                var hosts_buf: [256]u8 = undefined;
                const hosts = std.fmt.bufPrint(&hosts_buf, "features/{s}/hosts.zig", .{f.feature}) catch return null;
                if (to.?.layer == .model or to.?.layer == .client or std.mem.eql(u8, target, hosts)) return null;
            }
            return try std.fmt.allocPrint(gpa,
                \\imports {s}
                \\  client/ reaches the outside world only through what it is handed.
                \\  Add the effect it needs to features/{s}/hosts.zig as an interface and take it as a parameter, so a test can pass a stand-in.
            , .{ target, f.feature });
        },
        .entry, .root => return null,
    }
}

/// Every string an `@import("…")` names in `source`, with its line.
/// Comment lines are skipped: they often quote one.
const Imports = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_no: usize = 0,
    rest: []const u8 = "",

    fn init(source: []const u8) Imports {
        return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
    }

    fn next(self: *Imports) ?struct { name: []const u8, line: usize } {
        const marker = "@import(\"";
        while (true) {
            if (std.mem.indexOf(u8, self.rest, marker)) |at| {
                const start = at + marker.len;
                const end = std.mem.indexOfScalarPos(u8, self.rest, start, '"') orelse {
                    self.rest = "";
                    continue;
                };
                const name = self.rest[start..end];
                self.rest = self.rest[end..];
                return .{ .name = name, .line = self.line_no };
            }
            const line = self.lines.next() orelse return null;
            self.line_no += 1;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            self.rest = if (std.mem.startsWith(u8, trimmed, "//")) "" else line;
        }
    }
};

const Walk = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    failures: usize = 0,
    files: usize = 0,

    const Found = struct { name: []u8, is_dir: bool };

    const Listing = struct {
        gpa: std.mem.Allocator,
        found: std.ArrayList(Found) = .empty,

        fn visit(self: *Listing, e: sys.DirEntry) void {
            const name = self.gpa.dupe(u8, e.name) catch return;
            self.found.append(self.gpa, .{ .name = name, .is_dir = e.is_dir }) catch self.gpa.free(name);
        }
    };

    /// Checks every `.zig` file under `rel` (a `src`-relative folder, "" for all of it).
    fn dir(self: *Walk, rel: []const u8) !void {
        const gpa = self.gpa;
        const full = if (rel.len == 0) try gpa.dupe(u8, self.root) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, rel });
        defer gpa.free(full);
        var listing: Listing = .{ .gpa = gpa };
        defer {
            for (listing.found.items) |f| gpa.free(f.name);
            listing.found.deinit(gpa);
        }
        sys.listDir(gpa, full, &listing, Listing.visit);
        for (listing.found.items) |f| {
            const child = if (rel.len == 0) try gpa.dupe(u8, f.name) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, f.name });
            defer gpa.free(child);
            if (f.is_dir) {
                try self.dir(child);
            } else if (std.mem.endsWith(u8, f.name, ".zig")) {
                try self.file(child);
            }
        }
    }

    fn file(self: *Walk, rel: []const u8) !void {
        const gpa = self.gpa;
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, rel });
        defer gpa.free(full);
        const head = sys.readFileHead(gpa, full, 64 << 20) catch {
            std.debug.print("arch_check: cannot read {s}\n", .{full});
            self.failures += 1;
            return;
        };
        defer if (head.data.len > 0) gpa.free(head.data);
        self.files += 1;
        var imports = Imports.init(head.data);
        while (imports.next()) |imp| {
            const message = try check(gpa, rel, imp.name) orelse continue;
            defer gpa.free(message);
            std.debug.print("src/{s}:{d}: {s}\n\n", .{ rel, imp.line, message });
            self.failures += 1;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: arch_check <path to src>\n", .{});
        std.process.exit(2);
    }
    var walk: Walk = .{ .gpa = gpa, .root = std.mem.trimEnd(u8, args[1], "/") };
    try walk.dir("");
    if (walk.files == 0) {
        std.debug.print("arch_check: no .zig files under {s}\n", .{walk.root});
        std.process.exit(2);
    }
    if (walk.failures > 0) {
        std.debug.print("arch_check: {d} import{s} cross a boundary (the rules are at the top of tooling/arch_check.zig)\n", .{ walk.failures, if (walk.failures == 1) "" else "s" });
        std.process.exit(1);
    }
}

// ── tests ───────────────────────────────────────────────────────────────
fn expectOk(importer: []const u8, import: []const u8) !void {
    const gpa = std.testing.allocator;
    if (try check(gpa, importer, import)) |message| {
        defer gpa.free(message);
        std.debug.print("unexpected failure for {s} → {s}:\n{s}\n", .{ importer, import, message });
        return error.TestUnexpectedResult;
    }
}

fn expectFails(importer: []const u8, import: []const u8, saying: []const u8) !void {
    const gpa = std.testing.allocator;
    const message = try check(gpa, importer, import) orelse return error.TestExpectedFailure;
    defer gpa.free(message);
    if (std.mem.indexOf(u8, message, saying) == null) {
        std.debug.print("message for {s} → {s} does not say \"{s}\":\n{s}\n", .{ importer, import, saying, message });
        return error.TestUnexpectedResult;
    }
}

test "outside a feature, only its public file" {
    try expectOk("ui/files.zig", "../features/repo/repo.zig");
    try expectOk("app.zig", "features/diff/diff.zig");
    try expectFails("ui/files.zig", "../features/repo/view/panel.zig", "Import features/repo/repo.zig");
    try expectFails("app.zig", "features/diff/entry/tab.zig", "Import features/diff/diff.zig");
    // Another feature is outside too.
    try expectOk("features/repo/entry/tab.zig", "../../diff/diff.zig");
    try expectFails("features/repo/entry/tab.zig", "../../diff/model/rows.zig", "Import features/diff/diff.zig");
    // Inside, anything of its own.
    try expectOk("features/repo/repo.zig", "entry/panel.zig");
    try expectOk("features/repo/entry/panel.zig", "../client/git.zig");
}

test "framework code depends on no feature and not on the app" {
    try expectFails("ui/ui.zig", "../features/repo/repo.zig", "framework code");
    try expectFails("gfx/draw.zig", "../app.zig", "framework code");
    try expectFails("tabs/tab.zig", "../app.zig", "framework code");
    try expectOk("gfx/draw.zig", "text.zig");
    // The panels in ui/ are app code.
    try expectOk("ui/sidebar.zig", "../features/repo/repo.zig");
}

test "model is pure" {
    try expectOk("features/repo/model/log.zig", "std");
    try expectOk("features/repo/model/log.zig", "status.zig");
    try expectFails("features/repo/model/log.zig", "../../../sys.zig", "data and parsing only");
    try expectFails("features/repo/model/log.zig", "../client/git.zig", "data and parsing only");
    try expectFails("features/repo/model/log.zig", "ghostty-vt", "data and parsing only");
}

test "views do no I/O" {
    try expectOk("features/repo/view/panel.zig", "../model/status.zig");
    try expectOk("features/repo/view/panel.zig", "../../../ui/ui.zig");
    try expectFails("features/repo/view/panel.zig", "../../../sys.zig", "view/ only draws");
    try expectFails("features/repo/view/panel.zig", "../../../http.zig", "view/ only draws");
    try expectFails("features/repo/view/panel.zig", "../client/git.zig", "features/repo/entry/");
}

test "clients go through their hosts" {
    try expectOk("features/repo/client/git.zig", "../hosts.zig");
    try expectOk("features/repo/client/git.zig", "../model/status.zig");
    try expectOk("features/repo/client/github.zig", "forge.zig");
    try expectFails("features/repo/client/git.zig", "../../../sys.zig", "features/repo/hosts.zig");
    try expectFails("features/repo/client/github.zig", "../../../http.zig", "features/repo/hosts.zig");
    try expectFails("features/repo/client/git.zig", "../view/panel.zig", "features/repo/hosts.zig");
}

test "imports are found, comments are not" {
    var it = Imports.init(
        \\//! see `@import("ignored.zig")`
        \\const a = @import("a.zig");
        \\    // const b = @import("b.zig");
        \\fn f(x: @import("c.zig").T, y: @import("d.zig").T) void {}
    );
    try std.testing.expectEqualStrings("a.zig", it.next().?.name);
    const c = it.next().?;
    try std.testing.expectEqualStrings("c.zig", c.name);
    try std.testing.expectEqual(@as(usize, 4), c.line);
    try std.testing.expectEqualStrings("d.zig", it.next().?.name);
    try std.testing.expect(it.next() == null);
}

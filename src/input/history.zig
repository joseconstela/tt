//! Command history shared by all terminal tabs: seeds itself from the user's
//! zsh history, powers ↑/↓ browsing and fish-style inline suggestions.
const std = @import("std");
const sys = @import("../sys.zig");

pub const History = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    file_path: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
        if (self.file_path) |p| self.gpa.free(p);
    }

    /// Loads `~/.zsh_history` (read-only seed) and our own history file.
    pub fn load(self: *History) void {
        const home = sys.home();
        if (std.fmt.allocPrint(self.gpa, "{s}/.zsh_history", .{home})) |zsh_path| {
            defer self.gpa.free(zsh_path);
            if (sys.readFileTail(self.gpa, zsh_path, 768 * 1024)) |data| {
                defer self.gpa.free(data);
                self.parseZsh(data);
            } else |_| {}
        } else |_| {}

        self.file_path = std.fmt.allocPrint(self.gpa, "{s}/.conch_history", .{home}) catch null;
        if (self.file_path) |p| {
            if (sys.readFileTail(self.gpa, p, 512 * 1024)) |data| {
                defer self.gpa.free(data);
                var it = std.mem.splitScalar(u8, data, '\n');
                while (it.next()) |line| self.push(line);
            } else |_| {}
        }
    }

    /// zsh history: optional ": <ts>:<dur>;" prefix, bytes ≥ 0x83 "metafied".
    pub fn parseZsh(self: *History, data: []const u8) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        var first = true;
        var skip_continuation = false;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.gpa);
        while (it.next()) |raw| {
            // The tail read may start mid-line; drop the first fragment.
            if (first) {
                first = false;
                if (data.len >= 768 * 1024) continue;
            }
            const continued = raw.len > 0 and raw[raw.len - 1] == '\\';
            if (skip_continuation or continued) {
                // Multi-line entries are not useful as one-line suggestions.
                skip_continuation = continued;
                continue;
            }
            var line = raw;
            if (std.mem.startsWith(u8, line, ": ")) {
                if (std.mem.indexOfScalar(u8, line, ';')) |semi| line = line[semi + 1 ..];
            }
            scratch.clearRetainingCapacity();
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                if (line[i] == 0x83 and i + 1 < line.len) {
                    i += 1;
                    scratch.append(self.gpa, line[i] ^ 0x20) catch {};
                } else scratch.append(self.gpa, line[i]) catch {};
            }
            if (std.unicode.utf8ValidateSlice(scratch.items)) self.push(scratch.items);
        }
    }

    fn push(self: *History, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], trimmed)) return;
        const copy = self.gpa.dupe(u8, trimmed) catch return;
        self.entries.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    /// Records a command the user just ran.
    pub fn add(self: *History, cmd: []const u8) void {
        const before = self.entries.items.len;
        self.push(cmd);
        if (self.entries.items.len == before) return;
        if (std.mem.indexOfScalar(u8, cmd, '\n') != null) return;
        if (self.file_path) |p| {
            const line = std.fmt.allocPrint(self.gpa, "{s}\n", .{std.mem.trim(u8, cmd, " \t\r")}) catch return;
            defer self.gpa.free(line);
            sys.writeFile(self.gpa, p, line, true) catch {};
        }
    }

    /// Most recent entry that extends `prefix`; returns only the remainder.
    pub fn suggest(self: *const History, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return null;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.len > prefix.len and std.mem.startsWith(u8, e, prefix)) return e[prefix.len..];
        }
        return null;
    }

    /// Walks backwards (older) from `from` looking for an entry starting with
    /// `prefix` and different from `current`. `from` is exclusive.
    pub fn searchBack(self: *const History, from: usize, prefix: []const u8, current: []const u8) ?usize {
        var i = @min(from, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (std.mem.startsWith(u8, e, prefix) and !std.mem.eql(u8, e, current)) return i;
        }
        return null;
    }

    pub fn searchForward(self: *const History, from: usize, prefix: []const u8, current: []const u8) ?usize {
        var i = from + 1;
        while (i < self.entries.items.len) : (i += 1) {
            const e = self.entries.items[i];
            if (std.mem.startsWith(u8, e, prefix) and !std.mem.eql(u8, e, current)) return i;
        }
        return null;
    }
};

test "zsh history parsing: extended format, metafied bytes, continuations" {
    var h = History.init(std.testing.allocator);
    defer h.deinit();
    h.parseZsh(": 1700000000:0;git status\nls -la\n: 1700000001:0;echo one \\\ntwo\nls -la\necho \xc3\x83\x81\n");
    try std.testing.expectEqual(@as(usize, 3), h.entries.items.len);
    try std.testing.expectEqualStrings("git status", h.entries.items[0]);
    try std.testing.expectEqualStrings("ls -la", h.entries.items[1]);
    try std.testing.expectEqualStrings("echo á", h.entries.items[2]);
}

test "suggestions prefer the most recent match" {
    var h = History.init(std.testing.allocator);
    defer h.deinit();
    h.push("git diff src/main.zig");
    h.push("git diff src/ingest/parser.js");
    h.push("ls");
    try std.testing.expectEqualStrings("gest/parser.js", h.suggest("git diff src/in").?);
    try std.testing.expect(h.suggest("zzz") == null);
    try std.testing.expectEqual(@as(?usize, 1), h.searchBack(h.entries.items.len, "git", ""));
    try std.testing.expectEqual(@as(?usize, 0), h.searchBack(1, "git", "git diff src/ingest/parser.js"));
}

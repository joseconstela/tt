//! A unified diff as lines to draw: what `git diff` prints for one file,
//! with the header lines (`diff --git`, `index`, `---`, `+++`) dropped and
//! each remaining line told apart: a hunk header (`@@ -1,4 +1,5 @@`), a
//! line both sides have, one added, one removed. Each line carries its
//! number on the old and on the new side (0 when it has none there).
//!
//! `numstat` reads `git diff --numstat -z`: lines added and removed per
//! path, for the counts beside each file of the Changes view.
const std = @import("std");

pub const Kind = enum { hunk, context, added, removed, note };

pub const Line = struct {
    kind: Kind,
    /// 1-based line numbers; 0 where the line does not exist on that side.
    old_no: u32 = 0,
    new_no: u32 = 0,
    /// The line without its leading marker; a slice of the diff's text.
    text: []const u8,
};

pub const Patch = struct {
    gpa: std.mem.Allocator,
    /// The diff as git printed it; `lines` point into it.
    raw: []u8,
    lines: []Line,
    added: u32 = 0,
    removed: u32 = 0,
    binary: bool = false,

    pub fn deinit(self: *Patch) void {
        self.gpa.free(self.lines);
        self.gpa.free(self.raw);
    }
};

/// Parses the diff of one file. `raw` is copied.
pub fn parse(gpa: std.mem.Allocator, raw: []const u8) !Patch {
    const text = try gpa.dupe(u8, raw);
    errdefer gpa.free(text);
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    var out: Patch = .{ .gpa = gpa, .raw = text, .lines = &.{} };

    var old_no: u32 = 0;
    var new_no: u32 = 0;
    var in_hunk = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            const at = hunkStart(line);
            old_no = at.old;
            new_no = at.new;
            try lines.append(gpa, .{ .kind = .hunk, .text = line });
            continue;
        }
        if (!in_hunk) {
            if (std.mem.startsWith(u8, line, "Binary files ") or std.mem.startsWith(u8, line, "GIT binary patch")) out.binary = true;
            continue;
        }
        if (line.len == 0) {
            // The text ends with a newline: nothing after the last line.
            if (it.peek() == null) break;
            try lines.append(gpa, .{ .kind = .context, .old_no = old_no, .new_no = new_no, .text = "" });
            old_no += 1;
            new_no += 1;
            continue;
        }
        switch (line[0]) {
            '+' => {
                try lines.append(gpa, .{ .kind = .added, .new_no = new_no, .text = line[1..] });
                new_no += 1;
                out.added += 1;
            },
            '-' => {
                try lines.append(gpa, .{ .kind = .removed, .old_no = old_no, .text = line[1..] });
                old_no += 1;
                out.removed += 1;
            },
            ' ' => {
                try lines.append(gpa, .{ .kind = .context, .old_no = old_no, .new_no = new_no, .text = line[1..] });
                old_no += 1;
                new_no += 1;
            },
            // "\ No newline at end of file".
            '\\' => try lines.append(gpa, .{ .kind = .note, .text = std.mem.trimStart(u8, line[1..], " ") }),
            // The next file's header: one file is all this reads.
            else => in_hunk = false,
        }
    }
    out.lines = try lines.toOwnedSlice(gpa);
    return out;
}

/// Where a hunk starts on each side: `@@ -12,4 +13,6 @@ fn name()`.
fn hunkStart(header: []const u8) struct { old: u32, new: u32 } {
    var old: u32 = 0;
    var new: u32 = 0;
    var parts = std.mem.tokenizeScalar(u8, header, ' ');
    while (parts.next()) |p| {
        if (p.len < 2) continue;
        const digits = p[1 .. std.mem.indexOfScalar(u8, p, ',') orelse p.len];
        const n = std.fmt.parseInt(u32, digits, 10) catch continue;
        if (p[0] == '-') old = n;
        if (p[0] == '+') {
            new = n;
            break;
        }
    }
    return .{ .old = old, .new = new };
}

pub const Count = struct { path: []const u8, added: u32, removed: u32, binary: bool = false };

/// `git diff --numstat -z`: `3<tab>1<tab>path`, a NUL after each; a rename
/// is `3<tab>1<tab>` followed by the old and the new path, each with its
/// NUL (the new path is the one kept). Paths are slices of `raw`.
pub fn numstat(gpa: std.mem.Allocator, raw: []const u8) ![]Count {
    var out: std.ArrayList(Count) = .empty;
    errdefer out.deinit(gpa);
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |rec| {
        if (rec.len == 0) continue;
        var cols = std.mem.splitScalar(u8, rec, '\t');
        const added_s = cols.next() orelse continue;
        const removed_s = cols.next() orelse continue;
        var path = cols.rest();
        if (path.len == 0) {
            _ = records.next() orelse break;
            path = records.next() orelse break;
        }
        const binary = std.mem.eql(u8, added_s, "-");
        try out.append(gpa, .{
            .path = path,
            .added = if (binary) 0 else std.fmt.parseInt(u32, added_s, 10) catch 0,
            .removed = if (binary) 0 else std.fmt.parseInt(u32, removed_s, 10) catch 0,
            .binary = binary,
        });
    }
    return out.toOwnedSlice(gpa);
}

// ── tests ───────────────────────────────────────────────────────────────
test "a modified file: numbers on both sides" {
    const gpa = std.testing.allocator;
    const raw =
        \\diff --git a/notes.txt b/notes.txt
        \\index 1234567..89abcde 100644
        \\--- a/notes.txt
        \\+++ b/notes.txt
        \\@@ -1,5 +1,5 @@ heading
        \\ one
        \\-two
        \\+two changed
        \\ three
        \\-four
        \\ five
        \\+six
        \\\ No newline at end of file
        \\
    ;
    var p = try parse(gpa, raw);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 9), p.lines.len);
    try std.testing.expectEqual(Kind.hunk, p.lines[0].kind);
    try std.testing.expectEqualStrings("@@ -1,5 +1,5 @@ heading", p.lines[0].text);
    try std.testing.expectEqual(Kind.context, p.lines[1].kind);
    try std.testing.expectEqual(@as(u32, 1), p.lines[1].new_no);
    try std.testing.expectEqual(Kind.removed, p.lines[2].kind);
    try std.testing.expectEqual(@as(u32, 2), p.lines[2].old_no);
    try std.testing.expectEqual(@as(u32, 0), p.lines[2].new_no);
    try std.testing.expectEqualStrings("two changed", p.lines[3].text);
    try std.testing.expectEqual(@as(u32, 2), p.lines[3].new_no);
    // "five" is line 5 before and line 4 after.
    try std.testing.expectEqual(@as(u32, 5), p.lines[6].old_no);
    try std.testing.expectEqual(@as(u32, 4), p.lines[6].new_no);
    try std.testing.expectEqual(@as(u32, 5), p.lines[7].new_no);
    try std.testing.expectEqual(Kind.note, p.lines[8].kind);
    try std.testing.expectEqual(@as(u32, 2), p.added);
    try std.testing.expectEqual(@as(u32, 2), p.removed);
    try std.testing.expect(!p.binary);
}

test "a new file, an empty line inside a hunk, a binary file" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "diff --git a/x b/x\nnew file mode 100644\n--- /dev/null\n+++ b/x\n@@ -0,0 +1,3 @@\n+a\n+\n+c\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 4), p.lines.len);
    try std.testing.expectEqual(@as(u32, 3), p.lines[3].new_no);
    try std.testing.expectEqualStrings("", p.lines[2].text);
    try std.testing.expectEqual(@as(u32, 3), p.added);

    var ctx = try parse(gpa, "@@ -3,3 +3,3 @@\n a\n\n-b\n+c\n");
    defer ctx.deinit();
    try std.testing.expectEqual(Kind.context, ctx.lines[2].kind);
    try std.testing.expectEqual(@as(u32, 4), ctx.lines[2].old_no);
    try std.testing.expectEqual(@as(u32, 5), ctx.lines[3].old_no);

    var b = try parse(gpa, "diff --git a/l.png b/l.png\nBinary files a/l.png and b/l.png differ\n");
    defer b.deinit();
    try std.testing.expect(b.binary);
    try std.testing.expectEqual(@as(usize, 0), b.lines.len);
}

test "numstat" {
    const gpa = std.testing.allocator;
    const counts = try numstat(gpa, "84\t12\tsrc/worker.js\x00-\t-\tlogo.png\x003\t1\t\x00old.md\x00docs/new.md\x00");
    defer gpa.free(counts);
    try std.testing.expectEqual(@as(usize, 3), counts.len);
    try std.testing.expectEqual(@as(u32, 84), counts[0].added);
    try std.testing.expect(counts[1].binary);
    try std.testing.expectEqualStrings("docs/new.md", counts[2].path);
    try std.testing.expectEqual(@as(u32, 1), counts[2].removed);
}

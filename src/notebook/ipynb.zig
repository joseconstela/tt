//! Jupyter notebooks on disk: nbformat 4 (the `.ipynb` JSON that Jupyter,
//! VS Code and GitHub read), parsed into cells and written back the way
//! Jupyter writes it — keys sorted, one-space indent, sources and stream
//! text as lists of lines — so a save changes as little of the file as an
//! edit in Jupyter would. Whatever this app does not model (notebook and
//! cell metadata, mime bundles) is kept as JSON text and written back
//! verbatim, so nothing another tool put in the file is lost.
//!
//! Cells come in three kinds, as in nbformat: code, markdown and raw. A
//! code cell whose first line is a `%%sh` / `%%bash` / `%%zsh` magic is
//! what the notebook tab shows as a *shell* cell (`shellMagic`); the magic
//! line stays in the source, so the kernel runs it too. Every cell has an
//! id (nbformat 4.5): one is made up for cells that lack one.
const std = @import("std");

/// Darwin's own entropy, always there and never seeded.
extern "c" fn arc4random_buf(buf: *anyopaque, n: usize) void;

pub const CellKind = enum {
    code,
    markdown,
    raw,

    pub fn parse(s: []const u8) ?CellKind {
        return std.meta.stringToEnum(CellKind, s);
    }
};

/// One output of a code cell, in nbformat's own shape. `data` and
/// `metadata` are JSON object texts (minified); "" means `{}`.
pub const Output = struct {
    kind: Kind,
    /// stream: "stdout" or "stderr".
    name: []u8 = &.{},
    /// stream: what it printed; error: the traceback, lines joined by \n.
    text: []u8 = &.{},
    /// display_data / execute_result: the mime bundle.
    data: []u8 = &.{},
    metadata: []u8 = &.{},
    /// execute_result only.
    execution_count: ?i64 = null,
    ename: []u8 = &.{},
    evalue: []u8 = &.{},

    pub const Kind = enum {
        stream,
        display_data,
        execute_result,
        @"error",

        pub fn parse(s: []const u8) ?Kind {
            return std.meta.stringToEnum(Kind, s);
        }
    };

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.text);
        gpa.free(self.data);
        gpa.free(self.metadata);
        gpa.free(self.ename);
        gpa.free(self.evalue);
        self.* = .{ .kind = self.kind };
    }
};

pub const Cell = struct {
    id: []u8,
    kind: CellKind,
    /// The full source, magics included, without the file's line splitting.
    source: []u8,
    /// JSON object text; "" = `{}`.
    metadata: []u8 = &.{},
    execution_count: ?i64 = null,
    outputs: std.ArrayList(Output) = .empty,

    pub fn deinit(self: *Cell, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.source);
        gpa.free(self.metadata);
        for (self.outputs.items) |*o| o.deinit(gpa);
        self.outputs.deinit(gpa);
    }

    pub fn clearOutputs(self: *Cell, gpa: std.mem.Allocator) void {
        for (self.outputs.items) |*o| o.deinit(gpa);
        self.outputs.clearRetainingCapacity();
    }
};

pub const Notebook = struct {
    gpa: std.mem.Allocator,
    cells: std.ArrayList(Cell) = .empty,
    /// JSON object text; "" = `{}`.
    metadata: []u8 = &.{},
    nbformat: i64 = 4,
    nbformat_minor: i64 = 5,

    pub fn init(gpa: std.mem.Allocator) Notebook {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Notebook) void {
        for (self.cells.items) |*c| c.deinit(self.gpa);
        self.cells.deinit(self.gpa);
        self.gpa.free(self.metadata);
        self.* = .{ .gpa = self.gpa };
    }

    /// The kernel the file names (`metadata.kernelspec.name`), if any.
    pub fn kernelName(self: *const Notebook, buf: []u8) ?[]const u8 {
        if (self.metadata.len == 0) return null;
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.metadata, .{}) catch return null;
        defer parsed.deinit();
        const spec = objectGet(parsed.value, "kernelspec") orelse return null;
        const name = stringOf(objectGet(spec, "name") orelse return null) orelse return null;
        if (name.len == 0 or name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }

    /// A cell appended at `at` (or the end): an empty one of `kind`.
    pub fn insertCell(self: *Notebook, at: usize, kind: CellKind, source: []const u8) !*Cell {
        var id_buf: [id_len]u8 = undefined;
        const cell: Cell = .{
            .id = try self.gpa.dupe(u8, newId(&id_buf)),
            .kind = kind,
            .source = try self.gpa.dupe(u8, source),
        };
        errdefer self.gpa.free(cell.id);
        errdefer self.gpa.free(cell.source);
        const index = @min(at, self.cells.items.len);
        try self.cells.insert(self.gpa, index, cell);
        return &self.cells.items[index];
    }

    pub fn removeCell(self: *Notebook, at: usize) void {
        if (at >= self.cells.items.len) return;
        var c = self.cells.orderedRemove(at);
        c.deinit(self.gpa);
    }
};

// ── ids ──────────────────────────────────────────────────────────────────
pub const id_len = 8;

/// A fresh cell id: eight random lowercase hex digits, as nbformat allows.
pub fn newId(buf: *[id_len]u8) []const u8 {
    var raw: [id_len / 2]u8 = undefined;
    arc4random_buf(&raw, raw.len);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        buf[2 * i] = hex[b >> 4];
        buf[2 * i + 1] = hex[b & 15];
    }
    return buf[0..id_len];
}

fn validId(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

// ── shell cells ──────────────────────────────────────────────────────────
/// The cell magic on the first line when it is one that runs the rest as
/// a shell script (`%%sh`, `%%bash`, `%%zsh`, `%%script sh`…), else null.
pub fn shellMagic(source: []const u8) ?[]const u8 {
    const first = firstLine(source);
    const line = std.mem.trimEnd(u8, first, " \t\r");
    if (!std.mem.startsWith(u8, line, "%%")) return null;
    const word_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const magic = line[2..word_end];
    const shells = [_][]const u8{ "sh", "bash", "zsh" };
    for (shells) |sh| {
        if (std.mem.eql(u8, magic, sh)) return line;
    }
    if (std.mem.eql(u8, magic, "script")) {
        const args = std.mem.trim(u8, line[word_end..], " \t");
        const prog_end = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
        const prog = args[0..prog_end];
        for (shells) |sh| {
            if (std.mem.eql(u8, prog, sh)) return line;
            if (prog.len > sh.len and std.mem.endsWith(u8, prog, sh) and prog[prog.len - sh.len - 1] == '/') return line;
        }
    }
    return null;
}

/// The source without its first line (what a shell cell shows and edits).
pub fn afterFirstLine(source: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, source, '\n') orelse return "";
    return source[nl + 1 ..];
}

fn firstLine(source: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, source, '\n') orelse return source;
    return source[0..nl];
}

// ── reading ──────────────────────────────────────────────────────────────
fn objectGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn stringOf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// A string, or a list of strings joined (nbformat's multiline strings).
fn multilineOf(gpa: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const value = v orelse return gpa.dupe(u8, "");
    switch (value) {
        .string => |s| return gpa.dupe(u8, s),
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            for (a.items) |item| {
                if (stringOf(item)) |s| try out.appendSlice(gpa, s);
            }
            return out.toOwnedSlice(gpa);
        },
        else => return gpa.dupe(u8, ""),
    }
}

/// The traceback: a list of lines, joined by \n (a string is kept as is).
fn linesOf(gpa: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const value = v orelse return gpa.dupe(u8, "");
    switch (value) {
        .string => |s| return gpa.dupe(u8, s),
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            for (a.items, 0..) |item, i| {
                if (i > 0) try out.append(gpa, '\n');
                if (stringOf(item)) |s| try out.appendSlice(gpa, s);
            }
            return out.toOwnedSlice(gpa);
        },
        else => return gpa.dupe(u8, ""),
    }
}

/// A JSON object as minified text; "" for a missing or empty object.
fn objectText(gpa: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const value = v orelse return gpa.dupe(u8, "");
    switch (value) {
        .object => |o| if (o.count() == 0) return gpa.dupe(u8, ""),
        else => return gpa.dupe(u8, ""),
    }
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

pub fn parseOutput(gpa: std.mem.Allocator, v: std.json.Value) !?Output {
    const kind_text = stringOf(objectGet(v, "output_type") orelse return null) orelse return null;
    const kind = Output.Kind.parse(kind_text) orelse return null;
    var o: Output = .{ .kind = kind };
    errdefer o.deinit(gpa);
    switch (kind) {
        .stream => {
            o.name = try gpa.dupe(u8, stringOf(objectGet(v, "name") orelse .null) orelse "stdout");
            o.text = try multilineOf(gpa, objectGet(v, "text"));
        },
        .display_data, .execute_result => {
            o.data = try objectText(gpa, objectGet(v, "data"));
            o.metadata = try objectText(gpa, objectGet(v, "metadata"));
            if (kind == .execute_result) {
                if (objectGet(v, "execution_count")) |c| o.execution_count = intOf(c);
            }
        },
        .@"error" => {
            o.ename = try gpa.dupe(u8, stringOf(objectGet(v, "ename") orelse .null) orelse "");
            o.evalue = try gpa.dupe(u8, stringOf(objectGet(v, "evalue") orelse .null) orelse "");
            o.text = try linesOf(gpa, objectGet(v, "traceback"));
        },
    }
    return o;
}

/// The outputs in a JSON array text (what the workspace file keeps).
pub fn parseOutputs(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Output)) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const list = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.NotAnArray,
    };
    for (list) |item| {
        if (try parseOutput(gpa, item)) |o| try out.append(gpa, o);
    }
}

fn parseCell(gpa: std.mem.Allocator, v: std.json.Value) !?Cell {
    const kind_text = stringOf(objectGet(v, "cell_type") orelse return null) orelse return null;
    const kind = CellKind.parse(kind_text) orelse return null;
    var id_buf: [id_len]u8 = undefined;
    const given = stringOf(objectGet(v, "id") orelse .null);
    const id = if (given != null and validId(given.?)) given.? else newId(&id_buf);
    var cell: Cell = .{
        .id = try gpa.dupe(u8, id),
        .kind = kind,
        .source = &.{},
    };
    errdefer cell.deinit(gpa);
    cell.source = try multilineOf(gpa, objectGet(v, "source"));
    cell.metadata = try objectText(gpa, objectGet(v, "metadata"));
    if (kind == .code) {
        if (objectGet(v, "execution_count")) |c| cell.execution_count = intOf(c);
        if (objectGet(v, "outputs")) |outs| switch (outs) {
            .array => |a| for (a.items) |item| {
                if (try parseOutput(gpa, item)) |o| try cell.outputs.append(gpa, o);
            },
            else => {},
        };
    }
    return cell;
}

/// Reads a notebook. A file that is not a JSON object with a `cells`
/// list is `error.NotANotebook`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Notebook {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.NotANotebook;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.NotANotebook;
    const cells = objectGet(root, "cells") orelse return error.NotANotebook;
    if (cells != .array) return error.NotANotebook;

    var nb = Notebook.init(gpa);
    errdefer nb.deinit();
    if (objectGet(root, "nbformat")) |n| nb.nbformat = intOf(n) orelse 4;
    if (objectGet(root, "nbformat_minor")) |n| nb.nbformat_minor = intOf(n) orelse 5;
    nb.metadata = try objectText(gpa, objectGet(root, "metadata"));
    for (cells.array.items) |item| {
        if (try parseCell(gpa, item)) |c| try nb.cells.append(gpa, c);
    }
    return nb;
}

// ── writing ──────────────────────────────────────────────────────────────
const Stringify = std.json.Stringify;

fn writeRaw(js: *Stringify, text: []const u8) !void {
    try js.beginWriteRaw();
    try js.writer.writeAll(if (text.len == 0) "{}" else text);
    js.endWriteRaw();
}

/// A multiline string as nbformat writes it: one list item per line,
/// each keeping its newline; nothing after a final newline.
fn writeLines(js: *Stringify, text: []const u8) !void {
    try js.beginArray();
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = if (nl) |i| i + 1 else rest.len;
        try js.write(rest[0..end]);
        rest = rest[end..];
    }
    try js.endArray();
}

/// A traceback as nbformat writes it: a list of its lines, no newlines.
fn writeTraceback(js: *Stringify, text: []const u8) !void {
    try js.beginArray();
    if (text.len > 0) {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try js.write(line);
    }
    try js.endArray();
}

fn writeOptCount(js: *Stringify, count: ?i64) !void {
    if (count) |c| try js.write(c) else try js.write(null);
}

pub fn writeOutput(js: *Stringify, o: *const Output) !void {
    try js.beginObject();
    switch (o.kind) {
        .stream => {
            try js.objectField("name");
            try js.write(if (o.name.len == 0) "stdout" else o.name);
            try js.objectField("output_type");
            try js.write("stream");
            try js.objectField("text");
            try writeLines(js, o.text);
        },
        .display_data, .execute_result => {
            try js.objectField("data");
            try writeRaw(js, o.data);
            if (o.kind == .execute_result) {
                try js.objectField("execution_count");
                try writeOptCount(js, o.execution_count);
            }
            try js.objectField("metadata");
            try writeRaw(js, o.metadata);
            try js.objectField("output_type");
            try js.write(@tagName(o.kind));
        },
        .@"error" => {
            try js.objectField("ename");
            try js.write(o.ename);
            try js.objectField("evalue");
            try js.write(o.evalue);
            try js.objectField("output_type");
            try js.write("error");
            try js.objectField("traceback");
            try writeTraceback(js, o.text);
        },
    }
    try js.endObject();
}

pub fn writeOutputs(js: *Stringify, outputs: []const Output) !void {
    try js.beginArray();
    for (outputs) |*o| try writeOutput(js, o);
    try js.endArray();
}

/// The outputs as a JSON array text (for the workspace file); minified.
pub fn outputsText(gpa: std.mem.Allocator, outputs: []const Output) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: Stringify = .{ .writer = &aw.writer };
    writeOutputs(&js, outputs) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeCell(js: *Stringify, c: *const Cell, strip_outputs: bool) !void {
    try js.beginObject();
    try js.objectField("cell_type");
    try js.write(@tagName(c.kind));
    if (c.kind == .code) {
        try js.objectField("execution_count");
        try writeOptCount(js, if (strip_outputs) null else c.execution_count);
    }
    try js.objectField("id");
    try js.write(c.id);
    try js.objectField("metadata");
    try writeRaw(js, c.metadata);
    if (c.kind == .code) {
        try js.objectField("outputs");
        try writeOutputs(js, if (strip_outputs) &.{} else c.outputs.items);
    }
    try js.objectField("source");
    try writeLines(js, c.source);
    try js.endObject();
}

/// The notebook as Jupyter would write it. `strip_outputs` leaves the
/// outputs and execution counts out of the file.
pub fn write(nb: *const Notebook, gpa: std.mem.Allocator, strip_outputs: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_1 } };
    writeNotebook(&js, nb, strip_outputs) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeNotebook(js: *Stringify, nb: *const Notebook, strip_outputs: bool) !void {
    try js.beginObject();
    try js.objectField("cells");
    try js.beginArray();
    for (nb.cells.items) |*c| try writeCell(js, c, strip_outputs);
    try js.endArray();
    try js.objectField("metadata");
    try writeRaw(js, nb.metadata);
    try js.objectField("nbformat");
    try js.write(@max(nb.nbformat, 4));
    try js.objectField("nbformat_minor");
    // Cell ids need 4.5.
    try js.write(if (nb.nbformat > 4) nb.nbformat_minor else @max(nb.nbformat_minor, 5));
    try js.endObject();
}

// ── tests ────────────────────────────────────────────────────────────────
const sample =
    \\{
    \\ "cells": [
    \\  {"cell_type": "markdown", "id": "intro", "metadata": {}, "source": ["# Title\n", "text"]},
    \\  {"cell_type": "code", "execution_count": 3, "metadata": {"tags": ["x"]}, "outputs": [
    \\    {"name": "stdout", "output_type": "stream", "text": ["hi\n", "there\n"]},
    \\    {"data": {"text/plain": ["2"], "image/png": "iVBORw0KGgo="}, "execution_count": 3, "metadata": {}, "output_type": "execute_result"},
    \\    {"ename": "ValueError", "evalue": "boom", "output_type": "error", "traceback": ["line 1", "line 2"]}
    \\  ], "source": "import sys\nprint('hi')\n1+1"},
    \\  {"cell_type": "code", "execution_count": null, "id": "sh-1", "metadata": {}, "outputs": [], "source": ["%%sh\n", "ls -la\n"]},
    \\  {"cell_type": "raw", "id": "r", "metadata": {"tt": {"kind": "ask"}}, "source": ""}
    \\ ],
    \\ "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python"}},
    \\ "nbformat": 4,
    \\ "nbformat_minor": 4
    \\}
;

test "ipynb: a notebook parses into cells and outputs, ids filled in" {
    const gpa = std.testing.allocator;
    var nb = try parse(gpa, sample);
    defer nb.deinit();
    try std.testing.expectEqual(@as(usize, 4), nb.cells.items.len);
    const md = nb.cells.items[0];
    try std.testing.expectEqual(CellKind.markdown, md.kind);
    try std.testing.expectEqualStrings("intro", md.id);
    try std.testing.expectEqualStrings("# Title\ntext", md.source);
    const code = nb.cells.items[1];
    try std.testing.expectEqual(CellKind.code, code.kind);
    try std.testing.expect(validId(code.id) and code.id.len == id_len); // made up
    try std.testing.expectEqual(@as(?i64, 3), code.execution_count);
    try std.testing.expectEqualStrings("{\"tags\":[\"x\"]}", code.metadata);
    try std.testing.expectEqual(@as(usize, 3), code.outputs.items.len);
    try std.testing.expectEqual(Output.Kind.stream, code.outputs.items[0].kind);
    try std.testing.expectEqualStrings("hi\nthere\n", code.outputs.items[0].text);
    try std.testing.expectEqual(Output.Kind.execute_result, code.outputs.items[1].kind);
    try std.testing.expectEqualStrings("{\"text/plain\":[\"2\"],\"image/png\":\"iVBORw0KGgo=\"}", code.outputs.items[1].data);
    try std.testing.expectEqual(Output.Kind.@"error", code.outputs.items[2].kind);
    try std.testing.expectEqualStrings("ValueError", code.outputs.items[2].ename);
    try std.testing.expectEqualStrings("line 1\nline 2", code.outputs.items[2].text);
    const sh = nb.cells.items[2];
    try std.testing.expectEqualStrings("%%sh", shellMagic(sh.source).?);
    try std.testing.expectEqualStrings("ls -la\n", afterFirstLine(sh.source));
    try std.testing.expect(shellMagic(code.source) == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("python3", nb.kernelName(&buf).?);
}

test "ipynb: writing is Jupyter's shape and round-trips; stripping drops outputs" {
    const gpa = std.testing.allocator;
    var nb = try parse(gpa, sample);
    defer nb.deinit();
    const text = try write(&nb, gpa, false);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n \"cells\": [\n  {\n   \"cell_type\": \"markdown\",\n   \"id\": \"intro\",\n   \"metadata\": {},\n   \"source\": [\n    \"# Title\\n\",\n    \"text\"\n   ]\n  },"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"nbformat_minor\": 5\n}\n") != null); // bumped for the ids
    try std.testing.expect(std.mem.indexOf(u8, text, "\"traceback\": [\n      \"line 1\",\n      \"line 2\"\n     ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"execution_count\": 3,") != null);

    var back = try parse(gpa, text);
    defer back.deinit();
    try std.testing.expectEqual(nb.cells.items.len, back.cells.items.len);
    for (nb.cells.items, back.cells.items) |a, b| {
        try std.testing.expectEqualStrings(a.id, b.id);
        try std.testing.expectEqualStrings(a.source, b.source);
        try std.testing.expectEqualStrings(a.metadata, b.metadata);
        try std.testing.expectEqual(a.outputs.items.len, b.outputs.items.len);
    }
    try std.testing.expectEqualStrings(nb.metadata, back.metadata);
    const again = try write(&back, gpa, false);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(text, again);

    const stripped = try write(&nb, gpa, true);
    defer gpa.free(stripped);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "\"outputs\": [],") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "\"execution_count\": null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "stdout") == null);
}

test "ipynb: outputs round-trip through their own JSON list, cells come and go" {
    const gpa = std.testing.allocator;
    var nb = try parse(gpa, sample);
    defer nb.deinit();
    const list = try outputsText(gpa, nb.cells.items[1].outputs.items);
    defer gpa.free(list);
    var outs: std.ArrayList(Output) = .empty;
    defer {
        for (outs.items) |*o| o.deinit(gpa);
        outs.deinit(gpa);
    }
    try parseOutputs(gpa, list, &outs);
    try std.testing.expectEqual(@as(usize, 3), outs.items.len);
    try std.testing.expectEqualStrings("boom", outs.items[2].evalue);

    const c = try nb.insertCell(1, .code, "x = 1");
    try std.testing.expectEqualStrings("x = 1", c.source);
    try std.testing.expectEqual(@as(usize, 5), nb.cells.items.len);
    try std.testing.expectEqual(CellKind.code, nb.cells.items[1].kind);
    nb.removeCell(1);
    try std.testing.expectEqual(@as(usize, 4), nb.cells.items.len);
    try std.testing.expectEqualStrings("intro", nb.cells.items[0].id);
    try std.testing.expectError(error.NotANotebook, parse(gpa, "[1, 2]"));
    try std.testing.expectError(error.NotANotebook, parse(gpa, "not json"));
}

test "ipynb: shell magics" {
    try std.testing.expectEqualStrings("%%bash", shellMagic("%%bash\necho hi").?);
    try std.testing.expectEqualStrings("%%script zsh -l", shellMagic("%%script zsh -l\necho hi").?);
    try std.testing.expectEqualStrings("%%script /bin/bash", shellMagic("%%script /bin/bash\necho hi").?);
    try std.testing.expect(shellMagic("%%time\nx = 1") == null);
    try std.testing.expect(shellMagic("%%script python\nprint(1)") == null);
    try std.testing.expect(shellMagic("echo %%sh") == null);
    try std.testing.expectEqualStrings("", afterFirstLine("%%sh"));
}

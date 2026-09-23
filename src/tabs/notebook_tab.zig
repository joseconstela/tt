//! Jupyter notebooks: `.ipynb` files shown as a column of cells, each a
//! card like a terminal block — the source on top, what it produced under
//! it — and run by a real Jupyter kernel (notebook/bridge.zig) so magics,
//! rich display and every installed kernel work as they do in Jupyter Lab.
//! The frontend is this app's own: cells are the same editor the file tab
//! uses (Python or shell syntax), Markdown cells are the Markdown view
//! (rendered, the caret's line as source), outputs come through the block
//! buffer (colours and all), PNGs through the image path and DataFrames as
//! native tables.
//!
//! Four kinds of cell: `py` (a code cell), `sh` (a code cell whose first
//! line is a `%%sh` magic, so Jupyter runs it too), `md`, and `ask` — a
//! question for the agent set under Settings › AI › Features, which
//! answers under it and can add a code cell for the user to run. New cells
//! are born in the input row at the bottom (the terminal's input box, with
//! a py / sh / md / ask switch): ⇧↵ runs what was typed as a new cell.
//! In a cell, ⇧↵ runs it and moves on; ↑ and ↓ cross cell boundaries.
//!
//! The band shows Run all · Restart · Clear outputs · Variables (the
//! inspector: the kernel's variables, its state and memory, the agent's
//! access to the variable schema). The context line says which kernel is
//! up ("py 3.12 · idle"). Saving writes nbformat 4 the way Jupyter does
//! (notebook/ipynb.zig); outputs go into the file unless
//! `notebooks.strip_outputs` is on, and into the workspace file either
//! way, so a relaunch shows the results again.
const std = @import("std");
const tab_mod = @import("tab.zig");
const viewer = @import("viewer.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const field = @import("../ui/field.zig");
const gfx_text = @import("../gfx/text.zig");
const image = @import("../gfx/image.zig");
const texture_mod = @import("../gfx/texture.zig");
const boxdraw = @import("../gfx/boxdraw.zig");
const filetype = @import("../filetype.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");
const records = @import("../records.zig");
const config = @import("../config.zig");
const agent = @import("../agent.zig");
const ipynb = @import("../notebook/ipynb.zig");
const bridge = @import("../notebook/bridge.zig");
const buffer_mod = @import("../term/buffer.zig");
const Parser = @import("../term/parser.zig").Parser;
const TextEditor = @import("text_editor.zig").TextEditor;
const MarkdownView = @import("markdown_view.zig").MarkdownView;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Texture = texture_mod.Texture;

const line_h = theme.output_line_h;
/// The kind label and the count, left of the cards.
const gutter_w: f32 = 44;
const gutter_gap: f32 = 10;
const side_pad: f32 = 16;
const top_pad: f32 = 14;
const cell_gap: f32 = 10;
const src_pad: f32 = 8;
const out_pad: f32 = 8;
const out_gap: f32 = 6;
/// Output rows shown before the earlier ones fold away.
const max_out_rows: u32 = 600;
const shown_rows: u32 = 200;
const table_row_h: f32 = 26;
const table_col_max: f32 = 280;
const image_max_h: f32 = 640;
const inspector_w: f32 = 320;
const inspector_head_h: f32 = 44;
const input_rows_max: usize = 8;
const input_hint_h: f32 = 24;
const max_file_bytes: usize = 64 * 1024 * 1024;
/// What the workspace file keeps of the outputs, at most.
const max_kept_bytes: usize = 4 * 1024 * 1024;
/// What the agent is told of the notebook, at most.
const max_context_bytes: usize = 24 * 1024;
const max_context_lines: usize = 30;
const disk_check_every: f64 = 2.0;
const saved_flash: f64 = 1.6;

var next_salt: usize = 1 << 20;

fn salt() usize {
    next_salt += 1;
    return next_salt;
}

const Kind = enum {
    py,
    sh,
    md,
    raw,
    ask,

    fn label(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn language(self: Kind) filetype.Language {
        return switch (self) {
            .py => .python,
            .sh => .shell,
            .md => .markdown,
            .raw, .ask => .plain,
        };
    }

    fn runs(self: Kind) bool {
        return self == .py or self == .sh;
    }

    /// Code shows line numbers, as the file editor does; prose does not.
    fn numbered(self: Kind) bool {
        return self == .py or self == .sh or self == .raw;
    }

    fn color(self: Kind) Color {
        return switch (self) {
            .py => theme.teal,
            .sh => theme.ansi[4],
            .md, .raw => theme.text_3,
            .ask => theme.accent,
        };
    }
};

const RunState = enum { idle, queued, running, done, failed, aborted };

// ── outputs ──────────────────────────────────────────────────────────────
/// A DataFrame's table, as the bridge extracted it from the HTML repr.
const Table = struct {
    columns: [][]u8,
    dtypes: ?[][]u8,
    rows: [][][]u8,
    truncated: bool,
    /// Column widths in points, measured on the first draw.
    widths: []f32,

    fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (self.columns) |s| gpa.free(s);
        gpa.free(self.columns);
        if (self.dtypes) |d| {
            for (d) |s| gpa.free(s);
            gpa.free(d);
        }
        for (self.rows) |r| {
            for (r) |s| gpa.free(s);
            gpa.free(r);
        }
        gpa.free(self.rows);
        gpa.free(self.widths);
    }

    fn headerRows(self: *const Table) usize {
        return if (self.dtypes != null) 2 else 1;
    }

    fn height(self: *const Table) f32 {
        const rows: f32 = @floatFromInt(self.headerRows() + self.rows.len);
        return rows * table_row_h + (if (self.truncated) line_h else 0);
    }
};

const OutKind = enum { text, err, picture, table, note };

/// One output of a cell, ready to draw: text (a stream, a value's repr, a
/// traceback) goes through the block buffer, a PNG becomes a texture, a
/// table is drawn as cells. `src` is what the file gets.
const Out = struct {
    kind: OutKind,
    src: ipynb.Output,
    buf: buffer_mod.Buffer,
    parser: Parser = .{},
    png: []u8 = &.{},
    tex: Texture = .{},
    tex_state: enum { pending, ready, failed } = .pending,
    native_w: u32 = 0,
    native_h: u32 = 0,
    table: ?Table = null,
    note: []const u8 = "",
    row_starts: std.ArrayList(u32) = .empty,
    total_rows: u32 = 0,
    cache_cols: u32 = 0,
    cache_version: u64 = std.math.maxInt(u64),
    /// From the last layout: the content's height, and the rows shown.
    h: f32 = 0,
    rows: u32 = 0,
    first_row: u32 = 0,

    /// Takes `src` (the caller must not free it) and works out how to show it.
    fn init(gpa: std.mem.Allocator, src: ipynb.Output) Out {
        var self: Out = .{ .kind = .note, .src = src, .buf = buffer_mod.Buffer.init(gpa) };
        switch (src.kind) {
            .stream => {
                self.kind = .text;
                self.feed(src.text);
            },
            .@"error" => {
                self.kind = .err;
                if (src.text.len > 0) {
                    self.feed(src.text);
                } else {
                    self.feed(src.ename);
                    if (src.evalue.len > 0) {
                        self.feed(": ");
                        self.feed(src.evalue);
                    }
                }
            },
            .display_data, .execute_result => self.fromBundle(gpa),
        }
        return self;
    }

    fn deinit(self: *Out, gpa: std.mem.Allocator, textures: ?*texture_mod.Textures) void {
        self.src.deinit(gpa);
        self.buf.deinit();
        gpa.free(self.png);
        if (self.tex.valid()) if (textures) |t| t.release(&self.tex);
        if (self.table) |*t| t.deinit(gpa);
        self.row_starts.deinit(gpa);
    }

    /// Text into the buffer, newlines as the terminal would see them.
    fn feed(self: *Out, text: []const u8) void {
        var sink = buffer_mod.Sink{ .buf = &self.buf };
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n' and (i == 0 or text[i - 1] != '\r')) {
                self.parser.feed(text[start..i], &sink);
                self.parser.feed("\r\n", &sink);
                start = i + 1;
            }
        }
        self.parser.feed(text[start..], &sink);
    }

    /// More of a stream: shown and kept for the file.
    fn append(self: *Out, gpa: std.mem.Allocator, text: []const u8) void {
        self.feed(text);
        const joined = std.mem.concat(gpa, u8, &.{ self.src.text, text }) catch return;
        gpa.free(self.src.text);
        self.src.text = joined;
    }

    /// Picks what to show from a mime bundle: a PNG, a table, else text.
    fn fromBundle(self: *Out, gpa: std.mem.Allocator) void {
        self.kind = .note;
        self.note = "Output of a kind this viewer cannot show.";
        if (self.src.data.len == 0) {
            self.note = "(no output)";
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, self.src.data, .{}) catch return;
        defer parsed.deinit();
        const data = parsed.value;
        if (data != .object) return;
        if (data.object.get("image/png")) |png| {
            if (multiline(gpa, png)) |b64| {
                defer gpa.free(b64);
                if (decodeBase64(gpa, b64)) |bytes| {
                    self.png = bytes;
                    self.kind = .picture;
                    return;
                }
            }
        }
        if (data.object.get("application/vnd.tt.table+json")) |t| {
            if (parseTable(gpa, t)) |table| {
                self.table = table;
                self.kind = .table;
                return;
            }
        }
        const text_keys = [_][]const u8{ "text/plain", "text/markdown", "text/latex", "application/json" };
        for (text_keys) |key| {
            if (data.object.get(key)) |v| if (multiline(gpa, v)) |text| {
                defer gpa.free(text);
                self.kind = .text;
                self.feed(text);
                return;
            };
        }
        if (data.object.get("text/html") != null) {
            self.note = "HTML output — open the notebook in Jupyter to see it.";
        } else if (data.object.get("image/svg+xml") != null) {
            self.note = "SVG output — open the notebook in Jupyter to see it.";
        } else if (data.object.count() > 0) {
            self.note = "Output of a kind this viewer cannot show.";
        }
    }

    // ── layout ──────────────────────────────────────────────────────────
    fn ensureRows(self: *Out, gpa: std.mem.Allocator, cols: u32) void {
        if (self.cache_version == self.buf.version and self.cache_cols == cols) return;
        self.cache_version = self.buf.version;
        self.cache_cols = cols;
        self.row_starts.clearRetainingCapacity();
        var total: u32 = 0;
        const n = self.buf.lineCount();
        for (self.buf.lines.items[0..n]) |line| {
            self.row_starts.append(gpa, total) catch break;
            const len: u32 = @intCast(line.cells.items.len);
            total += @max(1, (len + cols - 1) / cols);
        }
        self.total_rows = total;
    }

    /// Works out `h` (and the rows shown) for a content width; decodes a
    /// picture on its first layout.
    fn layout(self: *Out, gpa: std.mem.Allocator, textures: ?*texture_mod.Textures, inner_w: f32, cols: u32) f32 {
        switch (self.kind) {
            .text, .err => {
                self.ensureRows(gpa, cols);
                self.rows = self.total_rows;
                self.first_row = 0;
                var h: f32 = 0;
                if (self.total_rows > max_out_rows) {
                    self.rows = shown_rows;
                    self.first_row = self.total_rows - shown_rows;
                    h += line_h; // "··· N earlier lines"
                }
                h += @as(f32, @floatFromInt(@max(1, self.rows))) * line_h;
                self.h = h;
            },
            .picture => {
                self.decode(gpa, textures);
                if (self.tex_state != .ready) {
                    self.h = line_h;
                } else {
                    const nw: f32 = @floatFromInt(@max(1, self.native_w));
                    const nh: f32 = @floatFromInt(@max(1, self.native_h));
                    const w = @min(nw, inner_w);
                    self.h = @min(image_max_h, nh * w / nw);
                }
            },
            .table => self.h = self.table.?.height(),
            .note => self.h = line_h,
        }
        return self.h;
    }

    fn decode(self: *Out, gpa: std.mem.Allocator, textures: ?*texture_mod.Textures) void {
        if (self.tex_state != .pending) return;
        const t = textures orelse return; // headless without a renderer: stays pending
        var img = image.decodeBytes(gpa, self.png, image.max_image_px) catch {
            self.tex_state = .failed;
            return;
        };
        defer img.bitmap.deinit(gpa);
        self.tex = t.upload(img.bitmap) catch {
            self.tex_state = .failed;
            return;
        };
        self.native_w = img.native_w;
        self.native_h = img.native_h;
        self.tex_state = .ready;
    }

    /// The plain text, for the agent (the last lines).
    fn plainText(self: *const Out, arena: std.mem.Allocator, max_lines: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        switch (self.kind) {
            .text, .err => {
                const n = self.buf.lineCount();
                const from = n -| max_lines;
                if (from > 0) try out.appendSlice(arena, "[…]\n");
                for (self.buf.lines.items[from..n]) |line| {
                    const cells = line.cells.items;
                    var end = cells.len;
                    while (end > 0 and cells[end - 1].cp == ' ') end -= 1;
                    for (cells[0..end]) |cell| {
                        var utf8: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cell.cp, &utf8) catch continue;
                        try out.appendSlice(arena, utf8[0..len]);
                    }
                    try out.append(arena, '\n');
                }
            },
            .picture => try out.appendSlice(arena, "[an image]\n"),
            .table => {
                const t = &self.table.?;
                for (t.columns, 0..) |c, i| {
                    if (i > 0) try out.appendSlice(arena, "\t");
                    try out.appendSlice(arena, c);
                }
                try out.append(arena, '\n');
                for (t.rows[0..@min(t.rows.len, max_lines)]) |r| {
                    for (r, 0..) |c, i| {
                        if (i > 0) try out.appendSlice(arena, "\t");
                        try out.appendSlice(arena, c);
                    }
                    try out.append(arena, '\n');
                }
            },
            .note => {
                try out.appendSlice(arena, self.note);
                try out.append(arena, '\n');
            },
        }
        return out.toOwnedSlice(arena);
    }
};

/// A string, or a list of strings joined (nbformat's multiline strings).
fn multiline(gpa: std.mem.Allocator, v: std.json.Value) ?[]u8 {
    switch (v) {
        .string => |s| return gpa.dupe(u8, s) catch null,
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            for (a.items) |item| switch (item) {
                .string => |s| out.appendSlice(gpa, s) catch {},
                else => {},
            };
            return out.toOwnedSlice(gpa) catch null;
        },
        else => return null,
    }
}

fn decodeBase64(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const upper = decoder.calcSizeUpperBound(text.len);
    const buf = gpa.alloc(u8, upper) catch return null;
    const n = decoder.decode(buf, text) catch {
        gpa.free(buf);
        return null;
    };
    if (n == 0) {
        gpa.free(buf);
        return null;
    }
    return gpa.realloc(buf, n) catch buf[0..n];
}

fn stringList(gpa: std.mem.Allocator, v: std.json.Value) ?[][]u8 {
    if (v != .array) return null;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (v.array.items) |item| {
        const s = switch (item) {
            .string => |s| gpa.dupe(u8, s) catch return null,
            .integer => |i| std.fmt.allocPrint(gpa, "{d}", .{i}) catch return null,
            .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}) catch return null,
            .bool => |b| gpa.dupe(u8, if (b) "true" else "false") catch return null,
            .null => gpa.dupe(u8, "") catch return null,
            else => gpa.dupe(u8, "…") catch return null,
        };
        list.append(gpa, s) catch {
            gpa.free(s);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn parseTable(gpa: std.mem.Allocator, v: std.json.Value) ?Table {
    if (v != .object) return null;
    const columns = stringList(gpa, v.object.get("columns") orelse return null) orelse return null;
    var ok = false;
    defer if (!ok) {
        for (columns) |s| gpa.free(s);
        gpa.free(columns);
    };
    var dtypes: ?[][]u8 = null;
    if (v.object.get("dtypes")) |d| dtypes = stringList(gpa, d);
    errdefer if (dtypes) |d| {
        for (d) |s| gpa.free(s);
        gpa.free(d);
    };
    var rows: std.ArrayList([][]u8) = .empty;
    errdefer {
        for (rows.items) |r| {
            for (r) |s| gpa.free(s);
            gpa.free(r);
        }
        rows.deinit(gpa);
    }
    if (v.object.get("rows")) |rs| if (rs == .array) {
        for (rs.array.items) |r| {
            const row = stringList(gpa, r) orelse continue;
            rows.append(gpa, row) catch {
                for (row) |s| gpa.free(s);
                gpa.free(row);
                return null;
            };
        }
    };
    const truncated = if (v.object.get("truncated")) |t| (t == .bool and t.bool) else false;
    const widths = gpa.alloc(f32, columns.len) catch return null;
    @memset(widths, 0);
    ok = true;
    return .{ .columns = columns, .dtypes = dtypes, .rows = rows.toOwnedSlice(gpa) catch return null, .truncated = truncated, .widths = widths };
}

// ── cells ────────────────────────────────────────────────────────────────
/// An `input()` the kernel is waiting on.
const Input = struct {
    prompt: []u8,
    password: bool,
    ed: TextEditor,
};

const Cell = struct {
    id: []u8,
    kind: Kind,
    /// The source (a shell cell: without its magic line; an ask cell: the question).
    ed: TextEditor,
    /// Markdown cells: the rendered view over `ed`.
    view: ?MarkdownView = null,
    /// Shell cells: the first line of the source ("%%sh").
    magic: []u8 = &.{},
    /// The cell's metadata as JSON object text ("" = `{}`).
    metadata: []u8 = &.{},
    outputs: std.ArrayList(Out) = .empty,
    count: ?i64 = null,
    state: RunState = .idle,
    t_start: f64 = 0,
    t_end: f64 = 0,
    /// Shell cells: the script's exit status when it failed.
    exit_code: ?i32 = null,
    /// Outputs are cleared on the next one (`clear_output(wait=True)`).
    clear_pending: bool = false,
    input: ?Input = null,
    /// Folded away (Jupyter's `jupyter.source_hidden` / `outputs_hidden`):
    /// the input shows as its first line, the outputs as one summary line.
    input_hidden: bool = false,
    outputs_hidden: bool = false,
    salt: usize,
    /// From the last layout.
    h: f32 = 0,
    src_h: f32 = 0,
    /// The outputs block with its separator and padding (0 = none).
    out_h: f32 = 0,

    fn create(gpa: std.mem.Allocator, id: []const u8, kind: Kind, source: []const u8) !*Cell {
        const self = try gpa.create(Cell);
        errdefer gpa.destroy(self);
        const s = salt();
        self.* = .{ .id = try gpa.dupe(u8, id), .kind = kind, .ed = TextEditor.init(gpa, s), .salt = s };
        errdefer gpa.free(self.id);
        self.ed.gutter = kind.numbered();
        self.ed.pad_top = src_pad;
        self.ed.pad_bottom = src_pad;
        try self.ed.load(source, kind.language());
        if (kind == .ask) self.ed.read_only = true;
        if (kind == .md) self.makeView(gpa);
        return self;
    }

    fn makeView(self: *Cell, gpa: std.mem.Allocator) void {
        var v = MarkdownView.init(gpa, self.salt);
        v.pad_top = 6;
        v.pad_bottom = 10;
        v.side_pad = theme.block_pad_x;
        self.view = v;
    }

    fn destroy(self: *Cell, gpa: std.mem.Allocator, textures: ?*texture_mod.Textures) void {
        self.clearOutputs(gpa, textures);
        self.outputs.deinit(gpa);
        if (self.view) |*v| v.deinit();
        self.ed.deinit();
        if (self.input) |*i| {
            gpa.free(i.prompt);
            i.ed.deinit();
        }
        gpa.free(self.magic);
        gpa.free(self.metadata);
        gpa.free(self.id);
        gpa.destroy(self);
    }

    fn clearOutputs(self: *Cell, gpa: std.mem.Allocator, textures: ?*texture_mod.Textures) void {
        for (self.outputs.items) |*o| o.deinit(gpa, textures);
        self.outputs.clearRetainingCapacity();
        self.clear_pending = false;
    }

    fn setKind(self: *Cell, gpa: std.mem.Allocator, kind: Kind, textures: ?*texture_mod.Textures) void {
        if (self.kind == kind) return;
        self.kind = kind;
        self.ed.doc.setLanguage(kind.language());
        self.ed.gutter = kind.numbered();
        if (kind == .md) {
            if (self.view == null) self.makeView(gpa);
            self.clearOutputs(gpa, textures);
            self.count = null;
            self.state = .idle;
        } else if (self.view) |*v| {
            v.deinit();
            self.view = null;
        }
        if (kind == .sh and self.magic.len == 0) self.magic = gpa.dupe(u8, "%%sh") catch &.{};
    }

    fn running(self: *const Cell) bool {
        return self.state == .queued or self.state == .running;
    }

    /// The source as the kernel and the file get it.
    fn fullSource(self: *const Cell, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        if (self.kind == .sh) {
            try out.appendSlice(gpa, if (self.magic.len > 0) self.magic else "%%sh");
            try out.append(gpa, '\n');
        }
        try out.appendSlice(gpa, self.ed.doc.bytes());
    }

    fn duration(self: *const Cell, now: f64) f64 {
        if (self.t_start == 0) return 0;
        return (if (self.state == .running or self.state == .queued) now else self.t_end) - self.t_start;
    }
};

// ── folded cells in the file ─────────────────────────────────────────────
/// nbformat's way of saying a cell is folded: `metadata.jupyter.source_hidden`
/// and `metadata.jupyter.outputs_hidden` (Jupyter Lab), plus the older
/// `metadata.collapsed` for the outputs.
const Hidden = struct { input: bool = false, outputs: bool = false };

fn hiddenIn(gpa: std.mem.Allocator, metadata: []const u8) Hidden {
    if (metadata.len == 0) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, metadata, .{}) catch return .{};
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{};
    var h: Hidden = .{};
    if (root.object.get("collapsed")) |c| if (c == .bool and c.bool) {
        h.outputs = true;
    };
    if (root.object.get("jupyter")) |j| if (j == .object) {
        if (j.object.get("source_hidden")) |v| if (v == .bool) {
            h.input = v.bool;
        };
        if (j.object.get("outputs_hidden")) |v| if (v == .bool) {
            h.outputs = v.bool;
        };
    };
    return h;
}

/// `metadata` with the fold state written the way Jupyter Lab writes it;
/// everything else in it stays. "" when nothing is left. Caller frees.
fn metadataWith(gpa: std.mem.Allocator, metadata: []const u8, h: Hidden) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root: std.json.Value = if (metadata.len == 0) .{ .object = .empty } else std.json.parseFromSliceLeaky(std.json.Value, a, metadata, .{}) catch .{ .object = .empty };
    if (root != .object) root = .{ .object = .empty };
    _ = root.object.orderedRemove("collapsed");
    var jup: std.json.Value = root.object.get("jupyter") orelse .{ .object = .empty };
    if (jup != .object) jup = .{ .object = .empty };
    if (h.input) try jup.object.put(a, "source_hidden", .{ .bool = true }) else _ = jup.object.orderedRemove("source_hidden");
    if (h.outputs) try jup.object.put(a, "outputs_hidden", .{ .bool = true }) else _ = jup.object.orderedRemove("outputs_hidden");
    if (jup.object.count() == 0) _ = root.object.orderedRemove("jupyter") else try root.object.put(a, "jupyter", jup);
    if (root.object.count() == 0) return gpa.dupe(u8, "");
    return std.json.Stringify.valueAlloc(gpa, root, .{});
}

// ── the tab ──────────────────────────────────────────────────────────────
pub const NotebookTab = struct {
    pub const kind_label = "Notebook";

    gpa: std.mem.Allocator,
    env: *tab_mod.Env,
    file_path: []u8,
    cells: std.ArrayList(*Cell) = .empty,
    /// The notebook's own metadata (kernelspec, language_info …), kept for the file.
    nb_metadata: []u8 = &.{},
    nbformat: i64 = 4,
    nbformat_minor: i64 = 5,
    kernel_name: []u8 = &.{},
    file_state: enum { ok, failed, not_notebook } = .ok,
    total_size: usize = 0,
    writable: bool = true,
    disk_mtime: i128 = 0,
    disk_changed: bool = false,
    missing: bool = false,
    save_failed: bool = false,
    just_saved: bool = false,
    saved_at: f64 = -1e9,
    last_check: f64 = 0,
    /// Cells added, removed, retyped or run since the last save.
    dirty: bool = false,
    now: f64 = 0,

    /// Which cell has the keyboard; null = the input row at the bottom.
    focus_cell: ?usize = 0,
    /// The input row: what a new cell is made of.
    input: TextEditor,
    input_kind: Kind = .py,
    scroll: f32 = 0,
    content_h: f32 = 0,
    view_h: f32 = 0,
    /// Scroll so this cell shows, on the next draw.
    reveal: ?usize = null,
    inspector: bool = false,
    inspector_page: enum { variables, kernel } = .variables,
    inspector_scroll: f32 = 0,
    was_focused: bool = false,
    last_anim: f64 = 0,

    // The kernel.
    kernel: ?*bridge.Kernel = null,
    interps: std.ArrayList([]u8) = .empty,
    script: []const u8 = "",
    kernel_version: []u8 = &.{},
    kernel_display: []u8 = &.{},
    kernel_language: []u8 = &.{},
    kernel_interpreter: []u8 = &.{},
    memory_mb: i64 = 0,
    vars: []bridge.Var = &.{},
    /// The Python the install hint names when none has Jupyter.
    no_jupyter_python: []u8 = &.{},
    events: std.ArrayList(bridge.Event) = .empty,

    // The agent (ask cells).
    ask_req: ?*agent.Request = null,
    ask_cell: []u8 = &.{},

    pub fn accepts(file_path: []const u8, head: []const u8) bool {
        if (!filetype.hasExtension(file_path, &.{"ipynb"})) return false;
        const trimmed = std.mem.trimStart(u8, head, " \t\r\n");
        return trimmed.len == 0 or trimmed[0] == '{';
    }

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        var kept = try viewer.kept(env.gpa, args.saved);
        defer if (kept) |*k| k.deinit(env.gpa);
        const file_path = args.path orelse if (kept) |k| k.path else return error.MissingPath;
        const self = try env.gpa.create(NotebookTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .env = env, .file_path = try env.gpa.dupe(u8, file_path), .input = TextEditor.init(env.gpa, salt()) };
        errdefer env.gpa.free(self.file_path);
        self.input.gutter = false;
        self.input.pad_top = 10;
        self.input.pad_bottom = 10;
        self.input.load("", .python) catch {};
        self.load();
        if (kept) |k| self.restoreKept(k, args.saved orelse "");
        if (self.cells.items.len == 0) self.focus_cell = null;
        return tab_mod.Tab.from(NotebookTab, self);
    }

    pub fn deinit(self: *NotebookTab) void {
        if (self.ask_req) |r| r.release();
        self.gpa.free(self.ask_cell);
        if (self.kernel) |k| k.destroy();
        for (self.events.items) |*e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.clearCells();
        self.cells.deinit(self.gpa);
        for (self.interps.items) |p| self.gpa.free(p);
        self.interps.deinit(self.gpa);
        self.freeVars();
        self.gpa.free(self.kernel_version);
        self.gpa.free(self.kernel_display);
        self.gpa.free(self.kernel_language);
        self.gpa.free(self.kernel_interpreter);
        self.gpa.free(self.no_jupyter_python);
        self.gpa.free(self.nb_metadata);
        self.gpa.free(self.kernel_name);
        self.input.deinit();
        self.gpa.free(self.file_path);
        self.gpa.destroy(self);
    }

    fn freeVars(self: *NotebookTab) void {
        for (self.vars) |v| {
            self.gpa.free(v.name);
            self.gpa.free(v.kind);
            self.gpa.free(v.value);
        }
        self.gpa.free(self.vars);
        self.vars = &.{};
    }

    fn clearCells(self: *NotebookTab) void {
        for (self.cells.items) |c| c.destroy(self.gpa, self.env.textures);
        self.cells.clearRetainingCapacity();
    }

    // ── the file ────────────────────────────────────────────────────────
    fn load(self: *NotebookTab) void {
        self.clearCells();
        self.gpa.free(self.nb_metadata);
        self.nb_metadata = &.{};
        self.file_state = .ok;
        self.missing = false;
        self.disk_changed = false;
        self.dirty = false;
        const head = sys.readFileHead(self.gpa, self.file_path, max_file_bytes) catch {
            self.file_state = .failed;
            return;
        };
        defer if (head.data.len > 0) self.gpa.free(head.data);
        self.total_size = head.total;
        self.writable = sys.isWritable(self.gpa, self.file_path);
        if (sys.statFile(self.gpa, self.file_path)) |st| self.disk_mtime = st.mtime_ns;
        const trimmed = std.mem.trim(u8, head.data, " \t\r\n");
        var nb = if (trimmed.len == 0) ipynb.Notebook.init(self.gpa) else ipynb.parse(self.gpa, head.data) catch {
            self.file_state = .not_notebook;
            return;
        };
        defer nb.deinit();
        self.nb_metadata = self.gpa.dupe(u8, nb.metadata) catch &.{};
        self.nbformat = nb.nbformat;
        self.nbformat_minor = nb.nbformat_minor;
        var name_buf: [128]u8 = undefined;
        self.gpa.free(self.kernel_name);
        self.kernel_name = self.gpa.dupe(u8, nb.kernelName(&name_buf) orelse "python3") catch &.{};
        for (nb.cells.items) |*c| {
            const kind: Kind = switch (c.kind) {
                .code => if (ipynb.shellMagic(c.source) != null) .sh else .py,
                .markdown => .md,
                .raw => if (askAnswer(self.gpa, c.metadata)) |answer| blk: {
                    defer self.gpa.free(answer);
                    break :blk .ask;
                } else .raw,
            };
            const body = if (kind == .sh) ipynb.afterFirstLine(c.source) else c.source;
            const cell = Cell.create(self.gpa, c.id, kind, body) catch continue;
            if (kind == .sh) cell.magic = self.gpa.dupe(u8, ipynb.shellMagic(c.source).?) catch &.{};
            cell.metadata = self.gpa.dupe(u8, c.metadata) catch &.{};
            const hidden = hiddenIn(self.gpa, c.metadata);
            cell.input_hidden = hidden.input;
            cell.outputs_hidden = hidden.outputs;
            cell.count = c.execution_count;
            if (kind == .ask) {
                if (askAnswer(self.gpa, c.metadata)) |answer| {
                    defer self.gpa.free(answer);
                    const o: ipynb.Output = .{ .kind = .stream, .name = self.gpa.dupe(u8, "stdout") catch &.{}, .text = self.gpa.dupe(u8, answer) catch &.{} };
                    cell.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
                }
                cell.state = .done;
            }
            // The outputs move over: the notebook no longer owns them.
            for (c.outputs.items) |o| cell.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
            c.outputs.clearRetainingCapacity();
            if (cell.outputs.items.len > 0 or cell.count != null) cell.state = if (hasError(cell)) .failed else .done;
            self.cells.append(self.gpa, cell) catch cell.destroy(self.gpa, self.env.textures);
        }
        if (self.focus_cell) |f| if (f >= self.cells.items.len) {
            self.focus_cell = if (self.cells.items.len == 0) null else self.cells.items.len - 1;
        };
    }

    fn hasError(cell: *const Cell) bool {
        for (cell.outputs.items) |o| if (o.kind == .err) return true;
        return false;
    }

    /// The agent's answer kept in an ask cell's metadata (`tt.answer`).
    fn askAnswer(gpa: std.mem.Allocator, metadata: []const u8) ?[]u8 {
        if (metadata.len == 0) return null;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, metadata, .{}) catch return null;
        defer parsed.deinit();
        const tt = switch (parsed.value) {
            .object => |o| o.get("tt") orelse return null,
            else => return null,
        };
        if (tt != .object) return null;
        const kind = tt.object.get("kind") orelse return null;
        if (kind != .string or !std.mem.eql(u8, kind.string, "ask")) return null;
        const answer = tt.object.get("answer") orelse std.json.Value{ .string = "" };
        return switch (answer) {
            .string => |s| gpa.dupe(u8, s) catch null,
            else => gpa.dupe(u8, "") catch null,
        };
    }

    fn modified(self: *const NotebookTab) bool {
        if (self.dirty) return true;
        for (self.cells.items) |c| if (c.ed.doc.modified()) return true;
        return false;
    }

    fn editable(self: *const NotebookTab) bool {
        return self.file_state == .ok and self.writable;
    }

    /// Writes the notebook back as nbformat 4.
    fn saveFile(self: *NotebookTab) bool {
        if (self.file_state == .failed and !sys.exists(self.gpa, self.file_path)) {
            // A file that could not be read but can be created: fine.
        } else if (!self.editable()) return false;
        var nb = ipynb.Notebook.init(self.gpa);
        defer nb.deinit();
        nb.metadata = self.gpa.dupe(u8, self.nb_metadata) catch return false;
        nb.nbformat = self.nbformat;
        nb.nbformat_minor = self.nbformat_minor;
        for (self.cells.items) |c| {
            var source: std.ArrayList(u8) = .empty;
            defer source.deinit(self.gpa);
            c.fullSource(&source, self.gpa) catch return false;
            const kind: ipynb.CellKind = switch (c.kind) {
                .py, .sh => .code,
                .md => .markdown,
                .raw, .ask => .raw,
            };
            const cell = nb.insertCell(nb.cells.items.len, kind, source.items) catch return false;
            self.gpa.free(cell.id);
            cell.id = self.gpa.dupe(u8, c.id) catch return false;
            self.gpa.free(cell.metadata);
            const base_meta = if (c.kind == .ask) self.askMetadata(c) catch return false else self.gpa.dupe(u8, c.metadata) catch return false;
            defer self.gpa.free(base_meta);
            cell.metadata = metadataWith(self.gpa, base_meta, .{ .input = c.input_hidden, .outputs = c.outputs_hidden }) catch return false;
            cell.execution_count = c.count;
            if (kind == .code) {
                for (c.outputs.items) |o| {
                    const dup = dupOutput(self.gpa, o.src) catch return false;
                    cell.outputs.append(self.gpa, dup) catch return false;
                }
            }
        }
        const text = ipynb.write(&nb, self.gpa, config.get().notebooks.strip_outputs) catch return false;
        defer self.gpa.free(text);
        sys.writeFileAtomic(self.gpa, self.file_path, text) catch {
            self.save_failed = true;
            return false;
        };
        self.save_failed = false;
        for (self.cells.items) |c| c.ed.doc.markSaved();
        self.dirty = false;
        self.file_state = .ok;
        self.writable = true;
        if (sys.statFile(self.gpa, self.file_path)) |st| {
            self.disk_mtime = st.mtime_ns;
            self.total_size = st.size;
        }
        self.disk_changed = false;
        self.missing = false;
        self.just_saved = true;
        return true;
    }

    /// `{"tt":{"kind":"ask","answer":"…"}}` for an ask cell.
    fn askMetadata(self: *NotebookTab, c: *const Cell) ![]u8 {
        var answer: std.ArrayList(u8) = .empty;
        defer answer.deinit(self.gpa);
        if (c.outputs.items.len > 0) try c.outputs.items[0].buf.appendText(&answer, self.gpa);
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("tt") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("kind") catch return error.OutOfMemory;
        js.write("ask") catch return error.OutOfMemory;
        js.objectField("answer") catch return error.OutOfMemory;
        js.write(answer.items) catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn dupOutput(gpa: std.mem.Allocator, o: ipynb.Output) !ipynb.Output {
        var dup: ipynb.Output = .{ .kind = o.kind, .execution_count = o.execution_count };
        errdefer dup.deinit(gpa);
        dup.name = try gpa.dupe(u8, o.name);
        dup.text = try gpa.dupe(u8, o.text);
        dup.data = try gpa.dupe(u8, o.data);
        dup.metadata = try gpa.dupe(u8, o.metadata);
        dup.ename = try gpa.dupe(u8, o.ename);
        dup.evalue = try gpa.dupe(u8, o.evalue);
        return dup;
    }

    /// The file changed under us: reload when nothing is edited here.
    fn checkDisk(self: *NotebookTab) bool {
        const st = sys.statFile(self.gpa, self.file_path) orelse {
            if (self.missing) return false;
            self.missing = true;
            return true;
        };
        if (self.missing) {
            self.missing = false;
            self.disk_changed = true;
            return true;
        }
        if (st.mtime_ns == self.disk_mtime) return false;
        self.disk_mtime = st.mtime_ns;
        if (self.modified()) {
            self.disk_changed = true;
            return true;
        }
        const focus = self.focus_cell;
        const scroll = self.scroll;
        self.load();
        self.focus_cell = if (focus) |f| @min(f, self.cells.items.len -| 1) else null;
        if (self.cells.items.len == 0) self.focus_cell = null;
        self.scroll = scroll;
        return true;
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// After the file record: the focused cell, the scroll, the inspector
    /// and the input row's kind; then one `cell` record per cell with
    /// results or folds (id, count, how long it ran in ms, fold flags,
    /// outputs as JSON), within a budget.
    fn keptFields(self: *const NotebookTab, buf: []u8) []const u8 {
        const focus: i64 = if (self.focus_cell) |f| @intCast(f) else -1;
        return std.fmt.bufPrint(buf, "{d}\t{d}\t{d}\t{s}", .{ focus, @as(i64, @intFromFloat(self.scroll)), @as(u8, if (self.inspector) 1 else 0), @tagName(self.input_kind) }) catch "";
    }

    pub fn save(self: *NotebookTab, out: *std.ArrayList(u8)) bool {
        var buf: [96]u8 = undefined;
        if (!viewer.keep(out, self.gpa, self.file_path, self.keptFields(&buf))) return false;
        var budget: usize = max_kept_bytes;
        for (self.cells.items) |c| {
            if (c.outputs.items.len == 0 and c.count == null and !c.input_hidden and !c.outputs_hidden) continue;
            var srcs: std.ArrayList(ipynb.Output) = .empty;
            defer srcs.deinit(self.gpa);
            for (c.outputs.items) |o| srcs.append(self.gpa, o.src) catch return true;
            const json = ipynb.outputsText(self.gpa, srcs.items) catch return true;
            defer self.gpa.free(json);
            if (json.len > budget) continue;
            budget -= json.len;
            out.appendSlice(self.gpa, "cell\t") catch return true;
            records.escape(out, self.gpa, c.id) catch return true;
            if (c.count) |n| out.print(self.gpa, "\t{d}", .{n}) catch return true else out.appendSlice(self.gpa, "\t-") catch return true;
            const ms: i64 = @intFromFloat(@max(0, c.duration(self.now)) * 1000);
            out.print(self.gpa, "\t{d}\t{s}{s}{s}\t", .{ ms, if (c.input_hidden) "i" else "", if (c.outputs_hidden) "o" else "", if (!c.input_hidden and !c.outputs_hidden) "-" else "" }) catch return true;
            records.escape(out, self.gpa, json) catch return true;
            out.append(self.gpa, '\n') catch return true;
        }
        return true;
    }

    pub fn saveVersion(self: *NotebookTab) u64 {
        var buf: [96]u8 = undefined;
        var h = std.hash.Wyhash.init(viewer.keptVersion(self.file_path, self.keptFields(&buf)));
        for (self.cells.items) |c| {
            h.update(c.id);
            h.update(&[_]u8{ @intFromBool(c.input_hidden), @intFromBool(c.outputs_hidden) });
            if (c.count) |n| h.update(std.mem.asBytes(&n));
            for (c.outputs.items) |o| {
                h.update(std.mem.asBytes(&o.buf.version));
                h.update(std.mem.asBytes(&o.src.text.len));
                h.update(std.mem.asBytes(&o.src.data.len));
            }
        }
        return h.final();
    }

    fn restoreKept(self: *NotebookTab, k: viewer.Kept, saved: []const u8) void {
        if (k.field(0)) |f| {
            const focus = std.fmt.parseInt(i64, f, 10) catch -1;
            self.focus_cell = if (focus < 0 or focus >= @as(i64, @intCast(self.cells.items.len))) null else @intCast(focus);
        }
        if (k.field(1)) |s| self.scroll = @floatFromInt(std.fmt.parseInt(i64, s, 10) catch 0);
        if (k.field(2)) |i| self.inspector = std.mem.eql(u8, i, "1");
        if (k.field(3)) |kind| self.input_kind = std.meta.stringToEnum(Kind, kind) orelse .py;
        var id_buf: std.ArrayList(u8) = .empty;
        defer id_buf.deinit(self.gpa);
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.gpa);
        var lines = std.mem.splitScalar(u8, saved, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, '\t');
            if (!std.mem.eql(u8, f.next() orelse continue, "cell")) continue;
            const id = records.unescape(&id_buf, self.gpa, f.next() orelse continue) catch continue;
            const cell = self.cellById(id) orelse continue;
            const count_text = f.next() orelse continue;
            const ms_text = f.next() orelse continue;
            const flags = f.next() orelse continue;
            cell.input_hidden = std.mem.indexOfScalar(u8, flags, 'i') != null;
            cell.outputs_hidden = std.mem.indexOfScalar(u8, flags, 'o') != null;
            const json = records.unescape(&json_buf, self.gpa, f.rest()) catch continue;
            var outs: std.ArrayList(ipynb.Output) = .empty;
            defer outs.deinit(self.gpa);
            ipynb.parseOutputs(self.gpa, json, &outs) catch continue;
            cell.clearOutputs(self.gpa, self.env.textures);
            for (outs.items) |o| cell.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
            cell.count = std.fmt.parseInt(i64, count_text, 10) catch null;
            // Any base works for a finished cell: only the difference shows.
            cell.t_start = 1;
            cell.t_end = 1 + @as(f64, @floatFromInt(std.fmt.parseInt(u64, ms_text, 10) catch 0)) / 1000;
            if (cell.outputs.items.len > 0 or cell.count != null) cell.state = if (hasError(cell)) .failed else .done;
        }
    }

    fn cellById(self: *NotebookTab, id: []const u8) ?*Cell {
        for (self.cells.items) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    fn indexOfCell(self: *NotebookTab, cell: *Cell) ?usize {
        for (self.cells.items, 0..) |c, i| if (c == cell) return i;
        return null;
    }

    // ── cells ───────────────────────────────────────────────────────────
    fn addCell(self: *NotebookTab, at: usize, kind: Kind, source: []const u8) ?*Cell {
        var id_buf: [ipynb.id_len]u8 = undefined;
        const cell = Cell.create(self.gpa, ipynb.newId(&id_buf), kind, source) catch return null;
        if (kind == .sh) cell.magic = self.gpa.dupe(u8, "%%sh") catch &.{};
        const index = @min(at, self.cells.items.len);
        self.cells.insert(self.gpa, index, cell) catch {
            cell.destroy(self.gpa, self.env.textures);
            return null;
        };
        if (self.focus_cell) |f| if (f >= index) {
            self.focus_cell = f + 1;
        };
        self.dirty = true;
        return cell;
    }

    fn deleteCell(self: *NotebookTab, i: usize) void {
        if (i >= self.cells.items.len) return;
        const cell = self.cells.orderedRemove(i);
        if (std.mem.eql(u8, cell.id, self.ask_cell)) self.stopAsk();
        cell.destroy(self.gpa, self.env.textures);
        self.dirty = true;
        if (self.focus_cell) |f| {
            if (self.cells.items.len == 0) {
                self.focus_cell = null;
            } else if (f > i or f >= self.cells.items.len) {
                self.focus_cell = @min(f -| 1, self.cells.items.len - 1);
            }
        }
    }

    fn moveCell(self: *NotebookTab, i: usize, up: bool) void {
        const n = self.cells.items.len;
        if (up and i == 0) return;
        if (!up and i + 1 >= n) return;
        const j = if (up) i - 1 else i + 1;
        std.mem.swap(*Cell, &self.cells.items[i], &self.cells.items[j]);
        if (self.focus_cell) |f| {
            if (f == i) self.focus_cell = j else if (f == j) self.focus_cell = i;
        }
        self.reveal = j;
        self.dirty = true;
    }

    fn focusCell(self: *NotebookTab, i: ?usize, caret_at_end: bool) void {
        self.focus_cell = i;
        if (i) |index| {
            const cell = self.cells.items[index];
            const len = cell.ed.doc.bytes().len;
            cell.ed.doc.editor.setCursor(if (caret_at_end) len else 0, false);
            cell.ed.follow = true;
            if (cell.view) |*v| v.follow = true;
            self.reveal = index;
        } else {
            self.input.follow = true;
        }
    }

    /// After ⇧↵ on cell `i`: the next cell, or a new one when it was the last.
    fn advance(self: *NotebookTab, i: usize) void {
        if (i + 1 < self.cells.items.len) {
            self.focusCell(i + 1, false);
        } else if (self.addCell(self.cells.items.len, .py, "")) |_| {
            self.focusCell(self.cells.items.len - 1, false);
        }
    }

    // ── the kernel ──────────────────────────────────────────────────────
    fn ensureKernel(self: *NotebookTab) void {
        if (self.kernel != null) return;
        if (self.env.integration_dir.len == 0) return;
        if (self.script.len == 0) self.script = bridge.scriptPath(self.gpa, self.env.integration_dir) catch return;
        if (self.interps.items.len == 0) bridge.interpreters(self.gpa, sys.dirname(self.file_path), &self.interps) catch {};
        self.kernel = bridge.Kernel.create(self.gpa, .{
            .script = self.script,
            .cwd = sys.dirname(self.file_path),
            .kernel_name = if (self.kernel_name.len > 0) self.kernel_name else "python3",
            .interpreters = self.interps.items,
        }) catch null;
    }

    fn runCell(self: *NotebookTab, i: usize) void {
        if (i >= self.cells.items.len) return;
        const cell = self.cells.items[i];
        if (!cell.kind.runs()) return;
        self.ensureKernel();
        const k = self.kernel orelse return;
        if (k.phase == .failed) return;
        cell.clearOutputs(self.gpa, self.env.textures);
        cell.count = null;
        cell.exit_code = null;
        cell.state = .queued;
        cell.t_start = self.now;
        cell.t_end = 0;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(self.gpa);
        cell.fullSource(&source, self.gpa) catch return;
        k.exec(cell.id, source.items);
        self.dirty = true;
    }

    fn runAll(self: *NotebookTab) void {
        for (self.cells.items, 0..) |c, i| if (c.kind.runs()) self.runCell(i);
    }

    fn interrupt(self: *NotebookTab) void {
        const k = self.kernel orelse return;
        k.interrupt();
    }

    fn restartKernel(self: *NotebookTab) void {
        self.ensureKernel();
        const k = self.kernel orelse return;
        for (self.cells.items) |c| if (c.running()) {
            c.state = .aborted;
            c.t_end = self.now;
        };
        self.freeVars();
        self.memory_mb = 0;
        k.restart();
    }

    fn clearAllOutputs(self: *NotebookTab) void {
        for (self.cells.items) |c| {
            if (c.kind == .ask) continue;
            c.clearOutputs(self.gpa, self.env.textures);
            c.count = null;
            c.exit_code = null;
            if (!c.running()) c.state = .idle;
        }
        self.dirty = true;
    }

    fn anyRunning(self: *const NotebookTab) bool {
        for (self.cells.items) |c| if (c.running()) return true;
        return false;
    }

    /// One event from the bridge into the cells.
    fn apply(self: *NotebookTab, ev: *bridge.Event) void {
        switch (ev.*) {
            .ready => |*r| {
                self.gpa.free(self.kernel_version);
                self.kernel_version = r.version;
                r.version = &.{};
                self.gpa.free(self.kernel_display);
                self.kernel_display = r.display_name;
                r.display_name = &.{};
                self.gpa.free(self.kernel_language);
                self.kernel_language = r.language;
                r.language = &.{};
                self.gpa.free(self.kernel_interpreter);
                self.kernel_interpreter = r.interpreter;
                r.interpreter = &.{};
                if (self.kernel) |k| k.requestVars();
            },
            .phase => |p| if (p == .dead or p == .restarting or p == .failed) {
                for (self.cells.items) |c| if (c.running()) {
                    c.state = .aborted;
                    c.t_end = self.now;
                };
            },
            .fatal => |*f| {
                if (self.no_jupyter_python.len == 0 and f.python.len > 0) {
                    self.no_jupyter_python = f.python;
                    f.python = &.{};
                }
            },
            .status => |s| if (s.busy and s.cell.len > 0) {
                if (self.cellById(s.cell)) |c| if (c.state == .queued) {
                    c.state = .running;
                    c.t_start = self.now;
                };
            },
            .stream => |*s| if (self.cellById(s.cell)) |c| {
                if (c.clear_pending) c.clearOutputs(self.gpa, self.env.textures);
                const n = c.outputs.items.len;
                if (n > 0 and c.outputs.items[n - 1].src.kind == .stream and (std.mem.eql(u8, c.outputs.items[n - 1].src.name, "stderr") == s.stderr)) {
                    c.outputs.items[n - 1].append(self.gpa, s.text);
                } else {
                    const o: ipynb.Output = .{ .kind = .stream, .name = self.gpa.dupe(u8, if (s.stderr) "stderr" else "stdout") catch &.{}, .text = s.text };
                    s.text = &.{};
                    c.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
                }
            },
            .display => |*d| if (self.cellById(d.cell)) |c| {
                if (c.clear_pending) c.clearOutputs(self.gpa, self.env.textures);
                const o: ipynb.Output = .{ .kind = .display_data, .data = d.data, .metadata = d.metadata };
                d.data = &.{};
                d.metadata = &.{};
                c.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
            },
            .result => |*r| if (self.cellById(r.cell)) |c| {
                if (c.clear_pending) c.clearOutputs(self.gpa, self.env.textures);
                const o: ipynb.Output = .{ .kind = .execute_result, .data = r.data, .metadata = r.metadata, .execution_count = r.count };
                r.data = &.{};
                r.metadata = &.{};
                c.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
                if (r.count) |n| c.count = n;
            },
            .err => |*e| if (self.cellById(e.cell)) |c| {
                if (c.clear_pending) c.clearOutputs(self.gpa, self.env.textures);
                if (c.kind == .sh and std.mem.eql(u8, e.ename, "CalledProcessError")) {
                    // The script's exit status is the whole story; the
                    // Python traceback behind it is noise.
                    c.exit_code = exitStatusOf(e.evalue) orelse 1;
                } else {
                    const o: ipynb.Output = .{ .kind = .@"error", .ename = e.ename, .evalue = e.evalue, .text = e.traceback };
                    e.ename = &.{};
                    e.evalue = &.{};
                    e.traceback = &.{};
                    c.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
                }
            },
            .clear => |cl| if (self.cellById(cl.cell)) |c| {
                if (cl.wait) c.clear_pending = true else c.clearOutputs(self.gpa, self.env.textures);
            },
            .done => |d| if (self.cellById(d.cell)) |c| {
                c.state = switch (d.status) {
                    .ok => .done,
                    .@"error" => .failed,
                    .aborted => .aborted,
                };
                if (d.count) |n| c.count = n;
                c.t_end = self.now;
                if (c.t_start == 0) c.t_start = self.now;
                c.t_start = c.t_end - @as(f64, @floatFromInt(d.ms)) / 1000.0;
                if (c.input) |*inp| {
                    self.gpa.free(inp.prompt);
                    inp.ed.deinit();
                    c.input = null;
                }
            },
            .vars => |list| {
                self.freeVars();
                self.vars = list;
                ev.* = .{ .memory_mb = 0 };
            },
            .input_request => |*i| {
                const c = self.cellById(i.cell) orelse (if (self.cells.items.len > 0) self.cells.items[self.cells.items.len - 1] else return);
                if (c.input) |*old| {
                    self.gpa.free(old.prompt);
                    old.ed.deinit();
                }
                var ed = TextEditor.init(self.gpa, salt());
                ed.gutter = false;
                ed.pad_top = 4;
                ed.pad_bottom = 4;
                ed.load("", .plain) catch {};
                c.input = .{ .prompt = i.prompt, .password = i.password, .ed = ed };
                i.prompt = &.{};
                if (self.indexOfCell(c)) |idx| {
                    self.focus_cell = idx;
                    self.reveal = idx;
                }
            },
            .memory_mb => |mb| if (mb > 0) {
                self.memory_mb = mb;
            },
            .log => |text| if (sys.getenv("TT_DEBUG_EVENTS") != null) std.debug.print("notebook: {s}\n", .{text}),
        }
    }

    /// "… returned non-zero exit status 3." → 3
    fn exitStatusOf(evalue: []const u8) ?i32 {
        const key = "exit status ";
        const at = std.mem.lastIndexOf(u8, evalue, key) orelse return null;
        var end = at + key.len;
        while (end < evalue.len and std.ascii.isDigit(evalue[end])) end += 1;
        return std.fmt.parseInt(i32, evalue[at + key.len .. end], 10) catch null;
    }

    fn sendInput(self: *NotebookTab, cell: *Cell) void {
        const inp = &(cell.input orelse return);
        const k = self.kernel orelse return;
        k.input(inp.ed.doc.bytes());
        // The prompt and the answer stay in the output, as a terminal shows them.
        const n = cell.outputs.items.len;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        line.appendSlice(self.gpa, inp.prompt) catch {};
        line.appendSlice(self.gpa, if (inp.password) "••••" else inp.ed.doc.bytes()) catch {};
        line.append(self.gpa, '\n') catch {};
        if (n > 0 and cell.outputs.items[n - 1].src.kind == .stream) {
            cell.outputs.items[n - 1].append(self.gpa, line.items);
        } else {
            const o: ipynb.Output = .{ .kind = .stream, .name = self.gpa.dupe(u8, "stdout") catch &.{}, .text = self.gpa.dupe(u8, line.items) catch &.{} };
            cell.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
        }
        self.gpa.free(inp.prompt);
        inp.ed.deinit();
        cell.input = null;
    }

    // ── the agent ───────────────────────────────────────────────────────
    fn stopAsk(self: *NotebookTab) void {
        if (self.ask_req) |r| r.release();
        self.ask_req = null;
        self.gpa.free(self.ask_cell);
        self.ask_cell = &.{};
    }

    fn failAsk(self: *NotebookTab, cell: *Cell, why: []const u8) void {
        if (cell.outputs.items.len > 0) {
            const o = &cell.outputs.items[0];
            if (o.buf.lineCount() > 0) o.feed("\n");
            o.feed(why);
        }
        cell.state = .failed;
        cell.t_end = self.now;
    }

    /// A question typed in the input row: an ask cell, answered by the
    /// agent of Settings › AI › Features › Unrecognised commands.
    fn ask(self: *NotebookTab, question: []const u8) void {
        if (self.ask_req != null) return;
        const cell = self.addCell(self.cells.items.len, .ask, question) orelse return;
        const o: ipynb.Output = .{ .kind = .stream, .name = self.gpa.dupe(u8, "stdout") catch &.{}, .text = self.gpa.dupe(u8, "") catch &.{} };
        cell.outputs.append(self.gpa, Out.init(self.gpa, o)) catch {};
        cell.state = .running;
        cell.t_start = self.now;
        self.reveal = self.cells.items.len - 1;

        const cfg = config.get();
        const name = cfg.features.command_fallback_agent orelse return self.failAsk(cell, "No agent answers here yet: pick one under Settings › AI › Features › Unrecognised commands.");
        const a = cfg.findAgentByName(name) orelse return self.failAsk(cell, "The agent chosen under Settings › AI › Features is no longer set up.");

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const system = self.askSystemPrompt(arena) catch "";
        var messages: std.ArrayList(agent.Message) = .empty;
        self.askConversation(arena, &messages, cell, question) catch return self.failAsk(cell, "Out of memory.");
        var prepared = agent.prepare(self.gpa, a, system, messages.items, .{ .tools = true, .tool = .notebook_cell }) catch |err| {
            const why = switch (err) {
                error.NoModel => "The agent has no model set (Settings › AI › APIs).",
                error.NoApiKey => "The agent needs an API key (Settings › AI › APIs).",
                error.NoBaseUrl => "The agent has no base URL (Settings › AI › APIs).",
                error.OutOfMemory => "Out of memory.",
            };
            return self.failAsk(cell, why);
        };
        defer prepared.deinit(self.gpa);
        const req = agent.Request.start(&prepared) catch return self.failAsk(cell, "Out of memory.");
        self.ask_req = req;
        self.ask_cell = self.gpa.dupe(u8, cell.id) catch &.{};
    }

    fn askSystemPrompt(self: *NotebookTab, arena: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "You help the user in a Jupyter notebook, shown in a native macOS app. ");
        if (self.kernel_display.len > 0) {
            try out.print(arena, "The kernel is {s}", .{self.kernel_display});
            if (self.kernel_version.len > 0) try out.print(arena, " ({s} {s})", .{ self.kernel_language, self.kernel_version });
            try out.appendSlice(arena, ". ");
        } else {
            try out.appendSlice(arena, "The kernel is Python 3 (ipykernel). ");
        }
        try out.print(arena, "The notebook is {s} in {s}. ", .{ sys.basename(self.file_path), sys.dirname(self.file_path) });
        try out.appendSlice(arena, "The messages carry the notebook so far: its cells in order — Markdown, code with the outputs it gave, %%sh shell cells — then the user's question; read them before answering. When code would do what the user wants, call propose_command with the source of one new cell: it is added to the notebook under the question for the user to review and run, so never assume it ran and never make up its output; say in a line what it does. Answer in plain text, briefly: no Markdown headings or tables.");
        if (config.get().notebooks.share_schema and self.vars.len > 0) {
            try out.appendSlice(arena, "\n\nVariables in the kernel right now (name: type):");
            var n: usize = 0;
            for (self.vars) |v| {
                if (n >= 80) break;
                try out.print(arena, "{s} {s}: {s}", .{ if (n == 0) "" else ",", v.name, v.kind });
                n += 1;
            }
            try out.appendSlice(arena, ".");
        }
        return out.toOwnedSlice(arena);
    }

    /// Earlier ask cells as turns, the cells before this one as the
    /// transcript of the last turn, then the question.
    fn askConversation(self: *NotebookTab, arena: std.mem.Allocator, out: *std.ArrayList(agent.Message), current: *Cell, question: []const u8) !void {
        const Turn = struct { user: []const u8, answer: []const u8 };
        var turns: std.ArrayList(Turn) = .empty;
        var transcript: std.ArrayList([]const u8) = .empty;
        for (self.cells.items) |c| {
            if (c == current) break;
            if (c.kind != .ask) {
                try transcript.append(arena, try self.cellTranscript(arena, c));
                continue;
            }
            if (c.outputs.items.len == 0) continue;
            var text: std.ArrayList(u8) = .empty;
            try c.outputs.items[0].buf.appendText(&text, arena);
            const answer = std.mem.trim(u8, text.items, " \n");
            if (answer.len == 0) continue;
            try turns.append(arena, .{ .user = try userText(arena, transcript.items, c.ed.doc.bytes()), .answer = answer });
            transcript.clearRetainingCapacity();
        }
        const last = try userText(arena, transcript.items, question);
        var first = turns.items.len;
        var budget: usize = max_context_bytes -| last.len;
        while (first > 0) {
            const t = turns.items[first - 1];
            const size = t.user.len + t.answer.len;
            if (size > budget) break;
            budget -= size;
            first -= 1;
        }
        for (turns.items[first..]) |t| {
            try out.append(arena, .{ .role = .user, .text = t.user });
            try out.append(arena, .{ .role = .assistant, .text = t.answer });
        }
        try out.append(arena, .{ .role = .user, .text = last });
    }

    fn userText(arena: std.mem.Allocator, entries: []const []const u8, question: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = entries.len;
        var budget: usize = max_context_bytes;
        while (first > 0 and entries[first - 1].len <= budget) {
            budget -= entries[first - 1].len;
            first -= 1;
        }
        if (first < entries.len) {
            try out.appendSlice(arena, "The notebook, cell by cell:\n");
            if (first > 0) try out.appendSlice(arena, "[… earlier cells omitted]\n");
            for (entries[first..]) |e| try out.appendSlice(arena, e);
            try out.append(arena, '\n');
        }
        try out.appendSlice(arena, "The user asks:\n");
        try out.appendSlice(arena, question);
        return out.toOwnedSlice(arena);
    }

    fn cellTranscript(self: *NotebookTab, arena: std.mem.Allocator, c: *const Cell) ![]u8 {
        _ = self;
        var out: std.ArrayList(u8) = .empty;
        switch (c.kind) {
            .md => try out.appendSlice(arena, "--- markdown cell:\n"),
            .raw => try out.appendSlice(arena, "--- raw cell:\n"),
            .sh => try out.appendSlice(arena, "--- shell cell (%%sh)"),
            .py => try out.appendSlice(arena, "--- code cell"),
            .ask => {},
        }
        if (c.kind == .py or c.kind == .sh) {
            if (c.count) |n| try out.print(arena, " [{d}]", .{n});
            try out.appendSlice(arena, ":\n");
        }
        try out.appendSlice(arena, c.ed.doc.bytes());
        try out.append(arena, '\n');
        if (c.outputs.items.len > 0) {
            try out.appendSlice(arena, "output:\n");
            for (c.outputs.items) |*o| try out.appendSlice(arena, try o.plainText(arena, max_context_lines));
        }
        if (c.exit_code) |code| try out.print(arena, "exit status {d}\n", .{code});
        if (c.state == .aborted) try out.appendSlice(arena, "(not run: an earlier cell failed)\n");
        return out.toOwnedSlice(arena);
    }

    /// Moves what the agent sent into its ask cell; true when anything changed.
    fn pollAsk(self: *NotebookTab) bool {
        const req = self.ask_req orelse return false;
        const cell = self.cellById(self.ask_cell) orelse {
            self.stopAsk();
            return false;
        };
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        var proposals: std.ArrayList([]u8) = .empty;
        defer {
            for (proposals.items) |p| self.gpa.free(p);
            proposals.deinit(self.gpa);
        }
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(self.gpa);
        const outcome = req.take(&text, &proposals, &err, self.gpa);
        var changed = false;
        if (text.items.len > 0 and cell.outputs.items.len > 0) {
            cell.outputs.items[0].append(self.gpa, text.items);
            changed = true;
        }
        if (proposals.items.len > 0) {
            var at = (self.indexOfCell(cell) orelse self.cells.items.len - 1) + 1;
            // Under the question, after any cell it already proposed.
            while (at < self.cells.items.len and self.cells.items[at].kind == .py and proposedBy(self.cells.items[at], cell.id)) at += 1;
            for (proposals.items) |code| {
                const kind: Kind = if (ipynb.shellMagic(code) != null) .sh else .py;
                const body = if (kind == .sh) ipynb.afterFirstLine(code) else code;
                if (self.addCell(at, kind, body)) |added| {
                    if (kind == .sh) {
                        self.gpa.free(added.magic);
                        added.magic = self.gpa.dupe(u8, ipynb.shellMagic(code).?) catch &.{};
                    }
                    self.gpa.free(added.metadata);
                    added.metadata = std.fmt.allocPrint(self.gpa, "{{\"tt\":{{\"from\":\"{s}\"}}}}", .{cell.id}) catch &.{};
                    at += 1;
                    self.reveal = at - 1;
                }
            }
            changed = true;
        }
        switch (outcome) {
            .running => {},
            .done => {
                cell.state = .done;
                cell.t_end = self.now;
                if (cell.outputs.items.len > 0 and cell.outputs.items[0].buf.isEmpty() and proposals.items.len == 0) self.failAsk(cell, "The agent sent no answer.");
                self.stopAsk();
                changed = true;
            },
            .failed => {
                self.failAsk(cell, if (err.items.len > 0) err.items else "The agent could not answer.");
                self.stopAsk();
                changed = true;
            },
        }
        return changed;
    }

    fn proposedBy(c: *const Cell, ask_id: []const u8) bool {
        if (c.metadata.len == 0) return false;
        var buf: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "\"from\":\"{s}\"", .{ask_id}) catch return false;
        return std.mem.indexOf(u8, c.metadata, key) != null;
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *NotebookTab, _: []u8) []const u8 {
        return sys.basename(self.file_path);
    }

    pub fn path(self: *NotebookTab) []const u8 {
        return self.file_path;
    }

    pub fn relocate(self: *NotebookTab, new_path: []const u8) void {
        const owned = self.gpa.dupe(u8, new_path) catch return;
        self.gpa.free(self.file_path);
        self.file_path = owned;
    }

    pub fn cwd(self: *NotebookTab) []const u8 {
        return sys.dirname(self.file_path);
    }

    pub fn status(self: *NotebookTab) tab_mod.Status {
        if (self.anyRunning() or self.ask_req != null) return .running;
        if (self.modified()) return .attention;
        return .none;
    }

    /// "Notebook  ·  py 3.12 · idle": the kind, then the kernel's state.
    pub fn info(self: *NotebookTab, buf: []u8) []const u8 {
        var kbuf: [96]u8 = undefined;
        const k = self.kernelLabel(&kbuf);
        return switch (self.file_state) {
            .failed => "Could not read this file",
            .not_notebook => "Not a notebook",
            .ok => std.fmt.bufPrint(buf, "Notebook  ·  {s}{s}", .{ k, self.suffix() }) catch "Notebook",
        };
    }

    fn suffix(self: *const NotebookTab) []const u8 {
        if (self.save_failed) return "  ·  Save failed";
        if (self.disk_changed) return "  ·  Changed on disk";
        if (self.missing) return "  ·  Deleted on disk";
        if (self.now - self.saved_at < saved_flash) return "  ·  Saved";
        if (!self.writable and self.file_state == .ok) return "  ·  Read-only";
        return "";
    }

    /// "py 3.12 · idle", "starting kernel…", "no kernel".
    fn kernelLabel(self: *const NotebookTab, buf: []u8) []const u8 {
        const k = self.kernel orelse return std.fmt.bufPrint(buf, "{d} cell{s}", .{ self.cells.items.len, if (self.cells.items.len == 1) "" else "s" }) catch "";
        return switch (k.phase) {
            .off, .launching, .starting => "starting kernel…",
            .restarting => "restarting kernel…",
            .dead => "kernel died",
            .failed => "no kernel",
            .ready => blk: {
                var lang_buf: [48]u8 = undefined;
                const lang = self.shortLanguage(&lang_buf);
                break :blk std.fmt.bufPrint(buf, "{s} · {s}", .{ lang, if (k.busy or self.anyRunning()) "busy" else "idle" }) catch "";
            },
        };
    }

    /// "py 3.12" from the kernel's language and version.
    fn shortLanguage(self: *const NotebookTab, buf: []u8) []const u8 {
        const lang = if (std.mem.eql(u8, self.kernel_language, "python")) "py" else if (self.kernel_language.len > 0) self.kernel_language else "kernel";
        var version = self.kernel_version;
        // "3.12.14" → "3.12"
        var dots: usize = 0;
        for (version, 0..) |ch, i| {
            if (ch == '.') {
                dots += 1;
                if (dots == 2) {
                    version = version[0..i];
                    break;
                }
            }
        }
        if (version.len == 0) return lang;
        return std.fmt.bufPrint(buf, "{s} {s}", .{ lang, version }) catch lang;
    }

    pub fn closeWarning(self: *NotebookTab, _: []u8) ?[]const u8 {
        if (self.anyRunning()) return "A cell is still running; the kernel will be stopped.";
        if (self.modified()) return "Unsaved changes will be lost.";
        return null;
    }

    pub fn tick(self: *NotebookTab, now: f64, active: bool) bool {
        self.now = now;
        var dirty = false;
        if (self.kernel) |k| {
            if (k.poll()) dirty = true;
            k.take(&self.events);
            if (self.events.items.len > 0) {
                for (self.events.items) |*e| {
                    self.apply(e);
                    e.deinit(self.gpa);
                }
                self.events.clearRetainingCapacity();
                dirty = true;
            }
        }
        if (self.pollAsk()) dirty = true;
        if (self.focusedEditor()) |ed| {
            if (ed.tick(now, active)) dirty = true;
        }
        if (self.just_saved) {
            self.just_saved = false;
            self.saved_at = now;
            dirty = true;
        } else if (now - self.saved_at < saved_flash + 0.1 and now - self.saved_at > saved_flash) {
            dirty = true;
        }
        if (active and (self.anyRunning() or self.ask_req != null) and now - self.last_anim > 0.25) {
            self.last_anim = now;
            dirty = true;
        }
        if (active and now - self.last_check > disk_check_every and self.file_state != .failed) {
            self.last_check = now;
            if (self.checkDisk()) dirty = true;
        }
        return dirty;
    }

    /// The editor the keyboard goes to.
    fn focusedEditor(self: *NotebookTab) ?*TextEditor {
        if (self.focus_cell) |i| {
            if (i >= self.cells.items.len) return null;
            const c = self.cells.items[i];
            if (c.input) |*inp| return &inp.ed;
            return &c.ed;
        }
        return &self.input;
    }

    fn focusedCell(self: *NotebookTab) ?*Cell {
        const i = self.focus_cell orelse return null;
        if (i >= self.cells.items.len) return null;
        return self.cells.items[i];
    }

    /// Typing into a folded cell unfolds it first.
    fn unfoldFocused(self: *NotebookTab) void {
        const c = self.focusedCell() orelse return;
        if (c.input_hidden and c.input == null) {
            c.input_hidden = false;
            self.dirty = true;
        }
    }

    pub fn onText(self: *NotebookTab, utf8: []const u8) void {
        const ed = self.focusedEditor() orelse return;
        self.unfoldFocused();
        ed.onText(utf8);
        if (self.focusedCell()) |c| if (c.view) |*v| {
            v.follow = true;
        };
    }

    pub fn onMarkedText(self: *NotebookTab, utf8: []const u8) void {
        const ed = self.focusedEditor() orelse return;
        ed.onMarkedText(utf8);
    }

    pub fn onEdit(self: *NotebookTab, cmd: EditCommand) void {
        if (self.focus_cell) |i| {
            if (i >= self.cells.items.len) {
                self.focus_cell = null;
                return;
            }
            const cell = self.cells.items[i];
            if (cell.input != null) {
                if (cmd == .insert_newline or cmd == .insert_line_break) return self.sendInput(cell);
                cell.input.?.ed.onEdit(cmd);
                return;
            }
            if (cmd != .move_up and cmd != .move_down and cmd != .insert_line_break) self.unfoldFocused();
            switch (cmd) {
                .insert_line_break => {
                    if (cell.kind.runs()) self.runCell(i);
                    self.advance(i);
                    return;
                },
                .move_up => if (cell.ed.doc.editor.selection() == null and cell.ed.position().line == 1) {
                    if (i > 0) self.focusCell(i - 1, true);
                    return;
                },
                .move_down => if (cell.ed.doc.editor.selection() == null and cell.ed.position().line == cell.ed.position().lines) {
                    if (i + 1 < self.cells.items.len) self.focusCell(i + 1, false) else self.focusCell(null, false);
                    return;
                },
                else => {},
            }
            if (cell.kind == .ask and cmd != .select_all and cmd != .cancel) {
                // A question is read-only: only navigation, and that means leaving it.
                if (cmd == .move_up and i > 0) self.focusCell(i - 1, true);
                if (cmd == .move_down) {
                    if (i + 1 < self.cells.items.len) self.focusCell(i + 1, false) else self.focusCell(null, false);
                }
                return;
            }
            if (cell.view) |*v| v.onEdit(&cell.ed, cmd) else cell.ed.onEdit(cmd);
            return;
        }
        // The input row.
        switch (cmd) {
            .insert_line_break => self.submitInput(true),
            .insert_newline => if (self.input_kind == .ask) self.submitInput(false) else self.input.onEdit(cmd),
            .move_up => if (self.input.doc.editor.selection() == null and self.input.position().line == 1 and self.cells.items.len > 0) {
                self.focusCell(self.cells.items.len - 1, true);
            } else self.input.onEdit(cmd),
            else => self.input.onEdit(cmd),
        }
    }

    /// What was typed in the input row becomes a cell: run when `run`
    /// (⇧↵), a question goes to the agent either way.
    fn submitInput(self: *NotebookTab, run: bool) void {
        const text = std.mem.trim(u8, self.input.doc.bytes(), "\n\r");
        if (std.mem.trim(u8, text, " \t").len == 0) return;
        switch (self.input_kind) {
            .ask => self.ask(text),
            .md, .raw => {
                _ = self.addCell(self.cells.items.len, self.input_kind, text);
                self.reveal = self.cells.items.len - 1;
            },
            .py, .sh => {
                _ = self.addCell(self.cells.items.len, self.input_kind, text);
                self.reveal = self.cells.items.len - 1;
                if (run) self.runCell(self.cells.items.len - 1);
            },
        }
        self.input.load("", self.input_kind.language()) catch {};
        self.input.follow = true;
    }

    fn setInputKind(self: *NotebookTab, kind: Kind) void {
        if (self.input_kind == kind) return;
        self.input_kind = kind;
        self.input.doc.setLanguage(kind.language());
    }

    pub fn onCtrl(self: *NotebookTab, key: u8) void {
        if (key == 'c' and self.anyRunning()) self.interrupt();
    }

    pub fn copy(self: *NotebookTab, out: *std.ArrayList(u8), cut: bool) bool {
        const ed = self.focusedEditor() orelse return false;
        return ed.copy(out, cut);
    }

    pub fn paste(self: *NotebookTab, utf8: []const u8) void {
        const ed = self.focusedEditor() orelse return;
        self.unfoldFocused();
        ed.paste(utf8);
        if (self.focusedCell()) |c| if (c.view) |*v| {
            v.follow = true;
        };
    }

    pub fn hasMarkedText(self: *NotebookTab) bool {
        const ed = self.focusedEditor() orelse return false;
        return ed.hasMarkedText();
    }

    pub fn caretRect(self: *NotebookTab) Rect {
        if (self.focusedCell()) |c| if (c.view) |v| if (c.input == null) return v.caret;
        const ed = self.focusedEditor() orelse return .{};
        return ed.caret;
    }

    pub fn position(self: *NotebookTab) ?tab_mod.Position {
        const c = self.focusedCell() orelse return null;
        return c.ed.position();
    }

    pub fn goTo(self: *NotebookTab, line: usize, col: usize) bool {
        const c = self.focusedCell() orelse return false;
        c.ed.goTo(line, col);
        if (c.view) |*v| v.follow = true;
        return true;
    }

    pub fn command(self: *NotebookTab, cmd: tab_mod.Command) bool {
        switch (cmd) {
            .save => return self.saveFile(),
            .undo => {
                const ed = self.focusedEditor() orelse return false;
                if (self.focusedCell()) |c| if (c.view) |*v| {
                    v.follow = true;
                };
                return ed.undo();
            },
            .redo => {
                const ed = self.focusedEditor() orelse return false;
                return ed.redo();
            },
            .toggle_view => {
                self.inspector = !self.inspector;
                return true;
            },
            else => return false,
        }
    }

    // ── the band: Run all · Restart · Clear outputs · Variables ─────────
    pub fn strip(self: *NotebookTab, ui: *Ui, room: Rect) f32 {
        if (self.file_state != .ok) return 0;
        const Item = struct { label: []const u8, w: f32 = 0, show: bool = false };
        var items = [_]Item{
            .{ .label = "Run all" },
            .{ .label = "Restart" },
            .{ .label = "Clear outputs" },
            .{ .label = if (self.inspector) "Hide variables" else "Variables" },
        };
        for (&items) |*it| it.w = ui.text.measure(theme.font_hint, it.label) + 18;
        // What fits, most useful first.
        const priority = [_]usize{ 0, 3, 1, 2 };
        var used: f32 = 0;
        for (priority) |p| {
            if (used + items[p].w + 4 > room.w) continue;
            items[p].show = true;
            used += items[p].w + 4;
        }
        if (used == 0) return 0;
        var x = room.right() - used + 4;
        const h: f32 = 24;
        const y = room.y + (room.h - h) / 2;
        for (items, 0..) |it, i| {
            if (!it.show) continue;
            const r: Rect = .{ .x = x, .y = y, .w = it.w, .h = h };
            const color = if (i == 0) theme.text else theme.text_2;
            if (field.textButton(ui, Ui.id("notebook.strip", self.input.salt * 8 + i), r, it.label, color)) {
                switch (i) {
                    0 => self.runAll(),
                    1 => self.restartKernel(),
                    2 => self.clearAllOutputs(),
                    else => self.inspector = !self.inspector,
                }
            }
            x += it.w + 4;
        }
        return used;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *NotebookTab, ui: *Ui, rect: Rect, focused: bool) void {
        self.now = ui.now;
        const dl = ui.dl;
        const body = viewer.frame(ui, rect);
        switch (self.file_state) {
            .failed => return viewer.notice(ui, body, "The notebook could not be opened."),
            .not_notebook => return viewer.notice(ui, body, "This file is not a Jupyter notebook (nbformat 4 JSON)."),
            .ok => {},
        }
        if (focused and !self.was_focused) self.ensureKernel();
        self.was_focused = focused;
        if (self.kernel == null) self.ensureKernel();

        var area = body;
        if (self.inspector and body.w > inspector_w + 360) {
            area.w -= inspector_w;
            const panel: Rect = .{ .x = body.right() - inspector_w, .y = body.y, .w = inspector_w, .h = body.h };
            dl.rect(.{ .x = panel.x, .y = panel.y, .w = 1, .h = panel.h }, theme.line);
            self.drawInspector(ui, panel);
        }

        // The input row, pinned at the bottom like the terminal's.
        const input_h = self.inputHeight(ui);
        const input_rect: Rect = .{ .x = area.x + side_pad, .y = area.bottom() - side_pad - input_h, .w = area.w - 2 * side_pad, .h = input_h };
        const cells_area: Rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = @max(0, input_rect.y - cell_gap - area.y) };
        self.drawCells(ui, cells_area, focused);
        self.drawInput(ui, input_rect, focused and self.focus_cell == null);
    }

    fn inputHeight(self: *NotebookTab, ui: *Ui) f32 {
        _ = ui;
        const rows = @min(input_rows_max, @max(1, self.input.doc.lineCount()));
        return @as(f32, @floatFromInt(rows)) * line_h + self.input.pad_top + self.input.pad_bottom + input_hint_h;
    }

    /// Lays a cell out for `card_w` and remembers its heights.
    fn layoutCell(self: *NotebookTab, ui: *Ui, cell: *Cell, card_w: f32, focused: bool) f32 {
        const inner_w = card_w - 2 * theme.block_pad_x;
        const cell_w = ui.text.cellAdvance(theme.font_output);
        const cols: u32 = @intFromFloat(@max(10, @floor(inner_w / cell_w)));
        cell.src_h = if (cell.input_hidden) line_h + 2 * src_pad else if (cell.view) |*v| v.measure(ui.text, &cell.ed, card_w, focused) else cell.ed.height();
        var h = cell.src_h;
        cell.out_h = 0;
        if (cell.outputs.items.len > 0) {
            var oh: f32 = 1 + out_pad;
            if (cell.outputs_hidden) {
                oh += line_h + out_pad;
            } else {
                for (cell.outputs.items) |*o| oh += o.layout(self.gpa, self.env.textures, inner_w, cols) + out_gap;
                oh += out_pad - out_gap;
            }
            cell.out_h = oh;
            h += oh;
        }
        if (cell.input != null) h += 1 + out_pad + line_h + 8 + out_pad;
        cell.h = h;
        return h;
    }

    fn drawCells(self: *NotebookTab, ui: *Ui, area: Rect, focused: bool) void {
        const dl = ui.dl;
        const card_x = area.x + side_pad + gutter_w + gutter_gap;
        const card_w = @max(200, area.right() - side_pad - card_x);
        self.view_h = area.h;

        // Heights first, so the scroll range is known before anything is drawn.
        var total: f32 = top_pad;
        for (self.cells.items, 0..) |c, i| {
            total += self.layoutCell(ui, c, card_w, focused and self.focus_cell == i) + cell_gap;
        }
        if (self.kernelNotice()) |_| total += 96;
        total += cell_gap;
        self.content_h = total;
        const max_scroll = @max(0, total - area.h);

        // A cell to bring into view.
        if (self.reveal) |idx| {
            self.reveal = null;
            if (idx < self.cells.items.len) {
                var y: f32 = top_pad;
                if (self.kernelNotice()) |_| y += 96;
                for (self.cells.items[0..idx]) |c| y += c.h + cell_gap;
                const bottom = y + self.cells.items[idx].h;
                if (y < self.scroll) self.scroll = @max(0, y - cell_gap);
                if (bottom > self.scroll + area.h) self.scroll = bottom - area.h + cell_gap;
            }
        }
        const vbar = Ui.id("notebook.vbar", self.input.salt);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, area, self.scroll, total)) |s| self.scroll = s;
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);

        dl.pushClip(area);
        defer dl.popClip();

        var y = area.y + top_pad - self.scroll;
        if (self.kernelNotice()) |notice| {
            self.drawKernelNotice(ui, .{ .x = card_x, .y = y, .w = card_w, .h = 84 }, notice);
            y += 96;
        }
        var follow_caret = false;
        for (self.cells.items, 0..) |c, i| {
            const r: Rect = .{ .x = card_x, .y = y, .w = card_w, .h = c.h };
            const gap: Rect = .{ .x = card_x, .y = r.bottom(), .w = card_w, .h = cell_gap };
            if (r.bottom() > area.y and r.y < area.bottom()) {
                if (ui.pressed and ui.mouseIn(r) and self.focus_cell != i) self.focus_cell = i;
                const is_focused = focused and self.focus_cell == i;
                if (is_focused and (c.ed.follow or (if (c.view) |v| v.follow else false))) follow_caret = true;
                self.drawCell(ui, c, i, r, area, is_focused);
            }
            // The gap below: a click adds a cell there.
            if (gap.bottom() > area.y and gap.y < area.bottom()) self.drawGap(ui, gap, i + 1);
            y += c.h + cell_gap;
        }

        // Keep the caret in view after keys (one frame late, which is fine).
        if (follow_caret) if (self.focusedCell()) |c| {
            const caret = if (c.view) |v| v.caret else c.ed.caret;
            if (caret.h > 0) {
                if (caret.y < area.y + line_h) {
                    self.scroll = @max(0, self.scroll - (area.y + line_h - caret.y));
                    ui.wants_frame = true;
                } else if (caret.bottom() > area.bottom() - line_h) {
                    self.scroll = @min(max_scroll, self.scroll + (caret.bottom() - (area.bottom() - line_h)));
                    ui.wants_frame = true;
                }
            }
        };
        if (self.cells.items.len == 0 and self.kernelNotice() == null) {
            viewer.notice(ui, area, "An empty notebook: type below and press ⇧↵ to run the first cell.");
        }
        sidebar.drawScrollbarAxis(ui, vbar, .vertical, area, self.scroll, total);
    }

    /// Why nothing runs, when so.
    fn kernelNotice(self: *const NotebookTab) ?[]const u8 {
        const k = self.kernel orelse return null;
        if (k.phase != .failed) return null;
        return if (k.failure.items.len > 0) k.failure.items else "The kernel could not be started.";
    }

    fn drawKernelNotice(self: *NotebookTab, ui: *Ui, r: Rect, notice: []const u8) void {
        const dl = ui.dl;
        dl.shape(r, theme.block_radius, theme.bg_block, 1, theme.red_line);
        const px = r.x + theme.block_pad_x;
        _ = dl.textEllipsis(theme.font_ui_medium, px, r.y + 22, notice, r.w - 2 * theme.block_pad_x, theme.text);
        var hint_buf: [512]u8 = undefined;
        const python = if (self.no_jupyter_python.len > 0) self.no_jupyter_python else if (self.kernel) |k| k.interpreter() else "python3";
        var abbrev: [256]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "Jupyter needs ipykernel in the notebook's Python ({s}).", .{sys.abbreviateHome(python, &abbrev)}) catch "";
        _ = dl.textEllipsis(theme.font_hint, px, r.y + 44, hint, r.w - 2 * theme.block_pad_x, theme.text_2);
        const by = r.y + 58;
        var x = px;
        const b1: Rect = .{ .x = x, .y = by, .w = ui.text.measure(theme.font_hint, "Install in a shell") + 18, .h = 22 };
        if (field.textButton(ui, Ui.id("notebook.install", self.input.salt), b1, "Install in a shell", theme.accent)) {
            const cmd = std.fmt.bufPrint(&hint_buf, "{s} -m pip install ipykernel", .{python}) catch "python3 -m pip install ipykernel";
            self.env.sendToShell(cmd);
        }
        x += b1.w + 10;
        const b2: Rect = .{ .x = x, .y = by, .w = ui.text.measure(theme.font_hint, "Try again") + 18, .h = 22 };
        if (field.textButton(ui, Ui.id("notebook.retry", self.input.salt), b2, "Try again", theme.text_2)) self.restartKernel();
    }

    /// The gap under a cell: hovering shows where a cell would go, a click adds one.
    fn drawGap(self: *NotebookTab, ui: *Ui, gap: Rect, at: usize) void {
        const dl = ui.dl;
        const st = ui.button(Ui.id("notebook.gap", self.input.salt * 4096 + at), gap);
        if (!st.hover and !st.held) return;
        const cy = gap.centerY();
        dl.rect(.{ .x = gap.x, .y = cy, .w = gap.w, .h = 1 }, theme.accent.alpha(0.5));
        const label = "+ cell";
        const w = ui.text.measure(theme.font_kbd, label) + 12;
        const pill: Rect = .{ .x = gap.x + (gap.w - w) / 2, .y = cy - 8, .w = w, .h = 16 };
        dl.rrect(pill, 8, theme.bg);
        dl.border(pill, 8, 1, theme.accent.alpha(0.5));
        _ = dl.textCentered(theme.font_kbd, pill.x + 6, cy, label, theme.accent);
        if (st.clicked) {
            if (self.addCell(at, .py, "")) |_| self.focusCell(at, false);
        }
    }

    fn drawCell(self: *NotebookTab, ui: *Ui, c: *Cell, i: usize, r: Rect, area: Rect, is_focused: bool) void {
        const dl = ui.dl;
        const failed = c.state == .failed or c.exit_code != null;
        const border_color = if (c.state == .running) theme.accent else if (failed) theme.red_line else if (is_focused) theme.accent.alpha(0.55) else theme.line;
        const border_w: f32 = if (c.state == .running or failed or is_focused) 1 else theme.block_border;
        dl.shape(r, theme.block_radius, theme.bg_block, border_w, border_color);

        // The gutter: kind, count.
        {
            const gx = r.x - gutter_gap;
            const gy = r.y + src_pad + line_h / 2;
            const label = c.kind.label();
            const lw = ui.text.measure(theme.font_kbd, label);
            const lr: Rect = .{ .x = gx - lw - 6, .y = gy - 10, .w = lw + 12, .h = 20 };
            const st = ui.button(Ui.id("notebook.kind", c.salt), lr);
            if (c.kind != .ask) {
                if (st.hover) dl.rrect(lr, 5, theme.hover);
                if (st.clicked) {
                    const next: Kind = switch (c.kind) {
                        .py => .sh,
                        .sh => .md,
                        .md, .raw => .py,
                        .ask => .ask,
                    };
                    c.setKind(self.gpa, next, self.env.textures);
                    self.dirty = true;
                }
            }
            _ = dl.textRight(theme.font_kbd, gx, gy, label, c.kind.color());
            if (c.kind.runs()) {
                var buf: [24]u8 = undefined;
                const count = switch (c.state) {
                    .queued, .running => "[*]",
                    else => if (c.count) |n| std.fmt.bufPrint(&buf, "[{d}]", .{n}) catch "" else "[ ]",
                };
                _ = dl.textRight(theme.font_kbd, gx, gy + 18, count, theme.text_3);
            }
        }

        // The source, or its first line when folded. The collapser bar
        // takes the mouse before the editor, so a press on it never lands
        // in the text.
        const src_rect: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = c.src_h };
        const bar_hot = c.kind != .ask and self.drawCollapser(ui, c, 0, src_rect, &c.input_hidden);
        if (c.input_hidden) {
            self.drawFoldedSource(ui, c, src_rect);
        } else if (c.kind == .ask) {
            dl.icon(.sparkle, r.x + theme.block_pad_x - 1, r.y + src_pad + line_h / 2 - 8, 16, theme.accent);
            const ask_rect: Rect = .{ .x = r.x + 18, .y = r.y, .w = r.w - 18, .h = c.src_h };
            c.ed.draw(ui, ask_rect, is_focused);
        } else if (c.view) |*v| {
            v.draw(ui, &c.ed, src_rect, is_focused);
        } else {
            c.ed.draw(ui, src_rect, is_focused);
        }
        if (bar_hot) ui.cursor = .pointer;

        // Status and hover actions at the top right.
        {
            const cy = r.y + src_pad + line_h / 2;
            var sbuf: [64]u8 = undefined;
            const status_text = self.cellStatus(c, &sbuf);
            const status_color = switch (c.state) {
                .failed => theme.red,
                .queued, .running => theme.teal,
                .aborted => theme.text_3,
                else => if (c.exit_code != null) theme.red else theme.text_3,
            };
            var right = r.right() - theme.block_pad_x;
            if (status_text.len > 0) right -= dl.textRight(theme.font_hint, right, cy, status_text, status_color) + 10;
            if (ui.mouseIn(r) and c.kind != .ask) {
                const Action = enum { run, stop, del, up, down };
                const actions = [_]struct { a: Action, label: []const u8 }{
                    .{ .a = .down, .label = "↓" },
                    .{ .a = .up, .label = "↑" },
                    .{ .a = .del, .label = "Delete" },
                    .{ .a = if (c.running()) .stop else .run, .label = if (c.running()) "Stop" else "Run" },
                };
                for (actions, 0..) |act, k| {
                    if (!c.kind.runs() and (act.a == .run or act.a == .stop)) continue;
                    const w = ui.text.measure(theme.font_hint, act.label) + 16;
                    const br: Rect = .{ .x = right - w, .y = cy - 11, .w = w, .h = 22 };
                    if (field.textButton(ui, Ui.id("notebook.act", c.salt * 8 + k), br, act.label, theme.text_3)) {
                        switch (act.a) {
                            .run => self.runCell(i),
                            .stop => self.interrupt(),
                            .del => {
                                self.deleteCell(i);
                                return;
                            },
                            .up => self.moveCell(i, true),
                            .down => self.moveCell(i, false),
                        }
                    }
                    right = br.x - 4;
                }
            }
        }

        // Outputs.
        var y = r.y + c.src_h;
        const px = r.x + theme.block_pad_x;
        const inner_w = r.w - 2 * theme.block_pad_x;
        if (c.outputs.items.len > 0) {
            const region: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = c.out_h };
            dl.rect(.{ .x = r.x + 1, .y = y, .w = r.w - 2, .h = 1 }, theme.line);
            const out_hot = self.drawCollapser(ui, c, 1, region, &c.outputs_hidden);
            y += 1 + out_pad;
            if (c.outputs_hidden) {
                self.drawFoldedOutputs(ui, c, px, y, inner_w);
                y += line_h + out_pad;
            } else {
                for (c.outputs.items) |*o| {
                    self.drawOut(ui, o, px, y, inner_w, area);
                    y += o.h + out_gap;
                }
                y += out_pad - out_gap;
            }
            if (out_hot) ui.cursor = .pointer;
        }
        if (c.input) |*inp| {
            dl.rect(.{ .x = r.x + 1, .y = y, .w = r.w - 2, .h = 1 }, theme.line);
            y += 1 + out_pad;
            const pw = dl.textCentered(theme.font_output, px, y + 4 + line_h / 2, inp.prompt, theme.text_2);
            const box: Rect = .{ .x = px + pw + 8, .y = y, .w = inner_w - pw - 8, .h = line_h + 8 };
            dl.shape(box, 6, theme.bg_inset, 1, theme.accent);
            inp.ed.draw(ui, .{ .x = box.x - theme.block_pad_x + 8, .y = box.y, .w = box.w + theme.block_pad_x - 8, .h = box.h }, is_focused);
            _ = dl.textRight(theme.font_hint, r.right() - theme.block_pad_x, y + 4 + line_h / 2, "↵ Send", theme.text_3);
        }
    }

    /// The thin bar at the left of a region (the input, the outputs) that
    /// folds it, as in Jupyter Lab: it brightens under the mouse, a click
    /// toggles. Returns true while hovered, so the caller can set the
    /// pointer after whatever it draws over the same area.
    fn drawCollapser(self: *NotebookTab, ui: *Ui, c: *Cell, which: usize, region: Rect, flag: *bool) bool {
        const dl = ui.dl;
        const hit: Rect = .{ .x = region.x + 1, .y = region.y + 3, .w = 13, .h = @max(6, region.h - 6) };
        const st = ui.button(Ui.id("notebook.fold", c.salt * 4 + which), hit);
        const hot = st.hover or st.held;
        const bar: Rect = .{ .x = region.x + 5, .y = region.y + 6, .w = 4, .h = @max(4, region.h - 12) };
        dl.rrect(bar, 2, if (hot) theme.accent else if (flag.*) theme.text_3 else theme.line);
        if (st.clicked) {
            flag.* = !flag.*;
            self.dirty = true;
        }
        return hot;
    }

    /// A folded input: its first line, dimmed, and how many lines there
    /// are. A click on it unfolds.
    fn drawFoldedSource(self: *NotebookTab, ui: *Ui, c: *Cell, src_rect: Rect) void {
        const dl = ui.dl;
        const cy = src_rect.y + src_pad + line_h / 2;
        const px = src_rect.x + theme.block_pad_x;
        const n = c.ed.doc.lineCount();
        var buf: [48]u8 = undefined;
        const more = if (n > 1) std.fmt.bufPrint(&buf, "··· {d} lines", .{n}) catch "···" else "···";
        const more_w = ui.text.measure(theme.font_hint, more);
        const row: Rect = .{ .x = px - 6, .y = src_rect.y + 2, .w = @max(40, src_rect.w - theme.block_pad_x - 150), .h = src_rect.h - 4 };
        const st = ui.button(Ui.id("notebook.unfold", c.salt * 4), row);
        const first = std.mem.trimEnd(u8, c.ed.doc.lineText(0), " \t\r");
        var used: f32 = 0;
        if (first.len > 0) used = dl.textEllipsis(theme.font_output, px, cy, first, @max(0, row.w - more_w - 24), if (st.hover) theme.text_2 else theme.text_3) + 12;
        _ = dl.textCentered(theme.font_hint, px + used, cy, more, theme.text_3);
        if (st.clicked) {
            c.input_hidden = false;
            self.dirty = true;
        }
    }

    /// Folded outputs: one line saying what is hidden; a click unfolds.
    fn drawFoldedOutputs(self: *NotebookTab, ui: *Ui, c: *Cell, px: f32, y: f32, w: f32) void {
        const dl = ui.dl;
        var lines: usize = 0;
        var pictures: usize = 0;
        var tables: usize = 0;
        var errors: usize = 0;
        for (c.outputs.items) |*o| switch (o.kind) {
            .text => lines += o.buf.lineCount(),
            .err => errors += 1,
            .picture => pictures += 1,
            .table => tables += 1,
            .note => lines += 1,
        };
        var buf: [160]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        fw.writeAll("··· ") catch {};
        var parts: usize = 0;
        if (lines > 0) {
            fw.print("{d} line{s}", .{ lines, if (lines == 1) "" else "s" }) catch {};
            parts += 1;
        }
        if (pictures > 0) {
            fw.print("{s}{d} figure{s}", .{ if (parts > 0) " · " else "", pictures, if (pictures == 1) "" else "s" }) catch {};
            parts += 1;
        }
        if (tables > 0) {
            fw.print("{s}{d} table{s}", .{ if (parts > 0) " · " else "", tables, if (tables == 1) "" else "s" }) catch {};
            parts += 1;
        }
        if (errors > 0) {
            fw.print("{s}an error", .{if (parts > 0) " · " else ""}) catch {};
            parts += 1;
        }
        fw.writeAll(if (parts > 0) " hidden" else "output hidden") catch {};
        const row: Rect = .{ .x = px - 6, .y = y - 3, .w = w + 12, .h = line_h + 6 };
        const st = ui.button(Ui.id("notebook.unfold", c.salt * 4 + 1), row);
        _ = dl.textEllipsis(theme.font_hint, px, y + line_h / 2, fw.buffered(), w, if (st.hover) theme.text_2 else theme.text_3);
        if (st.clicked) {
            c.outputs_hidden = false;
            self.dirty = true;
        }
    }

    /// "0.8s", "running 3.2s", "queued", "1.9s · exit 3", "not run". A
    /// cell whose results came from the file has no timing: nothing.
    fn cellStatus(self: *const NotebookTab, c: *const Cell, buf: []u8) []const u8 {
        const secs = c.duration(self.now);
        const timed = c.t_start != 0;
        return switch (c.state) {
            .idle => "",
            .queued => "queued",
            .running => if (c.kind == .ask) "asking…" else std.fmt.bufPrint(buf, "running {s}", .{fmtDuration(secs, buf[32..])}) catch "running",
            .done => if (c.kind == .ask or !timed) "" else fmtDuration(secs, buf),
            .failed => if (c.exit_code) |code| (if (timed) std.fmt.bufPrint(buf, "{s} · exit {d}", .{ fmtDuration(secs, buf[32..]), code }) catch "failed" else std.fmt.bufPrint(buf, "exit {d}", .{code}) catch "failed") else if (c.kind == .ask) "no answer" else if (timed) std.fmt.bufPrint(buf, "{s} · error", .{fmtDuration(secs, buf[32..])}) catch "error" else "error",
            .aborted => "not run",
        };
    }

    fn fmtDuration(secs: f64, buf: []u8) []const u8 {
        if (secs < 0.05) return std.fmt.bufPrint(buf, "{d} ms", .{@as(i64, @intFromFloat(secs * 1000))}) catch "";
        if (secs < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "";
        const m: i64 = @intFromFloat(@floor(secs / 60));
        const s: i64 = @intFromFloat(@floor(secs - @as(f64, @floatFromInt(m)) * 60));
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch "";
    }

    fn drawOut(self: *NotebookTab, ui: *Ui, o: *Out, x: f32, y: f32, w: f32, area: Rect) void {
        const dl = ui.dl;
        switch (o.kind) {
            .text, .err => {
                const cell_w = ui.text.cellAdvance(theme.font_output);
                const cols: u32 = @intFromFloat(@max(10, @floor(w / cell_w)));
                if (o.kind == .err) dl.rrect(.{ .x = x - 8, .y = y - 4, .w = w + 16, .h = o.h + 8 }, 8, theme.bg_inset);
                _ = self.drawRows(ui, o, x, y, area, cols);
            },
            .picture => {
                if (o.tex_state == .ready) {
                    const nw: f32 = @floatFromInt(@max(1, o.native_w));
                    const nh: f32 = @floatFromInt(@max(1, o.native_h));
                    var shown_w = @min(nw, w);
                    var shown_h = nh * shown_w / nw;
                    if (shown_h > image_max_h) {
                        shown_h = image_max_h;
                        shown_w = nw * shown_h / nh;
                    }
                    dl.image(.{ .x = x, .y = y, .w = shown_w, .h = shown_h }, o.tex, Color.hex(0xFFFFFF));
                } else {
                    _ = dl.textCentered(theme.font_hint, x, y + line_h / 2, if (o.tex_state == .failed) "An image that could not be decoded." else "An image (shown in a window).", theme.text_3);
                }
            },
            .table => self.drawTable(ui, &o.table.?, x, y, w),
            .note => _ = dl.textEllipsis(theme.font_hint, x, y + line_h / 2, o.note, w, theme.text_3),
        }
    }

    fn drawRows(self: *NotebookTab, ui: *Ui, o: *Out, x: f32, y0: f32, area: Rect, cols: u32) f32 {
        _ = self;
        const dl = ui.dl;
        var y = y0;
        if (o.first_row > 0) {
            var buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "··· {d} earlier lines", .{o.first_row}) catch "···";
            _ = dl.textCentered(theme.font_output, x, y + line_h / 2, label, theme.text_3);
            y += line_h;
        }
        if (o.row_starts.items.len == 0) return y;
        var row = o.first_row;
        const end_row = o.first_row + o.rows;
        if (y < area.y) {
            const skip: u32 = @intFromFloat(@floor((area.y - y) / line_h));
            const s = @min(skip, o.rows);
            row += s;
            y += @as(f32, @floatFromInt(s)) * line_h;
        }
        var lo: usize = 0;
        var hi: usize = o.row_starts.items.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (o.row_starts.items[mid] <= row) lo = mid else hi = mid;
        }
        var line_idx = lo;
        const scale = dl.scale;
        const cell_px = ui.text.cellAdvance(theme.font_output) * scale;
        const clip = blk: {
            const cr = dl.currentClip();
            break :blk [4]f32{ @round(cr.x * scale), @round(cr.y * scale), @round(cr.right() * scale), @round(cr.bottom() * scale) };
        };
        while (row < end_row and line_idx < o.row_starts.items.len) : (row += 1) {
            if (y > area.bottom()) {
                y += @as(f32, @floatFromInt(end_row - row)) * line_h;
                break;
            }
            while (line_idx + 1 < o.row_starts.items.len and o.row_starts.items[line_idx + 1] <= row) line_idx += 1;
            const cells = o.buf.lines.items[line_idx].cells.items;
            const seg = row - o.row_starts.items[line_idx];
            const from = @min(cells.len, @as(usize, seg) * cols);
            const to = @min(cells.len, from + cols);
            const baseline_px = @round(ui.text.baselineForCenter(theme.font_output, y + line_h / 2) * scale);
            const x_px = @round(x * scale);
            var col: f32 = 0;
            for (cells[from..to]) |cell| {
                const st = o.buf.style(cell.style);
                var fg = resolve(st.fg, if (st.bold) theme.text else theme.text_2, .fg);
                var bg: ?Color = if (st.bg != buffer_mod.color_default) resolve(st.bg, theme.bg_block, .bg) else null;
                if (st.inverse) {
                    const old_fg = fg;
                    fg = bg orelse theme.bg_block;
                    bg = old_fg;
                }
                if (st.dim) fg = fg.alpha(0.6);
                const w_cells: f32 = @floatFromInt(@max(1, gfx_text.cellWidth(cell.cp)));
                const cx = (x_px + col * cell_px) / scale;
                if (bg) |bc| dl.rect(.{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = line_h }, bc);
                if (cell.cp != ' ' and !boxdraw.draw(dl, .{ .x = cx, .y = y, .w = w_cells * cell_px / scale, .h = line_h }, cell.cp, fg)) {
                    const font = if (st.bold) theme.font_output_bold else theme.font_output;
                    _ = dl.glyph(font, cell.cp, x_px + col * cell_px, baseline_px, fg, clip);
                }
                if (st.underline) dl.rect(.{ .x = cx, .y = y + line_h - 5, .w = w_cells * cell_px / scale, .h = 1 }, fg);
                col += @floatFromInt(gfx_text.cellWidth(cell.cp));
            }
            y += line_h;
        }
        return y;
    }

    fn drawTable(self: *NotebookTab, ui: *Ui, t: *Table, x: f32, y0: f32, w: f32) void {
        _ = self;
        const dl = ui.dl;
        const font = theme.font_row_mono;
        const head_font = theme.font_row_mono_bold;
        // Column widths: the widest of header and cells, capped; measured once.
        if (t.widths.len > 0 and t.widths[0] == 0) {
            for (t.columns, 0..) |c, i| t.widths[i] = ui.text.measure(head_font, c);
            if (t.dtypes) |d| for (d, 0..) |s, i| {
                t.widths[i] = @max(t.widths[i], ui.text.measure(font, s));
            };
            for (t.rows) |r| for (r, 0..) |s, i| {
                if (i < t.widths.len) t.widths[i] = @max(t.widths[i], ui.text.measure(font, s));
            };
            for (t.widths) |*cw| cw.* = @min(table_col_max, cw.* + 20);
        }
        dl.pushClip(.{ .x = x, .y = y0, .w = w, .h = t.height() });
        defer dl.popClip();
        var y = y0;
        var cx = x;
        for (t.columns, 0..) |c, i| {
            _ = dl.textEllipsis(head_font, cx, y + table_row_h / 2, c, t.widths[i] - 10, theme.text_2);
            cx += t.widths[i];
        }
        y += table_row_h;
        if (t.dtypes) |d| {
            cx = x;
            for (d, 0..) |s, i| {
                if (i >= t.widths.len) break;
                _ = dl.textEllipsis(font, cx, y + table_row_h / 2, s, t.widths[i] - 10, theme.ansi[4]);
                cx += t.widths[i];
            }
            y += table_row_h;
        }
        dl.rect(.{ .x = x, .y = y - 1, .w = @min(w, cx - x), .h = 1 }, theme.line);
        for (t.rows) |r| {
            if (y > y0 + t.height()) break;
            cx = x;
            for (r, 0..) |s, i| {
                if (i >= t.widths.len) break;
                _ = dl.textEllipsis(font, cx, y + table_row_h / 2, s, t.widths[i] - 10, theme.text);
                cx += t.widths[i];
            }
            y += table_row_h;
        }
        if (t.truncated) _ = dl.textCentered(theme.font_hint, x, y + line_h / 2, "… more rows than shown", theme.text_3);
    }

    fn drawInput(self: *NotebookTab, ui: *Ui, r: Rect, focused: bool) void {
        const dl = ui.dl;
        const busy = self.ask_req != null and self.input_kind == .ask;
        const border_color = if (!focused) theme.line_strong else if (busy) theme.teal.alpha(0.75) else theme.accent;
        dl.shape(r, theme.block_radius, theme.bg_inset, 1, border_color);
        if (ui.pressed and ui.mouseIn(r)) self.focus_cell = null;

        // The kind switch, at the top left.
        const kinds = [_]Kind{ .py, .sh, .md, .ask };
        var x = r.x + 12;
        const chip_y = r.y + self.input.pad_top + (line_h - 22) / 2;
        for (kinds, 0..) |k, i| {
            const w = field.chipWidth(ui, k.label());
            const cr: Rect = .{ .x = x, .y = chip_y, .w = w, .h = 22 };
            if (field.chip(ui, Ui.id("notebook.inkind", self.input.salt * 8 + i), cr, k.label(), self.input_kind == k)) self.setInputKind(k);
            x += w + 4;
        }
        const text_x = x + 6;
        const editor_rect: Rect = .{ .x = text_x - theme.block_pad_x, .y = r.y, .w = r.right() - text_x + theme.block_pad_x - 6, .h = r.h - input_hint_h };
        self.input.draw(ui, editor_rect, focused);

        // The hint row.
        const hy = r.bottom() - input_hint_h / 2 - 2;
        var hx = r.x + 12;
        const hint: []const u8 = switch (self.input_kind) {
            .ask => if (busy) "Asking…" else "↵ Ask the agent · it answers below and can add a cell",
            .md => "⇧↵ Add the Markdown cell",
            .sh => "⇧↵ Run as a new shell cell · ↵ New line",
            else => "⇧↵ Run as a new cell · ↵ New line",
        };
        hx += dl.textCentered(theme.font_hint, hx, hy, hint, theme.text_3) + 20;
        var kbuf: [96]u8 = undefined;
        const klabel = self.kernelLabel(&kbuf);
        const kw = ui.text.measure(theme.font_hint, klabel);
        if (r.right() - 12 - kw > hx) {
            const dot_color = if (self.kernel) |k| switch (k.phase) {
                .ready => if (k.busy) theme.accent else theme.teal,
                .failed, .dead => theme.red,
                else => theme.text_3,
            } else theme.text_3;
            dl.circle(r.right() - 12 - kw - 12, hy, 3.5, dot_color);
            _ = dl.textCentered(theme.font_hint, r.right() - 12 - kw, hy, klabel, theme.text_3);
        }
    }

    // ── the inspector ───────────────────────────────────────────────────
    fn drawInspector(self: *NotebookTab, ui: *Ui, panel: Rect) void {
        const dl = ui.dl;
        dl.rect(panel, theme.bg_side);
        // Header: Variables | Kernel.
        var x = panel.x + 14;
        const pages = [_]struct { label: []const u8, page: @TypeOf(self.inspector_page) }{ .{ .label = "Variables", .page = .variables }, .{ .label = "Kernel", .page = .kernel } };
        for (pages, 0..) |p, i| {
            const w = field.chipWidth(ui, p.label);
            const cr: Rect = .{ .x = x, .y = panel.y + (inspector_head_h - 22) / 2, .w = w, .h = 22 };
            if (field.chip(ui, Ui.id("notebook.page", self.input.salt * 8 + i), cr, p.label, self.inspector_page == p.page)) self.inspector_page = p.page;
            x += w + 6;
        }
        dl.rect(.{ .x = panel.x, .y = panel.y + inspector_head_h, .w = panel.w, .h = 1 }, theme.line);
        const body: Rect = .{ .x = panel.x, .y = panel.y + inspector_head_h + 1, .w = panel.w, .h = panel.h - inspector_head_h - 1 };
        dl.pushClip(body);
        defer dl.popClip();
        switch (self.inspector_page) {
            .variables => self.drawVariables(ui, body),
            .kernel => self.drawKernelPage(ui, body),
        }
    }

    fn drawVariables(self: *NotebookTab, ui: *Ui, body: Rect) void {
        const dl = ui.dl;
        const font = theme.font_row_mono;
        const px = body.x + 14;
        const name_w: f32 = 84;
        const type_w: f32 = 96;
        const row_h: f32 = 30;
        const total = 28 + @as(f32, @floatFromInt(self.vars.len)) * row_h + 16;
        const max_scroll = @max(0, total - body.h);
        self.inspector_scroll = std.math.clamp(self.inspector_scroll - ui.takeScroll(body), 0, max_scroll);
        var y = body.y + 8 - self.inspector_scroll;
        _ = dl.textCentered(font, px, y + 14, "name", theme.text_3);
        _ = dl.textCentered(font, px + name_w, y + 14, "type", theme.text_3);
        _ = dl.textCentered(font, px + name_w + type_w, y + 14, "value", theme.text_3);
        y += 28;
        dl.rect(.{ .x = px, .y = y - 1, .w = body.w - 28, .h = 1 }, theme.line);
        if (self.vars.len == 0) {
            const msg: []const u8 = if (self.kernel == null or self.kernel.?.phase != .ready) "The variables show once the kernel is up." else "No variables yet: run a cell.";
            _ = dl.textEllipsis(theme.font_hint, px, y + 20, msg, body.w - 28, theme.text_3);
        }
        for (self.vars) |v| {
            if (y + row_h < body.y) {
                y += row_h;
                continue;
            }
            if (y > body.bottom()) break;
            const cy = y + row_h / 2;
            _ = dl.textEllipsis(font, px, cy, v.name, name_w - 8, theme.text);
            _ = dl.textEllipsis(font, px + name_w, cy, v.kind, type_w - 8, theme.ansi[4]);
            _ = dl.textEllipsis(font, px + name_w + type_w, cy, v.value, body.w - 28 - name_w - type_w, theme.text_2);
            y += row_h;
        }
        sidebar.drawScrollbarAxis(ui, Ui.id("notebook.vars.bar", self.input.salt), .vertical, body, self.inspector_scroll, total);
    }

    fn drawKernelPage(self: *NotebookTab, ui: *Ui, body: Rect) void {
        const dl = ui.dl;
        const px = body.x + 14;
        const right = body.right() - 14;
        var y = body.y + 14;
        _ = dl.textCentered(theme.font_group, px, y + 8, "KERNEL", theme.text_3);
        y += 28;
        var kbuf: [96]u8 = undefined;
        var abbrev: [256]u8 = undefined;
        const rows = [_]struct { label: []const u8, value: []const u8 }{
            .{ .label = "Kernel", .value = if (self.kernel_display.len > 0) self.kernel_display else if (self.kernel_name.len > 0) self.kernel_name else "python3" },
            .{ .label = "Interpreter", .value = if (self.kernel_interpreter.len > 0) sys.abbreviateHome(self.kernel_interpreter, &abbrev) else if (self.kernel) |k| sys.abbreviateHome(k.interpreter(), &abbrev) else "—" },
            .{ .label = "State", .value = self.kernelLabel(&kbuf) },
            .{ .label = "Memory", .value = if (self.memory_mb > 0) (std.fmt.bufPrint(abbrev[200..], "{d} MB", .{self.memory_mb}) catch "—") else "—" },
        };
        for (rows) |row| {
            _ = dl.textCentered(theme.font_hint, px, y + 11, row.label, theme.text_2);
            const lw = ui.text.measure(theme.font_hint, row.label) + 12;
            _ = dl.textEllipsis(theme.font_row_mono, px + lw, y + 11, row.value, right - px - lw, theme.text);
            y += 26;
        }
        y += 8;
        var x = px;
        const b1: Rect = .{ .x = x, .y = y, .w = ui.text.measure(theme.font_hint, "Interrupt") + 20, .h = 26 };
        dl.border(b1, 6, 1, theme.line_strong);
        if (field.textButton(ui, Ui.id("notebook.interrupt", self.input.salt), b1, "Interrupt", theme.text)) self.interrupt();
        x += b1.w + 8;
        const b2: Rect = .{ .x = x, .y = y, .w = ui.text.measure(theme.font_hint, "Restart") + 20, .h = 26 };
        dl.border(b2, 6, 1, theme.line_strong);
        if (field.textButton(ui, Ui.id("notebook.restart", self.input.salt), b2, "Restart", theme.text)) self.restartKernel();
        y += 26 + 30;

        _ = dl.textCentered(theme.font_group, px, y + 8, "AGENT CONTEXT", theme.text_3);
        y += 30;
        _ = dl.textCentered(theme.font_ui_medium, px, y + 8, "Share variable schema", theme.text);
        _ = dl.textEllipsis(theme.font_hint, px, y + 30, "Names and types only. Values never leave the kernel.", right - px - 52, theme.text_2);
        const cfg = config.get();
        const on = cfg.notebooks.share_schema;
        const toggle: Rect = .{ .x = right - 36, .y = y, .w = 36, .h = 20 };
        const st = ui.button(Ui.id("notebook.share", self.input.salt), toggle);
        dl.rrect(toggle, 10, if (on) theme.accent else theme.line_strong);
        const knob_x = if (on) toggle.right() - 18 else toggle.x + 2;
        dl.rrect(.{ .x = knob_x, .y = toggle.y + 2, .w = 16, .h = 16 }, 8, if (on) theme.on_accent else theme.text_2);
        if (st.clicked) {
            cfg.notebooks.share_schema = !on;
            cfg.save();
        }
        y += 50;
        _ = dl.textCentered(theme.font_group, px, y + 8, "STORAGE", theme.text_3);
        y += 30;
        const strip_on = cfg.notebooks.strip_outputs;
        _ = dl.textCentered(theme.font_ui_medium, px, y + 8, "Strip outputs when saving", theme.text);
        _ = dl.textEllipsis(theme.font_hint, px, y + 30, "The .ipynb keeps only the code; results stay here.", right - px - 52, theme.text_2);
        const toggle2: Rect = .{ .x = right - 36, .y = y, .w = 36, .h = 20 };
        const st2 = ui.button(Ui.id("notebook.stripout", self.input.salt), toggle2);
        dl.rrect(toggle2, 10, if (strip_on) theme.accent else theme.line_strong);
        const knob2_x = if (strip_on) toggle2.right() - 18 else toggle2.x + 2;
        dl.rrect(.{ .x = knob2_x, .y = toggle2.y + 2, .w = 16, .h = 16 }, 8, if (strip_on) theme.on_accent else theme.text_2);
        if (st2.clicked) {
            cfg.notebooks.strip_outputs = !strip_on;
            cfg.save();
        }
    }
};

// ── colours of styled output ─────────────────────────────────────────────
fn resolve(spec: buffer_mod.ColorSpec, default: Color, role: theme.InkRole) Color {
    return switch (spec >> 24) {
        1 => blk: {
            const n: u8 = @truncate(spec);
            break :blk if (n < 16 and role == .fg) theme.ansi[n] else theme.ink(palette(n), role);
        },
        2 => theme.ink(Color.fromRgb8(@truncate(spec >> 16), @truncate(spec >> 8), @truncate(spec)), role),
        else => default,
    };
}

fn palette(n: u8) Color {
    if (n < 16) return theme.ansi[n];
    if (n >= 232) {
        const v: u8 = 8 + 10 * (n - 232);
        return Color.fromRgb8(v, v, v);
    }
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    const i = n - 16;
    return Color.fromRgb8(levels[i / 36], levels[(i / 6) % 6], levels[i % 6]);
}

// ── tests ────────────────────────────────────────────────────────────────
test "notebook: folds round-trip through Jupyter's metadata, the rest untouched" {
    const gpa = std.testing.allocator;
    try std.testing.expect(!hiddenIn(gpa, "").input);
    const legacy = hiddenIn(gpa, "{\"collapsed\":true,\"tags\":[\"x\"]}");
    try std.testing.expect(legacy.outputs and !legacy.input);
    const lab = hiddenIn(gpa, "{\"jupyter\":{\"source_hidden\":true,\"outputs_hidden\":false}}");
    try std.testing.expect(lab.input and !lab.outputs);

    const both = try metadataWith(gpa, "{\"collapsed\":true,\"tags\":[\"x\"]}", .{ .input = true, .outputs = true });
    defer gpa.free(both);
    try std.testing.expectEqualStrings("{\"tags\":[\"x\"],\"jupyter\":{\"source_hidden\":true,\"outputs_hidden\":true}}", both);
    const back = hiddenIn(gpa, both);
    try std.testing.expect(back.input and back.outputs);
    const none = try metadataWith(gpa, both, .{});
    defer gpa.free(none);
    try std.testing.expectEqualStrings("{\"tags\":[\"x\"]}", none);
    const empty = try metadataWith(gpa, "{\"jupyter\":{\"outputs_hidden\":true}}", .{});
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "notebook: an exit status is read off a CalledProcessError" {
    try std.testing.expectEqual(@as(?i32, 3), NotebookTab.exitStatusOf("Command 'b'exit 3\\n'' returned non-zero exit status 3."));
    try std.testing.expect(NotebookTab.exitStatusOf("something else") == null);
}

test "notebook: text outputs keep their lines and colours" {
    const gpa = std.testing.allocator;
    var o = Out.init(gpa, .{ .kind = .stream, .name = try gpa.dupe(u8, "stdout"), .text = try gpa.dupe(u8, "one\n\x1b[31mtwo\x1b[0m\nthree") });
    defer o.deinit(gpa, null);
    try std.testing.expectEqual(OutKind.text, o.kind);
    try std.testing.expectEqual(@as(usize, 3), o.buf.lineCount());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try o.buf.appendText(&text, gpa);
    try std.testing.expectEqualStrings("one\ntwo\nthree", text.items);
    try std.testing.expect(o.buf.lines.items[1].cells.items[0].style != 0);
    o.append(gpa, " more\nfour");
    try std.testing.expectEqualStrings("one\n\x1b[31mtwo\x1b[0m\nthree more\nfour", o.src.text);
    try std.testing.expectEqual(@as(usize, 4), o.buf.lineCount());
}

test "notebook: a mime bundle picks the picture, the table, else the text" {
    const gpa = std.testing.allocator;
    var pic = Out.init(gpa, .{ .kind = .display_data, .data = try gpa.dupe(u8, "{\"image/png\":\"aGVsbG8=\\n\",\"text/plain\":\"<Figure>\"}") });
    defer pic.deinit(gpa, null);
    try std.testing.expectEqual(OutKind.picture, pic.kind);
    try std.testing.expectEqualStrings("hello", pic.png);

    var tab = Out.init(gpa, .{ .kind = .execute_result, .data = try gpa.dupe(u8, "{\"text/plain\":\"df\",\"text/html\":\"<table>…</table>\",\"application/vnd.tt.table+json\":{\"columns\":[\"a\",\"b\"],\"dtypes\":[\"i64\",\"str\"],\"rows\":[[\"1\",\"x\"],[2,\"y\"]],\"truncated\":true}}") });
    defer tab.deinit(gpa, null);
    try std.testing.expectEqual(OutKind.table, tab.kind);
    try std.testing.expectEqual(@as(usize, 2), tab.table.?.columns.len);
    try std.testing.expectEqualStrings("2", tab.table.?.rows[1][0]);
    try std.testing.expect(tab.table.?.truncated);

    var txt = Out.init(gpa, .{ .kind = .execute_result, .data = try gpa.dupe(u8, "{\"text/plain\":[\"a\\n\",\"b\"]}") });
    defer txt.deinit(gpa, null);
    try std.testing.expectEqual(OutKind.text, txt.kind);
    try std.testing.expectEqual(@as(usize, 2), txt.buf.lineCount());

    var html = Out.init(gpa, .{ .kind = .display_data, .data = try gpa.dupe(u8, "{\"text/html\":\"<b>x</b>\"}") });
    defer html.deinit(gpa, null);
    try std.testing.expectEqual(OutKind.note, html.kind);
}

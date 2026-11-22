//! The History view: the commits newest first, each on a row with its
//! place in the graph, its subject and the names pointing at it (branches,
//! remote branches, tags), its author, short hash and how long ago it was
//! made. A click selects a commit (its detail shows beside the list);
//! scrolling near the end asks for the next page. Typing in the box above
//! the list keeps the commits whose subject, author, hash or ref names
//! contain the text; the graph is not drawn then, since the rows left are
//! no longer neighbours.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const log_mod = @import("../model/log.zig");
const lanes_mod = @import("../model/lanes.zig");
const reltime = @import("../model/reltime.zig");
const kit = @import("kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;

const row_h: f32 = 44;
const head_h: f32 = 28;
const bar_h: f32 = 48;
const pad: f32 = 16;
const lane_w: f32 = 16;
const lane_x0: f32 = 12;
/// Lanes beyond this are not drawn: the message keeps its room.
const max_drawn_lanes: usize = 12;
const stroke: f32 = 2;

pub const State = struct {
    commits: []const log_mod.Commit,
    rows: []const lanes_mod.Row,
    /// The widest row of the graph, in lanes.
    width: u8,
    /// The index of the commit on show beside the list.
    selected: ?usize,
    /// Now, in seconds since the epoch.
    now: i64,
    loading: bool,
    /// A first answer has come in.
    loaded: bool,
    /// There is nothing older to ask for.
    complete: bool,
    /// Changes whenever the commits do.
    generation: u64,
};

pub const Intent = union(enum) { select: usize, more };

pub const View = struct {
    gpa: std.mem.Allocator,
    intent: ?Intent = null,
    scroll: f32 = 0,
    filter: std.ArrayList(u8) = .empty,
    /// The commits the filter keeps, and what they were worked out for.
    matches: std.ArrayList(u32) = .empty,
    matched_gen: u64 = 0,
    matched_dirty: bool = true,
    /// A row to bring into view on the next draw.
    reveal: ?usize = null,

    pub const field_filter = Ui.id("repo.history.filter", 0);

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.filter.deinit(self.gpa);
        self.matches.deinit(self.gpa);
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    fn filtering(self: *const View) bool {
        return self.filter.items.len > 0;
    }

    fn syncFilter(self: *View, focus: *field.Focus) void {
        if (focus.id != field_filter or !focus.changed()) return;
        self.filter.clearRetainingCapacity();
        self.filter.appendSlice(self.gpa, std.mem.trim(u8, focus.editor.bytes(), " ")) catch {};
        focus.markSynced();
        self.matched_dirty = true;
        self.scroll = 0;
    }

    fn matchesCommit(c: log_mod.Commit, needle: []const u8) bool {
        if (kit.containsIgnoreCase(c.subject, needle) or kit.containsIgnoreCase(c.author, needle)) return true;
        if (std.ascii.startsWithIgnoreCase(c.hash, needle)) return true;
        for (c.refs) |r| if (kit.containsIgnoreCase(r.name, needle)) return true;
        return false;
    }

    fn rematch(self: *View, state: State) void {
        if (!self.matched_dirty and self.matched_gen == state.generation) return;
        self.matched_dirty = false;
        self.matched_gen = state.generation;
        self.matches.clearRetainingCapacity();
        if (!self.filtering()) return;
        for (state.commits, 0..) |c, i| {
            if (matchesCommit(c, self.filter.items)) self.matches.append(self.gpa, @intCast(i)) catch break;
        }
    }

    /// The commit above (`delta` −1) or below (+1) the selected one among
    /// the rows on show: what ↑ and ↓ ask for.
    pub fn step(self: *View, state: State, delta: i32) void {
        const count = if (self.filtering()) self.matches.items.len else state.commits.len;
        if (count == 0) return;
        var pos: usize = 0;
        if (state.selected) |sel| {
            if (self.filtering()) {
                for (self.matches.items, 0..) |m, i| {
                    if (m == sel) pos = i;
                }
            } else pos = @min(sel, count - 1);
            if (delta < 0 and pos > 0) pos -= 1;
            if (delta > 0 and pos + 1 < count) pos += 1;
        }
        self.reveal = pos;
        self.intent = .{ .select = if (self.filtering()) self.matches.items[pos] else pos };
    }

    pub fn draw(self: *View, ui: *Ui, focus: *field.Focus, rect: Rect, state: State) void {
        const dl = ui.dl;
        self.syncFilter(focus);
        self.rematch(state);
        dl.pushClip(rect);
        defer dl.popClip();

        // The filter box, and what is going on at its right.
        {
            const fw = @min(400, rect.w - 2 * pad);
            const fr: Rect = .{ .x = rect.x + pad, .y = rect.y + (bar_h - field.height) / 2, .w = fw, .h = field.height };
            const fres = field.draw(ui, focus, field_filter, fr, self.filter.items, .{ .placeholder = "Filter commits by message, author, hash or branch", .font = kit.font_text });
            if (fres.clicked) focus.take(field_filter, self.filter.items, ui.now);
            if (ui.pressed and focus.id == field_filter and !ui.mouseIn(fr)) focus.drop();
            var note_buf: [48]u8 = undefined;
            const note: []const u8 = if (state.loading and !state.loaded)
                "Reading history…"
            else if (self.filtering())
                std.fmt.bufPrint(&note_buf, "{d} of {d}{s}", .{ self.matches.items.len, state.commits.len, if (state.complete) "" else "+" }) catch ""
            else
                std.fmt.bufPrint(&note_buf, "{d}{s} commits", .{ state.commits.len, if (state.complete) "" else "+" }) catch "";
            if (fr.right() + 16 < rect.right() - pad) _ = dl.textRightEllipsis(kit.font_small, rect.right() - pad, fr.centerY(), note, rect.right() - pad - fr.right() - 16, theme.text_3);
        }

        // The columns: how many fit depends on the room.
        const graph_w: f32 = if (self.filtering()) 0 else @max(44, lane_x0 * 2 + lane_w * @as(f32, @floatFromInt(@min(max_drawn_lanes, @max(1, state.width)) - 1)));
        // The author's name gives way to their initials alone, then the
        // hash goes, as the list narrows.
        const show_author = rect.w >= 520;
        const author_named = rect.w >= 760;
        const show_hash = rect.w >= 440;
        const date_w: f32 = 92;
        const hash_w: f32 = if (show_hash) 76 else 0;
        const author_w: f32 = if (!show_author) 0 else if (author_named) 150 else 22;
        const col_gap: f32 = 12;
        const date_right = rect.right() - pad;
        const hash_x = date_right - date_w - (if (show_hash) hash_w + col_gap else 0);
        const author_x = hash_x - (if (show_author) author_w + col_gap else 0);
        const msg_x = rect.x + pad + graph_w + (if (graph_w > 0) col_gap else 0);
        const msg_right = author_x - col_gap;

        const head: Rect = .{ .x = rect.x, .y = rect.y + bar_h, .w = rect.w, .h = head_h };
        dl.rect(.{ .x = head.x, .y = head.y, .w = head.w, .h = 1 }, theme.line);
        dl.rect(.{ .x = head.x, .y = head.bottom() - 1, .w = head.w, .h = 1 }, theme.line);
        if (graph_w > 0) _ = kit.label(ui, rect.x + pad, head.centerY(), "GRAPH");
        _ = kit.label(ui, msg_x, head.centerY(), "MESSAGE");
        if (show_author and author_named) _ = kit.label(ui, author_x, head.centerY(), "AUTHOR");
        if (show_hash) _ = kit.label(ui, hash_x, head.centerY(), "HASH");
        _ = dl.textRight(kit.font_label, date_right, head.centerY(), "DATE", theme.text_3);

        // The rows.
        const area: Rect = .{ .x = rect.x, .y = head.bottom(), .w = rect.w, .h = @max(0, rect.bottom() - head.bottom()) };
        const count = if (self.filtering()) self.matches.items.len else state.commits.len;
        const content_h = @as(f32, @floatFromInt(count)) * row_h;
        const max_scroll = @max(0, content_h - area.h);
        if (sidebar.scrollbarDrag(ui, Ui.id("repo.history.bar", 0), .vertical, area, self.scroll, content_h)) |to| self.scroll = to;
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        if (self.reveal) |pos| {
            self.reveal = null;
            const top = @as(f32, @floatFromInt(pos)) * row_h;
            if (top < self.scroll) self.scroll = top;
            if (top + row_h > self.scroll + area.h) self.scroll = top + row_h - area.h;
            self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
        }
        dl.pushClip(area);
        defer dl.popClip();

        if (count == 0) {
            const msg: []const u8 = if (!state.loaded) "" else if (self.filtering()) "No commit matches." else "No commits yet.";
            _ = dl.textEllipsis(kit.font_text, rect.x + pad, area.y + 24, msg, area.w - 2 * pad, theme.text_3);
            return;
        }

        const first: usize = @intFromFloat(@floor(self.scroll / row_h));
        const visible: usize = @as(usize, @intFromFloat(@ceil(area.h / row_h))) + 1;
        var pos = first;
        while (pos < count and pos < first + visible) : (pos += 1) {
            const i: usize = if (self.filtering()) self.matches.items[pos] else pos;
            const c = state.commits[i];
            const row: Rect = .{ .x = area.x, .y = area.y + @as(f32, @floatFromInt(pos)) * row_h - self.scroll, .w = area.w, .h = row_h };
            const selected = state.selected != null and state.selected.? == i;
            const st = ui.button(Ui.id("repo.history.row", i), row);
            if (selected) dl.rect(row, theme.accent.alpha(0.11)) else if (st.hover) dl.rect(row, theme.hover);
            dl.rect(.{ .x = row.x, .y = row.bottom() - 1, .w = row.w, .h = 1 }, theme.line.alpha(0.6));
            if (st.clicked) self.intent = .{ .select = i };
            const cy = row.centerY();

            if (graph_w > 0 and i < state.rows.len) drawGraph(ui, rect.x + pad, row, state.rows[i], if (selected) Color.mix(theme.bg, theme.accent, 0.11) else theme.bg);

            // The date, the hash and the author, from the right.
            var ago_buf: [32]u8 = undefined;
            _ = dl.textRight(kit.font_small, date_right, cy, reltime.ago(&ago_buf, state.now, c.time), theme.text_3);
            if (show_hash) _ = dl.textCentered(kit.font_mono, hash_x, cy, c.short(), theme.text_3);
            if (show_author) {
                kit.avatar(ui, author_x + 11, cy, 22, c.author);
                if (author_named) _ = dl.textEllipsis(kit.font_small, author_x + 30, cy, c.author, author_w - 30, theme.text_2);
            }

            // The subject, then the names pointing at the commit as far as they fit.
            const room = @max(0, msg_right - msg_x);
            var chips_w: f32 = 0;
            var shown: usize = 0;
            for (c.refs) |r| {
                const w = kit.chipWidth(ui, r.name) + 6;
                if (shown > 0 and chips_w + w > room * 0.6) break;
                chips_w += @min(w, room * 0.6);
                shown += 1;
            }
            const subject_w = dl.textEllipsis(if (selected) kit.font_text_bold else kit.font_text, msg_x, cy, c.subject, @max(0, room - chips_w - (if (shown > 0) @as(f32, 8) else 0)), theme.text);
            var cx = msg_x + subject_w + 8;
            for (c.refs[0..shown]) |r| {
                if (cx >= msg_right) break;
                cx += kit.chip(ui, cx, cy, r.name, refColor(r), msg_right - cx) + 6;
            }
        }

        if (max_scroll > 0) sidebar.drawScrollbarAxis(ui, Ui.id("repo.history.bar", 0), .vertical, area, self.scroll, content_h);
        // Near the end: the next page, unless one is on its way.
        if (!state.complete and !state.loading and state.loaded and self.scroll + area.h > content_h - 6 * row_h) self.intent = self.intent orelse .more;
    }
};

fn refColor(r: log_mod.Ref) Color {
    return switch (r.kind) {
        .head => theme.accent,
        .local => if (r.current) theme.accent else theme.teal,
        .remote => theme.text_3,
        .tag => kit.amber(),
    };
}

fn laneX(x0: f32, col: usize) f32 {
    return x0 + lane_x0 + lane_w * @as(f32, @floatFromInt(@min(col, max_drawn_lanes - 1)));
}

/// One row of the graph: the lanes passing by, the strokes bending into
/// and out of the commit, and the commit's own dot (filled with `ground`,
/// the row's background, so the strokes stop at its rim).
fn drawGraph(ui: *Ui, x0: f32, row: Rect, r: lanes_mod.Row, ground: Color) void {
    const dl = ui.dl;
    const top = row.y;
    const mid = row.centerY();
    const bot = row.bottom();
    const xc = laneX(x0, r.col);
    var col: usize = 0;
    while (col < r.width and col < lanes_mod.max_lanes) : (col += 1) {
        const x = laneX(x0, col);
        const color = kit.hue(col);
        if (lanes_mod.Row.has(r.through, col)) dl.line(x, top, x, bot, stroke, color);
        if (lanes_mod.Row.has(r.join, col)) {
            const d = mid - top;
            dl.curve(.{ x, top }, .{ x, top + d * 0.6 }, .{ x, mid }, .{ xc, mid }, stroke, color);
        }
        if (lanes_mod.Row.has(r.fork, col)) {
            const d = bot - mid;
            dl.curve(.{ xc, mid }, .{ x, mid }, .{ x, mid + d * 0.4 }, .{ x, bot }, stroke, color);
        }
        if (lanes_mod.Row.has(r.shift, col)) {
            // Down its own column, then over into the commit's by the bottom.
            dl.line(x, top, x, mid, stroke, color);
            const d = bot - mid;
            dl.curve(.{ x, mid }, .{ x, mid + d * 0.7 }, .{ xc, mid + d * 0.3 }, .{ xc, bot }, stroke, color);
        }
    }
    const own = kit.hue(r.col);
    if (r.from_top) dl.line(xc, top, xc, mid, stroke, own);
    if (r.to_bottom) dl.line(xc, mid, xc, bot, stroke, own);
    dl.shape(.{ .x = xc - 5, .y = mid - 5, .w = 10, .h = 10 }, 5, ground, 2, own);
}

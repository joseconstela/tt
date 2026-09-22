//! Settings › AI › Features: what the configured agents are used for. The
//! one feature so far hands commands the shell does not know to an agent;
//! this page picks that agent and edits the prompt it gets. Both live in
//! the config (`config.features`) and are written as they change.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const gfx_text = @import("../gfx/text.zig");
const config = @import("../config.zig");
const tab_mod = @import("tab.zig");
const Document = @import("../input/document.zig").Document;
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

/// What the agent is told when the prompt is left blank.
pub const default_prompt = "The user typed a line their shell does not recognise. Work out what they meant and propose the command that does it; keep any explanation to a line or two.";

const font = theme.font_ui;
const line_h: f32 = theme.output_line_h;
/// Rows the prompt box shows before it scrolls.
const box_rows: f32 = 6;
const box_pad: f32 = 10;
const row_h: f32 = 36;
const card_pad = theme.block_pad_x;
/// Height of a card's title and hint lines.
const card_head: f32 = 70;

/// One visual row of the prompt after soft wrapping: bytes [start, end)
/// of the text; `last` when it ends its line.
const Row = struct { start: u32, end: u32, last: bool };

pub const Page = struct {
    gpa: std.mem.Allocator,
    prompt: Document,
    /// The prompt box has the keyboard.
    editing: bool = false,
    rows: std.ArrayList(Row) = .empty,
    /// What `rows` reflect: the width they were wrapped for, the document
    /// revision, and whether they show the placeholder instead of the text.
    wrap_w: f32 = 0,
    wrap_revision: u64 = std.math.maxInt(u64),
    rows_placeholder: bool = false,
    /// Text engine from the last draw, for ↑/↓ between visual rows.
    text: ?*gfx_text.TextEngine = null,
    scroll: f32 = 0,
    content_h: f32 = 0,
    box_h: f32 = 0,
    /// Bring the caret into view on the next draw (set by keyboard actions).
    follow: bool = false,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    seen_version: u64 = 0,
    caret: Rect = .{},
    /// `prompt.revision` last written to the config.
    saved_revision: u64 = 0,
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa, .prompt = Document.init(gpa) };
    }

    pub fn deinit(self: *Page) void {
        self.rows.deinit(self.gpa);
        self.prompt.deinit();
    }

    /// Takes the prompt from the config, once.
    fn load(self: *Page) void {
        self.loaded = true;
        const cfg = config.get();
        self.prompt.setText(cfg.features.command_fallback_prompt, .plain) catch {};
        self.saved_revision = self.prompt.revision;
    }

    /// Writes the prompt to the config when it changed.
    fn flush(self: *Page) void {
        if (!self.loaded or self.prompt.revision == self.saved_revision) return;
        self.saved_revision = self.prompt.revision;
        const cfg = config.get();
        cfg.setString(&cfg.features.command_fallback_prompt, self.prompt.bytes());
        cfg.touch();
    }

    // ── keyboard (the settings tab routes here while this page is up) ───
    pub fn onText(self: *Page, utf8: []const u8) void {
        if (!self.editing) return;
        self.prompt.insert(utf8);
        self.follow = true;
    }

    pub fn onMarkedText(self: *Page, utf8: []const u8) void {
        if (!self.editing) return;
        self.prompt.setMarked(utf8);
        self.follow = true;
    }

    /// True when the prompt box had the keyboard and took the key.
    pub fn onEdit(self: *Page, cmd: EditCommand) bool {
        if (!self.editing) return false;
        const e = &self.prompt.editor;
        switch (cmd) {
            // ⎋ drops the selection, then the focus.
            .cancel => {
                if (e.selection() != null) {
                    e.anchor = null;
                    e.version +%= 1;
                } else self.editing = false;
                return true;
            },
            .move_up, .move_down, .select_up, .select_down => {
                if (!self.moveRow(cmd)) _ = self.prompt.apply(cmd);
            },
            .page_up, .page_down => {
                self.scroll += if (cmd == .page_up) -self.box_h else self.box_h;
                return true;
            },
            .scroll_to_top => {
                self.scroll = 0;
                return true;
            },
            .scroll_to_bottom => {
                self.scroll = self.content_h;
                return true;
            },
            // A prompt has no use for indentation.
            .insert_tab, .insert_backtab => return true,
            else => _ = self.prompt.apply(cmd),
        }
        self.follow = true;
        return true;
    }

    /// Gives the keyboard up (the tab switched page).
    pub fn blur(self: *Page) void {
        self.editing = false;
    }

    pub fn copy(self: *Page, out: *std.ArrayList(u8), cut: bool) bool {
        if (!self.editing) return false;
        const e = &self.prompt.editor;
        const sel = e.selection() orelse return false;
        out.appendSlice(self.gpa, e.selectedText()) catch return false;
        if (cut) {
            self.prompt.replace(sel[0], sel[1], "");
            self.follow = true;
        }
        return true;
    }

    pub fn paste(self: *Page, utf8: []const u8) void {
        if (!self.editing) return;
        // Clipboard text may use CR line ends; the document keeps LF.
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.gpa);
        for (utf8, 0..) |b, i| {
            if (b == '\r') {
                if (i + 1 < utf8.len and utf8[i + 1] == '\n') continue;
                clean.append(self.gpa, '\n') catch return;
            } else clean.append(self.gpa, b) catch return;
        }
        self.prompt.insert(clean.items);
        self.follow = true;
    }

    pub fn hasMarkedText(self: *const Page) bool {
        return self.editing and self.prompt.editor.marked.items.len > 0;
    }

    pub fn caretRect(self: *const Page) Rect {
        return if (self.editing) self.caret else .{};
    }

    /// ⌘Z / ⇧⌘Z while the box has the keyboard.
    pub fn command(self: *Page, cmd: tab_mod.Command) bool {
        if (!self.editing) return false;
        switch (cmd) {
            .undo => {
                self.follow = true;
                return self.prompt.undo();
            },
            .redo => {
                self.follow = true;
                return self.prompt.redo();
            },
            else => return false,
        }
    }

    /// Caret blink and the write-back; true when a redraw is needed.
    pub fn tick(self: *Page, now: f64, active: bool) bool {
        self.flush();
        const e = &self.prompt.editor;
        if (e.version != self.seen_version) {
            self.seen_version = e.version;
            self.blink_t0 = now;
            self.blink_on = true;
        }
        const on = @mod(now - self.blink_t0, 1.06) < 0.53;
        if (on != self.blink_on) {
            self.blink_on = on;
            return active and self.editing;
        }
        return false;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// The page body under the title: the agent picker, then the prompt.
    /// `x`/`col_w` is the content column, `y` its top; returns the bottom.
    pub fn draw(self: *Page, ui: *Ui, x: f32, y: f32, col_w: f32, focused: bool) f32 {
        if (!self.loaded) self.load();
        const agents_bottom = drawAgents(ui, x, y, col_w);
        const bottom = self.drawPrompt(ui, x, agents_bottom + theme.block_gap, col_w, focused);
        self.flush();
        return bottom;
    }

    /// Which agent gets the commands the shell does not know: "Off" first,
    /// then one row per configured agent. A chosen agent that has since been
    /// removed is still shown, so the choice can be seen and changed.
    fn drawAgents(ui: *Ui, x: f32, y: f32, col_w: f32) f32 {
        const dl = ui.dl;
        const cfg = config.get();
        const agents = cfg.agents.items;
        // `current` points into the config: a click below replaces that
        // string, so it is re-read after one (and a stale choice is gone).
        var current: ?[]const u8 = cfg.features.command_fallback_agent;
        var missing = if (current) |name| findAgent(agents, name) == null else false;
        const n_rows: f32 = @floatFromInt(1 + agents.len + @intFromBool(missing));
        const note_h: f32 = if (agents.len == 0) 26 else 0;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + n_rows * row_h + note_h + 10 };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, "Unrecognised commands", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + card_pad, card.y + 52, "When the shell does not know a command, the line goes to this agent instead.", theme.text_3);

        var ry = card.y + card_head;
        if (radioRow(ui, Ui.id("settings.features.agent", 0), card, ry, "Off", "Unknown commands stay errors.", current == null, true)) {
            cfg.setOptString(&cfg.features.command_fallback_agent, null);
            cfg.touch();
            current = null;
            missing = false;
        }
        ry += row_h;
        for (agents, 0..) |a, i| {
            const selected = if (current) |name| std.mem.eql(u8, name, a.name) else false;
            var detail_buf: [96]u8 = undefined;
            const detail = if (a.model.len == 0) a.provider.label() else std.fmt.bufPrint(&detail_buf, "{s} · {s}", .{ a.provider.label(), a.model }) catch a.provider.label();
            if (radioRow(ui, Ui.id("settings.features.agent", i + 1), card, ry, a.name, detail, selected, true)) {
                cfg.setOptString(&cfg.features.command_fallback_agent, a.name);
                cfg.touch();
                current = cfg.features.command_fallback_agent;
                missing = false;
            }
            ry += row_h;
        }
        if (missing) {
            _ = radioRow(ui, 0, card, ry, current.?, "No longer set up: pick another.", true, false);
            ry += row_h;
        }
        if (agents.len == 0) {
            _ = dl.textCentered(theme.font_hint, card.x + card_pad + 10, ry + 10, "No agents yet: add one under AI › Agents.", theme.text_3);
        }
        return card.bottom();
    }

    fn drawPrompt(self: *Page, ui: *Ui, x: f32, y: f32, col_w: f32, focused: bool) f32 {
        const dl = ui.dl;
        const box_h = box_rows * line_h + 2 * box_pad;
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_head + box_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, card.y + 28, "Prompt", theme.text);
        _ = dl.textCentered(theme.font_hint, card.x + card_pad, card.y + 52, "What the agent is told before the command you typed. Blank uses the default.", theme.text_3);
        self.drawBox(ui, .{ .x = card.x + card_pad, .y = card.y + card_head, .w = card.w - 2 * card_pad, .h = box_h }, focused);
        return card.bottom();
    }

    /// The prompt box: soft-wrapped text with caret, selection, IME text
    /// and scrolling. A press inside takes the keyboard, one anywhere else
    /// gives it up.
    fn drawBox(self: *Page, ui: *Ui, box: Rect, focused: bool) void {
        const dl = ui.dl;
        const text = ui.text;
        const scale = dl.scale;
        const doc = &self.prompt;
        const e = &doc.editor;
        self.text = text;
        self.box_h = box.h;

        if (ui.pressed) self.editing = ui.mouseIn(box);

        const inner = box.inset(box_pad, box_pad);
        const wrap_w = @max(20, inner.w - 6);
        const empty = doc.bytes().len == 0;
        const src: []const u8 = if (empty) default_prompt else doc.bytes();
        if (self.wrap_revision != doc.revision or self.wrap_w != wrap_w or self.rows_placeholder != empty) {
            self.wrap(text, src, wrap_w);
            self.wrap_revision = doc.revision;
            self.wrap_w = wrap_w;
            self.rows_placeholder = empty;
        }
        const rows = self.rows.items;
        self.content_h = @as(f32, @floatFromInt(rows.len)) * line_h + 2 * box_pad;
        const max_scroll = @max(0, self.content_h - box.h);

        self.scroll -= ui.takeScroll(box);
        const vbar = Ui.id("settings.features.prompt.vbar", 0);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, box, self.scroll, self.content_h)) |s| self.scroll = s;

        // Mouse: caret, word, line, drag selection (a drag past the top or
        // bottom scrolls that way).
        const d = ui.drag(Ui.id("settings.features.prompt", 0), box);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if ((d.started or d.dragging) and !empty) {
            if (d.dragging and !d.started) {
                const pull = edgePull(ui.my, box.y, box.bottom());
                if (pull != 0) {
                    self.scroll = std.math.clamp(self.scroll + pull, 0, max_scroll);
                    ui.wants_frame = true;
                }
            }
            const off = self.offsetAt(text, src, inner, ui.mx, ui.my);
            if (d.started) {
                if (ui.click_count >= 3) {
                    doc.selectLine(doc.lineOf(off));
                } else if (ui.click_count == 2) {
                    e.selectWordAt(off);
                } else e.setCursor(off, ui.mods.shift);
            } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                e.setCursor(off, true);
            }
            self.follow = false;
        }

        // Follow the caret after keyboard actions.
        const caret_row = if (empty) 0 else self.rowOf(e.cursor);
        if (self.follow) {
            self.follow = false;
            const top = @as(f32, @floatFromInt(caret_row)) * line_h;
            if (top < self.scroll) self.scroll = top;
            if (top + line_h > self.scroll + inner.h) self.scroll = top + line_h - inner.h;
        }
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);

        // Paint.
        const ring = if (self.editing and focused) theme.accent.alpha(0.7) else theme.line_strong;
        dl.shape(box, 8, theme.bg_inset, 1, ring);
        dl.pushClip(.{ .x = box.x + 1, .y = box.y + 1, .w = box.w - 2, .h = box.h - 2 });
        const clip = blk: {
            const c = dl.currentClip();
            break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
        };
        const y0 = inner.y - self.scroll;
        const first: usize = @intFromFloat(@floor(self.scroll / line_h));
        const sel: ?[2]usize = if (empty) null else e.selection();
        const color = if (empty) theme.text_3 else theme.text;
        var caret_x = inner.x;
        var caret_y = inner.y;
        var r = first;
        while (r < rows.len) : (r += 1) {
            const row = rows[r];
            const ry = y0 + @as(f32, @floatFromInt(r)) * line_h;
            if (ry > box.bottom()) break;
            const baseline_px = @round(text.baselineForCenter(font, ry + line_h / 2) * scale);
            var px = inner.x;
            var it = gfx_text.Utf8Iter{ .bytes = src[row.start..row.end] };
            while (true) {
                const at = row.start + it.index;
                if (!empty and r == caret_row and at == e.cursor) {
                    caret_x = px;
                    caret_y = ry;
                }
                const cp = it.next() orelse break;
                const adv = advanceOf(text, cp);
                if (sel) |s| if (at >= s[0] and at < s[1]) {
                    dl.rect(.{ .x = px, .y = ry + 1, .w = adv, .h = line_h - 2 }, theme.selection());
                };
                if (cp != ' ' and cp != '\t') _ = dl.glyph(font, cp, @round(px * scale), baseline_px, color, clip);
                px += adv;
            }
            // A selected line break shows as half a space.
            if (row.last and row.end < src.len) if (sel) |s| if (row.end >= s[0] and row.end < s[1]) {
                dl.rect(.{ .x = px, .y = ry + 1, .w = advanceOf(text, ' ') * 0.5, .h = line_h - 2 }, theme.selection());
            };
        }

        // IME composition at the caret, then the caret.
        if (e.marked.items.len > 0) {
            const w = dl.textCentered(font, caret_x, caret_y + line_h / 2, e.marked.items, theme.text);
            dl.rect(.{ .x = caret_x, .y = caret_y + line_h - 3, .w = w, .h = 1 }, theme.text_2);
            caret_x += w;
        }
        self.caret = .{ .x = caret_x, .y = caret_y + 3, .w = 2, .h = line_h - 6 };
        const caret_visible = caret_y + line_h > box.y and caret_y < box.bottom();
        if (self.editing and focused and caret_visible and (self.blink_on or ui.down)) dl.rect(self.caret, theme.accent);
        dl.popClip();

        sidebar.drawScrollbarAxis(ui, vbar, .vertical, box, self.scroll, self.content_h);
    }

    // ── rows ────────────────────────────────────────────────────────────
    /// Soft-wraps `src` into visual rows `w` points wide, breaking after a
    /// space where it can and inside a word when it must.
    fn wrap(self: *Page, text: *gfx_text.TextEngine, src: []const u8, w: f32) void {
        self.rows.clearRetainingCapacity();
        var ls: usize = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, src, ls, '\n');
            self.wrapLine(text, src, ls, nl orelse src.len, w);
            ls = (nl orelse break) + 1;
        }
    }

    fn wrapLine(self: *Page, text: *gfx_text.TextEngine, src: []const u8, ls: usize, le: usize, w: f32) void {
        var row_start = ls;
        var x: f32 = 0;
        // Right after the last space of the row so far.
        var brk: ?usize = null;
        var it = gfx_text.Utf8Iter{ .bytes = src[ls..le] };
        while (true) {
            const at = ls + it.index;
            const cp = it.next() orelse break;
            const adv = advanceOf(text, cp);
            if (x + adv > w and at > row_start) {
                const cut = brk orelse at;
                self.rows.append(self.gpa, .{ .start = @intCast(row_start), .end = @intCast(cut), .last = false }) catch return;
                row_start = cut;
                brk = null;
                x = adv;
                var rest = gfx_text.Utf8Iter{ .bytes = src[cut..at] };
                while (rest.next()) |c| x += advanceOf(text, c);
            } else x += adv;
            if (cp == ' ') brk = ls + it.index;
        }
        self.rows.append(self.gpa, .{ .start = @intCast(row_start), .end = @intCast(le), .last = true }) catch {};
    }

    /// The visual row byte `c` is on: the caret after a wrap belongs to the
    /// row that starts there, but at the end of a line it stays on that line.
    fn rowOf(self: *const Page, c: usize) usize {
        const rows = self.rows.items;
        for (rows, 0..) |row, i| {
            if (c >= row.start and (c < row.end or (c == row.end and row.last))) return i;
        }
        return rows.len -| 1;
    }

    /// Byte offset closest to the point (mx, my); the text starts at `inner`.
    fn offsetAt(self: *const Page, text: *gfx_text.TextEngine, src: []const u8, inner: Rect, mx: f32, my: f32) usize {
        const rows = self.rows.items;
        if (rows.len == 0) return 0;
        const rel_y = @max(0, my - inner.y + self.scroll);
        const r: usize = @min(rows.len - 1, @as(usize, @intFromFloat(@floor(rel_y / line_h))));
        return offsetInRow(text, src, rows[r], mx - inner.x);
    }

    /// Byte offset closest to `x` points from the start of `row`.
    fn offsetInRow(text: *gfx_text.TextEngine, src: []const u8, row: Row, x: f32) usize {
        var px: f32 = 0;
        var it = gfx_text.Utf8Iter{ .bytes = src[row.start..row.end] };
        while (true) {
            const at = row.start + it.index;
            const cp = it.next() orelse return row.end;
            const adv = advanceOf(text, cp);
            if (px + adv / 2 > x) return at;
            px += adv;
        }
    }

    /// Points from the start of `row` to byte `c` on it.
    fn xOf(text: *gfx_text.TextEngine, src: []const u8, row: Row, c: usize) f32 {
        var px: f32 = 0;
        var it = gfx_text.Utf8Iter{ .bytes = src[row.start..@min(row.end, c)] };
        while (it.next()) |cp| px += advanceOf(text, cp);
        return px;
    }

    /// ↑/↓ between visual rows, keeping the caret's x; the first row goes
    /// to the start of the text and the last to its end. False when the
    /// rows are not current, so the document's own line moves apply.
    fn moveRow(self: *Page, cmd: EditCommand) bool {
        const text = self.text orelse return false;
        const doc = &self.prompt;
        if (self.rows_placeholder or self.wrap_revision != doc.revision or self.rows.items.len == 0) return false;
        const rows = self.rows.items;
        const e = &doc.editor;
        const src = doc.bytes();
        const up = cmd == .move_up or cmd == .select_up;
        const extend = cmd == .select_up or cmd == .select_down;
        const r = self.rowOf(e.cursor);
        if (up and r == 0) {
            e.setCursor(0, extend);
            return true;
        }
        if (!up and r + 1 == rows.len) {
            e.setCursor(src.len, extend);
            return true;
        }
        const x = xOf(text, src, rows[r], e.cursor);
        const target = if (up) r - 1 else r + 1;
        e.setCursor(offsetInRow(text, src, rows[target], x), extend);
        return true;
    }
};

/// A pick-one row: a ring with a dot when selected, the label, and a dim
/// detail at the right. True when clicked.
fn radioRow(ui: *Ui, wid: u64, card: Rect, y: f32, label: []const u8, detail: []const u8, selected: bool, enabled: bool) bool {
    const dl = ui.dl;
    const r: Rect = .{ .x = card.x + 8, .y = y, .w = card.w - 16, .h = row_h };
    const st = if (enabled) ui.button(wid, r) else ui_mod.ButtonState{};
    ui.feedback(r, 6, st);
    const cy = r.centerY();
    const ring: Rect = .{ .x = r.x + 10, .y = cy - 8, .w = 16, .h = 16 };
    dl.border(ring, 8, 1.5, if (selected) theme.accent else theme.line_strong);
    if (selected) dl.circle(ring.x + 8, cy, 4, theme.accent);
    const detail_w = if (detail.len > 0) dl.textRight(theme.font_hint, r.right() - 12, cy, detail, theme.text_3) else 0;
    _ = dl.textEllipsis(font, r.x + 38, cy, label, r.w - 38 - detail_w - 24, if (enabled) theme.text else theme.text_3);
    return st.clicked;
}

fn findAgent(agents: []const config.Agent, name: []const u8) ?usize {
    for (agents, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, name)) return i;
    }
    return null;
}

/// Width of a code point in the prompt's font; a tab is four spaces.
fn advanceOf(text: *gfx_text.TextEngine, cp: u21) f32 {
    if (cp == '\t') return text.advance(font, ' ') * 4;
    return text.advance(font, cp);
}

/// How far a drag past an edge (`lo`..`hi`) pulls the view per frame:
/// gently near the edge, faster further out.
fn edgePull(pos: f32, lo: f32, hi: f32) f32 {
    if (pos < lo) return -@min(48, 3 + (lo - pos) * 0.2);
    if (pos > hi) return @min(48, 3 + (pos - hi) * 0.2);
    return 0;
}

//! Floating command palette, from the "Command palette" artboard: a query row
//! with a caret, scope chips, grouped fuzzy-matched rows and a keyboard
//! footer, drawn over a dimmed window. The rows are real: app commands, the
//! open tabs, the shell history and the accent setting.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const gfx_text = @import("../gfx/text.zig");
const tab_mod = @import("../tabs/tab.zig");
const Editor = @import("../input/editor.zig").Editor;
const History = @import("../input/history.zig").History;
const EditCommand = @import("../events.zig").EditCommand;
const Action = @import("../app.zig").Action;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

/// What the user picked; the app carries it out.
pub const Pick = union(enum) {
    action: Action,
    select_tab: usize,
    /// Index into `History.entries`; run in the active terminal.
    run_history: usize,
    /// Index into `theme.accent_options`.
    set_accent: usize,
};

/// Where the rows come from. Held while the palette is open.
pub const Sources = struct {
    tabs: *tab_mod.TabManager,
    history: *const History,
};

pub const Scope = enum(u8) {
    everything,
    commands,
    tabs,
    history,
    settings,

    /// Typing this character first narrows the query to the scope.
    fn prefix(s: Scope) u8 {
        return switch (s) {
            .everything => 0,
            .commands => '>',
            .tabs => '@',
            .history => '!',
            .settings => ':',
        };
    }

    fn label(s: Scope) []const u8 {
        return switch (s) {
            .everything => "Everything",
            .commands => "Commands",
            .tabs => "Tabs",
            .history => "History",
            .settings => "Settings",
        };
    }

    fn fromPrefix(c: u8) ?Scope {
        inline for (std.meta.tags(Scope)) |s| {
            if (s.prefix() != 0 and s.prefix() == c) return s;
        }
        return null;
    }
};

const Group = enum { commands, tabs, history, settings };

fn groupTitle(g: Group) []const u8 {
    return switch (g) {
        .commands => "COMMANDS",
        .tabs => "TABS",
        .history => "HISTORY",
        .settings => "SETTINGS",
    };
}

const Entry = struct {
    group: Group,
    /// Dimmed lead-in ("Shell:", "Go to").
    prefix: []const u8 = "",
    /// The matched text.
    label: []const u8,
    /// Right-aligned note; a keyboard shortcut when `kbd`.
    detail: []const u8 = "",
    kbd: bool = true,
    mono: bool = false,
    dot: ?Color = null,
    pick: Pick,
    score: i32 = 0,
    /// Code point indices of `label` that matched the query (first 64).
    mask: u64 = 0,
};

const Command = struct { prefix: []const u8, label: []const u8, kbd: []const u8, action: Action };

const commands = [_]Command{
    .{ .prefix = "Shell:", .label = "New terminal tab", .kbd = "⌘T", .action = .new_tab },
    .{ .prefix = "Shell:", .label = "New website tab", .kbd = "⌘⇧N", .action = .new_web_tab },
    .{ .prefix = "Shell:", .label = "Close tab", .kbd = "⌘W", .action = .close_tab },
    .{ .prefix = "Shell:", .label = "Clear blocks", .kbd = "⌃L", .action = .clear },
    .{ .prefix = "View:", .label = "Toggle sidebar", .kbd = "⌘B", .action = .toggle_sidebar },
    .{ .prefix = "View:", .label = "Next tab", .kbd = "⌘⇧]", .action = .next_tab },
    .{ .prefix = "View:", .label = "Previous tab", .kbd = "⌘⇧[", .action = .prev_tab },
    .{ .prefix = "View:", .label = "Split right", .kbd = "⌘D", .action = .split_right },
    .{ .prefix = "View:", .label = "Split down", .kbd = "⌘⇧D", .action = .split_down },
    .{ .prefix = "View:", .label = "Focus next pane", .kbd = "⌘]", .action = .next_pane },
    .{ .prefix = "View:", .label = "Focus previous pane", .kbd = "⌘[", .action = .prev_pane },
    .{ .prefix = "File:", .label = "Save", .kbd = "⌘S", .action = .save },
    .{ .prefix = "Edit:", .label = "Undo", .kbd = "⌘Z", .action = .undo },
    .{ .prefix = "Edit:", .label = "Redo", .kbd = "⌘⇧Z", .action = .redo },
    .{ .prefix = "View:", .label = "Markdown: switch preview / source", .kbd = "⌘E", .action = .toggle_view },
    .{ .prefix = "Settings:", .label = "Open settings", .kbd = "⌘,", .action = .open_settings },
    .{ .prefix = "Page:", .label = "Open location", .kbd = "⌘L", .action = .open_location },
    .{ .prefix = "Page:", .label = "Reload page", .kbd = "⌘R", .action = .web_reload },
    .{ .prefix = "Page:", .label = "Back", .kbd = "⌘⌥←", .action = .web_back },
    .{ .prefix = "Page:", .label = "Forward", .kbd = "⌘⌥→", .action = .web_forward },
};

const accent_names = [_][]const u8{ "Amber", "Peach", "Lime", "Rose" };

const max_entries = 64;
const max_tabs = 16;

const header_h: f32 = 52;
const chips_h: f32 = 44;
const footer_h: f32 = 34;
const row_h: f32 = 36;
const group_h_first: f32 = 28;
const group_h: f32 = 32;
const list_pad_top: f32 = 6;
const list_pad_bottom: f32 = 8;
const list_pad_x: f32 = 8;

pub const Palette = struct {
    gpa: std.mem.Allocator,
    open: bool = false,
    editor: Editor,
    scope: Scope = .everything,
    selected: usize = 0,
    /// Vertical scroll of the row list, in points.
    scroll: f32 = 0,
    src: ?Sources = null,

    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    title_bufs: [max_tabs][96]u8 = undefined,

    seen_version: u64 = 0,
    blink_t0: f64 = 0,
    blink_on: bool = true,
    caret: Rect = .{},
    panel: Rect = .{},

    pub fn init(gpa: std.mem.Allocator) Palette {
        return .{ .gpa = gpa, .editor = Editor.init(gpa) };
    }

    pub fn deinit(self: *Palette) void {
        self.editor.deinit();
    }

    pub fn show(self: *Palette, src: Sources) void {
        self.open = true;
        self.src = src;
        self.editor.clear();
        self.scope = .everything;
        self.selected = 0;
        self.scroll = 0;
        self.rebuild();
    }

    pub fn close(self: *Palette) void {
        self.open = false;
        self.src = null;
        self.count = 0;
    }

    pub fn toggle(self: *Palette, src: Sources) void {
        if (self.open) self.close() else self.show(src);
    }

    // ── per-tick ────────────────────────────────────────────────────────
    /// Caret blink; true when a redraw is needed.
    pub fn tick(self: *Palette, now: f64) bool {
        if (!self.open) return false;
        if (self.editor.version != self.seen_version) {
            self.seen_version = self.editor.version;
            self.blink_t0 = now;
        }
        const on = @mod(now - self.blink_t0, 1.06) < 0.53;
        if (on != self.blink_on) {
            self.blink_on = on;
            return true;
        }
        return false;
    }

    // ── query / scope ───────────────────────────────────────────────────
    /// The scope the rows follow: a typed prefix wins over the chip.
    fn effectiveScope(self: *const Palette) Scope {
        const t = self.editor.bytes();
        if (t.len > 0) {
            if (Scope.fromPrefix(t[0])) |s| return s;
        }
        return self.scope;
    }

    /// The query text without its scope prefix.
    fn query(self: *const Palette) []const u8 {
        var t = self.editor.bytes();
        if (t.len > 0 and Scope.fromPrefix(t[0]) != null) t = t[1..];
        return std.mem.trim(u8, t, " ");
    }

    fn setScope(self: *Palette, s: Scope) void {
        // A typed prefix would override the chip: drop it.
        const t = self.editor.bytes();
        if (t.len > 0 and Scope.fromPrefix(t[0]) != null) {
            var buf: [512]u8 = undefined;
            const n = @min(buf.len, t.len - 1);
            @memcpy(buf[0..n], t[1 .. 1 + n]);
            self.editor.setText(buf[0..n]);
        }
        self.scope = s;
        self.selected = 0;
        self.scroll = 0;
        self.rebuild();
    }

    fn cycleScope(self: *Palette, delta: i32) void {
        const n: i32 = @intCast(std.meta.tags(Scope).len);
        const cur: i32 = @intFromEnum(self.effectiveScope());
        self.setScope(@enumFromInt(@as(u8, @intCast(@mod(cur + delta, n)))));
    }

    // ── input ───────────────────────────────────────────────────────────
    pub fn onText(self: *Palette, utf8: []const u8) void {
        self.editor.insert(utf8);
        self.selected = 0;
        self.scroll = 0;
        self.rebuild();
    }

    pub fn onMarkedText(self: *Palette, utf8: []const u8) void {
        self.editor.setMarked(utf8);
    }

    pub fn onPaste(self: *Palette, utf8: []const u8) void {
        // One line only.
        const end = std.mem.indexOfAny(u8, utf8, "\r\n") orelse utf8.len;
        self.onText(utf8[0..end]);
    }

    /// Returns a pick to carry out, if any. `Escape` closes the palette.
    pub fn onEdit(self: *Palette, cmd: EditCommand) ?Pick {
        switch (cmd) {
            .cancel => self.close(),
            .insert_newline, .insert_line_break => {
                self.rebuild();
                if (self.selected < self.count) return self.entries[self.selected].pick;
            },
            .insert_tab => self.cycleScope(1),
            .insert_backtab => self.cycleScope(-1),
            .move_up, .select_up => self.moveSelection(-1),
            .move_down, .select_down => self.moveSelection(1),
            .page_up, .scroll_to_top, .move_doc_start => self.selected = 0,
            .page_down, .scroll_to_bottom, .move_doc_end => self.selected = if (self.count > 0) self.count - 1 else 0,
            else => {
                const before = self.editor.version;
                _ = self.editor.apply(cmd);
                if (self.editor.version != before) {
                    self.selected = 0;
                    self.scroll = 0;
                    self.rebuild();
                }
            },
        }
        return null;
    }

    pub fn onCtrl(self: *Palette, key: u8) ?Pick {
        return switch (key) {
            'n' => self.onEdit(.move_down),
            'p' => self.onEdit(.move_up),
            'a' => self.onEdit(.move_line_start),
            'e' => self.onEdit(.move_line_end),
            'u' => self.onEdit(.delete_to_line_start),
            'k' => self.onEdit(.delete_to_line_end),
            'w' => self.onEdit(.delete_word_backward),
            'c', 'g' => self.onEdit(.cancel),
            else => null,
        };
    }

    fn moveSelection(self: *Palette, delta: i32) void {
        if (self.count == 0) return;
        const n: i32 = @intCast(self.count);
        const cur: i32 = @intCast(@min(self.selected, self.count - 1));
        self.selected = @intCast(@mod(cur + delta, n));
    }

    // ── rows ────────────────────────────────────────────────────────────
    fn rebuild(self: *Palette) void {
        self.count = 0;
        const src = self.src orelse return;
        const q = self.query();
        const scope = self.effectiveScope();

        if (scope == .everything or scope == .commands) {
            for (commands) |c| self.push(q, .{
                .group = .commands,
                .prefix = c.prefix,
                .label = c.label,
                .detail = c.kbd,
                .pick = .{ .action = c.action },
            });
        }
        if (scope == .everything or scope == .tabs) {
            // The tabs in the strip (the group on show), so the ⌘n hints hold.
            const n = @min(src.tabs.items().len, max_tabs);
            for (0..n) |i| {
                const t = src.tabs.items()[i];
                const kbd = [_][]const u8{ "⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8" };
                const dot: ?Color = switch (t.vtable.status(t.ptr)) {
                    .none => null,
                    .running => theme.teal,
                    .attention => theme.accent,
                    .failed => theme.red,
                };
                self.push(q, .{
                    .group = .tabs,
                    .prefix = "Go to",
                    .label = t.title(&self.title_bufs[i]),
                    .detail = if (i < kbd.len) kbd[i] else if (i == n - 1) "⌘9" else "",
                    .dot = dot,
                    .pick = .{ .select_tab = i },
                });
            }
        }
        if (scope == .everything or scope == .history) {
            const limit: usize = if (scope == .history) 14 else if (q.len == 0) 4 else 6;
            const before = self.count;
            var i = src.history.entries.items.len;
            while (i > 0 and self.count - before < limit) {
                i -= 1;
                self.pushWith(q, .substring, .{
                    .group = .history,
                    .label = src.history.entries.items[i],
                    .detail = "↵ run",
                    .mono = true,
                    .pick = .{ .run_history = i },
                });
            }
        }
        if (scope == .everything or scope == .settings) {
            for (theme.accent_options, 0..) |c, i| {
                const current = std.meta.eql(c, theme.accent);
                self.push(q, .{
                    .group = .settings,
                    .prefix = "Accent colour ›",
                    .label = accent_names[i],
                    .detail = if (current) "current" else "",
                    .kbd = false,
                    .dot = c,
                    .pick = .{ .set_accent = i },
                });
            }
        }

        // Best matches first within each group (stable, so ties keep their order).
        if (q.len > 0) {
            var i: usize = 1;
            while (i < self.count) : (i += 1) {
                var j = i;
                while (j > 0 and self.entries[j - 1].group == self.entries[j].group and self.entries[j - 1].score < self.entries[j].score) : (j -= 1) {
                    std.mem.swap(Entry, &self.entries[j - 1], &self.entries[j]);
                }
            }
        }
        if (self.count == 0) self.selected = 0 else self.selected = @min(self.selected, self.count - 1);
    }

    const Match = enum { fuzzy, substring };

    fn push(self: *Palette, q: []const u8, entry: Entry) void {
        self.pushWith(q, .fuzzy, entry);
    }

    fn pushWith(self: *Palette, q: []const u8, mode: Match, entry: Entry) void {
        if (self.count >= max_entries) return;
        var e = entry;
        if (q.len > 0) {
            const matched: ?i32 = switch (mode) {
                .fuzzy => fuzzy(q, e.label, &e.mask),
                .substring => substring(q, e.label, &e.mask),
            };
            if (matched) |s| {
                e.score = s;
            } else if (e.prefix.len > 0 and fuzzy(q, e.prefix, &e.mask) != null) {
                e.mask = 0;
                e.score = -8;
            } else return;
        }
        self.entries[self.count] = e;
        self.count += 1;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws the scrim and the panel over the whole window. Returns a pick
    /// when a row was clicked.
    pub fn draw(self: *Palette, ui: *Ui, width: f32, height: f32) ?Pick {
        if (!self.open) return null;
        const dl = ui.dl;
        var pick: ?Pick = null;
        const window: Rect = .{ .x = 0, .y = 0, .w = width, .h = height };

        // Everything under the palette is inert; a click outside closes it.
        ui.interactive.append(ui.gpa, window) catch {};
        dl.rect(window, theme.scrim);

        const pw = @min(theme.palette_w, width - 40);
        const top = @min(theme.palette_top, @max(24, height * 0.12));
        const px = @round((width - pw) / 2);

        // Layout of the row list.
        var list_h: f32 = list_pad_top + list_pad_bottom;
        var ys: [max_entries]f32 = undefined;
        {
            var y: f32 = list_pad_top;
            var last: ?Group = null;
            for (0..self.count) |i| {
                const e = &self.entries[i];
                if (last == null or last.? != e.group) {
                    y += if (last == null) group_h_first else group_h;
                    last = e.group;
                }
                ys[i] = y;
                y += row_h;
            }
            if (self.count == 0) y += row_h;
            list_h = y + list_pad_bottom;
        }
        const max_list = @max(row_h + list_pad_top + list_pad_bottom, height - top - 40 - header_h - chips_h - footer_h);
        const visible_list = @min(list_h, max_list);
        const panel: Rect = .{ .x = px, .y = top, .w = pw, .h = header_h + chips_h + visible_list + footer_h };
        self.panel = panel;

        // Keep the selection in view.
        if (self.count > 0) {
            const sel = @min(self.selected, self.count - 1);
            const sel_top = ys[sel] - list_pad_top;
            const sel_bottom = ys[sel] + row_h + list_pad_bottom;
            if (sel_top < self.scroll) self.scroll = sel_top;
            if (sel_bottom > self.scroll + visible_list) self.scroll = sel_bottom - visible_list;
        }
        self.scroll = std.math.clamp(self.scroll, 0, @max(0, list_h - visible_list));

        if (ui.pressed and !panel.contains(ui.mx, ui.my)) {
            self.close();
            return null;
        }

        // Shadow (0 24px 80px rgba(0,0,0,.55)), approximated with soft rings.
        theme.dropShadow(dl, panel, 12, 6, 6, 14, 0.075);
        dl.shape(panel, 12, theme.bg_panel, 1, theme.line_strong);
        dl.pushClip(panel.inset(1, 1));
        defer dl.popClip();

        // ── query row ──
        const scope = self.effectiveScope();
        const q_r: Rect = .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = header_h };
        dl.rect(.{ .x = q_r.x, .y = q_r.bottom() - 1, .w = q_r.w, .h = 1 }, theme.line);
        const shown = self.editor.bytes();
        // A typed prefix character is drawn as the prompt itself.
        const typed_prefix = shown.len > 0 and Scope.fromPrefix(shown[0]) != null;
        const prompt = [_]u8{if (scope.prefix() == 0) '>' else scope.prefix()};
        var x = q_r.x + 16;
        if (!typed_prefix) x += dl.textCentered(theme.font_palette_prompt, x, q_r.centerY(), &prompt, theme.accent) + 10;
        {
            // "Esc" chip at the right.
            const label = "Esc";
            const lw = ui.text.measure(theme.font_kbd, label);
            const r: Rect = .{ .x = q_r.right() - 16 - lw - 12, .y = q_r.centerY() - 10, .w = lw + 12, .h = 20 };
            const st = ui.button(Ui.id("palette.esc", 0), r);
            dl.border(r, 4, 1, theme.line_strong);
            _ = dl.textCentered(theme.font_kbd, r.x + 6, r.centerY(), label, if (st.hover) theme.text else theme.text_2);
            if (st.clicked) {
                self.close();
                return null;
            }
        }
        const text_right = q_r.right() - 16 - 40 - 12;
        const text_rect: Rect = .{ .x = x - 4, .y = q_r.y, .w = text_right - x + 4, .h = q_r.h };
        const d = ui.drag(Ui.id("palette.text", 0), text_rect);
        if (d.hover or d.dragging) ui.cursor = .ibeam;
        if (shown.len == 0 and self.editor.marked.items.len == 0) {
            _ = dl.textEllipsis(theme.font_palette, x + 5, q_r.centerY(), "Search commands, tabs, history…", text_right - x - 5, theme.text_3);
        }
        // Text with selection, then the caret.
        {
            const font = theme.font_palette;
            const scale = dl.scale;
            const clip = blk: {
                const c = dl.currentClip();
                break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
            };
            const sel = self.editor.selection();
            var pen = x * scale;
            var caret_px = pen;
            var it = gfx_text.Utf8Iter{ .bytes = shown };
            var hit_offset: ?usize = null;
            while (true) {
                const at = it.index;
                if (at == self.editor.cursor) caret_px = pen;
                const cp = it.next() orelse break;
                const is_prefix = typed_prefix and at == 0;
                const f = if (is_prefix) theme.font_palette_prompt else font;
                const adv = ui.text.advance(f, cp) * scale + (if (is_prefix) 10 * scale else 0);
                if ((d.started or d.dragging) and hit_offset == null and ui.mx * scale < pen + adv / 2) hit_offset = at;
                if (sel) |s| if (at >= s[0] and at < s[1]) {
                    dl.rect(.{ .x = pen / scale, .y = q_r.centerY() - 10, .w = adv / scale, .h = 20 }, theme.selection());
                };
                const baseline_px = @round(ui.text.baselineForCenter(f, q_r.centerY()) * scale);
                _ = dl.glyph(f, cp, pen, baseline_px, if (is_prefix) theme.accent else theme.text, clip);
                pen += adv;
            }
            if (d.started or d.dragging) {
                const off = hit_offset orelse shown.len;
                if (d.started and d.double_clicked) {
                    self.editor.selectWordAt(off);
                } else if (d.started) {
                    self.editor.setCursor(off, ui.mods.shift);
                } else if (ui.mx != ui.press_x or ui.my != ui.press_y) {
                    self.editor.setCursor(off, true);
                }
            }
            var cx = caret_px / scale;
            if (self.editor.marked.items.len > 0) {
                const w = dl.textCentered(font, cx, q_r.centerY(), self.editor.marked.items, theme.text);
                dl.rect(.{ .x = cx, .y = q_r.centerY() + 9, .w = w, .h = 1 }, theme.text_2);
                cx += w;
            }
            self.caret = .{ .x = cx + 1, .y = q_r.centerY() - 9.5, .w = 2, .h = 19 };
            if (self.blink_on or ui.down) dl.rect(self.caret, theme.accent);
        }

        // ── scope chips ──
        const c_r: Rect = .{ .x = panel.x, .y = q_r.bottom(), .w = panel.w, .h = chips_h };
        dl.rect(.{ .x = c_r.x, .y = c_r.bottom() - 1, .w = c_r.w, .h = 1 }, theme.line);
        var cx = c_r.x + 16;
        inline for (std.meta.tags(Scope), 0..) |s, si| {
            const active = s == scope;
            const has_prefix = s.prefix() != 0;
            const glyph = [_]u8{s.prefix()};
            const gw: f32 = if (has_prefix) ui.text.measure(theme.font_chip_prefix, &glyph) + 6 else 0;
            const lw = ui.text.measure(theme.font_chip, s.label());
            const r: Rect = .{ .x = cx, .y = c_r.y + 10, .w = 10 + gw + lw + 10, .h = 24 };
            const st = ui.button(Ui.id("palette.chip", si), r);
            if (active) {
                dl.rrect(r, 12, theme.chip_active);
            } else {
                if (st.hover) dl.rrect(r, 12, theme.hover);
                dl.border(r, 12, 1, theme.line);
            }
            var tx = r.x + 10;
            if (has_prefix) tx += dl.textCentered(theme.font_chip_prefix, tx, r.centerY(), &glyph, if (active) theme.accent else theme.text_3) + 6;
            _ = dl.textCentered(theme.font_chip, tx, r.centerY(), s.label(), if (active) theme.text else theme.text_2);
            if (st.clicked) self.setScope(s);
            cx += r.w + 6;
        }

        // ── rows ──
        const l_r: Rect = .{ .x = panel.x, .y = c_r.bottom(), .w = panel.w, .h = visible_list };
        const wheel = ui.takeScroll(l_r);
        if (wheel != 0) self.scroll = std.math.clamp(self.scroll - wheel, 0, @max(0, list_h - visible_list));
        dl.pushClip(l_r);
        const oy = l_r.y - self.scroll;
        if (self.count == 0) {
            _ = dl.textCentered(theme.font_row, l_r.x + list_pad_x + 10, oy + list_pad_top + row_h / 2, "No matches", theme.text_3);
        }
        var last: ?Group = null;
        for (0..self.count) |ei| {
            const e = &self.entries[ei];
            const y = oy + ys[ei];
            if (last == null or last.? != e.group) {
                const gh: f32 = if (last == null) group_h_first else group_h;
                _ = dl.textCentered(theme.font_group, l_r.x + list_pad_x + 8, y - gh + 8 + (gh - 12) / 2, groupTitle(e.group), theme.text_3);
                last = e.group;
            }
            const r: Rect = .{ .x = l_r.x + list_pad_x, .y = y, .w = l_r.w - 2 * list_pad_x, .h = row_h };
            const st = ui.button(Ui.id("palette.row", ei), r);
            const selected = ei == self.selected;
            if (selected) {
                dl.rrect(r, 8, theme.accent.alpha(0.14));
            } else if (st.hover) dl.rrect(r, 8, theme.hover);
            if (st.clicked) pick = e.pick;

            var tx = r.x + 10;
            var right = r.right() - 10;
            if (e.detail.len > 0) {
                const dfont = if (e.kbd) theme.font_kbd else theme.font_status;
                right -= dl.textRight(dfont, right, r.centerY(), e.detail, theme.text_3) + 10;
            }
            if (e.dot) |c| {
                dl.circle(tx + 3.5, r.centerY(), 3.5, c);
                tx += 7 + 10;
            }
            if (e.prefix.len > 0) tx += dl.textCentered(theme.font_row, tx, r.centerY(), e.prefix, theme.text_2) + 5;
            const lf = if (e.mono) theme.font_row_mono else theme.font_row;
            const lb = if (e.mono) theme.font_row_mono_bold else theme.font_row_bold;
            drawHighlighted(ui, lf, lb, tx, r.centerY(), e.label, e.mask, right - tx, if (selected) theme.text else theme.text);
        }
        dl.popClip();

        // ── footer ──
        const f_r: Rect = .{ .x = panel.x, .y = l_r.bottom(), .w = panel.w, .h = footer_h };
        dl.rect(f_r, theme.bg_panel_footer);
        dl.rect(.{ .x = f_r.x, .y = f_r.y, .w = f_r.w, .h = 1 }, theme.line);
        var fx = f_r.x + 16;
        const hints = [_][]const u8{ "↑↓ move", "↵ run", "Tab switch scope", "Esc close" };
        for (hints) |h| fx += dl.textCentered(theme.font_kbd, fx, f_r.centerY(), h, theme.text_3) + 16;
        const tail = "type a prefix to narrow: > @ ! :";
        if (f_r.right() - 16 - ui.text.measure(theme.font_kbd, tail) > fx) {
            _ = dl.textRight(theme.font_kbd, f_r.right() - 16, f_r.centerY(), tail, theme.text_3);
        }

        if (pick != null) self.close();
        return pick;
    }
};

/// Draws `str` with the code points flagged in `mask` in the bold face,
/// truncated with an ellipsis when wider than `max_w`.
fn drawHighlighted(ui: *Ui, font: Font, bold: Font, x: f32, center_y: f32, str: []const u8, mask: u64, max_w: f32, color: Color) void {
    const dl = ui.dl;
    if (max_w <= 0) return;
    if (mask == 0) {
        _ = dl.textEllipsis(font, x, center_y, str, max_w, color);
        return;
    }
    const scale = dl.scale;
    const clip = blk: {
        const c = dl.currentClip();
        break :blk [4]f32{ @round(c.x * scale), @round(c.y * scale), @round(c.right() * scale), @round(c.bottom() * scale) };
    };
    const ell_w = ui.text.measure(font, "…");
    var pen = x * scale;
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = str };
    while (it.next()) |cp| : (idx += 1) {
        const f = if (idx < 64 and (mask >> @intCast(idx)) & 1 == 1) bold else font;
        const baseline_px = @round(ui.text.baselineForCenter(f, center_y) * scale);
        const adv = ui.text.advance(f, cp) * scale;
        if ((pen + adv) / scale - x + ell_w > max_w and it.index < str.len) {
            _ = dl.textCentered(font, pen / scale, center_y, "…", color);
            return;
        }
        pen += dl.glyph(f, cp, pen, baseline_px, color, clip);
    }
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Case-insensitive subsequence match of `q` in `hay`. Sets the bits of the
/// matched code point indices (first 64) and returns a score, higher is
/// better: runs and word starts score, a late first hit costs.
fn fuzzy(q: []const u8, hay: []const u8, mask: *u64) ?i32 {
    mask.* = 0;
    if (q.len == 0) return 0;
    var score: i32 = 0;
    var qi: usize = 0;
    var prev_matched = false;
    var prev_byte: u8 = ' ';
    var first: ?usize = null;
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = hay };
    while (true) : (idx += 1) {
        const at = it.index;
        _ = it.next() orelse break;
        const hb = hay[at..it.index];
        const qlen = std.unicode.utf8ByteSequenceLength(q[qi]) catch 1;
        const qb = q[qi..@min(q.len, qi + qlen)];
        var eq = hb.len == qb.len;
        if (eq) for (hb, qb) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                eq = false;
                break;
            }
        };
        if (eq) {
            const word_start = idx == 0 or !isWordByte(prev_byte);
            score += if (prev_matched) 4 else if (word_start) 3 else 1;
            if (first == null) first = idx;
            if (idx < 64) mask.* |= @as(u64, 1) << @intCast(idx);
            qi += qb.len;
            prev_matched = true;
            if (qi >= q.len) break;
        } else prev_matched = false;
        prev_byte = hb[0];
    }
    if (qi < q.len) return null;
    return score - @as(i32, @intCast(@min(first.?, 20)));
}

/// Case-insensitive contiguous match, for long shell commands where a
/// subsequence match would hit almost anything. Earlier hits score higher.
fn substring(q: []const u8, hay: []const u8, mask: *u64) ?i32 {
    mask.* = 0;
    if (q.len == 0) return 0;
    const at = std.ascii.indexOfIgnoreCase(hay, q) orelse return null;
    // Byte offsets → code point indices for the highlight mask.
    var idx: usize = 0;
    var it = gfx_text.Utf8Iter{ .bytes = hay };
    while (it.index < at) : (idx += 1) _ = it.next() orelse break;
    const first = idx;
    while (it.index < at + q.len) : (idx += 1) {
        if (idx < 64) mask.* |= @as(u64, 1) << @intCast(idx);
        _ = it.next() orelse break;
    }
    return 50 - @as(i32, @intCast(@min(first, 40)));
}

// ── tests ────────────────────────────────────────────────────────────────
test "substring match is contiguous and case-insensitive" {
    var m: u64 = 0;
    try std.testing.expect(substring("STAT", "git status -sb", &m) != null);
    try std.testing.expectEqual(@as(u64, 0b1111 << 4), m);
    try std.testing.expect(substring("gs", "git status", &m) == null);
    try std.testing.expect(substring("ndú", "echo ñandú", &m) != null);
    try std.testing.expectEqual(@as(u64, 0b111 << 7), m);
}

test "fuzzy prefers word starts and runs, ignores case" {
    var m: u64 = 0;
    const a = fuzzy("nt", "New terminal tab", &m).?;
    try std.testing.expectEqual(@as(u64, 0b10001), m); // "N" and the "t" of "terminal"
    const b = fuzzy("nt", "Untangle", &m).?;
    try std.testing.expect(a > b);
    try std.testing.expect(fuzzy("xyz", "New terminal tab", &m) == null);
    try std.testing.expect(fuzzy("close tab", "Close tab", &m) != null);
    try std.testing.expect(fuzzy("ñ", "ñandú", &m) != null);
}

test "scope prefixes" {
    try std.testing.expectEqual(Scope.commands, Scope.fromPrefix('>').?);
    try std.testing.expectEqual(Scope.history, Scope.fromPrefix('!').?);
    try std.testing.expect(Scope.fromPrefix('x') == null);
}

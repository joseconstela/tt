//! The Search view of the files panel, in the idiom of VS Code's: a
//! search box with the match-case / whole-word / regex switches inside
//! it, a chevron that unfolds the Replace box, a "…" that unfolds the
//! files-to-include / files-to-exclude boxes, and the matches underneath
//! grouped by file — a match row opens the file at that spot. The search
//! runs as you type (a short pause after the last keystroke), on a thread
//! (`search.zig`). Replacements ask first: the panel hands the app a
//! question, the app shows the box and calls `replaceConfirmed`.
//!
//! The folder searched is the folder on show in the tree — except that
//! opening a match moves the tree into the file's folder, and the search
//! stays put rather than narrowing itself to it; the refresh button
//! adopts the tree's folder again.
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const field = @import("field.zig");
const sidebar = @import("sidebar.zig");
const search = @import("../search.zig");
const sys = @import("../sys.zig");
const paths = @import("../paths.zig");
const EditCommand = @import("../events.zig").EditCommand;
const Icon = @import("../gfx/icons.zig").Icon;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Color = ui_mod.Color;
const Font = ui_mod.Font;

const row_h: f32 = 26;
const pad: f32 = 12;
const small: f32 = 22;
const toggle_w: f32 = 22;
const chevron_w: f32 = 16;
/// How long after the last keystroke the search runs.
const debounce: f64 = 0.25;
const history_max = 50;
const font_toggle = Font.mono(11);
const font_badge = Font.medium(12);

/// The boxes, in the panel's own numbering of fields.
const Field = enum(u64) { none = 0, query = 1, replace = 2, include = 3, exclude = 4 };

/// A match to open: the file, the 0-based line and byte column, and how
/// long the match is (selected there).
pub const Open = struct { path: []const u8, line: u32, col: u32, len: u32 };

/// What "Replace All" needs the user to agree to (strings live in the
/// panel until the next frame).
pub const Confirm = struct { heading: []const u8, reason: []const u8 };

pub const Result = struct {
    /// A match row was clicked (valid this frame).
    open: ?Open = null,
    /// Replace All was asked for: the app shows this and confirms it back.
    confirm: ?Confirm = null,
};

pub const Panel = struct {
    gpa: std.mem.Allocator,
    query: std.ArrayList(u8) = .empty,
    replace: std.ArrayList(u8) = .empty,
    include: std.ArrayList(u8) = .empty,
    exclude: std.ArrayList(u8) = .empty,
    focus: field.Focus,
    opts: search.Options = .{},
    show_replace: bool = false,
    show_details: bool = false,
    engine: search.Searcher,
    /// The folder searched (or to be searched).
    dir: std.ArrayList(u8) = .empty,
    /// The folder is inside a git repository (the file list comes from git).
    in_repo: bool = false,
    /// Something changed: a search is due after the pause.
    touched_flag: bool = false,
    due: ?f64 = null,
    /// Earlier searches, newest first; `hist_pos` while stepping through
    /// them (↑ / ↓ in the search box), `draft` what was typed before.
    history: std.ArrayList([]u8) = .empty,
    hist_pos: ?usize = null,
    draft: std.ArrayList(u8) = .empty,
    scroll: f32 = 0,
    content_h: f32 = 0,
    /// The absolute path of the row acted on this frame.
    out_path: std.ArrayList(u8) = .empty,
    heading_buf: [160]u8 = undefined,
    reason_buf: [200]u8 = undefined,
    /// Replace All waits for its confirmation.
    pending_replace: bool = false,
    /// `activate` ran this frame: the press that brought the view up
    /// must not take the focus away again.
    just_activated: bool = false,
    /// What the last replace did, under the summary.
    note_buf: [96]u8 = undefined,
    note_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa), .engine = search.Searcher.init(gpa) };
    }

    pub fn deinit(self: *Panel) void {
        self.engine.deinit();
        self.focus.deinit();
        self.query.deinit(self.gpa);
        self.replace.deinit(self.gpa);
        self.include.deinit(self.gpa);
        self.exclude.deinit(self.gpa);
        self.dir.deinit(self.gpa);
        for (self.history.items) |h| self.gpa.free(h);
        self.history.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        self.out_path.deinit(self.gpa);
    }

    /// The folder the results are (or will be) for.
    pub fn dirPath(self: *const Panel) []const u8 {
        return self.dir.items;
    }

    /// Matches on show (the strip's badge).
    pub fn matchCount(self: *const Panel) u32 {
        return self.engine.results.match_count;
    }

    /// The tree moved to `dir`. The search follows, unless the move is
    /// into a subfolder of the folder searched (opening a match does that).
    pub fn setRoot(self: *Panel, dir: []const u8) void {
        if (std.mem.eql(u8, self.dir.items, dir)) return;
        if (self.dir.items.len > 0 and self.query.items.len > 0 and paths.isUnder(self.dir.items, dir)) return;
        self.adopt(dir);
    }

    /// Searches `dir` from now on; a search re-runs if there is one.
    fn adopt(self: *Panel, dir: []const u8) void {
        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(self.gpa, dir) catch return;
        if (self.query.items.len > 0) self.touched();
    }

    /// The view was brought up (the strip, ⌘⇧F): the search box takes
    /// the keyboard with its text selected, and an idle view adopts the
    /// tree's folder.
    pub fn activate(self: *Panel, root: []const u8, now: f64) void {
        if (self.query.items.len == 0) self.adopt(root);
        self.takeFocus(.query, now);
        self.just_activated = true;
    }

    pub fn dropFocus(self: *Panel) void {
        self.syncFields();
        self.focus.drop();
    }

    /// Background results, the caret blink and the pause after typing;
    /// true when a redraw is needed.
    pub fn tick(self: *Panel, now: f64) bool {
        var changed = self.engine.tick();
        if (self.focus.tick(now)) changed = true;
        if (self.touched_flag) {
            self.touched_flag = false;
            self.due = now + debounce;
        }
        if (self.due) |t| if (now >= t) {
            self.due = null;
            self.runNow();
            changed = true;
        };
        return changed;
    }

    fn touched(self: *Panel) void {
        self.touched_flag = true;
    }

    /// Starts the search for what the boxes say (nothing to search: the
    /// results go).
    fn runNow(self: *Panel) void {
        self.due = null;
        self.touched_flag = false;
        self.scroll = 0;
        if (self.query.items.len == 0 or self.dir.items.len == 0) {
            self.engine.clear();
            return;
        }
        self.engine.start(self.dir.items, .{
            .text = self.query.items,
            .include = self.include.items,
            .exclude = self.exclude.items,
            .opts = self.opts,
        }, self.in_repo);
    }

    // ── keyboard, routed by the app while a box has the focus ───────────
    pub fn hasFocus(self: *const Panel) bool {
        return self.focus.active();
    }

    pub fn onText(self: *Panel, utf8: []const u8) void {
        self.focus.onText(utf8);
        self.hist_pos = null;
    }

    pub fn onMarkedText(self: *Panel, utf8: []const u8) void {
        self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *Panel, utf8: []const u8) void {
        self.focus.paste(utf8);
        self.hist_pos = null;
    }

    /// ↵ searches right away (and remembers the text); ↑ / ↓ step through
    /// earlier searches; the rest edits (Esc gives the focus up).
    pub fn onEdit(self: *Panel, cmd: EditCommand) void {
        self.syncFields();
        switch (cmd) {
            .insert_newline, .insert_line_break => {
                if (self.query.items.len > 0) self.remember(self.query.items);
                self.runNow();
            },
            .move_up, .move_down => if (self.focus.id == @intFromEnum(Field.query)) {
                self.stepHistory(if (cmd == .move_up) 1 else -1);
            },
            else => _ = self.focus.onEdit(cmd),
        }
    }

    pub fn onCtrl(self: *Panel, key: u8) void {
        self.syncFields();
        _ = self.focus.onCtrl(key);
    }

    pub fn copy(self: *Panel, out: *std.ArrayList(u8), cut: bool) bool {
        return self.focus.copy(out, cut);
    }

    pub fn hasMarkedText(self: *const Panel) bool {
        return self.focus.hasMarkedText();
    }

    pub fn caretRect(self: *const Panel) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    fn fieldValue(self: *Panel, f: Field) *std.ArrayList(u8) {
        return switch (f) {
            .query, .none => &self.query,
            .replace => &self.replace,
            .include => &self.include,
            .exclude => &self.exclude,
        };
    }

    fn focused(self: *const Panel) Field {
        return std.enums.fromInt(Field, self.focus.id) orelse .none;
    }

    /// Copies the editor's text back into the box that has the focus.
    fn syncFields(self: *Panel) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        const f = self.focused();
        if (f == .none) return;
        const value = self.fieldValue(f);
        value.clearRetainingCapacity();
        value.appendSlice(self.gpa, self.focus.editor.bytes()) catch {};
        self.focus.markSynced();
        // What replaces the matches does not change which ones there are.
        if (f != .replace) self.touched();
    }

    fn takeFocus(self: *Panel, f: Field, now: f64) void {
        self.syncFields();
        self.focus.take(@intFromEnum(f), self.fieldValue(f).items, now);
    }

    /// Tab / ⇧Tab: the next / previous box on show.
    fn moveFocus(self: *Panel, dir: i8, now: f64) void {
        var order: [4]Field = undefined;
        var n: usize = 0;
        order[n] = .query;
        n += 1;
        if (self.show_replace) {
            order[n] = .replace;
            n += 1;
        }
        if (self.show_details) {
            order[n] = .include;
            n += 1;
            order[n] = .exclude;
            n += 1;
        }
        const cur = self.focused();
        var i: usize = 0;
        while (i < n and order[i] != cur) i += 1;
        const next = if (i >= n) 0 else if (dir > 0) (i + 1) % n else (i + n - 1) % n;
        self.takeFocus(order[next], now);
    }

    // ── history ─────────────────────────────────────────────────────────
    fn remember(self: *Panel, text: []const u8) void {
        for (self.history.items, 0..) |h, i| {
            if (!std.mem.eql(u8, h, text)) continue;
            const s = self.history.orderedRemove(i);
            self.history.insert(self.gpa, 0, s) catch self.gpa.free(s);
            return;
        }
        const owned = self.gpa.dupe(u8, text) catch return;
        self.history.insert(self.gpa, 0, owned) catch {
            self.gpa.free(owned);
            return;
        };
        while (self.history.items.len > history_max) self.gpa.free(self.history.pop().?);
    }

    /// ↑ (`delta` 1) goes to older searches, ↓ back towards what was typed.
    fn stepHistory(self: *Panel, delta: i32) void {
        if (self.history.items.len == 0) return;
        var text: []const u8 = undefined;
        if (self.hist_pos) |pos| {
            const np = @as(i32, @intCast(pos)) + delta;
            if (np < 0) {
                self.hist_pos = null;
                text = self.draft.items;
            } else if (np >= self.history.items.len) {
                return;
            } else {
                self.hist_pos = @intCast(np);
                text = self.history.items[@intCast(np)];
            }
        } else {
            if (delta < 0) return;
            self.draft.clearRetainingCapacity();
            self.draft.appendSlice(self.gpa, self.query.items) catch return;
            self.hist_pos = 0;
            text = self.history.items[0];
        }
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, text) catch return;
        self.focus.take(@intFromEnum(Field.query), self.query.items, self.focus.blink_t0);
        self.focus.editor.setCursor(self.query.items.len, false);
        self.touched();
    }

    // ── replacing ───────────────────────────────────────────────────────
    fn askReplaceAll(self: *Panel) Confirm {
        const r = &self.engine.results;
        self.pending_replace = true;
        const files = r.files.items.len;
        const with = self.replace.items[0..@min(self.replace.items.len, 40)];
        const heading = std.fmt.bufPrint(&self.heading_buf, "Replace {d} {s} across {d} {s} with “{s}”?", .{
            r.match_count,
            if (r.match_count == 1) "occurrence" else "occurrences",
            files,
            if (files == 1) "file" else "files",
            with,
        }) catch "Replace all matches?";
        return .{ .heading = heading, .reason = "The files are rewritten on disk. This cannot be undone." };
    }

    /// The box was accepted: every match on show is replaced (dismissed
    /// ones, and matches that moved since the search, are left alone).
    pub fn replaceConfirmed(self: *Panel) void {
        if (!self.pending_replace) return;
        self.pending_replace = false;
        var matcher = search.Matcher.init(self.gpa, self.query.items, self.opts) catch return;
        defer matcher.deinit();
        var replaced: u32 = 0;
        var files: u32 = 0;
        var failed: u32 = 0;
        for (self.engine.results.files.items) |f| {
            self.setOut(f.rel);
            const n = search.replaceInFile(self.gpa, self.out_path.items, &matcher, self.replace.items, f.matches.items) catch {
                failed += 1;
                continue;
            };
            if (n > 0) files += 1;
            replaced += n;
        }
        self.noteReplaced(replaced, files, failed);
        self.runNow();
    }

    /// Replaces one match, or every match of one file (`only` null).
    fn replaceSome(self: *Panel, fi: usize, only: ?[]const search.Match) void {
        const r = &self.engine.results;
        if (fi >= r.files.items.len) return;
        var matcher = search.Matcher.init(self.gpa, self.query.items, self.opts) catch return;
        defer matcher.deinit();
        self.setOut(r.files.items[fi].rel);
        const n = search.replaceInFile(self.gpa, self.out_path.items, &matcher, self.replace.items, only) catch {
            self.noteReplaced(0, 0, 1);
            return;
        };
        self.noteReplaced(n, if (n > 0) 1 else 0, 0);
        self.runNow();
    }

    fn noteReplaced(self: *Panel, replaced: u32, files: u32, failed: u32) void {
        const s = if (failed > 0)
            std.fmt.bufPrint(&self.note_buf, "Replaced {d} in {d} {s}; {d} could not be written.", .{ replaced, files, if (files == 1) "file" else "files", failed }) catch ""
        else
            std.fmt.bufPrint(&self.note_buf, "Replaced {d} {s} in {d} {s}.", .{ replaced, if (replaced == 1) "occurrence" else "occurrences", files, if (files == 1) "file" else "files" }) catch "";
        self.note_len = s.len;
    }

    fn clearAll(self: *Panel) void {
        self.query.clearRetainingCapacity();
        self.engine.clear();
        self.due = null;
        self.touched_flag = false;
        self.note_len = 0;
        self.hist_pos = null;
        self.scroll = 0;
        if (self.focused() == .query) self.focus.take(@intFromEnum(Field.query), "", self.focus.blink_t0);
    }

    fn setOut(self: *Panel, rel: []const u8) void {
        self.out_path.clearRetainingCapacity();
        self.out_path.appendSlice(self.gpa, self.dir.items) catch return;
        if (!std.mem.endsWith(u8, self.dir.items, "/")) self.out_path.append(self.gpa, '/') catch return;
        self.out_path.appendSlice(self.gpa, rel) catch return;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws the view in `rect` (under the panel's strip); `root` is the
    /// tree's folder (what the refresh button adopts).
    pub fn draw(self: *Panel, ui: *Ui, rect: Rect, root: []const u8) Result {
        var res: Result = .{};
        const dl = ui.dl;
        self.syncFields();
        if (self.dir.items.len == 0) self.adopt(root);

        var y = rect.y;
        const x = rect.x + pad;
        const w = rect.w - 2 * pad;
        const fx = x + chevron_w;
        const fw = @max(0, w - chevron_w);
        var in_field = false;

        // The search box, its three switches inside at the right. The
        // switches are registered before the box (so they win the press
        // over it) and drawn after it (so they sit on top).
        {
            const toggles_w = 3 * toggle_w + 2 * 2 + 8;
            const qr: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
            const switches = [_]struct { label: []const u8, on: *bool, underline: bool }{
                .{ .label = ".*", .on = &self.opts.regex, .underline = false },
                .{ .label = "ab", .on = &self.opts.whole_word, .underline = true },
                .{ .label = "Aa", .on = &self.opts.match_case, .underline = false },
            };
            var rects: [switches.len]Rect = undefined;
            var states: [switches.len]ui_mod.ButtonState = undefined;
            var tx = qr.right() - 6 - toggle_w;
            for (0..switches.len) |i| {
                rects[i] = .{ .x = tx, .y = qr.centerY() - toggle_w / 2, .w = toggle_w, .h = toggle_w };
                states[i] = ui.button(Ui.id("search.switch", i), rects[i]);
                tx -= toggle_w + 2;
            }
            const long_hint = "Search (↑↓ for history)";
            const hint: []const u8 = if (ui.text.measure(theme.font_side, long_hint) <= fw - toggles_w - 24) long_hint else "Search";
            const fr = field.draw(ui, &self.focus, @intFromEnum(Field.query), qr, self.query.items, .{ .placeholder = hint, .font = theme.font_side, .right_pad = toggles_w });
            if (fr.clicked) self.takeFocus(.query, ui.now);
            if (ui.mouseIn(qr)) in_field = true;
            for (switches, 0..) |s, i| {
                self.drawToggle(ui, rects[i], s.label, s.on.*, s.underline, states[i]);
                if (states[i].clicked) {
                    s.on.* = !s.on.*;
                    self.runNow();
                }
            }
            y += field.height;
        }

        // Replace, unfolded by the chevron; Replace All inside at the right.
        if (self.show_replace) {
            y += 6;
            const rr: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
            const br: Rect = .{ .x = rr.right() - 6 - small, .y = rr.centerY() - small / 2, .w = small, .h = small };
            const can = self.engine.results.match_count > 0 and !self.engine.busy();
            const bst: ui_mod.ButtonState = if (can) ui.button(Ui.id("search.replace_all", 0), br) else .{};
            const fr = field.draw(ui, &self.focus, @intFromEnum(Field.replace), rr, self.replace.items, .{ .placeholder = "Replace", .font = theme.font_side, .right_pad = small + 8 });
            if (fr.clicked) self.takeFocus(.replace, ui.now);
            if (ui.mouseIn(rr)) in_field = true;
            self.drawIconButton(ui, br, .replace, bst, can);
            if (bst.clicked) res.confirm = self.askReplaceAll();
            y += field.height;
        }

        // The chevron, centred on the box(es) it governs.
        {
            const cr: Rect = .{ .x = rect.x + 2, .y = rect.y, .w = pad + chevron_w - 4, .h = y - rect.y };
            const st = ui.button(Ui.id("search.chevron", 0), cr);
            const ir: Rect = .{ .x = x - 4, .y = cr.centerY() - 10, .w = 20, .h = 20 };
            ui.feedback(ir, 5, st);
            dl.icon(if (self.show_replace) .chevron_down else .chevron_right, ir.x + 3, ir.y + 3, 14, if (st.hover) theme.text else theme.text_3);
            if (st.clicked) {
                self.show_replace = !self.show_replace;
                if (!self.show_replace and self.focused() == .replace) self.dropFocus();
            }
        }

        // The "…" row: the include label shares it once the details are out.
        {
            y += 4;
            const row: Rect = .{ .x = fx, .y = y, .w = fw, .h = small };
            const dr: Rect = .{ .x = row.right() - small, .y = row.y, .w = small, .h = small };
            const st = ui.button(Ui.id("search.details", 0), dr);
            if (self.show_details) dl.rrect(dr, 6, theme.chip_active) else ui.feedback(dr, 6, st);
            dl.icon(.ellipsis, dr.x + 4, dr.y + 4, 14, if (self.show_details or st.hover) theme.text else theme.text_3);
            if (st.clicked) {
                self.show_details = !self.show_details;
                if (!self.show_details and (self.focused() == .include or self.focused() == .exclude)) self.dropFocus();
            }
            if (self.show_details) _ = dl.textEllipsis(theme.font_hint, fx, row.centerY(), "files to include", @max(0, fw - small - 8), theme.text_2);
            y += small;
        }
        if (self.show_details) {
            y += 2;
            const ir: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
            const fi = field.draw(ui, &self.focus, @intFromEnum(Field.include), ir, self.include.items, .{ .placeholder = "e.g. *.zig, src/**", .font = theme.font_side });
            if (fi.clicked) self.takeFocus(.include, ui.now);
            if (ui.mouseIn(ir)) in_field = true;
            y += field.height + 6;
            _ = dl.textEllipsis(theme.font_hint, fx, y + small / 2, "files to exclude", fw, theme.text_2);
            y += small + 2;
            const er: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
            const fe = field.draw(ui, &self.focus, @intFromEnum(Field.exclude), er, self.exclude.items, .{ .placeholder = "e.g. node_modules, *.min.js", .font = theme.font_side });
            if (fe.clicked) self.takeFocus(.exclude, ui.now);
            if (ui.mouseIn(er)) in_field = true;
            y += field.height;
        }

        // A press anywhere else gives the focus up; Tab moves it along.
        if (ui.pressed and self.focus.active() and !in_field and !self.just_activated) self.dropFocus();
        self.just_activated = false;
        if (self.focus.move != 0) {
            const dir = self.focus.move;
            self.focus.move = 0;
            self.moveFocus(dir, ui.now);
        }
        y += 8;

        // The summary, with refresh / clear / fold at the right.
        const r = &self.engine.results;
        {
            const row: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = 24 };
            var right = row.right() - pad;
            if (self.smallButton(ui, Ui.id("search.refresh", 0), &right, row, .reload, self.query.items.len > 0)) {
                self.adopt(root);
                self.runNow();
            }
            if (self.smallButton(ui, Ui.id("search.clear", 0), &right, row, .clear_all, self.query.items.len > 0 or r.files.items.len > 0)) self.clearAll();
            const any_open = blk: {
                for (r.files.items) |f| if (f.open) break :blk true;
                break :blk false;
            };
            if (self.smallButton(ui, Ui.id("search.fold", 0), &right, row, if (any_open) .collapse_all else .expand_all, r.files.items.len > 0)) {
                for (r.files.items) |*f| f.open = !any_open;
            }
            right -= 6;
            var buf: [96]u8 = undefined;
            const color = theme.text_3;
            // A pattern problem gets a line of its own under the buttons.
            const summary: []const u8 = if (self.engine.err().len > 0 or self.query.items.len == 0)
                ""
            else if (self.engine.busy() and r.files.items.len == 0)
                "Searching…"
            else if (r.match_count == 0 and !self.engine.busy())
                "No results found"
            else
                std.fmt.bufPrint(&buf, "{s}{d} {s} in {d} {s}", .{
                    if (r.truncated) "More than " else "",
                    r.match_count,
                    if (r.match_count == 1) "result" else "results",
                    r.files.items.len,
                    if (r.files.items.len == 1) "file" else "files",
                }) catch "";
            if (summary.len > 0) _ = dl.textEllipsis(theme.font_hint, x, row.centerY(), summary, @max(0, right - x), color);
            y += 24;
            if (self.engine.err().len > 0) {
                _ = dl.textEllipsis(theme.font_hint, x, y + 9, self.engine.err(), w, theme.red);
                y += 18;
            }
            // The folder, when it is not the tree's own.
            if (self.query.items.len > 0 and !std.mem.eql(u8, self.dir.items, root)) {
                var pbuf: [512]u8 = undefined;
                const shown = sys.abbreviateHome(self.dir.items, &pbuf);
                const lw = dl.textCentered(theme.font_hint, x, y + 9, "in ", theme.text_3);
                _ = dl.textEllipsis(theme.font_hint, x + lw, y + 9, shown, @max(0, w - lw), theme.text_3);
                y += 18;
            }
            if (self.note_len > 0) {
                _ = dl.textEllipsis(theme.font_hint, x, y + 9, self.note_buf[0..self.note_len], w, theme.text_3);
                y += 18;
            }
        }
        y += 2;

        // The matches, grouped by file.
        const area: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(0, rect.bottom() - y) };
        const max_scroll = @max(0, self.content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        var cy = area.y - self.scroll;
        const top = cy;
        var fi: usize = 0;
        while (fi < r.files.items.len) {
            if (self.drawFile(ui, rect, fi, &cy, &res)) fi += 1;
        }
        self.content_h = (cy - top) + 12;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);
        return res;
    }

    /// One file and, unfolded, its matches. False when the file was taken
    /// out of the list (the caller stays on the same index).
    fn drawFile(self: *Panel, ui: *Ui, panel: Rect, fi: usize, y: *f32, res: *Result) bool {
        const dl = ui.dl;
        const clip = dl.currentClip();
        const r = &self.engine.results;
        const f = &r.files.items[fi];
        const row: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
        y.* += row_h;
        var remove = false;
        var replace_file = false;
        if (row.bottom() > clip.y and row.y < clip.bottom()) {
            const hovered = ui.mouseIn(row);
            var right = row.right() - 8;
            {
                var buf: [16]u8 = undefined;
                const n = std.fmt.bufPrint(&buf, "{d}", .{f.matches.items.len}) catch "?";
                const nw = ui.text.measure(font_badge, n);
                const pill: Rect = .{ .x = right - (nw + 12), .y = row.centerY() - 9, .w = nw + 12, .h = 18 };
                dl.rrect(pill, 9, theme.chip_active);
                _ = dl.textCentered(font_badge, pill.x + 6, pill.centerY(), n, theme.text_2);
                right = pill.x - 6;
            }
            if (hovered) {
                if (self.smallButton(ui, Ui.id("search.file_dismiss", fi), &right, row, .close, true)) remove = true;
                if (self.show_replace) {
                    if (self.smallButton(ui, Ui.id("search.file_replace", fi), &right, row, .replace, !self.engine.busy())) replace_file = true;
                }
            }
            const st = ui.button(Ui.id("search.file", fi), row);
            ui.feedback(row, 6, st);
            dl.icon(if (f.open) .chevron_down else .chevron_right, row.x + 8, row.centerY() - 7, 14, theme.text_3);
            const name = sys.basename(f.rel);
            const dir = sys.dirname(f.rel);
            var lx = row.x + 28;
            const nw = dl.textEllipsis(theme.font_side, lx, row.centerY(), name, @max(0, right - lx), theme.text);
            lx += nw + 8;
            if (!std.mem.eql(u8, dir, ".") and lx < right) _ = dl.textEllipsis(theme.font_hint, lx, row.centerY(), dir, right - lx, theme.text_3);
            if (st.clicked) f.open = !f.open;
        }
        if (replace_file) {
            self.replaceSome(fi, null);
            return true;
        }
        if (remove) {
            r.removeFile(fi);
            return false;
        }
        if (!f.open) return true;

        var mi: usize = 0;
        while (mi < f.matches.items.len) {
            const m = f.matches.items[mi];
            const mrow: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
            y.* += row_h;
            if (mrow.bottom() <= clip.y or mrow.y >= clip.bottom()) {
                mi += 1;
                continue;
            }
            const key = fi * 65536 + mi;
            const hovered = ui.mouseIn(mrow);
            var right = mrow.right() - 8;
            var dismiss = false;
            var replace_one = false;
            if (hovered) {
                if (self.smallButton(ui, Ui.id("search.match_dismiss", key), &right, mrow, .close, true)) dismiss = true;
                if (self.show_replace) {
                    if (self.smallButton(ui, Ui.id("search.match_replace", key), &right, mrow, .replace, !self.engine.busy())) replace_one = true;
                }
            }
            const st = ui.button(Ui.id("search.match", key), mrow);
            ui.feedback(mrow, 6, st);
            const preview = r.preview(m);
            const lx = mrow.x + 28;
            const avail = @max(0, right - lx);
            {
                dl.pushClip(.{ .x = lx, .y = mrow.y, .w = avail, .h = mrow.h });
                defer dl.popClip();
                const pre_w = ui.text.measure(theme.font_side, preview[0..m.hl]);
                const hl_w = ui.text.measure(theme.font_side, preview[m.hl..][0..m.hl_len]);
                if (pre_w < avail) dl.rrect(.{ .x = lx + pre_w - 1, .y = mrow.centerY() - 9, .w = hl_w + 2, .h = 18 }, 3, theme.accent.alpha(0.28));
                _ = dl.textEllipsis(theme.font_side, lx, mrow.centerY(), preview, avail, theme.text_2);
            }
            if (replace_one) {
                const one = [_]search.Match{m};
                self.replaceSome(fi, &one);
                return true;
            }
            if (dismiss) {
                const last = f.matches.items.len == 1;
                r.removeMatch(fi, mi);
                if (last) return false;
                continue;
            }
            if (st.clicked) {
                self.setOut(f.rel);
                res.open = .{ .path = self.out_path.items, .line = m.line, .col = m.col, .len = m.len };
            }
            mi += 1;
        }
        return true;
    }

    /// One of the switches inside the search box ("Aa", "ab", ".*"),
    /// registered by the caller (`st`).
    fn drawToggle(_: *Panel, ui: *Ui, r: Rect, label: []const u8, on: bool, underline: bool, st: ui_mod.ButtonState) void {
        const dl = ui.dl;
        if (on) {
            dl.rrect(r, 5, theme.accent.alpha(0.18));
            dl.border(r, 5, 1, theme.accent.alpha(0.6));
        } else ui.feedback(r, 5, st);
        const lw = ui.text.measure(font_toggle, label);
        const lx = r.x + (r.w - lw) / 2;
        const color = if (on or st.hover) theme.text else theme.text_3;
        _ = dl.textCentered(font_toggle, lx, r.centerY(), label, color);
        if (underline) dl.rect(.{ .x = lx, .y = r.centerY() + 7, .w = lw, .h = 1 }, color);
    }

    /// A 22pt icon button in `r`; dim and inert when `enabled` is false.
    fn iconButton(self: *Panel, ui: *Ui, wid: u64, r: Rect, icon: Icon, enabled: bool) bool {
        const st: ui_mod.ButtonState = if (enabled) ui.button(wid, r) else .{};
        self.drawIconButton(ui, r, icon, st, enabled);
        return st.clicked;
    }

    /// The looks of `iconButton`, for one registered by the caller.
    fn drawIconButton(_: *Panel, ui: *Ui, r: Rect, icon: Icon, st: ui_mod.ButtonState, enabled: bool) void {
        var color = theme.text_3.alpha(0.5);
        if (enabled) {
            ui.feedback(r, 6, st);
            color = if (st.hover) theme.text else theme.text_3;
        }
        ui.dl.icon(icon, r.x + 4, r.y + 4, 14, color);
    }

    /// A 22pt icon button at the right end of a row; moves `right` past it.
    fn smallButton(self: *Panel, ui: *Ui, wid: u64, right: *f32, row: Rect, icon: Icon, enabled: bool) bool {
        const r: Rect = .{ .x = right.* - small, .y = row.centerY() - small / 2, .w = small, .h = small };
        right.* = r.x - 2;
        return self.iconButton(ui, wid, r, icon, enabled);
    }
};

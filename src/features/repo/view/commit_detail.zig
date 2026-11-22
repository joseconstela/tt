//! The commit on show beside the History list: its hash, subject and the
//! rest of its message, who made it and when, its parents, the names
//! pointing at it, and the files it touched with their line counts. A
//! click on a file opens it compared with the commit's parent; the three
//! buttons at the bottom check the commit out, revert it, or cherry-pick
//! it onto the branch checked out. Nothing is run here: what was asked
//! for comes out of `takeIntent`.
//!
//! Everything written in the pane can be selected and copied
//! (`select.zig`): drag across it, double-click a word, triple-click a
//! line, then ⌘C or a secondary click → Copy. The files are buttons, so
//! theirs is a menu instead: a secondary click on one offers its path.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const wrap = @import("../../../ui/wrap.zig");
const log_mod = @import("../model/log.zig");
const status = @import("../model/status.zig");
const kit = @import("kit.zig");
const select = @import("select.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const width: f32 = 312;
const pad: f32 = 16;
const file_h: f32 = 28;
const footer_h: f32 = 60;
const key_w: f32 = 62;

pub const State = struct {
    commit: ?log_mod.Commit,
    /// The message and the files below have been read for this commit.
    ready: bool,
    body: []const u8,
    date: []const u8,
    changes: ?*const log_mod.Changes,
    /// A command is running: the buttons wait.
    busy: bool,
};

pub const Intent = union(enum) {
    /// A file of the commit, by its index in `changes.files`.
    open_file: usize,
    checkout,
    revert,
    cherry_pick,
    /// A secondary click on a file: what can be copied of it, as a menu here.
    file_menu: struct { index: usize, x: f32, y: f32 },
};

pub const View = struct {
    intent: ?Intent = null,
    scroll: f32 = 0,
    content_h: f32 = 0,
    /// The pane's text, selectable.
    sel: select.Selectable,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .sel = select.Selectable.init(gpa, Ui.id("repo.detail.select", 0)) };
    }

    pub fn deinit(self: *View) void {
        self.sel.deinit();
    }

    pub fn takeIntent(self: *View) ?Intent {
        defer self.intent = null;
        return self.intent;
    }

    pub fn draw(self: *View, ui: *Ui, rect: Rect, state: State) void {
        const dl = ui.dl;
        dl.rect(rect, theme.bg_side);
        dl.rect(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, theme.line);
        const c = state.commit orelse {
            self.sel.begin(0);
            _ = dl.textEllipsis(kit.font_text, rect.x + pad, rect.y + 28, "Select a commit to see what it changed.", rect.w - 2 * pad, theme.text_3);
            return;
        };
        // A selection is of this commit as it is shown now: the rest of its
        // message arriving moves every line after it.
        const sel = &self.sel;
        sel.begin(std.hash.Wyhash.hash(@intFromBool(state.ready), c.hash));
        const x = rect.x + pad;
        const w = rect.w - 2 * pad;

        // The three actions, pinned to the bottom.
        {
            const y = rect.bottom() - footer_h + 14;
            const bw = (w - 12) / 3;
            const can = !state.busy;
            if (kit.button(ui, Ui.id("repo.detail.checkout", 0), .{ .x = x, .y = y, .w = bw, .h = 32 }, "Checkout", null, .secondary, can)) self.intent = .checkout;
            if (kit.button(ui, Ui.id("repo.detail.revert", 0), .{ .x = x + bw + 6, .y = y, .w = bw, .h = 32 }, "Revert", null, .secondary, can)) self.intent = .revert;
            if (kit.button(ui, Ui.id("repo.detail.pick", 0), .{ .x = x + 2 * (bw + 6), .y = y, .w = bw, .h = 32 }, "Cherry-pick", null, .secondary, can)) self.intent = .cherry_pick;
            dl.rect(.{ .x = rect.x, .y = rect.bottom() - footer_h, .w = rect.w, .h = 1 }, theme.line);
        }

        const area: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(0, rect.h - footer_h) };
        const max_scroll = @max(0, self.content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();
        var y = area.y + 16 - self.scroll;
        const top = y;

        // "COMMIT" and the hash on a pill.
        {
            const lw = kit.label(ui, x, y + 10, "COMMIT");
            const hw = ui.text.measure(kit.font_mono_small, c.short()) + 14;
            const pill: Rect = .{ .x = x + lw + 8, .y = y, .w = hw, .h = 20 };
            dl.shape(pill, 6, theme.chip_active, 1, theme.line);
            _ = sel.text(ui, kit.font_mono_small, pill.x + 7, pill.centerY(), c.short(), hw - 7, theme.text_2);
            y += 20 + 12;
        }
        y = sel.wrapped(ui, kit.font_title, c.subject, x, y, w, 20, theme.text, false) + 8;
        if (state.ready and state.body.len > 0) {
            y = sel.wrapped(ui, kit.font_small, state.body, x, y, w, 19, theme.text_3, true) + 12;
        } else y += 4;

        // Who, when, from what.
        {
            _ = sel.text(ui, kit.font_small, x, y + 11, "Author", key_w, theme.text_3);
            _ = sel.text(ui, kit.font_small, x + key_w, y + 11, c.author, w - key_w, theme.text);
            y += 22;
            _ = sel.text(ui, kit.font_small, x, y + 11, "Date", key_w, theme.text_3);
            _ = sel.text(ui, kit.font_small, x + key_w, y + 11, if (state.ready) state.date else "", w - key_w, theme.text);
            y += 22;
            var buf: [200]u8 = undefined;
            var n: usize = 0;
            for (c.parents, 0..) |p, i| {
                const part = std.fmt.bufPrint(buf[n..], "{s}{s}", .{ if (i > 0) " · " else "", p[0..@min(7, p.len)] }) catch break;
                n += part.len;
            }
            _ = sel.text(ui, kit.font_small, x, y + 11, "Parents", key_w, theme.text_3);
            _ = sel.text(ui, kit.font_mono, x + key_w, y + 11, if (n > 0) buf[0..n] else "none", w - key_w, if (n > 0) theme.text else theme.text_3);
            y += 22;
            if (c.refs.len > 0) {
                n = 0;
                for (c.refs, 0..) |r, i| {
                    const part = std.fmt.bufPrint(buf[n..], "{s}{s}", .{ if (i > 0) ", " else "", r.name }) catch break;
                    n += part.len;
                }
                _ = sel.text(ui, kit.font_small, x, y + 11, "Refs", key_w, theme.text_3);
                _ = sel.text(ui, kit.font_mono, x + key_w, y + 11, buf[0..n], w - key_w, theme.text);
                y += 22;
            }
            y += 12;
        }

        // The files.
        if (state.ready) {
            if (state.changes) |ch| {
                var buf: [32]u8 = undefined;
                const head = std.fmt.bufPrint(&buf, "{d} {s}", .{ ch.files.len, if (ch.files.len == 1) "FILE" else "FILES" }) catch "";
                _ = kit.label(ui, x, y + 10, head);
                _ = kit.plusMinus(ui, x + w, y + 10, ch.added, ch.removed, kit.font_mono_small);
                y += 26;
                for (ch.files, 0..) |f, i| {
                    const row: Rect = .{ .x = rect.x + 8, .y = y, .w = rect.w - 16, .h = file_h };
                    y += file_h;
                    if (row.bottom() < area.y or row.y > area.bottom()) continue;
                    if (ui.rightClicked(row)) self.intent = .{ .file_menu = .{ .index = i, .x = ui.mx, .y = ui.my } };
                    const st = ui.button(Ui.id("repo.detail.file", i), row);
                    ui.feedback(row, 6, st);
                    kit.badge(ui, x, row.centerY(), f.letter, 18);
                    var right = x + w;
                    if (f.binary) {
                        right -= dl.textRight(kit.font_mono_small, right, row.centerY(), "bin", theme.text_3);
                    } else right -= kit.plusMinus(ui, right, row.centerY(), f.added, f.removed, kit.font_mono_small);
                    // The name is what tells files apart: the folder gives way first.
                    const name = status.baseName(f.path);
                    const room = @max(0, right - 8 - (x + 26));
                    const nw = dl.textEllipsis(kit.font_mono_small, x + 26, row.centerY(), name, room, theme.text);
                    const dir = status.dirName(f.path);
                    if (!std.mem.eql(u8, dir, ".") and nw + 8 < room) _ = dl.textEllipsis(kit.font_mono_small, x + 26 + nw + 8, row.centerY(), dir, room - nw - 8, theme.text_3);
                    if (st.clicked) self.intent = .{ .open_file = i };
                }
            }
        } else {
            _ = dl.textCentered(kit.font_small, x, y + 10, "Reading…", theme.text_3);
            y += 26;
        }

        self.content_h = (y - top) + 28;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);
        // Last, so the files' buttons took their presses first.
        sel.end(ui, area);
    }
};

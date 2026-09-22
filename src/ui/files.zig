//! Files panel (right side): the directory the current shell is in, as a
//! tree. Folders unfold in place, files open in a viewer tab, and a file can
//! be pinned to a project from here. The tree re-reads its visible folders
//! every couple of seconds so `touch`, `git checkout` … show up. Inside a
//! git repository the names take git's colours (new, changed …) and a
//! Files / Git strip at the top switches to the Git view (`git_panel.zig`).
const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const sidebar = @import("sidebar.zig");
const git_panel = @import("git_panel.zig");
const sys = @import("../sys.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const row_h: f32 = 26;
const indent: f32 = 16;
const refresh_every: f64 = 2.0;

const Node = struct {
    name: []u8,
    is_dir: bool,
    expanded: bool = false,
    loaded: bool = false,
    children: std.ArrayList(Node) = .empty,
};

pub const Result = struct {
    open_file: ?[]const u8 = null,
    pin_file: ?[]const u8 = null,
    /// The Git view wants a discard confirmed (see `discardConfirmed`).
    confirm: ?git_panel.Confirm = null,
};

/// What the panel shows: the tree, or the Git view.
pub const Mode = enum { files, git };

pub const FileBrowser = struct {
    gpa: std.mem.Allocator,
    width: f32 = theme.files_default_w,
    visible: bool = true,
    root: std.ArrayList(u8) = .empty,
    children: std.ArrayList(Node) = .empty,
    scroll: f32 = 0,
    content_h: f32 = 0,
    drag_dx: f32 = 0,
    last_refresh: f64 = 0,
    /// Path of the highlighted file.
    selected: std.ArrayList(u8) = .empty,
    /// Full path of the row acted on this frame (what `Result` points at).
    out_path: std.ArrayList(u8) = .empty,
    /// Scratch: path of the row being drawn.
    path: std.ArrayList(u8) = .empty,
    mode: Mode = .files,
    git: git_panel.Panel,

    pub fn init(gpa: std.mem.Allocator) FileBrowser {
        return .{ .gpa = gpa, .git = git_panel.Panel.init(gpa) };
    }

    pub fn deinit(self: *FileBrowser) void {
        self.git.deinit();
        freeNodes(self.gpa, &self.children);
        self.root.deinit(self.gpa);
        self.selected.deinit(self.gpa);
        self.out_path.deinit(self.gpa);
        self.path.deinit(self.gpa);
    }

    pub fn currentWidth(self: *const FileBrowser) f32 {
        return if (self.visible) self.width else 0;
    }

    pub fn toggle(self: *FileBrowser) void {
        self.visible = !self.visible;
    }

    /// Points the tree at `dir` (no-op if it already is).
    pub fn setRoot(self: *FileBrowser, dir: []const u8, now: f64) void {
        if (std.mem.eql(u8, self.root.items, dir)) return;
        self.git.setDir(dir);
        self.root.clearRetainingCapacity();
        self.root.appendSlice(self.gpa, dir) catch return;
        freeNodes(self.gpa, &self.children);
        self.scroll = 0;
        self.load(dir, &self.children);
        self.last_refresh = now;
    }

    /// Re-reads the visible folders now and then, and collects git's
    /// readings. True if anything changed.
    pub fn tick(self: *FileBrowser, now: f64) bool {
        if (!self.visible or self.root.items.len == 0) return false;
        var changed = self.git.tick(now);
        if (now - self.last_refresh >= refresh_every) {
            self.last_refresh = now;
            if (self.reload(self.root.items, &self.children)) changed = true;
        }
        return changed;
    }

    // ── keyboard, routed by the app while the Git view's message field has it ──
    pub fn hasFocus(self: *const FileBrowser) bool {
        return self.visible and self.mode == .git and self.git.hasFocus();
    }

    pub fn onText(self: *FileBrowser, utf8: []const u8) void {
        self.git.onText(utf8);
    }

    pub fn onMarkedText(self: *FileBrowser, utf8: []const u8) void {
        self.git.onMarkedText(utf8);
    }

    pub fn onEdit(self: *FileBrowser, cmd: EditCommand) void {
        self.git.onEdit(cmd);
    }

    pub fn onCtrl(self: *FileBrowser, key: u8) void {
        self.git.onCtrl(key);
    }

    pub fn paste(self: *FileBrowser, utf8: []const u8) void {
        self.git.paste(utf8);
    }

    pub fn copy(self: *FileBrowser, out: *std.ArrayList(u8), cut: bool) bool {
        return self.git.copy(out, cut);
    }

    pub fn hasMarkedText(self: *const FileBrowser) bool {
        return self.git.hasMarkedText();
    }

    pub fn caretRect(self: *const FileBrowser) ui_mod.Rect {
        return self.git.caretRect();
    }

    /// The discard box was accepted.
    pub fn discardConfirmed(self: *FileBrowser) void {
        self.git.discardConfirmed();
    }

    fn load(self: *FileBrowser, dir: []const u8, out: *std.ArrayList(Node)) void {
        const Collector = struct {
            gpa: std.mem.Allocator,
            out: *std.ArrayList(Node),
            fn visit(c: *@This(), e: sys.DirEntry) void {
                const name = c.gpa.dupe(u8, e.name) catch return;
                c.out.append(c.gpa, .{ .name = name, .is_dir = e.is_dir }) catch c.gpa.free(name);
            }
        };
        var collector = Collector{ .gpa = self.gpa, .out = out };
        sys.listDir(self.gpa, dir, &collector, Collector.visit);
        std.mem.sort(Node, out.items, {}, nodeLessThan);
    }

    /// Lists `dir` again, keeping the unfolded state of folders that still exist.
    fn reload(self: *FileBrowser, dir: []const u8, children: *std.ArrayList(Node)) bool {
        var fresh: std.ArrayList(Node) = .empty;
        self.load(dir, &fresh);
        var changed = fresh.items.len != children.items.len;
        for (fresh.items, 0..) |*n, i| {
            if (!changed and (children.items[i].is_dir != n.is_dir or !std.mem.eql(u8, children.items[i].name, n.name))) changed = true;
            if (!n.is_dir) continue;
            for (children.items) |*old| {
                if (!old.is_dir or !std.mem.eql(u8, old.name, n.name)) continue;
                n.expanded = old.expanded;
                n.loaded = old.loaded;
                n.children = old.children;
                old.children = .empty;
                break;
            }
        }
        freeNodes(self.gpa, children);
        children.* = fresh;
        for (children.items) |*n| {
            if (!n.is_dir or !n.expanded) continue;
            const sub = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, n.name }) catch continue;
            defer self.gpa.free(sub);
            if (self.reload(sub, &n.children)) changed = true;
        }
        return changed;
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *FileBrowser, ui: *Ui, rect: Rect, can_pin: bool) Result {
        var res: Result = .{};
        if (!self.visible or rect.w <= 0) return res;
        const dl = ui.dl;

        // Splitter on the left edge, handled first so it wins over the rows.
        const grip: Rect = .{ .x = rect.x - 4, .y = rect.y, .w = 8, .h = rect.h };
        const d = ui.drag(Ui.id("files.split", 0), grip);
        if (d.started) self.drag_dx = ui.mx - rect.x;
        if (d.double_clicked) {
            self.width = theme.files_default_w;
        } else if (d.dragging) {
            const want = rect.right() - (ui.mx - self.drag_dx);
            if (want < 120) {
                self.visible = false;
            } else {
                self.width = std.math.clamp(want, theme.files_min_w, theme.files_max_w);
            }
        }
        if (d.hover or d.dragging) ui.cursor = .resize_lr;

        dl.rect(rect, theme.bg_side);
        dl.rect(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, theme.line);
        dl.pushClip(.{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 1, .h = rect.h });
        defer dl.popClip();

        var y = rect.y + 8;
        // Inside a repository the strip offers the Git view; elsewhere there is only the tree.
        const is_repo = self.git.isRepoFor(self.root.items);
        if (!is_repo) self.mode = .files;
        if (is_repo) self.drawModeStrip(ui, rect, &y);
        if (self.mode == .git) {
            const area: Rect = .{ .x = rect.x + 1, .y = y, .w = rect.w - 1, .h = @max(0, rect.bottom() - y) };
            const gr = self.git.draw(ui, area);
            res.open_file = gr.open_file;
            res.confirm = gr.confirm;
            if (d.hover or d.dragging) {
                dl.rect(.{ .x = rect.x, .y = rect.y, .w = 2, .h = rect.h }, theme.accent.alpha(if (d.dragging) 0.9 else 0.55));
            }
            return res;
        }

        // Header: the folder being shown.
        {
            var buf: [512]u8 = undefined;
            const shown = sys.abbreviateHome(self.root.items, &buf);
            _ = dl.textEllipsis(theme.font_side, rect.x + 16, y + 14, shown, rect.w - 32, theme.text_3);
            y += 28 + 4;
        }

        const area: Rect = .{ .x = rect.x + 1, .y = y, .w = rect.w - 1, .h = @max(0, rect.bottom() - y) };
        const max_scroll = @max(0, self.content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, self.root.items) catch {};
        var cy = area.y - self.scroll;
        const top = cy;
        self.drawNodes(ui, rect, &self.children, 0, &cy, can_pin, &res);
        self.content_h = (cy - top) + 12;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);

        if (d.hover or d.dragging) {
            dl.rect(.{ .x = rect.x, .y = rect.y, .w = 2, .h = rect.h }, theme.accent.alpha(if (d.dragging) 0.9 else 0.55));
        }
        return res;
    }

    /// The Files / Git strip (the screenshot's pills): Git carries the
    /// number of changes.
    fn drawModeStrip(self: *FileBrowser, ui: *Ui, rect: Rect, y: *f32) void {
        const dl = ui.dl;
        const strip_h: f32 = 28;
        var x = rect.x + 10;
        const modes = [_]struct { mode: Mode, label: []const u8 }{ .{ .mode = .files, .label = "Files" }, .{ .mode = .git, .label = "Git" } };
        for (modes, 0..) |m, i| {
            var count_buf: [16]u8 = undefined;
            const count: []const u8 = if (m.mode == .git and self.git.changeCount() > 0)
                std.fmt.bufPrint(&count_buf, "{d}", .{self.git.changeCount()}) catch ""
            else
                "";
            const lw = ui.text.measure(theme.font_side_medium, m.label);
            const cw: f32 = if (count.len > 0) ui.text.measure(git_panel.font_badge, count) + 14 else 0;
            const r: Rect = .{ .x = x, .y = y.*, .w = lw + 24 + cw, .h = strip_h };
            const st = ui.button(Ui.id("files.mode", i), r);
            const selected = self.mode == m.mode;
            if (selected) dl.rrect(r, 7, theme.chip_active) else ui.feedback(r, 7, st);
            const color = if (selected) theme.text else if (st.hover) theme.text_2 else theme.text_3;
            _ = dl.textCentered(theme.font_side_medium, r.x + 12, r.centerY(), m.label, color);
            if (count.len > 0) {
                const pill: Rect = .{ .x = r.x + 12 + lw + 6, .y = r.centerY() - 8, .w = cw - 6, .h = 16 };
                dl.rrect(pill, 8, if (selected) theme.accent else theme.accent.alpha(0.55));
                _ = dl.textCentered(git_panel.font_badge, pill.x + 4, pill.centerY(), count, theme.on_accent);
            }
            if (st.clicked) self.mode = m.mode;
            x += r.w + 4;
        }
        y.* += strip_h + 6;
    }

    fn drawNodes(self: *FileBrowser, ui: *Ui, panel: Rect, nodes: *std.ArrayList(Node), depth: u32, y: *f32, can_pin: bool, res: *Result) void {
        const dl = ui.dl;
        const clip = dl.currentClip();
        for (nodes.items) |*n| {
            // `self.path` holds the parent's path; extend it for this row.
            const parent_len = self.path.items.len;
            self.path.append(self.gpa, '/') catch return;
            self.path.appendSlice(self.gpa, n.name) catch return;
            defer self.path.items.len = parent_len;

            const row: Rect = .{ .x = panel.x + 6, .y = y.*, .w = panel.w - 12, .h = row_h };
            y.* += row_h;
            if (row.bottom() > clip.y and row.y < clip.bottom()) {
                const key: usize = @truncate(std.hash.Wyhash.hash(0, self.path.items));
                const hovered = ui.mouseIn(row);
                var right = row.right() - 8;

                // "+" pins the file to a project; registered before the row so it wins the click.
                var pin_st: ui_mod.ButtonState = .{};
                if (hovered and can_pin and !n.is_dir) {
                    const pr: Rect = .{ .x = row.right() - 6 - 22, .y = row.centerY() - 11, .w = 22, .h = 22 };
                    pin_st = ui.button(Ui.id("files.pin", key), pr);
                    ui.feedback(pr, 6, pin_st);
                    dl.icon(.plus, pr.x + 5, pr.y + 5, 12, if (pin_st.hover) theme.text else theme.text_3);
                    right = pr.x - 4;
                }
                const st = ui.button(Ui.id("files.row", key), row);
                const selected = !n.is_dir and std.mem.eql(u8, self.selected.items, self.path.items);
                if (selected) dl.rrect(row, 6, theme.accent.alpha(0.14)) else ui.feedback(row, 6, st);

                const x = row.x + 10 + @as(f32, @floatFromInt(depth)) * indent;
                if (n.is_dir) dl.icon(if (n.expanded) .chevron_down else .chevron_right, x - 2, row.centerY() - 7, 14, theme.text_3);
                const lx = x + 18;
                // Git's colours: new, changed, ignored …; files also get the letter.
                const kind = self.git.repo.snapshot.kindOfPath(self.path.items, n.is_dir);
                var color = if (n.is_dir or selected) theme.text else theme.text_2;
                if (kind == .ignored) {
                    color = theme.text_3;
                } else if (kind != .none) {
                    color = git_panel.kindColor(kind);
                    if (!n.is_dir) right -= dl.textRight(git_panel.font_badge, right, row.centerY(), git_panel.kindLetter(kind), color) + 6;
                }
                _ = dl.textEllipsis(theme.font_side, lx, row.centerY(), n.name, right - lx, color);

                if (pin_st.clicked) {
                    self.setOut(self.path.items);
                    res.pin_file = self.out_path.items;
                } else if (st.clicked) {
                    if (n.is_dir) {
                        n.expanded = !n.expanded;
                        if (n.expanded and !n.loaded) {
                            n.loaded = true;
                            self.load(self.path.items, &n.children);
                        }
                    } else {
                        self.selected.clearRetainingCapacity();
                        self.selected.appendSlice(self.gpa, self.path.items) catch {};
                        self.setOut(self.path.items);
                        res.open_file = self.out_path.items;
                    }
                }
            }
            if (n.is_dir and n.expanded) self.drawNodes(ui, panel, &n.children, depth + 1, y, can_pin, res);
        }
    }

    fn setOut(self: *FileBrowser, path: []const u8) void {
        self.out_path.clearRetainingCapacity();
        self.out_path.appendSlice(self.gpa, path) catch {};
    }
};

fn freeNodes(gpa: std.mem.Allocator, list: *std.ArrayList(Node)) void {
    for (list.items) |*n| {
        freeNodes(gpa, &n.children);
        gpa.free(n.name);
    }
    list.deinit(gpa);
    list.* = .empty;
}

/// Folders first, then case-insensitive by name (so dotfiles lead).
fn nodeLessThan(_: void, a: Node, b: Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const n = @min(a.name.len, b.name.len);
    for (a.name[0..n], b.name[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.name.len < b.name.len;
}

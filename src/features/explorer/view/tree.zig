//! The files tree, drawn: the folder on show as a header, then a row per
//! entry — an icon (a folder open or closed, a file by what it holds,
//! `icon.zig`) and the name, in git's colour where the repository has
//! something to say (new, changed, ignored …; files also get the letter).
//! There are no disclosure arrows: an unfolded folder shows it by its
//! open icon and by a vertical line that runs under it past everything
//! it holds, one line per open level.
//!
//! This file only draws and keeps what the view itself remembers (the
//! scroll). It is shown the tree (`State`) and runs nothing: a click, a
//! right-click, a drag or a drop comes out as one `Intent`, which
//! `entry/tree.zig` serves (folding a folder lists it) or hands on to the
//! app (opening, pinning, the menu, the drag).
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const sidebar = @import("../../../ui/sidebar.zig");
const paths = @import("../../../paths.zig");
const repo = @import("../../repo/repo.zig");
const FileKind = @import("../../../ui/overlay.zig").FileKind;
const model = @import("../model/tree.zig");
const icon = @import("icon.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Node = model.Node;

const row_h: f32 = 26;
const header_h: f32 = 28;
/// How far a level sits to the right of the one holding it: enough for
/// the level's line, under the folder's icon, to clear the icons below.
const indent: f32 = 20;
const icon_size: f32 = 16;
/// From a row's left edge to its icon at the top level, and from the
/// icon to the name.
const icon_inset: f32 = 8;
const icon_gap: f32 = 8;
/// Moving this far (points) from the press turns a click into a drag.
const drag_threshold: f32 = 5;

/// A secondary click: what was clicked, and where the menu should open.
pub const Menu = struct { kind: FileKind, path: []const u8, x: f32, y: f32 };

/// What the user asked for this frame. Paths are absolute and valid
/// until the next draw.
pub const Intent = union(enum) {
    none,
    /// A file was clicked.
    open: []const u8,
    /// A file's "+" was clicked: pin it to a project.
    pin: []const u8,
    /// A folder was clicked: fold or unfold it.
    toggle: []const u8,
    /// A press on a row travelled: the drag of this path starts.
    drag: []const u8,
    /// The dragged path was let go over this folder.
    drop: []const u8,
    /// A right-click on a row, the header or the blank space.
    menu: Menu,
};

/// What a frame is drawn from.
pub const State = struct {
    /// The folder on show, absolute.
    root: []const u8,
    /// The same as the header spells it ("~/git/tt").
    title: []const u8,
    nodes: []const Node,
    /// Path of the highlighted file ("" for none).
    selected: []const u8,
    /// Where the rows' colours come from.
    git: *const repo.Panel,
    /// Whether files offer the "+" that pins them.
    can_pin: bool,
    /// The path being dragged from here, if any: folders under the
    /// pointer offer to take it, and rows do not click meanwhile.
    drag: ?[]const u8,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    scroll: f32 = 0,
    content_h: f32 = 0,
    /// Scratch: path of the row being drawn.
    path: std.ArrayList(u8) = .empty,
    /// The path this frame's intent is about.
    out: std.ArrayList(u8) = .empty,
    intent: Intent = .none,
    row_took_drop: bool = false,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        self.path.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    /// Back to the top (another folder is on show).
    pub fn reset(self: *View) void {
        self.scroll = 0;
    }

    pub fn draw(self: *View, ui: *Ui, rect: Rect, state: State) Intent {
        const dl = ui.dl;
        self.intent = .none;
        self.row_took_drop = false;
        var y = rect.y;

        // Header: the folder being shown. Its menu is the folder's own.
        {
            _ = dl.textEllipsis(theme.font_side, rect.x + 15, y + 14, state.title, rect.w - 31, theme.text_3);
            const header: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = header_h };
            if (ui.rightClicked(header)) self.say(.menu, state.root, .root, ui);
            y += header_h + 4;
        }

        const area: Rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(0, rect.bottom() - y) };
        const max_scroll = @max(0, self.content_h - area.h);
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(area), 0, max_scroll);
        dl.pushClip(area);
        defer dl.popClip();

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, std.mem.trimEnd(u8, state.root, "/")) catch {};
        var cy = area.y - self.scroll;
        const top = cy;
        self.drawNodes(ui, area, state, state.nodes, 0, &cy);
        self.content_h = (cy - top) + 12;
        if (max_scroll > 0) sidebar.drawScrollbar(ui, area, self.scroll, self.content_h);

        // The blank space below the rows stands for the folder on show:
        // its menu, and a dragged path let go there moves to it.
        if (ui.rightClicked(area)) self.say(.menu, state.root, .root, ui);
        if (state.drag) |src| if (!self.row_took_drop and ui.mouseIn(area) and dropAllowed(src, state.root)) {
            dl.border(area.inset(2, 2), 6, 1, theme.accent.alpha(0.6));
            if (ui.released) self.say(.drop, state.root, .root, ui);
        };
        return self.intent;
    }

    fn drawNodes(self: *View, ui: *Ui, area: Rect, state: State, nodes: []const Node, depth: u32, y: *f32) void {
        const dl = ui.dl;
        const clip = dl.currentClip();
        for (nodes) |*n| {
            // `self.path` holds the parent's path; extend it for this row.
            const parent_len = self.path.items.len;
            self.path.append(self.gpa, '/') catch return;
            self.path.appendSlice(self.gpa, n.name) catch return;
            defer self.path.items.len = parent_len;

            const row: Rect = .{ .x = area.x + 5, .y = y.*, .w = area.w - 11, .h = row_h };
            const icon_x = row.x + icon_inset + @as(f32, @floatFromInt(depth)) * indent;
            y.* += row_h;
            if (row.bottom() > clip.y and row.y < clip.bottom()) {
                const key: usize = @truncate(std.hash.Wyhash.hash(0, self.path.items));
                const hovered = ui.mouseIn(row);
                var right = row.right() - 8;

                // "+" pins the file to a project; registered before the row so it wins the click.
                var pin_st: ui_mod.ButtonState = .{};
                if (hovered and state.can_pin and !n.is_dir and state.drag == null) {
                    const pr: Rect = .{ .x = row.right() - 6 - 22, .y = row.centerY() - 11, .w = 22, .h = 22 };
                    pin_st = ui.button(Ui.id("files.pin", key), pr);
                    ui.feedback(pr, 6, pin_st);
                    dl.icon(.plus, pr.x + 5, pr.y + 5, 12, if (pin_st.hover) theme.text else theme.text_3);
                    right = pr.x - 4;
                }
                const st = ui.button(Ui.id("files.row", key), row);
                if (ui.rightClicked(row)) self.say(.menu, self.path.items, if (n.is_dir) .folder else .file, ui);
                const selected = !n.is_dir and std.mem.eql(u8, state.selected, self.path.items);
                if (selected) dl.rrect(row, 6, theme.accent.alpha(0.14)) else ui.feedback(row, 6, st);

                // A press that travels takes the path along (the app runs
                // the drag from here: the ghost, the sidebar, the panes).
                if (state.drag == null and st.held) {
                    const dx = ui.mx - ui.press_x;
                    const dy = ui.my - ui.press_y;
                    if (dx * dx + dy * dy >= drag_threshold * drag_threshold) self.say(.drag, self.path.items, .file, ui);
                }
                // While a path is dragged, the row under the pointer stands
                // for a folder — itself, or the one holding the file.
                if (state.drag) |src| if (hovered) {
                    self.row_took_drop = true;
                    const dir = if (n.is_dir) self.path.items else if (parent_len == 0) "/" else self.path.items[0..parent_len];
                    if (dropAllowed(src, dir)) {
                        dl.rrect(row, 6, theme.accent.alpha(0.12));
                        dl.border(row, 6, 1, theme.accent.alpha(0.7));
                        if (ui.released) self.say(.drop, dir, .folder, ui);
                    }
                };

                // Git's colours: new, changed, ignored …; files also get the letter.
                const kind = state.git.kindOfPath(self.path.items, n.is_dir);
                var color = if (n.is_dir or selected) theme.text else theme.text_2;
                var icon_color = if (selected) theme.text_2 else theme.text_3;
                if (kind == .ignored) {
                    color = theme.text_3;
                    icon_color = theme.text_3.alpha(0.7);
                } else if (kind != .none) {
                    color = repo.kindColor(kind);
                    icon_color = color;
                    if (!n.is_dir) right -= dl.textRight(repo.font_badge, right, row.centerY(), repo.kindLetter(kind), color) + 6;
                }
                const which = if (n.is_dir) icon.forFolder(n.expanded) else icon.forFile(n.name);
                dl.icon(which, icon_x, row.centerY() - icon_size / 2, icon_size, icon_color);
                const lx = icon_x + icon_size + icon_gap;
                _ = dl.textEllipsis(theme.font_side, lx, row.centerY(), n.name, right - lx, color);

                if (pin_st.clicked) {
                    self.say(.pin, self.path.items, .file, ui);
                } else if (st.clicked and state.drag == null) {
                    self.say(if (n.is_dir) .toggle else .open, self.path.items, .file, ui);
                }
            }
            if (n.is_dir and n.expanded) {
                const from = y.*;
                self.drawNodes(ui, area, state, n.children.items, depth + 1, y);
                // The level's line: under the folder's icon, past all it holds.
                if (y.* > from) dl.rect(.{ .x = icon_x + icon_size / 2 - 0.5, .y = from, .w = 1, .h = y.* - from - 3 }, theme.line_strong);
            }
        }
    }

    /// Records this frame's intent about `path`; `kind` and the pointer
    /// only matter to a menu.
    fn say(self: *View, what: std.meta.Tag(Intent), path: []const u8, kind: FileKind, ui: *const Ui) void {
        // `path` may be a slice of `out` (never) or of the scratch path (often): copy first.
        self.out.clearRetainingCapacity();
        self.out.appendSlice(self.gpa, path) catch return;
        const p = self.out.items;
        self.intent = switch (what) {
            .none => .none,
            .open => .{ .open = p },
            .pin => .{ .pin = p },
            .toggle => .{ .toggle = p },
            .drag => .{ .drag = p },
            .drop => .{ .drop = p },
            .menu => .{ .menu = .{ .kind = kind, .path = p, .x = ui.mx, .y = ui.my } },
        };
    }
};

/// Whether `src` may move into `dir`: not where it already is, and not
/// into itself.
pub fn dropAllowed(src: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, model.parentPath(src), dir)) return false;
    return !paths.isUnder(src, dir);
}

test "tree view: where a dragged path may land" {
    const expect = std.testing.expect;
    try expect(dropAllowed("/p/a.txt", "/p/src"));
    // Where it already is.
    try expect(!dropAllowed("/p/a.txt", "/p"));
    // A folder into itself, or into something it holds.
    try expect(!dropAllowed("/p/src", "/p/src"));
    try expect(!dropAllowed("/p/src", "/p/src/ui"));
    try expect(dropAllowed("/p/src/ui", "/p"));
}

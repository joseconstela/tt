//! The tab system. A tab is an interface (pointer + vtable, the same shape as
//! `std.mem.Allocator`); a *kind* is a named factory registered with the
//! manager. Adding a new kind of tab — notebook, agent run, preview … — means:
//!
//!   1. write a struct with `pub const kind_label` and a `draw` method, plus
//!      whichever optional hooks it needs (see `VTable`),
//!   2. give it a `create(env, args) !Tab` function that returns `Tab.from(T, ptr)`,
//!   3. `manager.register(.{ .name = "...", .label = "...", .create = T.create })`.
//!
//! A kind that shows files also gets an `accepts(path, head)` predicate; the
//! app asks `kindForFile` which viewer opens a path, so adding a viewer for
//! a new format is one struct and one `register` call — nothing else in
//! the app needs to know the new type exists.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const EditCommand = @import("../events.zig").EditCommand;
const History = @import("../input/history.zig").History;
const Textures = @import("../gfx/texture.zig").Textures;
const layout_mod = @import("layout.zig");

pub const Layout = layout_mod.Layout;
pub const Pane = layout_mod.Pane;
pub const Side = layout_mod.Side;

pub const Ui = ui_mod.Ui;
pub const Rect = ui_mod.Rect;

/// Little coloured dot next to the tab title.
pub const Status = enum { none, running, attention, failed };

/// Document commands routed to the active tab (menu items, palette, ⌘S …).
/// The last four are for website tabs: history, reload, focus the address bar.
pub const Command = enum { save, undo, redo, toggle_view, back, forward, reload, open_location };

/// What a tab is opened on. Kinds read the fields they care about.
pub const OpenArgs = struct {
    /// Terminal: directory to start in (default: where the app was launched).
    cwd: ?[]const u8 = null,
    /// File: the document to show.
    path: ?[]const u8 = null,
    /// Website: the page to load (null = an empty tab with the address bar focused).
    url: ?[]const u8 = null,
    /// Terminal: spawn the shell right away; false waits for the first command.
    start_shell: bool = true,
    /// What the kind's `save` wrote in an earlier run (see workspace.zig),
    /// for the tab to come back from.
    saved: ?[]const u8 = null,
};

/// Services shared by every tab.
pub const Env = struct {
    gpa: std.mem.Allocator,
    history: *History,
    /// Directory holding the zsh integration files.
    integration_dir: []const u8,
    user_zdotdir: []const u8,
    launch_cwd: []const u8,
    /// Puts text on the system clipboard (no-op when headless).
    setClipboard: *const fn ([]const u8) void,
    /// GPU textures for viewers that draw pictures (null without a renderer, e.g. in tests).
    textures: ?*Textures = null,
    /// Where a tab can hang a native view (a website tab's WKWebView) over
    /// the Metal layer. Null when there is no window: headless scripts, tests.
    host: ?*const Host = null,
};

/// Native views hosted in the window, implemented by the platform layer.
/// A tab attaches a view once, *places* it on every frame it draws (the
/// host hides whatever was not placed by the time the frame is presented,
/// and everything while a palette or box covers the window), and detaches
/// it when it closes. `rect` is in points, top-left origin, like everything
/// else the tab draws.
pub const Host = struct {
    attach: *const fn (view: *anyopaque) void,
    place: *const fn (view: *anyopaque, rect: Rect) void,
    detach: *const fn (view: *anyopaque) void,
    /// True while the native view (or something inside it) has the keyboard.
    hasFocus: *const fn (view: *anyopaque) bool,
    /// Gives the keyboard to the native view / back to the app's own view.
    focusView: *const fn (view: *anyopaque) void,
    focusApp: *const fn () void,
};

pub const Tab = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Stable identity, assigned by the manager.
    uid: u32 = 0,
    kind: []const u8 = "",
    /// Title the user gave the tab (owned by the manager); null = automatic.
    custom_title: ?[]u8 = null,

    /// What the tab strip shows: the user's name for the tab, else the kind's
    /// own title. The name is copied into `buf` so the result never points
    /// at storage another tab operation could free.
    pub fn title(self: Tab, buf: []u8) []const u8 {
        const custom = self.custom_title orelse return self.vtable.title(self.ptr, buf);
        const n = @min(custom.len, buf.len);
        @memcpy(buf[0..n], custom[0..n]);
        return buf[0..n];
    }

    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        /// Short title for the tab strip (may use `buf` as scratch).
        title: *const fn (*anyopaque, buf: []u8) []const u8,
        status: *const fn (*anyopaque) Status,
        /// Context line shown at the right of the tab strip.
        info: *const fn (*anyopaque, buf: []u8) []const u8,
        /// Called every tick, even in the background. True = needs redraw.
        tick: *const fn (*anyopaque, now: f64, active: bool) bool,
        draw: *const fn (*anyopaque, ui: *Ui, rect: Rect, focused: bool) void,
        onText: *const fn (*anyopaque, utf8: []const u8) void,
        onMarkedText: *const fn (*anyopaque, utf8: []const u8) void,
        onEdit: *const fn (*anyopaque, cmd: EditCommand) void,
        /// Control-key chord, `key` is the lowercase ASCII key.
        onCtrl: *const fn (*anyopaque, key: u8) void,
        /// Appends the current selection to `out`; false if nothing to copy.
        copy: *const fn (*anyopaque, out: *std.ArrayList(u8), cut: bool) bool,
        paste: *const fn (*anyopaque, utf8: []const u8) void,
        hasMarkedText: *const fn (*anyopaque) bool,
        /// Where the text caret is (for IME candidate windows).
        caretRect: *const fn (*anyopaque) Rect,
        /// True once the tab is finished and should be closed (e.g. `exit`).
        wantsClose: *const fn (*anyopaque) bool,
        /// Directory the tab works in ("" if it has none).
        cwd: *const fn (*anyopaque) []const u8,
        /// Document the tab shows ("" if none).
        path: *const fn (*anyopaque) []const u8,
        /// Runs a document command; false when the tab has no use for it.
        command: *const fn (*anyopaque, Command) bool,
        /// Why closing the tab needs a confirmation — a running command,
        /// unsent input, unsaved changes … — as a short sentence (may use
        /// `buf` as scratch). Null when nothing would be lost.
        closeWarning: *const fn (*anyopaque, buf: []u8) ?[]const u8,
        /// Appends what a relaunch needs to show this tab again, in the
        /// kind's own format (see workspace.zig); it comes back through
        /// `OpenArgs.saved`. False when the tab has nothing worth keeping,
        /// so it is not restored — the default.
        save: *const fn (*anyopaque, out: *std.ArrayList(u8)) bool,
        /// Changes whenever `save` would write something different, so the
        /// workspace file is only rewritten when needed.
        saveVersion: *const fn (*anyopaque) u64,
    };

    /// Builds the vtable for `T` at comptime. Only `deinit` and `draw` are
    /// mandatory; every other hook falls back to a sensible default.
    pub fn from(comptime T: type, impl: *T) Tab {
        const gen = struct {
            fn self(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn deinit(p: *anyopaque) void {
                self(p).deinit();
            }
            fn kindTitle(p: *anyopaque, buf: []u8) []const u8 {
                if (@hasDecl(T, "title")) return self(p).title(buf);
                return T.kind_label;
            }
            fn status(p: *anyopaque) Status {
                if (@hasDecl(T, "status")) return self(p).status();
                return .none;
            }
            fn info(p: *anyopaque, buf: []u8) []const u8 {
                if (@hasDecl(T, "info")) return self(p).info(buf);
                return "";
            }
            fn tick(p: *anyopaque, now: f64, active: bool) bool {
                if (@hasDecl(T, "tick")) return self(p).tick(now, active);
                return false;
            }
            fn draw(p: *anyopaque, ui: *Ui, rect: Rect, focused: bool) void {
                self(p).draw(ui, rect, focused);
            }
            fn onText(p: *anyopaque, utf8: []const u8) void {
                if (@hasDecl(T, "onText")) self(p).onText(utf8);
            }
            fn onMarkedText(p: *anyopaque, utf8: []const u8) void {
                if (@hasDecl(T, "onMarkedText")) self(p).onMarkedText(utf8);
            }
            fn onEdit(p: *anyopaque, cmd: EditCommand) void {
                if (@hasDecl(T, "onEdit")) self(p).onEdit(cmd);
            }
            fn onCtrl(p: *anyopaque, key: u8) void {
                if (@hasDecl(T, "onCtrl")) self(p).onCtrl(key);
            }
            fn copy(p: *anyopaque, out: *std.ArrayList(u8), cut: bool) bool {
                if (@hasDecl(T, "copy")) return self(p).copy(out, cut);
                return false;
            }
            fn paste(p: *anyopaque, utf8: []const u8) void {
                if (@hasDecl(T, "paste")) self(p).paste(utf8);
            }
            fn hasMarkedText(p: *anyopaque) bool {
                if (@hasDecl(T, "hasMarkedText")) return self(p).hasMarkedText();
                return false;
            }
            fn caretRect(p: *anyopaque) Rect {
                if (@hasDecl(T, "caretRect")) return self(p).caretRect();
                return .{};
            }
            fn wantsClose(p: *anyopaque) bool {
                if (@hasDecl(T, "wantsClose")) return self(p).wantsClose();
                return false;
            }
            fn cwd(p: *anyopaque) []const u8 {
                if (@hasDecl(T, "cwd")) return self(p).cwd();
                return "";
            }
            fn path(p: *anyopaque) []const u8 {
                if (@hasDecl(T, "path")) return self(p).path();
                return "";
            }
            fn command(p: *anyopaque, cmd: Command) bool {
                if (@hasDecl(T, "command")) return self(p).command(cmd);
                return false;
            }
            fn closeWarning(p: *anyopaque, buf: []u8) ?[]const u8 {
                if (@hasDecl(T, "closeWarning")) return self(p).closeWarning(buf);
                return null;
            }
            fn save(p: *anyopaque, out: *std.ArrayList(u8)) bool {
                if (@hasDecl(T, "save")) return self(p).save(out);
                return false;
            }
            fn saveVersion(p: *anyopaque) u64 {
                if (@hasDecl(T, "saveVersion")) return self(p).saveVersion();
                return 0;
            }
            const vtable: VTable = .{
                .deinit = deinit,
                .title = kindTitle,
                .status = status,
                .info = info,
                .tick = tick,
                .draw = draw,
                .onText = onText,
                .onMarkedText = onMarkedText,
                .onEdit = onEdit,
                .onCtrl = onCtrl,
                .copy = copy,
                .paste = paste,
                .hasMarkedText = hasMarkedText,
                .caretRect = caretRect,
                .wantsClose = wantsClose,
                .cwd = cwd,
                .path = path,
                .command = command,
                .closeWarning = closeWarning,
                .save = save,
                .saveVersion = saveVersion,
            };
        };
        return .{ .ptr = impl, .vtable = &gen.vtable };
    }
};

/// A registered kind of tab.
pub const Kind = struct {
    /// Stable identifier ("terminal").
    name: []const u8,
    /// Human label ("Terminal").
    label: []const u8,
    create: *const fn (env: *Env, args: OpenArgs) anyerror!Tab,
    /// Singleton kinds are focused instead of opened twice (e.g. Settings).
    singleton: bool = false,
    /// False for a tab whose title is its identity (Settings): the tab menu
    /// offers no "Rename…" and `rename` leaves it alone.
    renamable: bool = true,
    /// Viewer kinds: true when this kind should show `path`, given the
    /// file's first bytes (`head`, possibly empty). Kinds are asked in
    /// registration order, so specific formats go before the plain text
    /// fallback. Null = never opened by path (terminal, settings).
    accepts: ?*const fn (path: []const u8, head: []const u8) bool = null,
};

/// A set of tabs shown together. There is one group per sidebar row — a
/// project or one of its resources — keyed by its id, plus the *default*
/// group (id 0) for the default project's own tabs: the first shell, ⌘N
/// tabs, Settings. Switching row switches the group on show; every group's tabs keep running in
/// the background. Within a group the tabs are spread over *panes* — the
/// split layout of the content area (see `layout.zig`); one pane is focused
/// and gets the keyboard.
pub const Group = struct {
    id: u32,
    layout: Layout,

    /// The focused pane: where new tabs open and keys go.
    pub fn pane(self: *Group) *Pane {
        return self.layout.focusedPane();
    }

    pub fn current(self: *Group) ?Tab {
        return self.pane().current();
    }

    /// Tabs across every pane.
    pub fn count(self: *const Group) usize {
        return self.layout.tabCount();
    }
};

pub const TabManager = struct {
    gpa: std.mem.Allocator,
    env: *Env,
    kinds: std.ArrayList(Kind) = .empty,
    /// The default group is created first and never removed.
    groups: std.ArrayList(Group) = .empty,
    /// Id of the group the strip(s) show.
    shown: u32 = default_group,
    next_uid: u32 = 1,
    /// Pane ids are unique across groups, so a pane names itself anywhere.
    next_pane_id: u32 = 1,

    pub const default_group: u32 = 0;

    pub fn init(gpa: std.mem.Allocator, env: *Env) !TabManager {
        var self: TabManager = .{ .gpa = gpa, .env = env };
        try self.groups.append(gpa, .{ .id = default_group, .layout = try Layout.init(gpa, self.newPaneId()) });
        return self;
    }

    pub fn deinit(self: *TabManager) void {
        for (self.groups.items) |*g| self.freeGroup(g);
        self.groups.deinit(self.gpa);
        self.kinds.deinit(self.gpa);
    }

    fn freeGroup(self: *TabManager, g: *Group) void {
        for (g.layout.owned.items) |p| {
            for (p.tabs.items) |t| self.destroyTab(t);
            p.tabs.clearRetainingCapacity();
        }
        g.layout.deinit();
    }

    fn newPaneId(self: *TabManager) u32 {
        const id = self.next_pane_id;
        self.next_pane_id += 1;
        return id;
    }

    pub fn register(self: *TabManager, kind: Kind) void {
        self.kinds.append(self.gpa, kind) catch {};
    }

    pub fn kindByName(self: *const TabManager, name: []const u8) ?Kind {
        for (self.kinds.items) |k| {
            if (std.mem.eql(u8, k.name, name)) return k;
        }
        return null;
    }

    /// The first registered kind that wants to show `path`.
    pub fn kindForFile(self: *const TabManager, path: []const u8, head: []const u8) ?Kind {
        for (self.kinds.items) |k| {
            const accepts = k.accepts orelse continue;
            if (accepts(path, head)) return k;
        }
        return null;
    }

    // ── the group on show and its focused pane ──────────────────────────
    pub fn group(self: *TabManager) *Group {
        return self.findGroup(self.shown) orelse &self.groups.items[0];
    }

    pub fn groupId(self: *const TabManager) u32 {
        return self.shown;
    }

    /// The focused pane of the group on show.
    pub fn pane(self: *TabManager) *Pane {
        return self.group().pane();
    }

    /// The tabs in the focused pane's strip, in order.
    pub fn items(self: *TabManager) []Tab {
        return self.pane().tabs.items;
    }

    pub fn activeIndex(self: *TabManager) usize {
        return self.pane().active;
    }

    pub fn current(self: *TabManager) ?Tab {
        return self.pane().current();
    }

    /// Opens (or focuses, for singletons) a tab of the given kind in the
    /// focused pane of the group on show.
    pub fn open(self: *TabManager, kind_name: []const u8) !usize {
        return self.openWith(kind_name, .{});
    }

    pub fn openWith(self: *TabManager, kind_name: []const u8, args: OpenArgs) !usize {
        const kind = self.kindByName(kind_name) orelse return error.UnknownTabKind;
        if (kind.singleton) {
            // One per app: focusing it may mean switching group and pane.
            for (self.groups.items) |*g| {
                for (g.layout.owned.items) |p| {
                    for (p.tabs.items, 0..) |t, i| {
                        if (std.mem.eql(u8, t.kind, kind.name)) {
                            self.shown = g.id;
                            g.layout.focused = p.id;
                            p.active = i;
                            return i;
                        }
                    }
                }
            }
        }
        var tab = try kind.create(self.env, args);
        errdefer tab.vtable.deinit(tab.ptr);
        tab.uid = self.next_uid;
        tab.kind = kind.name;
        const p = self.pane();
        const at = if (p.tabs.items.len == 0) 0 else p.active + 1;
        try p.tabs.insert(self.gpa, at, tab);
        self.next_uid += 1;
        p.active = at;
        return at;
    }

    pub fn close(self: *TabManager, index: usize) void {
        const g = self.group();
        self.closeIn(g, g.pane(), index);
    }

    /// Closes a tab of any pane of any group (background shells exit too).
    /// A pane left empty is dropped, unless it is its group's last one, so
    /// `p` may be gone afterwards.
    pub fn closeIn(self: *TabManager, g: *Group, p: *Pane, index: usize) void {
        if (index >= p.tabs.items.len) return;
        const t = p.tabs.orderedRemove(index);
        self.destroyTab(t);
        if (p.active > index or p.active >= p.tabs.items.len) p.active -|= 1;
        if (p.tabs.items.len == 0) _ = g.layout.remove(p.id);
    }

    fn destroyTab(self: *TabManager, t: Tab) void {
        t.vtable.deinit(t.ptr);
        if (t.custom_title) |name| self.gpa.free(name);
    }

    /// Longest name `rename` keeps, in bytes (what a title buffer holds).
    pub const max_title_len: usize = 96;

    /// Gives a tab (in any group) a title of the user's choosing; blank
    /// restores the automatic one. Long names are cut at a code point.
    pub fn rename(self: *TabManager, uid: u32, name: []const u8) void {
        if (!self.canRename(uid)) return;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        var n = @min(trimmed.len, max_title_len);
        while (n > 0 and n < trimmed.len and (trimmed[n] & 0xC0) == 0x80) n -= 1;
        const t = self.byUidPtr(uid) orelse return;
        if (t.custom_title) |old| self.gpa.free(old);
        t.custom_title = if (n == 0) null else self.gpa.dupe(u8, trimmed[0..n]) catch null;
    }

    /// Whether the user may give this tab a name of their own.
    pub fn canRename(self: *TabManager, uid: u32) bool {
        const t = self.byUid(uid) orelse return false;
        const kind = self.kindByName(t.kind) orelse return true;
        return kind.renamable;
    }

    pub fn activate(self: *TabManager, index: usize) void {
        const p = self.pane();
        if (index < p.tabs.items.len) p.active = index;
    }

    pub fn cycle(self: *TabManager, delta: isize) void {
        const p = self.pane();
        const n: isize = @intCast(p.tabs.items.len);
        if (n == 0) return;
        const cur: isize = @intCast(p.active);
        p.active = @intCast(@mod(cur + delta, n));
    }

    /// Position of a tab in the focused pane's strip.
    pub fn indexOf(self: *TabManager, uid: u32) ?usize {
        return self.pane().indexOf(uid);
    }

    /// Position in the focused pane's strip of the tab showing `path`.
    pub fn indexOfPath(self: *TabManager, path: []const u8) ?usize {
        for (self.items(), 0..) |t, i| {
            if (std.mem.eql(u8, t.vtable.path(t.ptr), path)) return i;
        }
        return null;
    }

    /// Brings forward the tab showing `path` in any pane of the group on
    /// show (the focused pane first); false when none does.
    pub fn focusPath(self: *TabManager, path: []const u8) bool {
        if (self.indexOfPath(path)) |i| {
            self.activate(i);
            return true;
        }
        const g = self.group();
        for (g.layout.owned.items) |p| {
            for (p.tabs.items, 0..) |t, i| {
                if (!std.mem.eql(u8, t.vtable.path(t.ptr), path)) continue;
                g.layout.focused = p.id;
                p.active = i;
                return true;
            }
        }
        return false;
    }

    // ── panes ───────────────────────────────────────────────────────────
    pub fn paneById(self: *TabManager, id: u32) ?*Pane {
        return self.group().layout.find(id);
    }

    /// The pane (of the group on show) holding a tab.
    pub fn paneOf(self: *TabManager, uid: u32) ?*Pane {
        return self.group().layout.paneOf(uid);
    }

    pub fn focusPane(self: *TabManager, id: u32) bool {
        return self.group().layout.focus(id);
    }

    /// Focus moves `delta` panes along in reading order, wrapping.
    pub fn cyclePane(self: *TabManager, delta: isize) void {
        const l = &self.group().layout;
        l.focused = l.neighbour(delta).id;
    }

    /// A new, empty, focused pane beside the focused one. The caller opens
    /// a tab in it right away (an empty pane is dropped as soon as a tab
    /// leaves it, see `dropIfEmpty`).
    pub fn splitPane(self: *TabManager, side: Side) !*Pane {
        const l = &self.group().layout;
        return l.split(l.focused, side, self.newPaneId());
    }

    /// Rebuilds a group's pane tree from what `Layout.encode` wrote (the
    /// workspace file). The group must still be a single pane.
    pub fn decodeLayout(self: *TabManager, group_id: u32, text: []const u8) !void {
        const g = self.findGroup(group_id) orelse return error.NoSuchGroup;
        try g.layout.decode(text, &self.next_pane_id);
    }

    /// Removes a pane that ended up empty (e.g. its first tab failed to open).
    pub fn dropIfEmpty(self: *TabManager, id: u32) void {
        const g = self.group();
        const p = g.layout.find(id) orelse return;
        if (p.tabs.items.len == 0) _ = g.layout.remove(id);
    }

    /// Moves a tab of the group on show into pane `to` before position
    /// `index` (clamped), focusing it there. Within its own pane this
    /// reorders. A pane left empty is dropped.
    pub fn moveTab(self: *TabManager, uid: u32, to_id: u32, index: usize) bool {
        const g = self.group();
        const from = g.layout.paneOf(uid) orelse return false;
        const to = g.layout.find(to_id) orelse return false;
        const fi = from.indexOf(uid).?;
        if (from == to) {
            var at = @min(index, from.tabs.items.len);
            if (at > fi) at -= 1;
            if (at == fi) {
                from.active = fi;
                return true;
            }
            const t = from.tabs.orderedRemove(fi);
            from.tabs.insertAssumeCapacity(at, t);
            from.active = at;
            return true;
        }
        to.tabs.ensureUnusedCapacity(self.gpa, 1) catch return false;
        const t = from.tabs.orderedRemove(fi);
        if (from.active > fi or from.active >= from.tabs.items.len) from.active -|= 1;
        const at = @min(index, to.tabs.items.len);
        to.tabs.insertAssumeCapacity(at, t);
        to.active = at;
        g.layout.focused = to.id;
        if (from.tabs.items.len == 0) _ = g.layout.remove(from.id);
        return true;
    }

    /// Moves a tab into a new pane on `side` of pane `beside`. Nothing to do
    /// (false) when the tab is alone in that very pane.
    pub fn moveTabToNewPane(self: *TabManager, uid: u32, beside: u32, side: Side) bool {
        const g = self.group();
        const from = g.layout.paneOf(uid) orelse return false;
        if (from.id == beside and from.tabs.items.len == 1) return false;
        const p = g.layout.split(beside, side, self.newPaneId()) catch return false;
        if (self.moveTab(uid, p.id, 0)) return true;
        _ = g.layout.remove(p.id);
        return false;
    }

    // ── groups ──────────────────────────────────────────────────────────
    pub fn findGroup(self: *TabManager, id: u32) ?*Group {
        for (self.groups.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    /// Puts a group on show, creating it (empty, one pane) if needed.
    pub fn show(self: *TabManager, id: u32) !void {
        if (self.findGroup(id) == null) {
            try self.groups.append(self.gpa, .{ .id = id, .layout = try Layout.init(self.gpa, self.newPaneId()) });
        }
        self.shown = id;
    }

    /// The group a tab lives in.
    pub fn groupOf(self: *TabManager, uid: u32) ?u32 {
        for (self.groups.items) |g| {
            if (g.layout.paneOf(uid) != null) return g.id;
        }
        return null;
    }

    fn byUidPtr(self: *TabManager, uid: u32) ?*Tab {
        for (self.groups.items) |g| {
            for (g.layout.owned.items) |p| {
                if (p.indexOf(uid)) |i| return &p.tabs.items[i];
            }
        }
        return null;
    }

    /// A tab from any group.
    pub fn byUid(self: *TabManager, uid: u32) ?Tab {
        const t = self.byUidPtr(uid) orelse return null;
        return t.*;
    }

    /// Shows the group and pane a tab lives in with that tab active.
    pub fn focus(self: *TabManager, uid: u32) bool {
        for (self.groups.items) |*g| {
            for (g.layout.owned.items) |p| {
                const i = p.indexOf(uid) orelse continue;
                self.shown = g.id;
                g.layout.focused = p.id;
                p.active = i;
                return true;
            }
        }
        return false;
    }

    /// Drops a group. Its tabs move to the end of the default group's
    /// focused pane, so a resource can be removed without killing the
    /// shells that were in it.
    pub fn dissolve(self: *TabManager, id: u32) void {
        if (id == default_group) return;
        var gi: usize = 0;
        while (gi < self.groups.items.len and self.groups.items[gi].id != id) gi += 1;
        if (gi == self.groups.items.len) return;
        var g = self.groups.orderedRemove(gi);
        const was_shown = self.shown == id;
        if (was_shown) self.shown = default_group;
        const home = self.findGroup(default_group).?.pane();
        const first = home.tabs.items.len;
        const shown_active = if (g.layout.find(g.layout.focused)) |p| p.current() else null;
        const list = g.layout.panes();
        for (list.slice()) |p| {
            home.tabs.appendSlice(self.gpa, p.tabs.items) catch {
                for (p.tabs.items) |t| self.destroyTab(t);
            };
            p.tabs.clearRetainingCapacity();
        }
        g.layout.deinit();
        if (was_shown) {
            if (shown_active) |t| {
                if (home.indexOf(t.uid)) |i| home.active = i;
            } else if (home.tabs.items.len > first) home.active = first;
        }
    }

    /// Tabs across every group.
    pub fn count(self: *const TabManager) usize {
        var n: usize = 0;
        for (self.groups.items) |g| n += g.count();
        return n;
    }
};

// ── tests ───────────────────────────────────────────────────────────────
const TestTab = struct {
    pub const kind_label = "Test";
    gpa: std.mem.Allocator,
    doc: []const u8,

    fn create(env: *Env, args: OpenArgs) anyerror!Tab {
        const self = try env.gpa.create(TestTab);
        self.* = .{ .gpa = env.gpa, .doc = args.path orelse "" };
        return Tab.from(TestTab, self);
    }
    pub fn deinit(self: *TestTab) void {
        self.gpa.destroy(self);
    }
    pub fn draw(_: *TestTab, _: *Ui, _: Rect, _: bool) void {}
    pub fn path(self: *TestTab) []const u8 {
        return self.doc;
    }
};

fn testEnv(history: *History) Env {
    return .{
        .gpa = std.testing.allocator,
        .history = history,
        .integration_dir = "",
        .user_zdotdir = "",
        .launch_cwd = "/",
        .setClipboard = struct {
            fn f(_: []const u8) void {}
        }.f,
    };
}

test "tab groups: each group has its own strip, dissolving keeps the tabs" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var env = testEnv(&history);
    var tm = try TabManager.init(std.testing.allocator, &env);
    defer tm.deinit();
    tm.register(.{ .name = "test", .label = "Test", .create = TestTab.create });
    tm.register(.{ .name = "single", .label = "Single", .create = TestTab.create, .singleton = true, .renamable = false });
    // Viewer dispatch: the first kind whose predicate says yes wins; the
    // fallback comes last; kinds without a predicate are never chosen.
    const Pred = struct {
        fn md(path: []const u8, _: []const u8) bool {
            return std.mem.endsWith(u8, path, ".md");
        }
        fn any(_: []const u8, _: []const u8) bool {
            return true;
        }
    };
    tm.register(.{ .name = "markdown", .label = "Markdown", .create = TestTab.create, .accepts = Pred.md });
    tm.register(.{ .name = "text", .label = "Text", .create = TestTab.create, .accepts = Pred.any });
    try std.testing.expectEqualStrings("markdown", tm.kindForFile("/x/README.md", "").?.name);
    try std.testing.expectEqualStrings("text", tm.kindForFile("/x/main.zig", "").?.name);

    // Default group: two tabs, the second one active.
    _ = try tm.open("test");
    const ai = try tm.open("test");
    const a = tm.items()[ai].uid;
    try std.testing.expectEqual(@as(usize, 2), tm.items().len);
    try std.testing.expectEqual(@as(usize, 1), tm.activeIndex());

    // Resource 7 gets its own, initially empty, strip.
    try tm.show(7);
    try std.testing.expectEqual(@as(usize, 0), tm.items().len);
    try std.testing.expect(tm.current() == null);
    const bi = try tm.openWith("test", .{ .path = "/x/readme" });
    const b = tm.items()[bi].uid;
    try std.testing.expectEqual(@as(usize, 1), tm.items().len);
    try std.testing.expectEqual(@as(?usize, 0), tm.indexOfPath("/x/readme"));
    try std.testing.expectEqual(@as(?u32, 7), tm.groupOf(b));
    try std.testing.expectEqual(@as(?u32, 0), tm.groupOf(a));
    try std.testing.expect(tm.indexOf(a) == null); // not in this strip
    try std.testing.expect(tm.byUid(a) != null); // but still alive
    try std.testing.expectEqual(@as(usize, 3), tm.count());

    // Renaming: the user's name wins over the kind's title, blank restores
    // it, and a name outlives group moves (freed on close — the testing
    // allocator would report a leak).
    var tb: [96]u8 = undefined;
    tm.rename(a, "  Build  ");
    try std.testing.expectEqualStrings("Build", tm.byUid(a).?.title(&tb));
    tm.rename(a, "   ");
    try std.testing.expectEqualStrings("Test", tm.byUid(a).?.title(&tb));
    tm.rename(b, "Notes");
    try std.testing.expect(tm.byUid(b).?.vtable.closeWarning(tm.byUid(b).?.ptr, &tb) == null);

    // Focusing a tab switches to its group.
    try std.testing.expect(tm.focus(a));
    try std.testing.expectEqual(TabManager.default_group, tm.groupId());
    try std.testing.expectEqual(@as(usize, 1), tm.activeIndex());

    // A singleton opened from another group is found where it lives.
    try tm.show(7);
    const si = try tm.open("single");
    const s = tm.items()[si].uid;
    try tm.show(0);
    _ = try tm.open("single");
    try std.testing.expectEqual(@as(u32, 7), tm.groupId());
    try std.testing.expectEqual(@as(usize, 2), tm.items().len);
    try std.testing.expectEqual(@as(usize, 4), tm.count());

    // A kind whose title is its identity cannot be renamed.
    try std.testing.expect(tm.canRename(a));
    try std.testing.expect(!tm.canRename(s));
    tm.rename(s, "Prefs");
    try std.testing.expectEqualStrings("Test", tm.byUid(s).?.title(&tb));

    // Dissolving the shown group hands its tabs to the default one, keeping the active tab.
    tm.dissolve(7);
    try std.testing.expectEqual(TabManager.default_group, tm.groupId());
    try std.testing.expectEqual(@as(usize, 4), tm.items().len);
    try std.testing.expectEqual(@as(usize, 3), tm.activeIndex());
    try std.testing.expect(tm.findGroup(7) == null);
    try std.testing.expectEqual(@as(?u32, 0), tm.groupOf(b));
    try std.testing.expectEqualStrings("Notes", tm.byUid(b).?.title(&tb));

    // Closing keeps the active index sane; the default group cannot be dissolved.
    tm.close(3);
    try std.testing.expectEqual(@as(usize, 2), tm.activeIndex());
    tm.dissolve(0);
    try std.testing.expectEqual(@as(usize, 3), tm.count());
}

test "panes: splitting, moving tabs between panes, empty panes go away" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var env = testEnv(&history);
    var tm = try TabManager.init(std.testing.allocator, &env);
    defer tm.deinit();
    tm.register(.{ .name = "test", .label = "Test", .create = TestTab.create });

    // One pane with three tabs; the split opens an empty pane on the right
    // that takes the focus and the next tab.
    const a_i = try tm.openWith("test", .{ .path = "/a" });
    const a = tm.items()[a_i].uid;
    const b_i = try tm.openWith("test", .{ .path = "/b" });
    const b = tm.items()[b_i].uid;
    const c_i = try tm.openWith("test", .{ .path = "/c" });
    const c = tm.items()[c_i].uid;
    const left = tm.pane().id;
    const right = (try tm.splitPane(.right)).id;
    try std.testing.expectEqual(right, tm.pane().id);
    try std.testing.expectEqual(@as(usize, 0), tm.items().len);
    try std.testing.expectEqual(@as(usize, 2), tm.group().layout.count());
    const d_i = try tm.openWith("test", .{ .path = "/d" });
    const d = tm.items()[d_i].uid;
    try std.testing.expectEqual(@as(usize, 4), tm.count());
    try std.testing.expectEqual(@as(usize, 4), tm.group().count());

    // The strip is per pane; a path in another pane is found and focused.
    try std.testing.expect(tm.indexOfPath("/a") == null);
    try std.testing.expect(tm.focusPath("/a"));
    try std.testing.expectEqual(left, tm.pane().id);
    try std.testing.expectEqual(@as(usize, 0), tm.activeIndex());
    try std.testing.expect(!tm.focusPath("/nope"));

    // Move b to the right pane, first position: it becomes active there and
    // the right pane gets the focus.
    try std.testing.expect(tm.moveTab(b, right, 0));
    try std.testing.expectEqual(right, tm.pane().id);
    try std.testing.expectEqual(b, tm.items()[0].uid);
    try std.testing.expectEqual(d, tm.items()[1].uid);
    try std.testing.expectEqual(@as(usize, 0), tm.activeIndex());
    try std.testing.expectEqual(@as(usize, 2), tm.paneById(left).?.tabs.items.len);

    // Reordering within a pane: d before b.
    try std.testing.expect(tm.moveTab(d, right, 0));
    try std.testing.expectEqual(d, tm.items()[0].uid);
    try std.testing.expect(tm.moveTab(d, right, 2)); // to the end
    try std.testing.expectEqual(d, tm.items()[1].uid);

    // Splitting a tab off below its pane; a lone tab has nowhere to go.
    try std.testing.expect(tm.moveTabToNewPane(d, right, .bottom));
    try std.testing.expectEqual(@as(usize, 3), tm.group().layout.count());
    try std.testing.expectEqual(d, tm.current().?.uid);
    const below = tm.pane().id;
    try std.testing.expect(!tm.moveTabToNewPane(d, below, .right));
    try std.testing.expectEqual(@as(usize, 3), tm.group().layout.count());
    try std.testing.expectEqual(@as(usize, 3), tm.group().layout.count());
    try std.testing.expectEqual(below, tm.paneOf(d).?.id);

    // Closing the last tab of a pane drops the pane and focuses a neighbour.
    tm.close(0);
    try std.testing.expectEqual(@as(usize, 2), tm.group().layout.count());
    try std.testing.expect(tm.paneById(below) == null);
    try std.testing.expectEqual(right, tm.pane().id);
    try std.testing.expectEqual(b, tm.current().?.uid);

    // Moving the last tab out empties and drops its pane too.
    try std.testing.expect(tm.moveTab(b, left, 5));
    try std.testing.expectEqual(@as(usize, 1), tm.group().layout.count());
    try std.testing.expectEqual(left, tm.pane().id);
    try std.testing.expectEqual(b, tm.items()[2].uid);
    try std.testing.expectEqual(@as(usize, 2), tm.activeIndex());
    _ = a;
    _ = c;

    // Cycling panes wraps; with one pane it stays put.
    tm.cyclePane(1);
    try std.testing.expectEqual(left, tm.pane().id);
    const top = (try tm.splitPane(.top)).id;
    _ = try tm.open("test");
    tm.cyclePane(1);
    try std.testing.expectEqual(left, tm.pane().id);
    tm.cyclePane(-1);
    try std.testing.expectEqual(top, tm.pane().id);

    // Dissolving a group with several panes gathers every pane's tabs.
    try tm.show(9);
    _ = try tm.openWith("test", .{ .path = "/x" });
    _ = try tm.splitPane(.right);
    const y_i = try tm.openWith("test", .{ .path = "/y" });
    const y = tm.items()[y_i].uid;
    try std.testing.expectEqual(@as(usize, 2), tm.group().layout.count());
    tm.dissolve(9);
    try std.testing.expectEqual(TabManager.default_group, tm.groupId());
    try std.testing.expectEqual(y, tm.current().?.uid);
    try std.testing.expectEqual(@as(usize, 6), tm.count());
    try std.testing.expect(tm.findGroup(9) == null);
}

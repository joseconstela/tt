//! Platform-neutral application core: owns the renderer, the UI state, the
//! tabs and the projects; receives input events; builds and submits frames.
const std = @import("std");
const objc = @import("objc.zig");
const draw = @import("gfx/draw.zig");
const text_mod = @import("gfx/text.zig");
const Renderer = @import("gfx/renderer.zig").Renderer;
const ui_mod = @import("ui/ui.zig");
const theme = @import("ui/theme.zig");
const sidebar_mod = @import("ui/sidebar.zig");
const files_mod = @import("ui/files.zig");
const panes_mod = @import("ui/panes.zig");
const tabbar_mod = @import("ui/tabbar.zig");
const palette_mod = @import("ui/palette.zig");
const overlay_mod = @import("ui/overlay.zig");
const desktop = @import("desktop.zig");
const paths = @import("paths.zig");
const tab_mod = @import("tabs/tab.zig");
const TerminalTab = @import("tabs/terminal_tab.zig").TerminalTab;
const FileTab = @import("tabs/file_tab.zig").FileTab;
const MarkdownTab = @import("tabs/markdown_tab.zig").MarkdownTab;
const ImageTab = @import("tabs/image_tab.zig").ImageTab;
const PdfTab = @import("tabs/pdf_tab.zig").PdfTab;
const SettingsTab = @import("tabs/settings_tab.zig").SettingsTab;
const WebTab = @import("tabs/web_tab.zig").WebTab;
const History = @import("input/history.zig").History;
const projects_mod = @import("projects.zig");
const workspace_mod = @import("workspace.zig");
const shell_integration = @import("term/shell_integration.zig");
const EditCommand = @import("events.zig").EditCommand;
const sys = @import("sys.zig");
const filetype = @import("filetype.zig");
const config = @import("config.zig");
const appearance = @import("appearance.zig");

pub const LaunchOptions = struct {
    width: f32 = 1440,
    height: f32 = 900,
    scale: f32 = 2,
    script_path: ?[]const u8 = null,
};

pub const Chrome = sidebar_mod.Chrome;

pub const Action = enum {
    /// A terminal tab; with a resource on show, another shell in its folder.
    new_tab,
    /// A tab with no shell yet: the first ↵ or command starts one.
    new_empty_tab,
    /// A website tab (the globe next to "+", ⌘⇧N), address bar focused.
    new_web_tab,
    close_tab,
    next_tab,
    prev_tab,
    /// A new pane beside / below the focused one, with a shell in the
    /// current directory (⌘D / ⌘⇧D). Tabs are dragged between panes by
    /// their title; dropping one on a side of a pane splits it too.
    split_right,
    split_down,
    /// Focus the next / previous pane in reading order (⌘] / ⌘[).
    next_pane,
    prev_pane,
    toggle_sidebar,
    toggle_files,
    /// The files panel's Search view, its box focused (⌘⇧F).
    find_in_files,
    open_settings,
    clear,
    /// ⌘K: the palette in command mode.
    command_palette,
    /// ⌘P: the palette in quick-open mode ("Go to File…", as in VS Code).
    quick_open,
    /// Quick open with `:` typed: go to a line of the current editor.
    go_to_line,
    /// Asks the platform for a folder picker (see `folder_pick_requested`).
    add_project,
    /// Adds the current shell's directory as a project.
    add_project_here,
    // Document commands, routed to the active tab.
    save,
    undo,
    redo,
    /// Markdown: source ⇄ visual.
    toggle_view,
    // Website tabs.
    open_location,
    web_reload,
    web_back,
    web_forward,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    text: text_mod.TextEngine,
    dl: draw.DrawList,
    renderer: Renderer,
    ui: ui_mod.Ui,
    sidebar: sidebar_mod.Sidebar = .{},
    files: files_mod.FileBrowser,
    palette: palette_mod.Palette,
    /// The context menus (tab, sidebar project / resource) and their
    /// rename / close-confirmation boxes.
    overlay: overlay_mod.Overlay,
    /// The split panes of the group on show and a tab being dragged.
    panes: panes_mod.PaneView = .{},
    tabs: tab_mod.TabManager,
    env: tab_mod.Env,
    history: History,
    projects: projects_mod.Projects,
    /// The open tabs and what they show, kept across relaunches.
    workspace: workspace_mod.Workspace,
    chrome: Chrome = .{},

    width: f32,
    height: f32,
    scale: f32,
    /// Frames still to draw; input sets this to 2 so state changes made while
    /// building a frame are reflected by the next one.
    dirty: u32 = 2,
    now: f64 = 0,
    quit_requested: bool = false,
    /// Set by `.add_project`; the platform layer runs the picker and calls `addProject`.
    folder_pick_requested: bool = false,
    /// Project the user last touched (where pinned files go when the
    /// directory does not decide).
    selected_project: ?u32 = null,
    /// Directory of the last tab that had one; what the files panel shows
    /// while a tab without a directory (Settings) is active.
    last_cwd: std.ArrayList(u8) = .empty,
    /// The path being dragged from the files panel (the ghost is the pane
    /// view's `drag`); empty when none.
    file_drag: std.ArrayList(u8) = .empty,
    /// When macOS's appearance was last read (mode "system" polls it).
    appearance_checked: f64 = 0,
    /// The mode the theme was last put in; a change (the general setting,
    /// the window moving to a display with its own) applies at once.
    applied_mode: ?config.Mode = null,

    pub fn create(gpa: std.mem.Allocator, opts: LaunchOptions, layer: objc.id, setClipboard: *const fn ([]const u8) void) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        // The settings first: the theme has to be right before anything draws.
        config.init(gpa);
        appearance.applyAccent(config.get().accent);
        theme.setScheme(appearance.resolve(appearance.effectiveMode()));

        var cwd_buf: [4096]u8 = undefined;
        const cwd_ok = std.c.getcwd(&cwd_buf, cwd_buf.len) != null;
        var cwd: []const u8 = if (cwd_ok) std.mem.sliceTo(&cwd_buf, 0) else sys.home();
        // Launched from Finder the cwd is "/": start in the home directory instead.
        if (std.mem.eql(u8, cwd, "/")) cwd = sys.home();

        self.* = .{
            .gpa = gpa,
            .text = try text_mod.TextEngine.init(gpa),
            .dl = undefined,
            .renderer = try Renderer.init(layer),
            .ui = undefined,
            .files = files_mod.FileBrowser.init(gpa),
            .palette = palette_mod.Palette.init(gpa),
            .overlay = overlay_mod.Overlay.init(gpa),
            .tabs = undefined,
            .history = History.init(gpa),
            .projects = projects_mod.Projects.init(gpa),
            // Test runs (scripts, the selftest) leave the user's workspace alone
            // unless TT_WORKSPACE names a file of their own.
            .workspace = workspace_mod.Workspace.init(gpa, opts.script_path == null and sys.getenv("TT_SELFTEST") == null),
            .env = .{
                .gpa = gpa,
                .history = undefined,
                .integration_dir = try shell_integration.install(gpa),
                .user_zdotdir = try gpa.dupe(u8, sys.getenv("ZDOTDIR") orelse sys.home()),
                .launch_cwd = try gpa.dupe(u8, cwd),
                .setClipboard = setClipboard,
            },
            .width = opts.width,
            .height = opts.height,
            .scale = opts.scale,
        };
        self.text.setScale(opts.scale);
        self.dl = draw.DrawList.init(gpa, &self.text);
        self.ui = ui_mod.Ui.init(gpa, &self.dl, &self.text);
        self.history.load();
        self.env.history = &self.history;
        self.env.textures = &self.renderer.textures;
        self.projects.load();

        self.tabs = try tab_mod.TabManager.init(gpa, &self.env);
        self.tabs.register(.{ .name = "terminal", .label = "Terminal", .create = TerminalTab.create });
        // Viewers, most specific first: `openFile` asks them in this order
        // and the text viewer takes whatever is left.
        self.tabs.register(.{ .name = "image", .label = "Image", .create = ImageTab.create, .accepts = ImageTab.accepts });
        self.tabs.register(.{ .name = "pdf", .label = "PDF", .create = PdfTab.create, .accepts = PdfTab.accepts });
        self.tabs.register(.{ .name = "markdown", .label = "Markdown", .create = MarkdownTab.create, .accepts = MarkdownTab.accepts });
        self.tabs.register(.{ .name = "file", .label = "File", .create = FileTab.create, .accepts = FileTab.accepts });
        self.tabs.register(.{ .name = "settings", .label = "Settings", .create = SettingsTab.create, .singleton = true, .renamable = false });
        self.tabs.register(.{ .name = "web", .label = "Website", .create = WebTab.create });
        // The tabs of the last run come back; a first run starts with one shell.
        _ = self.workspace.restore(&self.tabs, &self.projects);
        self.keepShowingSomething();
        return self;
    }

    pub fn destroy(self: *App) void {
        self.workspace.save(&self.tabs, &self.projects);
        self.workspace.deinit();
        self.tabs.deinit();
        for (self.env.requests.items) |r| r.free(self.gpa);
        self.env.requests.deinit(self.gpa);
        config.get().save();
        config.deinit();
        appearance.deinit(self.gpa);
        self.palette.deinit();
        self.overlay.deinit();
        self.projects.deinit();
        self.files.deinit();
        self.history.deinit();
        self.last_cwd.deinit(self.gpa);
        self.file_drag.deinit(self.gpa);
        self.ui.deinit();
        self.dl.deinit();
        self.gpa.destroy(self);
    }

    pub fn invalidate(self: *App) void {
        self.dirty = 2;
    }

    pub fn resize(self: *App, width: f32, height: f32, scale: f32) void {
        if (width == self.width and height == self.height and scale == self.scale) return;
        self.width = width;
        self.height = height;
        self.scale = scale;
        self.text.setScale(scale);
        self.invalidate();
    }

    // ── per-tick work ───────────────────────────────────────────────────
    /// Polls tabs; returns true when a new frame should be drawn.
    pub fn update(self: *App, now: f64) bool {
        self.now = now;
        // Every group ticks, not just the one on show: shells keep running
        // (and may exit) while another resource is on show. A tab that
        // closes itself may take its pane with it, so the pane list is
        // fetched again after each close.
        for (self.tabs.groups.items) |*g| {
            const shown = g.id == self.tabs.groupId();
            var again = true;
            while (again) {
                again = false;
                const list = g.layout.panes();
                panes: for (list.slice()) |p| {
                    var i: usize = 0;
                    while (i < p.tabs.items.len) : (i += 1) {
                        const t = p.tabs.items[i];
                        if (t.vtable.tick(t.ptr, now, shown and i == p.active)) self.invalidate();
                        if (t.vtable.wantsClose(t.ptr)) {
                            self.tabs.closeIn(g, p, i);
                            self.invalidate();
                            again = true;
                            break :panes;
                        }
                    }
                }
            }
        }
        self.serveRequests();
        self.keepShowingSomething();
        // A menu or box about a tab that has since closed itself has nothing left to act on.
        if (self.overlay.aboutTab()) |uid| if (self.tabs.byUid(uid) == null) self.overlay.close();
        if (self.overlay.tick(now)) self.invalidate();
        if (self.files.tick(now)) self.invalidate();
        if (self.palette.tick(now)) self.invalidate();
        // The theme follows the mode set for the display the window is on,
        // else the general one; "system" also follows macOS when it
        // switches between light and dark (polled, it is a defaults read).
        const cfg = config.get();
        const mode = appearance.effectiveMode();
        if (mode != self.applied_mode or now - self.appearance_checked >= 2) {
            self.applied_mode = mode;
            self.appearance_checked = now;
            if (appearance.apply(mode)) self.invalidate();
        }
        cfg.saveIfDue(now);
        self.workspace.saveIfChanged(&self.tabs, &self.projects, now);
        return self.dirty > 0;
    }

    pub fn buildFrame(self: *App) void {
        // If the glyph atlas overflowed mid-frame the UVs emitted before the
        // wipe are stale: build the frame again (at most once more).
        var attempts: u32 = 0;
        while (attempts < 2) : (attempts += 1) {
            const generation = self.text.generation;
            self.buildFrameOnce();
            if (self.text.generation == generation) break;
        }
        if (self.dirty > 0) self.dirty -= 1;
        if (self.ui.wants_frame) self.invalidate();
    }

    fn buildFrameOnce(self: *App) void {
        const ui = &self.ui;
        self.dl.begin(self.width, self.height, self.scale);
        ui.beginFrame(self.now);
        defer ui.endFrame();

        self.dl.rect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, theme.bg);

        const cwd = self.currentCwd();
        self.files.setRoot(cwd, self.now);

        // A secondary click while a tab menu is open dismisses it first, so
        // the strip underneath can summon another one for that tab.
        if (self.overlay.mode == .menu and ui.right_pressed) self.overlay.close();
        // Under an open palette, menu or box everything else is inert.
        const palette_open = self.palette.open;
        const mouse_inside = ui.mouse_inside;
        if (palette_open or self.overlay.isOpen()) ui.mouse_inside = false;

        // Main column: the tab strips live in the titlebar band (right of the
        // sidebar header — or, with the sidebar collapsed, of its toggle in
        // the band — spanning the files panel too), the panes under it.
        // The panels' resize grips are drawn on top of it.
        const side_w = self.sidebar.currentWidth();
        const files_w = self.files.currentWidth();
        const bar: draw.Rect = .{ .x = side_w, .y = 0, .w = self.width - side_w, .h = theme.header_h };
        const content: draw.Rect = .{ .x = side_w, .y = theme.header_h, .w = self.width - side_w - files_w, .h = self.height - theme.header_h };
        const files_rect: draw.Rect = .{ .x = self.width - files_w, .y = theme.header_h, .w = files_w, .h = self.height - theme.header_h };

        // The sidebar handles its splitter before anything else claims the
        // mouse. A path dragged from the files panel is known to every part.
        const dragged = self.draggedFile();
        var ctx: sidebar_mod.Context = .{ .projects = &self.projects, .tabs = &self.tabs, .dragging_file = dragged != null };
        if (self.projects.containing(cwd)) |p| ctx.current_project = p.id;
        const side = self.sidebar.draw(ui, self.height, self.chrome, ctx);
        self.applySidebar(side);

        // The files panel owns the splitter on its left edge, so it goes before the panes.
        const fr = self.files.draw(ui, files_rect, true, dragged);
        if (fr.open_file) |path| self.openFile(path);
        if (fr.open_at) |o| self.openFileAt(o);
        if (fr.pin_file) |path| self.pinFile(path);
        if (fr.confirm) |c| self.overlay.openConfirmAction(.git_discard, 0, c.heading, c.reason, "Discard");
        if (fr.replace) |c| self.overlay.openConfirmAction(.search_replace, 0, c.heading, c.reason, "Replace");
        if (fr.menu) |m| self.overlay.openList(m.items, m.checked, m.sep_after, m.x, m.y);
        if (fr.file_menu) |m| self.openFileMenu(m);
        if (fr.drag_file) |path| self.startFileDrag(path);
        if (fr.drop_into) |dir| self.moveDroppedInto(dir);

        // The panes: each one's strip, its active tab, the dividers, and a
        // tab being dragged. Moves are applied to the tab manager inside.
        const pv = self.panes.draw(ui, &self.tabs, bar, content, side.band_inset, self.files.visible, self.chrome.window_focused);
        if (pv.menu) |m| self.openTabMenu(m);
        if (pv.new_tab) |pane| {
            _ = self.tabs.focusPane(pane);
            self.perform(.new_tab);
        }
        if (pv.new_web_tab) |pane| {
            _ = self.tabs.focusPane(pane);
            self.perform(.new_web_tab);
        }
        if (pv.toggle_files) self.perform(.toggle_files);
        if (pv.file_drop) |target| self.openDroppedAt(target);
        if (pv.changed) self.invalidate();
        // The drag is over once the pane view has let go of it.
        if (self.panes.drag == null) self.file_drag.clearRetainingCapacity();

        if (self.chrome.fake_lights) {
            const colors = [_]draw.Color{ draw.Color.hex(0xFF5F57), draw.Color.hex(0xFEBC2E), draw.Color.hex(0x28C840) };
            // Same geometry AppKit reports for the real buttons (x=19/42/65, 14pt).
            for (colors, 0..) |c, i| self.dl.circle(26 + @as(f32, @floatFromInt(i)) * 23, 26, 7, c);
        }

        // The tab menu / boxes and the palette float over everything and are
        // the only things that get the mouse.
        ui.mouse_inside = mouse_inside;
        if (!palette_open) {
            if (self.overlay.draw(ui, self.width, self.height)) |out| self.applyOverlay(out);
        }
        if (self.palette.draw(ui, self.width, self.height)) |pick| self.executePick(pick);
    }

    fn applySidebar(self: *App, side: sidebar_mod.Result) void {
        if (side.add_project) self.perform(.add_project);
        if (side.select_project) |id| self.selected_project = id;
        if (side.open_group) |gid| self.openGroup(gid);
        if (side.new_tab_in) |gid| self.newShellIn(gid);
        if (side.open_resource) |rid| self.openResource(rid);
        if (side.menu) |m| {
            const subject: overlay_mod.Subject = switch (m.target) {
                .project => .project,
                .default_project => .default_project,
                .resource => .resource,
            };
            self.overlay.openMenu(subject, m.id, m.x, m.y);
        }
        if (side.drop_file) |drop| self.pinDropped(drop);
        if (side.changed) self.projects.save();
    }

    /// The menu's "New Shell Group": a new group of shells under a project
    /// (in its folder) or, for id 0, under the default project (in the
    /// current directory), its first shell open.
    fn newShellGroup(self: *App, pid: u32) void {
        const p: ?*projects_mod.Project = if (pid == tab_mod.TabManager.default_group) null else (self.projects.find(pid) orelse return);
        const dir = if (p) |proj| proj.root else self.currentCwd();
        const group = self.projects.addShells(p, dir) catch |err| {
            std.log.err("could not add a shell group: {s}", .{@errorName(err)});
            return;
        };
        if (p) |proj| {
            proj.open = true;
            self.selected_project = proj.id;
        } else self.sidebar.default_open = true;
        self.openShell(group);
        self.projects.save();
    }

    /// Removing a resource keeps its open tabs: they move to the default
    /// project instead of being killed.
    fn removeResource(self: *App, rid: u32) void {
        const f = self.projects.findResource(rid) orelse return;
        self.tabs.dissolve(rid);
        self.projects.removeResource(f.project, rid);
        self.projects.save();
        self.keepShowingSomething();
    }

    /// Same for a project: its own tabs and every resource's join the
    /// default project.
    fn removeProject(self: *App, pid: u32) void {
        if (self.projects.find(pid)) |p| {
            for (p.resources.items) |r| self.tabs.dissolve(r.id);
        }
        self.tabs.dissolve(pid);
        self.projects.remove(pid);
        if (self.selected_project == pid) self.selected_project = null;
        self.projects.save();
        self.keepShowingSomething();
    }

    /// The sidebar's rename box for a project (blank: the folder's name).
    fn renameProject(self: *App, pid: u32, name: []const u8) void {
        const p = self.projects.find(pid) orelse return;
        self.projects.renameProject(p, name) catch |err| {
            std.log.err("could not rename the project: {s}", .{@errorName(err)});
            return;
        };
        self.projects.save();
    }

    /// The sidebar's rename box: a resource's sidebar label.
    fn renameResource(self: *App, rid: u32, name: []const u8) void {
        const f = self.projects.findResource(rid) orelse return;
        self.projects.renameResource(f.resource, name) catch |err| {
            std.log.err("could not rename the resource: {s}", .{@errorName(err)});
            return;
        };
        self.projects.save();
    }

    /// Where the icon of a project, the default project or a resource
    /// lives in the model (see `icon_spec`).
    fn iconSlot(self: *App, subject: overlay_mod.Subject, id: u32) ?*?[]u8 {
        return switch (subject) {
            .default_project => &self.projects.default_icon,
            .project => if (self.projects.find(id)) |p| &p.icon else null,
            .resource => if (self.projects.findResource(id)) |f| &f.resource.icon else null,
            .tab, .file => null,
        };
    }

    /// The icon picker's choice (null: none).
    fn setIcon(self: *App, subject: overlay_mod.Subject, id: u32, icon: ?[]const u8) void {
        const slot = self.iconSlot(subject, id) orelse return;
        self.projects.setIcon(slot, icon) catch |err| {
            std.log.err("could not set the icon: {s}", .{@errorName(err)});
            return;
        };
        self.projects.save();
    }

    /// A row's tabs in the strip: an empty group starts a shell (in the
    /// project's folder), and clicking the row that is already on show
    /// steps through its tabs.
    fn openGroup(self: *App, gid: u32) void {
        const again = self.tabs.groupId() == gid;
        if (self.projects.find(gid)) |p| self.selected_project = p.id;
        self.tabs.show(gid) catch |err| {
            std.log.err("could not show the group's tabs: {s}", .{@errorName(err)});
            return;
        };
        if (self.tabs.items().len == 0) {
            self.newShellIn(gid);
        } else if (again) self.tabs.cycle(1);
        self.invalidate();
    }

    /// One more shell among a row's tabs: in the project's folder, or for
    /// the default project where a plain new terminal starts. The rows'
    /// hover terminal and ⌘T.
    fn newShellIn(self: *App, gid: u32) void {
        self.tabs.show(gid) catch |err| {
            std.log.err("could not show the group's tabs: {s}", .{@errorName(err)});
            return;
        };
        const opened = if (self.projects.find(gid)) |p| blk: {
            self.selected_project = p.id;
            break :blk self.tabs.openWith("terminal", .{ .cwd = p.root });
        } else self.tabs.open("terminal");
        _ = opened catch |err| std.log.err("could not open terminal tab: {s}", .{@errorName(err)});
        self.invalidate();
    }

    pub fn present(self: *App) void {
        self.renderer.present(&self.dl, &self.text, theme.bg);
    }

    pub fn snapshot(self: *App, path: []const u8) !void {
        self.invalidate();
        self.buildFrame();
        self.buildFrame();
        const w: u32 = @intFromFloat(@round(self.width * self.scale));
        const h: u32 = @intFromFloat(@round(self.height * self.scale));
        try self.renderer.snapshot(&self.dl, &self.text, theme.bg, w, h, path);
    }

    /// True if (x, y) hits a widget (so a titlebar click must not drag the window).
    pub fn isInteractiveAt(self: *const App, x: f32, y: f32) bool {
        for (self.ui.interactive.items) |r| {
            if (r.contains(x, y)) return true;
        }
        return false;
    }

    // ── actions ─────────────────────────────────────────────────────────
    pub fn perform(self: *App, action: Action) void {
        // Any command closes the palette (⌘K / ⌘P toggle it) and whatever
        // the tab menu had open.
        if (action != .command_palette and action != .quick_open and action != .go_to_line) self.palette.close();
        self.overlay.close();
        switch (action) {
            .command_palette => self.palette.toggle(.commands, self.paletteSources()),
            .quick_open => self.palette.toggle(.files, self.paletteSources()),
            .go_to_line => self.palette.showLine(self.paletteSources()),
            .new_tab => self.newTerminal(),
            .new_empty_tab => _ = self.tabs.openWith("terminal", .{ .start_shell = false, .cwd = self.currentCwd() }) catch |err| {
                std.log.err("could not open a tab: {s}", .{@errorName(err)});
            },
            .close_tab => self.requestClose(self.tabs.activeIndex()),
            .next_tab => self.tabs.cycle(1),
            .prev_tab => self.tabs.cycle(-1),
            .split_right => self.splitFocused(.right),
            .split_down => self.splitFocused(.bottom),
            .next_pane => self.tabs.cyclePane(1),
            .prev_pane => self.tabs.cyclePane(-1),
            .toggle_sidebar => self.sidebar.toggle(),
            .toggle_files => self.files.toggle(),
            .find_in_files => self.files.openSearch(self.now),
            .open_settings => _ = self.tabs.open("settings") catch {},
            .clear => if (self.tabs.current()) |t| t.vtable.onCtrl(t.ptr, 'l'),
            .add_project => self.folder_pick_requested = true,
            .add_project_here => self.addProject(self.currentCwd()),
            .save => self.tabCommand(.save),
            .undo => self.tabCommand(.undo),
            .redo => self.tabCommand(.redo),
            .toggle_view => self.tabCommand(.toggle_view),
            .new_web_tab => _ = self.tabs.openWith("web", .{}) catch |err| {
                std.log.err("could not open a website tab: {s}", .{@errorName(err)});
            },
            .open_location => self.tabCommand(.open_location),
            .web_reload => self.tabCommand(.reload),
            .web_back => self.tabCommand(.back),
            .web_forward => self.tabCommand(.forward),
        }
        self.invalidate();
    }

    fn tabCommand(self: *App, cmd: tab_mod.Command) void {
        const t = self.tabs.current() orelse return;
        _ = t.vtable.command(t.ptr, cmd);
    }

    fn paletteSources(self: *App) palette_mod.Sources {
        return .{ .tabs = &self.tabs, .history = &self.history, .projects = &self.projects, .cwd = self.currentCwd() };
    }

    /// Carries out what the user picked in the palette.
    fn executePick(self: *App, pick: palette_mod.Pick) void {
        // The file listing dies with the palette: a file's path is read first.
        var path_buf: [1024]u8 = undefined;
        const file_path: ?[]const u8 = switch (pick) {
            .open_file => |t| self.palette.filePath(t.id, &path_buf),
            else => null,
        };
        self.palette.accept();
        switch (pick) {
            .none => {},
            .action => |a| self.perform(a),
            .open_file => |t| if (file_path) |p| {
                self.openFile(p);
                self.goTo(t.goto);
            },
            .focus_tab => |t| if (self.tabs.focus(t.id)) self.goTo(t.goto),
            .goto_line => |g| self.goTo(g),
            .select_tab => |i| self.tabs.activate(i),
            .run_history => |i| {
                if (i >= self.history.entries.items.len) return;
                // Typed into the active terminal (a fresh one if the current tab is not one).
                var t = self.tabs.current();
                if (t == null or !std.mem.eql(u8, t.?.kind, "terminal")) {
                    t = if (self.tabs.open("terminal")) |idx| self.tabs.items()[idx] else |_| null;
                }
                if (t) |tab| {
                    tab.vtable.onEdit(tab.ptr, .select_all); // replaces whatever was typed
                    tab.vtable.onText(tab.ptr, self.history.entries.items[i]);
                    tab.vtable.onEdit(tab.ptr, .insert_newline);
                }
            },
            .set_accent => |i| if (i < theme.accent_options.len) {
                theme.setAccent(i);
                config.get().setAccent(.{ .named = @intCast(i) });
                config.get().save();
            },
        }
        self.invalidate();
    }

    /// Puts the current editor's caret on a line (and column) from a
    /// quick-open `:line:col` suffix; nothing without one.
    fn goTo(self: *App, g: palette_mod.Goto) void {
        if (g.line == 0) return;
        const t = self.tabs.current() orelse return;
        _ = t.vtable.goTo(t.ptr, g.line, g.col);
    }

    /// What tabs asked for since the last tick (`tab_mod.Request`): a
    /// website tab's context menu sending its selection to a shell, to the
    /// agent, or opening an address.
    fn serveRequests(self: *App) void {
        if (self.env.requests.items.len == 0) return;
        // Taken as a whole first: serving one may queue another, for the next tick.
        var list = self.env.requests;
        self.env.requests = .empty;
        defer list.deinit(self.gpa);
        for (list.items) |r| {
            defer r.free(self.gpa);
            switch (r) {
                .open_url => |url| _ = self.tabs.openWith("web", .{ .url = url }) catch |err| {
                    std.log.err("could not open a website tab: {s}", .{@errorName(err)});
                },
                .send_to_shell => |text| if (self.shellTab()) |t| {
                    t.vtable.paste(t.ptr, text);
                    if (self.env.host) |h| h.focusApp();
                },
                .ask_agent => |q| if (self.shellTab()) |t| {
                    if (TerminalTab.fromTab(t)) |term| term.askAgent(q.label, q.question);
                    if (self.env.host) |h| h.focusApp();
                },
            }
        }
        self.invalidate();
    }

    /// A shell of the row on show, brought to the front, for text sent from
    /// another tab: the active tab when it is one, else the first in the
    /// focused pane, else a new one. Null when none could be opened.
    fn shellTab(self: *App) ?tab_mod.Tab {
        if (self.tabs.current()) |t| if (std.mem.eql(u8, t.kind, "terminal")) return t;
        for (self.tabs.items()) |t| {
            if (std.mem.eql(u8, t.kind, "terminal")) {
                _ = self.tabs.focus(t.uid);
                return t;
            }
        }
        self.newShellIn(self.tabs.groupId());
        const t = self.tabs.current() orelse return null;
        return if (std.mem.eql(u8, t.kind, "terminal")) t else null;
    }

    fn newTerminal(self: *App) void {
        // With a resource or a project on show, ⌘T means another shell in its folder.
        const gid = self.tabs.groupId();
        if (self.projects.findResource(gid)) |f| return self.openShell(f.resource);
        self.newShellIn(gid);
    }

    /// A new pane on `side` of the focused one, with a shell in the current
    /// directory. Nothing changes if the pane could not be split or the
    /// shell not started.
    fn splitFocused(self: *App, side: tab_mod.Side) void {
        const cwd = self.currentCwd();
        const p = self.tabs.splitPane(side) catch |err| {
            std.log.err("could not split the pane: {s}", .{@errorName(err)});
            return;
        };
        _ = self.tabs.openWith("terminal", .{ .cwd = cwd }) catch |err| {
            std.log.err("could not open terminal tab: {s}", .{@errorName(err)});
            self.tabs.dropIfEmpty(p.id);
        };
        self.invalidate();
    }

    /// A secondary click on a tab: its menu, with the rows that apply to it.
    fn openTabMenu(self: *App, m: tabbar_mod.MenuRequest) void {
        const p = self.tabs.paneOf(m.uid) orelse return;
        const i = p.indexOf(m.uid) orelse return;
        const n = p.tabs.items.len;
        self.overlay.openTabMenu(m.uid, m.x, m.y, .{
            .renamable = self.tabs.canRename(m.uid),
            .has_path = self.tabPath(m.uid) != null,
            .document = if (self.tabs.byUid(m.uid)) |t| t.vtable.path(t.ptr).len > 0 else false,
            .others = n - 1,
            .to_right = n - 1 - i,
        });
    }

    /// The path a tab stands for: its document, else its directory; null
    /// for a tab with neither (Settings, a website).
    fn tabPath(self: *App, uid: u32) ?[]const u8 {
        const t = self.tabs.byUid(uid) orelse return null;
        const doc = t.vtable.path(t.ptr);
        if (doc.len > 0) return doc;
        const dir = t.vtable.cwd(t.ptr);
        return if (dir.len > 0) dir else null;
    }

    /// The tab menu's "Copy Path" / "Copy Relative Path": the latter is
    /// relative to the project the path belongs to, else to the folder the
    /// files panel shows ("." for that folder itself; a path under neither
    /// is copied as it is).
    fn copyTabPath(self: *App, uid: u32, relative: bool) void {
        const path = self.tabPath(uid) orelse return;
        var text: []const u8 = path;
        if (relative) {
            const base: []const u8 = if (self.projects.containing(path)) |p| p.root else self.files.rootPath();
            if (base.len > 0) {
                text = paths.relativeTo(base, path);
                if (text.len == 0) text = ".";
            }
        }
        self.env.setClipboard(text);
    }

    /// Which other tabs of a strip "Close Others" / "Close to the Right" mean.
    const CloseScope = enum { others, right };

    /// The tab menu's "Close Others" / "Close to the Right": closes the
    /// other tabs of the strip right away, or asks once when any of them
    /// has work that would be lost.
    fn closeMany(self: *App, uid: u32, scope: CloseScope) void {
        const p = self.tabs.paneOf(uid) orelse return;
        const keep = p.indexOf(uid) orelse return;
        const from: usize = if (scope == .right) keep + 1 else 0;
        var count: usize = 0;
        var at_risk: usize = 0;
        var why_buf: [160]u8 = undefined;
        var why: []const u8 = "";
        for (p.tabs.items[from..], from..) |t, i| {
            if (i == keep) continue;
            count += 1;
            var buf: [160]u8 = undefined;
            const w = t.vtable.closeWarning(t.ptr, &buf) orelse continue;
            at_risk += 1;
            if (why.len == 0) {
                const n = @min(w.len, why_buf.len);
                @memcpy(why_buf[0..n], w[0..n]);
                why = why_buf[0..n];
            }
        }
        if (count == 0) return;
        if (at_risk == 0) return self.closeManyNow(uid, scope);
        var heading_buf: [96]u8 = undefined;
        const heading = switch (scope) {
            .others => if (count == 1) "Close the other tab?" else std.fmt.bufPrint(&heading_buf, "Close the other {d} tabs?", .{count}) catch "Close the other tabs?",
            .right => if (count == 1) "Close the tab to the right?" else std.fmt.bufPrint(&heading_buf, "Close the {d} tabs to the right?", .{count}) catch "Close the tabs to the right?",
        };
        // One busy tab: its own sentence. More: how many.
        var reason_buf: [200]u8 = undefined;
        const reason = if (at_risk == 1) why else std.fmt.bufPrint(&reason_buf, "{d} of them have work that would be lost.", .{at_risk}) catch why;
        const kind: overlay_mod.ConfirmKind = if (scope == .right) .close_right else .close_others;
        self.overlay.openConfirmAction(kind, uid, heading, reason, "Close");
        self.invalidate();
    }

    /// Closes the other tabs of the strip (all of them, or those after the
    /// kept one), background shells and all. The kept tab stays, so its
    /// pane does too.
    fn closeManyNow(self: *App, uid: u32, scope: CloseScope) void {
        const g = self.tabs.group();
        const p = self.tabs.paneOf(uid) orelse return;
        var i = p.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (p.tabs.items[i].uid == uid) {
                if (scope == .right) break;
                continue;
            }
            self.tabs.closeIn(g, p, i);
        }
        self.keepShowingSomething();
        self.invalidate();
    }

    /// The tab menu's "Split Right": a new pane on that side of the tab's
    /// own, with a shell in the tab's directory — what ⌘D does for the
    /// focused pane, so the tab is brought forward first.
    fn splitBeside(self: *App, uid: u32, side: tab_mod.Side) void {
        if (!self.tabs.focus(uid)) return;
        self.splitFocused(side);
    }

    /// The tab menu's "Split & Move" → a side: the tab moves into a new pane
    /// on that side of its own. A tab alone in its pane has nothing to move
    /// away from, so it gets a new shell beside it instead.
    fn splitTab(self: *App, uid: u32, side: tab_mod.Side) void {
        const p = self.tabs.paneOf(uid) orelse return;
        if (!self.tabs.moveTabToNewPane(uid, p.id, side)) {
            _ = self.tabs.focus(uid);
            self.splitFocused(side);
        }
        self.invalidate();
    }

    pub fn selectTab(self: *App, index: usize) void {
        // ⌘9 always means "last tab", like browsers.
        const n = self.tabs.items().len;
        if (n == 0) return;
        self.tabs.activate(if (index >= 8) n - 1 else @min(index, n - 1));
        self.invalidate();
    }

    /// Closes a tab of the focused pane's strip, asking first when it has
    /// work that would be lost (a running command, unsent input, unsaved
    /// changes …).
    fn requestClose(self: *App, index: usize) void {
        const items = self.tabs.items();
        if (index >= items.len) return;
        const t = items[index];
        var why_buf: [160]u8 = undefined;
        if (t.vtable.closeWarning(t.ptr, &why_buf)) |why| {
            var title_buf: [96]u8 = undefined;
            self.overlay.openConfirm(t.uid, t.title(&title_buf), why);
        } else self.closeTab(index);
        self.invalidate();
    }

    fn closeTab(self: *App, index: usize) void {
        self.tabs.close(index);
        self.keepShowingSomething();
        self.invalidate();
    }

    /// Before quitting: true when a tab has work that would be lost. That
    /// tab is brought forward with its close confirmation, so the user can
    /// save (⌘S), close it, or cancel — the quit itself is cancelled.
    pub fn confirmUnsaved(self: *App) bool {
        for (self.tabs.groups.items) |g| {
            for (g.layout.owned.items) |p| {
                for (p.tabs.items) |t| {
                    var why_buf: [160]u8 = undefined;
                    if (t.vtable.closeWarning(t.ptr, &why_buf) == null) continue;
                    self.closeByUid(t.uid);
                    return true;
                }
            }
        }
        return false;
    }

    /// Carries out what the user chose in a context menu or one of its boxes.
    fn applyOverlay(self: *App, out: overlay_mod.Outcome) void {
        switch (out) {
            .rename_tab => |uid| if (self.tabs.byUid(uid)) |t| {
                var buf: [96]u8 = undefined;
                self.overlay.openRename(.tab, uid, t.title(&buf));
            },
            .close_tab => |uid| self.closeByUid(uid),
            .close_others => |uid| self.closeMany(uid, .others),
            .close_right => |uid| self.closeMany(uid, .right),
            .close_others_confirmed => |uid| self.closeManyNow(uid, .others),
            .close_right_confirmed => |uid| self.closeManyNow(uid, .right),
            .split_tab => |st| self.splitTab(st.uid, st.side),
            .split_beside => |st| self.splitBeside(st.uid, st.side),
            .copy_tab_path => |c| self.copyTabPath(c.uid, c.relative),
            .reveal_tab => |uid| if (self.tabPath(uid)) |path| {
                _ = desktop.revealInFinder(path);
            },
            .renamed => |r| {
                // The name lives in the overlay's editor: copy it before closing.
                self.tabs.rename(r.uid, r.name);
                self.overlay.close();
            },
            .close_confirmed => |uid| if (self.tabs.focus(uid)) {
                if (self.tabs.indexOf(uid)) |i| self.closeTab(i);
            },
            .discard_confirmed => self.files.discardConfirmed(),
            .replace_confirmed => self.files.replaceConfirmed(),
            .list_picked => |i| self.files.menuPicked(i),
            .rename_project => |pid| if (self.projects.find(pid)) |p| {
                self.overlay.openRename(.project, pid, p.name);
            },
            .project_renamed => |r| {
                self.renameProject(r.id, r.name);
                self.overlay.close();
            },
            .new_shells => |pid| self.newShellGroup(pid),
            .remove_project => |pid| self.removeProject(pid),
            .rename_resource => |rid| if (self.projects.findResource(rid)) |f| {
                self.overlay.openRename(.resource, rid, f.resource.name);
            },
            .resource_renamed => |r| {
                self.renameResource(r.id, r.name);
                self.overlay.close();
            },
            .remove_resource => |rid| self.removeResource(rid),
            .set_icon => |t| if (self.iconSlot(t.subject, t.id)) |slot| {
                self.overlay.openIcons(t.subject, t.id, slot.*);
            },
            .icon_picked => |pk| {
                // The name is a static string: no copy needed before closing.
                self.setIcon(pk.subject, pk.id, pk.icon);
                self.overlay.close();
            },
            .open_externally => _ = desktop.openExternally(self.files.menuPath()),
            .open_with => |app| desktop.openWith(app, self.files.menuPath()),
            .reveal_in_finder => _ = desktop.revealInFinder(self.files.menuPath()),
            .copy_path => |c| self.copyPath(c.absolute),
            .name_file => |kind| self.askName(kind),
            .file_named => |f| self.fileNamed(f.kind, f.name),
            .delete_file => self.askDelete(),
            .delete_confirmed => self.deleteConfirmed(),
        }
        self.invalidate();
    }

    // ── files panel: its menu ───────────────────────────────────────────
    /// A secondary click in the files panel: the menu for its path, with
    /// the applications that open it in the "Open with" submenu.
    fn openFileMenu(self: *App, m: files_mod.FileMenu) void {
        const path = self.files.menuPath();
        const apps: []const desktop.App = desktop.appsFor(self.gpa, path) catch &.{};
        defer desktop.freeApps(self.gpa, apps);
        var rows: std.ArrayList(overlay_mod.SubItem) = .empty;
        defer rows.deinit(self.gpa);
        for (apps) |a| rows.append(self.gpa, .{ .label = a.name, .value = a.path }) catch break;
        self.overlay.openFileMenu(m.kind, m.x, m.y, rows.items);
    }

    /// "Copy path" (relative to the folder on show) / "Copy absolute path".
    fn copyPath(self: *App, absolute: bool) void {
        const path = self.files.menuPath();
        var text: []const u8 = path;
        if (!absolute) {
            text = paths.relativeTo(self.files.rootPath(), path);
            if (text.len == 0) text = sys.basename(path);
        }
        self.env.setClipboard(text);
    }

    /// The name box for the menu's path: a new name for it, or the name
    /// of a new file or folder inside it.
    fn askName(self: *App, kind: overlay_mod.NameKind) void {
        const path = self.files.menuPath();
        const is_dir = sys.isDirectory(self.gpa, path);
        var hint_buf: [200]u8 = undefined;
        var shown_buf: [512]u8 = undefined;
        const hint: []const u8 = switch (kind) {
            .rename => "It stays where it is; only the name changes.",
            .new_file, .new_folder => std.fmt.bufPrint(&hint_buf, "Inside {s}.", .{sys.abbreviateHome(path, &shown_buf)}) catch "Inside this folder.",
        };
        const file_kind: overlay_mod.FileKind = if (std.mem.eql(u8, path, self.files.rootPath())) .root else if (is_dir) .folder else .file;
        self.overlay.openName(kind, file_kind, if (kind == .rename) sys.basename(path) else "", hint);
    }

    /// The name box confirmed: renames the path, or creates the file or
    /// folder, and shows the result in the tree. A bad name or a clash
    /// keeps the box open with the reason.
    fn fileNamed(self: *App, kind: overlay_mod.NameKind, raw: []const u8) void {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (paths.nameProblem(name)) |why| return self.overlay.setNameError(why);
        const target = self.files.menuPath();
        const dir = if (kind == .rename) sys.dirname(target) else target;
        const dest = paths.join(self.gpa, dir, name) catch return;
        defer self.gpa.free(dest);
        var failed: ?anyerror = null;
        switch (kind) {
            .rename => if (!std.mem.eql(u8, dest, target)) self.renamePath(target, dest) catch |err| {
                failed = err;
            },
            .new_file => sys.createFile(self.gpa, dest) catch |err| {
                failed = err;
            },
            .new_folder => sys.createDir(self.gpa, dest) catch |err| {
                failed = err;
            },
        }
        if (failed) |err| {
            std.log.err("{s} {s}: {s}", .{ @tagName(kind), dest, @errorName(err) });
            return self.overlay.setNameError(if (err == error.Exists) "Something with that name is there already." else switch (kind) {
                .rename => "It could not be renamed.",
                .new_file => "The file could not be created.",
                .new_folder => "The folder could not be created.",
            });
        }
        self.overlay.close();
        self.files.refresh(self.now);
        self.files.reveal(dest);
        if (kind == .new_file) self.openFile(dest);
        self.invalidate();
    }

    /// Renames or moves a path on disk and lets what refers to it follow:
    /// the tabs showing it (or something under it) and the pinned resources.
    fn renamePath(self: *App, old: []const u8, new: []const u8) !void {
        try sys.renamePath(self.gpa, old, new);
        self.relocateTabs(old, new);
        if (self.projects.relocate(old, new)) self.projects.save();
    }

    fn relocateTabs(self: *App, old: []const u8, new: []const u8) void {
        for (self.tabs.groups.items) |*g| {
            for (g.layout.owned.items) |p| {
                for (p.tabs.items) |t| {
                    const cur = t.vtable.path(t.ptr);
                    if (cur.len == 0 or !paths.isUnder(old, cur)) continue;
                    const fresh = std.mem.concat(self.gpa, u8, &.{ new, cur[old.len..] }) catch continue;
                    defer self.gpa.free(fresh);
                    t.vtable.relocate(t.ptr, fresh);
                }
            }
        }
    }

    /// The menu's "Delete": asks first. The Trash keeps what goes.
    fn askDelete(self: *App) void {
        const path = self.files.menuPath();
        const is_dir = sys.isDirectory(self.gpa, path);
        var heading_buf: [160]u8 = undefined;
        const heading = std.fmt.bufPrint(&heading_buf, "Delete “{s}”?", .{sys.basename(path)}) catch "Delete this?";
        const reason: []const u8 = if (is_dir) "The folder and everything in it go to the Trash." else "It goes to the Trash, where it can be put back.";
        self.overlay.openConfirmAction(.delete_file, 0, heading, reason, "Delete");
    }

    fn deleteConfirmed(self: *App) void {
        const path = self.files.menuPath();
        desktop.trash(path) catch |err| {
            std.log.err("could not move {s} to the Trash: {s}", .{ path, @errorName(err) });
            return;
        };
        self.closeTabsShowing(path);
        self.files.refresh(self.now);
        self.invalidate();
    }

    /// Closes the viewers of a deleted file (or of the files of a deleted
    /// folder), except those holding unsaved changes.
    fn closeTabsShowing(self: *App, path: []const u8) void {
        for (self.tabs.groups.items) |*g| {
            var again = true;
            while (again) {
                again = false;
                const list = g.layout.panes();
                panes: for (list.slice()) |p| {
                    for (p.tabs.items, 0..) |t, i| {
                        const cur = t.vtable.path(t.ptr);
                        if (cur.len == 0 or !paths.isUnder(path, cur)) continue;
                        var why_buf: [160]u8 = undefined;
                        if (t.vtable.closeWarning(t.ptr, &why_buf) != null) continue;
                        self.tabs.closeIn(g, p, i);
                        again = true;
                        break :panes;
                    }
                }
            }
        }
        self.keepShowingSomething();
    }

    // ── files panel: drag & drop ────────────────────────────────────────
    /// The path being dragged from the files panel, if any.
    fn draggedFile(self: *App) ?[]const u8 {
        const d = self.panes.drag orelse return null;
        if (d.kind != .file or self.file_drag.items.len == 0) return null;
        return self.file_drag.items;
    }

    /// A press on a files-panel row travelled: the path goes along with
    /// the pointer as a ghost, and the tree, the sidebar and the panes say
    /// where it would land.
    fn startFileDrag(self: *App, path: []const u8) void {
        self.file_drag.clearRetainingCapacity();
        self.file_drag.appendSlice(self.gpa, path) catch return;
        self.panes.drag = tabbar_mod.fileDrag(&self.ui, sys.basename(path));
    }

    /// The dragged path was let go on a folder of the tree: it moves there.
    fn moveDroppedInto(self: *App, dir: []const u8) void {
        const src = self.file_drag.items;
        if (src.len == 0) return;
        const dest = paths.join(self.gpa, dir, sys.basename(src)) catch return;
        defer self.gpa.free(dest);
        self.renamePath(src, dest) catch |err| {
            std.log.err("could not move {s} into {s}: {s}", .{ src, dir, @errorName(err) });
            return;
        };
        self.files.refresh(self.now);
        self.files.reveal(dest);
        self.invalidate();
    }

    /// The dragged path was let go on the sidebar: a file is pinned to the
    /// project it landed on (else the selected one, else the one whose
    /// folder holds it), a folder joins it as a group of shells.
    fn pinDropped(self: *App, drop: sidebar_mod.FileDrop) void {
        const path = self.file_drag.items;
        if (path.len == 0) return;
        const p: ?*projects_mod.Project = if (drop.gid) |gid|
            (if (gid == tab_mod.TabManager.default_group) null else (self.projects.find(gid) orelse return))
        else if (self.selected_project) |sid|
            self.projects.find(sid)
        else
            self.projects.containing(path);
        if (sys.isDirectory(self.gpa, path)) {
            _ = self.projects.addShells(p, path) catch return;
        } else _ = self.projects.addFile(p, path) catch return;
        self.showPinned(p);
    }

    /// The dragged path was let go over a strip or a pane: a file opens in
    /// its viewer there, a folder as a shell in it — before a tab, at the
    /// end of a pane's tabs, or in a new pane on the side it was dropped.
    fn openDroppedAt(self: *App, target: tabbar_mod.DropTarget) void {
        const path = self.file_drag.items;
        if (path.len == 0) return;
        const is_dir = sys.isDirectory(self.gpa, path);
        switch (target) {
            .strip => |s| {
                _ = self.tabs.focusPane(s.pane);
                if (self.openDropped(path, is_dir)) |uid| _ = self.tabs.moveTab(uid, s.pane, s.index);
            },
            .zone => |z| if (z.side) |side| {
                // A viewer already open moves over; anything else opens in the new pane.
                if (!is_dir) if (self.uidShowing(path)) |uid| {
                    if (!self.tabs.moveTabToNewPane(uid, z.pane, side)) _ = self.tabs.focus(uid);
                    self.invalidate();
                    return;
                };
                _ = self.tabs.focusPane(z.pane);
                const p = self.tabs.splitPane(side) catch |err| {
                    std.log.err("could not split the pane: {s}", .{@errorName(err)});
                    return;
                };
                _ = self.openDropped(path, is_dir);
                self.tabs.dropIfEmpty(p.id);
            } else {
                _ = self.tabs.focusPane(z.pane);
                if (self.openDropped(path, is_dir)) |uid| {
                    const to = self.tabs.paneById(z.pane) orelse return;
                    _ = self.tabs.moveTab(uid, z.pane, to.tabs.items.len);
                }
            },
        }
        self.invalidate();
    }

    /// Opens a dropped path in the focused pane: a folder as a shell in
    /// it, a file in its viewer (or brings its tab forward). The tab's uid.
    fn openDropped(self: *App, path: []const u8, is_dir: bool) ?u32 {
        if (is_dir) {
            const idx = self.tabs.openWith("terminal", .{ .cwd = path }) catch |err| {
                std.log.err("could not open terminal tab: {s}", .{@errorName(err)});
                return null;
            };
            return self.tabs.items()[idx].uid;
        }
        self.openFile(path);
        return self.uidShowing(path);
    }

    /// The tab of the group on show that shows `path`, if one does.
    fn uidShowing(self: *App, path: []const u8) ?u32 {
        for (self.tabs.group().layout.owned.items) |p| {
            for (p.tabs.items) |t| {
                if (std.mem.eql(u8, t.vtable.path(t.ptr), path)) return t.uid;
            }
        }
        return null;
    }

    /// Brings a tab of any pane or group forward and asks to close it.
    fn closeByUid(self: *App, uid: u32) void {
        if (!self.tabs.focus(uid)) return;
        if (self.tabs.indexOf(uid)) |i| self.requestClose(i);
        self.invalidate();
    }

    /// Never leave the screen empty: a row whose last tab closed hands over
    /// to the default group, and an empty default group starts a shell.
    fn keepShowingSomething(self: *App) void {
        if (self.tabs.items().len > 0) return;
        const default_group = tab_mod.TabManager.default_group;
        if (self.tabs.groupId() != default_group) self.tabs.show(default_group) catch {};
        if (self.tabs.items().len == 0) _ = self.tabs.open("terminal") catch {};
        self.invalidate();
    }

    /// Directory of the active tab, or the last one seen.
    pub fn currentCwd(self: *App) []const u8 {
        if (self.tabs.current()) |t| {
            const dir = t.vtable.cwd(t.ptr);
            if (dir.len > 0 and !std.mem.eql(u8, self.last_cwd.items, dir)) {
                self.last_cwd.clearRetainingCapacity();
                self.last_cwd.appendSlice(self.gpa, dir) catch {};
            }
        }
        if (self.last_cwd.items.len == 0) return self.env.launch_cwd;
        return self.last_cwd.items;
    }

    // ── projects ────────────────────────────────────────────────────────
    pub fn addProject(self: *App, root: []const u8) void {
        if (root.len == 0) return;
        const p = self.projects.add(root) catch |err| {
            std.log.err("could not add project: {s}", .{@errorName(err)});
            return;
        };
        p.open = true;
        self.selected_project = p.id;
        self.projects.save();
        self.sidebar.collapsed = false;
        self.invalidate();
    }

    /// Opens a file in the viewer that claims it — by its first bytes, then
    /// its extension — or focuses the tab already showing it in any pane of
    /// the group on show.
    pub fn openFile(self: *App, path: []const u8) void {
        if (self.tabs.focusPath(path)) {
            self.invalidate();
            return;
        }
        // An unreadable file still gets a tab: the text viewer says why.
        const head = sys.readFileHead(self.gpa, path, filetype.sniff_bytes) catch null;
        defer if (head) |h| if (h.data.len > 0) self.gpa.free(h.data);
        const kind = self.tabs.kindForFile(path, if (head) |h| h.data else "") orelse {
            std.log.err("no viewer for {s}", .{path});
            return;
        };
        _ = self.tabs.openWith(kind.name, .{ .path = path }) catch |err| {
            std.log.err("could not open {s} as {s}: {s}", .{ path, kind.name, @errorName(err) });
        };
        self.invalidate();
    }

    /// A Search match: opens (or focuses) the file and selects the match.
    fn openFileAt(self: *App, o: files_mod.OpenAt) void {
        self.openFile(o.path);
        const t = self.tabs.current() orelse return;
        if (!std.mem.eql(u8, t.vtable.path(t.ptr), o.path)) return;
        t.vtable.selectSpan(t.ptr, o.line, o.col, o.len);
    }

    /// The files panel's "+": pins the file as a resource of the project
    /// its folder belongs to, else of the default project.
    fn pinFile(self: *App, path: []const u8) void {
        const p = self.projects.containing(path);
        _ = self.projects.addFile(p, path) catch return;
        self.showPinned(p);
    }

    /// After pinning: the project unfolds (and is the selected one) so the
    /// new resource is in view.
    fn showPinned(self: *App, p: ?*projects_mod.Project) void {
        if (p) |proj| {
            proj.open = true;
            self.selected_project = proj.id;
        } else self.sidebar.default_open = true;
        self.projects.save();
        self.invalidate();
    }

    /// Puts a resource's own tabs in the strip. A file resource starts with
    /// its viewer, a shell group with one shell; clicking the resource that
    /// is already on show steps through its tabs.
    fn openResource(self: *App, rid: u32) void {
        const f = self.projects.findResource(rid) orelse return;
        if (f.project) |p| self.selected_project = p.id;
        const again = self.tabs.groupId() == rid;
        self.tabs.show(rid) catch |err| {
            std.log.err("could not show resource tabs: {s}", .{@errorName(err)});
            return;
        };
        switch (f.resource.kind) {
            .file => if (again and self.tabs.indexOfPath(f.resource.path) != null) self.tabs.cycle(1) else self.openFile(f.resource.path),
            .shells => if (self.tabs.items().len == 0) self.openShell(f.resource) else if (again) self.tabs.cycle(1),
        }
        self.invalidate();
    }

    /// One more shell among a resource's tabs, started in its folder.
    fn openShell(self: *App, r: *const projects_mod.Resource) void {
        self.tabs.show(r.id) catch |err| {
            std.log.err("could not show resource tabs: {s}", .{@errorName(err)});
            return;
        };
        _ = self.tabs.openWith("terminal", .{ .cwd = r.dir() }) catch |err| {
            std.log.err("could not open terminal tab: {s}", .{@errorName(err)});
            return;
        };
        self.invalidate();
    }

    // ── input ───────────────────────────────────────────────────────────
    pub fn onMouseMove(self: *App, x: f32, y: f32) void {
        self.ui.mx = x;
        self.ui.my = y;
        self.ui.mouse_inside = true;
        self.invalidate();
    }

    pub fn onMouseLeave(self: *App) void {
        self.ui.mouse_inside = false;
        self.invalidate();
    }

    pub fn onMouseDown(self: *App, x: f32, y: f32, clicks: u32, mods: ui_mod.Mods) void {
        // ⌃-click is a secondary click, as everywhere on macOS.
        if (mods.ctrl and !mods.cmd) return self.onRightMouseDown(x, y, mods);
        self.onMouseMove(x, y);
        self.ui.down = true;
        self.ui.pressed = true;
        self.ui.click_count = clicks;
        self.ui.press_x = x;
        self.ui.press_y = y;
        self.ui.mods = mods;
    }

    pub fn onMouseUp(self: *App, x: f32, y: f32) void {
        self.onMouseMove(x, y);
        self.ui.down = false;
        self.ui.released = true;
    }

    /// Secondary click (right button, ⌃-click, two-finger tap): opens
    /// context menus. Nothing is pressed or dragged.
    pub fn onRightMouseDown(self: *App, x: f32, y: f32, mods: ui_mod.Mods) void {
        self.onMouseMove(x, y);
        self.ui.right_pressed = true;
        self.ui.mods = mods;
    }

    pub fn onScroll(self: *App, x: f32, y: f32, dx: f32, dy: f32) void {
        self.onMouseMove(x, y);
        self.ui.scroll_x += dx;
        self.ui.scroll_y += dy;
    }

    // Keyboard input goes to the palette while it is open, else to the tab
    // menu / boxes while one is open, else to the files panel's commit
    // message while it has the focus, else to the active tab.
    pub fn onText(self: *App, utf8: []const u8) void {
        if (self.palette.open) {
            self.palette.onText(utf8);
        } else if (self.overlay.isOpen()) {
            self.overlay.onText(utf8);
        } else if (self.files.hasFocus()) {
            self.files.onText(utf8);
        } else if (self.tabs.current()) |t| t.vtable.onText(t.ptr, utf8);
        self.invalidate();
    }

    pub fn onMarkedText(self: *App, utf8: []const u8) void {
        if (self.palette.open) {
            self.palette.onMarkedText(utf8);
        } else if (self.overlay.isOpen()) {
            self.overlay.onMarkedText(utf8);
        } else if (self.files.hasFocus()) {
            self.files.onMarkedText(utf8);
        } else if (self.tabs.current()) |t| t.vtable.onMarkedText(t.ptr, utf8);
        self.invalidate();
    }

    pub fn onEdit(self: *App, cmd: EditCommand) void {
        if (self.palette.open) {
            if (self.palette.onEdit(cmd)) |pick| self.executePick(pick);
        } else if (self.overlay.isOpen()) {
            if (self.overlay.onEdit(cmd)) |out| self.applyOverlay(out);
        } else if (self.files.hasFocus()) {
            self.files.onEdit(cmd);
        } else if (self.tabs.current()) |t| t.vtable.onEdit(t.ptr, cmd);
        self.invalidate();
    }

    pub fn onCtrl(self: *App, key: u8) void {
        if (self.palette.open) {
            if (self.palette.onCtrl(key)) |pick| self.executePick(pick);
            self.invalidate();
            return;
        }
        if (self.overlay.isOpen()) {
            if (self.overlay.onCtrl(key)) |out| self.applyOverlay(out);
            self.invalidate();
            return;
        }
        if (key == '\t') {
            self.perform(if (self.ui.mods.shift) .prev_tab else .next_tab);
            return;
        }
        if (self.files.hasFocus()) {
            self.files.onCtrl(key);
            self.invalidate();
            return;
        }
        if (self.tabs.current()) |t| t.vtable.onCtrl(t.ptr, key);
        self.invalidate();
    }

    pub fn onPaste(self: *App, utf8: []const u8) void {
        if (self.palette.open) {
            self.palette.onPaste(utf8);
        } else if (self.overlay.isOpen()) {
            self.overlay.onPaste(utf8);
        } else if (self.files.hasFocus()) {
            self.files.paste(utf8);
        } else if (self.tabs.current()) |t| t.vtable.paste(t.ptr, utf8);
        self.invalidate();
    }

    /// Returns the text to put on the clipboard (caller frees), if any.
    pub fn onCopy(self: *App, cut: bool) ?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        if (self.palette.open) {
            const sel = self.palette.editor.selectedText();
            if (sel.len == 0) return null;
            out.appendSlice(self.gpa, sel) catch return null;
            if (cut) _ = self.palette.editor.deleteSelection();
        } else if (self.overlay.mode == .rename) {
            const sel = self.overlay.editor.selectedText();
            if (sel.len == 0) return null;
            out.appendSlice(self.gpa, sel) catch return null;
            if (cut) _ = self.overlay.editor.deleteSelection();
        } else if (self.files.hasFocus()) {
            if (!self.files.copy(&out, cut)) {
                out.deinit(self.gpa);
                return null;
            }
        } else {
            const t = self.tabs.current() orelse return null;
            if (!t.vtable.copy(t.ptr, &out, cut)) {
                out.deinit(self.gpa);
                return null;
            }
        }
        self.invalidate();
        return out.toOwnedSlice(self.gpa) catch null;
    }

    pub fn hasMarkedText(self: *App) bool {
        if (self.palette.open) return self.palette.editor.marked.items.len > 0;
        if (self.overlay.mode == .rename) return self.overlay.editor.marked.items.len > 0;
        if (self.files.hasFocus()) return self.files.hasMarkedText();
        const t = self.tabs.current() orelse return false;
        return t.vtable.hasMarkedText(t.ptr);
    }

    pub fn caretRect(self: *App) draw.Rect {
        if (self.palette.open) return self.palette.caret;
        if (self.overlay.mode == .rename) return self.overlay.caret;
        if (self.files.hasFocus()) return self.files.caretRect();
        const t = self.tabs.current() orelse return .{};
        return t.vtable.caretRect(t.ptr);
    }
};

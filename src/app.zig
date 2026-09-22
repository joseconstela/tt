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
const palette_mod = @import("ui/palette.zig");
const overlay_mod = @import("ui/overlay.zig");
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
    open_settings,
    clear,
    command_palette,
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
    /// When macOS's appearance was last read (mode "system" polls it).
    appearance_checked: f64 = 0,

    pub fn create(gpa: std.mem.Allocator, opts: LaunchOptions, layer: objc.id, setClipboard: *const fn ([]const u8) void) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        // The settings first: the theme has to be right before anything draws.
        config.init(gpa);
        appearance.applyAccent(config.get().accent);
        theme.setScheme(appearance.resolve(config.get().mode));

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
            // unless CONCH_WORKSPACE names a file of their own.
            .workspace = workspace_mod.Workspace.init(gpa, opts.script_path == null and sys.getenv("CONCH_SELFTEST") == null),
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
        config.get().save();
        config.deinit();
        self.palette.deinit();
        self.overlay.deinit();
        self.projects.deinit();
        self.files.deinit();
        self.history.deinit();
        self.last_cwd.deinit(self.gpa);
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
        self.keepShowingSomething();
        // A menu or box about a tab that has since closed itself has nothing left to act on.
        if (self.overlay.isOpen() and self.overlay.subject == .tab and self.tabs.byUid(self.overlay.id) == null) self.overlay.close();
        if (self.overlay.tick(now)) self.invalidate();
        if (self.files.tick(now)) self.invalidate();
        if (self.palette.tick(now)) self.invalidate();
        // Mode "system": follow macOS when it switches between light and dark.
        const cfg = config.get();
        if (cfg.mode == .system and now - self.appearance_checked >= 2) {
            self.appearance_checked = now;
            if (appearance.apply(.system)) self.invalidate();
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
        // sidebar header, spanning the files panel too), the panes under it.
        // The panels' resize grips are drawn on top of it.
        const side_w = self.sidebar.currentWidth();
        const files_w = self.files.currentWidth();
        const main_x: f32 = if (self.sidebar.collapsed) 0 else side_w;
        const lights_inset = if (self.sidebar.collapsed) self.chrome.inset_left + 8 else 0;
        const bar: draw.Rect = .{ .x = main_x, .y = 0, .w = self.width - main_x, .h = theme.header_h };
        const content: draw.Rect = .{ .x = side_w, .y = theme.header_h, .w = self.width - side_w - files_w, .h = self.height - theme.header_h };
        const files_rect: draw.Rect = .{ .x = self.width - files_w, .y = theme.header_h, .w = files_w, .h = self.height - theme.header_h };

        // The sidebar handles its splitter before anything else claims the mouse.
        var ctx: sidebar_mod.Context = .{ .projects = &self.projects, .tabs = &self.tabs };
        if (self.projects.containing(cwd)) |p| ctx.current_project = p.id;
        const side = self.sidebar.draw(ui, self.height, self.chrome, ctx);
        self.applySidebar(side);

        // The files panel owns the splitter on its left edge, so it goes before the panes.
        const fr = self.files.draw(ui, files_rect, true);
        if (fr.open_file) |path| self.openFile(path);
        if (fr.pin_file) |path| self.pinFile(path);
        if (fr.confirm) |c| self.overlay.openConfirmAction(.git_discard, 0, c.heading, c.reason, "Discard");

        // The panes: each one's strip, its active tab, the dividers, and a
        // tab being dragged. Moves are applied to the tab manager inside.
        const pv = self.panes.draw(ui, &self.tabs, bar, content, lights_inset, self.files.visible, self.chrome.window_focused);
        if (pv.menu) |m| self.overlay.openMenu(.tab, m.uid, m.x, m.y, self.tabs.canRename(m.uid));
        if (pv.new_tab) |pane| {
            _ = self.tabs.focusPane(pane);
            self.perform(.new_tab);
        }
        if (pv.new_web_tab) |pane| {
            _ = self.tabs.focusPane(pane);
            self.perform(.new_web_tab);
        }
        if (pv.toggle_files) self.perform(.toggle_files);
        if (pv.changed) self.invalidate();

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
            self.overlay.openMenu(subject, m.id, m.x, m.y, true);
        }
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
            .tab => null,
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
        // Any command closes the palette (⌘K toggles it) and whatever the
        // tab menu had open.
        if (action != .command_palette) self.palette.close();
        self.overlay.close();
        switch (action) {
            .command_palette => self.palette.toggle(.{ .tabs = &self.tabs, .history = &self.history }),
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

    /// Carries out what the user picked in the palette.
    fn executePick(self: *App, pick: palette_mod.Pick) void {
        self.palette.close();
        switch (pick) {
            .action => |a| self.perform(a),
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

    /// The tab menu's "Split Right / Down": the tab moves into a new pane
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
            .split_tab => |st| self.splitTab(st.uid, if (st.down) .bottom else .right),
            .renamed => |r| {
                // The name lives in the overlay's editor: copy it before closing.
                self.tabs.rename(r.uid, r.name);
                self.overlay.close();
            },
            .close_confirmed => |uid| if (self.tabs.focus(uid)) {
                if (self.tabs.indexOf(uid)) |i| self.closeTab(i);
            },
            .discard_confirmed => self.files.discardConfirmed(),
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
        }
        self.invalidate();
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

    /// The files panel's "+": pins the file as a resource of the project
    /// its folder belongs to, else of the default project.
    fn pinFile(self: *App, path: []const u8) void {
        const p = self.projects.containing(path);
        _ = self.projects.addFile(p, path) catch return;
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

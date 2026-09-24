//! The user's settings: appearance, the model APIs they have set up and
//! what the features use, kept in `~/.tt/config.yml`. The file is
//! written by the Settings tab and meant to be edited by hand too, so it is
//! a small, readable subset of YAML: two levels of `key: value` mappings and
//! a list of mappings for the APIs. Unknown keys are ignored, so older
//! builds can read newer files.
//!
//!   ui:
//!     style: system         # dark | light | system | eink | eink-color, or a
//!                           # terminal theme's id (dracula, solarized-light …)
//!     accent: amber         # amber | peach | lime | rose | "#RRGGBB"
//!     compact: false        # tighter spacing, full-width terminal (Settings › Mode)
//!     nt_mode: false        # non-technical mode (a placeholder: changes nothing yet)
//!   screens:                # the style to use while the window is on a display
//!     - name: DASUNG Paperlike   # the display's name in System Settings
//!       style: eink              # as ui.style (older files say `mode:`)
//!   apis:                   # (older files say `agents:`; both are read)
//!     - name: Claude
//!       provider: anthropic # anthropic | openai | google | mistral | ollama | custom
//!       model: claude-sonnet-5
//!       api_key: "sk-ant-…"
//!       base_url: https://api.anthropic.com
//!       default: true
//!   features:
//!     command_fallback_agent: Claude      # an API by name; absent = off
//!     command_fallback_prompt: "…"
//!     explain_agent: Claude               # an API by name; absent = off
//!     explain_prompt: "…"
//!     explain_in_notebooks: true          # "Explain" under a failed notebook cell too
//!     fix_agent: auto                     # auto | off | a coding agent id (claude, codex …)
//!     fix_prompt: "…"
//!     fix_in_notebooks: true              # "Fix with agent" under a failed notebook cell too
//!   notebooks:
//!     strip_outputs: false                # save .ipynb files without their outputs
//!     share_schema: true                  # agents asked from a notebook get variable names + types
//!   browser:
//!     open_links: tt                      # tt | browser: where ⌘/⌃-clicked links open
//!     keep_cookies: false                 # false clears cookies and site data on close
//!     homepage: ""                        # blank = a white page
//!     do_not_track: false
//!     camera: ask                         # ask | allow | block, for websites that ask
//!     microphone: ask
//!     notifications: ask
//!   sites:                  # what a website was allowed or refused
//!     - origin: https://teams.microsoft.com
//!       camera: allow                     # allow | block; absent = the default above
//!       microphone: allow
//!       notifications: allow
//!   physical:               # tt's own use of the camera (Settings › Physical interactions)
//!     camera: ""                          # a camera's name; blank = the macOS default
//!     blur_when_away: false               # blur the window while nobody looks at it
//!     blur_after: 3                       # seconds of looking away before it blurs
//!     sensitivity: normal                 # relaxed | normal | strict
//!     center_yaw: 0                       # from Calibrate: the head while looking at
//!     center_pitch: 0                     #   the screen, in degrees …
//!     face_size: 0                        # … and its size (0 = not calibrated)
//!     neck: 0
//!   voice:                  # voice commands (Settings › Physical interactions › Voice)
//!     enabled: false                      # listen for the trigger word while tt is open
//!     microphone: ""                      # a microphone's name; blank = the macOS default
//!     language: ""                        # what is spoken (en-US, es-ES …); blank = the Mac's language
//!     trigger: tt                         # the word that starts a command
//!
//! In the code an "agent" is one of the APIs (a model at a provider); the
//! coding agents installed on the Mac live in `coding_agents.zig`.
//!
//! One instance lives for the whole app (`get()`); saves are debounced
//! (`touch`) so typing into a field does not rewrite the file per keystroke.
const std = @import("std");
const sys = @import("sys.zig");
const themes = @import("ui/themes.zig");
const posture = @import("physical/posture.zig");

/// The UI's style (Settings › Style): tt's own dark or light palette,
/// following macOS between them, e-ink (black on white, for e-paper
/// panels) and its colour variant, or one of the classic terminal themes.
pub const Mode = union(enum) {
    dark,
    light,
    system,
    eink,
    eink_color,
    /// A terminal theme: its index in `themes.all`.
    theme: u8,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .dark => "tt Dark",
            .light => "tt Light",
            .system => "System",
            .eink => "E-ink",
            .eink_color => "E-ink colour",
            .theme => |i| themes.all[i].name,
        };
    }

    /// How the style is written in the config file: a hyphen where the tag
    /// has an underscore, so hand-editors see `eink-color`; a theme by id.
    pub fn configName(self: Mode) []const u8 {
        return switch (self) {
            .eink_color => "eink-color",
            .theme => |i| themes.all[i].id,
            else => @tagName(self),
        };
    }

    pub fn eql(a: Mode, b: Mode) bool {
        return std.meta.eql(a, b);
    }

    fn parse(s: []const u8) ?Mode {
        if (std.ascii.eqlIgnoreCase(s, "eink-color") or std.ascii.eqlIgnoreCase(s, "eink-colour")) return .eink_color;
        inline for (.{ "dark", "light", "system", "eink", "eink_color" }) |name| {
            if (std.ascii.eqlIgnoreCase(s, name)) return @field(Mode, name);
        }
        if (themes.find(s)) |i| return .{ .theme = @intCast(i) };
        return null;
    }
};

/// The accent colour: one of the design's named options, or any colour
/// written into the file by hand.
pub const Accent = union(enum) {
    named: u8,
    custom: u24,
};

pub const accent_names = [_][]const u8{ "amber", "peach", "lime", "rose" };

/// Where an agent's model runs. The main hosted APIs, Ollama for local
/// models, and "custom" for anything speaking the OpenAI chat protocol
/// (Groq, DeepSeek, OpenRouter, LM Studio …).
pub const Provider = enum {
    anthropic,
    openai,
    google,
    mistral,
    ollama,
    custom,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "Anthropic",
            .openai => "OpenAI",
            .google => "Google",
            .mistral => "Mistral",
            .ollama => "Ollama",
            .custom => "OpenAI-compatible",
        };
    }

    /// A reasonable model to start from; the user edits it.
    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "claude-sonnet-5",
            .openai => "gpt-5",
            .google => "gemini-2.5-pro",
            .mistral => "mistral-large-latest",
            .ollama => "llama3.2",
            .custom => "",
        };
    }

    pub fn defaultBaseUrl(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "https://api.anthropic.com",
            .openai => "https://api.openai.com/v1",
            .google => "https://generativelanguage.googleapis.com",
            .mistral => "https://api.mistral.ai/v1",
            .ollama => "http://localhost:11434",
            .custom => "",
        };
    }

    /// Whether the service wants an API key (Ollama does not; a custom
    /// endpoint may or may not).
    pub fn needsKey(self: Provider) bool {
        return self != .ollama;
    }

    /// One line on what to type into the key / URL fields.
    pub fn hint(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "Key from console.anthropic.com.",
            .openai => "Key from platform.openai.com.",
            .google => "Key from aistudio.google.com.",
            .mistral => "Key from console.mistral.ai.",
            .ollama => "Runs locally: no key. Models come from `ollama pull`.",
            .custom => "Any OpenAI-compatible endpoint; the key is optional.",
        };
    }

    fn parse(s: []const u8) ?Provider {
        inline for (std.meta.fields(Provider)) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// One configured agent: a model at a provider, with what it needs to be
/// reached. The strings are owned by the config.
pub const Agent = struct {
    /// Runtime identity (not saved): stable across edits and removals, so
    /// the UI can keep a focus or a confirmation on one agent.
    uid: u32 = 0,
    name: []u8 = "",
    provider: Provider = .anthropic,
    model: []u8 = "",
    api_key: []u8 = "",
    base_url: []u8 = "",
    is_default: bool = false,

    fn deinit(self: *Agent, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.model);
        gpa.free(self.api_key);
        gpa.free(self.base_url);
        self.* = .{};
    }
};

/// Settings of the features that use the agents. Each prompt is what the
/// agent is told first; blank means the feature's default.
pub const Features = struct {
    /// Name of the agent that turns unrecognised terminal commands into a
    /// conversation, null = off.
    command_fallback_agent: ?[]u8 = null,
    command_fallback_prompt: []u8 = "",
    /// Name of the agent behind a failed block's "Explain", null = off.
    explain_agent: ?[]u8 = null,
    explain_prompt: []u8 = "",
    /// "Explain" is offered under a failed notebook cell as well.
    explain_notebooks: bool = true,
    /// The coding agent "Fix with agent" launches: a `coding_agents` id,
    /// "off", or "" (= `fix_auto`) for whichever one is installed.
    fix_agent: []u8 = "",
    fix_prompt: []u8 = "",
    /// "Fix with agent" is offered under a failed notebook cell as well.
    fix_notebooks: bool = true,

    pub const fix_auto = "";
    pub const fix_off = "off";

    /// True when "Fix with agent" is switched off outright.
    pub fn fixOff(self: *const Features) bool {
        return std.mem.eql(u8, self.fix_agent, fix_off);
    }

    pub fn fixAuto(self: *const Features) bool {
        return self.fix_agent.len == 0;
    }
};

/// Notebook tabs (see tabs/notebook_tab.zig).
pub const Notebooks = struct {
    /// Save .ipynb files without their outputs (the outputs stay on
    /// screen and in the workspace file).
    strip_outputs: bool = false,
    /// Tell the agent the names and types of the kernel's variables when
    /// it is asked from a notebook. Values never leave the kernel.
    share_schema: bool = true,
};

/// Website tabs (see tabs/web_tab.zig).
pub const Browser = struct {
    /// Where a link ⌘- or ⌃-clicked in a command's output, a Markdown
    /// preview, a notebook or a file opens: a website tab in tt (the
    /// default) or the system's default browser.
    open_links: LinkTarget = .tt,
    /// Keep cookies and site data between launches. Off (the default) uses a
    /// private, in-memory store that is cleared when the app closes.
    keep_cookies: bool = false,
    /// The address new website tabs open on. Blank starts them on a white,
    /// empty page with the address bar ready.
    homepage: []u8 = "",
    /// Send the "Do Not Track" request header with page loads.
    do_not_track: bool = false,
    /// What a website gets when it asks for the camera, the microphone or
    /// to show notifications, unless `sites` says otherwise for it.
    camera: Permission = .ask,
    microphone: Permission = .ask,
    notifications: Permission = .ask,

    fn deinit(self: *Browser, gpa: std.mem.Allocator) void {
        gpa.free(self.homepage);
        self.* = .{};
    }

    pub fn default(self: *const Browser, f: SiteFeature) Permission {
        return switch (f) {
            .camera => self.camera,
            .microphone => self.microphone,
            .notifications => self.notifications,
        };
    }
};

/// Settings › Physical interactions: what tt itself does with the camera
/// (see physical/camera_controller.zig).
pub const Physical = struct {
    /// The camera, by the name macOS gives it; blank = the macOS default.
    camera: []u8 = "",
    /// Blur the window while nobody looks at it.
    blur_when_away: bool = false,
    /// Seconds of looking away before the blur comes.
    blur_after: f32 = 3,
    /// How far the head may turn or nod before it counts as looking away.
    sensitivity: posture.Sensitivity = .normal,
    /// The head and shoulders while looking at the screen (Calibrate).
    calibration: posture.Calibration = .{},

    fn deinit(self: *Physical, gpa: std.mem.Allocator) void {
        gpa.free(self.camera);
        self.* = .{};
    }
};

/// Settings › Physical interactions › Voice: voice commands, started by a
/// trigger word (see physical/voice_controller.zig).
pub const Voice = struct {
    /// Listen for the trigger word while tt is open.
    enabled: bool = false,
    /// The microphone, by the name macOS gives it; blank = the macOS default.
    microphone: []u8 = "",
    /// The word that starts a command; blank = "tt".
    trigger: []u8 = "",
    /// The language spoken, as a code ("en-US"); blank = the Mac's language.
    language: []u8 = "",

    fn deinit(self: *Voice, gpa: std.mem.Allocator) void {
        gpa.free(self.microphone);
        gpa.free(self.language);
        gpa.free(self.trigger);
        self.* = .{};
    }
};

/// Where links open (`Browser.open_links`).
pub const LinkTarget = enum {
    /// A new website tab, next to the current one.
    tt,
    /// The default web browser, outside tt.
    browser,

    fn parse(s: []const u8) ?LinkTarget {
        const v = std.mem.trim(u8, s, " \t\"'");
        if (std.ascii.eqlIgnoreCase(v, "tt") or std.ascii.eqlIgnoreCase(v, "inside") or std.ascii.eqlIgnoreCase(v, "tab")) return .tt;
        if (std.ascii.eqlIgnoreCase(v, "browser") or std.ascii.eqlIgnoreCase(v, "system") or std.ascii.eqlIgnoreCase(v, "default") or std.ascii.eqlIgnoreCase(v, "outside")) return .browser;
        return null;
    }
};

/// What a website may do with something only the user can grant: ask each
/// time (a bar under the address bar), or a standing yes or no.
pub const Permission = enum {
    ask,
    allow,
    block,

    fn parse(s: []const u8) ?Permission {
        const v = std.mem.trim(u8, s, " \t\"'");
        if (std.ascii.eqlIgnoreCase(v, "ask")) return .ask;
        if (std.ascii.eqlIgnoreCase(v, "allow") or std.ascii.eqlIgnoreCase(v, "allowed")) return .allow;
        if (std.ascii.eqlIgnoreCase(v, "block") or std.ascii.eqlIgnoreCase(v, "blocked") or std.ascii.eqlIgnoreCase(v, "deny")) return .block;
        return null;
    }

    pub fn label(self: Permission) []const u8 {
        return switch (self) {
            .ask => "Ask",
            .allow => "Allow",
            .block => "Block",
        };
    }
};

/// What a website has to ask for (Settings › Browser).
pub const SiteFeature = enum {
    camera,
    microphone,
    notifications,

    pub fn label(self: SiteFeature) []const u8 {
        return switch (self) {
            .camera => "Camera",
            .microphone => "Microphone",
            .notifications => "Notifications",
        };
    }
};

/// A website's own answers, by origin ("https://teams.microsoft.com",
/// scheme://host[:port] as the browser means it). `.ask` = no answer kept:
/// the default in `Browser` applies.
pub const Site = struct {
    origin: []u8 = "",
    camera: Permission = .ask,
    microphone: Permission = .ask,
    notifications: Permission = .ask,

    fn deinit(self: *Site, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        self.* = .{};
    }

    pub fn get(self: *const Site, f: SiteFeature) Permission {
        return switch (f) {
            .camera => self.camera,
            .microphone => self.microphone,
            .notifications => self.notifications,
        };
    }

    fn slot(self: *Site, f: SiteFeature) *Permission {
        return switch (f) {
            .camera => &self.camera,
            .microphone => &self.microphone,
            .notifications => &self.notifications,
        };
    }

    fn empty(self: *const Site) bool {
        return self.camera == .ask and self.microphone == .ask and self.notifications == .ask;
    }
};

/// A display the window should change its mode on: the theme follows the
/// screen the window sits on, so an e-ink panel can have e-ink and the
/// laptop's own display stay dark. Matched by the display's name (what
/// System Settings › Displays calls it). Only tt's window changes; macOS's
/// own appearance is never touched.
pub const Screen = struct {
    name: []u8 = "",
    mode: Mode = .system,

    fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.* = .{};
    }
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    /// `~/.tt/config.yml` (null when there is no home directory).
    path: ?[]u8 = null,
    mode: Mode = .system,
    accent: Accent = .{ .named = 0 },
    /// Compact mode: smaller spacing everywhere, square corners, the
    /// terminal across the full width (`theme.setCompact`).
    compact: bool = false,
    /// "NT mode" (non-technical): only offered while compact mode is off.
    /// A placeholder for now; nothing reads it yet.
    nt_mode: bool = false,
    /// Displays with a mode of their own; the window follows whichever
    /// one it is on, and `mode` applies on any other.
    screens: std.ArrayList(Screen) = .empty,
    /// Websites' remembered answers (camera, microphone, notifications).
    sites: std.ArrayList(Site) = .empty,
    agents: std.ArrayList(Agent) = .empty,
    features: Features = .{},
    notebooks: Notebooks = .{},
    browser: Browser = .{},
    physical: Physical = .{},
    voice: Voice = .{},
    /// Bumped on every change, so views can notice edits made elsewhere.
    version: u64 = 0,
    /// A change waiting to be written (see `touch` / `saveIfDue`).
    dirty: bool = false,
    dirty_since: f64 = 0,
    next_uid: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Config {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Config) void {
        for (self.agents.items) |*a| a.deinit(self.gpa);
        self.agents.deinit(self.gpa);
        for (self.screens.items) |*sc| sc.deinit(self.gpa);
        self.screens.deinit(self.gpa);
        for (self.sites.items) |*st| st.deinit(self.gpa);
        self.sites.deinit(self.gpa);
        if (self.features.command_fallback_agent) |s| self.gpa.free(s);
        self.gpa.free(self.features.command_fallback_prompt);
        if (self.features.explain_agent) |s| self.gpa.free(s);
        self.gpa.free(self.features.explain_prompt);
        self.gpa.free(self.features.fix_agent);
        self.gpa.free(self.features.fix_prompt);
        self.browser.deinit(self.gpa);
        self.physical.deinit(self.gpa);
        self.voice.deinit(self.gpa);
        if (self.path) |p| self.gpa.free(p);
        self.* = .{ .gpa = self.gpa };
    }

    // ── agents ──────────────────────────────────────────────────────────
    pub fn findAgent(self: *Config, uid: u32) ?*Agent {
        for (self.agents.items) |*a| {
            if (a.uid == uid) return a;
        }
        return null;
    }

    pub fn findAgentByName(self: *Config, name: []const u8) ?*Agent {
        for (self.agents.items) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    /// The agent marked as default, else the first one.
    pub fn defaultAgent(self: *Config) ?*Agent {
        for (self.agents.items) |*a| {
            if (a.is_default) return a;
        }
        if (self.agents.items.len > 0) return &self.agents.items[0];
        return null;
    }

    /// A new agent at `provider`, prefilled with its defaults and a name
    /// that is not taken yet. The first agent becomes the default.
    pub fn addAgent(self: *Config, provider: Provider) !*Agent {
        var name_buf: [64]u8 = undefined;
        var name: []const u8 = provider.label();
        var n: u32 = 2;
        while (self.findAgentByName(name) != null) : (n += 1) {
            name = std.fmt.bufPrint(&name_buf, "{s} {d}", .{ provider.label(), n }) catch provider.label();
        }
        const a: Agent = .{
            .uid = self.takeUid(),
            .name = try self.gpa.dupe(u8, name),
            .provider = provider,
            .model = try self.gpa.dupe(u8, provider.defaultModel()),
            .api_key = "",
            .base_url = try self.gpa.dupe(u8, provider.defaultBaseUrl()),
            .is_default = self.agents.items.len == 0,
        };
        try self.agents.append(self.gpa, a);
        self.changed();
        return &self.agents.items[self.agents.items.len - 1];
    }

    pub fn removeAgent(self: *Config, uid: u32) void {
        for (self.agents.items, 0..) |*a, i| {
            if (a.uid != uid) continue;
            const was_default = a.is_default;
            a.deinit(self.gpa);
            _ = self.agents.orderedRemove(i);
            if (was_default and self.agents.items.len > 0) self.agents.items[0].is_default = true;
            self.changed();
            return;
        }
    }

    pub fn setDefaultAgent(self: *Config, uid: u32) void {
        for (self.agents.items) |*a| a.is_default = a.uid == uid;
        self.changed();
    }

    /// Switches an agent to another provider. Fields still at the old
    /// provider's defaults (or empty) take the new provider's, edited ones
    /// are kept.
    pub fn setProvider(self: *Config, a: *Agent, provider: Provider) void {
        if (a.provider == provider) return;
        const old = a.provider;
        a.provider = provider;
        if (a.model.len == 0 or std.mem.eql(u8, a.model, old.defaultModel())) self.setString(&a.model, provider.defaultModel());
        if (a.base_url.len == 0 or std.mem.eql(u8, a.base_url, old.defaultBaseUrl())) self.setString(&a.base_url, provider.defaultBaseUrl());
        self.changed();
    }

    // ── owned strings ───────────────────────────────────────────────────
    /// Replaces an owned string of the config (an agent's field, a feature
    /// setting) and marks the config changed.
    pub fn setString(self: *Config, slot: *[]u8, text: []const u8) void {
        if (std.mem.eql(u8, slot.*, text)) return;
        const copy = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(slot.*);
        slot.* = copy;
        self.changed();
    }

    pub fn setOptString(self: *Config, slot: *?[]u8, text: ?[]const u8) void {
        const new = text orelse {
            if (slot.*) |old| {
                self.gpa.free(old);
                slot.* = null;
                self.changed();
            }
            return;
        };
        if (slot.*) |old| {
            if (std.mem.eql(u8, old, new)) return;
        }
        const copy = self.gpa.dupe(u8, new) catch return;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
        self.changed();
    }

    pub fn setMode(self: *Config, mode: Mode) void {
        if (self.mode.eql(mode)) return;
        self.mode = mode;
        self.changed();
    }

    pub fn setCompact(self: *Config, on: bool) void {
        if (self.compact == on) return;
        self.compact = on;
        self.changed();
    }

    pub fn setNtMode(self: *Config, on: bool) void {
        if (self.nt_mode == on) return;
        self.nt_mode = on;
        self.changed();
    }

    pub fn setAccent(self: *Config, accent: Accent) void {
        if (std.meta.eql(self.accent, accent)) return;
        self.accent = accent;
        self.changed();
    }

    // ── screens ─────────────────────────────────────────────────────────
    /// The mode set for the display called `name`, if any.
    pub fn screenMode(self: *const Config, name: []const u8) ?Mode {
        for (self.screens.items) |sc| {
            if (std.mem.eql(u8, sc.name, name)) return sc.mode;
        }
        return null;
    }

    /// The mode the window should be in while on the display called
    /// `name` (null = no display known, e.g. headless): the display's own
    /// setting, else the general one.
    pub fn modeOn(self: *const Config, name: ?[]const u8) Mode {
        const n = name orelse return self.mode;
        return self.screenMode(n) orelse self.mode;
    }

    /// Gives the display called `name` a mode of its own, or takes it away
    /// (null: the display follows the general mode again).
    pub fn setScreenMode(self: *Config, name: []const u8, mode: ?Mode) void {
        for (self.screens.items, 0..) |*sc, i| {
            if (!std.mem.eql(u8, sc.name, name)) continue;
            const m = mode orelse {
                sc.deinit(self.gpa);
                _ = self.screens.orderedRemove(i);
                self.changed();
                return;
            };
            if (sc.mode.eql(m)) return;
            sc.mode = m;
            self.changed();
            return;
        }
        const m = mode orelse return;
        const copy = self.gpa.dupe(u8, name) catch return;
        self.screens.append(self.gpa, .{ .name = copy, .mode = m }) catch {
            self.gpa.free(copy);
            return;
        };
        self.changed();
    }

    // ── websites' permissions ───────────────────────────────────────────
    pub fn findSite(self: *const Config, origin: []const u8) ?*Site {
        for (self.sites.items) |*st| {
            if (std.mem.eql(u8, st.origin, origin)) return st;
        }
        return null;
    }

    /// The answer `origin` has kept for `f` (`.ask` = none).
    pub fn siteDecision(self: *const Config, origin: []const u8, f: SiteFeature) Permission {
        const st = self.findSite(origin) orelse return .ask;
        return st.get(f);
    }

    /// What `origin` gets for `f`: its own answer, else the default.
    pub fn permissionFor(self: *const Config, origin: []const u8, f: SiteFeature) Permission {
        const own = self.siteDecision(origin, f);
        return if (own != .ask) own else self.browser.default(f);
    }

    /// Keeps an answer for `origin` (`.ask` forgets it). A site left with
    /// no answer at all is dropped from the list.
    pub fn setSitePermission(self: *Config, origin: []const u8, f: SiteFeature, p: Permission) void {
        if (origin.len == 0) return;
        for (self.sites.items, 0..) |*st, i| {
            if (!std.mem.eql(u8, st.origin, origin)) continue;
            if (st.get(f) == p) return;
            st.slot(f).* = p;
            if (st.empty()) {
                st.deinit(self.gpa);
                _ = self.sites.orderedRemove(i);
            }
            self.changed();
            return;
        }
        if (p == .ask) return;
        const copy = self.gpa.dupe(u8, origin) catch return;
        var st: Site = .{ .origin = copy };
        st.slot(f).* = p;
        self.sites.append(self.gpa, st) catch {
            self.gpa.free(copy);
            return;
        };
        self.changed();
    }

    /// Takes back the answers `origin` has kept for `features`: the site
    /// asks again next time. A site left with no answer is dropped.
    /// (`origin` may point into the site's own entry.)
    pub fn removeSitePermissions(self: *Config, origin: []const u8, features: []const SiteFeature) void {
        for (self.sites.items, 0..) |*st, i| {
            if (!std.mem.eql(u8, st.origin, origin)) continue;
            var any = false;
            for (features) |f| {
                if (st.get(f) == .ask) continue;
                st.slot(f).* = .ask;
                any = true;
            }
            if (st.empty()) {
                st.deinit(self.gpa);
                _ = self.sites.orderedRemove(i);
            }
            if (any) self.changed();
            return;
        }
    }

    /// `removeSitePermissions` for every site.
    pub fn removeAllSitePermissions(self: *Config, features: []const SiteFeature) void {
        var any = false;
        var i = self.sites.items.len;
        while (i > 0) {
            i -= 1;
            const st = &self.sites.items[i];
            for (features) |f| {
                if (st.get(f) == .ask) continue;
                st.slot(f).* = .ask;
                any = true;
            }
            if (st.empty()) {
                st.deinit(self.gpa);
                _ = self.sites.orderedRemove(i);
            }
        }
        if (any) self.changed();
    }

    pub fn setDefaultPermission(self: *Config, f: SiteFeature, p: Permission) void {
        const slot = switch (f) {
            .camera => &self.browser.camera,
            .microphone => &self.browser.microphone,
            .notifications => &self.browser.notifications,
        };
        if (slot.* == p) return;
        slot.* = p;
        self.changed();
    }

    // ── persistence ─────────────────────────────────────────────────────
    /// Marks the config changed; the write happens on the next `saveIfDue`
    /// after a quiet moment, or on `save`.
    pub fn touch(self: *Config) void {
        self.changed();
    }

    fn changed(self: *Config) void {
        self.version +%= 1;
        self.dirty = true;
    }

    /// Writes a pending change once nothing has changed for a moment.
    pub fn saveIfDue(self: *Config, now: f64) void {
        if (!self.dirty) return;
        if (self.dirty_since == 0) {
            self.dirty_since = now;
            return;
        }
        if (now - self.dirty_since < 0.6) return;
        self.save();
    }

    pub fn save(self: *Config) void {
        self.dirty = false;
        self.dirty_since = 0;
        const path = self.path orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.write(&out) catch return;
        sys.mkdir(self.gpa, sys.dirname(path));
        sys.writeFileAtomic(self.gpa, path, out.items) catch |err| {
            std.log.err("could not save {s}: {s}", .{ path, @errorName(err) });
        };
    }

    /// Reads `~/.tt/config.yml` if there is one. A file that cannot be
    /// read leaves the defaults.
    pub fn load(self: *Config) void {
        self.path = std.fmt.allocPrint(self.gpa, "{s}/.tt/config.yml", .{sys.home()}) catch null;
        const path = self.path orelse return;
        const data = sys.readFileTail(self.gpa, path, 1 << 20) catch return;
        defer self.gpa.free(data);
        self.parse(data) catch |err| {
            std.log.err("could not read {s}: {s}", .{ path, @errorName(err) });
        };
        self.dirty = false;
    }

    fn takeUid(self: *Config) u32 {
        const uid = self.next_uid;
        self.next_uid += 1;
        return uid;
    }

    // ── the YAML subset ─────────────────────────────────────────────────
    pub fn write(self: *const Config, out: *std.ArrayList(u8)) !void {
        const gpa = self.gpa;
        try out.appendSlice(gpa, "# tt settings. Changed from the Settings tab; safe to edit by hand.\n");
        try out.appendSlice(gpa, "ui:\n");
        try out.print(gpa, "  style: {s}   # dark | light | system | eink | eink-color | a theme (Settings › Style)\n", .{self.mode.configName()});
        switch (self.accent) {
            .named => |i| try out.print(gpa, "  accent: {s}   # amber | peach | lime | rose | \"#RRGGBB\"\n", .{accent_names[@min(i, accent_names.len - 1)]}),
            .custom => |rgb| try out.print(gpa, "  accent: \"#{X:0>6}\"   # amber | peach | lime | rose | \"#RRGGBB\"\n", .{rgb}),
        }
        try out.print(gpa, "  compact: {s}   # tighter spacing, full-width terminal (Settings › Mode)\n", .{if (self.compact) "true" else "false"});
        try out.print(gpa, "  nt_mode: {s}   # non-technical mode (not in use yet)\n", .{if (self.nt_mode) "true" else "false"});
        if (self.screens.items.len > 0) {
            try out.appendSlice(gpa, "screens:   # the style to use while the window is on a display\n");
            for (self.screens.items) |sc| {
                try out.appendSlice(gpa, "  - name: ");
                try writeScalar(gpa, out, sc.name);
                try out.print(gpa, "\n    style: {s}\n", .{sc.mode.configName()});
            }
        }
        if (self.agents.items.len == 0) {
            try out.appendSlice(gpa, "apis: []\n");
        } else {
            try out.appendSlice(gpa, "apis:\n");
            for (self.agents.items) |a| {
                try out.appendSlice(gpa, "  - name: ");
                try writeScalar(gpa, out, a.name);
                try out.print(gpa, "\n    provider: {s}\n", .{@tagName(a.provider)});
                try out.appendSlice(gpa, "    model: ");
                try writeScalar(gpa, out, a.model);
                try out.appendSlice(gpa, "\n    api_key: ");
                try writeScalar(gpa, out, a.api_key);
                try out.appendSlice(gpa, "\n    base_url: ");
                try writeScalar(gpa, out, a.base_url);
                try out.append(gpa, '\n');
                if (a.is_default) try out.appendSlice(gpa, "    default: true\n");
            }
        }
        try out.appendSlice(gpa, "features:\n");
        try writeOptField(gpa, out, "command_fallback_agent", self.features.command_fallback_agent);
        try writeField(gpa, out, "command_fallback_prompt", self.features.command_fallback_prompt);
        try writeOptField(gpa, out, "explain_agent", self.features.explain_agent);
        try writeField(gpa, out, "explain_prompt", self.features.explain_prompt);
        try out.print(gpa, "  explain_in_notebooks: {s}\n", .{if (self.features.explain_notebooks) "true" else "false"});
        try writeField(gpa, out, "fix_agent", if (self.features.fixAuto()) "auto" else self.features.fix_agent);
        try writeField(gpa, out, "fix_prompt", self.features.fix_prompt);
        try out.print(gpa, "  fix_in_notebooks: {s}\n", .{if (self.features.fix_notebooks) "true" else "false"});
        try out.appendSlice(gpa, "notebooks:\n");
        try out.print(gpa, "  strip_outputs: {s}\n", .{if (self.notebooks.strip_outputs) "true" else "false"});
        try out.print(gpa, "  share_schema: {s}\n", .{if (self.notebooks.share_schema) "true" else "false"});
        try out.appendSlice(gpa, "browser:\n");
        try out.print(gpa, "  open_links: {s}   # tt | browser: where ⌘/⌃-clicked links open\n", .{@tagName(self.browser.open_links)});
        try out.print(gpa, "  keep_cookies: {s}   # false clears cookies and site data on close\n", .{if (self.browser.keep_cookies) "true" else "false"});
        try writeField(gpa, out, "homepage", self.browser.homepage); // blank = a white page
        try out.print(gpa, "  do_not_track: {s}\n", .{if (self.browser.do_not_track) "true" else "false"});
        try out.print(gpa, "  camera: {s}   # ask | allow | block, for websites that ask\n", .{@tagName(self.browser.camera)});
        try out.print(gpa, "  microphone: {s}\n", .{@tagName(self.browser.microphone)});
        try out.print(gpa, "  notifications: {s}\n", .{@tagName(self.browser.notifications)});
        if (self.sites.items.len > 0) {
            try out.appendSlice(gpa, "sites:   # what a website was allowed or refused; absent = the default above\n");
            for (self.sites.items) |st| {
                try out.appendSlice(gpa, "  - origin: ");
                try writeScalar(gpa, out, st.origin);
                try out.append(gpa, '\n');
                inline for (.{ SiteFeature.camera, SiteFeature.microphone, SiteFeature.notifications }) |f| {
                    const p = st.get(f);
                    if (p != .ask) try out.print(gpa, "    {s}: {s}\n", .{ @tagName(f), @tagName(p) });
                }
            }
        }
        const ph = &self.physical;
        try out.appendSlice(gpa, "physical:   # tt's own use of the camera (Settings › Physical interactions)\n");
        try writeField(gpa, out, "camera", ph.camera); // blank = the macOS default
        try out.print(gpa, "  blur_when_away: {s}\n", .{if (ph.blur_when_away) "true" else "false"});
        try out.print(gpa, "  blur_after: {d}   # seconds\n", .{ph.blur_after});
        try out.print(gpa, "  sensitivity: {s}   # relaxed | normal | strict\n", .{@tagName(ph.sensitivity)});
        try out.print(gpa, "  center_yaw: {d:.1}   # from Calibrate: the head while looking at the screen\n", .{ph.calibration.yaw});
        try out.print(gpa, "  center_pitch: {d:.1}\n", .{ph.calibration.pitch});
        try out.print(gpa, "  face_size: {d:.3}   # 0 = not calibrated\n", .{ph.calibration.face_size});
        try out.print(gpa, "  neck: {d:.3}\n", .{ph.calibration.neck});
        const vo = &self.voice;
        try out.appendSlice(gpa, "voice:   # voice commands (Settings › Physical interactions › Voice)\n");
        try out.print(gpa, "  enabled: {s}\n", .{if (vo.enabled) "true" else "false"});
        try writeField(gpa, out, "microphone", vo.microphone); // blank = the macOS default
        try writeField(gpa, out, "language", vo.language); // blank = the Mac's language
        try writeField(gpa, out, "trigger", if (vo.trigger.len > 0) vo.trigger else "tt");
    }

    fn writeField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
        try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, key);
        try out.appendSlice(gpa, ": ");
        try writeScalar(gpa, out, value);
        try out.append(gpa, '\n');
    }

    /// An optional field is left out when null (absent = off).
    fn writeOptField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: ?[]const u8) !void {
        if (value) |v| try writeField(gpa, out, key, v);
    }

    /// A string as a YAML scalar: bare when it is unambiguous, else
    /// double-quoted with escapes.
    fn writeScalar(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        if (isPlainScalar(s)) return out.appendSlice(gpa, s);
        try out.append(gpa, '"');
        for (s) |ch| switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => try out.append(gpa, ch),
        };
        try out.append(gpa, '"');
    }

    fn isPlainScalar(s: []const u8) bool {
        if (s.len == 0) return false;
        if (s[0] == ' ' or s[s.len - 1] == ' ') return false;
        // Would be read back as something else than a string, or as a mapping.
        switch (s[0]) {
            '"', '\'', '#', '-', '[', ']', '{', '}', '&', '*', '!', '|', '>', '%', '@', '`', '?', ',' => return false,
            else => {},
        }
        for (s, 0..) |ch, i| {
            if (ch < 0x20 or ch == 0x7f) return false;
            if (ch == ':' and (i + 1 == s.len or s[i + 1] == ' ')) return false;
            if (ch == '#' and i > 0 and s[i - 1] == ' ') return false;
        }
        const lower_bool = [_][]const u8{ "true", "false", "yes", "no", "on", "off", "null", "~" };
        for (lower_bool) |w| {
            if (std.ascii.eqlIgnoreCase(s, w)) return false;
        }
        if (std.fmt.parseFloat(f64, s)) |_| return false else |_| {}
        return true;
    }

    fn voiceString(vo: *Voice, key: []const u8) ?*[]u8 {
        if (std.mem.eql(u8, key, "microphone")) return &vo.microphone;
        if (std.mem.eql(u8, key, "trigger")) return &vo.trigger;
        if (std.mem.eql(u8, key, "language")) return &vo.language;
        return null;
    }

    const Section = enum { none, ui, agents, apis, features, screens, notebooks, browser, sites, physical, voice };

    /// Reads the subset `write` produces (plus hand edits of the same
    /// shape). Anything it does not understand is skipped.
    fn parse(self: *Config, data: []const u8) !void {
        var section: Section = .none;
        // Files from when a theme was picked per scheme: the one for the
        // scheme in use becomes the style (see the end).
        var old_dark: ?Mode = null;
        var old_light: ?Mode = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = stripComment(std.mem.trimEnd(u8, raw_line, "\r"));
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            const indent = countIndent(line);
            var body = line[indent..];

            var new_item = false;
            if (std.mem.startsWith(u8, body, "- ") or std.mem.eql(u8, body, "-")) {
                new_item = true;
                body = std.mem.trimStart(u8, body[1..], " ");
            }

            if (indent == 0 and !new_item) {
                const kv = splitKey(body) orelse continue;
                section = std.meta.stringToEnum(Section, kv.key) orelse .none;
                // Files from before the rename to APIs say `agents:`.
                if (section == .agents) section = .apis;
                // `apis: []` and any inline value: nothing to read under it.
                if (kv.value.len > 0) section = .none;
                continue;
            }

            switch (section) {
                .none => {},
                .ui => {
                    const kv = splitKey(body) orelse continue;
                    // `mode:` is what files from before Settings › Style say.
                    if (std.mem.eql(u8, kv.key, "style") or std.mem.eql(u8, kv.key, "mode")) {
                        if (Mode.parse(std.mem.trim(u8, kv.value, "\"' "))) |m| self.mode = m;
                    } else if (std.mem.eql(u8, kv.key, "accent")) {
                        if (parseAccent(kv.value)) |a| self.accent = a;
                    } else if (std.mem.eql(u8, kv.key, "compact")) {
                        self.compact = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "nt_mode")) {
                        self.nt_mode = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "dark_theme")) {
                        old_dark = Mode.parse(std.mem.trim(u8, kv.value, "\"' "));
                    } else if (std.mem.eql(u8, kv.key, "light_theme")) {
                        old_light = Mode.parse(std.mem.trim(u8, kv.value, "\"' "));
                    }
                },
                .features => {
                    const kv = splitKey(body) orelse continue;
                    const f = &self.features;
                    if (std.mem.eql(u8, kv.key, "explain_in_notebooks")) {
                        f.explain_notebooks = isTrue(kv.value);
                        continue;
                    } else if (std.mem.eql(u8, kv.key, "fix_in_notebooks")) {
                        f.fix_notebooks = isTrue(kv.value);
                        continue;
                    }
                    const opt_slot: ?*?[]u8 = if (std.mem.eql(u8, kv.key, "command_fallback_agent")) &f.command_fallback_agent else if (std.mem.eql(u8, kv.key, "explain_agent")) &f.explain_agent else null;
                    if (opt_slot) |slot| {
                        if (kv.value.len > 0 and !isNull(kv.value)) {
                            const v = try unquote(self.gpa, kv.value);
                            defer self.gpa.free(v);
                            self.setOptString(slot, v);
                        }
                        continue;
                    }
                    const slot: ?*[]u8 = if (std.mem.eql(u8, kv.key, "command_fallback_prompt")) &f.command_fallback_prompt else if (std.mem.eql(u8, kv.key, "explain_prompt")) &f.explain_prompt else if (std.mem.eql(u8, kv.key, "fix_agent")) &f.fix_agent else if (std.mem.eql(u8, kv.key, "fix_prompt")) &f.fix_prompt else null;
                    if (slot) |s| {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        // `auto` (and a blank) both mean "whichever is installed".
                        const text = if (s == &f.fix_agent and std.ascii.eqlIgnoreCase(v, "auto")) "" else v;
                        self.setString(s, text);
                    }
                },
                .notebooks => {
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "strip_outputs")) {
                        self.notebooks.strip_outputs = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "share_schema")) {
                        self.notebooks.share_schema = isTrue(kv.value);
                    }
                },
                .browser => {
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "open_links")) {
                        if (LinkTarget.parse(kv.value)) |t| self.browser.open_links = t;
                    } else if (std.mem.eql(u8, kv.key, "keep_cookies")) {
                        self.browser.keep_cookies = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "do_not_track")) {
                        self.browser.do_not_track = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "homepage")) {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(&self.browser.homepage, v);
                    } else if (std.meta.stringToEnum(SiteFeature, kv.key)) |f| {
                        if (Permission.parse(kv.value)) |p| switch (f) {
                            .camera => self.browser.camera = p,
                            .microphone => self.browser.microphone = p,
                            .notifications => self.browser.notifications = p,
                        };
                    }
                },
                .physical => {
                    const kv = splitKey(body) orelse continue;
                    const ph = &self.physical;
                    const bare = std.mem.trim(u8, kv.value, "\"' ");
                    if (std.mem.eql(u8, kv.key, "camera")) {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(&ph.camera, v);
                    } else if (std.mem.eql(u8, kv.key, "blur_when_away")) {
                        ph.blur_when_away = isTrue(kv.value);
                    } else if (std.mem.eql(u8, kv.key, "sensitivity")) {
                        if (posture.Sensitivity.parse(bare)) |v| ph.sensitivity = v;
                    } else if (std.fmt.parseFloat(f32, bare)) |v| {
                        if (!std.math.isFinite(v)) continue;
                        if (std.mem.eql(u8, kv.key, "blur_after")) {
                            ph.blur_after = std.math.clamp(v, 0.5, 600);
                        } else if (std.mem.eql(u8, kv.key, "center_yaw")) {
                            ph.calibration.yaw = std.math.clamp(v, -90, 90);
                        } else if (std.mem.eql(u8, kv.key, "center_pitch")) {
                            ph.calibration.pitch = std.math.clamp(v, -90, 90);
                        } else if (std.mem.eql(u8, kv.key, "face_size")) {
                            ph.calibration.face_size = std.math.clamp(v, 0, 1);
                        } else if (std.mem.eql(u8, kv.key, "neck")) {
                            ph.calibration.neck = std.math.clamp(v, 0, 10);
                        }
                    } else |_| {}
                },
                .voice => {
                    const kv = splitKey(body) orelse continue;
                    const vo = &self.voice;
                    if (std.mem.eql(u8, kv.key, "enabled")) {
                        vo.enabled = isTrue(kv.value);
                    } else if (voiceString(vo, kv.key)) |slot| {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(slot, std.mem.trim(u8, v, " \t"));
                    }
                },
                .sites => {
                    if (new_item) {
                        try self.sites.append(self.gpa, .{});
                        if (body.len == 0) continue;
                    }
                    if (self.sites.items.len == 0) continue;
                    const st = &self.sites.items[self.sites.items.len - 1];
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "origin")) {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(&st.origin, std.mem.trimEnd(u8, v, "/"));
                    } else if (std.meta.stringToEnum(SiteFeature, kv.key)) |f| {
                        if (Permission.parse(kv.value)) |p| st.slot(f).* = p;
                    }
                },
                .agents => unreachable,
                .screens => {
                    if (new_item) {
                        try self.screens.append(self.gpa, .{});
                        if (body.len == 0) continue;
                    }
                    if (self.screens.items.len == 0) continue;
                    const sc = &self.screens.items[self.screens.items.len - 1];
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "name")) {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(&sc.name, v);
                    } else if (std.mem.eql(u8, kv.key, "style") or std.mem.eql(u8, kv.key, "mode")) {
                        if (Mode.parse(std.mem.trim(u8, kv.value, "\"' "))) |m| sc.mode = m;
                    }
                },
                .apis => {
                    if (new_item) {
                        try self.agents.append(self.gpa, .{ .uid = self.takeUid() });
                        if (body.len == 0) continue;
                    }
                    if (self.agents.items.len == 0) continue;
                    const a = &self.agents.items[self.agents.items.len - 1];
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "provider")) {
                        if (Provider.parse(kv.value)) |p| a.provider = p;
                    } else if (std.mem.eql(u8, kv.key, "default")) {
                        a.is_default = isTrue(kv.value);
                    } else {
                        const slot: ?*[]u8 = if (std.mem.eql(u8, kv.key, "name")) &a.name else if (std.mem.eql(u8, kv.key, "model")) &a.model else if (std.mem.eql(u8, kv.key, "api_key")) &a.api_key else if (std.mem.eql(u8, kv.key, "base_url")) &a.base_url else null;
                        if (slot) |s| {
                            const v = try unquote(self.gpa, kv.value);
                            defer self.gpa.free(v);
                            self.setString(s, v);
                        }
                    }
                },
            }
        }
        // A site without an origin or without any answer is noise; an
        // origin listed twice keeps its first entry.
        var si: usize = 0;
        while (si < self.sites.items.len) {
            const st = &self.sites.items[si];
            var dup = false;
            for (self.sites.items[0..si]) |earlier| {
                if (std.mem.eql(u8, earlier.origin, st.origin)) dup = true;
            }
            if (st.origin.len == 0 or st.empty() or dup) {
                st.deinit(self.gpa);
                _ = self.sites.orderedRemove(si);
            } else si += 1;
        }
        // A screen entry without a name matches nothing; a name listed
        // twice keeps its first entry.
        var k: usize = 0;
        while (k < self.screens.items.len) {
            const sc = &self.screens.items[k];
            var dup = false;
            for (self.screens.items[0..k]) |earlier| {
                if (std.mem.eql(u8, earlier.name, sc.name)) dup = true;
            }
            if (sc.name.len == 0 or dup) {
                sc.deinit(self.gpa);
                _ = self.screens.orderedRemove(k);
            } else k += 1;
        }
        // A theme picked for dark (light) mode is the style where that mode was.
        const migrate = struct {
            fn f(m: *Mode, dark: ?Mode, light: ?Mode) void {
                const t = switch (m.*) {
                    .dark => dark,
                    .light => light,
                    else => null,
                } orelse return;
                if (t == .theme) m.* = t;
            }
        }.f;
        migrate(&self.mode, old_dark, old_light);
        for (self.screens.items) |*sc| migrate(&sc.mode, old_dark, old_light);
        // Agents without a name are useless; drop them. Exactly one default.
        var i: usize = 0;
        while (i < self.agents.items.len) {
            if (self.agents.items[i].name.len == 0) {
                self.agents.items[i].deinit(self.gpa);
                _ = self.agents.orderedRemove(i);
            } else i += 1;
        }
        var seen_default = false;
        for (self.agents.items) |*a| {
            if (a.is_default and seen_default) a.is_default = false;
            if (a.is_default) seen_default = true;
        }
        if (!seen_default and self.agents.items.len > 0) self.agents.items[0].is_default = true;
    }

    const KeyValue = struct { key: []const u8, value: []const u8 };

    /// `key: value` → the two halves (value may be empty). Null for a line
    /// without a key.
    fn splitKey(body: []const u8) ?KeyValue {
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == ':' and (i + 1 == body.len or body[i + 1] == ' ' or body[i + 1] == '\t')) break;
            if (body[i] == '"' or body[i] == '\'') return null;
        } else return null;
        const key = std.mem.trim(u8, body[0..i], " \t");
        if (key.len == 0) return null;
        return .{ .key = key, .value = std.mem.trim(u8, body[i + 1 ..], " \t") };
    }

    fn countIndent(line: []const u8) usize {
        var n: usize = 0;
        while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
        return n;
    }

    /// Drops a `# comment` that is not inside quotes.
    fn stripComment(line: []const u8) []const u8 {
        var quote: u8 = 0;
        for (line, 0..) |ch, i| {
            if (quote != 0) {
                if (ch == quote and !(quote == '"' and i > 0 and line[i - 1] == '\\')) quote = 0;
                continue;
            }
            if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (ch == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
                return std.mem.trimEnd(u8, line[0..i], " \t");
            }
        }
        return line;
    }

    /// A scalar's string value: quotes removed and escapes resolved. Owned.
    fn unquote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var i: usize = 1;
            while (i < s.len - 1) : (i += 1) {
                const ch = s[i];
                if (ch == '\\' and i + 1 < s.len - 1) {
                    i += 1;
                    switch (s[i]) {
                        'n' => try out.append(gpa, '\n'),
                        'r' => try out.append(gpa, '\r'),
                        't' => try out.append(gpa, '\t'),
                        '"' => try out.append(gpa, '"'),
                        '\\' => try out.append(gpa, '\\'),
                        '/' => try out.append(gpa, '/'),
                        else => |other| {
                            try out.append(gpa, '\\');
                            try out.append(gpa, other);
                        },
                    }
                } else try out.append(gpa, ch);
            }
            return out.toOwnedSlice(gpa);
        }
        if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var i: usize = 1;
            while (i < s.len - 1) : (i += 1) {
                if (s[i] == '\'' and i + 1 < s.len - 1 and s[i + 1] == '\'') i += 1;
                try out.append(gpa, s[i]);
            }
            return out.toOwnedSlice(gpa);
        }
        if (isNull(s)) return gpa.dupe(u8, "");
        return gpa.dupe(u8, s);
    }

    fn isNull(s: []const u8) bool {
        return std.mem.eql(u8, s, "~") or std.ascii.eqlIgnoreCase(s, "null");
    }

    fn isTrue(s: []const u8) bool {
        const words = [_][]const u8{ "true", "yes", "on", "1" };
        for (words) |w| {
            if (std.ascii.eqlIgnoreCase(s, w)) return true;
        }
        return false;
    }

    fn parseAccent(raw: []const u8) ?Accent {
        const s = std.mem.trim(u8, raw, "\"' ");
        for (accent_names, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(s, n)) return .{ .named = @intCast(i) };
        }
        const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (hex.len != 6) return null;
        const rgb = std.fmt.parseInt(u24, hex, 16) catch return null;
        return .{ .custom = rgb };
    }
};

// ── the single instance ─────────────────────────────────────────────────
var current: Config = undefined;
var ready = false;

/// Loads the settings once, at startup.
pub fn init(gpa: std.mem.Allocator) void {
    current = Config.init(gpa);
    current.load();
    ready = true;
}

pub fn deinit() void {
    if (!ready) return;
    current.deinit();
    ready = false;
}

/// The app's settings. Valid after `init`.
pub fn get() *Config {
    std.debug.assert(ready);
    return &current;
}

// ── tests ───────────────────────────────────────────────────────────────
test "ui: compact and NT mode round-trip, and default to off" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try a.parse("ui:\n  style: dark\n");
    try std.testing.expect(!a.compact and !a.nt_mode);
    a.setCompact(true);
    a.setNtMode(true);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  compact: true") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expect(b.compact and b.nt_mode);
    try b.parse("ui:\n  compact: no\n  nt_mode: off\n");
    try std.testing.expect(!b.compact and !b.nt_mode);
}

test "round trip through the YAML subset" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    a.mode = .light;
    a.accent = .{ .custom = 0x123ABC };
    const claude = try a.addAgent(.anthropic);
    a.setString(&claude.api_key, "sk-ant: \"quoted\" #not a comment\\end");
    const local = try a.addAgent(.ollama);
    a.setString(&local.name, "Local: llama");
    a.setString(&local.model, "llama3.2:latest");
    a.setDefaultAgent(local.uid);
    a.setOptString(&a.features.command_fallback_agent, "Local: llama");
    a.setString(&a.features.command_fallback_prompt, "Line one\nLine two\ttabbed");
    a.setOptString(&a.features.explain_agent, "Anthropic");
    a.setString(&a.features.explain_prompt, "Why did it fail?");
    a.setString(&a.features.fix_agent, "codex");
    a.setString(&a.features.fix_prompt, "Fix: it");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqual(Mode.light, b.mode);
    try std.testing.expectEqual(Accent{ .custom = 0x123ABC }, b.accent);
    try std.testing.expectEqual(@as(usize, 2), b.agents.items.len);
    try std.testing.expectEqualStrings("Anthropic", b.agents.items[0].name);
    try std.testing.expectEqual(Provider.anthropic, b.agents.items[0].provider);
    try std.testing.expectEqualStrings("claude-sonnet-5", b.agents.items[0].model);
    try std.testing.expectEqualStrings("sk-ant: \"quoted\" #not a comment\\end", b.agents.items[0].api_key);
    try std.testing.expectEqualStrings("https://api.anthropic.com", b.agents.items[0].base_url);
    try std.testing.expect(!b.agents.items[0].is_default);
    try std.testing.expectEqualStrings("Local: llama", b.agents.items[1].name);
    try std.testing.expectEqual(Provider.ollama, b.agents.items[1].provider);
    try std.testing.expectEqualStrings("llama3.2:latest", b.agents.items[1].model);
    try std.testing.expectEqualStrings("", b.agents.items[1].api_key);
    try std.testing.expect(b.agents.items[1].is_default);
    try std.testing.expectEqualStrings("Local: llama", b.features.command_fallback_agent.?);
    try std.testing.expectEqualStrings("Line one\nLine two\ttabbed", b.features.command_fallback_prompt);
    try std.testing.expectEqualStrings("Anthropic", b.features.explain_agent.?);
    try std.testing.expectEqualStrings("Why did it fail?", b.features.explain_prompt);
    try std.testing.expectEqualStrings("codex", b.features.fix_agent);
    try std.testing.expectEqualStrings("Fix: it", b.features.fix_prompt);
    try std.testing.expect(b.defaultAgent().? == &b.agents.items[1]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "apis:\n") != null);
}

test "fix_agent: auto is the blank default, off is off, and the defaults write back as auto" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expect(a.features.fixAuto() and !a.features.fixOff());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fix_agent: auto\n") != null);
    // Nothing under features is absent: explain_agent is off, so it is not written.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "explain_agent") == null);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse("features:\n  fix_agent: Auto\n  explain_agent: ~\n");
    try std.testing.expect(b.features.fixAuto());
    try std.testing.expect(b.features.explain_agent == null);
    try b.parse("features:\n  fix_agent: off\n");
    try std.testing.expect(b.features.fixOff());
    try b.parse("features:\n  fix_agent: claude\n");
    try std.testing.expectEqualStrings("claude", b.features.fix_agent);
}

test "styles: a theme by id round-trips; old per-scheme themes become the style" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try a.parse("ui:\n  mode: light\n  light_theme: solarized-light\nscreens:\n  - name: Desk\n    mode: dark\n");
    try std.testing.expectEqualStrings("solarized-light", a.mode.configName());
    // No theme was picked for dark mode: the display stays on tt's own.
    try std.testing.expect(a.modeOn("Desk").eql(.dark));
    a.setScreenMode("Desk", .{ .theme = @intCast(themes.find("dracula").?) });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "style: solarized-light") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqualStrings("Solarized Light", b.mode.label());
    try std.testing.expectEqualStrings("Dracula", b.modeOn("Desk").label());
}

test "e-ink mode parses and round-trips" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try a.parse("ui:\n  mode: E-Ink\n");
    try std.testing.expectEqual(Mode.system, a.mode); // "e-ink" is not a mode name; "eink" is
    try a.parse("ui:\n  mode: eink\n");
    try std.testing.expectEqual(Mode.eink, a.mode);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "style: eink") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqual(Mode.eink, b.mode);
}

test "e-ink colour mode parses (hyphen or underscore) and round-trips with a hyphen" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try a.parse("ui:\n  mode: eink-color\n");
    try std.testing.expectEqual(Mode.eink_color, a.mode);
    try a.parse("ui:\n  mode: EInk-Colour\n");
    try std.testing.expectEqual(Mode.eink_color, a.mode);
    try a.parse("ui:\n  mode: eink_color\n"); // the enum tag spelling is accepted too
    try std.testing.expectEqual(Mode.eink_color, a.mode);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "style: eink-color") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqual(Mode.eink_color, b.mode);
}

test "hand-written file: comments, quotes, empty list, unknown keys" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.parse(
        \\# my settings
        \\ui:
        \\  mode: Dark # trailing comment
        \\  accent: "#ff8800"
        \\  font: something-newer   # unknown, ignored
        \\apis: []
        \\features:
        \\  command_fallback_prompt: 'it''s quoted'
        \\  command_fallback_agent: ~
        \\
    );
    try std.testing.expectEqual(Mode.dark, c.mode);
    try std.testing.expectEqual(Accent{ .custom = 0xFF8800 }, c.accent);
    try std.testing.expectEqual(@as(usize, 0), c.agents.items.len);
    try std.testing.expectEqualStrings("it's quoted", c.features.command_fallback_prompt);
    try std.testing.expect(c.features.command_fallback_agent == null);
    try std.testing.expect(c.defaultAgent() == null);

    // The default when the file says nothing: the first agent. An older
    // file's `agents:` list is read as the APIs.
    var d = Config.init(gpa);
    defer d.deinit();
    try d.parse(
        \\agents:
        \\  -
        \\    name: One
        \\    provider: mistral
        \\  - name: Two
        \\    provider: nonsense
        \\  - provider: openai
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), d.agents.items.len);
    try std.testing.expect(d.agents.items[0].is_default);
    try std.testing.expectEqual(Provider.mistral, d.agents.items[0].provider);
    try std.testing.expectEqualStrings("Two", d.agents.items[1].name);
    try std.testing.expectEqual(Provider.anthropic, d.agents.items[1].provider);
}

test "provider switch keeps edited fields, replaces defaults" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    const a = try c.addAgent(.openai);
    c.setProvider(a, .ollama);
    try std.testing.expectEqualStrings("llama3.2", a.model);
    try std.testing.expectEqualStrings("http://localhost:11434", a.base_url);
    c.setString(&a.model, "mixtral");
    c.setProvider(a, .mistral);
    try std.testing.expectEqualStrings("mixtral", a.model);
    try std.testing.expectEqualStrings("https://api.mistral.ai/v1", a.base_url);
    c.removeAgent(a.uid);
    try std.testing.expectEqual(@as(usize, 0), c.agents.items.len);
}

test "screens: a mode per display round-trips, resolves and can be taken away" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    a.mode = .dark;
    a.setScreenMode("DASUNG Paperlike", .eink);
    a.setScreenMode("Built-in Retina Display: 2", .light);
    a.setScreenMode("Built-in Retina Display: 2", .light); // no change
    try std.testing.expectEqual(@as(usize, 2), a.screens.items.len);
    try std.testing.expectEqual(Mode.eink, a.modeOn("DASUNG Paperlike"));
    try std.testing.expectEqual(Mode.light, a.modeOn("Built-in Retina Display: 2"));
    try std.testing.expectEqual(Mode.dark, a.modeOn("LG UltraFine"));
    try std.testing.expectEqual(Mode.dark, a.modeOn(null));
    try std.testing.expect(a.screenMode("LG UltraFine") == null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try a.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "screens:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  - name: DASUNG Paperlike\n    style: eink\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  - name: \"Built-in Retina Display: 2\"\n    style: light\n") != null);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqual(@as(usize, 2), b.screens.items.len);
    try std.testing.expectEqual(Mode.eink, b.modeOn("DASUNG Paperlike"));
    try std.testing.expectEqual(Mode.light, b.modeOn("Built-in Retina Display: 2"));

    // Back to the general mode: the entry goes away and nothing is written.
    b.setScreenMode("DASUNG Paperlike", null);
    b.setScreenMode("never listed", null);
    try std.testing.expectEqual(@as(usize, 1), b.screens.items.len);
    try std.testing.expectEqual(Mode.dark, b.modeOn("DASUNG Paperlike"));
    b.setScreenMode("Built-in Retina Display: 2", null);
    out.clearRetainingCapacity();
    try b.write(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "screens:") == null);
}

test "screens: hand-written entries without a name or listed twice are dropped" {
    const gpa = std.testing.allocator;
    var c = Config.init(gpa);
    defer c.deinit();
    try c.parse(
        \\ui:
        \\  mode: light
        \\screens:
        \\  - name: Paper
        \\    mode: eink
        \\  - mode: dark        # no name: matches nothing
        \\  - name: Paper       # again: the first one counts
        \\    mode: dark
        \\  -
        \\    name: Desk
        \\    mode: system
        \\apis: []
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), c.screens.items.len);
    try std.testing.expectEqual(Mode.eink, c.modeOn("Paper"));
    try std.testing.expectEqual(Mode.system, c.modeOn("Desk"));
    try std.testing.expectEqual(Mode.light, c.modeOn("Other"));
}

test "notebooks: the two switches round trip and default to outputs kept, schema shared" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expect(!a.notebooks.strip_outputs and a.notebooks.share_schema);
    a.notebooks.strip_outputs = true;
    a.notebooks.share_schema = false;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a.write(&text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "notebooks:\n  strip_outputs: true\n  share_schema: false\n") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(text.items);
    try std.testing.expect(b.notebooks.strip_outputs and !b.notebooks.share_schema);
}

test "browser: cookies, homepage and do-not-track round trip and default to session cookies, blank homepage" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expect(!a.browser.keep_cookies and a.browser.homepage.len == 0 and !a.browser.do_not_track);
    try std.testing.expectEqual(LinkTarget.tt, a.browser.open_links);
    a.browser.open_links = .browser;
    a.browser.keep_cookies = true;
    a.setString(&a.browser.homepage, "https://ziglang.org/");
    a.browser.do_not_track = true;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a.write(&text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "browser:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "homepage: https://ziglang.org/\n") != null);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(text.items);
    try std.testing.expect(b.browser.keep_cookies and b.browser.do_not_track);
    try std.testing.expectEqual(LinkTarget.browser, b.browser.open_links);
    try std.testing.expectEqualStrings("https://ziglang.org/", b.browser.homepage);

    // A blank homepage is what "start on a white page" writes and reads back.
    var c = Config.init(gpa);
    defer c.deinit();
    try c.parse("browser:\n  keep_cookies: yes\n  homepage: \"\"\n  do_not_track: off\n  open_links: system\n");
    try std.testing.expect(c.browser.keep_cookies and !c.browser.do_not_track);
    try std.testing.expectEqual(LinkTarget.browser, c.browser.open_links);
    try std.testing.expectEqualStrings("", c.browser.homepage);
}

test "physical: camera, blur and calibration round trip; the blur is off by default" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expect(!a.physical.blur_when_away and a.physical.camera.len == 0 and !a.physical.calibration.isSet());
    a.setString(&a.physical.camera, "Studio Display Camera");
    a.physical.blur_when_away = true;
    a.physical.blur_after = 5;
    a.physical.sensitivity = .strict;
    a.physical.calibration = .{ .yaw = -12.5, .pitch = 8, .face_size = 0.25, .neck = 0.7 };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a.write(&text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "physical:") != null);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(text.items);
    try std.testing.expectEqualStrings("Studio Display Camera", b.physical.camera);
    try std.testing.expect(b.physical.blur_when_away);
    try std.testing.expectEqual(@as(f32, 5), b.physical.blur_after);
    try std.testing.expectEqual(posture.Sensitivity.strict, b.physical.sensitivity);
    try std.testing.expectApproxEqAbs(@as(f32, -12.5), b.physical.calibration.yaw, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), b.physical.calibration.pitch, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), b.physical.calibration.face_size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), b.physical.calibration.neck, 0.001);

    // Hand edits: a blank camera, nonsense numbers ignored or kept in range.
    var c = Config.init(gpa);
    defer c.deinit();
    try c.parse("physical:\n  camera: \"\"\n  blur_after: soon\n  sensitivity: RELAXED\n  face_size: 7\n");
    try std.testing.expectEqualStrings("", c.physical.camera);
    try std.testing.expectEqual(@as(f32, 3), c.physical.blur_after);
    try std.testing.expectEqual(posture.Sensitivity.relaxed, c.physical.sensitivity);
    try std.testing.expectEqual(@as(f32, 1), c.physical.calibration.face_size);
}

test "voice: off by default, round trips, a blank trigger is written as tt" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expect(!a.voice.enabled and a.voice.microphone.len == 0 and a.voice.trigger.len == 0);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a.write(&text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "  trigger: tt\n") != null);

    a.voice.enabled = true;
    a.setString(&a.voice.microphone, "MacBook Pro Microphone");
    a.setString(&a.voice.trigger, "hey tt");
    a.setString(&a.voice.language, "en-US");
    text.clearRetainingCapacity();
    try a.write(&text);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(text.items);
    try std.testing.expect(b.voice.enabled);
    try std.testing.expectEqualStrings("MacBook Pro Microphone", b.voice.microphone);
    try std.testing.expectEqualStrings("hey tt", b.voice.trigger);
    try std.testing.expectEqualStrings("en-US", b.voice.language);
    // The physical section before it is still read.
    try std.testing.expect(!b.physical.blur_when_away);
}

test "sites: permissions round trip, fall back to the defaults and drop empty sites" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    try std.testing.expectEqual(Permission.ask, a.permissionFor("https://teams.microsoft.com", .camera));
    a.setDefaultPermission(.notifications, .block);
    a.setSitePermission("https://teams.microsoft.com", .camera, .allow);
    a.setSitePermission("https://teams.microsoft.com", .microphone, .allow);
    a.setSitePermission("https://teams.microsoft.com", .notifications, .allow);
    a.setSitePermission("http://localhost:8080", .camera, .block);
    try std.testing.expectEqual(Permission.allow, a.permissionFor("https://teams.microsoft.com", .notifications));
    try std.testing.expectEqual(Permission.block, a.permissionFor("https://example.com", .notifications));

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try a.write(&text);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "  notifications: block\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "  - origin: https://teams.microsoft.com\n    camera: allow\n    microphone: allow\n    notifications: allow\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "  - origin: http://localhost:8080\n    camera: block\n") != null);

    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(text.items);
    try std.testing.expectEqual(@as(usize, 2), b.sites.items.len);
    try std.testing.expectEqual(Permission.block, b.browser.notifications);
    try std.testing.expectEqual(Permission.allow, b.siteDecision("https://teams.microsoft.com", .microphone));
    try std.testing.expectEqual(Permission.block, b.siteDecision("http://localhost:8080", .camera));
    try std.testing.expectEqual(Permission.ask, b.siteDecision("http://localhost:8080", .microphone));

    // Forgetting the last answer drops the site.
    b.setSitePermission("http://localhost:8080", .camera, .ask);
    try std.testing.expectEqual(@as(usize, 1), b.sites.items.len);

    // Hand edits: a trailing slash, an unknown value, an empty entry, a duplicate.
    var c = Config.init(gpa);
    defer c.deinit();
    try c.parse("sites:\n  - origin: https://a.example/\n    camera: yes-please\n    microphone: allowed\n  -\n  - origin: https://a.example\n    camera: block\n");
    try std.testing.expectEqual(@as(usize, 1), c.sites.items.len);
    try std.testing.expectEqualStrings("https://a.example", c.sites.items[0].origin);
    try std.testing.expectEqual(Permission.ask, c.sites.items[0].camera);
    try std.testing.expectEqual(Permission.allow, c.sites.items[0].microphone);
}

test "sites: removing answers, one site or all, keeps the other features" {
    const gpa = std.testing.allocator;
    var a = Config.init(gpa);
    defer a.deinit();
    a.setSitePermission("https://teams.microsoft.com", .notifications, .allow);
    a.setSitePermission("https://teams.microsoft.com", .camera, .allow);
    a.setSitePermission("https://news.example", .notifications, .block);
    a.setSitePermission("https://spam.example", .notifications, .allow);

    // The origin handed in may be the entry's own string.
    a.removeSitePermissions(a.sites.items[2].origin, &.{.notifications});
    try std.testing.expectEqual(@as(usize, 2), a.sites.items.len);
    try std.testing.expect(a.findSite("https://spam.example") == null);

    const v = a.version;
    a.removeAllSitePermissions(&.{.notifications});
    try std.testing.expect(a.version != v);
    // Teams keeps its camera answer; news.example had nothing else.
    try std.testing.expectEqual(@as(usize, 1), a.sites.items.len);
    try std.testing.expectEqual(Permission.allow, a.siteDecision("https://teams.microsoft.com", .camera));
    try std.testing.expectEqual(Permission.ask, a.siteDecision("https://teams.microsoft.com", .notifications));

    // Nothing to remove: no change recorded.
    const v2 = a.version;
    a.removeAllSitePermissions(&.{.notifications});
    try std.testing.expectEqual(v2, a.version);
}

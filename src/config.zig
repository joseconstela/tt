//! The user's settings: appearance and the AI agents they have set up,
//! kept in `~/.conch/config.yml`. The file is written by the Settings tab
//! and meant to be edited by hand too, so it is a small, readable subset of
//! YAML: two levels of `key: value` mappings and a list of mappings for the
//! agents. Unknown keys are ignored, so older builds can read newer files.
//!
//!   ui:
//!     mode: system          # dark | light | system | eink
//!     accent: amber         # amber | peach | lime | rose | "#RRGGBB"
//!   agents:
//!     - name: Claude
//!       provider: anthropic # anthropic | openai | google | mistral | ollama | custom
//!       model: claude-sonnet-5
//!       api_key: "sk-ant-…"
//!       base_url: https://api.anthropic.com
//!       default: true
//!   features:
//!     command_fallback_agent: Claude
//!     command_fallback_prompt: "…"
//!
//! One instance lives for the whole app (`get()`); saves are debounced
//! (`touch`) so typing into a field does not rewrite the file per keystroke.
const std = @import("std");
const sys = @import("sys.zig");

/// The UI's colour scheme (e-ink is black on white, for e-paper panels),
/// or following macOS.
pub const Mode = enum {
    dark,
    light,
    system,
    eink,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .dark => "Dark",
            .light => "Light",
            .system => "System",
            .eink => "E-ink",
        };
    }

    fn parse(s: []const u8) ?Mode {
        inline for (std.meta.fields(Mode)) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
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

/// Settings of the features that use the agents.
pub const Features = struct {
    /// Name of the agent that turns unrecognised terminal commands into a
    /// conversation, null = off.
    command_fallback_agent: ?[]u8 = null,
    command_fallback_prompt: []u8 = "",
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    /// `~/.conch/config.yml` (null when there is no home directory).
    path: ?[]u8 = null,
    mode: Mode = .system,
    accent: Accent = .{ .named = 0 },
    agents: std.ArrayList(Agent) = .empty,
    features: Features = .{},
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
        if (self.features.command_fallback_agent) |s| self.gpa.free(s);
        self.gpa.free(self.features.command_fallback_prompt);
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
        if (self.mode == mode) return;
        self.mode = mode;
        self.changed();
    }

    pub fn setAccent(self: *Config, accent: Accent) void {
        if (std.meta.eql(self.accent, accent)) return;
        self.accent = accent;
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

    /// Reads `~/.conch/config.yml` if there is one. A file that cannot be
    /// read leaves the defaults.
    pub fn load(self: *Config) void {
        self.path = std.fmt.allocPrint(self.gpa, "{s}/.conch/config.yml", .{sys.home()}) catch null;
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
        try out.appendSlice(gpa, "# conch settings. Changed from the Settings tab; safe to edit by hand.\n");
        try out.appendSlice(gpa, "ui:\n");
        try out.print(gpa, "  mode: {s}   # dark | light | system | eink\n", .{@tagName(self.mode)});
        switch (self.accent) {
            .named => |i| try out.print(gpa, "  accent: {s}   # amber | peach | lime | rose | \"#RRGGBB\"\n", .{accent_names[@min(i, accent_names.len - 1)]}),
            .custom => |rgb| try out.print(gpa, "  accent: \"#{X:0>6}\"   # amber | peach | lime | rose | \"#RRGGBB\"\n", .{rgb}),
        }
        if (self.agents.items.len == 0) {
            try out.appendSlice(gpa, "agents: []\n");
        } else {
            try out.appendSlice(gpa, "agents:\n");
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
        if (self.features.command_fallback_agent) |name| {
            try out.appendSlice(gpa, "  command_fallback_agent: ");
            try writeScalar(gpa, out, name);
            try out.append(gpa, '\n');
        }
        try out.appendSlice(gpa, "  command_fallback_prompt: ");
        try writeScalar(gpa, out, self.features.command_fallback_prompt);
        try out.append(gpa, '\n');
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

    const Section = enum { none, ui, agents, features };

    /// Reads the subset `write` produces (plus hand edits of the same
    /// shape). Anything it does not understand is skipped.
    fn parse(self: *Config, data: []const u8) !void {
        var section: Section = .none;
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
                // `agents: []` and any inline value: nothing to read under it.
                if (kv.value.len > 0) section = .none;
                continue;
            }

            switch (section) {
                .none => {},
                .ui => {
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "mode")) {
                        if (Mode.parse(kv.value)) |m| self.mode = m;
                    } else if (std.mem.eql(u8, kv.key, "accent")) {
                        if (parseAccent(kv.value)) |a| self.accent = a;
                    }
                },
                .features => {
                    const kv = splitKey(body) orelse continue;
                    if (std.mem.eql(u8, kv.key, "command_fallback_agent")) {
                        if (kv.value.len > 0 and !isNull(kv.value)) {
                            const v = try unquote(self.gpa, kv.value);
                            defer self.gpa.free(v);
                            self.setOptString(&self.features.command_fallback_agent, v);
                        }
                    } else if (std.mem.eql(u8, kv.key, "command_fallback_prompt")) {
                        const v = try unquote(self.gpa, kv.value);
                        defer self.gpa.free(v);
                        self.setString(&self.features.command_fallback_prompt, v);
                    }
                },
                .agents => {
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
    try std.testing.expect(b.defaultAgent().? == &b.agents.items[1]);
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "mode: eink") != null);
    var b = Config.init(gpa);
    defer b.deinit();
    try b.parse(out.items);
    try std.testing.expectEqual(Mode.eink, b.mode);
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
        \\agents: []
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

    // The default when the file says nothing: the first agent.
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

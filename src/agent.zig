//! Talking to a configured agent (`config.Agent`): the request each
//! provider wants, the reply streamed back as it is generated, and what
//! went wrong when none came. The pure parts — building the request,
//! reading the stream — are tested; the transport is NSURLSession, whose
//! callbacks arrive on its own threads, so a reply comes in while the app
//! keeps drawing and its owner picks the text up on its tick (`Request.take`).
//!
//! Wire formats: Anthropic's Messages API, OpenAI's chat completions (which
//! OpenAI, Mistral, Ollama and the "custom" endpoints speak) and Google's
//! Gemini API, all streamed as server-sent events. The agent gets one tool,
//! `propose_command`: a command for the user's input box, which the app
//! places there for the user to run — the tool never runs anything itself.
const std = @import("std");
const config = @import("config.zig");
const objc = @import("objc.zig");

const msg = objc.msg;
const id = objc.id;
const SEL = objc.SEL;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;

pub const Role = enum { user, assistant };
pub const Message = struct { role: Role, text: []const u8 };

/// The longest reply asked for.
pub const max_tokens: u32 = 4096;
/// Seconds the connection may stay quiet before the request fails.
const request_timeout: f64 = 120;

/// The tool: one shell command, proposed rather than run.
pub const tool_name = "propose_command";
const tool_description = "Puts one shell command into the user's input box, ready to run. The user reads it and presses Enter themselves, so it never executes on its own and you never see its output in this turn. Call it whenever a command would do what the user wants; one call per command, the most useful first.";
const tool_arg_description = "The zsh command line exactly as it should be run, on one line where possible, with no trailing newline.";

/// The wire format a provider speaks.
pub const Format = enum {
    anthropic,
    openai,
    google,

    pub fn of(p: config.Provider) Format {
        return switch (p) {
            .anthropic => .anthropic,
            .google => .google,
            .openai, .mistral, .ollama, .custom => .openai,
        };
    }
};

pub const Header = struct { name: []const u8, value: []u8 };

/// An HTTP request ready to send; owns its strings.
pub const Prepared = struct {
    url: []u8,
    body: []u8,
    headers: std.ArrayList(Header) = .empty,
    format: Format,

    pub fn deinit(self: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        gpa.free(self.body);
        for (self.headers.items) |h| gpa.free(h.value);
        self.headers.deinit(gpa);
    }

    fn header(self: *Prepared, gpa: std.mem.Allocator, name: []const u8, value: []const u8) error{OutOfMemory}!void {
        const copy = try gpa.dupe(u8, value);
        errdefer gpa.free(copy);
        try self.headers.append(gpa, .{ .name = name, .value = copy });
    }
};

pub const PrepareError = error{ NoModel, NoBaseUrl, NoApiKey, OutOfMemory };

pub const Options = struct {
    /// Offer the `propose_command` tool.
    tools: bool = false,
};

/// The request that asks `agent` to answer `messages` (oldest first, the
/// last one from the user) under the `system` instructions.
pub fn prepare(gpa: std.mem.Allocator, agent: *const config.Agent, system: []const u8, messages: []const Message, opts: Options) PrepareError!Prepared {
    if (agent.model.len == 0) return error.NoModel;
    const key_required = switch (agent.provider) {
        .anthropic, .openai, .google, .mistral => true,
        .ollama, .custom => false,
    };
    if (key_required and agent.api_key.len == 0) return error.NoApiKey;
    const format = Format.of(agent.provider);

    var self: Prepared = .{ .url = try endpoint(gpa, agent), .body = "", .format = format };
    errdefer self.deinit(gpa);
    self.body = try body(gpa, format, agent.model, system, messages, opts.tools);

    try self.header(gpa, "Content-Type", "application/json");
    switch (format) {
        .anthropic => {
            try self.header(gpa, "x-api-key", agent.api_key);
            try self.header(gpa, "anthropic-version", "2023-06-01");
        },
        .openai => if (agent.api_key.len > 0) {
            const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{agent.api_key});
            defer gpa.free(bearer);
            try self.header(gpa, "Authorization", bearer);
        },
        .google => try self.header(gpa, "x-goog-api-key", agent.api_key),
    }
    return self;
}

/// Where the provider takes the request: the agent's base URL plus the
/// path of its chat endpoint, unless the URL already names it.
fn endpoint(gpa: std.mem.Allocator, agent: *const config.Agent) PrepareError![]u8 {
    const base = std.mem.trimEnd(u8, agent.base_url, "/");
    if (base.len == 0) return error.NoBaseUrl;
    return switch (agent.provider) {
        .anthropic => if (std.mem.endsWith(u8, base, "/v1"))
            std.fmt.allocPrint(gpa, "{s}/messages", .{base})
        else
            std.fmt.allocPrint(gpa, "{s}/v1/messages", .{base}),
        .google => if (std.mem.endsWith(u8, base, "/v1beta") or std.mem.endsWith(u8, base, "/v1"))
            std.fmt.allocPrint(gpa, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base, agent.model })
        else
            std.fmt.allocPrint(gpa, "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse", .{ base, agent.model }),
        .openai, .mistral, .ollama, .custom => if (std.mem.endsWith(u8, base, "/chat/completions"))
            gpa.dupe(u8, base)
        else if (std.mem.endsWith(u8, base, "/v1"))
            std.fmt.allocPrint(gpa, "{s}/chat/completions", .{base})
        else
            std.fmt.allocPrint(gpa, "{s}/v1/chat/completions", .{base}),
    };
}

fn body(gpa: std.mem.Allocator, format: Format, model: []const u8, system: []const u8, messages: []const Message, tools: bool) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    writeBody(&js, format, model, system, messages, tools) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// The tool's parameters as a JSON schema object.
fn writeToolSchema(js: *std.json.Stringify) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("object");
    try js.objectField("properties");
    try js.beginObject();
    try js.objectField("command");
    try js.beginObject();
    try js.objectField("type");
    try js.write("string");
    try js.objectField("description");
    try js.write(tool_arg_description);
    try js.endObject();
    try js.endObject();
    try js.objectField("required");
    try js.beginArray();
    try js.write("command");
    try js.endArray();
    try js.endObject();
}

fn writeBody(js: *std.json.Stringify, format: Format, model: []const u8, system: []const u8, messages: []const Message, tools: bool) !void {
    try js.beginObject();
    switch (format) {
        .anthropic => {
            try js.objectField("model");
            try js.write(model);
            try js.objectField("max_tokens");
            try js.write(max_tokens);
            try js.objectField("stream");
            try js.write(true);
            if (system.len > 0) {
                try js.objectField("system");
                try js.write(system);
            }
            try js.objectField("messages");
            try js.beginArray();
            for (messages) |m| {
                try js.beginObject();
                try js.objectField("role");
                try js.write(@tagName(m.role));
                try js.objectField("content");
                try js.write(m.text);
                try js.endObject();
            }
            try js.endArray();
            if (tools) {
                try js.objectField("tools");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("name");
                try js.write(tool_name);
                try js.objectField("description");
                try js.write(tool_description);
                try js.objectField("input_schema");
                try writeToolSchema(js);
                try js.endObject();
                try js.endArray();
            }
        },
        .openai => {
            try js.objectField("model");
            try js.write(model);
            try js.objectField("stream");
            try js.write(true);
            try js.objectField("messages");
            try js.beginArray();
            if (system.len > 0) {
                try js.beginObject();
                try js.objectField("role");
                try js.write("system");
                try js.objectField("content");
                try js.write(system);
                try js.endObject();
            }
            for (messages) |m| {
                try js.beginObject();
                try js.objectField("role");
                try js.write(@tagName(m.role));
                try js.objectField("content");
                try js.write(m.text);
                try js.endObject();
            }
            try js.endArray();
            if (tools) {
                try js.objectField("tools");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("type");
                try js.write("function");
                try js.objectField("function");
                try js.beginObject();
                try js.objectField("name");
                try js.write(tool_name);
                try js.objectField("description");
                try js.write(tool_description);
                try js.objectField("parameters");
                try writeToolSchema(js);
                try js.endObject();
                try js.endObject();
                try js.endArray();
            }
        },
        .google => {
            if (system.len > 0) {
                try js.objectField("system_instruction");
                try js.beginObject();
                try js.objectField("parts");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("text");
                try js.write(system);
                try js.endObject();
                try js.endArray();
                try js.endObject();
            }
            try js.objectField("contents");
            try js.beginArray();
            for (messages) |m| {
                try js.beginObject();
                try js.objectField("role");
                try js.write(if (m.role == .user) "user" else "model");
                try js.objectField("parts");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("text");
                try js.write(m.text);
                try js.endObject();
                try js.endArray();
                try js.endObject();
            }
            try js.endArray();
            if (tools) {
                try js.objectField("tools");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("function_declarations");
                try js.beginArray();
                try js.beginObject();
                try js.objectField("name");
                try js.write(tool_name);
                try js.objectField("description");
                try js.write(tool_description);
                try js.objectField("parameters");
                try writeToolSchema(js);
                try js.endObject();
                try js.endArray();
                try js.endObject();
                try js.endArray();
            }
            try js.objectField("generationConfig");
            try js.beginObject();
            try js.objectField("maxOutputTokens");
            try js.write(max_tokens);
            try js.endObject();
        },
    }
    try js.endObject();
}

// ── the reply stream ────────────────────────────────────────────────────
pub const Status = enum { running, done, failed };

/// A tool call still being streamed: its name and its arguments' JSON so far.
const Call = struct {
    index: usize,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

/// Reads a provider's event stream as it arrives: the text the model
/// wrote so far, the commands it proposed, and whether the reply is
/// complete or failed.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    format: Format,
    /// The text since the owner last took it.
    text: std.ArrayList(u8) = .empty,
    /// The commands proposed since the owner last took them (owned).
    proposals: std.ArrayList([]u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    /// Reply text not released to `text` yet (see `pushText`).
    held: std.ArrayList(u8) = .empty,
    /// `held` starts with a tool call written as text, still arriving.
    capturing: bool = false,
    /// A line not finished by the bytes so far.
    line: std.ArrayList(u8) = .empty,
    status: Status = .running,
    err: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, format: Format) Stream {
        return .{ .gpa = gpa, .format = format };
    }

    pub fn deinit(self: *Stream) void {
        self.text.deinit(self.gpa);
        for (self.proposals.items) |p| self.gpa.free(p);
        self.proposals.deinit(self.gpa);
        for (self.calls.items) |*c| {
            c.name.deinit(self.gpa);
            c.args.deinit(self.gpa);
        }
        self.calls.deinit(self.gpa);
        self.held.deinit(self.gpa);
        self.line.deinit(self.gpa);
        self.err.deinit(self.gpa);
    }

    pub fn feed(self: *Stream, bytes: []const u8) void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            self.line.appendSlice(self.gpa, rest[0..nl]) catch return;
            self.handleLine(std.mem.trimEnd(u8, self.line.items, "\r"));
            self.line.clearRetainingCapacity();
            rest = rest[nl + 1 ..];
        }
        self.line.appendSlice(self.gpa, rest) catch return;
    }

    /// The connection ended: whatever is left is the last line, and a
    /// reply that had no error is complete.
    pub fn finish(self: *Stream) void {
        if (self.line.items.len > 0) {
            self.handleLine(std.mem.trimEnd(u8, self.line.items, "\r"));
            self.line.clearRetainingCapacity();
        }
        self.sift(true);
        self.finishCalls();
        if (self.status == .running) self.status = .done;
    }

    pub fn fail(self: *Stream, message: []const u8) void {
        if (self.status != .running) return;
        self.status = .failed;
        self.err.clearRetainingCapacity();
        self.err.appendSlice(self.gpa, message) catch {};
    }

    fn handleLine(self: *Stream, line: []const u8) void {
        if (self.status != .running) return;
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const data = std.mem.trim(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) {
            self.sift(true);
            self.finishCalls();
            self.status = .done;
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (errorMessage(root)) |e| {
            self.fail(e);
            return;
        }
        switch (self.format) {
            .anthropic => {
                const kind = getString(root, "type") orelse return;
                const index: usize = @intCast(@max(0, getInt(root, "index") orelse 0));
                if (std.mem.eql(u8, kind, "content_block_start")) {
                    const block = getObject(root, "content_block") orelse return;
                    const bk = getString(block, "type") orelse return;
                    if (std.mem.eql(u8, bk, "tool_use")) {
                        const c = self.call(index) orelse return;
                        if (getString(block, "name")) |n| c.name.appendSlice(self.gpa, n) catch {};
                    }
                } else if (std.mem.eql(u8, kind, "content_block_delta")) {
                    const delta = getObject(root, "delta") orelse return;
                    const dk = getString(delta, "type") orelse return;
                    if (std.mem.eql(u8, dk, "text_delta")) {
                        if (getString(delta, "text")) |t| self.pushText(t);
                    } else if (std.mem.eql(u8, dk, "input_json_delta")) {
                        const c = self.call(index) orelse return;
                        if (getString(delta, "partial_json")) |j| c.args.appendSlice(self.gpa, j) catch {};
                    }
                } else if (std.mem.eql(u8, kind, "content_block_stop")) {
                    self.finishCall(index);
                } else if (std.mem.eql(u8, kind, "message_stop")) {
                    self.sift(true);
                    self.finishCalls();
                    self.status = .done;
                }
            },
            .openai => {
                const choices = getArray(root, "choices") orelse return;
                if (choices.items.len == 0) return;
                const choice = choices.items[0];
                if (getObject(choice, "delta")) |delta| {
                    if (getString(delta, "content")) |t| self.pushText(t);
                    if (getArray(delta, "tool_calls")) |calls| for (calls.items, 0..) |tc, i| {
                        const index: usize = @intCast(@max(0, getInt(tc, "index") orelse @as(i64, @intCast(i))));
                        const c = self.call(index) orelse continue;
                        const function = getObject(tc, "function") orelse continue;
                        if (getString(function, "name")) |n| c.name.appendSlice(self.gpa, n) catch {};
                        if (function.object.get("arguments")) |a| switch (a) {
                            // Arguments come as JSON text, in pieces — or, from
                            // some servers, as the object itself.
                            .string => |j| c.args.appendSlice(self.gpa, j) catch {},
                            .object => {
                                c.args.clearRetainingCapacity();
                                if (getString(a, "command")) |cmd| {
                                    var w: std.Io.Writer.Allocating = .init(self.gpa);
                                    defer w.deinit();
                                    std.json.Stringify.value(.{ .command = cmd }, .{}, &w.writer) catch {};
                                    c.args.appendSlice(self.gpa, w.written()) catch {};
                                }
                            },
                            else => {},
                        };
                    };
                }
                if (getString(choice, "finish_reason") != null) self.finishCalls();
            },
            .google => {
                const candidates = getArray(root, "candidates") orelse return;
                if (candidates.items.len == 0) return;
                const content = getObject(candidates.items[0], "content") orelse return;
                const parts = getArray(content, "parts") orelse return;
                for (parts.items) |p| {
                    if (getString(p, "text")) |t| self.pushText(t);
                    if (getObject(p, "functionCall")) |fc| {
                        const name = getString(fc, "name") orelse continue;
                        if (!std.mem.eql(u8, name, tool_name)) continue;
                        const args = getObject(fc, "args") orelse continue;
                        if (getString(args, "command")) |cmd| self.propose(cmd);
                    }
                }
            },
        }
    }

    // ── tool calls written as text ───────────────────────────────────────
    // Local models often write a call into the reply instead of making one:
    // Gemma as `propose_command{command:<|"|>…<|"|>}`, others as a JSON
    // object or a <tool_call> element. The text released to the owner runs
    // `lag` bytes behind what arrived, so such a call is caught whole before
    // any of it shows, taken out and turned into a proposal. Anything that
    // looked like one but was not is released unchanged.
    const lag: usize = 24;
    const max_capture: usize = 4096;
    const markers = [_][]const u8{ "propose_command{", "<tool_call>", "{\"name\"", "{ \"name\"", "{\"command\"", "{ \"command\"" };

    fn pushText(self: *Stream, t: []const u8) void {
        self.held.appendSlice(self.gpa, t) catch return;
        self.sift(false);
    }

    /// Releases what cannot be part of a call; `final` releases everything.
    fn sift(self: *Stream, final: bool) void {
        while (true) {
            if (self.capturing) {
                if (callEnd(self.held.items)) |end| {
                    self.capturing = false;
                    if (!self.takeCall(self.held.items[0..end])) self.text.appendSlice(self.gpa, self.held.items[0..end]) catch {};
                    self.dropHeld(end);
                    continue;
                }
                if (final or self.held.items.len > max_capture) {
                    // Never finished: it was text after all.
                    self.capturing = false;
                    self.releaseHeld(self.held.items.len);
                }
                return;
            }
            var found: ?usize = null;
            for (markers) |m| {
                if (std.mem.indexOf(u8, self.held.items, m)) |at| {
                    if (found == null or at < found.?) found = at;
                }
            }
            if (found) |at| {
                self.releaseHeld(at);
                self.capturing = true;
                continue;
            }
            const keep = if (final) 0 else @min(lag, self.held.items.len);
            self.releaseHeld(self.held.items.len - keep);
            return;
        }
    }

    fn releaseHeld(self: *Stream, n: usize) void {
        self.text.appendSlice(self.gpa, self.held.items[0..n]) catch {};
        self.dropHeld(n);
    }

    fn dropHeld(self: *Stream, n: usize) void {
        std.mem.copyForwards(u8, self.held.items, self.held.items[n..]);
        self.held.items.len -= n;
    }

    /// Where the call that `held` starts with ends, once it is all there.
    fn callEnd(held: []const u8) ?usize {
        if (std.mem.startsWith(u8, held, "<tool_call>")) {
            const close = std.mem.indexOf(u8, held, "</tool_call>") orelse return null;
            return close + "</tool_call>".len;
        }
        if (std.mem.startsWith(u8, held, "propose_command{")) {
            // Gemma quotes the value with <|"|>: a `}` inside it is not the end.
            if (std.mem.indexOf(u8, held, "<|\"|>")) |open| {
                const close = std.mem.indexOfPos(u8, held, open + 5, "<|\"|>") orelse return null;
                const brace = std.mem.indexOfScalarPos(u8, held, close + 5, '}') orelse return null;
                return brace + 1;
            }
        }
        return balancedEnd(held);
    }

    /// Index after the `}` closing the first `{`, strings skipped.
    fn balancedEnd(s: []const u8) ?usize {
        const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
        var depth: usize = 0;
        var in_str = false;
        var esc = false;
        var i = start;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (in_str) {
                if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return null;
    }

    /// A complete call written as text becomes a proposal; false when it
    /// turns out not to be one (a JSON object about something else).
    fn takeCall(self: *Stream, text: []const u8) bool {
        if (std.mem.startsWith(u8, text, "propose_command{")) return self.inlineCall(text);
        var json = text;
        if (std.mem.startsWith(u8, json, "<tool_call>")) json = std.mem.trim(u8, json["<tool_call>".len .. json.len - "</tool_call>".len], " \r\n\t");
        return self.jsonCall(json);
    }

    /// `propose_command{command:<|"|>…<|"|>}` (Gemma), or the value as a
    /// JSON string, or bare up to the `}`.
    fn inlineCall(self: *Stream, text: []const u8) bool {
        const key = std.mem.indexOfPos(u8, text, "propose_command{".len, "command") orelse return false;
        var i = key + "command".len;
        if (i < text.len and (text[i] == '"' or text[i] == '\'')) i += 1;
        while (i < text.len and text[i] == ' ') i += 1;
        if (i < text.len and (text[i] == ':' or text[i] == '=')) i += 1;
        while (i < text.len and text[i] == ' ') i += 1;
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "<|\"|>")) {
            const v = rest[5..];
            const close = std.mem.indexOf(u8, v, "<|\"|>") orelse return false;
            self.propose(v[0..close]);
            return true;
        }
        if (rest.len > 0 and rest[0] == '"') {
            const end = balancedEnd(text) orelse return false;
            // The JSON string up to the last quote before the closing brace.
            const close = std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '"') orelse return false;
            if (close <= i) return false;
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, text[i .. close + 1], .{}) catch return false;
            defer parsed.deinit();
            if (parsed.value != .string) return false;
            self.propose(parsed.value.string);
            return true;
        }
        const brace = std.mem.lastIndexOfScalar(u8, rest, '}') orelse return false;
        self.propose(std.mem.trim(u8, rest[0..brace], " "));
        return true;
    }

    /// `{"name":"propose_command","arguments":{"command":…}}` (also with
    /// `parameters` or `input`, or the arguments as a JSON string), or just
    /// `{"command":…}`.
    fn jsonCall(self: *Stream, json: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, json, .{}) catch return false;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return false;
        if (getString(root, "name")) |name| {
            if (!std.mem.eql(u8, name, tool_name)) return false;
            for ([_][]const u8{ "arguments", "parameters", "input" }) |key| {
                const args = root.object.get(key) orelse continue;
                switch (args) {
                    .object => if (getString(args, "command")) |cmd| {
                        self.propose(cmd);
                        return true;
                    },
                    .string => |raw| {
                        var inner = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch continue;
                        defer inner.deinit();
                        if (getString(inner.value, "command")) |cmd| {
                            self.propose(cmd);
                            return true;
                        }
                    },
                    else => {},
                }
            }
            return false;
        }
        if (getString(root, "command")) |cmd| {
            self.propose(cmd);
            return true;
        }
        return false;
    }

    /// The call being streamed at `index`, started if new.
    fn call(self: *Stream, index: usize) ?*Call {
        for (self.calls.items) |*c| {
            if (c.index == index) return c;
        }
        self.calls.append(self.gpa, .{ .index = index }) catch return null;
        return &self.calls.items[self.calls.items.len - 1];
    }

    /// The call at `index` is complete: its arguments are read.
    fn finishCall(self: *Stream, index: usize) void {
        for (self.calls.items, 0..) |*c, i| {
            if (c.index != index) continue;
            self.settle(c);
            c.name.deinit(self.gpa);
            c.args.deinit(self.gpa);
            _ = self.calls.orderedRemove(i);
            return;
        }
    }

    fn finishCalls(self: *Stream) void {
        for (self.calls.items) |*c| {
            self.settle(c);
            c.name.deinit(self.gpa);
            c.args.deinit(self.gpa);
        }
        self.calls.clearRetainingCapacity();
    }

    /// A finished call to the tool becomes a proposal.
    fn settle(self: *Stream, c: *const Call) void {
        if (!std.mem.eql(u8, c.name.items, tool_name)) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, c.args.items, .{}) catch return;
        defer parsed.deinit();
        if (getString(parsed.value, "command")) |cmd| self.propose(cmd);
    }

    /// Keeps a proposed command: trimmed, with no trailing newline (the
    /// command must not run just by being placed) and no control bytes
    /// but tabs and the line breaks inside a multi-line command.
    fn propose(self: *Stream, raw: []const u8) void {
        var clean: std.ArrayList(u8) = .empty;
        for (raw) |b| {
            if (b == '\r' or (b < 0x20 and b != '\n' and b != '\t') or b == 0x7f) continue;
            clean.append(self.gpa, b) catch return;
        }
        const trimmed = std.mem.trim(u8, clean.items, " \t\n");
        if (trimmed.len == 0) {
            clean.deinit(self.gpa);
            return;
        }
        const copy = self.gpa.dupe(u8, trimmed) catch {
            clean.deinit(self.gpa);
            return;
        };
        clean.deinit(self.gpa);
        self.proposals.append(self.gpa, copy) catch self.gpa.free(copy);
    }
};

/// The message of an error the providers put in a JSON body:
/// `{"error": {"message": "…"}}` (all three) or `{"error": "…"}` (Ollama).
pub fn errorMessage(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const e = root.object.get("error") orelse return null;
    return switch (e) {
        .string => |s| s,
        .object => getString(e, "message"),
        else => null,
    };
}

/// One line on why a request with HTTP status `status` failed, from its
/// body when the body says (into `buf` when it does not).
pub fn describeFailure(gpa: std.mem.Allocator, status: i64, raw: []const u8, buf: []u8) []const u8 {
    if (raw.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, gpa, raw, .{})) |parsed| {
            defer parsed.deinit();
            if (errorMessage(parsed.value)) |m| {
                const n = @min(m.len, buf.len);
                @memcpy(buf[0..n], m[0..n]);
                return buf[0..n];
            }
        } else |_| {}
    }
    return switch (status) {
        401 => "The API key was refused (HTTP 401).",
        403 => "Access was refused (HTTP 403).",
        404 => "Nothing answers at that address or model (HTTP 404).",
        429 => "Rate limited (HTTP 429): try again in a moment.",
        else => std.fmt.bufPrint(buf, "The server answered with HTTP {d}.", .{status}) catch "The server refused the request.",
    };
}

fn getObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .object) child else null;
}

fn getArray(v: std.json.Value, key: []const u8) ?std.json.Array {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .array) child.array else null;
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .string) child.string else null;
}

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return if (child == .integer) child.integer else null;
}

// ── the transport ───────────────────────────────────────────────────────
// One NSURLSession per request, with a delegate object whose indexed
// ivars hold the pointer back here. Delegate callbacks arrive on the
// session's own queue, so everything they touch sits under `lock`; the
// owner reads on the main thread through `take`. The session is asked to
// invalidate itself once the task is over, and its "did become invalid"
// callback is the last thing it sends: only then can the request be freed.
// An owner that goes away first (`release`) leaves the request on the
// orphan list, which `reap` sweeps on the main thread.
pub const Request = struct {
    gpa: std.mem.Allocator,
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    stream: Stream,
    /// The body of an error response (HTTP status ≥ 400), for its message.
    raw: std.ArrayList(u8) = .empty,
    http_status: i64 = 0,
    /// No callback will come after this.
    invalidated: bool = false,
    session: id = null,
    task: id = null,
    delegate: id = null,
    next_orphan: ?*Request = null,

    /// Sends `prepared`. The returned request may already have failed
    /// (a bad URL): `take` says so.
    pub fn start(prepared: *const Prepared) error{OutOfMemory}!*Request {
        const gpa = std.heap.c_allocator;
        const self = try gpa.create(Request);
        self.* = .{ .gpa = gpa, .stream = Stream.init(gpa, prepared.format) };

        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const nsurl = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(prepared.url)});
        if (nsurl == null) {
            self.stream.fail("The agent's base URL is not a valid address (Settings › AI › APIs).");
            self.invalidated = true;
            return self;
        }
        const req = msg(id, objc.class("NSMutableURLRequest"), "requestWithURL:", .{nsurl});
        msg(void, req, "setHTTPMethod:", .{objc.nsString("POST")});
        msg(void, req, "setTimeoutInterval:", .{request_timeout});
        for (prepared.headers.items) |h| {
            msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString(h.value), objc.nsString(h.name) });
        }
        const data = msg(id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, prepared.body.ptr), @as(NSUInteger, prepared.body.len) });
        msg(void, req, "setHTTPBody:", .{data});

        const delegate = msg(id, msg(id, delegateClass(), "alloc", .{}), "init", .{});
        const slot: *?*Request = @ptrCast(@alignCast(object_getIndexedIvars(delegate).?));
        slot.* = self;
        self.delegate = delegate;

        const cfg = msg(id, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
        msg(void, cfg, "setTimeoutIntervalForRequest:", .{request_timeout});
        const session = msg(id, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ cfg, delegate, @as(id, null) });
        self.session = objc.retain(session);
        const task = msg(id, session, "dataTaskWithRequest:", .{req});
        self.task = objc.retain(task);
        msg(void, task, "resume", .{});
        // Invalidates once the task is over; the delegate hears about it last.
        msg(void, session, "finishTasksAndInvalidate", .{});
        return self;
    }

    /// Moves the text received since the last call to `text`, the commands
    /// proposed since then to `proposals` (copies the caller frees with
    /// `gpa`) and, once the reply is over, says how it ended (`err` gets
    /// the reason).
    pub fn take(self: *Request, text: *std.ArrayList(u8), proposals: *std.ArrayList([]u8), err: *std.ArrayList(u8), gpa: std.mem.Allocator) Status {
        self.lockMutex();
        defer self.unlockMutex();
        text.appendSlice(gpa, self.stream.text.items) catch {};
        self.stream.text.clearRetainingCapacity();
        for (self.stream.proposals.items) |p| {
            if (gpa.dupe(u8, p)) |copy| proposals.append(gpa, copy) catch gpa.free(copy) else |_| {}
            self.gpa.free(p);
        }
        self.stream.proposals.clearRetainingCapacity();
        if (self.stream.status == .failed) err.appendSlice(gpa, self.stream.err.items) catch {};
        return self.stream.status;
    }

    /// Stops the request; it ends as failed with "Stopped".
    pub fn cancel(self: *Request) void {
        if (self.task != null) msg(void, self.task, "cancel", .{});
    }

    /// The owner is done with the request. Freed now when no callback can
    /// still come, otherwise cancelled and swept up later by `reap`.
    pub fn release(self: *Request) void {
        self.lockMutex();
        const gone = self.invalidated;
        self.unlockMutex();
        if (gone) {
            self.destroy();
            return;
        }
        self.cancel();
        self.next_orphan = orphans;
        orphans = self;
    }

    /// Frees the released requests whose sessions have since finished.
    pub fn reap() void {
        var p = &orphans;
        while (p.*) |r| {
            r.lockMutex();
            const gone = r.invalidated;
            r.unlockMutex();
            if (gone) {
                p.* = r.next_orphan;
                r.destroy();
            } else p = &r.next_orphan;
        }
    }

    fn destroy(self: *Request) void {
        objc.release(self.task);
        objc.release(self.session);
        objc.release(self.delegate);
        self.stream.deinit();
        self.raw.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn lockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_lock(&self.lock);
    }

    fn unlockMutex(self: *Request) void {
        _ = std.c.pthread_mutex_unlock(&self.lock);
    }

    /// The HTTP status of the task's response, once there is one.
    fn noteStatus(self: *Request, task: id) void {
        if (self.http_status != 0) return;
        const resp = msg(id, task, "response", .{});
        if (resp == null) return;
        if (msg(bool, resp, "respondsToSelector:", .{objc.sel("statusCode")})) {
            self.http_status = msg(NSInteger, resp, "statusCode", .{});
        } else self.http_status = 200;
    }
};

var orphans: ?*Request = null;

extern "c" fn object_getIndexedIvars(obj: id) ?*anyopaque;

var delegate_class: objc.Class = null;

fn delegateClass() objc.Class {
    if (delegate_class == null) {
        const cls = objc.objc_allocateClassPair(objc.class("NSObject"), "ConchAgentDelegate", @sizeOf(?*Request));
        if (cls == null) std.debug.panic("failed to allocate objc class ConchAgentDelegate", .{});
        const proto = objc.objc_getProtocol("NSURLSessionDataDelegate");
        if (proto != null) _ = objc.class_addProtocol(cls, proto);
        _ = objc.class_addMethod(cls, objc.sel("URLSession:dataTask:didReceiveData:"), @ptrCast(&didReceiveData), "v@:@@@");
        _ = objc.class_addMethod(cls, objc.sel("URLSession:task:didCompleteWithError:"), @ptrCast(&didComplete), "v@:@@@");
        _ = objc.class_addMethod(cls, objc.sel("URLSession:didBecomeInvalidWithError:"), @ptrCast(&didInvalidate), "v@:@@");
        objc.objc_registerClassPair(cls);
        delegate_class = cls;
    }
    return delegate_class;
}

fn requestOf(delegate: id) ?*Request {
    const slot: *?*Request = @ptrCast(@alignCast(object_getIndexedIvars(delegate) orelse return null));
    return slot.*;
}

fn didReceiveData(self: id, _: SEL, _: id, task: id, data: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    const len: usize = msg(NSUInteger, data, "length", .{});
    const ptr = msg(?[*]const u8, data, "bytes", .{});
    const bytes: []const u8 = if (ptr) |p| p[0..len] else "";
    req.lockMutex();
    defer req.unlockMutex();
    req.noteStatus(task);
    if (req.http_status >= 400) {
        req.raw.appendSlice(req.gpa, bytes) catch {};
    } else req.stream.feed(bytes);
}

fn didComplete(self: id, _: SEL, _: id, task: id, err: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    req.lockMutex();
    defer req.unlockMutex();
    req.noteStatus(task);
    if (err != null) {
        const code = msg(NSInteger, err, "code", .{});
        // NSURLErrorCancelled: `cancel` was called.
        if (code == -999) req.stream.fail("Stopped.") else req.stream.fail(objc.utf8(msg(id, err, "localizedDescription", .{})));
    } else if (req.http_status >= 400) {
        var buf: [512]u8 = undefined;
        req.stream.fail(describeFailure(req.gpa, req.http_status, req.raw.items, &buf));
    } else req.stream.finish();
}

fn didInvalidate(self: id, _: SEL, _: id, _: id) callconv(.c) void {
    const req = requestOf(self) orelse return;
    req.lockMutex();
    defer req.unlockMutex();
    req.stream.fail("The connection closed before the reply was complete.");
    req.invalidated = true;
}

// ── tests ────────────────────────────────────────────────────────────────
fn testAgent(provider: config.Provider, model: []const u8, key: []const u8, base: []const u8) config.Agent {
    return .{ .name = @constCast("t"), .provider = provider, .model = @constCast(model), .api_key = @constCast(key), .base_url = @constCast(base) };
}

fn hasHeader(p: *const Prepared, name: []const u8, value: []const u8) bool {
    for (p.headers.items) |h| {
        if (std.mem.eql(u8, h.name, name)) return std.mem.eql(u8, h.value, value);
    }
    return false;
}

test "agent: each provider gets its endpoint, headers and body shape" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{ .{ .role = .user, .text = "how big is \"this\"?" }, .{ .role = .assistant, .text = "du -sh ." }, .{ .role = .user, .text = "and hidden files" } };

    var a = try prepare(gpa, &testAgent(.anthropic, "claude-sonnet-5", "sk-1", "https://api.anthropic.com"), "be brief", &msgs, .{});
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", a.url);
    try std.testing.expect(hasHeader(&a, "x-api-key", "sk-1"));
    try std.testing.expect(hasHeader(&a, "anthropic-version", "2023-06-01"));
    try std.testing.expectEqualStrings(
        "{\"model\":\"claude-sonnet-5\",\"max_tokens\":4096,\"stream\":true,\"system\":\"be brief\",\"messages\":[{\"role\":\"user\",\"content\":\"how big is \\\"this\\\"?\"},{\"role\":\"assistant\",\"content\":\"du -sh .\"},{\"role\":\"user\",\"content\":\"and hidden files\"}]}",
        a.body,
    );

    var o = try prepare(gpa, &testAgent(.openai, "gpt-5", "sk-2", "https://api.openai.com/v1/"), "sys", msgs[0..1], .{});
    defer o.deinit(gpa);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", o.url);
    try std.testing.expect(hasHeader(&o, "Authorization", "Bearer sk-2"));
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"sys\"},{\"role\":\"user\",\"content\":\"how big is \\\"this\\\"?\"}]}",
        o.body,
    );

    // Ollama speaks OpenAI's format under /v1 and wants no key; a custom
    // endpoint given without /v1 gets it, one with it does not.
    var l = try prepare(gpa, &testAgent(.ollama, "llama3.2", "", "http://localhost:11434"), "", msgs[0..1], .{});
    defer l.deinit(gpa);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", l.url);
    try std.testing.expect(!hasHeader(&l, "Authorization", ""));
    try std.testing.expect(std.mem.indexOf(u8, l.body, "system") == null);
    var c = try prepare(gpa, &testAgent(.custom, "m", "", "http://localhost:1234"), "", msgs[0..1], .{});
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("http://localhost:1234/v1/chat/completions", c.url);
    var c2 = try prepare(gpa, &testAgent(.custom, "m", "k", "https://openrouter.ai/api/v1"), "", msgs[0..1], .{});
    defer c2.deinit(gpa);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", c2.url);
    try std.testing.expect(hasHeader(&c2, "Authorization", "Bearer k"));

    var g = try prepare(gpa, &testAgent(.google, "gemini-2.5-pro", "g-1", "https://generativelanguage.googleapis.com"), "sys", &msgs, .{});
    defer g.deinit(gpa);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse", g.url);
    try std.testing.expect(hasHeader(&g, "x-goog-api-key", "g-1"));
    try std.testing.expectEqualStrings(
        "{\"system_instruction\":{\"parts\":[{\"text\":\"sys\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"how big is \\\"this\\\"?\"}]},{\"role\":\"model\",\"parts\":[{\"text\":\"du -sh .\"}]},{\"role\":\"user\",\"parts\":[{\"text\":\"and hidden files\"}]}],\"generationConfig\":{\"maxOutputTokens\":4096}}",
        g.body,
    );

    try std.testing.expectError(error.NoApiKey, prepare(gpa, &testAgent(.anthropic, "m", "", "https://api.anthropic.com"), "", msgs[0..1], .{}));
    try std.testing.expectError(error.NoModel, prepare(gpa, &testAgent(.custom, "", "", "http://x"), "", msgs[0..1], .{}));
    try std.testing.expectError(error.NoBaseUrl, prepare(gpa, &testAgent(.custom, "m", "", "/"), "", msgs[0..1], .{}));
}

test "agent: the tool goes out in each provider's shape" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{.{ .role = .user, .text = "q" }};
    var a = try prepare(gpa, &testAgent(.anthropic, "m", "k", "https://api.anthropic.com"), "", &msgs, .{ .tools = true });
    defer a.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, a.body, "\"tools\":[{\"name\":\"propose_command\",\"description\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.body, "\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":") != null);
    try std.testing.expect(std.mem.endsWith(u8, a.body, "\"required\":[\"command\"]}}]}"));
    var o = try prepare(gpa, &testAgent(.ollama, "m", "", "http://localhost:11434"), "", &msgs, .{ .tools = true });
    defer o.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, o.body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"propose_command\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.body, "\"parameters\":{\"type\":\"object\"") != null);
    var g = try prepare(gpa, &testAgent(.google, "m", "k", "https://generativelanguage.googleapis.com"), "", &msgs, .{ .tools = true });
    defer g.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, g.body, "\"tools\":[{\"function_declarations\":[{\"name\":\"propose_command\",") != null);
    var plain = try prepare(gpa, &testAgent(.google, "m", "k", "https://generativelanguage.googleapis.com"), "", &msgs, .{});
    defer plain.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, plain.body, "tools") == null);
}

test "agent: tool calls become proposals, trimmed of newlines" {
    const gpa = std.testing.allocator;
    // OpenAI: arguments as JSON text in pieces, interleaved with text.
    var o = Stream.init(gpa, .openai);
    defer o.deinit();
    o.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Sure.\"}}]}\n\n");
    o.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"propose_command\",\"arguments\":\"\"}}]}}]}\n\n");
    o.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"comm\"}}]}}]}\n\n");
    o.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"and\\\": \\\"ls -la\\\\n\\\"}\"}}]}}]}\n\n");
    try std.testing.expectEqual(@as(usize, 0), o.proposals.items.len);
    o.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n");
    try std.testing.expectEqual(Status.done, o.status);
    try std.testing.expectEqualStrings("Sure.", o.text.items);
    try std.testing.expectEqual(@as(usize, 1), o.proposals.items.len);
    try std.testing.expectEqualStrings("ls -la", o.proposals.items[0]);

    // Arguments as an object (some OpenAI-compatible servers), no finish_reason.
    var o2 = Stream.init(gpa, .openai);
    defer o2.deinit();
    o2.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"propose_command\",\"arguments\":{\"command\":\"  du -sh . \\r\\n\"}}}]}}]}\n\n");
    o2.finish();
    try std.testing.expectEqual(@as(usize, 1), o2.proposals.items.len);
    try std.testing.expectEqualStrings("du -sh .", o2.proposals.items[0]);

    // Anthropic: a tool_use block with input_json_delta pieces.
    var a = Stream.init(gpa, .anthropic);
    defer a.deinit();
    a.feed("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n");
    a.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Here:\"}}\n\n");
    a.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"propose_command\",\"input\":{}}}\n\n");
    a.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\": \\\"git \"}}\n\n");
    a.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"log --oneline\\\\n\\\"}\"}}\n\n");
    a.feed("data: {\"type\":\"content_block_stop\",\"index\":1}\n\n");
    try std.testing.expectEqual(@as(usize, 1), a.proposals.items.len);
    try std.testing.expectEqualStrings("git log --oneline", a.proposals.items[0]);
    a.feed("data: {\"type\":\"message_stop\"}\n\n");
    try std.testing.expectEqual(Status.done, a.status);
    try std.testing.expectEqualStrings("Here:", a.text.items);

    // Google: the call arrives whole; other tools are ignored.
    var g = Stream.init(gpa, .google);
    defer g.deinit();
    g.feed("data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"other\",\"args\":{\"command\":\"rm -rf /\"}}},{\"functionCall\":{\"name\":\"propose_command\",\"args\":{\"command\":\"pwd\\n\"}}}]}}]}\n\n");
    try std.testing.expectEqual(@as(usize, 1), g.proposals.items.len);
    try std.testing.expectEqualStrings("pwd", g.proposals.items[0]);
}

test "agent: a call written as text becomes a proposal and leaves the text" {
    const gpa = std.testing.allocator;
    // Gemma's inline form, token by token, prose around it.
    var g = Stream.init(gpa, .openai);
    defer g.deinit();
    const pieces = [_][]const u8{ "Sure, this one: ", "propose", "_command", "{command", ":<|\"|>", "ls -lS", " | head", " -n 6<|\"", "|>}", "\nIt sorts by size.", " Done." };
    for (pieces) |piece| {
        var buf: [256]u8 = undefined;
        const chunk = std.fmt.bufPrint(&buf, "data: {{\"choices\":[{{\"delta\":{{\"content\":{f}}}}}]}}\n\n", .{std.json.fmt(piece, .{})}) catch unreachable;
        g.feed(chunk);
    }
    try std.testing.expectEqualStrings("Sure, this one: ", g.text.items);
    try std.testing.expectEqual(@as(usize, 1), g.proposals.items.len);
    try std.testing.expectEqualStrings("ls -lS | head -n 6", g.proposals.items[0]);
    g.feed("data: [DONE]\n\n");
    try std.testing.expectEqualStrings("Sure, this one: \nIt sorts by size. Done.", g.text.items);

    // A JSON object and a <tool_call> element; a JSON object about
    // something else stays text, exactly as written.
    var j = Stream.init(gpa, .openai);
    defer j.deinit();
    j.feed("data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"name\\\": \\\"propose_command\\\", \\\"arguments\\\": {\\\"command\\\": \\\"pwd\\\\n\\\"}}\\n<tool_call>{\\\"name\\\":\\\"propose_command\\\",\\\"parameters\\\":{\\\"command\\\":\\\"git status\\\"}}</tool_call>\\nExample: {\\\"name\\\": \\\"Alice\\\", \\\"age\\\": 3} ok\"}}]}\n\n");
    j.finish();
    try std.testing.expectEqual(@as(usize, 2), j.proposals.items.len);
    try std.testing.expectEqualStrings("pwd", j.proposals.items[0]);
    try std.testing.expectEqualStrings("git status", j.proposals.items[1]);
    try std.testing.expectEqualStrings("\n\nExample: {\"name\": \"Alice\", \"age\": 3} ok", j.text.items);

    // A quoted value with escapes, and one that never closes.
    var q = Stream.init(gpa, .anthropic);
    defer q.deinit();
    q.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"propose_command{\\\"command\\\": \\\"echo \\\\\\\"hi\\\\\\\"\\\"}\"}}\n\n");
    q.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" and then propose_command{command: never\"}}\n\n");
    q.finish();
    try std.testing.expectEqual(@as(usize, 1), q.proposals.items.len);
    try std.testing.expectEqualStrings("echo \"hi\"", q.proposals.items[0]);
    try std.testing.expectEqualStrings(" and then propose_command{command: never", q.text.items);
}

test "agent: OpenAI stream, in arbitrary chunks" {
    var s = Stream.init(std.testing.allocator, .openai);
    defer s.deinit();
    const sse =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Try \"}}]}\r\n\r\n" ++
        ": keep-alive\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"du -sh .\\n\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":null},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"total_tokens\":9}}\n\n" ++
        "data: [DONE]\n\n";
    var i: usize = 0;
    while (i < sse.len) : (i += 7) {
        try std.testing.expectEqual(Status.running, s.status);
        s.feed(sse[i..@min(sse.len, i + 7)]);
    }
    try std.testing.expectEqual(Status.done, s.status);
    try std.testing.expectEqualStrings("Try du -sh .\n", s.text.items);
}

test "agent: Anthropic events, errors and the end of the connection" {
    const gpa = std.testing.allocator;
    var s = Stream.init(gpa, .anthropic);
    defer s.deinit();
    s.feed("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n");
    s.feed("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n");
    s.feed("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Use \"}}\n\n");
    s.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ls -la\"}}\n\n");
    try std.testing.expectEqual(Status.running, s.status);
    // The visible text runs a few bytes behind (a call written as text is
    // caught before it shows); the end releases the rest.
    try std.testing.expectEqualStrings("", s.text.items);
    s.feed("event: message_stop\ndata: {\"type\":\"message_stop\"}");
    try std.testing.expectEqual(Status.running, s.status); // no newline yet
    s.finish();
    try std.testing.expectEqual(Status.done, s.status);
    try std.testing.expectEqualStrings("Use ls -la", s.text.items);

    var e = Stream.init(gpa, .anthropic);
    defer e.deinit();
    e.feed("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n");
    try std.testing.expectEqual(Status.failed, e.status);
    try std.testing.expectEqualStrings("Overloaded", e.err.items);
    e.feed("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"late\"}}\n\n");
    try std.testing.expectEqualStrings("", e.text.items);

    // A stream that simply ends is a complete reply.
    var q = Stream.init(gpa, .openai);
    defer q.deinit();
    q.feed("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n");
    q.finish();
    try std.testing.expectEqual(Status.done, q.status);
    try std.testing.expectEqualStrings("hi", q.text.items);
}

test "agent: Google candidates and error bodies" {
    const gpa = std.testing.allocator;
    var s = Stream.init(gpa, .google);
    defer s.deinit();
    s.feed("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Run \"},{\"text\":\"pwd\"}],\"role\":\"model\"},\"index\":0}]}\r\n\r\n");
    s.finish();
    try std.testing.expectEqualStrings("Run pwd", s.text.items);
    try std.testing.expectEqual(Status.done, s.status);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("model 'x' not found", describeFailure(gpa, 404, "{\"error\":\"model 'x' not found\"}", &buf));
    try std.testing.expectEqualStrings("invalid x-api-key", describeFailure(gpa, 401, "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}", &buf));
    try std.testing.expectEqualStrings("The API key was refused (HTTP 401).", describeFailure(gpa, 401, "<html>nope</html>", &buf));
    try std.testing.expectEqualStrings("The server answered with HTTP 502.", describeFailure(gpa, 502, "", &buf));
}

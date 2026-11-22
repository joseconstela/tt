//! The hosting accounts: who tt is on each git host, for pull requests.
//! One per host, kept in the `accounts:` section of `~/.tt/config.yml`,
//! which only this file reads and writes (`config.zig` hands it each line
//! of the section and asks it to write the section back):
//!
//!   accounts:
//!     - host: github.com
//!       kind: github          # github | gitlab | bitbucket | gitea
//!       user: me              # Bitbucket: the account's e-mail; else optional
//!       token: "…"            # an access token, in the clear
//!       token_from: gh        # instead of `token`: gh | glab | git
//!
//! `token_from` keeps the secret out of the file: the token is asked of a
//! tool that already has it when it is needed (`gh auth token`, `glab
//! config get token`, `git credential fill`), on a thread of its own
//! (`TokenLookup`). Nothing is sent to a host with no account here.
const std = @import("std");
const hosts = @import("../hosts.zig");
const pr = @import("../model/pull_request.zig");

/// Where an account's token comes from.
pub const Source = enum {
    /// Written in the file.
    token,
    gh,
    glab,
    git,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .token => "Token",
            .gh => "gh CLI",
            .glab => "glab CLI",
            .git => "git credential",
        };
    }
};

pub const Account = struct {
    /// Stable for the run (not saved): what the settings page names a field by.
    uid: u32,
    host: []u8 = &.{},
    kind: pr.Kind = .github,
    user: []u8 = &.{},
    token: []u8 = &.{},
    source: Source = .token,

    fn deinit(self: *Account, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        gpa.free(self.user);
        gpa.free(self.token);
    }

    /// Enough to ask a host anything.
    pub fn usable(self: *const Account) bool {
        return self.host.len > 0 and (self.source != .token or self.token.len > 0);
    }
};

pub const Accounts = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Account) = .empty,
    next_uid: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Accounts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Accounts) void {
        for (self.items.items) |*a| a.deinit(self.gpa);
        self.items.deinit(self.gpa);
    }

    pub fn add(self: *Accounts) !*Account {
        try self.items.append(self.gpa, .{ .uid = self.next_uid });
        self.next_uid += 1;
        return &self.items.items[self.items.items.len - 1];
    }

    pub fn remove(self: *Accounts, uid: u32) void {
        for (self.items.items, 0..) |*a, i| {
            if (a.uid != uid) continue;
            a.deinit(self.gpa);
            _ = self.items.orderedRemove(i);
            return;
        }
    }

    pub fn find(self: *Accounts, uid: u32) ?*Account {
        for (self.items.items) |*a| if (a.uid == uid) return a;
        return null;
    }

    /// The account for a host, whatever the case of its name.
    pub fn forHost(self: *const Accounts, host: []const u8) ?*const Account {
        for (self.items.items) |*a| {
            if (std.ascii.eqlIgnoreCase(a.host, host)) return a;
        }
        return null;
    }

    /// Replaces an account's string (its host, user or token).
    pub fn set(self: *Accounts, slot: *[]u8, value: []const u8) void {
        const copy = self.gpa.dupe(u8, value) catch return;
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    // ── config.yml ──────────────────────────────────────────────────────
    /// One `key: value` of the section, its value already unquoted;
    /// `new_item` when the line began a list entry (`- `).
    pub fn parseEntry(self: *Accounts, new_item: bool, key: []const u8, value: []const u8) !void {
        if (new_item) _ = try self.add();
        if (self.items.items.len == 0) return;
        const a = &self.items.items[self.items.items.len - 1];
        if (std.mem.eql(u8, key, "host")) {
            self.set(&a.host, std.mem.trim(u8, value, " "));
        } else if (std.mem.eql(u8, key, "user")) {
            self.set(&a.user, value);
        } else if (std.mem.eql(u8, key, "token")) {
            self.set(&a.token, value);
        } else if (std.mem.eql(u8, key, "kind")) {
            if (std.meta.stringToEnum(pr.Kind, value)) |k| a.kind = k;
        } else if (std.mem.eql(u8, key, "token_from")) {
            if (std.meta.stringToEnum(Source, value)) |s| a.source = s;
        }
    }

    /// After a file is read: an entry with no host says nothing, and a
    /// host listed twice keeps its first entry.
    pub fn tidy(self: *Accounts) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const a = &self.items.items[i];
            var drop = a.host.len == 0;
            for (self.items.items[0..i]) |before| {
                if (std.ascii.eqlIgnoreCase(before.host, a.host)) drop = true;
            }
            if (drop) {
                a.deinit(self.gpa);
                _ = self.items.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Writes the section; nothing at all when there is no account.
    /// `scalar` writes a string the way the file's other values are written.
    pub fn write(self: *const Accounts, gpa: std.mem.Allocator, out: *std.ArrayList(u8), scalar: *const fn (std.mem.Allocator, *std.ArrayList(u8), []const u8) anyerror!void) !void {
        var any = false;
        for (self.items.items) |a| {
            if (a.host.len == 0) continue;
            if (!any) try out.appendSlice(gpa, "accounts:   # git hosts, for pull requests (Settings › Hosting)\n");
            any = true;
            try out.appendSlice(gpa, "  - host: ");
            try scalar(gpa, out, a.host);
            try out.print(gpa, "\n    kind: {s}\n", .{@tagName(a.kind)});
            if (a.user.len > 0) {
                try out.appendSlice(gpa, "    user: ");
                try scalar(gpa, out, a.user);
                try out.append(gpa, '\n');
            }
            if (a.source == .token) {
                try out.appendSlice(gpa, "    token: ");
                try scalar(gpa, out, a.token);
                try out.append(gpa, '\n');
            } else {
                try out.print(gpa, "    token_from: {s}\n", .{@tagName(a.source)});
            }
        }
    }
};

const lookup_env = [_][]const u8{ "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };

/// What a lookup found: the token, and the user when the tool names one.
pub const Credentials = struct {
    token: []u8 = &.{},
    user: []u8 = &.{},

    pub fn deinit(self: *Credentials, gpa: std.mem.Allocator) void {
        gpa.free(self.token);
        gpa.free(self.user);
    }
};

/// Asks the account's tool for its token; the caller's thread waits.
/// The token written in the file is returned as it is.
pub fn lookup(gpa: std.mem.Allocator, runner: hosts.Runner, source: Source, host: []const u8, token: []const u8) !Credentials {
    if (source == .token) return .{ .token = try gpa.dupe(u8, token) };
    const path = try hosts.toolPath(gpa);
    defer gpa.free(path);
    const env = [_][]const u8{ path, lookup_env[0], lookup_env[1] };
    switch (source) {
        .token => unreachable,
        .gh, .glab => {
            const argv: []const []const u8 = if (source == .gh) &.{ "gh", "auth", "token", "--hostname", host } else &.{ "glab", "config", "get", "token", "--host", host };
            var res = try runner.run(gpa, "/", argv, &env);
            defer res.deinit();
            const found = std.mem.trim(u8, res.stdout, " \r\n\t");
            if (!res.ok() or found.len == 0) return error.NoToken;
            return .{ .token = try gpa.dupe(u8, found) };
        },
        .git => {
            var question_buf: [512]u8 = undefined;
            const question = std.fmt.bufPrint(&question_buf, "protocol=https\nhost={s}\n\n", .{host}) catch return error.NoToken;
            var res = try runner.feed(gpa, "/", &.{ "git", "credential", "fill" }, &env, question);
            defer res.deinit();
            if (!res.ok()) return error.NoToken;
            return parseCredential(gpa, res.stdout);
        },
    }
}

/// What `git credential fill` prints: `key=value` lines; the password is
/// the token.
fn parseCredential(gpa: std.mem.Allocator, out: []const u8) !Credentials {
    var found: Credentials = .{};
    errdefer found.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, out, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "password=")) {
            gpa.free(found.token);
            found.token = try gpa.dupe(u8, line["password=".len..]);
        } else if (std.mem.startsWith(u8, line, "username=")) {
            gpa.free(found.user);
            found.user = try gpa.dupe(u8, line["username=".len..]);
        }
    }
    if (found.token.len == 0) return error.NoToken;
    return found;
}

/// A token asked for on a thread of its own, so a slow keychain prompt
/// never stops a frame. Poll `finished`, read `result`, then `destroy`.
pub const TokenLookup = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    source: Source,
    host: []u8,
    token: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// Null when nothing was found.
    result: ?Credentials = null,

    pub fn start(gpa: std.mem.Allocator, runner: hosts.Runner, account: *const Account) !*TokenLookup {
        const self = try gpa.create(TokenLookup);
        errdefer gpa.destroy(self);
        const host = try gpa.dupe(u8, account.host);
        errdefer gpa.free(host);
        const token = try gpa.dupe(u8, account.token);
        errdefer gpa.free(token);
        self.* = .{ .gpa = gpa, .runner = runner, .source = account.source, .host = host, .token = token };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *TokenLookup) void {
        defer self.done.store(true, .release);
        self.result = lookup(self.gpa, self.runner, self.source, self.host, self.token) catch null;
    }

    pub fn finished(self: *const TokenLookup) bool {
        return self.done.load(.acquire);
    }

    pub fn destroy(self: *TokenLookup) void {
        if (self.thread) |t| t.join();
        if (self.result) |*r| r.deinit(self.gpa);
        self.gpa.free(self.host);
        self.gpa.free(self.token);
        self.gpa.destroy(self);
    }
};

// ── tests ───────────────────────────────────────────────────────────────
fn plain(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) anyerror!void {
    try out.appendSlice(gpa, s);
}

test "the accounts section, read and written back" {
    const gpa = std.testing.allocator;
    var accounts = Accounts.init(gpa);
    defer accounts.deinit();
    try accounts.parseEntry(true, "host", "github.com");
    try accounts.parseEntry(false, "kind", "github");
    try accounts.parseEntry(false, "token_from", "gh");
    try accounts.parseEntry(true, "host", "git.example.com");
    try accounts.parseEntry(false, "kind", "gitea");
    try accounts.parseEntry(false, "user", "me");
    try accounts.parseEntry(false, "token", "s3cret");
    try accounts.parseEntry(false, "colour", "blue");
    // No host: nothing; a host twice: the first stands.
    try accounts.parseEntry(true, "kind", "gitlab");
    try accounts.parseEntry(true, "host", "GitHub.com");
    try accounts.parseEntry(false, "token", "other");
    accounts.tidy();
    try std.testing.expectEqual(@as(usize, 2), accounts.items.items.len);
    try std.testing.expectEqual(Source.gh, accounts.forHost("GITHUB.COM").?.source);
    try std.testing.expect(accounts.forHost("github.com").?.usable());
    try std.testing.expectEqual(pr.Kind.gitea, accounts.forHost("git.example.com").?.kind);
    try std.testing.expect(accounts.forHost("gitlab.com") == null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try accounts.write(gpa, &out, plain);
    try std.testing.expectEqualStrings(
        \\accounts:   # git hosts, for pull requests (Settings › Hosting)
        \\  - host: github.com
        \\    kind: github
        \\    token_from: gh
        \\  - host: git.example.com
        \\    kind: gitea
        \\    user: me
        \\    token: s3cret
        \\
    , out.items);

    // No account: the section is not written at all.
    var none = Accounts.init(gpa);
    defer none.deinit();
    out.clearRetainingCapacity();
    try none.write(gpa, &out, plain);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

const FakeTools = struct {
    asked: std.ArrayList(u8) = .empty,
    fed: std.ArrayList(u8) = .empty,

    fn runner(self: *FakeTools) hosts.Runner {
        return .{ .ptr = self, .runFn = run, .feedFn = feed };
    }

    fn note(self: *FakeTools, argv: []const []const u8) !void {
        self.asked.clearRetainingCapacity();
        for (argv) |a| {
            try self.asked.appendSlice(std.testing.allocator, a);
            try self.asked.append(std.testing.allocator, ' ');
        }
    }

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8) anyerror!hosts.Output {
        const self: *FakeTools = @ptrCast(@alignCast(ptr));
        try self.note(argv);
        const gh = std.mem.eql(u8, argv[0], "gh");
        return .{ .gpa = gpa, .stdout = try gpa.dupe(u8, if (gh) "from-gh\n" else ""), .stderr = try gpa.dupe(u8, ""), .status = if (gh) 0 else 1 };
    }

    fn feed(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8, input: []const u8) anyerror!hosts.Output {
        const self: *FakeTools = @ptrCast(@alignCast(ptr));
        try self.note(argv);
        try self.fed.appendSlice(std.testing.allocator, input);
        return .{ .gpa = gpa, .stdout = try gpa.dupe(u8, "protocol=https\nhost=h\nusername=me@example.invalid\npassword=from-git\n"), .stderr = try gpa.dupe(u8, ""), .status = 0 };
    }
};

test "a token: written down, or asked of the tool that keeps it" {
    const gpa = std.testing.allocator;
    var fake: FakeTools = .{};
    defer fake.asked.deinit(gpa);
    defer fake.fed.deinit(gpa);

    var written = try lookup(gpa, fake.runner(), .token, "github.com", "s3cret");
    defer written.deinit(gpa);
    try std.testing.expectEqualStrings("s3cret", written.token);
    try std.testing.expectEqual(@as(usize, 0), fake.asked.items.len);

    var gh = try lookup(gpa, fake.runner(), .gh, "github.com", "");
    defer gh.deinit(gpa);
    try std.testing.expectEqualStrings("from-gh", gh.token);
    try std.testing.expectEqualStrings("gh auth token --hostname github.com ", fake.asked.items);

    // glab has nothing for this host.
    try std.testing.expectError(error.NoToken, lookup(gpa, fake.runner(), .glab, "gitlab.com", ""));

    var git = try lookup(gpa, fake.runner(), .git, "bitbucket.org", "");
    defer git.deinit(gpa);
    try std.testing.expectEqualStrings("from-git", git.token);
    try std.testing.expectEqualStrings("me@example.invalid", git.user);
    try std.testing.expectEqualStrings("protocol=https\nhost=bitbucket.org\n\n", fake.fed.items);

    // The same, on a thread.
    var account: Account = .{ .uid = 1, .host = @constCast("github.com"), .source = .gh };
    const job = try TokenLookup.start(gpa, fake.runner(), &account);
    defer job.destroy();
    while (!job.finished()) std.Thread.yield() catch {};
    try std.testing.expectEqualStrings("from-gh", job.result.?.token);
}

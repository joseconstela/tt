//! The repository tab: a git client for one repository, in a tab of its
//! own. Down its left side its navigation (`view/nav.zig`); beside it the
//! view picked there: History (the commit graph and the selected commit's
//! detail), Changes (staging, the commit composer and the selected file's
//! diff), Stashes, and Pull Requests. Pull and Push sit on the navigation's
//! row for the branch checked out, Fetch on each remote's; the branch and
//! how far it is ahead and behind show in the tab's context line.
//!
//! This file puts the pieces together and draws nothing of its own: it
//! owns the clients (`client/git.zig` for the repository's status and
//! commands, `client/history.zig` for the log, `client/worktree.zig` for
//! the working tree's diffs), shows each view the data it needs, and runs
//! what the views asked for. Questions that need a box ("Revert this
//! commit?") go to the app through `Env.askConfirm` and come back in
//! `answered`.
//!
//! Pull requests come from the repository's host. Which host that is is
//! read from the remote's address; the account for it is the one in
//! Settings › Git › Hosting (`client/accounts.zig`). Nothing is asked of
//! a host before the Pull Requests view is first shown, and nothing at
//! all without an account for it: the view then says what is missing.
//!
//! A commit that fails (a hook that says no) opens everything it printed
//! as a text file in a tab beside this one.
//!
//! Across relaunches the tab keeps one record, `repo <folder> <view>`: the
//! folder it was opened on and the view on show.
const std = @import("std");
const tab_mod = @import("../../../tabs/tab.zig");
const viewer = @import("../../../tabs/viewer.zig");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const icons = @import("../../../gfx/icons.zig");
const records = @import("../../../records.zig");
const config = @import("../../../config.zig");
const EditCommand = @import("../../../events.zig").EditCommand;
const hosts = @import("../hosts.zig");
const git = @import("../client/git.zig");
const history_client = @import("../client/history.zig");
const worktree = @import("../client/worktree.zig");
const accounts = @import("../client/accounts.zig");
const forge = @import("../client/forge.zig");
const pull_files = @import("../client/pull_files.zig");
const pr = @import("../model/pull_request.zig");
const remote_url = @import("../model/remote_url.zig");
const pulls_view = @import("../view/pulls.zig");
const pull_view = @import("../view/pull_detail.zig");
const status_model = @import("../model/status.zig");
const log_mod = @import("../model/log.zig");
const nav_view = @import("../view/nav.zig");
const history_view = @import("../view/history.zig");
const detail_view = @import("../view/commit_detail.zig");
const changes_view = @import("../view/changes.zig");
const stashes_view = @import("../view/stashes.zig");
const kit = @import("../view/kit.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

/// What a confirmation box is about; the tag it comes back with.
const Question = enum(u32) { checkout, revert, cherry_pick, discard, drop_stash, merge, merge_method, commit_options };

pub const RepoTab = struct {
    pub const kind_label = "Repository";

    gpa: std.mem.Allocator,
    env: *tab_mod.Env,
    /// The folder the tab was opened on (the repository's root is read from it).
    dir: []u8,
    repo: git.Repo,
    history: history_client.History,
    detail: history_client.Detail,
    working: worktree.Working,
    focus: field.Focus,

    section: nav_view.Section = .history,
    nav: nav_view.View,
    list: history_view.View,
    commit: detail_view.View = .{},
    changes: changes_view.View,
    stashes: stashes_view.View = .{},

    /// The commit on show (its hash), and where it is in the log now.
    selected: std.ArrayList(u8) = .empty,
    selected_index: ?usize = null,
    selected_for: u64 = std.math.maxInt(u64),
    /// The file on show in Changes, and which side of it.
    file: std.ArrayList(u8) = .empty,
    file_staged: bool = false,
    /// The readings last acted on.
    seen_refs: u64 = std.math.maxInt(u64),
    seen_status: u64 = std.math.maxInt(u64),
    /// What the box on show would act on: a hash, a path, a stash's name.
    pending: std.ArrayList(u8) = .empty,
    pending_flag: bool = false,

    // ── pull requests ───────────────────────────────────────────────────
    pulls: pulls_view.View,
    pull: pull_view.View,
    files: pull_files.PullFiles,
    /// The host's side, once there is an account and its token is known.
    session: ?*forge.Session = null,
    lookup: ?*accounts.TokenLookup = null,
    /// What the session under way is for: the remote's address and the
    /// settings it was read with. A change of either starts over.
    hosting_for: std.ArrayList(u8) = .empty,
    /// The Pull Requests view has been looked at: the host may be asked.
    hosting_wanted: bool = false,
    /// Why there is no list (no remote, no account for its host …).
    notice: std.ArrayList(u8) = .empty,
    /// The remote the pull requests' commits are fetched from.
    remote_name: std.ArrayList(u8) = .empty,
    /// The pull request on show, when one is.
    pull_open: ?u64 = null,
    method: pr.MergeMethod = .merge,
    rows: std.ArrayList(pulls_view.Row) = .empty,

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        const gpa = env.gpa;
        var kept = try Kept.parse(gpa, args.saved);
        defer kept.deinit(gpa);
        const dir = args.cwd orelse kept.dir orelse env.launch_cwd;
        const self = try gpa.create(RepoTab);
        errdefer gpa.destroy(self);
        const runner = hosts.system();
        self.* = .{
            .gpa = gpa,
            .env = env,
            .dir = try gpa.dupe(u8, dir),
            .repo = git.Repo.init(gpa, runner),
            .history = history_client.History.init(gpa, runner),
            .detail = history_client.Detail.init(gpa, runner),
            .working = worktree.Working.init(gpa, runner),
            .focus = field.Focus.init(gpa),
            .section = kept.section,
            .nav = nav_view.View.init(gpa),
            .list = history_view.View.init(gpa),
            .changes = changes_view.View.init(gpa),
            .pulls = pulls_view.View.init(gpa),
            .pull = pull_view.View.init(gpa),
            .files = pull_files.PullFiles.init(gpa, runner),
        };
        self.repo.setDir(self.dir);
        return tab_mod.Tab.from(RepoTab, self);
    }

    pub fn deinit(self: *RepoTab) void {
        const gpa = self.gpa;
        self.repo.deinit();
        self.history.deinit();
        self.detail.deinit();
        self.working.deinit();
        self.focus.deinit();
        self.nav.deinit();
        self.list.deinit();
        self.changes.deinit();
        if (self.session) |s| s.destroy();
        if (self.lookup) |l| l.destroy();
        self.files.deinit();
        self.pulls.deinit();
        self.pull.deinit();
        self.hosting_for.deinit(gpa);
        self.notice.deinit(gpa);
        self.remote_name.deinit(gpa);
        self.rows.deinit(gpa);
        self.selected.deinit(gpa);
        self.file.deinit(gpa);
        self.pending.deinit(gpa);
        gpa.free(self.dir);
        gpa.destroy(self);
    }

    /// True when this tab is the repository `dir` is in.
    pub fn shows(self: *const RepoTab, dir: []const u8) bool {
        return std.mem.eql(u8, self.dir, dir) or self.repo.snapshot.contains(dir);
    }

    fn root(self: *const RepoTab) []const u8 {
        return self.repo.snapshot.root;
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *RepoTab, buf: []u8) []const u8 {
        const name = status_model.baseName(if (self.root().len > 0) self.root() else self.dir);
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }

    /// "main  ↑1 ↓2": the branch and how far it is from its upstream.
    pub fn info(self: *RepoTab, buf: []u8) []const u8 {
        const s = &self.repo.snapshot;
        if (!s.isRepo()) return if (self.repo.generation == 0) "" else "Not a git repository";
        const branch = if (s.detached) "detached HEAD" else s.branch;
        if (s.ahead > 0 and s.behind > 0) return std.fmt.bufPrint(buf, "{s}  ↑{d} ↓{d}", .{ branch, s.ahead, s.behind }) catch branch;
        if (s.ahead > 0) return std.fmt.bufPrint(buf, "{s}  ↑{d}", .{ branch, s.ahead }) catch branch;
        if (s.behind > 0) return std.fmt.bufPrint(buf, "{s}  ↓{d}", .{ branch, s.behind }) catch branch;
        return std.fmt.bufPrint(buf, "{s}", .{branch}) catch "";
    }

    pub fn status(self: *RepoTab) tab_mod.Status {
        return if (self.repo.cmd_label.len > 0) .running else .none;
    }

    /// The repository's root, so the files panel shows it.
    pub fn cwd(self: *RepoTab) []const u8 {
        return if (self.root().len > 0) self.root() else self.dir;
    }

    pub fn tick(self: *RepoTab, now: f64, active: bool) bool {
        var dirty = false;
        // A tab in the background reads the repository once, then rests
        // until it is looked at again (or has a command to see through).
        if (active or self.repo.generation == 0 or self.repo.busy() or self.repo.cmdRunning()) {
            if (self.repo.tick(now)) dirty = true;
        }
        while (self.repo.takeDone()) |done| {
            if (done.what == .commit) {
                if (done.ok) self.changes.committed(&self.focus) else self.showFailure();
            }
            dirty = true;
        }
        const r = self.root();
        if (r.len > 0 and self.repo.refs_generation != self.seen_refs) {
            self.seen_refs = self.repo.refs_generation;
            self.history.reload(r);
        }
        if (r.len > 0 and self.repo.generation != self.seen_status) {
            self.seen_status = self.repo.generation;
            self.working.refresh(r);
            self.keepFile();
        }
        if (self.history.tick()) dirty = true;
        self.keepSelection();
        if (self.detail.tick()) dirty = true;
        if (self.working.tick()) dirty = true;
        if (self.focus.tick(now)) dirty = true;
        if (self.tickHosting()) dirty = true;
        return dirty;
    }

    // ── the host ────────────────────────────────────────────────────────
    fn say(self: *RepoTab, comptime fmt: []const u8, args: anytype) void {
        self.notice.clearRetainingCapacity();
        self.notice.print(self.gpa, fmt, args) catch {};
    }

    fn dropHosting(self: *RepoTab) void {
        if (self.session) |s| s.destroy();
        self.session = null;
        if (self.lookup) |l| l.destroy();
        self.lookup = null;
        self.pull_open = null;
    }

    /// Works out the host from the remote and finds the account for it;
    /// again whenever the remote's address or the settings change.
    fn tickHosting(self: *RepoTab) bool {
        var dirty = false;
        const s = &self.repo.snapshot;
        if (self.hosting_wanted and s.isRepo()) {
            const cfg = config.get();
            const name = s.pushRemote() orelse "";
            const address = s.remoteUrl(name) orelse "";
            var key_buf: [1024]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}\x1f{d}", .{ address, cfg.version }) catch address;
            if (!std.mem.eql(u8, self.hosting_for.items, key)) {
                self.hosting_for.clearRetainingCapacity();
                self.hosting_for.appendSlice(self.gpa, key) catch {};
                self.dropHosting();
                self.notice.clearRetainingCapacity();
                self.remote_name.clearRetainingCapacity();
                self.remote_name.appendSlice(self.gpa, name) catch {};
                dirty = true;
                if (address.len == 0) {
                    self.say("This repository has no remote, so there is no host to ask for pull requests.", .{});
                } else if (remote_url.parse(address)) |remote| {
                    if (cfg.accounts.forHost(remote.host)) |account| {
                        if (!account.usable()) {
                            self.say("The account for {s} has no token yet (Settings › Git › Hosting).", .{remote.host});
                        } else {
                            self.lookup = accounts.TokenLookup.start(self.gpa, hosts.system(), account) catch null;
                            if (self.lookup == null) self.say("The account's token could not be looked up.", .{});
                        }
                    } else {
                        self.say("Pull requests come from {s}, and tt has no account there. Add one in Settings › Git › Hosting; until then nothing is sent to that host.", .{remote.host});
                    }
                } else {
                    self.say("The remote “{s}” points at {s}, which does not name a host tt can ask.", .{ name, address });
                }
            }
        }
        if (self.lookup) |l| if (l.finished()) {
            self.lookup = null;
            defer l.destroy();
            dirty = true;
            self.openSession(l);
        };
        if (self.session) |session| {
            if (session.tick()) dirty = true;
            while (session.takeDone()) |done| {
                dirty = true;
                if (!done.ok) continue;
                if (done.what == .reply) self.pull.dropReply();
                // What was done shows once the host is asked again.
                if (self.pull_open) |n| session.refresh(n);
                if (done.what == .merge or done.what == .update or done.what == .create) session.load(session.filter);
            }
        }
        if (self.files.tick()) dirty = true;
        // A pull request's first file is on show as soon as its files are known.
        if (self.pull_open != null and self.files.state == .ready and self.files.path.items.len == 0) {
            if (self.files.changes) |ch| if (ch.files.len > 0) self.files.select(ch.files[0].path);
        }
        return dirty;
    }

    /// The token is in: the session for the host, and its first list.
    fn openSession(self: *RepoTab, l: *accounts.TokenLookup) void {
        const s = &self.repo.snapshot;
        const address = s.remoteUrl(self.remote_name.items) orelse return;
        const remote = remote_url.parse(address) orelse return;
        const found = l.result orelse {
            self.say("No token for {s}: the tool the account takes it from has none for this host, or is not installed (Settings › Git › Hosting).", .{remote.host});
            return;
        };
        const cfg = config.get();
        const account = cfg.accounts.forHost(remote.host) orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const api = forge.apiBase(scratch.allocator(), account.kind, remote) catch return;
        const session = forge.Session.create(self.gpa, hosts.systemHttp(), .{
            .kind = account.kind,
            .api = api,
            .path = remote.path,
            .user = if (account.user.len > 0) account.user else found.user,
            .token = found.token,
        }) catch return;
        self.session = session;
        self.method = session.caps().merge_methods[0];
        session.load(.open);
    }

    fn openPull(self: *const RepoTab) ?pr.PullRequest {
        const session = self.session orelse return null;
        return session.find(self.pull_open orelse return null);
    }

    /// Shows a pull request: the host is asked about it and its head fetched.
    fn showPull(self: *RepoTab, number: u64) void {
        const session = self.session orelse return;
        const p = session.find(number) orelse return;
        self.pull_open = number;
        session.want(number);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const head_ref = forge.headRef(a, session.remote.kind, p) catch return;
        // A host that does not say where the base was: the base branch as last fetched.
        const base = if (p.base_sha.len > 0) p.base_sha else std.fmt.allocPrint(a, "{s}/{s}", .{ self.remote_name.items, p.base }) catch return;
        self.files.want(self.root(), self.remote_name.items, head_ref, p.base, base, p.head_sha);
    }

    /// A commit that failed has more to say than a line holds (a hook's
    /// report): all of it opens as a text file in a tab of its own.
    fn showFailure(self: *RepoTab) void {
        const output = self.repo.last_output.items;
        if (output.len == 0) return;
        var name: [160]u8 = undefined;
        const file = std.fmt.bufPrint(&name, "commit-output-{s}.txt", .{status_model.baseName(self.cwd())}) catch "commit-output.txt";
        const path = hosts.saveScratch(self.gpa, file, output) catch return;
        defer self.gpa.free(path);
        self.env.openFile(path);
    }

    /// The selected commit's place in the log as it is now; the newest
    /// commit when nothing is selected, or the one selected is gone.
    fn keepSelection(self: *RepoTab) void {
        if (self.selected_for == self.history.generation) return;
        self.selected_for = self.history.generation;
        self.selected_index = if (self.selected.items.len > 0) self.history.indexOf(self.selected.items) else null;
        if (self.selected_index == null and self.history.log.commits.items.len > 0) self.select(0);
    }

    fn select(self: *RepoTab, index: usize) void {
        const commits = self.history.log.commits.items;
        if (index >= commits.len) return;
        const c = commits[index];
        self.selected.clearRetainingCapacity();
        self.selected.appendSlice(self.gpa, c.hash) catch return;
        self.selected_index = index;
        self.detail.want(self.root(), c.hash, if (c.parents.len > 0) c.parents[0] else null);
    }

    fn selectedCommit(self: *const RepoTab) ?log_mod.Commit {
        const i = self.selected_index orelse return null;
        const commits = self.history.log.commits.items;
        return if (i < commits.len) commits[i] else null;
    }

    /// The file on show in Changes follows the status: when its side has
    /// nothing to show any more (it was staged, committed, discarded) the
    /// other side takes over, else the first change there is.
    fn keepFile(self: *RepoTab) void {
        const s = &self.repo.snapshot;
        if (self.file.items.len > 0) {
            for (s.entries.items) |e| {
                if (!std.mem.eql(u8, e.path, self.file.items)) continue;
                if (self.file_staged and e.staged()) return self.working.select(e.path, true, false);
                if (!self.file_staged and e.unstaged()) return self.working.select(e.path, false, e.untracked());
                if (e.staged()) return self.setFile(e.path, true, false);
                if (e.unstaged()) return self.setFile(e.path, false, e.untracked());
            }
        }
        for (s.entries.items) |e| {
            if (e.is_dir or e.ignored()) continue;
            if (e.staged()) return self.setFile(e.path, true, false);
            if (e.unstaged()) return self.setFile(e.path, false, e.untracked());
        }
        self.file.clearRetainingCapacity();
        self.working.deselect();
    }

    fn setFile(self: *RepoTab, path: []const u8, staged: bool, untracked: bool) void {
        self.file_staged = staged;
        if (!std.mem.eql(u8, self.file.items, path)) {
            // `path` may be the snapshot's: copy before anything reads it again.
            var fresh: std.ArrayList(u8) = .empty;
            fresh.appendSlice(self.gpa, path) catch return;
            self.file.deinit(self.gpa);
            self.file = fresh;
        }
        self.working.select(self.file.items, staged, untracked);
    }

    // ── keyboard ────────────────────────────────────────────────────────
    pub fn onText(self: *RepoTab, utf8: []const u8) void {
        if (self.focus.active()) self.focus.onText(utf8);
    }

    pub fn onMarkedText(self: *RepoTab, utf8: []const u8) void {
        if (self.focus.active()) self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *RepoTab, utf8: []const u8) void {
        if (self.focus.active()) self.focus.paste(utf8);
    }

    pub fn onEdit(self: *RepoTab, cmd: EditCommand) void {
        if (self.focus.active()) {
            switch (cmd) {
                .insert_newline, .insert_line_break => {
                    if (self.focus.id == nav_view.View.field_name) {
                        self.nav.submitName(&self.focus);
                    } else if (self.focus.id == changes_view.View.field_summary) {
                        self.changes.submit(&self.focus, &self.repo.snapshot);
                    } else if (self.pull.ownsFocus(&self.focus)) {
                        self.pull.submit(&self.focus);
                    }
                    self.run();
                },
                .cancel => {
                    self.nav.cancelName(&self.focus);
                    self.pull.dropReply();
                    self.focus.drop();
                },
                else => _ = self.focus.onEdit(cmd),
            }
            return;
        }
        if (self.section != .history) return;
        switch (cmd) {
            .move_up => self.list.step(self.historyState(), -1),
            .move_down => self.list.step(self.historyState(), 1),
            else => return,
        }
        self.run();
    }

    /// ⌘⇧↵ on the Changes view: Amend on, or the amend made.
    pub fn command(self: *RepoTab, cmd: tab_mod.Command) bool {
        if (cmd != .amend or self.section != .changes) return false;
        self.changes.amendKey(&self.focus, &self.repo.snapshot);
        self.run();
        return true;
    }

    pub fn onCtrl(self: *RepoTab, key: u8) void {
        if (self.focus.active()) _ = self.focus.onCtrl(key);
    }

    pub fn copy(self: *RepoTab, out: *std.ArrayList(u8), cut: bool) bool {
        if (self.focus.active()) return self.focus.copy(out, cut);
        // With no field focused, ⌘C copies the selected commit's hash.
        if (self.section == .history) if (self.selectedCommit()) |c| {
            out.appendSlice(self.gpa, c.hash) catch return false;
            return true;
        };
        return false;
    }

    pub fn hasMarkedText(self: *RepoTab) bool {
        return self.focus.hasMarkedText();
    }

    pub fn caretRect(self: *RepoTab) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    // ── drawing ─────────────────────────────────────────────────────────
    fn historyState(self: *const RepoTab) history_view.State {
        return .{
            .commits = self.history.log.commits.items,
            .rows = self.history.rows.items,
            .width = self.history.width,
            .selected = self.selected_index,
            .now = hosts.wallClock(),
            .loading = self.history.loading(),
            .loaded = self.history.loaded,
            .complete = self.history.complete,
            .generation = self.history.generation,
        };
    }

    pub fn draw(self: *RepoTab, ui: *Ui, rect: Rect, _: bool) void {
        const dl = ui.dl;
        dl.rect(rect, theme.bg);
        const s = &self.repo.snapshot;
        const nav_w = @min(nav_view.width, rect.w * 0.4);
        self.nav.draw(ui, &self.focus, .{ .x = rect.x, .y = rect.y, .w = nav_w, .h = rect.h }, .{
            .snapshot = s,
            .section = self.section,
            .tags = self.history.tags.items,
            .stashes = self.history.stashes.len,
            .pulls = if (self.session) |session| (if (session.filter == .open and session.loaded) session.pulls.items.len else null) else null,
            .busy = self.repo.cmdRunning(),
            .cmd_label = self.repo.cmd_label,
            .last_error = self.repo.last_error.items,
        });
        const body: Rect = .{ .x = rect.x + nav_w, .y = rect.y, .w = @max(0, rect.w - nav_w), .h = rect.h };
        switch (self.section) {
            .history => {
                // The detail pane gives way first when the tab is narrow.
                const detail_w: f32 = if (body.w >= 620) detail_view.width else 0;
                self.list.draw(ui, &self.focus, .{ .x = body.x, .y = body.y, .w = body.w - detail_w, .h = body.h }, self.historyState());
                if (detail_w > 0) self.commit.draw(ui, .{ .x = body.right() - detail_w, .y = body.y, .w = detail_w, .h = body.h }, .{
                    .commit = self.selectedCommit(),
                    .ready = self.detail.ready(),
                    .body = self.detail.body,
                    .date = self.detail.date,
                    .changes = if (self.detail.changes) |*c| c else null,
                    .busy = self.repo.cmdRunning(),
                });
            },
            .changes => self.changes.draw(ui, &self.focus, body, .{
                .snapshot = s,
                .staged_counts = self.working.staged,
                .unstaged_counts = self.working.unstaged,
                .selected = if (self.file.items.len > 0) .{ .path = self.file.items, .staged = self.file_staged } else null,
                .patch = if (self.working.patch) |*p| p else null,
                .busy = self.repo.cmdRunning(),
                .cmd_label = self.repo.cmd_label,
                .last_error = self.repo.last_error.items,
            }),
            .stashes => self.stashes.draw(ui, body, .{
                .stashes = self.history.stashes,
                .dirty = s.staged_count + s.unstaged_count > 0,
                .busy = self.repo.cmdRunning(),
                .cmd_label = self.repo.cmd_label,
                .last_error = self.repo.last_error.items,
            }),
            .pulls => self.drawPulls(ui, body),
        }
        self.run();
    }

    fn drawPulls(self: *RepoTab, ui: *Ui, body: Rect) void {
        self.hosting_wanted = true;
        const now = hosts.wallClock();
        const session = self.session orelse {
            const waiting = self.lookup != null or (self.notice.items.len == 0 and self.repo.generation == 0);
            self.pulls.draw(ui, &self.focus, body, .{ .rows = &.{}, .filter = .open, .loading = false, .loaded = false, .has_more = false, .err = "", .me = "", .now = now, .noun = "pull request", .notice = if (waiting) "Looking up the account…" else if (self.notice.items.len > 0) self.notice.items else "Reading the repository…" });
            return;
        };
        if (self.openPull()) |p| {
            self.pull.draw(ui, &self.focus, body, .{
                .pull = p,
                .detail = session.detail(p.number),
                .caps = session.caps(),
                .files = switch (self.files.state) {
                    .ready => .ready,
                    .failed => .failed,
                    .idle, .fetching => .fetching,
                },
                .changes = if (self.files.changes) |*c| c else null,
                .commits = self.files.commits,
                .selected = self.files.path.items,
                .patch = self.files.shown(),
                .now = now,
                .busy = session.acting() or self.repo.cmdRunning(),
                .action_error = if (session.action_error.items.len > 0) session.action_error.items else self.repo.last_error.items,
                .method = self.method,
            });
            return;
        }
        self.pull_open = null;
        self.rows.clearRetainingCapacity();
        for (session.pulls.items) |p| self.rows.append(self.gpa, .{ .pull = p, .detail = session.detail(p.number) }) catch break;
        self.pulls.draw(ui, &self.focus, body, .{
            .rows = self.rows.items,
            .filter = session.filter,
            .loading = session.loading(),
            .loaded = session.loaded,
            .has_more = session.next != null,
            .err = session.list_error.items,
            .me = session.me,
            .now = now,
            .noun = session.caps().noun,
        });
        // The rows on show are looked at closely, a few at a time.
        for (self.pulls.wanted[0..self.pulls.wanted_len]) |n| session.want(n);
    }

    // ── what the views asked for ────────────────────────────────────────
    fn run(self: *RepoTab) void {
        if (self.nav.takeIntent()) |intent| switch (intent) {
            .show => |section| {
                self.section = section;
                self.focus.drop();
            },
            .switch_branch => |name| self.repo.switchBranch(name),
            .switch_remote => |name| self.repo.switchRemote(name),
            .new_branch => |name| self.repo.newBranch(name),
            .pull => self.repo.pull(),
            .push => self.repo.push(),
            .fetch => |remote| self.repo.fetch(remote),
        };
        if (self.list.takeIntent()) |intent| switch (intent) {
            .select => |i| self.select(i),
            .more => self.history.more(),
        };
        if (self.commit.takeIntent()) |intent| self.runCommit(intent);
        if (self.changes.takeIntent()) |intent| switch (intent) {
            .select => |f| self.setFile(f.path, f.staged, f.untracked),
            .stage => |path| self.repo.stage(path),
            .unstage => |path| self.repo.unstage(path),
            .stage_all => self.repo.stageAll(),
            .unstage_all => self.repo.unstageAll(),
            .commit => |c| self.repo.commit(c.summary, .{ .description = c.description, .all = c.all, .amend = c.amend, .signoff = c.signoff, .no_verify = c.no_verify }),
            .options => |at| self.env.askChecks(self, @backingInt(Question.commit_options), &changes_view.option_rows, self.changes.optionChecks(), at.x, at.y),
            .discard => |d| {
                var heading: [200]u8 = undefined;
                self.ask(.discard, d.path, d.untracked, std.fmt.bufPrint(&heading, "Discard changes in “{s}”?", .{status_model.baseName(d.path)}) catch "Discard changes?", if (d.untracked)
                    "The file is not in git yet: it is deleted. This cannot be undone."
                else
                    "The file goes back to what the index has. This cannot be undone.", "Discard");
            },
            .split => |f| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.gpa);
                buf.print(self.gpa, "{s}/{s}", .{ self.root(), f.path }) catch return;
                self.env.openDiff(buf.items, .{ .staged = f.staged, .orig = f.orig });
            },
        };
        if (self.pulls.takeIntent()) |intent| if (self.session) |session| switch (intent) {
            .open => |n| self.showPull(n),
            .filter => |f| session.load(f),
            .more => session.more(),
            .reload => session.load(session.filter),
        };
        if (self.pull.takeIntent()) |intent| self.runPull(intent);
        if (self.stashes.takeIntent()) |intent| switch (intent) {
            .stash => self.repo.stashAll(),
            .apply => |name| self.repo.stashPop(name),
            .drop => |name| {
                var heading: [120]u8 = undefined;
                self.ask(.drop_stash, name, false, std.fmt.bufPrint(&heading, "Drop {s}?", .{name}) catch "Drop this stash?", "The changes it holds are thrown away. This cannot be undone.", "Drop");
            },
        };
    }

    fn runCommit(self: *RepoTab, intent: detail_view.Intent) void {
        const c = self.selectedCommit() orelse return;
        const merge = c.parents.len > 1;
        var heading: [120]u8 = undefined;
        var reason: [240]u8 = undefined;
        const branch = if (self.repo.snapshot.detached or self.repo.snapshot.branch.len == 0) "the commit checked out" else self.repo.snapshot.branch;
        switch (intent) {
            .open_file => |i| {
                const changes = self.detail.changes orelse return;
                if (!self.detail.ready() or i >= changes.files.len) return;
                const f = changes.files[i];
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.gpa);
                buf.print(self.gpa, "{s}/{s}", .{ self.root(), f.path }) catch return;
                self.env.openDiff(buf.items, .{ .orig = f.orig, .revs = .{ .left = if (c.parents.len > 0) c.parents[0] else null, .right = c.hash } });
            },
            .checkout => self.ask(.checkout, c.hash, false, std.fmt.bufPrint(&heading, "Check out {s}?", .{c.short()}) catch "Check out this commit?", "HEAD is detached at this commit: new commits belong to no branch until you make one.", "Checkout"),
            .revert => self.ask(.revert, c.hash, merge, std.fmt.bufPrint(&heading, "Revert {s}?", .{c.short()}) catch "Revert this commit?", std.fmt.bufPrint(&reason, "A new commit undoing it is added to {s}.", .{branch}) catch "", "Revert"),
            .cherry_pick => self.ask(.cherry_pick, c.hash, merge, std.fmt.bufPrint(&heading, "Cherry-pick {s}?", .{c.short()}) catch "Cherry-pick this commit?", std.fmt.bufPrint(&reason, "Its change is applied to {s} as a new commit.", .{branch}) catch "", "Cherry-pick"),
        }
    }

    fn runPull(self: *RepoTab, intent: pull_view.Intent) void {
        const session = self.session orelse return;
        const p = self.openPull() orelse return;
        switch (intent) {
            .back => {
                self.pull_open = null;
                self.focus.drop();
            },
            .checkout => {
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                const head_ref = forge.headRef(scratch.allocator(), session.remote.kind, p) catch return;
                self.repo.checkoutPull(self.remote_name.items, head_ref, p.head);
            },
            .select => |path| self.files.select(path),
            .reply => |r| session.reply(p, r.thread, r.text),
            .resolve => |thread| session.resolve(p, thread),
            .update => session.update(p),
            .browse => self.env.openUrl(p.url),
            .methods => |at| {
                const methods = session.caps().merge_methods;
                var labels: [8][]const u8 = undefined;
                var checked: ?usize = null;
                const n = @min(methods.len, labels.len);
                for (methods[0..n], 0..) |m, i| {
                    labels[i] = m.label();
                    if (m == self.method) checked = i;
                }
                self.env.askMenu(self, @backingInt(Question.merge_method), labels[0..n], checked, at.x, at.y);
            },
            .merge => {
                var heading: [160]u8 = undefined;
                var reason: [240]u8 = undefined;
                var number: [24]u8 = undefined;
                self.ask(.merge, std.fmt.bufPrint(&number, "{d}", .{p.number}) catch return, false, std.fmt.bufPrint(&heading, "{s} #{d}?", .{ self.method.label(), p.number }) catch "Merge?", std.fmt.bufPrint(&reason, "{s} goes into {s} on the host. This cannot be undone from here.", .{ p.head, p.base }) catch "", "Merge");
            },
        }
    }

    fn ask(self: *RepoTab, what: Question, subject: []const u8, flag: bool, heading: []const u8, reason: []const u8, ok: []const u8) void {
        self.pending.clearRetainingCapacity();
        self.pending.appendSlice(self.gpa, subject) catch return;
        self.pending_flag = flag;
        self.env.askConfirm(self, @backingInt(what), heading, reason, ok);
    }

    /// A box this tab asked for was accepted.
    pub fn answered(self: *RepoTab, tag: u32, choice: usize) void {
        const what = std.enums.fromInt(Question, tag) orelse return;
        if (what == .commit_options) return self.changes.toggleOption(choice);
        if (what == .merge_method) {
            const session = self.session orelse return;
            const methods = session.caps().merge_methods;
            if (choice < methods.len) self.method = methods[choice];
            return;
        }
        const subject = self.pending.items;
        if (subject.len == 0) return;
        switch (what) {
            .merge_method, .commit_options => {},
            .merge => if (self.session) |session| {
                // The pull request the box was about, if it is still the one on show.
                const number = std.fmt.parseInt(u64, subject, 10) catch 0;
                if (self.openPull()) |p| if (p.number == number) session.merge(p, self.method);
            },
            .checkout => self.repo.checkout(subject),
            .revert => self.repo.revert(subject, self.pending_flag),
            .cherry_pick => self.repo.cherryPick(subject, self.pending_flag),
            .discard => self.repo.discard(subject, self.pending_flag),
            .drop_stash => self.repo.stashDrop(subject),
        }
        self.pending.clearRetainingCapacity();
    }

    // ── across relaunches ───────────────────────────────────────────────
    const Kept = struct {
        dir: ?[]u8 = null,
        section: nav_view.Section = .history,

        fn parse(gpa: std.mem.Allocator, saved: ?[]const u8) !Kept {
            var out: Kept = .{};
            errdefer out.deinit(gpa);
            var lines = std.mem.splitScalar(u8, saved orelse return out, '\n');
            while (lines.next()) |line| {
                var f = std.mem.splitScalar(u8, line, '\t');
                if (!std.mem.eql(u8, f.next() orelse continue, "repo")) continue;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                out.dir = try gpa.dupe(u8, try records.unescape(&buf, gpa, f.next() orelse continue));
                out.section = std.meta.stringToEnum(nav_view.Section, f.next() orelse "") orelse .history;
                break;
            }
            return out;
        }

        fn deinit(self: *Kept, gpa: std.mem.Allocator) void {
            if (self.dir) |d| gpa.free(d);
        }
    };

    pub fn save(self: *RepoTab, out: *std.ArrayList(u8)) bool {
        const gpa = self.gpa;
        out.appendSlice(gpa, "repo\t") catch return false;
        records.escape(out, gpa, self.dir) catch return false;
        out.append(gpa, '\t') catch return false;
        out.appendSlice(gpa, @tagName(self.section)) catch return false;
        out.append(gpa, '\n') catch return false;
        return true;
    }

    pub fn saveVersion(self: *RepoTab) u64 {
        return viewer.keptVersion(self.dir, @tagName(self.section));
    }
};

test "repo tab: what it keeps comes back" {
    const gpa = std.testing.allocator;
    var k = try RepoTab.Kept.parse(gpa, "repo\t/r/my\\trepo\tchanges\n");
    defer k.deinit(gpa);
    try std.testing.expectEqualStrings("/r/my\trepo", k.dir.?);
    try std.testing.expectEqual(nav_view.Section.changes, k.section);
    // A view this build does not know falls back to the history.
    var other = try RepoTab.Kept.parse(gpa, "repo\t/r\tblame\n");
    defer other.deinit(gpa);
    try std.testing.expectEqual(nav_view.Section.history, other.section);
    var none = try RepoTab.Kept.parse(gpa, null);
    defer none.deinit(gpa);
    try std.testing.expect(none.dir == null);
}

//! Git for the repository feature: a folder's `git status` kept fresh on a
//! thread of its own, and the commands the views ask for (stage, unstage,
//! commit, discard, and on a thread pull, push, fetch and switching
//! branches). The only file of the feature that runs git; it does so
//! through the `Runner` it is handed (`hosts.zig`), so a test passes one
//! that answers from memory. What git prints is parsed in `model/status.zig`.
const std = @import("std");
const hosts = @import("../hosts.zig");
const status = @import("../model/status.zig");

const Snapshot = status.Snapshot;

const refresh_every: f64 = 2.0;
const status_env = [_][]const u8{ "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C" };
/// No prompts and no editor: a command that would need either fails
/// instead of hanging (a pull's merge message takes git's default).
const action_env = [_][]const u8{ "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "LC_ALL=C" };
/// Commands waiting their turn beyond this are refused.
const max_queued = 16;

/// One reading of the repository, run on its own thread.
const Job = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    dir: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    root: []u8 = &.{},
    status: []u8 = &.{},
    refs: []u8 = &.{},
    remotes: []u8 = &.{},
    head: []u8 = &.{},

    fn run(job: *Job) void {
        defer job.done.store(true, .release);
        var top = job.runner.run(job.gpa, job.dir, &.{ "git", "rev-parse", "--show-toplevel" }, &status_env) catch return;
        defer top.deinit();
        if (!top.ok()) return;
        const root = std.mem.trim(u8, top.stdout, " \r\n");
        if (root.len == 0) return;
        var st = job.runner.run(job.gpa, root, &.{ "git", "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=normal", "--ignored" }, &status_env) catch return;
        defer st.deinit();
        if (!st.ok()) return;
        job.root = job.gpa.dupe(u8, root) catch return;
        job.status = job.gpa.dupe(u8, st.stdout) catch return;
        // Each ref with the commit it points at, so a fetch or a commit shows as a change.
        var refs = job.runner.run(job.gpa, root, &.{ "git", "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/remotes" }, &status_env) catch return;
        defer refs.deinit();
        if (refs.ok()) job.refs = job.gpa.dupe(u8, refs.stdout) catch return;
        // Exits with 1 when the repository has no remote: nothing to read then.
        var remotes = job.runner.run(job.gpa, root, &.{ "git", "config", "--get-regexp", "^remote\\..*\\.url$" }, &status_env) catch return;
        defer remotes.deinit();
        if (remotes.ok()) job.remotes = job.gpa.dupe(u8, remotes.stdout) catch return;
        // Fails before the first commit: the head then stays empty.
        var head = job.runner.run(job.gpa, root, &.{ "git", "rev-parse", "-q", "--verify", "HEAD" }, &status_env) catch return;
        defer head.deinit();
        if (head.ok()) job.head = job.gpa.dupe(u8, std.mem.trim(u8, head.stdout, " \r\n")) catch return;
    }

    fn destroy(job: *Job) void {
        job.gpa.free(job.dir);
        job.gpa.free(job.root);
        job.gpa.free(job.status);
        job.gpa.free(job.refs);
        job.gpa.free(job.remotes);
        job.gpa.free(job.head);
        job.gpa.destroy(job);
    }
};

/// A list of commands, each its own argv, copied so the list outlives
/// whoever asked.
const Steps = struct {
    list: []const []const []const u8 = &.{},

    fn copy(gpa: std.mem.Allocator, steps: []const []const []const u8) !Steps {
        const list = try gpa.alloc([]const []const u8, steps.len);
        var done: usize = 0;
        errdefer {
            for (list[0..done]) |argv| freeArgv(gpa, argv);
            gpa.free(list);
        }
        for (steps) |argv| {
            const args = try gpa.alloc([]const u8, argv.len);
            var n: usize = 0;
            errdefer {
                for (args[0..n]) |a| gpa.free(a);
                gpa.free(args);
            }
            for (argv) |a| {
                args[n] = try gpa.dupe(u8, a);
                n += 1;
            }
            list[done] = args;
            done += 1;
        }
        return .{ .list = list };
    }

    fn freeArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }

    fn deinit(self: Steps, gpa: std.mem.Allocator) void {
        for (self.list) |argv| freeArgv(gpa, argv);
        gpa.free(self.list);
    }
};

/// What a command the views asked for was about; `Repo.takeDone` says
/// how each ended.
pub const What = enum { stage, unstage, discard, commit, fetch, pull, push, switch_branch, new_branch, checkout, revert, cherry_pick, stash };

pub const Done = struct { what: What, ok: bool };

/// Commands that change the repository, run in order on a thread of their
/// own; `Repo.tick` collects what they said.
const CmdJob = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    root: []u8,
    steps: Steps,
    what: What,
    /// What to call it while it runs ("Pulling…"); empty for a quick one.
    label: []const u8,
    /// Run the later steps even when one failed.
    keep_going: bool,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: bool = true,
    err: []u8 = &.{},
    /// Everything the first step that failed printed, under the command
    /// it was (`failureText`).
    output: []u8 = &.{},

    fn create(gpa: std.mem.Allocator, runner: hosts.Runner, root: []const u8, what: What, label: []const u8, steps: []const []const []const u8, keep_going: bool) !*CmdJob {
        const job = try gpa.create(CmdJob);
        errdefer gpa.destroy(job);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        job.* = .{ .gpa = gpa, .runner = runner, .root = root_copy, .steps = try Steps.copy(gpa, steps), .what = what, .label = label, .keep_going = keep_going };
        return job;
    }

    fn run(job: *CmdJob) void {
        defer job.done.store(true, .release);
        for (job.steps.list) |argv| {
            var res = job.runner.run(job.gpa, job.root, argv, &action_env) catch |err| {
                if (job.output.len == 0) job.output = failureText(job.gpa, argv, null, "", @errorName(err)) catch &.{};
                job.fail(@errorName(err));
                if (job.keep_going) continue;
                return;
            };
            defer res.deinit();
            if (res.ok()) continue;
            if (job.output.len == 0) job.output = failureText(job.gpa, argv, res.status, res.stdout, res.stderr) catch &.{};
            const line = res.firstErrorLine();
            job.fail(if (line.len > 0) line else "git failed");
            if (!job.keep_going) return;
        }
    }

    /// Keeps the first thing that went wrong.
    fn fail(job: *CmdJob, msg: []const u8) void {
        job.ok = false;
        if (job.err.len == 0) job.err = job.gpa.dupe(u8, msg) catch &.{};
    }

    fn destroy(job: *CmdJob) void {
        job.steps.deinit(job.gpa);
        job.gpa.free(job.root);
        job.gpa.free(job.err);
        job.gpa.free(job.output);
        job.gpa.destroy(job);
    }
};

/// A failed command as text to read: the command as it would be typed,
/// how it ended, then everything it printed (what it wrote to stdout,
/// then to stderr: a hook's report and git's own complaint). `exit` is
/// null when the command could not be started; `stderr` then says why.
pub fn failureText(gpa: std.mem.Allocator, argv: []const []const u8, exit: ?i32, stdout: []const u8, stderr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '$');
    for (argv) |arg| {
        try out.append(gpa, ' ');
        const plain = arg.len > 0 and for (arg) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_./=:@+,%", ch) == null) break false;
        } else true;
        if (plain) {
            try out.appendSlice(gpa, arg);
            continue;
        }
        // As a shell would take it back: single quotes, a quote inside as '\''.
        try out.append(gpa, '\'');
        for (arg) |ch| {
            if (ch == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, ch);
        }
        try out.append(gpa, '\'');
    }
    if (exit) |code| {
        if (code < 0) try out.appendSlice(gpa, "\nended by a signal\n") else try out.print(gpa, "\nexit status {d}\n", .{code});
    } else try out.appendSlice(gpa, "\ncould not be started\n");
    for ([_][]const u8{ stdout, stderr }) |part| {
        const text = std.mem.trim(u8, part, "\r\n");
        if (text.len == 0) continue;
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, text);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Commands that only read, run in order on a thread of their own, for
/// what each prints: how the history views ask git. Poll `finished`, read
/// `output`, then `destroy` (which waits for the thread).
pub const Query = struct {
    gpa: std.mem.Allocator,
    runner: hosts.Runner,
    root: []u8,
    steps: Steps,
    outputs: []?[]u8,
    /// Which commands exited with 0.
    succeeded: []bool,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(gpa: std.mem.Allocator, runner: hosts.Runner, root: []const u8, steps: []const []const []const u8) !*Query {
        const q = try gpa.create(Query);
        errdefer gpa.destroy(q);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const copied = try Steps.copy(gpa, steps);
        errdefer copied.deinit(gpa);
        const outputs = try gpa.alloc(?[]u8, steps.len);
        errdefer gpa.free(outputs);
        @memset(outputs, null);
        const succeeded = try gpa.alloc(bool, steps.len);
        errdefer gpa.free(succeeded);
        @memset(succeeded, false);
        q.* = .{ .gpa = gpa, .runner = runner, .root = root_copy, .steps = copied, .outputs = outputs, .succeeded = succeeded };
        q.thread = try std.Thread.spawn(.{}, run, .{q});
        return q;
    }

    fn run(q: *Query) void {
        defer q.done.store(true, .release);
        for (q.steps.list, 0..) |argv, i| {
            var res = q.runner.run(q.gpa, q.root, argv, &status_env) catch continue;
            defer res.deinit();
            q.outputs[i] = q.gpa.dupe(u8, res.stdout) catch null;
            q.succeeded[i] = res.ok() and q.outputs[i] != null;
        }
    }

    pub fn finished(q: *const Query) bool {
        return q.done.load(.acquire);
    }

    /// What command `i` printed; null when it failed. Only once `finished`.
    pub fn output(q: *const Query, i: usize) ?[]const u8 {
        return if (q.succeeded[i]) q.outputs[i] else null;
    }

    /// What command `i` printed whatever its exit status (`git diff
    /// --no-index` exits with 1 when the files differ); null when it
    /// could not be run.
    pub fn printed(q: *const Query, i: usize) ?[]const u8 {
        return q.outputs[i];
    }

    pub fn destroy(q: *Query) void {
        if (q.thread) |t| t.join();
        for (q.outputs) |o| if (o) |bytes| q.gpa.free(bytes);
        q.gpa.free(q.outputs);
        q.gpa.free(q.succeeded);
        q.steps.deinit(q.gpa);
        q.gpa.free(q.root);
        q.gpa.destroy(q);
    }
};

pub const Repo = struct {
    gpa: std.mem.Allocator,
    /// What runs git: the system's processes, or a test's stand-in.
    runner: hosts.Runner,
    /// The folder the status is wanted for.
    dir: std.ArrayList(u8) = .empty,
    snapshot: Snapshot,
    /// What the snapshot was parsed from, to skip readings that say the same.
    raw_seen: std.ArrayList(u8) = .empty,
    refs_seen: std.ArrayList(u8) = .empty,
    remotes_seen: std.ArrayList(u8) = .empty,
    /// What the last failed command said (the views show it).
    last_error: std.ArrayList(u8) = .empty,
    /// The whole of it: the command that failed and everything it
    /// printed (`failureText`). What a failed commit is opened as.
    last_output: std.ArrayList(u8) = .empty,
    thread: ?std.Thread = null,
    job: ?*Job = null,
    last_run: f64 = -1e9,
    want_refresh: bool = true,
    /// How long to wait between readings: `refresh_every`, stretched
    /// (up to 30 s) when the last one took long, so a huge repository
    /// does not keep a core busy.
    interval: f64 = refresh_every,
    /// Set whenever a reading of the repository has come in.
    generation: u64 = 0,
    /// Set whenever the commits changed: a ref moved, appeared or went, or
    /// HEAD points elsewhere. What the history is read again for.
    refs_generation: u64 = 0,
    /// The command under way, if one is, and the ones waiting behind it.
    cmd: ?*CmdJob = null,
    cmd_thread: ?std.Thread = null,
    queue: std.ArrayList(*CmdJob) = .empty,
    /// What to call the command under way ("Pulling…"), "" for a quick one.
    cmd_label: []const u8 = "",
    /// How the commands that finished ended, until `takeDone`.
    finished: std.ArrayList(Done) = .empty,

    pub fn init(gpa: std.mem.Allocator, runner: hosts.Runner) Repo {
        return .{ .gpa = gpa, .runner = runner, .snapshot = Snapshot.init(gpa) };
    }

    pub fn deinit(self: *Repo) void {
        if (self.thread) |t| t.join();
        if (self.job) |j| j.destroy();
        if (self.cmd_thread) |t| t.join();
        if (self.cmd) |j| j.destroy();
        for (self.queue.items) |j| j.destroy();
        self.queue.deinit(self.gpa);
        self.finished.deinit(self.gpa);
        self.snapshot.deinit();
        self.dir.deinit(self.gpa);
        self.raw_seen.deinit(self.gpa);
        self.refs_seen.deinit(self.gpa);
        self.remotes_seen.deinit(self.gpa);
        self.last_error.deinit(self.gpa);
        self.last_output.deinit(self.gpa);
    }

    /// Points the repository at `dir` (a fresh reading follows at once).
    pub fn setDir(self: *Repo, dir: []const u8) void {
        if (std.mem.eql(u8, self.dir.items, dir)) return;
        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(self.gpa, dir) catch return;
        self.want_refresh = true;
    }

    pub fn refreshSoon(self: *Repo) void {
        self.want_refresh = true;
    }

    /// True while a reading is on its way.
    pub fn busy(self: *const Repo) bool {
        return self.job != null;
    }

    /// True while a command runs or waits its turn.
    pub fn cmdRunning(self: *const Repo) bool {
        return self.cmd != null;
    }

    /// Whether `dir` is inside the repository last read.
    pub fn isRepoFor(self: *const Repo, dir: []const u8) bool {
        return self.snapshot.contains(dir);
    }

    /// How the next finished command ended, once; null when none has.
    pub fn takeDone(self: *Repo) ?Done {
        if (self.finished.items.len == 0) return null;
        return self.finished.orderedRemove(0);
    }

    /// Starts and collects readings and commands. True when something the
    /// views show changed.
    pub fn tick(self: *Repo, now: f64) bool {
        var changed = self.collectCmd();
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return changed;
            if (self.thread) |t| t.join();
            self.thread = null;
            self.job = null;
            defer job.destroy();
            self.interval = std.math.clamp((now - self.last_run) * 5, refresh_every, 30);
            if (self.adopt(job)) changed = true;
        }
        if (self.dir.items.len > 0 and (self.want_refresh or now - self.last_run >= self.interval)) self.start(now);
        return changed;
    }

    /// Takes the command under way off when it is done and starts the
    /// next one waiting. True when one finished.
    fn collectCmd(self: *Repo) bool {
        const job = self.cmd orelse return false;
        if (!job.done.load(.acquire)) return false;
        if (self.cmd_thread) |t| t.join();
        self.cmd_thread = null;
        self.cmd = null;
        self.cmd_label = "";
        defer job.destroy();
        if (job.ok) self.last_error.clearRetainingCapacity() else self.setError(job.err);
        if (!job.ok) {
            self.last_output.clearRetainingCapacity();
            self.last_output.appendSlice(self.gpa, job.output) catch {};
        }
        self.finished.append(self.gpa, .{ .what = job.what, .ok = job.ok }) catch {};
        self.want_refresh = true;
        self.launchNext();
        return true;
    }

    fn launchNext(self: *Repo) void {
        while (self.cmd == null and self.queue.items.len > 0) {
            const next = self.queue.orderedRemove(0);
            self.cmd_thread = std.Thread.spawn(.{}, CmdJob.run, .{next}) catch {
                next.destroy();
                continue;
            };
            self.cmd = next;
            self.cmd_label = next.label;
        }
    }

    fn start(self: *Repo, now: f64) void {
        const job = self.gpa.create(Job) catch return;
        job.* = .{ .gpa = self.gpa, .runner = self.runner, .dir = self.gpa.dupe(u8, self.dir.items) catch {
            self.gpa.destroy(job);
            return;
        } };
        self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            job.destroy();
            return;
        };
        self.job = job;
        self.want_refresh = false;
        self.last_run = now;
    }

    fn adopt(self: *Repo, job: *Job) bool {
        const same_root = std.mem.eql(u8, self.snapshot.root, job.root);
        const same_dir = std.mem.eql(u8, self.snapshot.dir, job.dir);
        const same_refs = std.mem.eql(u8, self.refs_seen.items, job.refs);
        const same_remotes = std.mem.eql(u8, self.remotes_seen.items, job.remotes);
        const same_head = std.mem.eql(u8, self.snapshot.head, job.head);
        if (same_root and same_dir and same_refs and same_remotes and same_head and std.mem.eql(u8, self.raw_seen.items, job.status)) return false;
        var fresh = status.parse(self.gpa, job.dir, job.root, job.status) catch return false;
        fresh.parseRefs(job.refs) catch {};
        fresh.parseRemotes(job.remotes) catch {};
        fresh.head = self.gpa.dupe(u8, job.head) catch &.{};
        self.snapshot.deinit();
        self.snapshot = fresh;
        fresh = undefined;
        self.raw_seen.clearRetainingCapacity();
        self.raw_seen.appendSlice(self.gpa, job.status) catch {};
        self.refs_seen.clearRetainingCapacity();
        self.refs_seen.appendSlice(self.gpa, job.refs) catch {};
        self.remotes_seen.clearRetainingCapacity();
        self.remotes_seen.appendSlice(self.gpa, job.remotes) catch {};
        self.generation +%= 1;
        if (!same_root or !same_refs or !same_head) self.refs_generation +%= 1;
        return true;
    }

    // ── commands ────────────────────────────────────────────────────────
    fn setError(self: *Repo, msg: []const u8) void {
        self.last_error.clearRetainingCapacity();
        // git prefixes with "fatal: " / "error: "; the views have little room.
        var m = msg;
        for ([_][]const u8{ "fatal: ", "error: " }) |p| {
            if (std.mem.startsWith(u8, m, p)) m = m[p.len..];
        }
        self.last_error.appendSlice(self.gpa, m) catch {};
    }

    /// Queues `steps` (each an argv) to run in the repository's root, one
    /// after another, behind whatever is already running: nothing here
    /// waits for git. `label` says what it is meanwhile ("" for a quick
    /// one); `takeDone` says how it ended, `last_error` what went wrong.
    fn startCmd(self: *Repo, what: What, label: []const u8, steps: []const []const []const u8, keep_going: bool) void {
        if (!self.snapshot.isRepo()) return;
        if (self.queue.items.len >= max_queued) {
            self.setError("Too many commands are waiting.");
            return;
        }
        const job = CmdJob.create(self.gpa, self.runner, self.snapshot.root, what, label, steps, keep_going) catch return;
        self.queue.append(self.gpa, job) catch {
            job.destroy();
            return;
        };
        self.last_error.clearRetainingCapacity();
        self.launchNext();
    }

    fn one(self: *Repo, what: What, label: []const u8, argv: []const []const u8) void {
        self.startCmd(what, label, &.{argv}, false);
    }

    pub fn fetchAll(self: *Repo) void {
        self.one(.fetch, "Fetching…", &.{ "git", "fetch", "--all", "--prune" });
    }

    /// Brings one remote's branches up to date, dropping the ones it no longer has.
    pub fn fetch(self: *Repo, remote: []const u8) void {
        self.one(.fetch, "Fetching…", &.{ "git", "fetch", "--prune", remote });
    }

    /// Checks a local branch out.
    pub fn switchBranch(self: *Repo, name: []const u8) void {
        self.one(.switch_branch, "Switching…", &.{ "git", "switch", name });
    }

    /// Checks a remote branch (`origin/x`) out as a local `x` tracking it.
    pub fn switchRemote(self: *Repo, remote_short: []const u8) void {
        self.one(.switch_branch, "Switching…", &.{ "git", "switch", "--track", remote_short });
    }

    /// A new branch at HEAD, checked out.
    pub fn newBranch(self: *Repo, name: []const u8) void {
        self.one(.new_branch, "Creating branch…", &.{ "git", "switch", "-c", name });
    }

    /// Checks a commit out, leaving HEAD detached at it.
    pub fn checkout(self: *Repo, rev: []const u8) void {
        self.one(.checkout, "Checking out…", &.{ "git", "switch", "--detach", rev });
    }

    /// A new commit undoing `rev` (`mainline`: a merge is undone against
    /// its first parent).
    pub fn revert(self: *Repo, rev: []const u8, mainline: bool) void {
        if (mainline) {
            self.one(.revert, "Reverting…", &.{ "git", "revert", "--no-edit", "-m", "1", rev });
        } else {
            self.one(.revert, "Reverting…", &.{ "git", "revert", "--no-edit", rev });
        }
    }

    /// `rev`'s change again, as a new commit on the branch checked out.
    pub fn cherryPick(self: *Repo, rev: []const u8, mainline: bool) void {
        if (mainline) {
            self.one(.cherry_pick, "Cherry-picking…", &.{ "git", "cherry-pick", "-m", "1", rev });
        } else {
            self.one(.cherry_pick, "Cherry-picking…", &.{ "git", "cherry-pick", rev });
        }
    }

    pub fn pull(self: *Repo) void {
        self.one(.pull, "Pulling…", &.{ "git", "pull" });
    }

    /// Pushes the branch; one without an upstream yet is published to the
    /// repository's remote (`origin` when there is one by that name, else
    /// the first) and starts tracking it.
    pub fn push(self: *Repo) void {
        const s = &self.snapshot;
        if (s.upstream.len > 0) return self.one(.push, "Pushing…", &.{ "git", "push" });
        if (s.branch.len == 0 or s.detached or s.unborn) return;
        const remote = s.pushRemote() orelse {
            self.setError("This repository has no remote to push to.");
            return;
        };
        self.one(.push, "Publishing…", &.{ "git", "push", "-u", remote, s.branch });
    }

    pub fn stage(self: *Repo, rel: []const u8) void {
        self.one(.stage, "", &.{ "git", "add", "-A", "--", rel });
    }

    pub fn stageAll(self: *Repo) void {
        self.one(.stage, "", &.{ "git", "add", "-A" });
    }

    pub fn unstage(self: *Repo, rel: []const u8) void {
        self.one(.unstage, "", &.{ "git", "reset", "-q", "--", rel });
    }

    pub fn unstageAll(self: *Repo) void {
        self.one(.unstage, "", &.{ "git", "reset", "-q" });
    }

    /// Throws the worktree changes of `rel` away: a new file is deleted, a
    /// tracked one goes back to what the index has.
    pub fn discard(self: *Repo, rel: []const u8, untracked: bool) void {
        if (untracked) {
            self.one(.discard, "", &.{ "git", "clean", "-f", "-d", "-q", "--", rel });
        } else {
            self.one(.discard, "", &.{ "git", "restore", "--worktree", "--", rel });
        }
    }

    /// Throws every worktree change away, new files included.
    pub fn discardAll(self: *Repo) void {
        self.startCmd(.discard, "", &.{
            &.{ "git", "restore", "--worktree", "--", "." },
            &.{ "git", "clean", "-f", "-d", "-q" },
        }, true);
    }

    pub const CommitOptions = struct {
        /// A second paragraph under the message.
        description: []const u8 = "",
        /// Stage everything first.
        all: bool = false,
        /// Replace the last commit instead of adding one. With no
        /// message, the last commit keeps its own.
        amend: bool = false,
        /// Add a `Signed-off-by` line for the committer.
        signoff: bool = false,
        /// Skip the pre-commit and commit-msg hooks.
        no_verify: bool = false,
    };

    /// Commits what is staged with `message`. A hook may take its time:
    /// "Committing…" shows meanwhile.
    pub fn commit(self: *Repo, message: []const u8, options: CommitOptions) void {
        var argv_buf: [12][]const u8 = undefined;
        var n: usize = 0;
        for ([_][]const u8{ "git", "commit", "-q" }) |a| {
            argv_buf[n] = a;
            n += 1;
        }
        if (message.len > 0) {
            argv_buf[n] = "-m";
            argv_buf[n + 1] = message;
            n += 2;
            if (options.description.len > 0) {
                argv_buf[n] = "-m";
                argv_buf[n + 1] = options.description;
                n += 2;
            }
        } else if (options.amend) {
            // Nothing new to say: the commit keeps the message it has.
            argv_buf[n] = "--no-edit";
            n += 1;
        }
        for ([_]struct { on: bool, flag: []const u8 }{
            .{ .on = options.amend, .flag = "--amend" },
            .{ .on = options.signoff, .flag = "--signoff" },
            .{ .on = options.no_verify, .flag = "--no-verify" },
        }) |opt| {
            if (!opt.on) continue;
            argv_buf[n] = opt.flag;
            n += 1;
        }
        const argv: []const []const u8 = argv_buf[0..n];
        if (options.all) {
            self.startCmd(.commit, "Committing…", &.{ &.{ "git", "add", "-A" }, argv }, false);
        } else {
            self.startCmd(.commit, "Committing…", &.{argv}, false);
        }
    }

    /// Puts every change away on the stash, new files included.
    pub fn stashAll(self: *Repo) void {
        self.one(.stash, "Stashing…", &.{ "git", "stash", "push", "--include-untracked" });
    }

    /// Checks a pull request's branch out: the local branch of that name
    /// when there is one, else a new one at the head just fetched from
    /// `remote` through `head_ref`.
    pub fn checkoutPull(self: *Repo, remote: []const u8, head_ref: []const u8, branch: []const u8) void {
        if (self.snapshot.hasBranch(branch)) return self.switchBranch(branch);
        self.startCmd(.checkout, "Checking out…", &.{
            &.{ "git", "fetch", remote, head_ref },
            &.{ "git", "switch", "-c", branch, "FETCH_HEAD" },
        }, false);
    }

    /// Brings a stash (`stash@{0}`) back and drops it from the list.
    pub fn stashPop(self: *Repo, name: []const u8) void {
        self.one(.stash, "Applying stash…", &.{ "git", "stash", "pop", name });
    }

    pub fn stashDrop(self: *Repo, name: []const u8) void {
        self.one(.stash, "", &.{ "git", "stash", "drop", name });
    }

    /// Waits for every command asked for to end (a test's way; the app
    /// polls `tick`).
    fn drain(self: *Repo) void {
        while (self.cmd) |job| {
            while (!job.done.load(.acquire)) std.Thread.yield() catch {};
            _ = self.collectCmd();
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────
/// A runner that answers from memory and remembers what it was asked.
const FakeGit = struct {
    /// Every command asked for, one a line.
    asked: std.ArrayList(u8) = .empty,
    /// The command (its `git` subcommand) that fails.
    fail: []const u8 = "",
    head: []const u8 = "1111111111111111111111111111111111111111",

    fn runner(self: *FakeGit) hosts.Runner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, argv: []const []const u8, _: []const []const u8) anyerror!hosts.Output {
        const self: *FakeGit = @ptrCast(@alignCast(ptr));
        const t = std.testing.allocator;
        for (argv, 0..) |a, i| {
            if (i > 0) try self.asked.append(t, ' ');
            try self.asked.appendSlice(t, a);
        }
        try self.asked.append(t, '\n');
        const sub = if (argv.len > 1) argv[1] else "";
        const out: []const u8 = if (std.mem.eql(u8, sub, "rev-parse"))
            (if (std.mem.eql(u8, argv[2], "--show-toplevel")) "/r\n" else self.head)
        else if (std.mem.eql(u8, sub, "status"))
            "## main [ahead 2]\x00 M a.txt\x00?? b.txt\x00"
        else if (std.mem.eql(u8, sub, "for-each-ref"))
            "refs/heads/main 1111111111111111111111111111111111111111\nrefs/remotes/upstream/main 2222222222222222222222222222222222222222\n"
        else if (std.mem.eql(u8, sub, "config"))
            "remote.upstream.url git@example.invalid:acme/repo.git\nremote.fork.url git@example.invalid:me/repo.git\n"
        else
            "said";
        const failed = self.fail.len > 0 and std.mem.eql(u8, sub, self.fail);
        return .{
            .gpa = gpa,
            .stdout = try gpa.dupe(u8, out),
            .stderr = try gpa.dupe(u8, if (failed) "fatal: nothing to do\nmore\n" else ""),
            .status = if (failed) 1 else 0,
        };
    }

    fn read(self: *FakeGit, repo: *Repo) !bool {
        const gpa = std.testing.allocator;
        const job = try gpa.create(Job);
        job.* = .{ .gpa = gpa, .runner = repo.runner, .dir = try gpa.dupe(u8, "/r") };
        defer job.destroy();
        Job.run(job);
        self.asked.clearRetainingCapacity();
        return repo.adopt(job);
    }
};

test "a reading becomes the snapshot, and commands go through the runner" {
    const gpa = std.testing.allocator;
    var fake: FakeGit = .{};
    defer fake.asked.deinit(gpa);
    var repo = Repo.init(gpa, fake.runner());
    defer repo.deinit();

    // Nothing is run for a folder that is not a repository yet.
    repo.stage("a.txt");
    repo.drain();
    try std.testing.expectEqual(@as(usize, 0), fake.asked.items.len);
    try std.testing.expect(repo.takeDone() == null);

    try std.testing.expect(try fake.read(&repo));
    try std.testing.expectEqualStrings("/r", repo.snapshot.root);
    try std.testing.expectEqualStrings("main", repo.snapshot.branch);
    try std.testing.expectEqual(@as(u32, 2), repo.snapshot.ahead);
    try std.testing.expectEqual(@as(u32, 2), repo.snapshot.unstaged_count);
    try std.testing.expect(repo.snapshot.hasBranch("main"));
    try std.testing.expectEqualStrings("upstream/main", repo.snapshot.remotes.items[0]);
    try std.testing.expectEqualStrings(fake.head, repo.snapshot.head);
    try std.testing.expectEqual(@as(u64, 1), repo.refs_generation);
    // The same reading again changes nothing.
    try std.testing.expect(!try fake.read(&repo));
    // A commit moves HEAD: the commits changed.
    fake.head = "3333333333333333333333333333333333333333";
    try std.testing.expect(try fake.read(&repo));
    try std.testing.expectEqual(@as(u64, 2), repo.refs_generation);

    repo.stage("a b.txt");
    repo.discard("b.txt", true);
    repo.drain();
    try std.testing.expectEqualStrings("git add -A -- a b.txt\ngit clean -f -d -q -- b.txt\n", fake.asked.items);
    try std.testing.expectEqual(Done{ .what = .stage, .ok = true }, repo.takeDone().?);
    try std.testing.expectEqual(Done{ .what = .discard, .ok = true }, repo.takeDone().?);
    try std.testing.expect(repo.takeDone() == null);

    // No upstream: published to the remote there is, not to a guessed `origin`.
    fake.asked.clearRetainingCapacity();
    repo.push();
    repo.drain();
    try std.testing.expectEqualStrings("git push -u upstream main\n", fake.asked.items);
    _ = repo.takeDone();
}

test "a commit: its steps in order, and what a failure leaves" {
    const gpa = std.testing.allocator;
    var fake: FakeGit = .{};
    defer fake.asked.deinit(gpa);
    var repo = Repo.init(gpa, fake.runner());
    defer repo.deinit();
    _ = try fake.read(&repo);

    repo.commit("msg", .{ .description = "more words", .all = true, .amend = true });
    repo.drain();
    try std.testing.expectEqualStrings("git add -A\ngit commit -q -m msg -m more words --amend\n", fake.asked.items);
    try std.testing.expectEqual(Done{ .what = .commit, .ok = true }, repo.takeDone().?);

    // The options, and an amend with nothing new to say.
    fake.asked.clearRetainingCapacity();
    repo.commit("msg", .{ .signoff = true, .no_verify = true });
    repo.commit("", .{ .amend = true, .signoff = true });
    repo.drain();
    try std.testing.expectEqualStrings("git commit -q -m msg --signoff --no-verify\ngit commit -q --no-edit --amend --signoff\n", fake.asked.items);
    _ = repo.takeDone();
    _ = repo.takeDone();

    // Staging fails: the commit is not tried, and git's first line is kept without its prefix.
    fake.asked.clearRetainingCapacity();
    fake.fail = "add";
    repo.commit("msg", .{ .all = true });
    repo.drain();
    try std.testing.expectEqualStrings("git add -A\n", fake.asked.items);
    try std.testing.expectEqual(Done{ .what = .commit, .ok = false }, repo.takeDone().?);
    try std.testing.expectEqualStrings("nothing to do", repo.last_error.items);
    // The whole of what the failing step said is kept, to be read in full.
    try std.testing.expectEqualStrings("$ git add -A\nexit status 1\n\nsaid\n\nfatal: nothing to do\nmore\n", repo.last_output.items);

    // Discarding everything cleans up even when restoring failed.
    fake.asked.clearRetainingCapacity();
    fake.fail = "restore";
    repo.discardAll();
    repo.drain();
    try std.testing.expectEqualStrings("git restore --worktree -- .\ngit clean -f -d -q\n", fake.asked.items);
    try std.testing.expectEqual(Done{ .what = .discard, .ok = false }, repo.takeDone().?);
}

test "a failed command as text" {
    const gpa = std.testing.allocator;
    const text = try failureText(gpa, &.{ "git", "commit", "-q", "-m", "fix: it's done", "--amend" }, 1, "lint: 2 problems\n  src/a.js:3 unused\n\n", "error: hook declined\n");
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\$ git commit -q -m 'fix: it'\''s done' --amend
        \\exit status 1
        \\
        \\lint: 2 problems
        \\  src/a.js:3 unused
        \\
        \\error: hook declined
        \\
    , text);
    const unstarted = try failureText(gpa, &.{ "git", "commit" }, null, "", "FileNotFound");
    defer gpa.free(unstarted);
    try std.testing.expectEqualStrings("$ git commit\ncould not be started\n\nFileNotFound\n", unstarted);
}

test "a query: what each command printed" {
    const gpa = std.testing.allocator;
    var fake: FakeGit = .{ .fail = "log" };
    defer fake.asked.deinit(gpa);
    const q = try Query.start(gpa, fake.runner(), "/r", &.{ &.{ "git", "tag" }, &.{ "git", "log" }, &.{ "git", "remote" } });
    defer q.destroy();
    while (!q.finished()) std.Thread.yield() catch {};
    try std.testing.expectEqualStrings("said", q.output(0).?);
    try std.testing.expect(q.output(1) == null);
    try std.testing.expectEqualStrings("said", q.printed(1).?);
    try std.testing.expectEqualStrings("said", q.output(2).?);
}

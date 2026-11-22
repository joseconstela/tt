//! The Git view as the files panel mounts it: the live repository
//! (`client/git.zig`) and its view (`view/panel.zig`) put together. Each
//! frame the view is shown the repository's latest reading and drawn; what
//! it asked for (`view.Intent`) is then handed to the git client, which
//! runs it on a thread of its own; how it ended is collected in `tick`.
//! A commit that failed leaves everything it printed in a text file the
//! files panel opens in a tab (`takeFailure`).
//! Keyboard input is passed on while the message field has the focus.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const EditCommand = @import("../../../events.zig").EditCommand;
const hosts = @import("../hosts.zig");
const git = @import("../client/git.zig");
const status = @import("../model/status.zig");
const view = @import("../view/panel.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const Panel = struct {
    repo: git.Repo,
    view: view.View,
    /// Where a failed commit's output was written, until the files panel
    /// has opened it (`takeFailure`).
    failure: ?[]u8 = null,
    failure_taken: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{ .repo = git.Repo.init(gpa, hosts.system()), .view = view.View.init(gpa) };
    }

    pub fn deinit(self: *Panel) void {
        if (self.failure) |path| self.view.gpa.free(path);
        self.view.gpa.free(self.failure_taken);
        self.repo.deinit();
        self.view.deinit();
    }

    /// The text file a failed commit's output was written to, once, for
    /// the files panel to open in a tab (valid until the next call).
    pub fn takeFailure(self: *Panel) ?[]const u8 {
        const path = self.failure orelse return null;
        // Kept one call longer, so the caller can read it this frame.
        self.view.gpa.free(self.failure_taken);
        self.failure_taken = path;
        self.failure = null;
        return path;
    }

    pub fn setDir(self: *Panel, dir: []const u8) void {
        self.repo.setDir(dir);
    }

    /// Whether `dir` is inside the repository last read.
    pub fn isRepoFor(self: *const Panel, dir: []const u8) bool {
        return self.repo.isRepoFor(dir);
    }

    /// Everything the lists would show.
    pub fn changeCount(self: *const Panel) u32 {
        const s = &self.repo.snapshot;
        return s.staged_count + s.unstaged_count + s.conflict_count;
    }

    /// The colour an absolute path gets in the tree (none outside the repository).
    pub fn kindOfPath(self: *const Panel, path: []const u8, is_dir: bool) status.Kind {
        return self.repo.snapshot.kindOfPath(path, is_dir);
    }

    /// Background readings, the commands that ended, and the caret blink;
    /// true when a redraw is needed.
    pub fn tick(self: *Panel, now: f64) bool {
        const fresh = self.repo.tick(now);
        // The message has done its job once the commit it was for is made.
        while (self.repo.takeDone()) |done| {
            if (done.what != .commit) continue;
            if (done.ok) self.view.committed() else self.keepFailure();
        }
        const blink = self.view.tick(now);
        return fresh or blink;
    }

    /// A commit that failed has more to say than the line under the
    /// button holds: all of it is written out, for a tab to show.
    fn keepFailure(self: *Panel) void {
        const gpa = self.view.gpa;
        const output = self.repo.last_output.items;
        if (output.len == 0) return;
        var name: [160]u8 = undefined;
        const file = std.fmt.bufPrint(&name, "commit-output-{s}.txt", .{status.baseName(self.repo.snapshot.root)}) catch "commit-output.txt";
        const path = hosts.saveScratch(gpa, file, output) catch return;
        if (self.failure) |old| gpa.free(old);
        self.failure = path;
    }

    /// Draws the view in `rect` and runs what was asked for in it.
    pub fn draw(self: *Panel, ui: *Ui, rect: Rect) view.Result {
        const res = self.view.draw(ui, rect, .{
            .snapshot = &self.repo.snapshot,
            .busy = self.repo.busy(),
            .cmd_running = self.repo.cmdRunning(),
            .cmd_label = self.repo.cmd_label,
            .last_error = self.repo.last_error.items,
        });
        self.run();
        return res;
    }

    /// Hands what the view asked for to git.
    fn run(self: *Panel) void {
        const intent = self.view.takeIntent() orelse return;
        switch (intent) {
            .refresh => self.repo.refreshSoon(),
            .fetch_all => self.repo.fetchAll(),
            .push => self.repo.push(),
            .pull => self.repo.pull(),
            .switch_branch => |name| self.repo.switchBranch(name),
            .switch_remote => |name| self.repo.switchRemote(name),
            .stage => |rel| self.repo.stage(rel),
            .stage_all => self.repo.stageAll(),
            .unstage => |rel| self.repo.unstage(rel),
            .unstage_all => self.repo.unstageAll(),
            .discard => |d| self.repo.discard(d.rel, d.untracked),
            .discard_all => self.repo.discardAll(),
            .commit => |c| self.repo.commit(c.message, .{ .all = c.all, .amend = c.amend, .signoff = c.signoff, .no_verify = c.no_verify }),
        }
    }

    /// ⌘⇧↵ while the message has the keyboard: Amend on, or the amend made.
    pub fn amend(self: *Panel) void {
        self.view.amendKey(&self.repo.snapshot);
        self.run();
    }

    /// Row `i` of the menu the view asked for (branches, commit options) was picked.
    pub fn menuPicked(self: *Panel, i: usize) void {
        self.view.menuPicked(i);
        self.run();
    }

    /// The box was accepted: runs the discard that waited for it.
    pub fn discardConfirmed(self: *Panel) void {
        self.view.discardConfirmed();
        self.run();
    }

    // ── keyboard, routed by the app while the message field is focused ──
    pub fn hasFocus(self: *const Panel) bool {
        return self.view.hasFocus();
    }

    pub fn onText(self: *Panel, utf8: []const u8) void {
        self.view.onText(utf8);
    }

    pub fn onMarkedText(self: *Panel, utf8: []const u8) void {
        self.view.onMarkedText(utf8);
    }

    pub fn paste(self: *Panel, utf8: []const u8) void {
        self.view.paste(utf8);
    }

    /// ↵ commits; the rest edits the message (Esc gives the focus up).
    pub fn onEdit(self: *Panel, cmd: EditCommand) void {
        self.view.onEdit(cmd, &self.repo.snapshot);
        self.run();
    }

    pub fn onCtrl(self: *Panel, key: u8) void {
        self.view.onCtrl(key);
    }

    pub fn copy(self: *Panel, out: *std.ArrayList(u8), cut: bool) bool {
        return self.view.copy(out, cut);
    }

    pub fn hasMarkedText(self: *const Panel) bool {
        return self.view.hasMarkedText();
    }

    /// Gives the keyboard up (the message typed so far is kept).
    pub fn dropFocus(self: *Panel) void {
        self.view.dropFocus();
    }

    pub fn caretRect(self: *const Panel) Rect {
        return self.view.caretRect();
    }
};

//! Settings › Git › Hosting: who tt is on each git host, so the
//! repository tab can show and act on pull requests. One card per host:
//! its name, what kind of host it is (GitHub, GitLab, Bitbucket, Gitea),
//! and where the token comes from: written here, or asked of a tool that
//! already keeps it (`gh`, `glab`, git's credential helper), which leaves
//! the secret out of the file. "Test" asks the host who the account is.
//!
//! Everything edits the config in place (the `accounts:` section, which
//! `client/accounts.zig` owns); text fields share one keyboard focus.
//! Nothing is sent to a host until an account for it is here, and then
//! only to that host.
const std = @import("std");
const ui_mod = @import("../../../ui/ui.zig");
const theme = @import("../../../ui/theme.zig");
const field = @import("../../../ui/field.zig");
const config = @import("../../../config.zig");
const EditCommand = @import("../../../events.zig").EditCommand;
const hosts = @import("../hosts.zig");
const accounts_mod = @import("../client/accounts.zig");
const forge = @import("../client/forge.zig");
const pr = @import("../model/pull_request.zig");
const url = @import("../model/remote_url.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Account = accounts_mod.Account;
const Source = accounts_mod.Source;

const kinds = [_]pr.Kind{ .github, .gitlab, .bitbucket, .gitea };
const sources = [_]Source{ .token, .gh, .glab, .git };

const card_pad: f32 = 18;
const head_h: f32 = 44;
const label_w: f32 = 104;
const row_gap: f32 = 12;
const chip_h: f32 = 26;

const FieldKind = enum(u8) { host, user, token };

const FieldRef = struct {
    uid: u32,
    kind: FieldKind,

    fn id(self: FieldRef) u64 {
        return Ui.id("hosting.field", @as(usize, self.uid) * 8 + @backingInt(self.kind));
    }

    fn slot(self: FieldRef, cfg: *config.Config) ?*[]u8 {
        const a = cfg.accounts.find(self.uid) orelse return null;
        return switch (self.kind) {
            .host => &a.host,
            .user => &a.user,
            .token => &a.token,
        };
    }
};

/// "Test" under way or answered, for one account.
const Probe = struct {
    uid: u32,
    lookup: ?*accounts_mod.TokenLookup = null,
    session: ?*forge.Session = null,
    /// What to say under the card, and whether it is good news.
    text: std.ArrayList(u8) = .empty,
    ok: bool = false,
};

pub const Page = struct {
    gpa: std.mem.Allocator,
    focus: field.Focus,
    /// The field behind `focus` (valid while `focus.active()`).
    focus_ref: FieldRef = .{ .uid = 0, .kind = .host },
    /// Account whose token is shown in clear, if any.
    revealed: ?u32 = null,
    /// "Remove" was clicked once on this account; the next click removes it.
    confirm_remove: ?u32 = null,
    probe: ?Probe = null,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *Page) void {
        self.flush();
        self.focus.deinit();
        self.dropProbe();
    }

    fn dropProbe(self: *Page) void {
        var p = self.probe orelse return;
        if (p.lookup) |l| l.destroy();
        if (p.session) |s| s.destroy();
        p.text.deinit(self.gpa);
        self.probe = null;
    }

    /// Copies the focused field's text into the config.
    fn flush(self: *Page) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        const cfg = config.get();
        if (self.focus_ref.slot(cfg)) |s| {
            cfg.accounts.set(s, self.focus.editor.bytes());
            cfg.touch();
        }
        self.focus.markSynced();
        // What a test said was about the account as it was.
        if (self.probe) |p| if (p.uid == self.focus_ref.uid) self.dropProbe();
    }

    fn takeFocus(self: *Page, ref: FieldRef, now: f64) void {
        self.flush();
        const cfg = config.get();
        const s = ref.slot(cfg) orelse return;
        self.focus_ref = ref;
        self.focus.take(ref.id(), s.*, now);
    }

    pub fn blur(self: *Page) void {
        self.flush();
        self.focus.drop();
    }

    // ── per-tick / keyboard (routed by the settings tab) ────────────────
    pub fn tick(self: *Page, now: f64) bool {
        var dirty = self.focus.tick(now);
        if (self.advanceProbe()) dirty = true;
        return dirty;
    }

    /// A test goes: the token (asked of its tool when it is not written
    /// down), then the host's answer to "who am I?".
    fn advanceProbe(self: *Page) bool {
        const p = &(self.probe orelse return false);
        const gpa = self.gpa;
        if (p.lookup) |l| {
            if (!l.finished()) return false;
            defer {
                l.destroy();
                p.lookup = null;
            }
            const found = l.result orelse {
                p.text.appendSlice(gpa, "No token: the tool has none for this host, or is not installed.") catch {};
                return true;
            };
            const cfg = config.get();
            const a = cfg.accounts.find(p.uid) orelse return true;
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const api = forge.apiBase(scratch.allocator(), a.kind, .{ .host = a.host, .path = "" }) catch return true;
            p.session = forge.Session.create(gpa, hosts.systemHttp(), .{ .kind = a.kind, .api = api, .path = "", .user = if (a.user.len > 0) a.user else found.user, .token = found.token }) catch return true;
            p.session.?.identify();
            return true;
        }
        if (p.session) |s| {
            _ = s.tick();
            if (s.identifying()) return false;
            if (s.me.len > 0) {
                p.ok = true;
                p.text.print(gpa, "Connected as {s}.", .{s.me}) catch {};
            } else {
                p.text.appendSlice(gpa, if (s.me_error.items.len > 0) s.me_error.items else "The host did not say who the account is.") catch {};
            }
            s.destroy();
            p.session = null;
            return true;
        }
        return false;
    }

    fn startProbe(self: *Page, a: *const Account) void {
        self.dropProbe();
        self.probe = .{ .uid = a.uid };
        const p = &self.probe.?;
        p.lookup = accounts_mod.TokenLookup.start(self.gpa, hosts.system(), a) catch null;
        if (p.lookup == null) p.text.appendSlice(self.gpa, "The test could not be started.") catch {};
    }

    pub fn onText(self: *Page, utf8: []const u8) void {
        self.focus.onText(utf8);
        self.flush();
    }

    pub fn onMarkedText(self: *Page, utf8: []const u8) void {
        self.focus.onMarkedText(utf8);
    }

    pub fn paste(self: *Page, utf8: []const u8) void {
        self.focus.paste(utf8);
        self.flush();
    }

    /// True when a field used the command.
    pub fn onEdit(self: *Page, cmd: EditCommand) bool {
        if (!self.focus.active()) return false;
        const used = self.focus.onEdit(cmd);
        self.flush();
        return used;
    }

    pub fn onCtrl(self: *Page, key: u8) bool {
        const used = self.focus.onCtrl(key);
        self.flush();
        return used;
    }

    pub fn copy(self: *Page, out: *std.ArrayList(u8), cut: bool) bool {
        const ok = self.focus.copy(out, cut);
        self.flush();
        return ok;
    }

    pub fn hasMarkedText(self: *const Page) bool {
        return self.focus.hasMarkedText();
    }

    pub fn caretRect(self: *const Page) Rect {
        return if (self.focus.active()) self.focus.caret else .{};
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Draws the page in the column at `x`, from `y0` down; returns the y
    /// where it ends.
    pub fn draw(self: *Page, ui: *Ui, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        const cfg = config.get();
        // A focus on a field that is gone (account removed) is dropped.
        if (self.focus.active() and self.focus_ref.slot(cfg) == null) self.focus.drop();
        var press_outside = ui.pressed;
        var y = y0;

        var i: usize = 0;
        while (i < cfg.accounts.items.items.len) {
            const uid = cfg.accounts.items.items[i].uid;
            const r = self.drawCard(ui, cfg, uid, x, y, col_w, now, &press_outside);
            y = r.bottom() + theme.block_gap;
            // Removing an account shifts the list up: the next card is at this same index.
            if (cfg.accounts.find(uid) != null) i += 1;
        }
        y = self.drawAddCard(ui, cfg, x, y, col_w, now);

        y += 18;
        y = @import("../../../ui/wrap.zig").drawWrapped(ui, theme.font_hint, "tt talks to a git host only once it has an account here, and then only to that host: to list pull requests and to do what you ask with them. Everything else about a repository is read with git on this Mac.", x, y, col_w, 18, theme.text_3);

        if (press_outside) {
            self.confirm_remove = null;
            if (self.focus.active()) self.blur();
        }
        return y;
    }

    fn drawCard(self: *Page, ui: *Ui, cfg: *config.Config, uid: u32, x: f32, y0: f32, col_w: f32, now: f64, press_outside: *bool) Rect {
        const dl = ui.dl;
        const a = cfg.accounts.find(uid) orelse return .{ .x = x, .y = y0, .w = col_w, .h = 0 };
        const fields_x = x + card_pad + label_w;
        const fields_w = col_w - card_pad * 2 - label_w;
        const written = a.source == .token;
        const probe_text: []const u8 = if (self.probe) |p| (if (p.uid == uid) p.text.items else "") else "";

        var h: f32 = card_pad + head_h + 1 + 14;
        h += field.height + row_gap; // host
        h += chip_h + row_gap; // kind
        h += chip_h + row_gap; // token from
        h += field.height + row_gap; // user
        h += field.height + row_gap; // token, or the note that a tool keeps it
        h += 18 + 12; // hint
        h += 28 + card_pad - 6; // test row
        const card: Rect = .{ .x = x, .y = y0, .w = col_w, .h = h };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        if (self.focus.active() and self.focus_ref.uid == uid) dl.border(card, theme.block_radius, 1, theme.accent.alpha(0.35));

        // Header: the host and its kind; "Remove" on the right.
        const hcy = card.y + card_pad + head_h / 2 - 6;
        dl.icon(.cloud, card.x + card_pad, hcy - 8, 16, theme.text_3);
        var right = card.right() - card_pad;
        {
            const remove_label: []const u8 = if (self.confirm_remove == uid) "Remove?" else "Remove";
            const rw = ui.text.measure(theme.font_hint, remove_label) + 20;
            const rr: Rect = .{ .x = right - rw, .y = hcy - 13, .w = rw, .h = 26 };
            if (ui.pressed and ui.mouseIn(rr)) press_outside.* = false;
            if (self.confirm_remove == uid) dl.rrect(rr, 6, theme.red.alpha(0.14));
            if (field.textButton(ui, Ui.id("hosting.remove", uid), rr, remove_label, theme.red)) {
                if (self.confirm_remove == uid) {
                    if (self.focus.active() and self.focus_ref.uid == uid) self.focus.drop();
                    if (self.revealed == uid) self.revealed = null;
                    if (self.probe) |p| if (p.uid == uid) self.dropProbe();
                    self.confirm_remove = null;
                    cfg.accounts.remove(uid);
                    cfg.touch();
                    cfg.save();
                    return card;
                }
                self.confirm_remove = uid;
            }
            right = rr.x - 10;
        }
        const name_x = card.x + card_pad + 16 + 10;
        const shown: []const u8 = if (a.host.len > 0) a.host else "New host";
        const nw = dl.textEllipsis(theme.font_ui_medium, name_x, hcy, shown, @max(0, right - name_x - 8), theme.text);
        _ = dl.textEllipsis(theme.font_hint, name_x + nw + 10, hcy, a.kind.label(), @max(0, right - name_x - nw - 10), theme.text_3);
        var y = card.y + card_pad + head_h - 6;
        dl.rect(.{ .x = card.x, .y = y, .w = card.w, .h = 1 }, theme.line);
        y += 1 + 14;

        self.textRow(ui, .{ .uid = uid, .kind = .host }, card.x + card_pad, fields_x, y, fields_w, "Host", .{ .placeholder = "github.com, or your own server's name" }, now, press_outside);
        y += field.height + row_gap;

        // What kind of host it is.
        _ = dl.textCentered(theme.font_ui, card.x + card_pad, y + chip_h / 2, "Kind", theme.text_2);
        {
            var cx = fields_x;
            for (kinds, 0..) |k, i| {
                const cw = field.chipWidth(ui, k.label());
                const cr: Rect = .{ .x = cx, .y = y, .w = cw, .h = chip_h };
                if (ui.pressed and ui.mouseIn(cr)) press_outside.* = false;
                if (field.chip(ui, Ui.id("hosting.kind", @as(usize, uid) * 8 + i), cr, k.label(), k == a.kind) and k != a.kind) {
                    a.kind = k;
                    self.changed(cfg, uid);
                }
                cx += cw + 8;
            }
        }
        y += chip_h + row_gap;

        // Where the token comes from.
        _ = dl.textCentered(theme.font_ui, card.x + card_pad, y + chip_h / 2, "Token from", theme.text_2);
        {
            var cx = fields_x;
            for (sources, 0..) |src, i| {
                const cw = field.chipWidth(ui, src.label());
                const cr: Rect = .{ .x = cx, .y = y, .w = cw, .h = chip_h };
                if (ui.pressed and ui.mouseIn(cr)) press_outside.* = false;
                if (field.chip(ui, Ui.id("hosting.source", @as(usize, uid) * 8 + i), cr, src.label(), src == a.source) and src != a.source) {
                    a.source = src;
                    if (self.focus.active() and self.focus_ref.uid == uid and self.focus_ref.kind == .token) self.focus.drop();
                    self.changed(cfg, uid);
                }
                cx += cw + 8;
            }
        }
        y += chip_h + row_gap;

        const user_label: []const u8 = if (a.kind == .bitbucket) "E-mail" else "User";
        self.textRow(ui, .{ .uid = uid, .kind = .user }, card.x + card_pad, fields_x, y, fields_w, user_label, .{ .placeholder = if (a.kind == .bitbucket) "The Atlassian account's e-mail (for an API token)" else "Optional" }, now, press_outside);
        y += field.height + row_gap;

        // The token, masked, with a Show / Hide toggle; or who keeps it.
        if (written) {
            const toggle_w: f32 = 52;
            const revealed = self.revealed == uid;
            self.textRow(ui, .{ .uid = uid, .kind = .token }, card.x + card_pad, fields_x, y, fields_w - toggle_w - 8, "Token", .{ .masked = true, .revealed = revealed, .placeholder = "Paste an access token" }, now, press_outside);
            const tr: Rect = .{ .x = fields_x + fields_w - toggle_w, .y = y + 3, .w = toggle_w, .h = field.height - 6 };
            if (ui.pressed and ui.mouseIn(tr)) press_outside.* = false;
            if (field.textButton(ui, Ui.id("hosting.reveal", uid), tr, if (revealed) "Hide" else "Show", theme.text_2)) {
                self.revealed = if (revealed) null else uid;
            }
        } else {
            _ = dl.textCentered(theme.font_ui, card.x + card_pad, y + field.height / 2, "Token", theme.text_2);
            const note: []const u8 = switch (a.source) {
                .gh => "Asked of `gh auth token` when needed; not kept in tt's file.",
                .glab => "Asked of `glab config get token` when needed; not kept in tt's file.",
                .git => "Asked of git's credential helper when needed; not kept in tt's file.",
                .token => "",
            };
            _ = dl.textEllipsis(theme.font_hint, fields_x + 12, y + field.height / 2, note, fields_w - 12, theme.text_3);
        }
        y += field.height + row_gap;

        const hint: []const u8 = switch (a.kind) {
            .github => "A fine-grained token needs Pull requests (read and write) and Contents (read) on the repositories.",
            .gitlab => "A personal or project access token with the `api` scope.",
            .bitbucket => "An API token with pull request read and write scopes, with the account's e-mail; or a repository access token, without one.",
            .gitea => "An access token with read and write on repositories (Gitea, Forgejo, Codeberg).",
        };
        _ = dl.textEllipsis(theme.font_hint, fields_x, y + 9, hint, fields_w, theme.text_3);
        y += 18 + 12;

        // "Test", and what it found.
        {
            const busy = if (self.probe) |p| p.uid == uid and (p.lookup != null or p.session != null) else false;
            const label: []const u8 = if (busy) "Testing…" else "Test";
            const bw = ui.text.measure(theme.font_hint, label) + 28;
            const br: Rect = .{ .x = fields_x, .y = y, .w = bw, .h = 28 };
            if (ui.pressed and ui.mouseIn(br)) press_outside.* = false;
            dl.shape(br, 8, theme.chip_active, 1, theme.line);
            if (field.textButton(ui, Ui.id("hosting.test", uid), br, label, theme.text_2) and !busy and a.usable()) {
                self.flush();
                self.startProbe(a);
            }
            if (probe_text.len > 0) {
                const good = if (self.probe) |p| p.ok else false;
                _ = dl.textEllipsis(theme.font_hint, br.right() + 12, br.centerY(), probe_text, @max(0, card.right() - card_pad - br.right() - 12), if (good) theme.ansi[2] else theme.red);
            } else if (!a.usable()) {
                _ = dl.textEllipsis(theme.font_hint, br.right() + 12, br.centerY(), "Needs a host and a token.", @max(0, card.right() - card_pad - br.right() - 12), theme.text_3);
            }
        }
        return card;
    }

    /// A chip changed the account: written at once, and the last test no longer speaks for it.
    fn changed(self: *Page, cfg: *config.Config, uid: u32) void {
        cfg.touch();
        cfg.save();
        if (self.probe) |p| if (p.uid == uid) self.dropProbe();
    }

    /// A labelled text field; clicking it takes the focus.
    fn textRow(self: *Page, ui: *Ui, ref: FieldRef, label_x: f32, fx: f32, y: f32, fw: f32, label: []const u8, opts: field.Options, now: f64, press_outside: *bool) void {
        _ = ui.dl.textCentered(theme.font_ui, label_x, y + field.height / 2, label, theme.text_2);
        const r: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
        if (ui.pressed and ui.mouseIn(r)) press_outside.* = false;
        const value: []const u8 = if (ref.slot(config.get())) |s| s.* else "";
        const res = field.draw(ui, &self.focus, ref.id(), r, value, opts);
        if (res.clicked) self.takeFocus(ref, now);
    }

    /// The card that adds an account: one pill per kind of host.
    fn drawAddCard(self: *Page, ui: *Ui, cfg: *config.Config, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        const dl = ui.dl;
        const card: Rect = .{ .x = x, .y = y0, .w = col_w, .h = card_pad + 22 + 6 + 18 + 14 + chip_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        var y = card.y + card_pad;
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, y + 11, if (cfg.accounts.items.items.len == 0) "No hosts yet" else "Add another host", theme.text);
        y += 22 + 6;
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, y + 9, "Pick the kind of host; its name and token can be set afterwards. One account per host.", col_w - 2 * card_pad, theme.text_3);
        y += 18 + 14;
        var cx = card.x + card_pad;
        for (kinds, 0..) |k, i| {
            const cw = field.chipWidth(ui, k.label());
            if (field.chip(ui, Ui.id("hosting.add", i), .{ .x = cx, .y = y, .w = cw, .h = chip_h }, k.label(), false)) {
                if (cfg.accounts.add()) |a| {
                    a.kind = k;
                    // The public host of its kind, unless it has an account already.
                    const usual: []const u8 = switch (k) {
                        .github => "github.com",
                        .gitlab => "gitlab.com",
                        .bitbucket => "bitbucket.org",
                        .gitea => "",
                    };
                    var taken = false;
                    for (cfg.accounts.items.items) |other| {
                        if (other.uid != a.uid and usual.len > 0 and std.ascii.eqlIgnoreCase(other.host, usual)) taken = true;
                    }
                    if (!taken) cfg.accounts.set(&a.host, usual);
                    cfg.touch();
                    cfg.save();
                    self.takeFocus(.{ .uid = a.uid, .kind = if (a.host.len == 0) .host else .token }, now);
                } else |err| std.log.err("could not add a host: {s}", .{@errorName(err)});
            }
            cx += cw + 8;
        }
        return card.bottom();
    }
};

test "a known host's kind needs no telling" {
    try std.testing.expectEqual(@as(?pr.Kind, .gitlab), url.knownKind("gitlab.com"));
}

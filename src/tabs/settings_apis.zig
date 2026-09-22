//! Settings › AI › APIs: the models conch can talk to. One card per
//! agent — name, provider, model, key, endpoint — and a card to add one at
//! any of the main providers or Ollama. Everything edits the config in
//! place (see `config.zig`); text fields share one keyboard focus.
const std = @import("std");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const field = @import("../ui/field.zig");
const config = @import("../config.zig");
const EditCommand = @import("../events.zig").EditCommand;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const Font = ui_mod.Font;
const Provider = config.Provider;

const providers = [_]Provider{ .anthropic, .openai, .google, .mistral, .ollama, .custom };

const card_pad: f32 = 18;
const head_h: f32 = 44;
const label_w: f32 = 104;
const row_gap: f32 = 12;
const chip_h: f32 = 26;

/// The text fields of an agent card, in Tab order.
pub const FieldKind = enum(u8) { name, model, api_key, base_url };

const FieldRef = struct {
    uid: u32,
    kind: FieldKind,

    fn id(self: FieldRef) u64 {
        return Ui.id("apis.field", @as(usize, self.uid) * 8 + @intFromEnum(self.kind));
    }

    fn slot(self: FieldRef, cfg: *config.Config) ?*[]u8 {
        const a = cfg.findAgent(self.uid) orelse return null;
        return switch (self.kind) {
            .name => &a.name,
            .model => &a.model,
            .api_key => &a.api_key,
            .base_url => &a.base_url,
        };
    }
};

pub const Page = struct {
    gpa: std.mem.Allocator,
    focus: field.Focus,
    /// The field behind `focus` (valid while `focus.active()`).
    focus_ref: FieldRef = .{ .uid = 0, .kind = .name },
    /// Agent whose key is shown in clear, if any.
    revealed: ?u32 = null,
    /// "Remove" was clicked once on this agent; the next click removes it.
    confirm_remove: ?u32 = null,
    /// The fields drawn this frame, in Tab order.
    order: [256]FieldRef = undefined,
    order_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Page {
        return .{ .gpa = gpa, .focus = field.Focus.init(gpa) };
    }

    pub fn deinit(self: *Page) void {
        self.flush();
        self.focus.deinit();
    }

    /// Copies the focused field's text into the config.
    fn flush(self: *Page) void {
        if (!self.focus.active() or !self.focus.changed()) return;
        const cfg = config.get();
        if (self.focus_ref.slot(cfg)) |s| cfg.setString(s, self.focus.editor.bytes());
        self.focus.markSynced();
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
        return self.focus.tick(now);
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
        // A focus on a field that is gone (agent removed, key hidden) is dropped.
        if (self.focus.active() and self.focus_ref.slot(cfg) == null) self.focus.drop();
        self.order_len = 0;
        var press_outside = ui.pressed;
        var y = y0;

        var i: usize = 0;
        while (i < cfg.agents.items.len) {
            const uid = cfg.agents.items[i].uid;
            const r = self.drawCard(ui, cfg, uid, x, y, col_w, now, &press_outside);
            y = r.bottom() + theme.block_gap;
            // Removing an agent shifts the list up, so the next card is at
            // this same index; only a card that is still there moves on.
            if (cfg.findAgent(uid) != null) i += 1;
        }

        // Tab / ⇧Tab: the next field in reading order, wrapping around.
        if (self.focus.active() and self.focus.move != 0 and self.order_len > 0) {
            const delta = self.focus.move;
            self.focus.move = 0;
            var at: usize = 0;
            for (self.order[0..self.order_len], 0..) |ref, k| {
                if (ref.uid == self.focus_ref.uid and ref.kind == self.focus_ref.kind) at = k;
            }
            const n: isize = @intCast(self.order_len);
            const next: usize = @intCast(@mod(@as(isize, @intCast(at)) + delta, n));
            self.takeFocus(self.order[next], now);
        }

        y = self.drawAddCard(ui, cfg, x, y, col_w, now);

        // A click anywhere but on a field gives the focus up; one anywhere
        // but on "Remove?" cancels it.
        if (press_outside) {
            self.confirm_remove = null;
            if (self.focus.active()) self.blur();
        }
        return y;
    }

    fn drawCard(self: *Page, ui: *Ui, cfg: *config.Config, uid: u32, x: f32, y0: f32, col_w: f32, now: f64, press_outside: *bool) Rect {
        const dl = ui.dl;
        const a = cfg.findAgent(uid) orelse return .{ .x = x, .y = y0, .w = col_w, .h = 0 };
        const needs_key = a.provider.needsKey();
        const fields_x = x + card_pad + label_w;
        const fields_w = col_w - card_pad * 2 - label_w;

        // Height first: header, four or five rows, the hint line.
        const chips_h = chipsHeight(ui, fields_w);
        var h: f32 = card_pad + head_h + 1 + 14;
        h += field.height + row_gap; // name
        h += chips_h + row_gap; // provider
        h += field.height + row_gap; // model
        h += field.height + row_gap; // key (or the note that none is needed)
        h += field.height + row_gap; // base url
        h += 18 + card_pad - 6; // hint
        const card: Rect = .{ .x = x, .y = y0, .w = col_w, .h = h };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        if (self.focus.active() and self.focus_ref.uid == uid) dl.border(card, theme.block_radius, 1, theme.accent.alpha(0.35));

        // Header: icon, name, provider; on the right "Default" and "Remove".
        const hcy = card.y + card_pad + head_h / 2 - 6;
        dl.icon(.agent, card.x + card_pad, hcy - 8, 16, theme.text_3);
        var right = card.right() - card_pad;
        {
            const remove_label: []const u8 = if (self.confirm_remove == uid) "Remove?" else "Remove";
            const rw = ui.text.measure(theme.font_hint, remove_label) + 20;
            const rr: Rect = .{ .x = right - rw, .y = hcy - 13, .w = rw, .h = 26 };
            if (ui.pressed and ui.mouseIn(rr)) press_outside.* = false;
            if (self.confirm_remove == uid) dl.rrect(rr, 6, theme.red.alpha(0.14));
            if (field.textButton(ui, Ui.id("apis.remove", uid), rr, remove_label, theme.red)) {
                if (self.confirm_remove == uid) {
                    if (self.focus.active() and self.focus_ref.uid == uid) self.focus.drop();
                    if (self.revealed == uid) self.revealed = null;
                    self.confirm_remove = null;
                    cfg.removeAgent(uid);
                    cfg.save();
                    return card;
                }
                self.confirm_remove = uid;
            }
            right = rr.x - 10;
        }
        if (a.is_default) {
            const tag = "Default";
            const tw = ui.text.measure(theme.font_chip, tag);
            const pill: Rect = .{ .x = right - tw - 16, .y = hcy - 10, .w = tw + 16, .h = 20 };
            dl.rrect(pill, 10, theme.accent);
            _ = dl.textCentered(theme.font_chip, pill.x + 8, pill.centerY(), tag, theme.on_accent);
            right = pill.x - 10;
        } else {
            const label = "Make default";
            const bw = ui.text.measure(theme.font_hint, label) + 20;
            const br: Rect = .{ .x = right - bw, .y = hcy - 13, .w = bw, .h = 26 };
            if (field.textButton(ui, Ui.id("apis.default", uid), br, label, theme.text_2)) {
                cfg.setDefaultAgent(uid);
                cfg.save();
            }
            right = br.x - 10;
        }
        const name_x = card.x + card_pad + 16 + 10;
        const shown_name: []const u8 = if (a.name.len > 0) a.name else "Unnamed agent";
        const nw = dl.textEllipsis(theme.font_ui_medium, name_x, hcy, shown_name, @max(0, right - name_x - 8), theme.text);
        _ = dl.textEllipsis(theme.font_hint, name_x + nw + 10, hcy, a.provider.label(), @max(0, right - name_x - nw - 10), theme.text_3);
        var y = card.y + card_pad + head_h - 6;
        dl.rect(.{ .x = card.x, .y = y, .w = card.w, .h = 1 }, theme.line);
        y += 1 + 14;

        // Name.
        self.textRow(ui, .{ .uid = uid, .kind = .name }, card.x + card_pad, fields_x, y, fields_w, "Name", .{ .placeholder = "How the agent is listed" }, now, press_outside);
        y += field.height + row_gap;

        // Provider chips.
        _ = dl.textCentered(theme.font_ui, card.x + card_pad, y + chip_h / 2, "Provider", theme.text_2);
        if (self.providerChips(ui, uid, fields_x, y, fields_w, a.provider)) |p| {
            cfg.setProvider(a, p);
            if (!p.needsKey() and self.focus.active() and self.focus_ref.uid == uid and self.focus_ref.kind == .api_key) self.focus.drop();
            cfg.save();
        }
        y += chips_h + row_gap;

        // Model.
        self.textRow(ui, .{ .uid = uid, .kind = .model }, card.x + card_pad, fields_x, y, fields_w, "Model", .{ .placeholder = if (a.provider.defaultModel().len > 0) a.provider.defaultModel() else "model id" }, now, press_outside);
        y += field.height + row_gap;

        // API key, masked, with a Show / Hide toggle.
        if (needs_key) {
            const toggle_w: f32 = 52;
            const revealed = self.revealed == uid;
            self.textRow(ui, .{ .uid = uid, .kind = .api_key }, card.x + card_pad, fields_x, y, fields_w - toggle_w - 8, "API key", .{ .masked = true, .revealed = revealed, .placeholder = if (a.provider == .custom) "Optional" else "Paste the key" }, now, press_outside);
            const tr: Rect = .{ .x = fields_x + fields_w - toggle_w, .y = y + 3, .w = toggle_w, .h = field.height - 6 };
            if (ui.pressed and ui.mouseIn(tr)) press_outside.* = false;
            if (field.textButton(ui, Ui.id("apis.reveal", uid), tr, if (revealed) "Hide" else "Show", theme.text_2)) {
                self.revealed = if (revealed) null else uid;
            }
        } else {
            _ = dl.textCentered(theme.font_ui, card.x + card_pad, y + field.height / 2, "API key", theme.text_2);
            _ = dl.textCentered(theme.font_hint, fields_x + 12, y + field.height / 2, "Not needed: Ollama runs on this Mac.", theme.text_3);
        }
        y += field.height + row_gap;

        // Base URL.
        self.textRow(ui, .{ .uid = uid, .kind = .base_url }, card.x + card_pad, fields_x, y, fields_w, "Base URL", .{ .placeholder = if (a.provider.defaultBaseUrl().len > 0) a.provider.defaultBaseUrl() else "https://…/v1" }, now, press_outside);
        y += field.height + row_gap;

        _ = dl.textEllipsis(theme.font_hint, fields_x, y + 9, a.provider.hint(), fields_w, theme.text_3);
        return card;
    }

    /// A labelled text field; clicking it takes the focus.
    fn textRow(self: *Page, ui: *Ui, ref: FieldRef, label_x: f32, fx: f32, y: f32, fw: f32, label: []const u8, opts: field.Options, now: f64, press_outside: *bool) void {
        _ = ui.dl.textCentered(theme.font_ui, label_x, y + field.height / 2, label, theme.text_2);
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = ref;
            self.order_len += 1;
        }
        const r: Rect = .{ .x = fx, .y = y, .w = fw, .h = field.height };
        if (ui.pressed and ui.mouseIn(r)) press_outside.* = false;
        const value: []const u8 = if (ref.slot(config.get())) |s| s.* else "";
        const res = field.draw(ui, &self.focus, ref.id(), r, value, opts);
        if (res.clicked) self.takeFocus(ref, now);
    }

    fn chipsHeight(ui: *Ui, w: f32) f32 {
        var cx: f32 = 0;
        var rows: f32 = 1;
        for (providers) |p| {
            const cw = field.chipWidth(ui, p.label());
            if (cx + cw > w and cx > 0) {
                cx = 0;
                rows += 1;
            }
            cx += cw + 8;
        }
        return rows * chip_h + (rows - 1) * 8;
    }

    /// The provider pills, wrapping when the column is narrow; returns the
    /// one clicked.
    fn providerChips(self: *Page, ui: *Ui, uid: u32, x: f32, y: f32, w: f32, selected: Provider) ?Provider {
        _ = self;
        var picked: ?Provider = null;
        var cx = x;
        var cy = y;
        for (providers, 0..) |p, i| {
            const cw = field.chipWidth(ui, p.label());
            if (cx + cw > x + w and cx > x) {
                cx = x;
                cy += chip_h + 8;
            }
            if (field.chip(ui, Ui.id("apis.provider", @as(usize, uid) * 8 + i), .{ .x = cx, .y = cy, .w = cw, .h = chip_h }, p.label(), p == selected)) picked = p;
            cx += cw + 8;
        }
        return picked;
    }

    /// The card that adds an agent: one pill per provider.
    fn drawAddCard(self: *Page, ui: *Ui, cfg: *config.Config, x: f32, y0: f32, col_w: f32, now: f64) f32 {
        const dl = ui.dl;
        const chips_w = col_w - 2 * card_pad;
        const chips_h = chipsHeight(ui, chips_w);
        const card: Rect = .{ .x = x, .y = y0, .w = col_w, .h = card_pad + 22 + 6 + 18 + 14 + chips_h + card_pad };
        dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
        dl.border(card, theme.block_radius, 1, theme.line);
        var y = card.y + card_pad;
        _ = dl.textCentered(theme.font_ui_medium, card.x + card_pad, y + 11, if (cfg.agents.items.len == 0) "No agents yet" else "Add another agent", theme.text);
        y += 22 + 6;
        _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, y + 9, "Pick where its model runs; the name, model, key and endpoint can be changed afterwards.", chips_w, theme.text_3);
        y += 18 + 14;

        var cx = card.x + card_pad;
        var cy = y;
        for (providers, 0..) |p, i| {
            const cw = field.chipWidth(ui, p.label());
            if (cx + cw > card.x + card_pad + chips_w and cx > card.x + card_pad) {
                cx = card.x + card_pad;
                cy += chip_h + 8;
            }
            if (field.chip(ui, Ui.id("apis.add", i), .{ .x = cx, .y = cy, .w = cw, .h = chip_h }, p.label(), false)) {
                if (cfg.addAgent(p)) |a| {
                    cfg.save();
                    self.takeFocus(.{ .uid = a.uid, .kind = .name }, now);
                } else |err| std.log.err("could not add an agent: {s}", .{@errorName(err)});
            }
            cx += cw + 8;
        }
        return card.bottom();
    }
};

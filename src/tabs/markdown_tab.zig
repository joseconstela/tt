//! Markdown files: the same editor as any text file, plus a *preview* mode
//! (the default) that renders the document in place — headings, lists,
//! emphasis, code — while it stays editable: the source markers show only
//! on the caret's line. The Preview / Source switch at the right end of the
//! tab strip, ⌘E, the View menu and the palette all flip between the two.
const std = @import("std");
const tab_mod = @import("tab.zig");
const viewer = @import("viewer.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const filetype = @import("../filetype.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");
const FileDoc = @import("file_tab.zig").FileDoc;
const MarkdownView = @import("markdown_view.zig").MarkdownView;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

// The Preview / Source switch in the tab strip.
const switch_h: f32 = 24;
const switch_pad_x: f32 = 11;
const switch_labels = [2][]const u8{ "Preview", "Source" };

pub const MarkdownTab = struct {
    pub const kind_label = "Markdown";

    pub const Mode = enum { source, visual };

    gpa: std.mem.Allocator,
    file: FileDoc,
    view: MarkdownView,
    mode: Mode = .visual,

    pub fn accepts(file_path: []const u8, _: []const u8) bool {
        return filetype.language(file_path, "") == .markdown;
    }

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        var kept = try viewer.kept(env.gpa, args.saved);
        defer if (kept) |*k| k.deinit(env.gpa);
        const file_path = args.path orelse if (kept) |k| k.path else return error.MissingPath;
        const self = try env.gpa.create(MarkdownTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .file = try FileDoc.init(env.gpa, file_path), .view = undefined };
        self.view = MarkdownView.init(env.gpa, self.file.ed.salt);
        if (kept) |k| {
            if (k.field(0)) |mode| self.mode = if (std.mem.eql(u8, mode, "source")) .source else .visual;
            self.file.restoreCaret(k.field(1));
            self.view.follow = true;
        }
        return tab_mod.Tab.from(MarkdownTab, self);
    }

    pub fn deinit(self: *MarkdownTab) void {
        self.view.deinit();
        self.file.deinit();
        self.gpa.destroy(self);
    }

    fn visual(self: *const MarkdownTab) bool {
        return self.mode == .visual and self.file.state != .binary and self.file.state != .failed;
    }

    pub fn setMode(self: *MarkdownTab, mode: Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        // Whichever view comes up, it should show the caret's line.
        self.view.follow = true;
        self.file.ed.follow = true;
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *MarkdownTab, _: []u8) []const u8 {
        return sys.basename(self.file.file_path);
    }

    pub fn path(self: *MarkdownTab) []const u8 {
        return self.file.file_path;
    }

    pub fn relocate(self: *MarkdownTab, new_path: []const u8) void {
        self.file.relocate(new_path);
    }

    pub fn cwd(self: *MarkdownTab) []const u8 {
        return sys.dirname(self.file.file_path);
    }

    pub fn status(self: *MarkdownTab) tab_mod.Status {
        return self.file.status();
    }

    pub fn info(self: *MarkdownTab, buf: []u8) []const u8 {
        return self.file.info(buf);
    }

    pub fn tick(self: *MarkdownTab, now: f64, active: bool) bool {
        return self.file.tick(now, active);
    }

    pub fn onText(self: *MarkdownTab, utf8: []const u8) void {
        self.file.ed.onText(utf8);
        self.view.follow = true;
    }

    pub fn onMarkedText(self: *MarkdownTab, utf8: []const u8) void {
        self.file.ed.onMarkedText(utf8);
        self.view.follow = true;
    }

    pub fn onEdit(self: *MarkdownTab, cmd: EditCommand) void {
        if (self.visual()) self.view.onEdit(&self.file.ed, cmd) else self.file.ed.onEdit(cmd);
    }

    pub fn copy(self: *MarkdownTab, out: *std.ArrayList(u8), cut: bool) bool {
        return self.file.ed.copy(out, cut);
    }

    pub fn paste(self: *MarkdownTab, utf8: []const u8) void {
        self.file.ed.paste(utf8);
        self.view.follow = true;
    }

    pub fn hasMarkedText(self: *MarkdownTab) bool {
        return self.file.ed.hasMarkedText();
    }

    pub fn caretRect(self: *MarkdownTab) Rect {
        return if (self.visual()) self.view.caret else self.file.ed.caret;
    }

    pub fn closeWarning(self: *MarkdownTab, _: []u8) ?[]const u8 {
        return self.file.closeWarning();
    }

    pub fn position(self: *MarkdownTab) ?tab_mod.Position {
        return self.file.ed.position();
    }

    /// Both modes share the buffer and the caret: the source editor
    /// centres the line, the preview follows the caret.
    pub fn goTo(self: *MarkdownTab, line: usize, col: usize) bool {
        self.file.ed.goTo(line, col);
        self.view.follow = true;
        return true;
    }

    pub fn selectSpan(self: *MarkdownTab, line: u32, col: u32, len: u32) void {
        self.file.ed.selectSpan(line, col, len);
    }

    pub fn command(self: *MarkdownTab, cmd: tab_mod.Command) bool {
        switch (cmd) {
            .toggle_view => {
                self.setMode(if (self.mode == .source) .visual else .source);
                return true;
            },
            .undo, .redo => {
                self.view.follow = true;
                return self.file.command(cmd);
            },
            else => return self.file.command(cmd),
        }
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// After the file: the mode and the caret.
    fn keptFields(self: *const MarkdownTab, buf: []u8) []const u8 {
        var caret_buf: [32]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}\t{s}", .{ @tagName(self.mode), self.file.caretField(&caret_buf) }) catch "";
    }

    pub fn save(self: *MarkdownTab, out: *std.ArrayList(u8)) bool {
        var buf: [48]u8 = undefined;
        return viewer.keep(out, self.gpa, self.file.file_path, self.keptFields(&buf));
    }

    pub fn saveVersion(self: *MarkdownTab) u64 {
        var buf: [48]u8 = undefined;
        return viewer.keptVersion(self.file.file_path, self.keptFields(&buf));
    }

    // ── drawing ─────────────────────────────────────────────────────────
    pub fn draw(self: *MarkdownTab, ui: *Ui, rect: Rect, focused: bool) void {
        const body = self.file.frame(ui, rect) orelse return;
        if (self.visual()) self.view.draw(ui, &self.file.ed, body, focused) else self.file.ed.draw(ui, body, focused);
    }

    /// The Preview / Source switch, right-aligned in the strip's spare
    /// room; nothing when there is no text to switch between.
    pub fn strip(self: *MarkdownTab, ui: *Ui, room: Rect) f32 {
        if (self.file.state == .binary or self.file.state == .failed) return 0;
        const w = self.switchWidth(ui);
        if (w > room.w) return 0;
        self.drawSwitch(ui, .{ .x = room.right() - w, .y = room.y + (room.h - switch_h) / 2, .w = w, .h = switch_h });
        return w;
    }

    fn switchWidth(_: *const MarkdownTab, ui: *Ui) f32 {
        var w: f32 = 4; // the track's inset on both sides
        for (switch_labels) |label| w += ui.text.measure(theme.font_chip, label) + 2 * switch_pad_x;
        return w;
    }

    /// A two-segment pill: the current mode sits on the raised chip, the
    /// other one is a button. Clicking a segment switches.
    fn drawSwitch(self: *MarkdownTab, ui: *Ui, r: Rect) void {
        const dl = ui.dl;
        dl.rrect(r, r.h / 2, theme.bg_inset);
        var x = r.x + 2;
        for (switch_labels, 0..) |label, i| {
            const w = ui.text.measure(theme.font_chip, label) + 2 * switch_pad_x;
            const seg: Rect = .{ .x = x, .y = r.y + 2, .w = w, .h = r.h - 4 };
            const mode: Mode = if (i == 0) .visual else .source;
            const active = self.mode == mode;
            const st = ui.button(Ui.id("markdown.mode", self.file.ed.salt * 2 + i), seg);
            if (active) dl.rrect(seg, seg.h / 2, theme.chip_active) else ui.feedback(seg, seg.h / 2, st);
            _ = dl.textCentered(theme.font_chip, seg.x + switch_pad_x, seg.centerY(), label, if (active) theme.text else theme.text_2);
            if (st.clicked) self.setMode(mode);
            x += w;
        }
    }
};

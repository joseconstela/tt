//! Image viewer: PNG, JPEG, GIF, HEIC, TIFF, BMP, WebP, PSD, RAW … whatever
//! ImageIO decodes. The picture is fitted to the card; a click switches to
//! one image pixel per point (wheel to pan) and back.
const std = @import("std");
const tab_mod = @import("tab.zig");
const viewer = @import("viewer.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const sidebar = @import("../ui/sidebar.zig");
const image = @import("../gfx/image.zig");
const texture_mod = @import("../gfx/texture.zig");
const filetype = @import("../filetype.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const pad: f32 = 24;
const line_step: f32 = 40;

pub const ImageTab = struct {
    pub const kind_label = "Image";

    gpa: std.mem.Allocator,
    textures: *texture_mod.Textures,
    file_path: []u8,
    total_size: usize = 0,
    /// Decoded, not yet on the GPU: uploaded on the first draw, then freed.
    pending: ?image.Bitmap = null,
    tex: texture_mod.Texture = .{},
    native_w: u32 = 0,
    native_h: u32 = 0,
    frames: usize = 1,
    failed: bool = false,
    /// false: fitted to the card; true: 1 px = 1 pt, scrollable.
    actual_size: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    view_h: f32 = 0,

    pub fn accepts(file: []const u8, head: []const u8) bool {
        return filetype.isImage(file, head);
    }

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        var kept = try viewer.kept(env.gpa, args.saved);
        defer if (kept) |*k| k.deinit(env.gpa);
        const file_path = args.path orelse if (kept) |k| k.path else return error.MissingPath;
        const textures = env.textures orelse return error.NoGpu;
        const self = try env.gpa.create(ImageTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .textures = textures, .file_path = try env.gpa.dupe(u8, file_path) };
        if (kept) |k| self.actual_size = if (k.field(0)) |f| std.mem.eql(u8, f, "1") else false;
        self.total_size = sys.fileSize(env.gpa, file_path) orelse 0;
        if (image.decodeImage(env.gpa, file_path, image.max_image_px)) |img| {
            self.pending = img.bitmap;
            self.native_w = img.native_w;
            self.native_h = img.native_h;
            self.frames = img.frames;
        } else |_| self.failed = true;
        return tab_mod.Tab.from(ImageTab, self);
    }

    pub fn deinit(self: *ImageTab) void {
        if (self.pending) |*bm| bm.deinit(self.gpa);
        self.textures.release(&self.tex);
        self.gpa.free(self.file_path);
        self.gpa.destroy(self);
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *ImageTab, _: []u8) []const u8 {
        return sys.basename(self.file_path);
    }

    pub fn path(self: *ImageTab) []const u8 {
        return self.file_path;
    }

    pub fn cwd(self: *ImageTab) []const u8 {
        return sys.dirname(self.file_path);
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// The file, and whether it was shown at 1:1.
    pub fn save(self: *ImageTab, out: *std.ArrayList(u8)) bool {
        return viewer.keep(out, self.gpa, self.file_path, if (self.actual_size) "1" else "0");
    }

    pub fn saveVersion(self: *ImageTab) u64 {
        return viewer.keptVersion(self.file_path, if (self.actual_size) "1" else "0");
    }

    pub fn info(self: *ImageTab, buf: []u8) []const u8 {
        var path_buf: [512]u8 = undefined;
        const shown = sys.abbreviateHome(self.file_path, &path_buf);
        if (self.failed) return std.fmt.bufPrint(buf, "{s}", .{shown}) catch "";
        var size_buf: [32]u8 = undefined;
        const size = viewer.formatSize(self.total_size, &size_buf);
        if (self.frames > 1) return std.fmt.bufPrint(buf, "{s}  ·  {d}×{d}  ·  {d} frames  ·  {s}", .{ shown, self.native_w, self.native_h, self.frames, size }) catch "";
        return std.fmt.bufPrint(buf, "{s}  ·  {d}×{d}  ·  {s}", .{ shown, self.native_w, self.native_h, size }) catch "";
    }

    pub fn onEdit(self: *ImageTab, cmd: EditCommand) void {
        self.scroll_y = viewer.scrollKey(cmd, self.scroll_y, line_step, self.view_h * 0.9, std.math.floatMax(f32));
    }

    // ── drawing ─────────────────────────────────────────────────────────
    fn ensureTexture(self: *ImageTab) void {
        const bm = &(self.pending orelse return);
        self.tex = self.textures.upload(bm.*) catch .{};
        bm.deinit(self.gpa);
        self.pending = null;
    }

    pub fn draw(self: *ImageTab, ui: *Ui, rect: Rect, focused: bool) void {
        _ = focused;
        const dl = ui.dl;
        const c = viewer.card(rect);

        var meta_buf: [96]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        const size = viewer.formatSize(self.total_size, &size_buf);
        const meta: []const u8 = if (self.failed)
            "Could not decode"
        else
            (std.fmt.bufPrint(&meta_buf, "{d}×{d}  ·  {s}", .{ self.native_w, self.native_h, size }) catch "");
        const body = viewer.header(ui, c, .image, sys.basename(self.file_path), meta);
        self.view_h = body.h;

        self.ensureTexture();
        if (self.failed or !self.tex.valid()) {
            viewer.notice(ui, body, "This image could not be decoded.");
            return;
        }

        dl.pushClip(body);
        defer dl.popClip();
        dl.rect(body, theme.bg_inset);

        // Fit shrinks only: small pictures show at their size.
        const iw: f32 = @floatFromInt(self.native_w);
        const ih: f32 = @floatFromInt(self.native_h);
        const fit = @min(1, @min((body.w - 2 * pad) / iw, (body.h - 2 * pad) / ih));
        const zoomable = fit < 1;
        const s: f32 = if (self.actual_size and zoomable) 1 else fit;
        const shown_w = iw * s;
        const shown_h = ih * s;

        // Larger than the body (only at 1:1): the wheel pans, both ways.
        const content_w = shown_w + 2 * pad;
        const content_h = shown_h + 2 * pad;
        const max_sx = @max(0, content_w - body.w);
        const max_sy = @max(0, content_h - body.h);
        const vbar = Ui.id("image.vbar", 0);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, body, self.scroll_y, content_h)) |sy| self.scroll_y = sy;
        if (ui.mouseIn(body) and ui.scroll_x != 0) {
            self.scroll_x -= ui.scroll_x;
            ui.scroll_x = 0;
        }
        self.scroll_x = std.math.clamp(self.scroll_x, 0, max_sx);
        self.scroll_y = std.math.clamp(self.scroll_y - ui.takeScroll(body), 0, max_sy);

        const x = if (max_sx > 0) body.x + pad - self.scroll_x else body.x + (body.w - shown_w) / 2;
        const y = if (max_sy > 0) body.y + pad - self.scroll_y else body.y + (body.h - shown_h) / 2;
        const r: Rect = .{ .x = x, .y = y, .w = shown_w, .h = shown_h };

        if (zoomable) {
            const st = ui.button(Ui.id("image.zoom", 0), r);
            if (st.clicked) {
                self.actual_size = !self.actual_size;
                self.scroll_x = 0;
                self.scroll_y = 0;
            }
        }
        dl.image(r, self.tex, .{ .r = 1, .g = 1, .b = 1 });

        if (zoomable) {
            var hint_buf: [48]u8 = undefined;
            const hint: []const u8 = if (self.actual_size)
                "100%  ·  click to fit"
            else
                (std.fmt.bufPrint(&hint_buf, "{d}%  ·  click for 100%", .{@as(u32, @intFromFloat(@round(fit * 100)))}) catch "");
            // On a pill, so it reads over any picture.
            const hw = ui.text.measure(theme.font_hint, hint);
            const pill: Rect = .{ .x = body.right() - theme.block_pad_x - hw - 20, .y = body.bottom() - 30, .w = hw + 20, .h = 22 };
            dl.rrect(pill, 11, theme.bg_panel.alpha(0.88));
            _ = dl.textCentered(theme.font_hint, pill.x + 10, pill.centerY(), hint, theme.text_2);
        }
        sidebar.drawScrollbarAxis(ui, vbar, .vertical, body, self.scroll_y, content_h);
    }
};

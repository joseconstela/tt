//! PDF viewer: the pages one under another at the card's width, rendered
//! by CGPDF at the backing scale as they scroll into view and dropped
//! again once they are far off, so long documents stay cheap.
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

const page_pad: f32 = 24;
const page_gap: f32 = 16;
const line_step: f32 = 40;
/// Pages kept rasterised on either side of the visible ones.
const keep_around: usize = 2;
/// While the width keeps changing (live resize) a page is re-rendered at
/// most this often; in between the old raster is drawn stretched.
const rerender_after: f64 = 0.15;

const Page = struct {
    w_pt: f32,
    h_pt: f32,
    tex: texture_mod.Texture = .{},
    rendered_at: f64 = -1,
};

pub const PdfTab = struct {
    pub const kind_label = "PDF";

    gpa: std.mem.Allocator,
    textures: *texture_mod.Textures,
    file_path: []u8,
    total_size: usize = 0,
    doc: ?image.Pdf = null,
    pages: std.ArrayList(Page) = .empty,
    failed: bool = false,
    scroll: f32 = 0,
    content_h: f32 = 0,
    view_h: f32 = 0,
    /// The page taking up most of the view (0-based).
    current: usize = 0,
    /// A page to scroll to on the next draw (an earlier run was on it).
    go_to: ?usize = null,

    pub fn accepts(file: []const u8, head: []const u8) bool {
        return filetype.isPdf(file, head);
    }

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        var kept = try viewer.kept(env.gpa, args.saved);
        defer if (kept) |*k| k.deinit(env.gpa);
        const file_path = args.path orelse if (kept) |k| k.path else return error.MissingPath;
        const textures = env.textures orelse return error.NoGpu;
        const self = try env.gpa.create(PdfTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .textures = textures, .file_path = try env.gpa.dupe(u8, file_path) };
        self.total_size = sys.fileSize(env.gpa, file_path) orelse 0;
        if (image.Pdf.open(file_path)) |doc| {
            self.doc = doc;
            var i: usize = 0;
            while (i < doc.pages) : (i += 1) {
                const size = doc.pageSize(i);
                self.pages.append(env.gpa, .{ .w_pt = size.w, .h_pt = size.h }) catch break;
            }
        } else |_| self.failed = true;
        if (kept) |k| self.go_to = std.fmt.parseInt(usize, k.field(0) orelse "", 10) catch null;
        return tab_mod.Tab.from(PdfTab, self);
    }

    pub fn deinit(self: *PdfTab) void {
        for (self.pages.items) |*p| self.textures.release(&p.tex);
        self.pages.deinit(self.gpa);
        if (self.doc) |*d| d.deinit();
        self.gpa.free(self.file_path);
        self.gpa.destroy(self);
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *PdfTab, _: []u8) []const u8 {
        return sys.basename(self.file_path);
    }

    pub fn path(self: *PdfTab) []const u8 {
        return self.file_path;
    }

    pub fn cwd(self: *PdfTab) []const u8 {
        return sys.dirname(self.file_path);
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// The file and the page it was on.
    pub fn save(self: *PdfTab, out: *std.ArrayList(u8)) bool {
        var buf: [32]u8 = undefined;
        return viewer.keep(out, self.gpa, self.file_path, std.fmt.bufPrint(&buf, "{d}", .{self.current}) catch "");
    }

    pub fn saveVersion(self: *PdfTab) u64 {
        var buf: [32]u8 = undefined;
        return viewer.keptVersion(self.file_path, std.fmt.bufPrint(&buf, "{d}", .{self.current}) catch "");
    }

    pub fn info(self: *PdfTab, buf: []u8) []const u8 {
        var path_buf: [512]u8 = undefined;
        const shown = sys.abbreviateHome(self.file_path, &path_buf);
        const n = self.pages.items.len;
        if (n == 0) return std.fmt.bufPrint(buf, "{s}", .{shown}) catch "";
        return std.fmt.bufPrint(buf, "{s}  ·  page {d} of {d}", .{ shown, self.current + 1, n }) catch "";
    }

    pub fn onEdit(self: *PdfTab, cmd: EditCommand) void {
        self.scroll = viewer.scrollKey(cmd, self.scroll, line_step, self.view_h * 0.9, self.content_h);
    }

    // ── drawing ─────────────────────────────────────────────────────────
    /// Rasterises page `i` `want_px` wide unless it already is (or was, a
    /// moment ago: the stale raster is stretched until things settle).
    fn ensureRendered(self: *PdfTab, i: usize, want_px: u32, now: f64) bool {
        const p = &self.pages.items[i];
        if (p.tex.valid() and p.tex.width == want_px) return true;
        if (p.tex.valid() and now - p.rendered_at < rerender_after) return false;
        const doc = self.doc orelse return p.tex.valid();
        var bm = doc.render(self.gpa, i, want_px) catch return p.tex.valid();
        defer bm.deinit(self.gpa);
        const tex = self.textures.upload(bm) catch return p.tex.valid();
        self.textures.release(&p.tex);
        p.tex = tex;
        p.rendered_at = now;
        return true;
    }

    pub fn draw(self: *PdfTab, ui: *Ui, rect: Rect, focused: bool) void {
        _ = focused;
        const dl = ui.dl;
        const c = viewer.card(rect);
        const n = self.pages.items.len;

        var meta_buf: [96]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        const size = viewer.formatSize(self.total_size, &size_buf);
        const locked = if (self.doc) |d| d.locked else false;
        const meta: []const u8 = if (self.failed)
            "Could not open"
        else if (locked)
            (std.fmt.bufPrint(&meta_buf, "Locked  ·  {s}", .{size}) catch "Locked")
        else
            (std.fmt.bufPrint(&meta_buf, "{d} / {d}  ·  {s}", .{ self.current + 1, n, size }) catch "");
        const body = viewer.header(ui, c, .document, sys.basename(self.file_path), meta);
        self.view_h = body.h;

        if (self.failed) return viewer.notice(ui, body, "The file could not be opened as a PDF.");
        if (locked) return viewer.notice(ui, body, "This PDF is password-protected; nothing can be shown.");
        if (n == 0) return viewer.notice(ui, body, "This PDF has no pages.");

        // Layout: every page as wide as the column, heights follow.
        const pw = @max(1, body.w - 2 * page_pad);
        var total: f32 = page_pad;
        for (self.pages.items, 0..) |p, i| {
            if (i > 0) total += page_gap;
            total += pw * p.h_pt / p.w_pt;
        }
        total += page_pad;
        self.content_h = total;
        if (self.go_to) |target| {
            // Now that the pages have heights: back to the page an earlier run was on.
            self.go_to = null;
            var top: f32 = 0;
            for (self.pages.items[0..@min(target, n)]) |p| top += pw * p.h_pt / p.w_pt + page_gap;
            self.scroll = top;
        }
        const max_scroll = @max(0, total - body.h);
        const vbar = Ui.id("pdf.vbar", 0);
        if (sidebar.scrollbarDrag(ui, vbar, .vertical, body, self.scroll, total)) |s| self.scroll = s;
        self.scroll = std.math.clamp(self.scroll - ui.takeScroll(body), 0, max_scroll);

        dl.pushClip(body);
        defer dl.popClip();
        dl.rect(body, theme.bg_inset);

        const want_px: u32 = @intFromFloat(@round(pw * dl.scale));
        var first_visible: ?usize = null;
        var last_visible: usize = 0;
        var best_overlap: f32 = 0;
        var y = body.y + page_pad - self.scroll;
        for (self.pages.items, 0..) |*p, i| {
            const ph = pw * p.h_pt / p.w_pt;
            const r: Rect = .{ .x = body.x + page_pad, .y = y, .w = pw, .h = ph };
            y += ph + page_gap;
            if (r.bottom() <= body.y or r.y >= body.bottom()) continue;
            if (first_visible == null) first_visible = i;
            last_visible = i;
            const overlap = @min(r.bottom(), body.bottom()) - @max(r.y, body.y);
            if (overlap > best_overlap) {
                best_overlap = overlap;
                self.current = i;
            }
            if (!self.ensureRendered(i, want_px, ui.now)) ui.wants_frame = true;
            if (p.tex.valid()) {
                dl.image(r, p.tex, .{ .r = 1, .g = 1, .b = 1 });
            } else {
                dl.rect(r, theme.text);
            }
        }
        const fv = first_visible orelse 0;

        // Drop rasters far from the view so memory stays bounded.
        for (self.pages.items, 0..) |*p, i| {
            if (i + keep_around < fv or i > last_visible + keep_around) self.textures.release(&p.tex);
        }
        sidebar.drawScrollbarAxis(ui, vbar, .vertical, body, self.scroll, total);
    }
};

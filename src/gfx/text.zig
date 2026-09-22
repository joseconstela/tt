//! Text engine: CoreText fonts → glyph lookup with fallback → alpha atlas.
//! All public measurements are in points; rasterisation happens at the
//! window's backing scale so glyphs are pixel-exact on Retina displays.
const std = @import("std");
const apple = @import("../apple.zig");
const icons = @import("icons.zig");

pub const Face = enum(u8) {
    sans,
    sans_medium,
    sans_semibold,
    mono,
    mono_medium,
    mono_semibold,

    pub fn isMono(self: Face) bool {
        return @intFromEnum(self) >= @intFromEnum(Face.mono);
    }

    fn weight(self: Face) f64 {
        return switch (self) {
            .sans, .mono => 400,
            .sans_medium, .mono_medium => 500,
            .sans_semibold, .mono_semibold => 600,
        };
    }
};

pub const Font = struct {
    face: Face,
    size: f32,

    pub fn sans(size: f32) Font {
        return .{ .face = .sans, .size = size };
    }
    pub fn medium(size: f32) Font {
        return .{ .face = .sans_medium, .size = size };
    }
    pub fn semibold(size: f32) Font {
        return .{ .face = .sans_semibold, .size = size };
    }
    pub fn mono(size: f32) Font {
        return .{ .face = .mono, .size = size };
    }
    pub fn monoMedium(size: f32) Font {
        return .{ .face = .mono_medium, .size = size };
    }
    pub fn monoSemibold(size: f32) Font {
        return .{ .face = .mono_semibold, .size = size };
    }
};

pub const GlyphInfo = struct {
    font_idx: u16,
    glyph: u16,
    /// Advance in device pixels.
    advance: f32,
};

pub const AtlasEntry = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
};

const FontInst = struct {
    ct: apple.CTFontRef,
    ascent: f32,
    descent: f32,
    /// Fixed cell advance (px) for monospace faces, 0 otherwise.
    cell: f32 = 0,
};

pub const atlas_size: u32 = 2048;
const scratch_size: usize = 512;

pub const Utf8Iter = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *Utf8Iter) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const b0 = self.bytes[self.index];
        const len: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
            self.index += 1;
            return 0xFFFD;
        };
        if (self.index + len > self.bytes.len) {
            self.index = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.index .. self.index + len]) catch {
            self.index += 1;
            return 0xFFFD;
        };
        self.index += len;
        return cp;
    }
};

/// Display width in terminal cells.
pub const cellWidth = @import("../term/width.zig").cellWidth;

pub const TextEngine = struct {
    gpa: std.mem.Allocator,
    scale: f32 = 2,

    sans_desc: apple.CTFontDescriptorRef = null,
    mono_desc: apple.CTFontDescriptorRef = null,
    wght_axis: apple.CFNumberRef = null,

    insts: std.ArrayList(FontInst) = .empty,
    inst_map: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    glyph_map: std.AutoHashMapUnmanaged(u64, GlyphInfo) = .empty,
    atlas_map: std.AutoHashMapUnmanaged(u32, AtlasEntry) = .empty,
    icon_map: std.AutoHashMapUnmanaged(u32, AtlasEntry) = .empty,

    pixels: []u8 = &.{},
    pack_x: u32 = 1,
    pack_y: u32 = 1,
    pack_row_h: u32 = 0,
    dirty: bool = false,
    dirty_y0: u32 = 0,
    dirty_y1: u32 = 0,
    /// Bumped whenever the atlas is wiped; draw lists built before are stale.
    generation: u32 = 0,

    scratch: []u8 = &.{},
    scratch_ctx: apple.CGContextRef = null,

    pub fn init(gpa: std.mem.Allocator) !TextEngine {
        var self: TextEngine = .{ .gpa = gpa };
        self.pixels = try gpa.alloc(u8, atlas_size * atlas_size);
        @memset(self.pixels, 0);
        self.scratch = try gpa.alloc(u8, scratch_size * scratch_size);
        @memset(self.scratch, 0);

        const gray = apple.CGColorSpaceCreateDeviceGray();
        defer apple.CGColorSpaceRelease(gray);
        self.scratch_ctx = apple.CGBitmapContextCreate(self.scratch.ptr, scratch_size, scratch_size, 8, scratch_size, gray, apple.kCGImageAlphaNone);
        if (self.scratch_ctx == null) return error.BitmapContextFailed;
        const ctx = self.scratch_ctx;
        apple.CGContextSetAllowsAntialiasing(ctx, true);
        apple.CGContextSetShouldAntialias(ctx, true);
        apple.CGContextSetAllowsFontSmoothing(ctx, true);
        apple.CGContextSetShouldSmoothFonts(ctx, true);
        apple.CGContextSetAllowsFontSubpixelPositioning(ctx, false);
        apple.CGContextSetShouldSubpixelPositionFonts(ctx, false);
        apple.CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        apple.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);

        self.sans_desc = loadDescriptor(@embedFile("font_sans"));
        self.mono_desc = loadDescriptor(@embedFile("font_mono"));
        const tag: i64 = 0x77676874; // 'wght'
        self.wght_axis = apple.CFNumberCreate(null, apple.kCFNumberSInt64Type, &tag);
        return self;
    }

    fn loadDescriptor(bytes: []const u8) apple.CTFontDescriptorRef {
        const data = apple.CFDataCreateWithBytesNoCopy(null, bytes.ptr, @intCast(bytes.len), apple.kCFAllocatorNull);
        if (data == null) return null;
        defer apple.CFRelease(data);
        return apple.CTFontManagerCreateFontDescriptorFromData(data);
    }

    pub fn setScale(self: *TextEngine, scale: f32) void {
        if (scale == self.scale) return;
        self.scale = scale;
        for (self.insts.items) |inst| apple.CFRelease(inst.ct);
        self.insts.clearRetainingCapacity();
        self.inst_map.clearRetainingCapacity();
        self.glyph_map.clearRetainingCapacity();
        self.resetAtlas();
    }

    fn resetAtlas(self: *TextEngine) void {
        self.atlas_map.clearRetainingCapacity();
        self.icon_map.clearRetainingCapacity();
        @memset(self.pixels, 0);
        self.pack_x = 1;
        self.pack_y = 1;
        self.pack_row_h = 0;
        self.dirty = true;
        self.dirty_y0 = 0;
        self.dirty_y1 = atlas_size;
        self.generation +%= 1;
    }

    // ── fonts ───────────────────────────────────────────────────────────
    fn instFor(self: *TextEngine, font: Font) u16 {
        const px = font.size * self.scale;
        const q: u32 = @intFromFloat(@round(px * 8));
        const key: u32 = (@as(u32, @intFromEnum(font.face)) << 24) | (q & 0xFFFFFF);
        if (self.inst_map.get(key)) |idx| return idx;

        const ct = self.createFont(font.face, @as(f64, px));
        var inst: FontInst = .{
            .ct = ct,
            .ascent = @floatCast(apple.CTFontGetAscent(ct)),
            .descent = @floatCast(apple.CTFontGetDescent(ct)),
        };
        if (font.face.isMono()) {
            var chars = [_]u16{'M'};
            var glyphs = [_]u16{0};
            _ = apple.CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, 1);
            // Whole-pixel cells keep columns perfectly even.
            inst.cell = @round(@as(f32, @floatCast(apple.CTFontGetAdvancesForGlyphs(ct, apple.kCTFontOrientationDefault, &glyphs, null, 1))));
        }
        const idx: u16 = @intCast(self.insts.items.len);
        self.insts.append(self.gpa, inst) catch @panic("oom");
        self.inst_map.put(self.gpa, key, idx) catch @panic("oom");
        return idx;
    }

    fn createFont(self: *TextEngine, face: Face, px: f64) apple.CTFontRef {
        const base = if (face.isMono()) self.mono_desc else self.sans_desc;
        if (base != null) {
            const desc = apple.CTFontDescriptorCreateCopyWithVariation(base, self.wght_axis, face.weight());
            if (desc != null) {
                defer apple.CFRelease(desc);
                const ct = apple.CTFontCreateWithFontDescriptor(desc, px, null);
                if (ct != null) return ct;
            }
        }
        // Fallback to system fonts if the embedded ones cannot be loaded.
        if (face.isMono()) {
            const name = apple.cfString(if (face == .mono) "Menlo-Regular" else "Menlo-Bold");
            defer apple.CFRelease(name);
            return apple.CTFontCreateWithName(name, px, null);
        }
        return apple.CTFontCreateUIFontForLanguage(apple.kCTFontUIFontSystem, px, null);
    }

    fn fallbackInst(self: *TextEngine, ct: apple.CTFontRef) u16 {
        for (self.insts.items, 0..) |inst, i| {
            if (inst.ct == ct or apple.CFEqual(inst.ct, ct)) {
                apple.CFRelease(ct);
                return @intCast(i);
            }
        }
        const idx: u16 = @intCast(self.insts.items.len);
        self.insts.append(self.gpa, .{
            .ct = ct,
            .ascent = @floatCast(apple.CTFontGetAscent(ct)),
            .descent = @floatCast(apple.CTFontGetDescent(ct)),
        }) catch @panic("oom");
        return idx;
    }

    // ── glyph lookup ────────────────────────────────────────────────────
    pub fn glyphFor(self: *TextEngine, font: Font, cp_in: u21) GlyphInfo {
        const base_idx = self.instFor(font);
        const cp: u21 = if (cp_in == '\t') ' ' else cp_in;
        const key: u64 = (@as(u64, base_idx) << 32) | cp;
        if (self.glyph_map.get(key)) |gi| return gi;

        var chars: [2]u16 = undefined;
        var n: usize = 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            chars[0] = @intCast(0xD800 + (v >> 10));
            chars[1] = @intCast(0xDC00 + (v & 0x3FF));
            n = 2;
        } else chars[0] = @intCast(cp);

        var glyphs = [_]u16{ 0, 0 };
        var font_idx = base_idx;
        const base = self.insts.items[base_idx];
        const ok = apple.CTFontGetGlyphsForCharacters(base.ct, &chars, &glyphs, @intCast(n));
        if (!ok or glyphs[0] == 0) {
            const str = apple.CFStringCreateWithCharacters(null, &chars, @intCast(n));
            if (str != null) {
                defer apple.CFRelease(str);
                const fb = apple.CTFontCreateForString(base.ct, str, .{ .location = 0, .length = @intCast(n) });
                if (fb != null) {
                    var fb_glyphs = [_]u16{ 0, 0 };
                    if (apple.CTFontGetGlyphsForCharacters(fb, &chars, &fb_glyphs, @intCast(n)) and fb_glyphs[0] != 0) {
                        font_idx = self.fallbackInst(fb);
                        glyphs = fb_glyphs;
                    } else apple.CFRelease(fb);
                }
            }
        }

        const inst = self.insts.items[font_idx];
        var adv: f32 = @floatCast(apple.CTFontGetAdvancesForGlyphs(inst.ct, apple.kCTFontOrientationDefault, &glyphs, null, 1));
        if (base.cell > 0) adv = base.cell * @as(f32, @floatFromInt(cellWidth(cp)));
        const gi: GlyphInfo = .{ .font_idx = font_idx, .glyph = glyphs[0], .advance = adv };
        self.glyph_map.put(self.gpa, key, gi) catch {};
        return gi;
    }

    /// Advance of one code point, in points.
    pub fn advance(self: *TextEngine, font: Font, cp: u21) f32 {
        return self.glyphFor(font, cp).advance / self.scale;
    }

    /// Width of a string, in points.
    pub fn measure(self: *TextEngine, font: Font, str: []const u8) f32 {
        var it = Utf8Iter{ .bytes = str };
        var w: f32 = 0;
        while (it.next()) |cp| w += self.glyphFor(font, cp).advance;
        return w / self.scale;
    }

    /// Fixed cell advance in points (monospace faces only).
    pub fn cellAdvance(self: *TextEngine, font: Font) f32 {
        const inst = self.insts.items[self.instFor(font)];
        return inst.cell / self.scale;
    }

    pub fn ascent(self: *TextEngine, font: Font) f32 {
        return self.insts.items[self.instFor(font)].ascent / self.scale;
    }

    pub fn descent(self: *TextEngine, font: Font) f32 {
        return self.insts.items[self.instFor(font)].descent / self.scale;
    }

    /// Baseline that vertically centres the font's content area on `center_y`.
    pub fn baselineForCenter(self: *TextEngine, font: Font, center_y: f32) f32 {
        const inst = self.insts.items[self.instFor(font)];
        return center_y + (inst.ascent - inst.descent) / (2 * self.scale);
    }

    // ── atlas ───────────────────────────────────────────────────────────
    fn pack(self: *TextEngine, w: u32, h: u32) ?[2]u32 {
        if (w + 2 > atlas_size or h + 2 > atlas_size) return null;
        if (self.pack_x + w + 1 > atlas_size) {
            self.pack_x = 1;
            self.pack_y += self.pack_row_h + 1;
            self.pack_row_h = 0;
        }
        if (self.pack_y + h + 1 > atlas_size) {
            // Atlas exhausted: wipe and start again. Callers holding UVs from
            // this frame will notice via `generation`.
            self.resetAtlas();
        }
        const pos = [2]u32{ self.pack_x, self.pack_y };
        self.pack_x += w + 1;
        self.pack_row_h = @max(self.pack_row_h, h);
        return pos;
    }

    fn commitScratch(self: *TextEngine, w: u32, h: u32) ?[2]u32 {
        const pos = self.pack(w, h) orelse return null;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const src = self.scratch[row * scratch_size ..][0..w];
            const dst = self.pixels[(pos[1] + row) * atlas_size + pos[0] ..][0..w];
            @memcpy(dst, src);
        }
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_y0 = pos[1];
            self.dirty_y1 = pos[1] + h;
        } else {
            self.dirty_y0 = @min(self.dirty_y0, pos[1]);
            self.dirty_y1 = @max(self.dirty_y1, pos[1] + h);
        }
        return pos;
    }

    fn clearScratch(self: *TextEngine, w: u32, h: u32) void {
        var row: u32 = 0;
        while (row < h) : (row += 1) @memset(self.scratch[row * scratch_size ..][0..w], 0);
    }

    pub fn atlasEntry(self: *TextEngine, gi: GlyphInfo) ?AtlasEntry {
        const key: u32 = (@as(u32, gi.font_idx) << 16) | gi.glyph;
        if (self.atlas_map.get(key)) |e| return e;

        const inst = self.insts.items[gi.font_idx];
        var glyphs = [_]u16{gi.glyph};
        var bbox: apple.CGRect = .{};
        _ = apple.CTFontGetBoundingRectsForGlyphs(inst.ct, apple.kCTFontOrientationDefault, &glyphs, @ptrCast(&bbox), 1);

        var entry: AtlasEntry = .{};
        if (bbox.size.width > 0 and bbox.size.height > 0) {
            const pad: f64 = 1;
            const x0 = @floor(bbox.origin.x) - pad;
            const y0 = @floor(bbox.origin.y) - pad;
            const x1 = @ceil(bbox.origin.x + bbox.size.width) + pad;
            const y1 = @ceil(bbox.origin.y + bbox.size.height) + pad;
            const gw: u32 = @intFromFloat(x1 - x0);
            const gh: u32 = @intFromFloat(y1 - y0);
            if (gw <= scratch_size and gh <= scratch_size) {
                self.clearScratch(gw, gh);
                apple.CGContextSetGrayFillColor(self.scratch_ctx, 1, 1);
                const pos = [_]apple.CGPoint{.{
                    .x = -x0,
                    .y = @as(f64, @floatFromInt(scratch_size - gh)) - y0,
                }};
                apple.CTFontDrawGlyphs(inst.ct, &glyphs, &pos, 1, self.scratch_ctx);
                if (self.commitScratch(gw, gh)) |p| {
                    entry = .{
                        .x = @intCast(p[0]),
                        .y = @intCast(p[1]),
                        .w = @intCast(gw),
                        .h = @intCast(gh),
                        .bearing_x = @floatCast(x0),
                        .bearing_y = @floatCast(y1),
                    };
                }
            }
        }
        self.atlas_map.put(self.gpa, key, entry) catch {};
        return entry;
    }

    pub fn iconEntry(self: *TextEngine, which: icons.Icon, size_pt: f32) ?AtlasEntry {
        const size_px: u32 = @intFromFloat(@round(size_pt * self.scale));
        if (size_px == 0) return null;
        const key: u32 = (@as(u32, @intFromEnum(which)) << 16) | (size_px & 0xFFFF);
        if (self.icon_map.get(key)) |e| return e;

        const dim = size_px + 2 * icons.pad_px;
        if (dim > scratch_size) return null;
        self.clearScratch(dim, dim);
        const ctx = self.scratch_ctx;
        apple.CGContextSaveGState(ctx);
        // Top-left of the scratch bitmap is (0, scratch_size) in CG space.
        apple.CGContextTranslateCTM(ctx, @floatFromInt(icons.pad_px), @floatFromInt(scratch_size - icons.pad_px));
        const k: f64 = @as(f64, @floatFromInt(size_px)) / 24.0;
        apple.CGContextScaleCTM(ctx, k, -k);
        icons.stroke(ctx, which);
        apple.CGContextRestoreGState(ctx);

        var entry: AtlasEntry = .{};
        if (self.commitScratch(dim, dim)) |p| {
            entry = .{ .x = @intCast(p[0]), .y = @intCast(p[1]), .w = @intCast(dim), .h = @intCast(dim) };
        }
        self.icon_map.put(self.gpa, key, entry) catch {};
        return entry;
    }
};

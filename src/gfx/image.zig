//! Decoding documents into CPU bitmaps: still images through ImageIO, PDF
//! pages through CGPDF. Nothing here touches the GPU — `texture.zig`
//! uploads what comes out, and viewers draw it with `DrawList.image`.
const std = @import("std");
const apple = @import("../apple.zig");

/// BGRA, premultiplied alpha, `width * 4` bytes per row: what a CoreGraphics
/// bitmap context writes and what Metal's BGRA8Unorm reads back, so nothing
/// is converted in between. Row 0 is the top edge.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Bitmap, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.* = .{ .width = 0, .height = 0, .pixels = &.{} };
    }
};

/// Longest side, in pixels, that `decodeImage` hands back; bigger sources
/// are downsampled while decoding (a 4096² BGRA texture is already 64 MB).
pub const max_image_px: u32 = 4096;

const bitmap_info: u32 = apple.kCGImageAlphaPremultipliedFirst | apple.kCGBitmapByteOrder32Little;

/// A blank bitmap with a CoreGraphics context drawing into it (sRGB).
const Canvas = struct {
    bitmap: Bitmap,
    ctx: apple.CGContextRef,

    fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Canvas {
        if (width == 0 or height == 0) return error.EmptyBitmap;
        const stride = @as(usize, width) * 4;
        const pixels = try gpa.alloc(u8, stride * height);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);
        const cs = apple.CGColorSpaceCreateWithName(apple.kCGColorSpaceSRGB);
        defer apple.CGColorSpaceRelease(cs);
        const ctx = apple.CGBitmapContextCreate(pixels.ptr, width, height, 8, stride, cs, bitmap_info);
        if (ctx == null) return error.BitmapContextFailed;
        apple.CGContextSetInterpolationQuality(ctx, apple.kCGInterpolationHigh);
        apple.CGContextSetAllowsAntialiasing(ctx, true);
        apple.CGContextSetShouldAntialias(ctx, true);
        apple.CGContextSetAllowsFontSmoothing(ctx, true);
        apple.CGContextSetShouldSmoothFonts(ctx, true);
        return .{ .bitmap = .{ .width = width, .height = height, .pixels = pixels }, .ctx = ctx };
    }

    /// Releases the context; the bitmap is the caller's from here on.
    fn finish(self: *Canvas) Bitmap {
        apple.CGContextRelease(self.ctx);
        self.ctx = null;
        return self.bitmap;
    }
};

fn fileUrl(path: []const u8) apple.CFURLRef {
    return apple.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false);
}

fn numberAt(dict: apple.CFDictionaryRef, key: apple.CFStringRef) ?i64 {
    const v = apple.CFDictionaryGetValue(dict, key) orelse return null;
    var out: i64 = 0;
    if (!apple.CFNumberGetValue(@constCast(v), apple.kCFNumberSInt64Type, &out)) return null;
    return out;
}

// ── still images ────────────────────────────────────────────────────────
pub const Image = struct {
    bitmap: Bitmap,
    /// Size of the source in pixels (after EXIF rotation); larger than the
    /// bitmap when the file was downsampled to fit `max_px`.
    native_w: u32,
    native_h: u32,
    /// Frames in the file (animated GIF/PNG/WebP); only the first is decoded.
    frames: usize,
};

/// Decodes the first frame of an image file — PNG, JPEG, GIF, HEIC, TIFF,
/// BMP, WebP, PSD, RAW … whatever ImageIO reads — applying the EXIF
/// orientation and keeping the longer side at most `max_px`.
pub fn decodeImage(gpa: std.mem.Allocator, path: []const u8, max_px: u32) !Image {
    const url = fileUrl(path);
    if (url == null) return error.BadPath;
    defer apple.CFRelease(url);
    const src = apple.CGImageSourceCreateWithURL(url, null);
    if (src == null) return error.NotAnImage;
    defer apple.CFRelease(src);
    return decodeSource(gpa, src, max_px);
}

/// `decodeImage` for an image held in memory (a notebook's PNG output).
/// `bytes` must stay alive until this returns.
pub fn decodeBytes(gpa: std.mem.Allocator, bytes: []const u8, max_px: u32) !Image {
    if (bytes.len == 0) return error.NotAnImage;
    const data = apple.CFDataCreateWithBytesNoCopy(null, bytes.ptr, @intCast(bytes.len), apple.kCFAllocatorNull);
    if (data == null) return error.NotAnImage;
    defer apple.CFRelease(data);
    const src = apple.CGImageSourceCreateWithData(data, null);
    if (src == null) return error.NotAnImage;
    defer apple.CFRelease(src);
    return decodeSource(gpa, src, max_px);
}

fn decodeSource(gpa: std.mem.Allocator, src: apple.CGImageSourceRef, max_px: u32) !Image {
    const frames = apple.CGImageSourceGetCount(src);
    if (frames == 0) return error.NotAnImage;

    // Native size + orientation from the metadata (no decode yet).
    var native_w: u32 = 0;
    var native_h: u32 = 0;
    var orientation: i64 = 1;
    if (apple.CGImageSourceCopyPropertiesAtIndex(src, 0, null)) |props| {
        defer apple.CFRelease(props);
        native_w = @intCast(@max(0, numberAt(props, apple.kCGImagePropertyPixelWidth) orelse 0));
        native_h = @intCast(@max(0, numberAt(props, apple.kCGImagePropertyPixelHeight) orelse 0));
        orientation = numberAt(props, apple.kCGImagePropertyOrientation) orelse 1;
    }
    // EXIF 5–8 are the transposed orientations.
    if (orientation >= 5) std.mem.swap(u32, &native_w, &native_h);

    // Decode from the real image (not an embedded preview), rotated, capped.
    const max_val: i64 = max_px;
    const max_num = apple.CFNumberCreate(null, apple.kCFNumberSInt64Type, &max_val);
    defer apple.CFRelease(max_num);
    const keys = [_]?*const anyopaque{
        apple.kCGImageSourceCreateThumbnailFromImageAlways,
        apple.kCGImageSourceCreateThumbnailWithTransform,
        apple.kCGImageSourceThumbnailMaxPixelSize,
    };
    const values = [_]?*const anyopaque{ apple.kCFBooleanTrue, apple.kCFBooleanTrue, max_num };
    const opts = apple.CFDictionaryCreate(null, &keys, &values, keys.len, &apple.kCFTypeDictionaryKeyCallBacks, &apple.kCFTypeDictionaryValueCallBacks);
    defer apple.CFRelease(opts);
    const cg = apple.CGImageSourceCreateThumbnailAtIndex(src, 0, opts);
    if (cg == null) return error.DecodeFailed;
    defer apple.CGImageRelease(cg);

    const w: u32 = @intCast(apple.CGImageGetWidth(cg));
    const h: u32 = @intCast(apple.CGImageGetHeight(cg));
    var canvas = try Canvas.init(gpa, w, h);
    apple.CGContextDrawImage(canvas.ctx, apple.CGRect.make(0, 0, @floatFromInt(w), @floatFromInt(h)), cg);
    return .{
        .bitmap = canvas.finish(),
        .native_w = if (native_w > 0) native_w else w,
        .native_h = if (native_h > 0) native_h else h,
        .frames = frames,
    };
}

// ── PDF ─────────────────────────────────────────────────────────────────
pub const Pdf = struct {
    doc: apple.CGPDFDocumentRef,
    pages: usize,
    /// Encrypted with a password we do not have: nothing can be drawn.
    locked: bool,

    pub const PageSize = struct { w: f32, h: f32 };

    pub fn open(path: []const u8) !Pdf {
        const url = fileUrl(path);
        if (url == null) return error.BadPath;
        defer apple.CFRelease(url);
        const doc = apple.CGPDFDocumentCreateWithURL(url);
        if (doc == null) return error.NotAPdf;
        const locked = apple.CGPDFDocumentIsEncrypted(doc) and !apple.CGPDFDocumentIsUnlocked(doc);
        return .{
            .doc = doc,
            .pages = if (locked) 0 else apple.CGPDFDocumentGetNumberOfPages(doc),
            .locked = locked,
        };
    }

    pub fn deinit(self: *Pdf) void {
        apple.CGPDFDocumentRelease(self.doc);
        self.doc = null;
    }

    /// Size of page `index` (0-based) in points as it is displayed, i.e.
    /// its crop box with the page's /Rotate applied.
    pub fn pageSize(self: *const Pdf, index: usize) PageSize {
        const page = apple.CGPDFDocumentGetPage(self.doc, index + 1);
        if (page == null) return .{ .w = 612, .h = 792 };
        const box = apple.CGPDFPageGetBoxRect(page, apple.kCGPDFCropBox);
        var w: f32 = @floatCast(box.size.width);
        var h: f32 = @floatCast(box.size.height);
        if (!(w > 0 and h > 0)) {
            w = 612;
            h = 792;
        }
        const rot = @mod(apple.CGPDFPageGetRotationAngle(page), 360);
        if (rot == 90 or rot == 270) std.mem.swap(f32, &w, &h);
        return .{ .w = w, .h = h };
    }

    /// Rasterises page `index` on white, `width_px` pixels wide, at the
    /// aspect ratio `pageSize` reports.
    pub fn render(self: *const Pdf, gpa: std.mem.Allocator, index: usize, width_px: u32) !Bitmap {
        const page = apple.CGPDFDocumentGetPage(self.doc, index + 1);
        if (page == null) return error.NoSuchPage;
        const size = self.pageSize(index);
        const w = @max(1, width_px);
        const h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(w)) * size.h / size.w))));
        var canvas = try Canvas.init(gpa, w, h);
        const full = apple.CGRect.make(0, 0, @floatFromInt(w), @floatFromInt(h));
        apple.CGContextSetRGBFillColor(canvas.ctx, 1, 1, 1, 1);
        apple.CGContextFillRect(canvas.ctx, full);
        // Maps the crop box (rotation included) onto the whole bitmap.
        const xf = apple.CGPDFPageGetDrawingTransform(page, apple.kCGPDFCropBox, full, 0, true);
        apple.CGContextConcatCTM(canvas.ctx, xf);
        apple.CGContextDrawPDFPage(canvas.ctx, page);
        return canvas.finish();
    }
};

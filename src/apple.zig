//! Hand-written bindings for the C APIs we use from CoreFoundation,
//! CoreGraphics (incl. CGPDF), CoreText, ImageIO, QuartzCore and Metal.
const objc = @import("objc.zig");

pub const CGFloat = objc.CGFloat;
pub const CGPoint = objc.CGPoint;
pub const CGSize = objc.CGSize;
pub const CGRect = objc.CGRect;

pub const CFTypeRef = ?*anyopaque;
pub const CFIndex = c_long;
pub const CFRange = extern struct { location: CFIndex, length: CFIndex };
pub const CFStringRef = ?*anyopaque;
pub const CFDataRef = ?*anyopaque;
pub const CFURLRef = ?*anyopaque;
pub const CFNumberRef = ?*anyopaque;
pub const CFArrayRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;

pub const kCFStringEncodingUTF8: u32 = 0x08000100;
pub const kCFNumberSInt32Type: CFIndex = 3;
pub const kCFNumberSInt64Type: CFIndex = 4;
pub const kCFNumberFloat64Type: CFIndex = 6;

pub extern "c" const kCFAllocatorNull: CFAllocatorRef;

pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;
pub extern "c" fn CFEqual(a: CFTypeRef, b: CFTypeRef) bool;
pub extern "c" fn CFStringCreateWithBytes(alloc: CFAllocatorRef, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, is_external: bool) CFStringRef;
pub extern "c" fn CFStringCreateWithCharacters(alloc: CFAllocatorRef, chars: [*]const u16, num_chars: CFIndex) CFStringRef;
pub extern "c" fn CFDataCreateWithBytesNoCopy(alloc: CFAllocatorRef, bytes: [*]const u8, length: CFIndex, bytes_deallocator: CFAllocatorRef) CFDataRef;
pub extern "c" fn CFNumberCreate(alloc: CFAllocatorRef, the_type: CFIndex, value_ptr: *const anyopaque) CFNumberRef;
pub extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: CFAllocatorRef, buffer: [*]const u8, buf_len: CFIndex, is_directory: bool) CFURLRef;
pub extern "c" fn CFArrayGetCount(array: CFArrayRef) CFIndex;
pub extern "c" fn CFNumberGetValue(number: CFNumberRef, the_type: CFIndex, value_ptr: *anyopaque) bool;
pub extern "c" const kCFBooleanTrue: CFTypeRef;

pub const CFDictionaryRef = ?*anyopaque;
pub const CFDictionaryKeyCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copy_description: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
pub const CFDictionaryValueCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copy_description: ?*const anyopaque, equal: ?*const anyopaque };
pub extern "c" const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
pub extern "c" const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
pub extern "c" fn CFDictionaryCreate(alloc: CFAllocatorRef, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, count: CFIndex, key_cb: ?*const CFDictionaryKeyCallBacks, value_cb: ?*const CFDictionaryValueCallBacks) CFDictionaryRef;
pub extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;
pub extern "c" fn CFArrayGetValueAtIndex(array: CFArrayRef, idx: CFIndex) ?*const anyopaque;

// ── CoreGraphics ─────────────────────────────────────────────────────────
pub const CGContextRef = ?*anyopaque;
pub const CGColorSpaceRef = ?*anyopaque;
pub const CGImageRef = ?*anyopaque;
pub const CGDataProviderRef = ?*anyopaque;

pub const kCGImageAlphaNone: u32 = 0;
pub const kCGImageAlphaPremultipliedFirst: u32 = 2;
pub const kCGImageAlphaNoneSkipFirst: u32 = 6;
pub const kCGBitmapByteOrder32Little: u32 = 2 << 12;
pub const kCGLineCapRound: c_int = 1;
pub const kCGLineJoinRound: c_int = 1;
pub const kCGRenderingIntentDefault: c_int = 0;

pub extern "c" const kCGColorSpaceSRGB: CFStringRef;

pub extern "c" fn CGColorSpaceCreateDeviceGray() CGColorSpaceRef;
pub extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: CGColorSpaceRef, bitmap_info: u32) CGContextRef;
pub extern "c" fn CGContextRelease(ctx: CGContextRef) void;
pub extern "c" fn CGContextSetGrayFillColor(ctx: CGContextRef, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetGrayStrokeColor(ctx: CGContextRef, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextFillRect(ctx: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextSetShouldAntialias(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsFontSmoothing(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSaveGState(ctx: CGContextRef) void;
pub extern "c" fn CGContextRestoreGState(ctx: CGContextRef) void;
pub extern "c" fn CGContextScaleCTM(ctx: CGContextRef, sx: CGFloat, sy: CGFloat) void;
pub extern "c" fn CGContextTranslateCTM(ctx: CGContextRef, tx: CGFloat, ty: CGFloat) void;
pub extern "c" fn CGContextBeginPath(ctx: CGContextRef) void;
pub extern "c" fn CGContextMoveToPoint(ctx: CGContextRef, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextAddLineToPoint(ctx: CGContextRef, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextAddCurveToPoint(ctx: CGContextRef, c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextClosePath(ctx: CGContextRef) void;
pub extern "c" fn CGContextStrokePath(ctx: CGContextRef) void;
pub extern "c" fn CGContextFillPath(ctx: CGContextRef) void;
pub extern "c" fn CGContextSetLineWidth(ctx: CGContextRef, w: CGFloat) void;
pub extern "c" fn CGContextSetLineCap(ctx: CGContextRef, cap: c_int) void;
pub extern "c" fn CGContextSetLineJoin(ctx: CGContextRef, join: c_int) void;
pub extern "c" fn CGContextAddEllipseInRect(ctx: CGContextRef, rect: CGRect) void;

pub extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: *const anyopaque, size: usize, release: ?*const anyopaque) CGDataProviderRef;
pub extern "c" fn CGDataProviderRelease(p: CGDataProviderRef) void;
pub extern "c" fn CGImageCreate(width: usize, height: usize, bits_per_component: usize, bits_per_pixel: usize, bytes_per_row: usize, space: CGColorSpaceRef, bitmap_info: u32, provider: CGDataProviderRef, decode: ?[*]const CGFloat, should_interpolate: bool, intent: c_int) CGImageRef;
pub extern "c" fn CGImageRelease(img: CGImageRef) void;
pub extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
pub extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
pub extern "c" fn CGContextDrawImage(ctx: CGContextRef, rect: CGRect, image: CGImageRef) void;
pub extern "c" fn CGContextSetRGBFillColor(ctx: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern "c" fn CGContextSetInterpolationQuality(ctx: CGContextRef, quality: c_int) void;
pub extern "c" fn CGContextConcatCTM(ctx: CGContextRef, transform: CGAffineTransform) void;
pub const kCGInterpolationHigh: c_int = 3;
pub const CGAffineTransform = extern struct { a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat };

// ── CGPDF ────────────────────────────────────────────────────────────────
pub const CGPDFDocumentRef = ?*anyopaque;
pub const CGPDFPageRef = ?*anyopaque;
pub const kCGPDFMediaBox: c_int = 0;
pub const kCGPDFCropBox: c_int = 1;
pub extern "c" fn CGPDFDocumentCreateWithURL(url: CFURLRef) CGPDFDocumentRef;
pub extern "c" fn CGPDFDocumentRelease(doc: CGPDFDocumentRef) void;
pub extern "c" fn CGPDFDocumentGetNumberOfPages(doc: CGPDFDocumentRef) usize;
pub extern "c" fn CGPDFDocumentIsEncrypted(doc: CGPDFDocumentRef) bool;
pub extern "c" fn CGPDFDocumentIsUnlocked(doc: CGPDFDocumentRef) bool;
/// Page numbers start at 1.
pub extern "c" fn CGPDFDocumentGetPage(doc: CGPDFDocumentRef, page_number: usize) CGPDFPageRef;
pub extern "c" fn CGPDFPageGetBoxRect(page: CGPDFPageRef, box: c_int) CGRect;
pub extern "c" fn CGPDFPageGetRotationAngle(page: CGPDFPageRef) c_int;
pub extern "c" fn CGPDFPageGetDrawingTransform(page: CGPDFPageRef, box: c_int, rect: CGRect, rotate: c_int, preserve_aspect_ratio: bool) CGAffineTransform;
pub extern "c" fn CGContextDrawPDFPage(ctx: CGContextRef, page: CGPDFPageRef) void;

// ── ImageIO ──────────────────────────────────────────────────────────────
pub const CGImageDestinationRef = ?*anyopaque;
pub extern "c" fn CGImageDestinationCreateWithURL(url: CFURLRef, uti: CFStringRef, count: usize, options: ?*anyopaque) CGImageDestinationRef;
pub extern "c" fn CGImageDestinationAddImage(dest: CGImageDestinationRef, image: CGImageRef, properties: ?*anyopaque) void;
pub extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;

pub const CGImageSourceRef = ?*anyopaque;
pub extern "c" fn CGImageSourceCreateWithURL(url: CFURLRef, options: CFDictionaryRef) CGImageSourceRef;
pub extern "c" fn CGImageSourceGetCount(src: CGImageSourceRef) usize;
pub extern "c" fn CGImageSourceCopyPropertiesAtIndex(src: CGImageSourceRef, index: usize, options: CFDictionaryRef) CFDictionaryRef;
pub extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: CGImageSourceRef, index: usize, options: CFDictionaryRef) CGImageRef;
pub extern "c" const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
pub extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
pub extern "c" const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
pub extern "c" const kCGImagePropertyPixelWidth: CFStringRef;
pub extern "c" const kCGImagePropertyPixelHeight: CFStringRef;
pub extern "c" const kCGImagePropertyOrientation: CFStringRef;

// ── CoreText ─────────────────────────────────────────────────────────────
pub const CTFontRef = ?*anyopaque;
pub const CTFontDescriptorRef = ?*anyopaque;
pub const CGGlyph = u16;
pub const kCTFontOrientationDefault: u32 = 0;
pub const kCTFontUIFontSystem: u32 = 2;
pub const kCTFontUIFontUserFixedPitch: u32 = 1;

pub extern "c" fn CTFontManagerCreateFontDescriptorFromData(data: CFDataRef) CTFontDescriptorRef;
pub extern "c" fn CTFontDescriptorCreateCopyWithVariation(original: CTFontDescriptorRef, variation_identifier: CFNumberRef, value: CGFloat) CTFontDescriptorRef;
pub extern "c" fn CTFontCreateWithFontDescriptor(descriptor: CTFontDescriptorRef, size: CGFloat, matrix: ?*const anyopaque) CTFontRef;
pub extern "c" fn CTFontCreateWithName(name: CFStringRef, size: CGFloat, matrix: ?*const anyopaque) CTFontRef;
pub extern "c" fn CTFontCreateUIFontForLanguage(ui_type: u32, size: CGFloat, language: CFStringRef) CTFontRef;
pub extern "c" fn CTFontCreateForString(current_font: CTFontRef, string: CFStringRef, range: CFRange) CTFontRef;
pub extern "c" fn CTFontGetGlyphsForCharacters(font: CTFontRef, characters: [*]const u16, glyphs: [*]CGGlyph, count: CFIndex) bool;
pub extern "c" fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: u32, glyphs: [*]const CGGlyph, advances: ?[*]CGSize, count: CFIndex) f64;
pub extern "c" fn CTFontGetBoundingRectsForGlyphs(font: CTFontRef, orientation: u32, glyphs: [*]const CGGlyph, bounding_rects: ?[*]CGRect, count: CFIndex) CGRect;
pub extern "c" fn CTFontDrawGlyphs(font: CTFontRef, glyphs: [*]const CGGlyph, positions: [*]const CGPoint, count: usize, context: CGContextRef) void;
pub extern "c" fn CTFontGetAscent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetDescent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetLeading(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetSize(font: CTFontRef) CGFloat;

// ── QuartzCore / Metal ───────────────────────────────────────────────────
pub extern "c" fn CACurrentMediaTime() f64;
pub extern "c" fn MTLCreateSystemDefaultDevice() objc.id;

/// Owned CFString from a UTF-8 slice. Caller releases.
pub fn cfString(s: []const u8) CFStringRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), kCFStringEncodingUTF8, false);
}

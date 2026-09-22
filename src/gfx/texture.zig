//! GPU textures for decoded images and rendered pages. The renderer owns one
//! `Textures`; viewers upload bitmaps through it and draw the resulting
//! `Texture` with `DrawList.image`. Every texture gets mipmaps so pictures
//! shown smaller than their pixel size stay smooth.
const std = @import("std");
const objc = @import("../objc.zig");
const Bitmap = @import("image.zig").Bitmap;

const id = objc.id;
const msg = objc.msg;
const NSUInteger = objc.NSUInteger;

const MTLPixelFormatBGRA8Unorm: NSUInteger = 80;

pub const MTLOrigin = extern struct { x: NSUInteger, y: NSUInteger, z: NSUInteger };
pub const MTLSize = extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger };
pub const MTLRegion = extern struct { origin: MTLOrigin, size: MTLSize };

pub const Texture = struct {
    handle: id = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn valid(self: Texture) bool {
        return self.handle != null;
    }
};

pub const Textures = struct {
    device: id,
    queue: id,
    /// Level-0 bytes currently resident, for keeping an eye on viewers.
    resident_bytes: usize = 0,
    count: usize = 0,

    pub fn upload(self: *Textures, bm: Bitmap) !Texture {
        if (bm.width == 0 or bm.height == 0) return error.EmptyBitmap;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const desc = msg(id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            MTLPixelFormatBGRA8Unorm,
            @as(NSUInteger, bm.width),
            @as(NSUInteger, bm.height),
            true,
        });
        const tex = msg(id, self.device, "newTextureWithDescriptor:", .{desc});
        if (tex == null) return error.TextureFailed;
        const region: MTLRegion = .{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = bm.width, .height = bm.height, .depth = 1 },
        };
        msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            region,
            @as(NSUInteger, 0),
            @as(?*const anyopaque, bm.pixels.ptr),
            @as(NSUInteger, @as(usize, bm.width) * 4),
        });
        // Same queue as the frames, so the mipmaps exist before the next draw.
        const cmd = msg(id, self.queue, "commandBuffer", .{});
        const blit = msg(id, cmd, "blitCommandEncoder", .{});
        msg(void, blit, "generateMipmapsForTexture:", .{tex});
        msg(void, blit, "endEncoding", .{});
        msg(void, cmd, "commit", .{});

        self.resident_bytes += @as(usize, bm.width) * bm.height * 4;
        self.count += 1;
        return .{ .handle = tex, .width = bm.width, .height = bm.height };
    }

    /// Frees the GPU memory; safe to call on an empty handle.
    pub fn release(self: *Textures, tex: *Texture) void {
        if (tex.handle == null) return;
        objc.release(tex.handle);
        self.resident_bytes -= @min(self.resident_bytes, @as(usize, tex.width) * tex.height * 4);
        self.count -|= 1;
        tex.* = .{};
    }
};

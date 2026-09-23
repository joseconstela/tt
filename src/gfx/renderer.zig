//! Metal renderer: one pipeline, one instanced draw call per frame — plus
//! one more for every distinct image texture the frame shows.
const std = @import("std");
const objc = @import("../objc.zig");
const apple = @import("../apple.zig");
const draw = @import("draw.zig");
const text_mod = @import("text.zig");
const texture_mod = @import("texture.zig");

const id = objc.id;
const msg = objc.msg;
const NSUInteger = objc.NSUInteger;

const MTLPixelFormatBGRA8Unorm: NSUInteger = 80;
const MTLPixelFormatR8Unorm: NSUInteger = 10;
const MTLLoadActionClear: NSUInteger = 2;
const MTLStoreActionStore: NSUInteger = 1;
const MTLPrimitiveTypeTriangleStrip: NSUInteger = 4;
const MTLBlendFactorOne: NSUInteger = 1;
const MTLBlendFactorOneMinusSourceAlpha: NSUInteger = 5;

const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const MTLRegion = texture_mod.MTLRegion;

const Uniforms = extern struct {
    viewport: [2]f32,
    atlas_size: [2]f32,
};

pub const Renderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    atlas_tex: id,
    layer: id,
    /// Image textures (viewers upload through `Env.textures`).
    textures: texture_mod.Textures,

    pub fn init(layer: id) !Renderer {
        const device = apple.MTLCreateSystemDefaultDevice();
        if (device == null) return error.NoMetalDevice;
        const queue = msg(id, device, "newCommandQueue", .{});

        // Compile the shader library at startup; no offline metal toolchain needed.
        var err: id = null;
        const src = objc.nsString(@embedFile("shaders_metal"));
        const library = msg(id, device, "newLibraryWithSource:options:error:", .{ src, @as(id, null), &err });
        if (library == null) {
            std.debug.print("metal: shader compile failed: {s}\n", .{describe(err)});
            return error.ShaderCompileFailed;
        }
        defer objc.release(library);
        const vs = msg(id, library, "newFunctionWithName:", .{objc.nsString("tt_vs")});
        const fs = msg(id, library, "newFunctionWithName:", .{objc.nsString("tt_fs")});
        defer objc.release(vs);
        defer objc.release(fs);

        const desc = objc.new("MTLRenderPipelineDescriptor");
        defer objc.release(desc);
        msg(void, desc, "setVertexFunction:", .{vs});
        msg(void, desc, "setFragmentFunction:", .{fs});
        const attachments = msg(id, desc, "colorAttachments", .{});
        const ca0 = msg(id, attachments, "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        msg(void, ca0, "setPixelFormat:", .{MTLPixelFormatBGRA8Unorm});
        msg(void, ca0, "setBlendingEnabled:", .{true});
        // Premultiplied-alpha "over".
        msg(void, ca0, "setSourceRGBBlendFactor:", .{MTLBlendFactorOne});
        msg(void, ca0, "setDestinationRGBBlendFactor:", .{MTLBlendFactorOneMinusSourceAlpha});
        msg(void, ca0, "setSourceAlphaBlendFactor:", .{MTLBlendFactorOne});
        msg(void, ca0, "setDestinationAlphaBlendFactor:", .{MTLBlendFactorOneMinusSourceAlpha});

        const pipeline = msg(id, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
        if (pipeline == null) {
            std.debug.print("metal: pipeline creation failed: {s}\n", .{describe(err)});
            return error.PipelineFailed;
        }

        const tex_desc = msg(id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            MTLPixelFormatR8Unorm,
            @as(NSUInteger, text_mod.atlas_size),
            @as(NSUInteger, text_mod.atlas_size),
            false,
        });
        const atlas_tex = msg(id, device, "newTextureWithDescriptor:", .{tex_desc});
        if (atlas_tex == null) return error.AtlasTextureFailed;

        if (layer != null) {
            msg(void, layer, "setDevice:", .{device});
            msg(void, layer, "setPixelFormat:", .{MTLPixelFormatBGRA8Unorm});
            msg(void, layer, "setFramebufferOnly:", .{true});
            msg(void, layer, "setOpaque:", .{true});
            // Interpret our colours as sRGB so hex values match the design.
            const cs = apple.CGColorSpaceCreateWithName(apple.kCGColorSpaceSRGB);
            msg(void, layer, "setColorspace:", .{cs});
            apple.CGColorSpaceRelease(cs);
        }

        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .atlas_tex = atlas_tex,
            .layer = layer,
            .textures = .{ .device = device, .queue = queue },
        };
    }

    fn describe(err: id) []const u8 {
        if (err == null) return "(no error object)";
        return objc.utf8(msg(id, err, "localizedDescription", .{}));
    }

    pub fn setDrawableSize(self: *Renderer, w_px: f64, h_px: f64, scale: f64) void {
        msg(void, self.layer, "setContentsScale:", .{scale});
        msg(void, self.layer, "setDrawableSize:", .{objc.CGSize{ .width = w_px, .height = h_px }});
    }

    fn uploadAtlas(self: *Renderer, text: *text_mod.TextEngine) void {
        if (!text.dirty) return;
        const y0 = text.dirty_y0;
        const y1 = @min(text.dirty_y1, text_mod.atlas_size);
        if (y1 > y0) {
            const region: MTLRegion = .{
                .origin = .{ .x = 0, .y = y0, .z = 0 },
                .size = .{ .width = text_mod.atlas_size, .height = y1 - y0, .depth = 1 },
            };
            msg(void, self.atlas_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                region,
                @as(NSUInteger, 0),
                @as(?*const anyopaque, text.pixels.ptr + @as(usize, y0) * text_mod.atlas_size),
                @as(NSUInteger, text_mod.atlas_size),
            });
        }
        text.dirty = false;
    }

    fn encode(self: *Renderer, cmd: id, target: id, w_px: f32, h_px: f32, dl: *draw.DrawList, clear: draw.Color) void {
        const rpd = msg(id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const att = msg(id, msg(id, rpd, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        msg(void, att, "setTexture:", .{target});
        msg(void, att, "setLoadAction:", .{MTLLoadActionClear});
        msg(void, att, "setStoreAction:", .{MTLStoreActionStore});
        msg(void, att, "setClearColor:", .{MTLClearColor{ .r = clear.r, .g = clear.g, .b = clear.b, .a = 1 }});

        const enc = msg(id, cmd, "renderCommandEncoderWithDescriptor:", .{rpd});
        const n = dl.instances.items.len;
        if (n > 0) {
            const bytes = std.mem.sliceAsBytes(dl.instances.items);
            const buf = msg(id, self.device, "newBufferWithBytes:length:options:", .{
                @as(?*const anyopaque, bytes.ptr),
                @as(NSUInteger, bytes.len),
                @as(NSUInteger, 0),
            });
            defer objc.release(buf);
            var uniforms: Uniforms = .{
                .viewport = .{ w_px, h_px },
                .atlas_size = .{ @floatFromInt(text_mod.atlas_size), @floatFromInt(text_mod.atlas_size) },
            };
            msg(void, enc, "setRenderPipelineState:", .{self.pipeline});
            msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buf, @as(NSUInteger, 0), @as(NSUInteger, 0) });
            msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buf, @as(NSUInteger, 0), @as(NSUInteger, 0) });
            msg(void, enc, "setVertexBytes:length:atIndex:", .{
                @as(?*const anyopaque, &uniforms),
                @as(NSUInteger, @sizeOf(Uniforms)),
                @as(NSUInteger, 1),
            });
            msg(void, enc, "setFragmentTexture:atIndex:", .{ self.atlas_tex, @as(NSUInteger, 0) });
            // Batches split only where a different image texture is needed;
            // a frame without images is still a single draw call. The atlas
            // stands in for slot 1 so the binding is never empty.
            for (dl.batches.items) |b| {
                if (b.count == 0) continue;
                msg(void, enc, "setFragmentTexture:atIndex:", .{ b.texture orelse self.atlas_tex, @as(NSUInteger, 1) });
                msg(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
                    MTLPrimitiveTypeTriangleStrip,
                    @as(NSUInteger, 0),
                    @as(NSUInteger, 4),
                    @as(NSUInteger, b.count),
                    @as(NSUInteger, b.first),
                });
            }
        }
        msg(void, enc, "endEncoding", .{});
    }

    /// Renders the draw list to the layer's next drawable.
    pub fn present(self: *Renderer, dl: *draw.DrawList, text: *text_mod.TextEngine, clear: draw.Color) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const drawable = msg(id, self.layer, "nextDrawable", .{});
        if (drawable == null) return;
        const target = msg(id, drawable, "texture", .{});
        const w: f32 = @floatFromInt(msg(NSUInteger, target, "width", .{}));
        const h: f32 = @floatFromInt(msg(NSUInteger, target, "height", .{}));

        self.uploadAtlas(text);
        const cmd = msg(id, self.queue, "commandBuffer", .{});
        self.encode(cmd, target, w, h, dl, clear);
        msg(void, cmd, "presentDrawable:", .{drawable});
        msg(void, cmd, "commit", .{});
    }

    /// Renders the draw list offscreen and writes a PNG (used by --snapshot).
    pub fn snapshot(self: *Renderer, dl: *draw.DrawList, text: *text_mod.TextEngine, clear: draw.Color, w_px: u32, h_px: u32, path: []const u8) !void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const desc = msg(id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            MTLPixelFormatBGRA8Unorm,
            @as(NSUInteger, w_px),
            @as(NSUInteger, h_px),
            false,
        });
        msg(void, desc, "setUsage:", .{@as(NSUInteger, 5)}); // shaderRead | renderTarget
        msg(void, desc, "setStorageMode:", .{@as(NSUInteger, 0)}); // shared
        const target = msg(id, self.device, "newTextureWithDescriptor:", .{desc});
        if (target == null) return error.SnapshotTextureFailed;
        defer objc.release(target);

        self.uploadAtlas(text);
        const cmd = msg(id, self.queue, "commandBuffer", .{});
        self.encode(cmd, target, @floatFromInt(w_px), @floatFromInt(h_px), dl, clear);
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});

        const stride: usize = @as(usize, w_px) * 4;
        const pixels = try std.heap.c_allocator.alloc(u8, stride * h_px);
        defer std.heap.c_allocator.free(pixels);
        const region: MTLRegion = .{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = w_px, .height = h_px, .depth = 1 },
        };
        msg(void, target, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(?*anyopaque, pixels.ptr),
            @as(NSUInteger, stride),
            region,
            @as(NSUInteger, 0),
        });

        const cs = apple.CGColorSpaceCreateWithName(apple.kCGColorSpaceSRGB);
        defer apple.CGColorSpaceRelease(cs);
        const provider = apple.CGDataProviderCreateWithData(null, pixels.ptr, pixels.len, null);
        defer apple.CGDataProviderRelease(provider);
        const image = apple.CGImageCreate(w_px, h_px, 8, 32, stride, cs, apple.kCGBitmapByteOrder32Little | apple.kCGImageAlphaNoneSkipFirst, provider, null, false, apple.kCGRenderingIntentDefault);
        if (image == null) return error.SnapshotImageFailed;
        defer apple.CGImageRelease(image);

        const url = apple.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false);
        if (url == null) return error.SnapshotUrlFailed;
        defer apple.CFRelease(url);
        const uti = apple.cfString("public.png");
        defer apple.CFRelease(uti);
        const dest = apple.CGImageDestinationCreateWithURL(url, uti, 1, null);
        if (dest == null) return error.SnapshotDestFailed;
        defer apple.CFRelease(dest);
        apple.CGImageDestinationAddImage(dest, image, null);
        if (!apple.CGImageDestinationFinalize(dest)) return error.SnapshotWriteFailed;
    }
};

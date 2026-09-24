//! Minimal Objective-C runtime bridge. Everything AppKit/Metal related goes
//! through `msg`, so there are no .m files anywhere in the project.
const std = @import("std");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const NSUInteger = c_ulong;
pub const NSInteger = c_long;
pub const CGFloat = f64;

pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct {
    origin: CGPoint = .{},
    size: CGSize = .{},

    pub fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    }
};
pub const NSRange = extern struct { location: NSUInteger = 0, length: NSUInteger = 0 };
pub const NSNotFound: NSUInteger = @as(NSUInteger, @bitCast(@as(c_long, std.math.maxInt(c_long))));

pub const ObjcSuper = extern struct { receiver: id, super_class: Class };

extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSendSuper() void;
pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn sel_getName(sel: SEL) [*:0]const u8;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
pub extern "c" fn class_addProtocol(cls: Class, protocol: ?*anyopaque) bool;
pub extern "c" fn class_getSuperclass(cls: Class) Class;
pub extern "c" fn object_getClass(obj: id) Class;
pub extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// Cached selector lookup; one static slot per distinct comptime name.
pub fn sel(comptime name: [:0]const u8) SEL {
    // The struct must capture `name`, otherwise every instantiation would
    // share one type (and therefore one cache slot).
    const S = struct {
        const key = name;
        var cached: SEL = null;
    };
    if (S.cached == null) S.cached = sel_registerName(name.ptr);
    return S.cached;
}

pub fn class(comptime name: [:0]const u8) Class {
    const S = struct {
        const key = name;
        var cached: Class = null;
    };
    if (S.cached == null) {
        S.cached = objc_getClass(name.ptr);
        if (S.cached == null) std.debug.panic("objc class not found: {s}", .{name});
    }
    return S.cached;
}

fn MsgFn(comptime Ret: type, comptime First: type, comptime Args: type) type {
    const f = @typeInfo(Args).@"struct".fields;
    inline for (f) |field| {
        if (field.type == comptime_int or field.type == comptime_float)
            @compileError("objc.msg: cast numeric literals to a concrete C type");
    }
    return switch (f.len) {
        0 => *const fn (First, SEL) callconv(.c) Ret,
        1 => *const fn (First, SEL, f[0].type) callconv(.c) Ret,
        2 => *const fn (First, SEL, f[0].type, f[1].type) callconv(.c) Ret,
        3 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type) callconv(.c) Ret,
        4 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type) callconv(.c) Ret,
        5 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type) callconv(.c) Ret,
        6 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type, f[5].type) callconv(.c) Ret,
        7 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type, f[5].type, f[6].type) callconv(.c) Ret,
        8 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type, f[5].type, f[6].type, f[7].type) callconv(.c) Ret,
        9 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type, f[5].type, f[6].type, f[7].type, f[8].type) callconv(.c) Ret,
        10 => *const fn (First, SEL, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type, f[5].type, f[6].type, f[7].type, f[8].type, f[9].type) callconv(.c) Ret,
        else => @compileError("objc.msg: too many arguments"),
    };
}

/// `[target selector:args...]`
pub fn msg(comptime Ret: type, target: id, comptime sel_name: [:0]const u8, args: anytype) Ret {
    const F = MsgFn(Ret, id, @TypeOf(args));
    const fp: F = @ptrCast(&objc_msgSend);
    return @call(.auto, fp, .{ target, sel(sel_name) } ++ args);
}

/// `[super selector:args...]` from inside a method of a runtime-registered class.
pub fn msgSuper(comptime Ret: type, self: id, super_class: Class, comptime sel_name: [:0]const u8, args: anytype) Ret {
    var sup: ObjcSuper = .{ .receiver = self, .super_class = super_class };
    const F = MsgFn(Ret, *ObjcSuper, @TypeOf(args));
    const fp: F = @ptrCast(&objc_msgSendSuper);
    return @call(.auto, fp, .{ &sup, sel(sel_name) } ++ args);
}

pub fn alloc(comptime class_name: [:0]const u8) id {
    return msg(id, class(class_name), "alloc", .{});
}

pub fn new(comptime class_name: [:0]const u8) id {
    return msg(id, msg(id, class(class_name), "alloc", .{}), "init", .{});
}

pub fn retain(obj: id) id {
    return msg(id, obj, "retain", .{});
}

pub fn release(obj: id) void {
    if (obj != null) msg(void, obj, "release", .{});
}

pub fn autorelease(obj: id) id {
    return msg(id, obj, "autorelease", .{});
}

/// Autoreleased NSString from a UTF-8 slice.
pub fn nsString(s: []const u8) id {
    const raw = msg(id, alloc("NSString"), "initWithBytes:length:encoding:", .{
        @as(?*const anyopaque, s.ptr),
        @as(NSUInteger, s.len),
        @as(NSUInteger, 4), // NSUTF8StringEncoding
    });
    return autorelease(raw);
}

/// Borrowed UTF-8 view of an NSString (valid while the string lives / pool drains).
pub fn utf8(ns_string: id) []const u8 {
    if (ns_string == null) return "";
    const p = msg(?[*:0]const u8, ns_string, "UTF8String", .{});
    if (p) |ptr| return std.mem.span(ptr);
    return "";
}

pub const AutoreleasePool = struct {
    token: ?*anyopaque,
    pub fn push() AutoreleasePool {
        return .{ .token = objc_autoreleasePoolPush() };
    }
    pub fn pop(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.token);
    }
};

// ── blocks ──────────────────────────────────────────────────────────────
// Objective-C blocks by their ABI (clang's "Block Implementation
// Specification"): an object whose `invoke` takes the block itself first,
// then the arguments. Blocks WebKit or AppKit hand us are called with
// `invokeBlock`; the ones we hand them are made with `Block.global`, which
// needs no copy/dispose helpers — copying a global block returns it as is.

pub const Block = extern struct {
    isa: ?*const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,

    /// A block that calls `func` (first parameter: the block, as `*Block`
    /// or a struct that starts with one). Put it in static storage, or in
    /// memory that outlives every call, as blocks of this kind are never
    /// copied to the heap.
    pub fn global(func: *const anyopaque, size: usize) Block {
        return .{ .isa = &_NSConcreteGlobalBlock, .flags = block_is_global, .invoke = func, .descriptor = descriptorFor(size) };
    }
};

pub const BlockDescriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };

const block_is_global: c_int = 1 << 28;
extern "c" var _NSConcreteGlobalBlock: anyopaque;
extern "c" fn _Block_copy(block: ?*const anyopaque) ?*anyopaque;
extern "c" fn _Block_release(block: ?*const anyopaque) void;

fn descriptorFor(size: usize) *const BlockDescriptor {
    // The sizes in use are few (a bare block, a block with a context
    // pointer); one descriptor each.
    const S = struct {
        var bare: BlockDescriptor = .{ .size = @sizeOf(Block) };
        var with_ctx: BlockDescriptor = .{ .size = @sizeOf(Block) + @sizeOf(usize) };
    };
    if (size == @sizeOf(Block)) return &S.bare;
    return &S.with_ctx;
}

/// Keeps a block that was passed in (it may live on the caller's stack)
/// for calling later; balance with `releaseBlock`.
pub fn copyBlock(block: ?*anyopaque) ?*anyopaque {
    if (block == null) return null;
    return _Block_copy(block);
}

pub fn releaseBlock(block: ?*anyopaque) void {
    if (block != null) _Block_release(block);
}

/// Calls a block with `args` (C types; `void` result).
pub fn invokeBlock(block: ?*anyopaque, args: anytype) void {
    const b: *Block = @ptrCast(@alignCast(block orelse return));
    const F = BlockFn(@TypeOf(args));
    const fp: F = @ptrCast(@alignCast(b.invoke));
    @call(.auto, fp, .{b} ++ args);
}

fn BlockFn(comptime Args: type) type {
    const f = @typeInfo(Args).@"struct".fields;
    inline for (f) |field| {
        if (field.type == comptime_int or field.type == comptime_float)
            @compileError("objc.invokeBlock: cast numeric literals to a concrete C type");
    }
    return switch (f.len) {
        0 => *const fn (*Block) callconv(.c) void,
        1 => *const fn (*Block, f[0].type) callconv(.c) void,
        2 => *const fn (*Block, f[0].type, f[1].type) callconv(.c) void,
        3 => *const fn (*Block, f[0].type, f[1].type, f[2].type) callconv(.c) void,
        else => @compileError("objc.invokeBlock: too many arguments"),
    };
}

/// Builder for runtime-registered classes.
pub const ClassBuilder = struct {
    cls: Class,

    pub fn begin(comptime name: [:0]const u8, comptime super_name: [:0]const u8) ClassBuilder {
        const cls = objc_allocateClassPair(class(super_name), name.ptr, 0);
        if (cls == null) std.debug.panic("failed to allocate objc class {s}", .{name});
        return .{ .cls = cls };
    }

    pub fn method(self: ClassBuilder, comptime sel_name: [:0]const u8, imp: anytype, types: [*:0]const u8) void {
        if (!class_addMethod(self.cls, sel(sel_name), @ptrCast(&imp), types))
            std.debug.panic("class_addMethod failed for {s}", .{sel_name});
    }

    pub fn protocol(self: ClassBuilder, comptime name: [:0]const u8) void {
        const p = objc_getProtocol(name.ptr);
        if (p != null) _ = class_addProtocol(self.cls, p);
    }

    pub fn register(self: ClassBuilder) Class {
        objc_registerClassPair(self.cls);
        return self.cls;
    }
};

test "blocks: a global block with a context is invoked with its arguments and survives a copy" {
    const Ctx = extern struct {
        base: Block,
        hits: *usize,
    };
    const S = struct {
        fn call(b: *Ctx, a: c_long, c: bool) callconv(.c) void {
            if (a == 7 and c) b.hits.* += 1;
        }
    };
    var hits: usize = 0;
    var blk: Ctx = .{ .base = Block.global(@ptrCast(&S.call), @sizeOf(Ctx)), .hits = &hits };
    invokeBlock(@ptrCast(&blk), .{ @as(c_long, 7), true });
    // Copying a global block hands back the block itself.
    const copied = copyBlock(@ptrCast(&blk));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&blk)), copied);
    invokeBlock(copied, .{ @as(c_long, 7), true });
    releaseBlock(copied);
    try std.testing.expectEqual(@as(usize, 2), hits);
}

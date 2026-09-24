//! The Mac's cameras and microphones, as Settings › Permissions shows them:
//! whether macOS lets tt use them (the privacy switch every app has), the
//! devices there are and which one is the system's default. Websites in
//! tabs pick among the devices themselves; this only reads (and asks macOS
//! for access when the user presses the button).
//!
//! A bare binary (zig-out/bin/tt) started from a terminal gets the
//! terminal's access, as macOS counts it; tt.app gets its own.
const std = @import("std");
const objc = @import("../objc.zig");

const id = objc.id;
const msg = objc.msg;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;

pub const Kind = enum { camera, microphone };

/// AVAuthorizationStatus.
pub const Access = enum {
    not_determined,
    restricted,
    denied,
    authorized,

    pub fn label(self: Access) []const u8 {
        return switch (self) {
            .not_determined => "Not asked yet",
            .restricted => "Restricted",
            .denied => "Off",
            .authorized => "Allowed",
        };
    }
};

/// AVMediaTypeVideo / AVMediaTypeAudio.
fn mediaType(kind: Kind) id {
    return objc.nsString(if (kind == .camera) "vide" else "soun");
}

pub fn access(kind: Kind) Access {
    const cls = objc.objc_getClass("AVCaptureDevice");
    if (cls == null) return .restricted;
    return switch (msg(NSInteger, cls, "authorizationStatusForMediaType:", .{mediaType(kind)})) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        else => .authorized,
    };
}

/// Has macOS ask the user (once per app); `access` shows the answer when
/// it comes.
pub fn requestAccess(kind: Kind) void {
    const cls = objc.objc_getClass("AVCaptureDevice");
    if (cls == null) return;
    const S = struct {
        var block: objc.Block = undefined;
        fn answered(_: *objc.Block, _: bool) callconv(.c) void {}
    };
    S.block = objc.Block.global(@ptrCast(&S.answered), @sizeOf(objc.Block));
    msg(void, cls, "requestAccessForMediaType:completionHandler:", .{ mediaType(kind), @as(?*anyopaque, &S.block) });
}

/// System Settings › Privacy & Security › Camera (or Microphone).
pub fn openPrivacySettings(kind: Kind) void {
    const url_text = if (kind == .camera)
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    else
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
    const url = msg(id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url_text)});
    if (url == null) return;
    _ = msg(bool, msg(id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{url});
}

/// One device, by the name macOS gives it.
pub const Device = struct {
    name: []u8,
    is_default: bool,
};

/// The devices of `kind` now, the default first. Free with `freeDevices`.
pub fn devices(gpa: std.mem.Allocator, kind: Kind) []Device {
    var out: std.ArrayList(Device) = .empty;
    const cls = objc.objc_getClass("AVCaptureDevice");
    if (cls == null) return out.toOwnedSlice(gpa) catch &.{};
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const default = msg(id, cls, "defaultDeviceWithMediaType:", .{mediaType(kind)});
    const default_id = if (default != null) objc.utf8(msg(id, default, "uniqueID", .{})) else "";
    const list = deviceList(kind);
    const n: usize = if (list != null) @intCast(msg(NSUInteger, list, "count", .{})) else 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dev = msg(id, list, "objectAtIndex:", .{@as(NSUInteger, i)});
        const name = gpa.dupe(u8, objc.utf8(msg(id, dev, "localizedName", .{}))) catch continue;
        const is_default = default_id.len > 0 and std.mem.eql(u8, objc.utf8(msg(id, dev, "uniqueID", .{})), default_id);
        const d: Device = .{ .name = name, .is_default = is_default };
        (if (is_default) out.insert(gpa, 0, d) else out.append(gpa, d)) catch gpa.free(name);
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

pub fn freeDevices(gpa: std.mem.Allocator, list: []Device) void {
    for (list) |d| gpa.free(d.name);
    gpa.free(list);
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// Every device of `kind` through a discovery session over the device
/// types this macOS has (their names are looked up, as older systems lack
/// some); the old class method when none of them is there.
fn deviceList(kind: Kind) id {
    const cls = objc.class("AVCaptureDevice");
    const names: []const [*:0]const u8 = if (kind == .camera)
        &.{ "AVCaptureDeviceTypeBuiltInWideAngleCamera", "AVCaptureDeviceTypeExternal", "AVCaptureDeviceTypeContinuityCamera", "AVCaptureDeviceTypeDeskViewCamera" }
    else
        &.{ "AVCaptureDeviceTypeMicrophone", "AVCaptureDeviceTypeBuiltInMicrophone", "AVCaptureDeviceTypeExternalUnknown" };
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const types = msg(id, objc.class("NSMutableArray"), "array", .{});
    for (names) |name| {
        const sym = dlsym(rtld_default, name) orelse continue;
        const value: *const id = @ptrCast(@alignCast(sym));
        if (value.* != null and !msg(bool, types, "containsObject:", .{value.*})) msg(void, types, "addObject:", .{value.*});
    }
    const disc = objc.objc_getClass("AVCaptureDeviceDiscoverySession");
    if (disc != null and msg(NSUInteger, types, "count", .{}) > 0) {
        // AVCaptureDevicePositionUnspecified = 0.
        const session = msg(id, disc, "discoverySessionWithDeviceTypes:mediaType:position:", .{ types, mediaType(kind), @as(NSInteger, 0) });
        if (session != null) return msg(id, session, "devices", .{});
    }
    return msg(id, cls, "devicesWithMediaType:", .{mediaType(kind)});
}

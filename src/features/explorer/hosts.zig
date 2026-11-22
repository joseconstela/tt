//! The effect the explorer feature is handed instead of reaching for it:
//! listing a folder (`Dirs`). `client/` goes through it and never imports
//! `sys.zig` itself, so a test hands it a stand-in that answers from
//! memory; the app hands it `system()`.
const std = @import("std");
const sys = @import("../../sys.zig");

/// One entry of a folder. The name is only valid during the call that
/// delivers it.
pub const Entry = struct { name: []const u8, is_dir: bool };

/// Where a listing delivers its entries, one call each.
pub const Sink = struct {
    ptr: *anyopaque,
    addFn: *const fn (ptr: *anyopaque, entry: Entry) void,

    pub fn add(self: Sink, entry: Entry) void {
        self.addFn(self.ptr, entry);
    }
};

/// Lists a folder: every entry but "." and "..", in no particular order.
/// A folder that cannot be read delivers nothing.
pub const Dirs = struct {
    ptr: *anyopaque,
    listFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, dir: []const u8, sink: Sink) void,

    pub fn list(self: Dirs, gpa: std.mem.Allocator, dir: []const u8, sink: Sink) void {
        self.listFn(self.ptr, gpa, dir, sink);
    }
};

var system_state: u8 = 0;

fn deliver(sink: Sink, e: sys.DirEntry) void {
    sink.add(.{ .name = e.name, .is_dir = e.is_dir });
}

fn systemList(_: *anyopaque, gpa: std.mem.Allocator, dir: []const u8, sink: Sink) void {
    sys.listDir(gpa, dir, sink, deliver);
}

/// The real disk (`sys.listDir`).
pub fn system() Dirs {
    return .{ .ptr = &system_state, .listFn = systemList };
}

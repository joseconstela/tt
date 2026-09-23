//! The app's part of a website tab's context menu, ahead of WebKit's own
//! items: what the app can do with the text selected in the page — put it
//! in a shell's input box, ask the agent about it, open or search it — and
//! with the link under the pointer. The selection and the link come from
//! the `selection` bridge (web_bridge.zig); what the entries do goes
//! through `Env` requests, which the app serves between ticks (tab.zig).
//!
//! Adding an entry: a tag in `Action`, its title in `build`, what it does
//! in `perform`. `build` is pure, so the entries are unit-tested; the
//! NSMenu glue in `fill` is the only part that needs a window.
const std = @import("std");
const objc = @import("../objc.zig");
const web_tab = @import("web_tab.zig");

const WebTab = web_tab.WebTab;
const id = objc.id;
const msg = objc.msg;
const NSInteger = objc.NSInteger;

pub const Action = enum(u8) {
    separator,
    /// The selection into the input box of a shell in the row on show; nothing runs.
    send_to_shell,
    /// The selection to the agent that takes plain-English lines, in such a shell.
    ask_agent,
    /// The selection as an address — or a web search — in a new website tab.
    open_selection,
    /// The link under the pointer in a new website tab.
    open_link,
};

pub const Entry = struct { action: Action, title: []const u8 };

/// How much of the selection a title quotes.
pub const preview_len = 24;

/// The entries for a selection and a link, either of which may be empty;
/// titles are allocated in `arena`. Empty when there is nothing to add.
pub fn build(out: *std.ArrayList(Entry), arena: std.mem.Allocator, selection: []const u8, link: []const u8) !void {
    const sel = std.mem.trim(u8, selection, " \t\r\n");
    if (sel.len > 0) {
        var buf: [128]u8 = undefined;
        const short = preview(sel, &buf);
        try out.append(arena, .{ .action = .send_to_shell, .title = "Send to Shell" });
        try out.append(arena, .{ .action = .ask_agent, .title = try std.fmt.allocPrint(arena, "Ask Agent About “{s}”", .{short}) });
        const open = if (web_tab.isAddress(sel))
            try std.fmt.allocPrint(arena, "Open “{s}” in New Tab", .{short})
        else
            try std.fmt.allocPrint(arena, "Search Web for “{s}”", .{short});
        try out.append(arena, .{ .action = .open_selection, .title = open });
    }
    if (link.len > 0) try out.append(arena, .{ .action = .open_link, .title = "Open Link in New Tab" });
    if (out.items.len > 0) try out.append(arena, .{ .action = .separator, .title = "" });
}

/// The selection on one line — whitespace runs become one space — cut to
/// `preview_len` characters with an ellipsis. `buf` needs 128 bytes.
pub fn preview(text: []const u8, buf: []u8) []const u8 {
    const ellipsis = "…";
    const view = std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, preview_len)];
    var it = view.iterator();
    var n: usize = 0;
    var chars: usize = 0;
    var pending_space = false;
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len == 1 and std.ascii.isWhitespace(cp[0])) {
            pending_space = n > 0;
            continue;
        }
        const need = cp.len + @as(usize, if (pending_space) 1 else 0);
        if (chars >= preview_len or n + need + ellipsis.len > buf.len) {
            @memcpy(buf[n .. n + ellipsis.len], ellipsis);
            return buf[0 .. n + ellipsis.len];
        }
        if (pending_space) {
            buf[n] = ' ';
            n += 1;
            pending_space = false;
        }
        @memcpy(buf[n .. n + cp.len], cp);
        n += cp.len;
        chars += 1;
    }
    return buf[0..n];
}

// ── the menu ────────────────────────────────────────────────────────────

/// WebKit's menu is about to open over `view`: the app's entries go in
/// front of its items. Each carries its action in its tag and targets the
/// web view, whose `ttMenuAction:` comes back to `perform`.
pub fn fill(tab: *WebTab, view: id, menu: id) void {
    var arena_state = std.heap.ArenaAllocator.init(tab.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    build(&entries, arena, tab.selection.items, tab.link_url.items) catch return;
    for (entries.items, 0..) |e, i| {
        const item = if (e.action == .separator) msg(id, objc.class("NSMenuItem"), "separatorItem", .{}) else blk: {
            const it = objc.autorelease(msg(id, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{
                objc.nsString(e.title), objc.sel("ttMenuAction:"), objc.nsString(""),
            }));
            msg(void, it, "setTarget:", .{view});
            msg(void, it, "setTag:", .{@as(NSInteger, @intFromEnum(e.action))});
            break :blk it;
        };
        msg(void, menu, "insertItem:atIndex:", .{ item, @as(NSInteger, @intCast(i)) });
    }
}

/// An entry was picked (`tag` is its `Action`). What it needs from the
/// rest of the app is queued on the tab's `Env`; the app serves it on the
/// next tick.
pub fn perform(tab: *WebTab, tag: NSInteger) void {
    if (tag < 0 or tag > @intFromEnum(Action.open_link)) return;
    const action: Action = @enumFromInt(tag);
    const sel = std.mem.trim(u8, tab.selection.items, " \t\r\n");
    switch (action) {
        .separator => {},
        .send_to_shell => if (sel.len > 0) tab.env.sendToShell(sel),
        .ask_agent => if (sel.len > 0) {
            var arena_state = std.heap.ArenaAllocator.init(tab.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var buf: [128]u8 = undefined;
            const host = web_tab.hostOf(tab.url.items);
            const label = std.fmt.allocPrint(arena, "# About “{s}” from {s}", .{ preview(sel, &buf), if (host.len > 0) host else "the web" }) catch return;
            const question = std.fmt.allocPrint(arena, "On the web page {s} the user selected this and wants it explained:\n\n{s}", .{ tab.url.items, sel }) catch return;
            tab.env.askAgent(label, question);
        },
        .open_selection => if (sel.len > 0) {
            const url = web_tab.resolve(tab.gpa, sel) catch return;
            defer tab.gpa.free(url);
            if (url.len > 0) tab.env.openUrl(url);
        },
        .open_link => if (tab.link_url.items.len > 0) tab.env.openUrl(tab.link_url.items),
    }
}

test "preview: one line, cut with an ellipsis" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("zig comptime", preview("  zig\n\tcomptime ", &buf));
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwx…", preview("abcdefghijklmnopqrstuvwxyz", &buf));
    try std.testing.expectEqualStrings("ñandú → ok", preview("ñandú   →\nok", &buf));
    try std.testing.expectEqualStrings("", preview("   ", &buf));
}

test "build: the entries for a selection, a link, both, nothing" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var none: std.ArrayList(Entry) = .empty;
    try build(&none, arena, "  \n", "");
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    var words: std.ArrayList(Entry) = .empty;
    try build(&words, arena, "zig comptime tricks", "");
    try std.testing.expectEqual(@as(usize, 4), words.items.len);
    try std.testing.expectEqual(Action.send_to_shell, words.items[0].action);
    try std.testing.expectEqualStrings("Ask Agent About “zig comptime tricks”", words.items[1].title);
    try std.testing.expectEqualStrings("Search Web for “zig comptime tricks”", words.items[2].title);
    try std.testing.expectEqual(Action.separator, words.items[3].action);

    var address: std.ArrayList(Entry) = .empty;
    try build(&address, arena, "ziglang.org/download", "");
    try std.testing.expectEqualStrings("Open “ziglang.org/download” in New Tab", address.items[2].title);

    var both: std.ArrayList(Entry) = .empty;
    try build(&both, arena, "x", "https://example.com/a");
    try std.testing.expectEqual(@as(usize, 5), both.items.len);
    try std.testing.expectEqual(Action.open_link, both.items[3].action);

    var link_only: std.ArrayList(Entry) = .empty;
    try build(&link_only, arena, "", "https://example.com/a");
    try std.testing.expectEqual(@as(usize, 2), link_only.items.len);
    try std.testing.expectEqualStrings("Open Link in New Tab", link_only.items[0].title);
}

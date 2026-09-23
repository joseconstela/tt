//! A project's or resource's icon of the user's choosing, kept as a short
//! string in ~/.tt_projects: either the name of a stroke icon ("folder")
//! or a colour ("#E5484D") drawn as a filled circle. Unknown strings draw
//! nothing, so a hand-edited file cannot break the sidebar.
const std = @import("std");
const draw = @import("../gfx/draw.zig");
const icons = @import("../gfx/icons.zig");

const Color = draw.Color;
const theme = @import("theme.zig");

pub const Spec = union(enum) { glyph: icons.Icon, color: Color };

/// The symbols the picker offers, in its order (chrome icons left out).
pub const glyphs = [_]icons.Icon{
    .folder, .terminal, .file, .document, .notebook, .image, .globe, .agent,
    .sparkle, .plug, .cloud, .drop, .sun, .lock, .bell, .search, .settings,
};

pub const NamedColor = struct { name: []const u8, color: Color };

/// The colours the picker offers; `name` is what the file keeps.
pub const colors = [_]NamedColor{
    .{ .name = "#E5484D", .color = Color.hex(0xE5484D) },
    .{ .name = "#F76B15", .color = Color.hex(0xF76B15) },
    .{ .name = "#F5B400", .color = Color.hex(0xF5B400) },
    .{ .name = "#30A46C", .color = Color.hex(0x30A46C) },
    .{ .name = "#12A594", .color = Color.hex(0x12A594) },
    .{ .name = "#3E86F5", .color = Color.hex(0x3E86F5) },
    .{ .name = "#6E56CF", .color = Color.hex(0x6E56CF) },
    .{ .name = "#E93D82", .color = Color.hex(0xE93D82) },
    .{ .name = "#AD7F58", .color = Color.hex(0xAD7F58) },
    .{ .name = "#8B8D98", .color = Color.hex(0x8B8D98) },
};

/// The picker's choices, symbols first: what row `i` of it stands for.
pub const count = glyphs.len + colors.len;

pub fn nameAt(i: usize) []const u8 {
    return if (i < glyphs.len) @tagName(glyphs[i]) else colors[i - glyphs.len].name;
}

pub fn specAt(i: usize) Spec {
    return if (i < glyphs.len) .{ .glyph = glyphs[i] } else .{ .color = colors[i - glyphs.len].color };
}

/// The picker row whose name is `name`, if any.
pub fn indexOf(name: ?[]const u8) ?usize {
    const n = name orelse return null;
    for (0..count) |i| {
        if (std.mem.eql(u8, nameAt(i), n)) return i;
    }
    return null;
}

/// What a stored string means; null for nothing set or nothing drawable.
pub fn parse(name: ?[]const u8) ?Spec {
    const n = name orelse return null;
    if (n.len == 7 and n[0] == '#') {
        const rgb = std.fmt.parseInt(u24, n[1..], 16) catch return null;
        return .{ .color = Color.fromRgb8(@intCast(rgb >> 16), @intCast((rgb >> 8) & 0xff), @intCast(rgb & 0xff)) };
    }
    const g = std.meta.stringToEnum(icons.Icon, n) orelse return null;
    return .{ .glyph = g };
}

/// Draws `spec` in a `size`-point box whose left edge is `x`, centred on
/// `cy`; a symbol in `color`, a colour as its own filled circle.
pub fn drawSpec(dl: *draw.DrawList, spec: Spec, x: f32, cy: f32, size: f32, color: Color) void {
    switch (spec) {
        .glyph => |g| dl.icon(g, x, cy - size / 2, size, color),
        // On e-ink the colour is shown as ink (a light one would vanish on white).
        .color => |c| dl.circle(x + size / 2, cy, size * 0.36, theme.ink(c, .fg)),
    }
}

test "icon spec: names round trip and bad strings draw nothing" {
    try std.testing.expect(parse("folder").? == .glyph);
    try std.testing.expect(parse("#E5484D").? == .color);
    try std.testing.expect(parse("#12345") == null);
    try std.testing.expect(parse("#GGGGGG") == null);
    try std.testing.expect(parse("no-such-icon") == null);
    try std.testing.expect(parse(null) == null);
    try std.testing.expectEqual(@as(?usize, 0), indexOf("folder"));
    try std.testing.expectEqual(@as(?usize, glyphs.len), indexOf("#E5484D"));
    try std.testing.expectEqual(@as(?usize, null), indexOf("#000000"));
    for (0..count) |i| try std.testing.expect(parse(nameAt(i)) != null);
}

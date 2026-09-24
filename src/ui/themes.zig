//! The classic terminal colour schemes, as terminalcolors.com publishes
//! them (its Ghostty exports: background, foreground, cursor, selection and
//! the 16 ANSI colours, plus the accent the site shows for each variant).
//! The values are copied exactly; `theme.zig` derives the rest of the
//! workspace (sidebar, lines, secondary text, …) from the background and
//! foreground, so a theme's own colours are what the terminal, the editors
//! and the syntax colours use. Most traditional first within each kind.
//! Pure data, so the config can name them: Settings › Style lists them
//! beside the modes, and the config remembers one by `id`.
const std = @import("std");

pub const Kind = enum { dark, light };

pub const Theme = struct {
    /// How the config file names it.
    id: []const u8,
    name: []const u8,
    kind: Kind,
    background: u24,
    foreground: u24,
    cursor: u24,
    cursor_text: u24,
    selection: u24,
    selection_text: u24,
    /// The colour the site shows the variant with.
    accent: u24,
    ansi: [16]u24,
};

/// The index in `all` of the theme the config calls `id`, if it is one.
pub fn find(id: []const u8) ?usize {
    for (all, 0..) |t, i| {
        if (std.ascii.eqlIgnoreCase(t.id, id)) return i;
    }
    return null;
}

/// The themes of one kind, in list order.
pub fn ofKind(kind: Kind) []const Theme {
    const first_light = comptime blk: {
        var i: usize = 0;
        while (all[i].kind == .dark) i += 1;
        break :blk i;
    };
    return if (kind == .dark) all[0..first_light] else all[first_light..];
}

/// Dark themes first, then light ones (`ofKind` relies on it).
pub const all = [_]Theme{
    .{ .id = "solarized-dark", .name = "Solarized Dark", .kind = .dark, .background = 0x002B36, .foreground = 0x839496, .cursor = 0x839496, .cursor_text = 0x002B36, .selection = 0x073642, .selection_text = 0x93A1A1, .accent = 0xB58900, .ansi = .{
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    } },
    .{ .id = "tomorrow-night", .name = "Tomorrow Night", .kind = .dark, .background = 0x1D1F21, .foreground = 0xC5C8C6, .cursor = 0xC5C8C6, .cursor_text = 0x1D1F21, .selection = 0x373B41, .selection_text = 0xC5C8C6, .accent = 0xF0C674, .ansi = .{
        0x000000, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF,
        0x000000, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF,
    } },
    .{ .id = "tomorrow-night-eighties", .name = "Tomorrow Night Eighties", .kind = .dark, .background = 0x2D2D2D, .foreground = 0xCCCCCC, .cursor = 0xCCCCCC, .cursor_text = 0x2D2D2D, .selection = 0x515151, .selection_text = 0xCCCCCC, .accent = 0xFFCC66, .ansi = .{
        0x000000, 0xF2777A, 0x99CC99, 0xFFCC66, 0x6699CC, 0xCC99CC, 0x66CCCC, 0xFFFFFF,
        0x000000, 0xF2777A, 0x99CC99, 0xFFCC66, 0x6699CC, 0xCC99CC, 0x66CCCC, 0xFFFFFF,
    } },
    .{ .id = "gruvbox-dark", .name = "Gruvbox Dark", .kind = .dark, .background = 0x282828, .foreground = 0xEBDBB2, .cursor = 0xEBDBB2, .cursor_text = 0x282828, .selection = 0xEBDBB2, .selection_text = 0x282828, .accent = 0xD65D0E, .ansi = .{
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    } },
    .{ .id = "dracula", .name = "Dracula", .kind = .dark, .background = 0x282A36, .foreground = 0xF8F8F2, .cursor = 0xF8F8F2, .cursor_text = 0x282A36, .selection = 0x44475A, .selection_text = 0xF8F8F2, .accent = 0xFF79C6, .ansi = .{
        0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
        0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    } },
    .{ .id = "nord", .name = "Nord", .kind = .dark, .background = 0x2E3440, .foreground = 0xD8DEE9, .cursor = 0xD8DEE9, .cursor_text = 0x2E3440, .selection = 0x3F4758, .selection_text = 0xD8DEE9, .accent = 0x88C0D0, .ansi = .{
        0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
        0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
    } },
    .{ .id = "one-dark", .name = "One Dark", .kind = .dark, .background = 0x282C34, .foreground = 0xABB2BF, .cursor = 0xABB2BF, .cursor_text = 0x282C34, .selection = 0xABB2BF, .selection_text = 0x282C34, .accent = 0x61AFEF, .ansi = .{
        0x1E2127, 0xE06C75, 0x98C379, 0xD19A66, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
        0x5C6370, 0xE06C75, 0x98C379, 0xD19A66, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
    } },
    .{ .id = "jellybeans", .name = "Jellybeans", .kind = .dark, .background = 0x121212, .foreground = 0xDEDEDE, .cursor = 0xFFA560, .cursor_text = 0xFFFFFF, .selection = 0x474E91, .selection_text = 0xF4F4F4, .accent = 0xFFBA7B, .ansi = .{
        0x929292, 0xE27373, 0x94B979, 0xFFBA7B, 0x97BEDC, 0xE1C0FA, 0x00988E, 0xDEDEDE,
        0xBDBDBD, 0xFFA1A1, 0xBDDEAB, 0xFFDCA0, 0xB1D8F6, 0xFBDAFF, 0x1AB2A8, 0xFFFFFF,
    } },
    .{ .id = "night-owl", .name = "Night Owl", .kind = .dark, .background = 0x011627, .foreground = 0xCCCCCC, .cursor = 0xCCCCCC, .cursor_text = 0x011627, .selection = 0x093B5E, .selection_text = 0xCCCCCC, .accent = 0x5F7E97, .ansi = .{
        0x011627, 0xEF5350, 0x22DA6E, 0xC5E478, 0x82AAFF, 0xC792EA, 0x21C7A8, 0xFFFFFF,
        0x575656, 0xEF5350, 0x22DA6E, 0xFFEB95, 0x82AAFF, 0xC792EA, 0x7FDBCA, 0xFFFFFF,
    } },
    .{ .id = "ayu-dark", .name = "Ayu Dark", .kind = .dark, .background = 0x0B0E14, .foreground = 0xBFBDB6, .cursor = 0xBFBDB6, .cursor_text = 0x0B0E14, .selection = 0x1B3A5B, .selection_text = 0xBFBDB6, .accent = 0xE6B450, .ansi = .{
        0x1E232B, 0xEA6C73, 0x7FD962, 0xF9AF4F, 0x53BDFA, 0xCDA1FA, 0x90E1C6, 0xC7C7C7,
        0x686868, 0xF07178, 0xAAD94C, 0xFFB454, 0x59C2FF, 0xD2A6FF, 0x95E6CB, 0xFFFFFF,
    } },
    .{ .id = "ayu-mirage", .name = "Ayu Mirage", .kind = .dark, .background = 0x1F2430, .foreground = 0xCCCAC2, .cursor = 0xCCCAC2, .cursor_text = 0x1F2430, .selection = 0x274364, .selection_text = 0xCCCAC2, .accent = 0xFFCC66, .ansi = .{
        0x171B24, 0xED8274, 0x87D96C, 0xFACC6E, 0x6DCBFA, 0xDABAFA, 0x90E1C6, 0xC7C7C7,
        0x686868, 0xF28779, 0xD5FF80, 0xFFD173, 0x73D0FF, 0xDFBFFF, 0x95E6CB, 0xFFFFFF,
    } },
    .{ .id = "tokyo-night", .name = "Tokyo Night", .kind = .dark, .background = 0x1A1B26, .foreground = 0xC0CAF5, .cursor = 0xC0CAF5, .cursor_text = 0x1A1B26, .selection = 0x283457, .selection_text = 0xC0CAF5, .accent = 0x7AA2F7, .ansi = .{
        0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
        0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
    } },
    .{ .id = "catppuccin-mocha", .name = "Catppuccin Mocha", .kind = .dark, .background = 0x1E1E2E, .foreground = 0xCDD6F4, .cursor = 0xF5E0DC, .cursor_text = 0x11111B, .selection = 0x353748, .selection_text = 0xCDD6F4, .accent = 0xB4BEFE, .ansi = .{
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
    } },
    .{ .id = "rose-pine", .name = "Rosé Pine", .kind = .dark, .background = 0x1F1D2E, .foreground = 0xE0DEF4, .cursor = 0xE0DEF4, .cursor_text = 0x1F1D2E, .selection = 0x2F2C40, .selection_text = 0xE0DEF4, .accent = 0xE0DEF4, .ansi = .{
        0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        0x908CAA, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
    } },
    .{ .id = "kanagawa-wave", .name = "Kanagawa Wave", .kind = .dark, .background = 0x1F1F28, .foreground = 0xDCD7BA, .cursor = 0xDCD7BA, .cursor_text = 0x1F1F28, .selection = 0x2D4F67, .selection_text = 0xC8C093, .accent = 0xDCD7BA, .ansi = .{
        0x16161D, 0xC34043, 0x76946A, 0xC0A36E, 0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
        0x727169, 0xE82424, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA,
    } },
    .{ .id = "everforest-dark", .name = "Everforest Dark", .kind = .dark, .background = 0x2D353B, .foreground = 0xD3C6AA, .cursor = 0xD3C6AA, .cursor_text = 0x2D353B, .selection = 0x414B51, .selection_text = 0xD3C6AA, .accent = 0x83C092, .ansi = .{
        0x343F44, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
        0x859289, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
    } },
    .{ .id = "github-dark", .name = "GitHub Dark", .kind = .dark, .background = 0x010409, .foreground = 0xE6EDF3, .cursor = 0xE6EDF3, .cursor_text = 0x010409, .selection = 0x264F78, .selection_text = 0xE6EDF3, .accent = 0xF78166, .ansi = .{
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
    } },
    .{ .id = "solarized-light", .name = "Solarized Light", .kind = .light, .background = 0xFDF6E3, .foreground = 0x657B83, .cursor = 0x657B83, .cursor_text = 0xFDF6E3, .selection = 0xEEE8D5, .selection_text = 0x586E75, .accent = 0x2AA198, .ansi = .{
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    } },
    .{ .id = "tomorrow", .name = "Tomorrow", .kind = .light, .background = 0xFFFFFF, .foreground = 0x4D4D4C, .cursor = 0x4D4D4C, .cursor_text = 0xFFFFFF, .selection = 0xD6D6D6, .selection_text = 0x4D4D4C, .accent = 0xEAB700, .ansi = .{
        0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF,
        0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF,
    } },
    .{ .id = "gruvbox-light", .name = "Gruvbox Light", .kind = .light, .background = 0xFBF1C7, .foreground = 0x3C3836, .cursor = 0x3C3836, .cursor_text = 0xFBF1C7, .selection = 0x3C3836, .selection_text = 0xFBF1C7, .accent = 0xD65D0E, .ansi = .{
        0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
        0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
    } },
    .{ .id = "one-light", .name = "One Light", .kind = .light, .background = 0xF8F8F8, .foreground = 0x2A2B33, .cursor = 0x2A2B33, .cursor_text = 0xF8F8F8, .selection = 0x2A2B33, .selection_text = 0xF8F8F8, .accent = 0x2F5AF3, .ansi = .{
        0x000000, 0xDE3D35, 0x3E953A, 0xD2B67B, 0x2F5AF3, 0xA00095, 0x3E953A, 0xBBBBBB,
        0x000000, 0xDE3D35, 0x3E953A, 0xD2B67B, 0x2F5AF3, 0xA00095, 0x3E953A, 0xFFFFFF,
    } },
    .{ .id = "night-owl-light", .name = "Night Owl Light", .kind = .light, .background = 0xF6F6F6, .foreground = 0x403F53, .cursor = 0x403F53, .cursor_text = 0xF6F6F6, .selection = 0xE0E0E0, .selection_text = 0x403F53, .accent = 0x2AA298, .ansi = .{
        0x403F53, 0xDE3D3B, 0x08916A, 0xE0AF02, 0x288ED7, 0xD6438A, 0x2AA298, 0x93A1A1,
        0x403F53, 0xDE3D3B, 0x08916A, 0xDAAA01, 0x288ED7, 0xD6438A, 0x2AA298, 0x93A1A1,
    } },
    .{ .id = "ayu-light", .name = "Ayu Light", .kind = .light, .background = 0xF8F9FA, .foreground = 0x5C6166, .cursor = 0x5C6166, .cursor_text = 0xF8F9FA, .selection = 0xD3E1F5, .selection_text = 0x5C6166, .accent = 0xFFAA33, .ansi = .{
        0x000000, 0xEA6C6D, 0x6CBF43, 0xECA944, 0x3199E1, 0x9E75C7, 0x46BA94, 0xC7C7C7,
        0x686868, 0xF07171, 0x86B300, 0xF2AE49, 0x399EE6, 0xA37ACC, 0x4CBF99, 0xD1D1D1,
    } },
    .{ .id = "tokyo-night-day", .name = "Tokyo Night Day", .kind = .light, .background = 0xE1E2E7, .foreground = 0x3760BF, .cursor = 0x3760BF, .cursor_text = 0xE1E2E7, .selection = 0xB7C1E3, .selection_text = 0x3760BF, .accent = 0x2E7DE9, .ansi = .{
        0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
        0xA1A6C5, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x3760BF,
    } },
    .{ .id = "catppuccin-latte", .name = "Catppuccin Latte", .kind = .light, .background = 0xEFF1F5, .foreground = 0x4C4F69, .cursor = 0xDC8A78, .cursor_text = 0xEFF1F5, .selection = 0xD8DAE1, .selection_text = 0x4C4F69, .accent = 0x7287FD, .ansi = .{
        0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
        0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D, 0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC,
    } },
    .{ .id = "rose-pine-dawn", .name = "Rosé Pine Dawn", .kind = .light, .background = 0xFFFAF3, .foreground = 0x575279, .cursor = 0x575279, .cursor_text = 0xFFFAF3, .selection = 0xF3EEEA, .selection_text = 0x575279, .accent = 0x575279, .ansi = .{
        0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
        0x797593, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
    } },
    .{ .id = "everforest-light", .name = "Everforest Light", .kind = .light, .background = 0xFDF6E3, .foreground = 0x5C6A72, .cursor = 0x5C6A72, .cursor_text = 0xFDF6E3, .selection = 0xEFE9D5, .selection_text = 0x5C6A72, .accent = 0x35A77C, .ansi = .{
        0x5C6A72, 0xF85552, 0x8DA101, 0xDFA000, 0x3A94C5, 0xDF69BA, 0x35A77C, 0x939F91,
        0x5C6A72, 0xF85552, 0x8DA101, 0xDFA000, 0x3A94C5, 0xDF69BA, 0x35A77C, 0xF4F0D9,
    } },
};

comptime {
    // `ofKind` splits the list where the light themes start.
    var seen_light = false;
    for (all) |t| {
        if (t.kind == .light) seen_light = true else if (seen_light) @compileError("dark theme after a light one: " ++ t.id);
    }
}

test "themes: exact colours from terminalcolors.com and a lookup by id" {
    const d = all[find("Dracula").?];
    try std.testing.expectEqual(@as(u24, 0x282A36), d.background);
    try std.testing.expectEqual(@as(u24, 0xBD93F9), d.ansi[4]);
    try std.testing.expect(find("tt") == null);
    try std.testing.expectEqual(@as(usize, 17), ofKind(.dark).len);
    try std.testing.expectEqual(@as(usize, 10), ofKind(.light).len);
}

//! Design tokens from the "1b · Workspace, calm" artboard. The colours are
//! variables: the artboard's dark set is the default and `setScheme` swaps
//! in a light counterpart of the same warm paper tones (Settings › Mode,
//! or macOS when the mode is "system"), or the e-ink set: ink on paper for
//! e-paper panels, which also turns off what those cannot show well (see
//! `eink_palette`). Metrics and the type ramp never change. The accent is
//! the one tweakable prop the design exposes; the config remembers it by
//! name or as a custom colour. Instead of the design's own dark or light
//! palette a classic terminal theme can be in force (`themes.zig`): its
//! exact colours replace the design's, its kind is the scheme.
const draw = @import("../gfx/draw.zig");
const themes = @import("themes.zig");
const Color = draw.Color;
const Font = draw.Font;

pub const Scheme = enum { dark, light, eink, eink_color };

/// Everything that differs between the dark and the light scheme.
pub const Palette = struct {
    bg: Color,
    bg_side: Color,
    bg_block: Color,
    bg_inset: Color,
    line: Color,
    line_strong: Color,
    bg_panel: Color,
    bg_panel_footer: Color,
    chip_active: Color,
    scrim: Color,
    text: Color,
    text_2: Color,
    text_3: Color,
    on_accent: Color,
    teal: Color,
    red: Color,
    red_line: Color,
    hover: Color,
    pressed: Color,
    /// The row the keyboard is on in a menu or grid: the hover tint, except
    /// on e-ink where hover is off but the choice still has to show.
    highlight: Color,
    /// The quiet tint under the caret's line in the code editor.
    line_highlight: Color,
    /// Border around blocks and cards: 0 where a background tint tells them
    /// apart, 1 on e-ink where it cannot.
    block_border: f32,
    /// Whether carets blink. Not on e-ink, where every change is a refresh.
    caret_blinks: bool,
    /// Soft ring shadows under floating panels; else a solid offset block.
    soft_shadow: bool,
    /// The accent options of the design, tuned per scheme (same names).
    accents: [4]Color,
    /// What Settings and the palette call each accent option.
    accent_labels: [4][]const u8 = design_accent_labels,
    /// 16-colour ANSI palette tuned to sit calmly on the block background.
    ansi: [16]Color,
    /// The terminal's cursor, and the glyph under a block cursor.
    cursor: Color,
    cursor_text: Color,
    /// Program output in the scheme's default colour (not bold).
    term_fg: Color,
    /// A theme's own selection colour (opaque); null = the accent, washed.
    sel: ?Color = null,
};

const design_accent_labels = [4][]const u8{ "Amber", "Peach", "Lime", "Rose" };

pub const dark_palette: Palette = .{
    .bg = Color.hex(0x1A1917),
    .bg_side = Color.hex(0x141312),
    .bg_block = Color.hex(0x211F1C),
    .bg_inset = Color.hex(0x141312),
    .line = Color.hex(0x2A2824),
    .line_strong = Color.hex(0x3A3731),
    // Floating panels ("Command palette" artboard).
    .bg_panel = Color.hex(0x1E1D1A),
    .bg_panel_footer = Color.hex(0x171614),
    .chip_active = Color.hex(0x282622),
    .scrim = Color.hex(0x11100E).alpha(0.6),
    .text = Color.hex(0xECE7DC),
    .text_2 = Color.hex(0xB9B2A4),
    .text_3 = Color.hex(0x958F83),
    .on_accent = Color.hex(0x141312),
    .teal = Color.hex(0x62CDB5),
    .red = Color.hex(0xF08A7B),
    .red_line = Color.hex(0x6B3F38),
    .hover = Color.hex(0xECE7DC).alpha(0.055),
    .pressed = Color.hex(0xECE7DC).alpha(0.09),
    .highlight = Color.hex(0xECE7DC).alpha(0.055),
    .line_highlight = Color.hex(0xECE7DC).alpha(0.03),
    .block_border = 0,
    .caret_blinks = true,
    .soft_shadow = true,
    .accents = .{ Color.hex(0xE9B44C), Color.hex(0xF0A060), Color.hex(0xC8D46A), Color.hex(0xEBA0B8) },
    .ansi = .{
        Color.hex(0x3A3731), Color.hex(0xF08A7B), Color.hex(0x9BD18B), Color.hex(0xE3C078),
        Color.hex(0x7FB4E8), Color.hex(0xD6A0E0), Color.hex(0x62CDB5), Color.hex(0xB9B2A4),
        Color.hex(0x958F83), Color.hex(0xFF9F91), Color.hex(0xB4E3A5), Color.hex(0xF5CE7A),
        Color.hex(0xA3CCF5), Color.hex(0xE6BDEE), Color.hex(0x8EE0CC), Color.hex(0xECE7DC),
    },
    .cursor = Color.hex(0xECE7DC),
    .cursor_text = Color.hex(0x1A1917),
    .term_fg = Color.hex(0xB9B2A4),
};

/// The same warm paper, lit: the dark set's greys inverted around the
/// artboard's cream, accents and ANSI colours darkened to keep contrast.
pub const light_palette: Palette = .{
    .bg = Color.hex(0xF6F3EC),
    .bg_side = Color.hex(0xEEEAE1),
    .bg_block = Color.hex(0xFCFAF6),
    .bg_inset = Color.hex(0xECE8DF),
    .line = Color.hex(0xE3DED3),
    .line_strong = Color.hex(0xCDC6B8),
    .bg_panel = Color.hex(0xFBF9F4),
    .bg_panel_footer = Color.hex(0xF0ECE4),
    .chip_active = Color.hex(0xE6E1D6),
    .scrim = Color.hex(0x3A3731).alpha(0.35),
    .text = Color.hex(0x2A2724),
    .text_2 = Color.hex(0x5C574F),
    .text_3 = Color.hex(0x8A8477),
    .on_accent = Color.hex(0x1A1917),
    .teal = Color.hex(0x1E9C84),
    .red = Color.hex(0xC9503F),
    .red_line = Color.hex(0xE5B0A7),
    .hover = Color.hex(0x1A1917).alpha(0.06),
    .pressed = Color.hex(0x1A1917).alpha(0.10),
    .highlight = Color.hex(0x1A1917).alpha(0.06),
    .line_highlight = Color.hex(0x2A2724).alpha(0.03),
    .block_border = 0,
    .caret_blinks = true,
    .soft_shadow = true,
    .accents = .{ Color.hex(0xC28E1C), Color.hex(0xD4772E), Color.hex(0x7E9A1A), Color.hex(0xCC6A8E) },
    .ansi = .{
        Color.hex(0x2A2724), Color.hex(0xC0392B), Color.hex(0x3E8E41), Color.hex(0xA67C0F),
        Color.hex(0x2E6FBF), Color.hex(0x9B4DAD), Color.hex(0x1E8F7C), Color.hex(0x8A8477),
        Color.hex(0x6F695F), Color.hex(0xD9534F), Color.hex(0x4CA34E), Color.hex(0xBF8F1A),
        Color.hex(0x3B7FD4), Color.hex(0xB060C4), Color.hex(0x24A28E), Color.hex(0xA39C8E),
    },
    .cursor = Color.hex(0x2A2724),
    .cursor_text = Color.hex(0xF6F3EC),
    .term_fg = Color.hex(0x5C574F),
};

/// Ink on paper, for e-ink panels. Pure white, pure black, and a few greys
/// on the 16-level steps such panels can show (0x22 apart at least), none
/// lighter than 0x88 for anything that has to be read. No colour: the
/// accent is black whatever the config says, ANSI colours are a grey ramp
/// where the brighter the colour was meant to be, the blacker the ink, and
/// `ink` does the same to the 256/true colours programs pick themselves.
/// Nothing translucent that would dither, and no tint-only distinctions:
/// blocks and cards get a border. What a panel cannot show without a
/// refresh is off too: hover feedback, the blinking caret, the soft
/// shadows (panels throw a solid offset block instead) and the scrim.
pub const eink_palette: Palette = .{
    .bg = Color.hex(0xFFFFFF),
    .bg_side = Color.hex(0xFFFFFF),
    .bg_block = Color.hex(0xFFFFFF),
    .bg_inset = Color.hex(0xF2F2F2),
    .line = Color.hex(0x777777),
    .line_strong = Color.hex(0x000000),
    .bg_panel = Color.hex(0xFFFFFF),
    .bg_panel_footer = Color.hex(0xF2F2F2),
    .chip_active = Color.hex(0xE6E6E6),
    .scrim = Color.transparent,
    .text = Color.hex(0x000000),
    .text_2 = Color.hex(0x333333),
    .text_3 = Color.hex(0x666666),
    .on_accent = Color.hex(0xFFFFFF),
    .teal = Color.hex(0x555555),
    .red = Color.hex(0x000000),
    .red_line = Color.hex(0x000000),
    .hover = Color.transparent,
    .pressed = Color.hex(0x000000).alpha(0.18),
    .highlight = Color.hex(0x000000).alpha(0.10),
    .line_highlight = Color.transparent,
    .block_border = 1,
    .caret_blinks = false,
    .soft_shadow = false,
    .accents = .{ Color.hex(0x000000), Color.hex(0x000000), Color.hex(0x000000), Color.hex(0x000000) },
    .ansi = .{
        Color.hex(0x000000), Color.hex(0x000000), Color.hex(0x333333), Color.hex(0x555555),
        Color.hex(0x222222), Color.hex(0x444444), Color.hex(0x666666), Color.hex(0x777777),
        Color.hex(0x888888), Color.hex(0x000000), Color.hex(0x222222), Color.hex(0x444444),
        Color.hex(0x000000), Color.hex(0x333333), Color.hex(0x555555), Color.hex(0x000000),
    },
    .cursor = Color.hex(0x000000),
    .cursor_text = Color.hex(0xFFFFFF),
    .term_fg = Color.hex(0x333333),
};

/// Muted colour on paper, for the colour e-paper panels (Kaleido and the
/// like). The same paper discipline as `eink_palette` — white grounds, ink
/// text, borders instead of tint-only separators, and none of what a panel
/// cannot refresh cleanly: no hover, no blinking caret, no soft shadows, no
/// scrim — but colour is kept. Such panels show only low-saturation colour,
/// so the accents, teal, red and ANSI ramp are desaturated mid-tones that
/// read on white without looking like a backlit screen. The accent is NOT
/// forced to black (that stays an `eink`-only rule), and `ink` leaves a
/// program's own 256/true colours alone, since the panel can carry them.
pub const eink_color_palette: Palette = .{
    .bg = Color.hex(0xFFFFFF),
    .bg_side = Color.hex(0xFFFFFF),
    .bg_block = Color.hex(0xFFFFFF),
    .bg_inset = Color.hex(0xF1F0ED),
    .line = Color.hex(0x8A8A8A),
    .line_strong = Color.hex(0x2A2724),
    .bg_panel = Color.hex(0xFFFFFF),
    .bg_panel_footer = Color.hex(0xF1F0ED),
    .chip_active = Color.hex(0xEAE6DC),
    .scrim = Color.transparent,
    .text = Color.hex(0x1A1917),
    .text_2 = Color.hex(0x4A463F),
    .text_3 = Color.hex(0x767065),
    .on_accent = Color.hex(0xFFFFFF),
    .teal = Color.hex(0x2E8474),
    .red = Color.hex(0xB0483C),
    .red_line = Color.hex(0xCFA59D),
    .hover = Color.transparent,
    .pressed = Color.hex(0x000000).alpha(0.16),
    .highlight = Color.hex(0x000000).alpha(0.10),
    .line_highlight = Color.transparent,
    .block_border = 1,
    .caret_blinks = false,
    .soft_shadow = false,
    .accents = .{ Color.hex(0xA9853A), Color.hex(0xB57A50), Color.hex(0x7E8B44), Color.hex(0xAE6E82) },
    .ansi = .{
        Color.hex(0x2A2724), Color.hex(0xA9483E), Color.hex(0x4E8250), Color.hex(0x93791F),
        Color.hex(0x4A6E9E), Color.hex(0x8C5B96), Color.hex(0x3C8478), Color.hex(0x8A8477),
        Color.hex(0x6F695F), Color.hex(0xB86058), Color.hex(0x5E9460), Color.hex(0xA5852F),
        Color.hex(0x5C7EA8), Color.hex(0x9A6EA2), Color.hex(0x4E9184), Color.hex(0x2A2724),
    },
    .cursor = Color.hex(0x1A1917),
    .cursor_text = Color.hex(0xFFFFFF),
    .term_fg = Color.hex(0x4A463F),
};

pub var scheme: Scheme = .dark;
/// Bumped whenever the tokens change, so the window can follow a theme
/// switch that keeps the scheme (see `cocoa.zig`).
pub var generation: u32 = 0;
/// The terminal theme (`themes.zig`) in force, whose kind is `scheme`;
/// null = the design's own palette for the scheme.
pub var active_theme: ?*const themes.Theme = null;
/// The palette derived from the theme in force.
var theme_palette: Palette = undefined;

pub var bg = dark_palette.bg;
pub var bg_side = dark_palette.bg_side;
pub var bg_block = dark_palette.bg_block;
pub var bg_inset = dark_palette.bg_inset;
pub var line = dark_palette.line;
pub var line_strong = dark_palette.line_strong;
pub var bg_panel = dark_palette.bg_panel;
pub var bg_panel_footer = dark_palette.bg_panel_footer;
pub var chip_active = dark_palette.chip_active;
pub var scrim = dark_palette.scrim;

pub var text = dark_palette.text;
pub var text_2 = dark_palette.text_2;
pub var text_3 = dark_palette.text_3;

/// The design exposes the accent as a tweakable prop; Settings can change it.
pub var accent = dark_palette.accents[0];
pub var accent_options = dark_palette.accents;
/// Which of `accent_options` is on; null when the config set a custom colour.
pub var accent_choice: ?usize = 0;
/// What each of `accent_options` is called in this scheme or theme.
pub var accent_labels = design_accent_labels;
pub var on_accent = dark_palette.on_accent;
pub var teal = dark_palette.teal;
pub var red = dark_palette.red;
pub var red_line = dark_palette.red_line;

pub var hover = dark_palette.hover;
pub var pressed = dark_palette.pressed;
pub var highlight = dark_palette.highlight;
pub var line_highlight = dark_palette.line_highlight;
pub var block_border = dark_palette.block_border;
pub var caret_blinks = dark_palette.caret_blinks;
pub var soft_shadow = dark_palette.soft_shadow;
pub var cursor = dark_palette.cursor;
pub var cursor_text = dark_palette.cursor_text;
pub var term_fg = dark_palette.term_fg;
var sel: ?Color = null;
/// A custom accent from the config, kept so it comes back after e-ink.
var custom_accent: ?Color = null;

pub fn selection() Color {
    // A translucent accent on e-ink is black at some alpha: a mid grey that
    // would dither. A flat light grey reads the same and stays crisp.
    if (scheme == .eink) return Color.hex(0xCCCCCC);
    // On colour e-paper a translucent accent would dither: a pale, fully
    // opaque wash of the accent reads the same and stays crisp.
    if (scheme == .eink_color) return .{ .r = accent.r * 0.2 + 0.8, .g = accent.g * 0.2 + 0.8, .b = accent.b * 0.2 + 0.8, .a = 1 };
    // A terminal theme brings its own (drawn under the text).
    if (sel) |c| return c;
    return accent.alpha(0.28);
}

/// Whether the caret is in its "on" phase: always on e-ink, else half of
/// each 1.06 s from `t0`, when the caret last moved.
pub fn caretOn(now: f64, t0: f64) bool {
    if (!caret_blinks) return true;
    return @mod(now - t0, 1.06) < 0.53;
}

/// The shadow under a floating panel: `rings` rings `step` points apart at
/// `alpha` each, dropped by `lift`, or on e-ink one solid block offset to
/// the bottom right, where translucent rings would only dither.
pub fn dropShadow(dl: *draw.DrawList, r: draw.Rect, radius: f32, rings: u32, step: f32, lift: f32, a: f32) void {
    if (!soft_shadow) {
        dl.rrect(.{ .x = r.x + 3, .y = r.y + 3, .w = r.w, .h = r.h }, radius, line_strong);
        return;
    }
    var i: f32 = @floatFromInt(rings);
    while (i >= 1) : (i -= 1) {
        const spread = i * step;
        dl.rrect(.{ .x = r.x - spread, .y = r.y - spread + lift, .w = r.w + spread * 2, .h = r.h + spread * 2 }, radius + spread, Color.hex(0x000000).alpha(a));
    }
}

/// What a colour a program chose is for: its text, or a cell's background.
pub const InkRole = enum { fg, bg };

/// A colour a program picked itself (256-colour or true colour), as the
/// scheme shows it. Untouched on the colour schemes. On e-ink it becomes
/// ink: text gets a grey between black and 0x66 (the brighter the colour
/// was meant to be — emphasis, on a dark terminal — the blacker), so it
/// always reads on white; a background gets a light grey between 0xF0 and
/// 0xD6 (brighter meant more), so the text on it still reads.
pub fn ink(c: Color, role: InkRole) Color {
    if (scheme != .eink) return c;
    const l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    const v: f32 = switch (role) {
        .fg => 0.40 * (1 - l),
        .bg => 0.94 - 0.10 * l,
    };
    return .{ .r = v, .g = v, .b = v, .a = c.a };
}

/// 16-colour ANSI palette tuned to sit calmly on the block background.
pub var ansi = dark_palette.ansi;

pub fn palette(s: Scheme) *const Palette {
    return switch (s) {
        .dark => &dark_palette,
        .light => &light_palette,
        .eink => &eink_palette,
        .eink_color => &eink_color_palette,
    };
}

/// Puts a scheme's colours in every token: those of terminal theme `t`
/// when one is given (the scheme is its kind), else the design's. A named
/// accent follows the scheme (each has its own tuning), a custom one stays
/// as it is — except on e-ink, where the accent is always black.
pub fn setScheme(s: Scheme, t: ?*const themes.Theme) void {
    scheme = s;
    active_theme = t;
    generation +%= 1;
    const p = if (t) |th| blk: {
        theme_palette = themePalette(th);
        break :blk &theme_palette;
    } else palette(s);
    bg = p.bg;
    bg_side = p.bg_side;
    bg_block = p.bg_block;
    bg_inset = p.bg_inset;
    line = p.line;
    line_strong = p.line_strong;
    bg_panel = p.bg_panel;
    bg_panel_footer = p.bg_panel_footer;
    chip_active = p.chip_active;
    scrim = p.scrim;
    text = p.text;
    text_2 = p.text_2;
    text_3 = p.text_3;
    on_accent = p.on_accent;
    teal = p.teal;
    red = p.red;
    red_line = p.red_line;
    hover = p.hover;
    pressed = p.pressed;
    highlight = p.highlight;
    line_highlight = p.line_highlight;
    block_border = p.block_border;
    caret_blinks = p.caret_blinks;
    soft_shadow = p.soft_shadow;
    accent_options = p.accents;
    accent_labels = p.accent_labels;
    ansi = p.ansi;
    cursor = p.cursor;
    cursor_text = p.cursor_text;
    term_fg = p.term_fg;
    sel = p.sel;
    refreshAccent();
}

/// The workspace in a terminal theme. The terminal's own colours are the
/// theme's exactly: background (blocks and full-screen programs alike,
/// so blocks get a border instead of a tint), foreground, cursor,
/// selection and ANSI. The chrome is mixed from background and
/// foreground. The accent options are the theme's accent, then its
/// yellow, blue and magenta (whichever of them is not the accent).
pub fn themePalette(t: *const themes.Theme) Palette {
    const b = rgb(t.background);
    const f = rgb(t.foreground);
    const dark = t.kind == .dark;
    const black = Color.hex(0x000000);
    const shade = if (dark) Color.mix(b, black, 0.28) else Color.mix(b, black, 0.045);
    var colors: [16]Color = undefined;
    for (&colors, t.ansi) |*c, v| c.* = rgb(v);
    var p: Palette = .{
        .bg = b,
        .bg_side = shade,
        .bg_block = b,
        .bg_inset = shade,
        .line = Color.mix(b, f, 0.13),
        .line_strong = Color.mix(b, f, 0.24),
        .bg_panel = Color.mix(b, f, 0.035),
        .bg_panel_footer = shade,
        .chip_active = Color.mix(b, f, 0.11),
        .scrim = if (dark) black.alpha(0.5) else Color.mix(f, black, 0.5).alpha(0.35),
        .text = f,
        .text_2 = Color.mix(f, b, 0.2),
        .text_3 = Color.mix(f, b, 0.38),
        .on_accent = if (luminance(rgb(t.accent)) > 0.45) (if (dark) b else Color.hex(0x1A1917)) else (if (dark) f else b),
        .teal = colors[6],
        .red = colors[1],
        .red_line = Color.mix(b, colors[1], 0.4),
        .hover = f.alpha(0.06),
        .pressed = f.alpha(0.10),
        .highlight = f.alpha(0.07),
        .line_highlight = f.alpha(0.035),
        .block_border = 1,
        .caret_blinks = true,
        .soft_shadow = true,
        .accents = undefined,
        .accent_labels = undefined,
        .ansi = colors,
        .cursor = rgb(t.cursor),
        .cursor_text = rgb(t.cursor_text),
        .term_fg = f,
        .sel = rgb(t.selection),
    };
    p.accents[0] = rgb(t.accent);
    p.accent_labels[0] = "Theme accent";
    const extra = [_]struct { i: usize, name: []const u8 }{ .{ .i = 3, .name = "Yellow" }, .{ .i = 4, .name = "Blue" }, .{ .i = 5, .name = "Magenta" }, .{ .i = 2, .name = "Green" } };
    var n: usize = 1;
    for (extra) |e| {
        if (n == p.accents.len) break;
        if (t.ansi[e.i] == t.accent) continue;
        p.accents[n] = colors[e.i];
        p.accent_labels[n] = e.name;
        n += 1;
    }
    return p;
}

/// A `0xRRGGBB` value as a colour.
pub fn rgb(v: u24) Color {
    return Color.fromRgb8(@intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff));
}

fn luminance(c: Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// The accent for the scheme in force: the chosen option in its tuning,
/// the custom colour as written, or black on e-ink whatever was chosen.
fn refreshAccent() void {
    if (accent_choice) |i| {
        accent = accent_options[@min(i, accent_options.len - 1)];
    } else if (scheme == .eink) {
        accent = accent_options[0];
    } else if (custom_accent) |c| {
        accent = c;
    }
}

/// One of the design's accent options, by index.
pub fn setAccent(i: usize) void {
    accent_choice = @min(i, accent_options.len - 1);
    custom_accent = null;
    refreshAccent();
}

/// Any colour, as written into the config file by hand.
pub fn setCustomAccent(value: u24) void {
    accent_choice = null;
    custom_accent = rgb(value);
    refreshAccent();
}

// Metrics (points).
// The spacing ones are `var`s: compact mode (Settings › Mode, `setCompact`)
// swaps in tighter values, the way `setScheme` swaps the colours.

/// Compact mode is on: tighter spacing everywhere, square corners, and
/// the terminal's blocks and input across the full width of their pane.
pub var compact: bool = false;
/// Titlebar band at the very top of the window: the sidebar header on the
/// left, the tab strip on the right. The transparent titlebar sits over it,
/// so its empty parts drag the window. Compact mode asks AppKit for the
/// compact toolbar titlebar, which is this tall.
pub var header_h: f32 = 52;
pub const palette_w: f32 = 720;
pub const palette_top: f32 = 112;
pub var sidebar_default_w: f32 = 300;
pub var sidebar_min_w: f32 = 208;
pub const sidebar_max_w: f32 = 520;
pub const files_default_w: f32 = 260;
pub const files_min_w: f32 = 180;
pub const files_max_w: f32 = 520;
pub const content_max_w: f32 = 880;
/// Split panes: the strip of a pane that is not under the titlebar band,
/// the narrowest a pane gets, the line between two panes and the extra
/// width around it that grabs the mouse.
pub var pane_strip_h: f32 = 40;
pub const pane_min: f32 = 160;
pub const divider_w: f32 = 1;
pub const divider_grab: f32 = 9;
pub var content_pad: f32 = 24;
pub var block_gap: f32 = 14;
pub var block_radius: f32 = 10;
pub var block_pad_x: f32 = 18;
/// Room above a terminal block's command and below its output, and
/// above and below the text of the command input.
pub var block_pad_y: f32 = 14;
pub var input_pad_y: f32 = 16;
pub const output_line_h: f32 = 22;
/// A row of a terminal block's output.
pub var term_line_h: f32 = output_line_h;
/// Sidebar rows (projects, then their resources), how far they sit in
/// from the sidebar's edges, and their corners.
pub var side_row_h: f32 = 32;
pub var side_res_h: f32 = 30;
pub var side_inset: f32 = 8;
pub var row_radius: f32 = 8;
/// Tabs in a strip: the padding either side of a title and the pill
/// behind a hovered one.
pub var tab_pad: f32 = 12;
pub var tab_pill_h: f32 = 34;
/// Compact mode's sizes for the tab-like ones above. The files panel's
/// Files / Search / Git tabs use them in both modes.
pub const compact_tab_pad: f32 = 9;
pub const compact_tab_pill_h: f32 = 26;
pub const compact_strip_h: f32 = 30;
pub const compact_row_radius: f32 = 3;

/// Switches between the regular spacing and compact mode's. The caller
/// redraws; the window's titlebar follows `header_h` (see `cocoa.zig`).
pub fn setCompact(on: bool) void {
    if (compact == on) return;
    compact = on;
    header_h = if (on) 38 else 52;
    sidebar_default_w = if (on) 220 else 300;
    sidebar_min_w = if (on) 150 else 208;
    pane_strip_h = if (on) compact_strip_h else 40;
    content_pad = if (on) 12 else 24;
    block_gap = if (on) 8 else 14;
    block_radius = if (on) 0 else 10;
    block_pad_x = if (on) 10 else 18;
    block_pad_y = if (on) 6 else 14;
    input_pad_y = if (on) 8 else 16;
    term_line_h = if (on) 18 else output_line_h;
    side_row_h = if (on) 24 else 32;
    side_res_h = if (on) 22 else 30;
    side_inset = if (on) 4 else 8;
    row_radius = if (on) compact_row_radius else 8;
    tab_pad = if (on) compact_tab_pad else 12;
    tab_pill_h = if (on) compact_tab_pill_h else 34;
    generation +%= 1;
}

// Type ramp.
pub const font_ui = Font.sans(14);
pub const font_ui_medium = Font.medium(14);
pub const font_side = Font.sans(13.5);
pub const font_side_medium = Font.medium(13.5);
pub const font_section = Font.semibold(12.5);
pub const font_status = Font.sans(12);
pub const font_hint = Font.sans(12.5);
pub const font_tab = Font.sans(13.5);
pub const font_tab_active = Font.medium(13.5);
pub const font_kbd = Font.mono(11);
pub const font_brand = Font.monoSemibold(15);
pub const font_cmd = Font.mono(14);
pub const font_output = Font.mono(13);
pub const font_output_bold = Font.monoSemibold(13);
pub const font_input = Font.mono(15);
pub const font_palette = Font.sans(15);
pub const font_palette_prompt = Font.mono(15);
pub const font_row = Font.sans(13.5);
pub const font_row_bold = Font.semibold(13.5);
pub const font_row_mono = Font.mono(12.5);
pub const font_row_mono_bold = Font.monoSemibold(12.5);
pub const font_group = Font.semibold(11);
pub const font_chip = Font.sans(12);
pub const font_chip_prefix = Font.mono(12);

/// Syntax colours, from the ANSI palette above so code sits as calmly as
/// terminal output does.
pub fn scopeColor(scope: @import("../syntax/lexer.zig").Scope) Color {
    return switch (scope) {
        .plain, .heading, .strong, .emphasis => text,
        .comment, .marker, .strike => text_3,
        .keyword, .link => ansi[4],
        .type => ansi[6],
        .string, .code => ansi[2],
        .number => ansi[3],
        .constant => ansi[5],
        .operator, .punct, .quote => text_2,
        .escape, .field_c => ansi[11],
        .property, .field_a => ansi[12],
        .func, .field_d => ansi[13],
        .field_b => ansi[10],
        .list => accent,
    };
}

test "theme palette: exact colours, accents skip the one that is the accent" {
    const p = themePalette(&themes.all[themes.find("solarized-light").?]);
    try @import("std").testing.expectEqual(rgb(0xFDF6E3), p.bg);
    try @import("std").testing.expectEqual(rgb(0x657B83), p.term_fg);
    try @import("std").testing.expectEqualStrings("Yellow", p.accent_labels[1]);
    // Solarized Dark's accent is its yellow, so the options skip to blue.
    try @import("std").testing.expectEqualStrings("Blue", themePalette(&themes.all[themes.find("solarized-dark").?]).accent_labels[1]);
}

//! Design tokens from the "1b · Workspace, calm" artboard. The colours are
//! variables: the artboard's dark set is the default and `setScheme` swaps
//! in a light counterpart of the same warm paper tones (Settings › Mode,
//! or macOS when the mode is "system"), or the e-ink set: ink on paper for
//! e-paper panels, which also turns off what those cannot show well (see
//! `eink_palette`). Metrics and the type ramp never change. The accent is
//! the one tweakable prop the design exposes; the config remembers it by
//! name (`accent_names`) or as a custom colour.
const draw = @import("../gfx/draw.zig");
const Color = draw.Color;
const Font = draw.Font;

pub const Scheme = enum { dark, light, eink };

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
    /// 16-colour ANSI palette tuned to sit calmly on the block background.
    ansi: [16]Color,
};

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
};

pub var scheme: Scheme = .dark;

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
pub const accent_names = [_][]const u8{ "Amber", "Peach", "Lime", "Rose" };
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
/// A custom accent from the config, kept so it comes back after e-ink.
var custom_accent: ?Color = null;

pub fn selection() Color {
    // A translucent accent on e-ink is black at some alpha: a mid grey that
    // would dither. A flat light grey reads the same and stays crisp.
    if (scheme == .eink) return Color.hex(0xCCCCCC);
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
    };
}

/// Puts a scheme's colours in every token. A named accent follows the
/// scheme (each has its own tuning), a custom one stays as it is — except
/// on e-ink, where the accent is always black.
pub fn setScheme(s: Scheme) void {
    scheme = s;
    const p = palette(s);
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
    ansi = p.ansi;
    refreshAccent();
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
pub fn setCustomAccent(rgb: u24) void {
    accent_choice = null;
    custom_accent = Color.fromRgb8(@intCast((rgb >> 16) & 0xff), @intCast((rgb >> 8) & 0xff), @intCast(rgb & 0xff));
    refreshAccent();
}

// Metrics (points).
/// Titlebar band at the very top of the window: the sidebar header on the
/// left, the tab strip on the right. The transparent titlebar sits over it,
/// so its empty parts drag the window.
pub const header_h: f32 = 52;
pub const palette_w: f32 = 720;
pub const palette_top: f32 = 112;
pub const sidebar_default_w: f32 = 300;
pub const sidebar_min_w: f32 = 208;
pub const sidebar_max_w: f32 = 520;
pub const files_default_w: f32 = 260;
pub const files_min_w: f32 = 180;
pub const files_max_w: f32 = 520;
pub const content_max_w: f32 = 880;
/// Split panes: the strip of a pane that is not under the titlebar band,
/// the narrowest a pane gets, the line between two panes and the extra
/// width around it that grabs the mouse.
pub const pane_strip_h: f32 = 40;
pub const pane_min: f32 = 160;
pub const divider_w: f32 = 1;
pub const divider_grab: f32 = 4;
pub const content_pad: f32 = 24;
pub const block_gap: f32 = 14;
pub const block_radius: f32 = 10;
pub const block_pad_x: f32 = 18;
pub const output_line_h: f32 = 22;

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

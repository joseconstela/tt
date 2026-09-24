//! Settings › UI › Mode: how much room tt's UI takes. Compact mode
//! tightens every spacing (`theme.setCompact`); with it off, NT mode
//! ("non-technical") can be switched on — a placeholder that changes
//! nothing yet.
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const config = @import("../config.zig");

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

const card_pad: f32 = 18; // the regular block padding, in compact mode too
const card_h: f32 = 92;

/// The page body at (x, y), `col_w` wide; returns its bottom.
pub fn draw(ui: *Ui, x: f32, y0: f32, col_w: f32) f32 {
    const dl = ui.dl;
    const cfg = config.get();
    var y = y0;

    // Compact mode.
    {
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_h };
        if (switchCard(ui, Ui.id("settings.mode.compact", 0), card, "Compact mode", "Smaller spacing everywhere: smaller tabs, a narrower sidebar, and the terminal across the full width without rounded corners.", cfg.compact, true)) {
            cfg.setCompact(!cfg.compact);
            // The two do not go together: compact mode turns NT mode off.
            if (cfg.compact) cfg.setNtMode(false);
            cfg.save();
        }
        y = card.bottom() + theme.block_gap;
    }

    // NT mode, only while compact mode is off.
    {
        const card: Rect = .{ .x = x, .y = y, .w = col_w, .h = card_h };
        const usable = !cfg.compact;
        if (switchCard(ui, Ui.id("settings.mode.nt", 0), card, "NT mode", "Non-technical mode: tt for people who do not live in a terminal. Nothing changes yet.", cfg.nt_mode and usable, usable)) {
            cfg.setNtMode(!cfg.nt_mode);
            cfg.save();
        }
        y = card.bottom();
        if (!usable) {
            _ = dl.textCentered(theme.font_hint, card.x + card_pad, y + 20, "Only with compact mode off.", theme.text_3);
            y += 30;
        }
    }
    return y;
}

/// A card with a title, a one-line detail and a switch at the right; the
/// whole card toggles it. Dimmed and inert when not `enabled`. True when
/// clicked.
fn switchCard(ui: *Ui, wid: u64, card: Rect, title: []const u8, detail: []const u8, on: bool, enabled: bool) bool {
    const dl = ui.dl;
    dl.shape(card, theme.block_radius, theme.bg_block, theme.block_border, theme.line);
    const toggle: Rect = .{ .x = card.right() - card_pad - 36, .y = card.centerY() - 10, .w = 36, .h = 20 };
    const text_w = toggle.x - 16 - (card.x + card_pad);
    _ = dl.textEllipsis(theme.font_ui_medium, card.x + card_pad, card.y + 28, title, text_w, if (enabled) theme.text else theme.text_3);
    _ = dl.textEllipsis(theme.font_hint, card.x + card_pad, card.y + 52, detail, text_w, theme.text_3);

    var clicked = false;
    if (enabled) {
        const st = ui.button(wid, card);
        if (st.hover) ui.cursor = .pointer;
        clicked = st.clicked;
    }
    const track = if (!enabled) theme.line else if (on) theme.accent else theme.line_strong;
    dl.rrect(toggle, 10, track);
    const knob_x = if (on) toggle.right() - 18 else toggle.x + 2;
    dl.rrect(.{ .x = knob_x, .y = toggle.y + 2, .w = 16, .h = 16 }, 8, if (on) theme.on_accent else if (enabled) theme.text_2 else theme.text_3);
    return clicked;
}


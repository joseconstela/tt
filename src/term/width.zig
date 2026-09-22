//! Display width of a code point in terminal cells (a small wcwidth). Pure,
//! so the grid emulator and the text engine share one answer.

pub fn cellWidth(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if ((cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x20D0 and cp <= 0x20FF)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F680 and cp <= 0x1F6FF) or (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

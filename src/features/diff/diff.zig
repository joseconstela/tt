//! The diff feature: two versions of a file side by side. This file is the
//! feature's public surface, the only one code outside `features/diff/`
//! may import (`tooling/arch_check.zig` holds everyone to it).
//!
//!   model/rows.zig  the line comparison, pure
//!   entry/tab.zig   the `diff` tab kind the app mounts
//!
//! What a tab is opened on travels in `tabs/tab.zig`'s `OpenArgs.diff`.
const tab_mod = @import("../../tabs/tab.zig");

/// The comparison tab (the app asks one whether it already `shows` a change).
pub const Tab = @import("entry/tab.zig").DiffTab;
/// The line comparison itself: `rows`, `splitLines`, `changedSpan`.
pub const rows = @import("model/rows.zig");

/// Adds the `diff` kind to the tab manager.
pub fn register(manager: *tab_mod.TabManager) void {
    manager.register(.{ .name = "diff", .label = "Diff", .create = Tab.create });
}

test {
    _ = @import("model/rows.zig");
    _ = @import("entry/tab.zig");
}

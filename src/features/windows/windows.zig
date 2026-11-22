//! The windows feature: a tab can leave the main window and live in a
//! window of its own. This file is the feature's public surface, the only
//! one code outside `features/windows/` may import (`tooling/arch_check.zig`
//! holds everyone to it).
//!
//!   model/frames.zig   where windows are on screen, as numbers: which one
//!                      a point is over, where a new one opens, the
//!                      workspace record
//!   entry/window.zig   `TabWindow`: one separate window's draw list, input
//!                      state, pane view and size
//!
//! The tabs of a window are a group in `tabs/tab.zig`'s `TabManager` (a
//! *window group*); `App` owns the windows, builds their frames and decides
//! what a tab let go outside its window lands on; `platform/cocoa.zig`
//! gives each one an NSWindow.
pub const frames = @import("model/frames.zig");
pub const Frame = frames.Frame;
pub const Point = frames.Point;
pub const TabWindow = @import("entry/window.zig").TabWindow;

test {
    _ = @import("model/frames.zig");
    _ = @import("entry/window.zig");
}

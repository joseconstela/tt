//! The explorer feature: the files tree of the files panel. This file is
//! the feature's public surface, the only one code outside
//! `features/explorer/` may import (`tooling/arch_check.zig` holds
//! everyone to it).
//!
//!   model/tree.zig      the tree as data: nodes, their order, what a
//!                       fresh listing keeps of the old one
//!   client/listing.zig  reading folders, through the host it is handed
//!   view/tree.zig       the rows, drawn: icons, names, the level lines
//!   view/icon.zig       which icon a name gets
//!   entry/tree.zig      what the files panel mounts (`Tree`)
//!   hosts.zig           the effect the feature is handed (listing a folder)
//!
//! The panel around it (the Files / Search / Git strip, the splitter) is
//! `ui/files.zig`, which mounts `Tree` beside the Search and Git views.
const entry = @import("entry/tree.zig");

/// The files tree, as the files panel mounts it.
pub const Tree = entry.Tree;
/// What a draw of the tree hands the app: a file to open or pin, a menu
/// to show, a drag that starts, a folder something was dropped on.
pub const Result = entry.Result;
pub const FileMenu = entry.FileMenu;

test {
    _ = @import("model/tree.zig");
    _ = @import("client/listing.zig");
    _ = @import("view/icon.zig");
    _ = @import("view/tree.zig");
    _ = @import("entry/tree.zig");
}

//! Root for `zig build test`: pulls in every pure-logic module.
test {
    _ = @import("term/parser.zig");
    _ = @import("term/buffer.zig");
    _ = @import("term/screen.zig");
    _ = @import("input/editor.zig");
    _ = @import("input/history.zig");
    _ = @import("input/complete.zig");
    _ = @import("projects.zig");
    _ = @import("filetype.zig");
    _ = @import("syntax/lexer.zig");
    _ = @import("input/document.zig");
    _ = @import("tabs/tab.zig");
    _ = @import("records.zig");
    _ = @import("term/block_codec.zig");
    _ = @import("workspace.zig");
    _ = @import("tabs/viewer.zig");
    _ = @import("tabs/layout.zig");
    _ = @import("ui/palette.zig");
    _ = @import("ui/icon_spec.zig");
    _ = @import("config.zig");
    _ = @import("tabs/web_tab.zig");
    _ = @import("agent.zig");
}

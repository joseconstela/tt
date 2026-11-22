//! Which icon a row of the files tree gets, from its name alone (no file
//! is read for it): folders open or closed, files by what they hold. The
//! kinds are few on purpose, in the app's own stroke style: a picture, a
//! notebook, a script, a text to read, source code, Zig's mark for Zig,
//! and a plain sheet for everything else.
const std = @import("std");
const icons = @import("../../../gfx/icons.zig");
const filetype = @import("../../../filetype.zig");

pub fn forFolder(expanded: bool) icons.Icon {
    return if (expanded) .folder_open else .folder;
}

/// Texts meant to be read rather than run, beyond what `filetype` names.
const reading_extensions = [_][]const u8{ "txt", "text", "rst", "rtf", "pdf", "log", "adoc", "org" };

pub fn forFile(name: []const u8) icons.Icon {
    // Git's own files are settings, whatever grammar colours them.
    if (std.mem.startsWith(u8, name, ".git")) return .file;
    if (filetype.hasExtension(name, &.{"ipynb"})) return .notebook;
    if (filetype.hasExtension(name, &filetype.image_extensions)) return .image;
    if (filetype.hasExtension(name, &reading_extensions)) return .document;
    return switch (filetype.language(name, "")) {
        .plain => .file,
        .zig => .zig,
        .shell => .terminal,
        .markdown, .csv => .document,
        else => .code,
    };
}

test "icon: by what a file holds" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(icons.Icon.zig, forFile("diff.zig"));
    try expectEqual(icons.Icon.zig, forFile("build.zig.zon"));
    try expectEqual(icons.Icon.image, forFile("shot.PNG"));
    try expectEqual(icons.Icon.notebook, forFile("analysis.ipynb"));
    try expectEqual(icons.Icon.terminal, forFile("deploy.sh"));
    try expectEqual(icons.Icon.terminal, forFile(".zshrc"));
    try expectEqual(icons.Icon.document, forFile("README.md"));
    try expectEqual(icons.Icon.document, forFile("notes.txt"));
    try expectEqual(icons.Icon.code, forFile("main.rs"));
    try expectEqual(icons.Icon.code, forFile("config.yml"));
    try expectEqual(icons.Icon.code, forFile("Makefile"));
    try expectEqual(icons.Icon.file, forFile("LICENSE"));
    try expectEqual(icons.Icon.file, forFile("data.bin"));
    try expectEqual(icons.Icon.file, forFile(".gitignore"));
}

test "icon: folders open and closed" {
    try std.testing.expectEqual(icons.Icon.folder_open, forFolder(true));
    try std.testing.expectEqual(icons.Icon.folder, forFolder(false));
}

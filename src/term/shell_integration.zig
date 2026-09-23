//! Installs the zsh integration without touching the user's dotfiles: we point
//! ZDOTDIR at a private directory whose startup files source the user's real
//! ones and then load `tt.zsh` (the same trick VS Code and kitty use).
const std = @import("std");
const sys = @import("../sys.zig");

const zshenv =
    \\# tt: chain to the user's .zshenv, then keep our ZDOTDIR for the next files.
    \\if [[ -f "$TT_USER_ZDOTDIR/.zshenv" ]]; then
    \\  ZDOTDIR="$TT_USER_ZDOTDIR"
    \\  builtin source "$TT_USER_ZDOTDIR/.zshenv"
    \\  [[ "$ZDOTDIR" != "$TT_ZDOTDIR" ]] && TT_USER_ZDOTDIR="$ZDOTDIR"
    \\fi
    \\ZDOTDIR="$TT_ZDOTDIR"
    \\
;

const zprofile =
    \\if [[ -f "$TT_USER_ZDOTDIR/.zprofile" ]]; then
    \\  ZDOTDIR="$TT_USER_ZDOTDIR"
    \\  builtin source "$TT_USER_ZDOTDIR/.zprofile"
    \\  ZDOTDIR="$TT_ZDOTDIR"
    \\fi
    \\
;

const zshrc =
    \\# /etc/zshrc derived HISTFILE from our private ZDOTDIR; point it back.
    \\HISTFILE="$TT_USER_ZDOTDIR/.zsh_history"
    \\if [[ -f "$TT_USER_ZDOTDIR/.zshrc" ]]; then
    \\  ZDOTDIR="$TT_USER_ZDOTDIR"
    \\  builtin source "$TT_USER_ZDOTDIR/.zshrc"
    \\  ZDOTDIR="$TT_ZDOTDIR"
    \\fi
    \\builtin source "$TT_ZDOTDIR/tt.zsh"
    \\
;

const zlogin =
    \\if [[ -f "$TT_USER_ZDOTDIR/.zlogin" ]]; then
    \\  ZDOTDIR="$TT_USER_ZDOTDIR"
    \\  builtin source "$TT_USER_ZDOTDIR/.zlogin"
    \\fi
    \\# Startup is over: restore the user's ZDOTDIR for nested shells.
    \\if [[ "$TT_USER_ZDOTDIR" == "$HOME" ]]; then
    \\  builtin unset ZDOTDIR
    \\else
    \\  export ZDOTDIR="$TT_USER_ZDOTDIR"
    \\fi
    \\
;

/// Writes the integration files and returns the directory (caller owns it).
pub fn install(gpa: std.mem.Allocator) ![]u8 {
    const tmp = std.mem.trimEnd(u8, sys.getenv("TMPDIR") orelse "/tmp", "/");
    const dir = try std.fmt.allocPrint(gpa, "{s}/tt-{d}", .{ tmp, sys.getuid() });
    errdefer gpa.free(dir);
    sys.mkdir(gpa, dir);

    const files = [_]struct { name: []const u8, body: []const u8 }{
        .{ .name = ".zshenv", .body = zshenv },
        .{ .name = ".zprofile", .body = zprofile },
        .{ .name = ".zshrc", .body = zshrc },
        .{ .name = ".zlogin", .body = zlogin },
        .{ .name = "tt.zsh", .body = @embedFile("zsh_integration") },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, f.name });
        defer gpa.free(path);
        try sys.writeFile(gpa, path, f.body, false);
    }
    return dir;
}

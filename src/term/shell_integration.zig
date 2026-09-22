//! Installs the zsh integration without touching the user's dotfiles: we point
//! ZDOTDIR at a private directory whose startup files source the user's real
//! ones and then load `conch.zsh` (the same trick VS Code and kitty use).
const std = @import("std");
const sys = @import("../sys.zig");

const zshenv =
    \\# conch: chain to the user's .zshenv, then keep our ZDOTDIR for the next files.
    \\if [[ -f "$CONCH_USER_ZDOTDIR/.zshenv" ]]; then
    \\  ZDOTDIR="$CONCH_USER_ZDOTDIR"
    \\  builtin source "$CONCH_USER_ZDOTDIR/.zshenv"
    \\  [[ "$ZDOTDIR" != "$CONCH_ZDOTDIR" ]] && CONCH_USER_ZDOTDIR="$ZDOTDIR"
    \\fi
    \\ZDOTDIR="$CONCH_ZDOTDIR"
    \\
;

const zprofile =
    \\if [[ -f "$CONCH_USER_ZDOTDIR/.zprofile" ]]; then
    \\  ZDOTDIR="$CONCH_USER_ZDOTDIR"
    \\  builtin source "$CONCH_USER_ZDOTDIR/.zprofile"
    \\  ZDOTDIR="$CONCH_ZDOTDIR"
    \\fi
    \\
;

const zshrc =
    \\# /etc/zshrc derived HISTFILE from our private ZDOTDIR; point it back.
    \\HISTFILE="$CONCH_USER_ZDOTDIR/.zsh_history"
    \\if [[ -f "$CONCH_USER_ZDOTDIR/.zshrc" ]]; then
    \\  ZDOTDIR="$CONCH_USER_ZDOTDIR"
    \\  builtin source "$CONCH_USER_ZDOTDIR/.zshrc"
    \\  ZDOTDIR="$CONCH_ZDOTDIR"
    \\fi
    \\builtin source "$CONCH_ZDOTDIR/conch.zsh"
    \\
;

const zlogin =
    \\if [[ -f "$CONCH_USER_ZDOTDIR/.zlogin" ]]; then
    \\  ZDOTDIR="$CONCH_USER_ZDOTDIR"
    \\  builtin source "$CONCH_USER_ZDOTDIR/.zlogin"
    \\fi
    \\# Startup is over: restore the user's ZDOTDIR for nested shells.
    \\if [[ "$CONCH_USER_ZDOTDIR" == "$HOME" ]]; then
    \\  builtin unset ZDOTDIR
    \\else
    \\  export ZDOTDIR="$CONCH_USER_ZDOTDIR"
    \\fi
    \\
;

/// Writes the integration files and returns the directory (caller owns it).
pub fn install(gpa: std.mem.Allocator) ![]u8 {
    const tmp = std.mem.trimEnd(u8, sys.getenv("TMPDIR") orelse "/tmp", "/");
    const dir = try std.fmt.allocPrint(gpa, "{s}/conch-{d}", .{ tmp, sys.getuid() });
    errdefer gpa.free(dir);
    sys.mkdir(gpa, dir);

    const files = [_]struct { name: []const u8, body: []const u8 }{
        .{ .name = ".zshenv", .body = zshenv },
        .{ .name = ".zprofile", .body = zprofile },
        .{ .name = ".zshrc", .body = zshrc },
        .{ .name = ".zlogin", .body = zlogin },
        .{ .name = "conch.zsh", .body = @embedFile("zsh_integration") },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, f.name });
        defer gpa.free(path);
        try sys.writeFile(gpa, path, f.body, false);
    }
    return dir;
}

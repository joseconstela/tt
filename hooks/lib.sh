# Shared by the hooks in this directory. Sourced, not run.

# zig_version_guard ZON_TEXT
# Prints a one-line message and returns 1 when the `zig` on PATH is not the
# version build.zig.zon asks for in `minimum_zig_version`.
zig_version_guard() {
    want=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$want" ]; then
        echo "zig version: no minimum_zig_version found in build.zig.zon"
        return 1
    fi
    if ! command -v zig >/dev/null 2>&1; then
        echo "zig version: no zig on PATH (build.zig.zon wants $want)"
        return 1
    fi
    have=$(zig version 2>/dev/null)
    if [ "$have" != "$want" ]; then
        echo "zig version: PATH has zig $have, build.zig.zon wants $want"
        return 1
    fi
    return 0
}

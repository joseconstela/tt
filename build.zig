const std = @import("std");

const frameworks = [_][]const u8{
    "Foundation",
    "AppKit",
    "Metal",
    "QuartzCore",
    "CoreFoundation",
    "CoreGraphics",
    "CoreText",
    "ImageIO",
    "WebKit",
};

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleName</key><string>tt</string>
    \\  <key>CFBundleDisplayName</key><string>tt</string>
    \\  <key>CFBundleIdentifier</key><string>es.lab34.tt</string>
    \\  <key>CFBundleExecutable</key><string>tt</string>
    \\  <key>CFBundlePackageType</key><string>APPL</string>
    \\  <key>CFBundleShortVersionString</key><string>0.1.0</string>
    \\  <key>CFBundleVersion</key><string>1</string>
    \\  <key>LSMinimumSystemVersion</key><string>13.0</string>
    \\  <key>NSHighResolutionCapable</key><true/>
    \\  <key>NSPrincipalClass</key><string>NSApplication</string>
    \\  <key>NSAppTransportSecurity</key>
    \\  <dict>
    \\    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    \\    <!-- Agents at plain-http endpoints (Ollama, LM Studio on the LAN …). -->
    \\    <key>NSAllowsArbitraryLoads</key><true/>
    \\  </dict>
    \\</dict>
    \\</plist>
    \\
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (frameworks) |f| mod.linkFramework(f, .{});
    mod.linkSystemLibrary("objc", .{});

    // Assets are embedded so the binary is self-contained.
    mod.addAnonymousImport("font_sans", .{ .root_source_file = b.path("assets/fonts/SplineSans.ttf") });
    mod.addAnonymousImport("font_mono", .{ .root_source_file = b.path("assets/fonts/SplineSansMono.ttf") });
    mod.addAnonymousImport("shaders_metal", .{ .root_source_file = b.path("src/gfx/shaders.metal") });
    mod.addAnonymousImport("zsh_integration", .{ .root_source_file = b.path("assets/shell/tt.zsh") });

    // Full-screen programs (vim, htop, Claude Code …) run on libghostty-vt,
    // Ghostty's terminal emulation core, pinned to a commit in build.zig.zon.
    // SIMD stays off: it would compile C++ dependencies for a parsing
    // speed-up this app does not need.
    const ghostty = b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false });
    if (ghostty) |dep| mod.addImport("ghostty-vt", dep.module("ghostty-vt"));

    const exe = b.addExecutable(.{ .name = "tt", .root_module = mod });
    b.installArtifact(exe);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tt");
    run_step.dependOn(&run_cmd.step);

    // `zig build app` → zig-out/tt.app
    const app_step = b.step("app", "Build the macOS app bundle (zig-out/tt.app)");
    const install_bin = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "tt.app/Contents/MacOS" } },
    });
    const wf = b.addWriteFiles();
    const plist = wf.add("Info.plist", info_plist);
    const install_plist = b.addInstallFile(plist, "tt.app/Contents/Info.plist");
    app_step.dependOn(&install_bin.step);
    app_step.dependOn(&install_plist.step);

    // `zig build test` — pure-Zig logic (terminal parser, buffers, editor …)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (ghostty) |dep| test_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

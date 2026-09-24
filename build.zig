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
    // Website tabs: camera and microphone access, desktop notifications.
    "AVFoundation",
    "UserNotifications",
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
    \\  <!-- App icon from icon.icon: the Assets.car entry (macOS 26+) and the icns fallback. -->
    \\  <key>CFBundleIconName</key><string>icon</string>
    \\  <key>CFBundleIconFile</key><string>icon</string>
    \\  <!-- Website tabs (video calls): macOS shows these when it asks. -->
    \\  <key>NSCameraUsageDescription</key><string>Websites open in tt, such as video calls, can use the camera when you allow them.</string>
    \\  <key>NSMicrophoneUsageDescription</key><string>Websites open in tt, such as video calls, can use the microphone when you allow them.</string>
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
    // The Jupyter bridge that notebook tabs start with the notebook's Python.
    mod.addAnonymousImport("jupyter_bridge", .{ .root_source_file = b.path("assets/notebook/tt_jupyter.py") });
    // Plotly's library, vendored so interactive figures render in a notebook's
    // cell outputs without reaching a CDN (tt stays local only). Written next
    // to the bridge at runtime and loaded by the output web views.
    mod.addAnonymousImport("plotly_js", .{ .root_source_file = b.path("assets/notebook/plotly.min.js") });

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
    // The linker signs only the binary; macOS files camera, microphone and
    // notification permissions under the app's signed identity, which needs
    // the whole bundle (its Info.plist) sealed: sign it again, ad hoc.
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-" });
    sign.addArg(b.getInstallPath(.prefix, "tt.app"));
    sign.step.dependOn(&install_bin.step);
    sign.step.dependOn(&install_plist.step);
    app_step.dependOn(&sign.step);

    // The app icon: icon.icon (an Icon Composer file) compiled by Xcode's
    // actool into Resources/Assets.car (the layered icon macOS 26 renders)
    // plus icon.icns for older macOS. Run hashes a directory argument by path
    // only, so the icon's files are listed as inputs to rebuild on edits.
    const actool = b.addSystemCommand(&.{ "xcrun", "actool" });
    actool.addDirectoryArg(b.path("icon.icon"));
    actool.addFileInput(b.path("icon.icon/icon.json"));
    actool.addFileInput(b.path("icon.icon/Assets/Image.png"));
    actool.addArg("--compile");
    const icon_dir = actool.addOutputDirectoryArg("Resources");
    actool.addArgs(&.{
        "--app-icon",                  "icon",
        "--platform",                  "macosx",
        "--target-device",             "mac",
        "--minimum-deployment-target", "13.0",
        "--output-format",             "human-readable-text",
        "--output-partial-info-plist",
    });
    _ = actool.addOutputFileArg("icon-partial.plist");
    const install_icon = b.addInstallDirectory(.{
        .source_dir = icon_dir,
        .install_dir = .{ .custom = "tt.app/Contents" },
        .install_subdir = "Resources",
    });
    app_step.dependOn(&install_icon.step);

    // `zig build test` — pure-Zig logic (terminal parser, buffers, editor …)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (ghostty) |dep| test_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    test_mod.addAnonymousImport("jupyter_bridge", .{ .root_source_file = b.path("assets/notebook/tt_jupyter.py") });
    // The notebook tab's tests reach the texture code, which talks to Metal through the runtime.
    test_mod.linkSystemLibrary("objc", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

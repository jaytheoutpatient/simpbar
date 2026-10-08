const std = @import("std");
const Build = std.Build;

// simpbar-shell — the "desktop widgets" idea from Event-Horizon-Shell,
// rewritten in Zig on top of the infra the bar (../simpbar) already proves:
// the same zig-wayland scanner for layer-shell surfaces, and the bar's
// font.zig (freetype glyph cache) + logging.zig imported as source modules.
const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});

    const scanner = Scanner.create(b, .{});

    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    // Screenshot capture for the overview's window thumbnails (vendored
    // from swaywm/wlr-protocols; Hyprland implements zwlr_screencopy too).
    scanner.addCustomProtocol(b.path("protocols/wlr-screencopy-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("zwlr_layer_shell_v1", 4);
    // Bound at v1 at runtime (see registryListener): v1 already has the
    // buffer/copy/ready/failed flow the overview needs, and skipping v3's
    // buffer_done handshake keeps the capture state machine trivial.
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    // xdg_wm_base is generated too (the scanner pulls it in for surface
    // role wiring) even though the shell itself never creates an xdg window.

    // Shared-with-simpbar source modules: the shell only needs the font
    // cache and logging; it never touches the bar's tray/icons/Hyprland glue.
    const font_mod = b.createModule(.{
        .root_source_file = b.path("../simpbar/src/font.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    font_mod.linkSystemLibrary("freetype2", .{});

    const logging_mod = b.createModule(.{
        .root_source_file = b.path("../simpbar/src/logging.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const widgets_mod = b.createModule(.{
        .root_source_file = b.path("src/widgets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    widgets_mod.addImport("font", font_mod);
    widgets_mod.addImport("logging", logging_mod);

    // Album-art decode for the media card: same gdk-pixbuf shim the bar
    // compiles for tray icons, referenced out of ../simpbar/src like the
    // font module above (the installer stages both trees side by side).
    const art_mod = b.createModule(.{
        .root_source_file = b.path("src/art.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    art_mod.addIncludePath(b.path("../simpbar/src")); // gdkpixbuf_shim.h lives with the bar's sources
    widgets_mod.addImport("art", art_mod);

    // Overview mode (Alt+W): the second layer surface on the overlay layer,
    // screencopy thumbnails, hyprctl window/workspace queries. Own module so
    // main.zig stays the host/wiring file.
    const overview_mod = b.createModule(.{
        .root_source_file = b.path("src/overview.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    overview_mod.addImport("wayland", wayland_mod);
    overview_mod.addImport("font", font_mod);
    overview_mod.addImport("logging", logging_mod);
    overview_mod.addImport("widgets", widgets_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("wayland", wayland_mod);
    exe_mod.addImport("font", font_mod);
    exe_mod.addImport("logging", logging_mod);
    exe_mod.addImport("widgets", widgets_mod);
    exe_mod.addImport("overview", overview_mod);
    // No EGL/GL stack: everything renders CPU-side into wl_shm ARGB buffers,
    // exactly like the bar.
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("freetype2", .{});
    exe_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{}); // media cover-art decode (src/art.zig)
    // Sticky-note typing decodes the compositor's keymap through xkb; the
    // bar links the same library for its input handling.
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    // Same translate-c workaround as the bar: gdk-pixbuf.h itself is only
    // ever included from gdkpixbuf_shim.c, compiled by a real C compiler;
    // art.zig @cImports the shim's plain-C header.
    exe_mod.addIncludePath(b.path("../simpbar/src"));
    exe_mod.addCSourceFile(.{ .file = b.path("../simpbar/src/gdkpixbuf_shim.c"), .flags = &.{} });

    const exe = b.addExecutable(.{
        .name = "simpbar-shell",
        .root_module = exe_mod,
    });

    _ = wayland_dep;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run simpbar-shell");
    run_step.dependOn(&run_cmd.step);
}
const std = @import("std");
const Build = std.Build;

// zig-wayland exposes a build-time helper (Scanner) that turns protocol XML
// into Zig source at build time. This import works because `wayland` is
// declared as a dependency in build.zig.zon.
const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});

    const scanner = Scanner.create(b, .{});

    // Core protocol module produced by the scanner. We import specific
    // interfaces from it below via `wayland.client.wl` / `.zwlr`.
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    // Core Wayland interfaces we need: surfaces, shared memory, outputs.
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    // wlr-layer-shell is NOT part of upstream wayland-protocols — it's a
    // wlroots extension. Vendor the XML yourself; see protocols/README.md.
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));

    // Generate bindings up to the given protocol version. Bump these if you
    // need newer requests/events.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("zwlr_layer_shell_v1", 4);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("wayland", wayland_mod);
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("freetype2", .{}); // real Nerd Font/Unicode glyph rendering (src/font.zig)
    exe_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{}); // tray icon-name -> PNG/SVG decode (src/icontheme.zig)
    // gdk-pixbuf.h pulls in GLib headers that Zig's translate-c can't parse
    // directly (G_GNUC_BEGIN_IGNORE_DEPRECATIONS expands to back-to-back
    // _Pragma(...) invocations translate-c chokes on) — src/gdkpixbuf_shim.c
    // wraps the parts we need behind a plain C API instead, compiled here
    // by a real C compiler; icontheme.zig only @cImports the shim's header.
    exe_mod.addIncludePath(b.path("src"));
    exe_mod.addCSourceFile(.{ .file = b.path("src/gdkpixbuf_shim.c"), .flags = &.{} });

    const exe = b.addExecutable(.{
        .name = "zbar",
        .root_module = exe_mod,
    });

    _ = wayland_dep;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zbar");
    run_step.dependOn(&run_cmd.step);
}

//! simpbar-shell — desktop widgets for Wayland, the Event-Horizon-Shell idea
//! rewritten in Zig.
//!
//! One full-output layer-shell surface per monitor on the `background` layer
//! (so widgets float behind your windows, rainmeter-style), painted entirely
//! in software into wl_shm ARGB buffers. Each configured widget is a small
//! paint-only object (see widgets.zig) drawn into that shared surface; the
//! host repaints lazily — it poll()s with a timeout computed from the
//! earliest widget cadence deadline, never a fixed animation loop.
//!
//! Input is limited to the widget rects (surface set_input_region), so the
//! rest of the desktop passes clicks straight through to windows.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const font_mod = @import("font");
const logging = @import("logging");
const widgets_mod = @import("widgets");

pub const panic = std.debug.FullPanic(logging.panicHandler);

const MAX_OUTPUTS: usize = 8;
const MAX_WIDGETS: usize = 8;
const FONT_PIXEL_SIZE: u32 = 13;
const BTN_LEFT: u32 = 0x110;

// getenv by hand — enough here, no env-map machinery needed (same approach
// as the bar).
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const libc_clock = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

/// Monotonic milliseconds since some arbitrary epoch — only deltas are
/// meaningful. 0.16 removed std.time.milliTimestamp/Instant, and the bar
/// binds its own libc time helpers, so this follows suit.
fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_clock.clock_gettime(1, &tp) != 0) return 0; // 1 = CLOCK_MONOTONIC
    const sec: i64 = @intCast(tp.sec);
    const nsec: i64 = @intCast(tp.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

// --- configuration ---------------------------------------------------------

const JsonWidgetCfg = struct {
    id: []const u8 = "clock",
    x: i32 = 0,
    y: i32 = 0,
};

const JsonConfig = struct {
    font_path: ?[]const u8 = null,
    card_bg_opacity: ?u8 = null,
    card_corner_radius: ?u32 = null,
    widgets: ?[]const JsonWidgetCfg = null,
};

const JsonMatugenColors = struct {
    bg_color: ?[]const u8 = null,
    text_color: ?[]const u8 = null,
    border_color: ?[]const u8 = null,
    hover_color: ?[]const u8 = null,
};

const WidgetCfg = struct {
    id: widgets_mod.WidgetId,
    x: i32,
    y: i32,
};

const ShellConfig = struct {
    font_path: []const u8 = "",
    card_bg_opacity: u8 = 55,
    corner_radius: u32 = 12,
    widget_cfgs: [MAX_WIDGETS]WidgetCfg = undefined,
    widget_count: usize = 0,
};

const DEFAULT_WIDGETS = [_]WidgetCfg{
    .{ .id = .clock, .x = 24, .y = 24 },
    .{ .id = .weather, .x = 24, .y = 106 },
    .{ .id = .media, .x = 24, .y = 176 },
    // Media is a tall card (cover + progress + controls ≈ 156px at the
    // 13px font); system sits below it with a gap.
    .{ .id = .system, .x = 24, .y = 350 },
};

var shell_config_path_buf: [512]u8 = undefined;
var shell_config_path: [:0]const u8 = "";
var matugen_path_buf: [512]u8 = undefined;
var matugen_path: [:0]const u8 = "";

fn resolveConfigPaths() void {
    const home = std.mem.span(getenv("HOME") orelse return);
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o755); // EEXIST on a normal first boot — best-effort
    shell_config_path = std.fmt.bufPrintZ(&shell_config_path_buf, "{s}/shell.json", .{dir}) catch "";
    matugen_path = std.fmt.bufPrintZ(&matugen_path_buf, "{s}/matugen.json", .{dir}) catch "";
}

fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    if (path.len == 0) return error.NoPath;
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return error.OpenFailed;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
        if (list.items.len > 1024 * 1024) break; // sanity cap
    }
    return list.toOwnedSlice(allocator);
}

fn parseHexColor(s: []const u8) !u32 {
    if (s.len != 7 or s[0] != '#') return error.InvalidColor;
    const rgb = try std.fmt.parseInt(u32, s[1..7], 16);
    return 0xFF000000 | rgb;
}

/// Reads shell.json (missing/malformed → defaults). Read once at startup —
/// no live reload in v1.
fn loadConfig(gpa: std.mem.Allocator) ShellConfig {
    var cfg = ShellConfig{};
    for (DEFAULT_WIDGETS, 0..) |dw, i| cfg.widget_cfgs[i] = dw;
    cfg.widget_count = DEFAULT_WIDGETS.len;
    if (shell_config_path.len == 0) return cfg;

    const bytes = readFileAlloc(gpa, shell_config_path) catch |err| {
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ shell_config_path, err });
        }
        return cfg;
    };
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSliceLeaky(JsonConfig, gpa, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping defaults", .{ shell_config_path, err });
        return cfg;
    };

    if (parsed.font_path) |fp| {
        if (fp.len > 0) cfg.font_path = fp;
    }
    if (parsed.card_bg_opacity) |a| cfg.card_bg_opacity = @min(a, 100);
    if (parsed.card_corner_radius) |r| cfg.corner_radius = r;
    if (parsed.widgets) |ws| {
        if (ws.len == 0) {
            cfg.widget_count = 0; // explicit empty list = all widgets off
            return cfg;
        }
        var count: usize = 0;
        for (ws) |w| {
            if (count >= MAX_WIDGETS) break;
            const id = std.meta.stringToEnum(widgets_mod.WidgetId, w.id) orelse {
                logging.warn("config: unknown widget id \"{s}\" — skipping", .{w.id});
                continue;
            };
            cfg.widget_cfgs[count] = .{ .id = id, .x = w.x, .y = w.y };
            count += 1;
        }
        cfg.widget_count = count;
    }
    return cfg;
}

/// Merges the matugen palette (same keys the bar reads) when present.
/// Any failure keeps the defaults entirely.
fn tryApplyMatugenColors(gpa: std.mem.Allocator, theme: *widgets_mod.Theme) bool {
    if (matugen_path.len == 0) return false;
    const bytes = readFileAlloc(gpa, matugen_path) catch |err| {
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ matugen_path, err });
        }
        return false;
    };
    defer gpa.free(bytes);
    const colors = std.json.parseFromSliceLeaky(JsonMatugenColors, gpa, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping defaults", .{ matugen_path, err });
        return false;
    };
    if (colors.bg_color) |hex| {
        theme.bg_color = parseHexColor(hex) catch theme.bg_color;
    }
    if (colors.text_color) |hex| {
        theme.text_color = parseHexColor(hex) catch theme.text_color;
    }
    if (colors.border_color) |hex| {
        theme.border_color = parseHexColor(hex) catch theme.border_color;
    }
    if (colors.hover_color) |hex| {
        theme.hover_color = parseHexColor(hex) catch theme.hover_color;
    }
    return true;
}

fn setCloexec(fd: posix.fd_t) void {
    _ = std.c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}

fn fontPathZ(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

// --- Wayland plumbing ------------------------------------------------------

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    seat: ?*wl.Seat = null,
    seat_has_pointer: bool = false,
    output_count: usize = 0,
    outputs: [MAX_OUTPUTS]*wl.Output = undefined,
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.sliceTo(g.interface, 0);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                globals.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                globals.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
                globals.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                const seat = registry.bind(g.name, wl.Seat, 7) catch return;
                globals.seat = seat;
                seat.setListener(*Globals, seatListener, globals);
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                if (globals.output_count >= globals.outputs.len) return;
                globals.outputs[globals.output_count] = registry.bind(g.name, wl.Output, 4) catch return;
                globals.output_count += 1;
            }
        },
        .global_remove => {},
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, globals: *Globals) void {
    switch (event) {
        .capabilities => |caps| globals.seat_has_pointer = caps.capabilities.pointer,
        .name => {},
    }
}

const Desktop = struct {
    host: *Host,
    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
};

const Host = struct {
    gpa: std.mem.Allocator,
    theme: widgets_mod.Theme,
    font: *font_mod.Font,
    shm: *wl.Shm,
    compositor: *wl.Compositor,
    desktops: [MAX_OUTPUTS]Desktop = undefined,
    desktop_count: usize = 0,
    widgets: [MAX_WIDGETS]widgets_mod.Widget = undefined,
    widget_rects: [MAX_WIDGETS]widgets_mod.Rect = undefined,
    widget_count: usize = 0,
    next_tick_ms: [MAX_WIDGETS]i64 = [_]i64{0} ** MAX_WIDGETS,
    needs_repaint: bool = false,
    hovered_index: ?usize = null,
    pointer_desktop: ?usize = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
};

fn initWidgets(host: *Host, cfg: ShellConfig) void {
    for (cfg.widget_cfgs[0..cfg.widget_count]) |wc| {
        const size = widgets_mod.cardSizeFor(wc.id, host.font);
        host.widgets[host.widget_count] = switch (wc.id) {
            .clock => .{ .clock = .{} },
            .weather => .{ .weather = .{} },
            .media => .{ .media = .{} },
            .system => .{ .system = .{} },
        };
        host.widget_rects[host.widget_count] = .{
            .x = wc.x,
            .y = wc.y,
            .w = size[0],
            .h = size[1],
        };
        host.widget_count += 1;
    }
}

/// Restricts the desktop surface's input to the union of widget rects so the
/// rest of the desktop passes clicks through to windows.
fn setInputRegion(host: *Host, d: *Desktop) void {
    const region = host.compositor.createRegion() catch return;
    defer region.destroy();
    for (0..host.widget_count) |i| {
        const r = host.widget_rects[i];
        region.add(r.x, r.y, @intCast(r.w), @intCast(r.h));
    }
    d.surface.setInputRegion(region);
}

fn paintDesktop(host: *Host, d: *Desktop) !void {
    const stride = d.width * 4; // ARGB8888
    const size: usize = @as(usize, stride) * d.height;
    if (size == 0) return;

    const fd = try posix.memfd_create("simpbar-shell-buffer", 0);
    defer _ = posix.system.close(fd);
    switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
        .SUCCESS => {},
        else => return error.FTruncateFailed,
    }
    const data = try posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(data);

    const pixels: [*]u32 = @ptrCast(@alignCast(data.ptr));
    // Clear to fully transparent — the wallpaper shows through everywhere the
    // widgets don't draw.
    @memset(pixels[0 .. d.width * d.height], 0x00000000);

    const c = widgets_mod.Canvas{
        .pixels = pixels,
        .width = d.width,
        .height = d.height,
        .font = host.font,
        .theme = &host.theme,
    };
    for (0..host.widget_count) |i| {
        const rect = host.widget_rects[i];
        const hovered = host.hovered_index == i;
        const fill = widgets_mod.withAlpha(
            if (hovered) host.theme.hover_color else host.theme.bg_color,
            host.theme.card_alpha,
        );
        c.card(rect, fill, host.theme.border_color);
        host.widgets[i].paint(c, rect);
    }

    const pool = try host.shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const buffer = try pool.createBuffer(
        0,
        @intCast(d.width),
        @intCast(d.height),
        @intCast(stride),
        .argb8888,
    );
    defer buffer.destroy();

    d.surface.attach(buffer, 0, 0);
    d.surface.damageBuffer(0, 0, @intCast(d.width), @intCast(d.height));
    d.surface.commit();
}

fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, d: *Desktop) void {
    switch (event) {
        .configure => |cfg| {
            d.layer_surface.ackConfigure(cfg.serial);
            if (cfg.width > 0) d.width = cfg.width;
            if (cfg.height > 0) d.height = cfg.height;
            if (!d.configured) {
                d.configured = true;
                setInputRegion(d.host, d);
            }
            paintDesktop(d.host, d) catch |err| {
                logging.err("draw failed: {}", .{err});
            };
        },
        .closed => std.process.exit(0),
    }
}

/// Returns true if the hovered widget changed (caller should repaint).
fn updateHover(host: *Host) bool {
    var new_hover: ?usize = null;
    for (0..host.widget_count) |i| {
        if (host.widget_rects[i].contains(host.pointer_x, host.pointer_y)) {
            new_hover = i;
            break;
        }
    }
    if (new_hover == host.hovered_index) return false;
    host.hovered_index = new_hover;
    return true;
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, host: *Host) void {
    switch (event) {
        .enter => |e| {
            for (0..host.desktop_count) |i| {
                if (host.desktops[i].surface == e.surface) {
                    host.pointer_desktop = i;
                    break;
                }
            }
            host.pointer_x = e.surface_x.toInt();
            host.pointer_y = e.surface_y.toInt();
            if (updateHover(host)) host.needs_repaint = true;
        },
        .leave => {
            host.pointer_desktop = null;
            if (host.hovered_index != null) {
                host.hovered_index = null;
                host.needs_repaint = true;
            }
        },
        .motion => |e| {
            host.pointer_x = e.surface_x.toInt();
            host.pointer_y = e.surface_y.toInt();
            if (updateHover(host)) host.needs_repaint = true;
        },
        .button => |e| {
            if (e.state != .pressed or e.button != BTN_LEFT) return;
            if (host.hovered_index) |i| {
                host.widgets[i].click(host.font, host.widget_rects[i], host.pointer_x, host.pointer_y);
                host.needs_repaint = true; // media flips control state optimistically
            }
        },
        .frame => {},
        .axis => {},
        .axis_source => {},
        .axis_stop => {},
        .axis_discrete => {},
    }
}

/// Reaps finished detached children (weather/media fetches) so they don't
/// pile up as zombies.
fn reapChildren() void {
    while (true) {
        var status: c_int = undefined;
        const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        if (pid <= 0) break;
    }
}

pub fn main() !void {
    logging.init("simpbar-shell");
    defer logging.deinit();
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    resolveConfigPaths();
    const cfg = loadConfig(gpa);
    var theme = widgets_mod.Theme{
        .card_alpha = cfg.card_bg_opacity,
        .radius_px = cfg.corner_radius,
    };
    if (tryApplyMatugenColors(gpa, &theme)) {
        logging.step("theme: applied matugen colors", .{});
    }

    var font_path_buf: [512]u8 = undefined;
    const font_path_z = fontPathZ(cfg.font_path, &font_path_buf) orelse font_mod.FONT_PATH;
    var font = font_mod.Font.init(gpa, font_path_z, FONT_PIXEL_SIZE) catch |err| blk: {
        logging.warn("font: could not load {s}: {} — falling back to {s}", .{ font_path_z, err, font_mod.FONT_PATH });
        break :blk try font_mod.Font.init(gpa, font_mod.FONT_PATH, FONT_PIXEL_SIZE);
    };
    defer font.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    setCloexec(display.getFd());

    const registry = try display.getRegistry();
    var globals = Globals{};
    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = globals.compositor orelse return error.NoCompositor;
    const shm = globals.shm orelse return error.NoShm;
    const layer_shell = globals.layer_shell orelse return error.NoLayerShell;

    if (globals.seat) |seat| {
        _ = seat;
    }

    var host = Host{
        .gpa = gpa,
        .theme = theme,
        .font = &font,
        .shm = shm,
        .compositor = compositor,
    };
    initWidgets(&host, cfg);
    logging.step("widgets: {d} placed on {d} output(s)", .{ host.widget_count, globals.output_count });

    // One desktop layer surface per output (or a single compositor-picked
    // surface if the registry reported none), anchored edge-to-edge on the
    // background layer — same level as the wallpaper, matching the
    // Event-Horizon-Shell "widgets on the desktop" concept.
    const desktop_count: usize = if (globals.output_count > 0) globals.output_count else 1;
    for (0..desktop_count) |i| {
        const surface = compositor.createSurface() catch continue;
        const output: ?*wl.Output = if (i < globals.output_count) globals.outputs[i] else null;
        const layer_surface = layer_shell.getLayerSurface(
            surface,
            output,
            .background,
            "simpbar-shell",
        ) catch {
            surface.destroy();
            continue;
        };
        layer_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer_surface.setExclusiveZone(0);
        layer_surface.setKeyboardInteractivity(.none);
        host.desktops[host.desktop_count] = .{
            .host = &host,
            .surface = surface,
            .layer_surface = layer_surface,
        };
        host.desktop_count += 1;

        // Initial empty commit so the compositor engages the layer role and
        // sends the first configure (the bar relies on the same configure
        // event to learn the surface size).
        surface.commit();

        const d = &host.desktops[host.desktop_count - 1];
        layer_surface.setListener(*Desktop, layerSurfaceListener, d);
    }
    if (host.desktop_count == 0) return error.NoSurfaceCreated;

    const pointer: ?*wl.Pointer = if (globals.seat) |seat|
        (if (globals.seat_has_pointer) seat.getPointer() catch null else null)
    else
        null;
    defer if (pointer) |p| p.release();
    if (pointer) |p| p.setListener(*Host, pointerListener, &host);

    var poll_fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // weather fetch pipe
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // media fetch pipe
    };

    while (true) {
        // Refresh the pipe fds (they change across fetch cycles).
        poll_fds[1].fd = -1;
        poll_fds[2].fd = -1;
        for (0..host.widget_count) |i| {
            switch (host.widgets[i].pollFd()) {
                -1 => {},
                else => |other_fd| {
                    if (poll_fds[1].fd < 0) {
                        poll_fds[1].fd = other_fd;
                    } else if (poll_fds[2].fd < 0) {
                        poll_fds[2].fd = other_fd;
                    }
                },
            }
        }

        _ = display.flush();

        const now = nowMs();

        // Poll with a timeout computed from the earliest widget cadence
        // deadline — the "lazy repaint" schedule from the friend's shell.
        var next_deadline: i64 = std.math.maxInt(i64);
        for (0..host.widget_count) |i| {
            next_deadline = @min(next_deadline, host.next_tick_ms[i]);
        }
        const timeout: i32 = blk: {
            if (host.widget_count == 0) break :blk -1; // nothing to wake for; wait for events only
            const rel = next_deadline - now;
            break :blk @intCast(@max(@min(rel, std.math.maxInt(i32)), 0));
        };

        const ready = posix.poll(&poll_fds, timeout) catch 0;

        if (ready > 0) {
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            if (poll_fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                for (0..host.widget_count) |i| {
                    if (host.widgets[i].onPipe()) host.needs_repaint = true;
                }
            }
            if (poll_fds[2].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                for (0..host.widget_count) |i| {
                    if (host.widgets[i].onPipe()) host.needs_repaint = true;
                }
            }
        }

        reapChildren();

        // Fire any widget cadences that came due.
        const now2 = nowMs();
        for (0..host.widget_count) |i| {
            if (now2 >= host.next_tick_ms[i]) {
                if (host.widgets[i].tick()) host.needs_repaint = true;
                host.next_tick_ms[i] = now2 + host.widgets[i].intervalMs();
            }
        }

        if (host.needs_repaint) {
            host.needs_repaint = false;
            for (0..host.desktop_count) |i| {
                paintDesktop(&host, &host.desktops[i]) catch |err| {
                    logging.err("draw failed: {}", .{err});
                };
            }
        }
    }
}
//! simpbar-shell — desktop widgets for Wayland, the Event-Horizon-Shell idea
//! rewritten in Zig.
//!
//! One full-output layer-shell surface per monitor on the `bottom` layer
//! (above the wallpaper, behind your windows, rainmeter-style), painted
//! entirely in software into wl_shm ARGB buffers. Each configured widget is
//! a small paint-only object (see widgets.zig) drawn into that shared
//! surface; the host repaints lazily — it poll()s with a timeout computed
//! from the earliest widget cadence deadline, never a fixed animation loop.
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
// 6 base widgets + 3 sticky notes = 9 ≤ 12. Only bits tell you a tile is
// stale, without scanning every widget for changes.
const MAX_WIDGETS: usize = 12;
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
    holiday_country: ?[]const u8 = null,
    holiday_region: ?[]const u8 = null,
    widgets: ?[]const JsonWidgetCfg = null,
};

const JsonMatugenColors = struct {
    bg_color: ?[]const u8 = null,
    text_color: ?[]const u8 = null,
    border_color: ?[]const u8 = null,
    hover_color: ?[]const u8 = null,
    holiday_color: ?[]const u8 = null,
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
    holiday_country: []const u8 = "AU",
    holiday_region: []const u8 = "",
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
    // Calendar below the stack (≈ 215px tall); drag anywhere with
    // Ctrl+left-click once running.
    .{ .id = .calendar, .x = 24, .y = 470 },
    // Sticky notes along the middle-left, clear of the watch (right) and the
    // weather/media/calendar stack (left column) at the 13px default font.
    .{ .id = .note1, .x = 24, .y = 700 },
    .{ .id = .note2, .x = 264, .y = 700 },
    .{ .id = .note3, .x = 504, .y = 700 },
    // The analog watch stands alone on the right — it draws its own steel
    // case instead of a frosted card.
    .{ .id = .watch, .x = 1711, .y = 24 },
};

var shell_config_path_buf: [512]u8 = undefined;
var shell_config_path: [:0]const u8 = "";
var matugen_path_buf: [512]u8 = undefined;
var matugen_path: [:0]const u8 = "";
var reminders_path_buf: [512]u8 = undefined;
var reminders_path: [:0]const u8 = "";
var notes_dir_path_buf: [512]u8 = undefined;
var notes_dir_path: [:0]const u8 = "";

// --- xkbcommon (hand-bound, like everything else in this shell) ------------

// The sticky notes translate compositor key events back into text, and only
// xkbcommon can interpret the keymap the compositor sends. The bar links it
// for the same reason; the C surface here is the four calls we need.
const xkb = struct {
    pub const Context = opaque {};
    pub const Keymap = opaque {};
    pub const State = opaque {};
    pub const CONTEXT_NO_FLAGS: c_uint = 0;
    pub const KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
    pub const KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;

    extern "c" fn xkb_context_new(flags: c_uint) ?*Context;
    extern "c" fn xkb_context_unref(ctx: ?*Context) void;
    extern "c" fn xkb_keymap_new_from_string(ctx: *Context, str: [*:0]const u8, format: c_uint, flags: c_uint) ?*Keymap;
    extern "c" fn xkb_keymap_unref(keymap: ?*Keymap) void;
    extern "c" fn xkb_state_new(keymap: *Keymap) ?*State;
    extern "c" fn xkb_state_unref(state: ?*State) void;
    extern "c" fn xkb_state_update_mask(state: *State, depressed: u32, latched: u32, locked: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) c_int;
    extern "c" fn xkb_state_key_get_utf32(state: *State, key: u32) u32;
};

var g_xkb_ctx: ?*xkb.Context = null;
var g_xkb_keymap: ?*xkb.Keymap = null;
var g_xkb_state: ?*xkb.State = null;
/// True once the compositor's keymap has been compiled — note editing won't
/// decode anything before it (and the self-test waits for it).
var g_kb_ready = false;

fn resolveConfigPaths() void {
    const home = std.mem.span(getenv("HOME") orelse return);
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o755); // EEXIST on a normal first boot — best-effort
    shell_config_path = std.fmt.bufPrintZ(&shell_config_path_buf, "{s}/shell.json", .{dir}) catch "";
    matugen_path = std.fmt.bufPrintZ(&matugen_path_buf, "{s}/matugen.json", .{dir}) catch "";
    reminders_path = std.fmt.bufPrintZ(&reminders_path_buf, "{s}/reminders.txt", .{dir}) catch "";
    notes_dir_path = std.fmt.bufPrintZ(&notes_dir_path_buf, "{s}/notes", .{dir}) catch "";
    if (notes_dir_path.len > 0) _ = posix.system.mkdir(notes_dir_path.ptr, 0o755); // sticky-note slots
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

/// The startup config, kept around so config writes (drag-persisted widget
/// positions) can round-trip every other key untouched.
var g_shell_cfg: ShellConfig = blk: {
    var c = ShellConfig{};
    for (DEFAULT_WIDGETS, 0..) |dw, i| c.widget_cfgs[i] = dw;
    c.widget_count = DEFAULT_WIDGETS.len;
    break :blk c;
};

/// Reads shell.json (missing/malformed → defaults). Read once at startup —
/// no live reload in v1.
fn loadConfig(gpa: std.mem.Allocator) ShellConfig {
    var cfg = ShellConfig{};
    for (DEFAULT_WIDGETS, 0..) |dw, i| cfg.widget_cfgs[i] = dw;
    cfg.widget_count = DEFAULT_WIDGETS.len;
    g_shell_cfg = cfg;
    if (shell_config_path.len == 0) return cfg;

    const bytes = readFileAlloc(gpa, shell_config_path) catch |err| {
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ shell_config_path, err });
        }
        return cfg;
    };
    defer gpa.free(bytes);

    // alloc_always: the default (alloc_if_needed) would leave string fields
    // pointing into `bytes`, which is freed below — a dangling holiday_country
    // then segfaults the calendar widget's configure(). Strings must outlive
    // this function (they land in cfg / g_shell_cfg for the process lifetime).
    const parsed = std.json.parseFromSliceLeaky(JsonConfig, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping defaults", .{ shell_config_path, err });
        return cfg;
    };

    if (parsed.font_path) |fp| {
        if (fp.len > 0) cfg.font_path = fp;
    }
    if (parsed.card_bg_opacity) |a| cfg.card_bg_opacity = @min(a, 100);
    if (parsed.card_corner_radius) |r| cfg.corner_radius = r;
    if (parsed.holiday_country) |hc| {
        if (hc.len > 0) cfg.holiday_country = hc;
    }
    if (parsed.holiday_region) |hr| cfg.holiday_region = hr;
    if (parsed.widgets) |ws| {
        if (ws.len == 0) {
            cfg.widget_count = 0; // explicit empty list = all widgets off
            g_shell_cfg = cfg;
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
    g_shell_cfg = cfg;
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
    if (colors.holiday_color) |hex| {
        theme.holiday_color = parseHexColor(hex) catch theme.holiday_color;
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
    seat_has_keyboard: bool = false,
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
        .capabilities => |caps| {
            globals.seat_has_pointer = caps.capabilities.pointer;
            globals.seat_has_keyboard = caps.capabilities.keyboard;
        },
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
    /// Per-widget ARGB tile cache (allocated in initWidgets, freed in
    /// main): a widget re-renders into its own tile only when its
    /// `tile_dirty` bit is set, and every frame just composites the tiles
    /// onto a fresh zero-filled surface. The watch's 6 Hz beat then costs
    /// one 190x240 repaint instead of re-rastering every widget on every
    /// output (measured: 12% -> ~3% of a core).
    tiles: [MAX_WIDGETS]?[]u32 = [_]?[]u32{null} ** MAX_WIDGETS,
    tile_dirty: u16 = 0xFFFF, // all dirty until first paint; MAX_WIDGETS ≤ 16
    hovered_index: ?usize = null,
    pointer_desktop: ?usize = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    // Sticky-note editing: the one note currently receiving keys via the
    // compositor's on_demand keyboard grab. The host owns the slot (the
    // widget owns text/caret) and the key-repeat clock.
    edit_index: ?usize = null,
    repeat_key: ?u32 = null,
    repeat_next_ms: i64 = 0,
    kb_rate: i32 = 0, // key auto-repeat from wl_keyboard.repeat_info (0 = off)
    kb_delay: i32 = 400,
    // Ctrl+drag state. A press is held pending until release so the Ctrl
    // decision survives the focus-on-click ordering (the modifiers event can
    // arrive just after the press): press+Ctrl becomes a drag, anything else
    // becomes a click on release.
    ctrl_down: bool = false,
    left_down: bool = false,
    press_index: ?usize = null,
    drag_index: ?usize = null,
    drag_off_x: i32 = 0,
    drag_off_y: i32 = 0,
    // Bezel-timer grab on the watch: press (no Ctrl) on the bezel ring
    // starts a circular turn. Angles are pointer angles about the dial
    // center (0 at 12, clockwise); the widget folds the swept angle into
    // its resting offset.
    bezel_index: ?usize = null,
    bezel_base: u8 = 0,
    bezel_last_a: f64 = 0,
    bezel_accum: f64 = 0,
};

fn initWidgets(host: *Host, cfg: ShellConfig) void {
    for (cfg.widget_cfgs[0..cfg.widget_count]) |wc| {
        const size = widgets_mod.cardSizeFor(wc.id, host.font);
        host.widgets[host.widget_count] = switch (wc.id) {
            .clock => .{ .clock = .{} },
            .weather => .{ .weather = .{} },
            .media => .{ .media = .{} },
            .system => .{ .system = .{} },
            .calendar => .{ .calendar = .{} },
            .note1 => .{ .note1 = .{} },
            .note2 => .{ .note2 = .{} },
            .note3 => .{ .note3 = .{} },
            .watch => .{ .watch = .{} },
        };
        if (wc.id == .calendar) {
            host.widgets[host.widget_count].calendar.configure(
                reminders_path,
                cfg.holiday_country,
                cfg.holiday_region,
            );
        } else switch (wc.id) {
            // Sticky notes load their text (possibly empty) from disk.
            .note1 => host.widgets[host.widget_count].note1.configure(notes_dir_path, 1),
            .note2 => host.widgets[host.widget_count].note2.configure(notes_dir_path, 2),
            .note3 => host.widgets[host.widget_count].note3.configure(notes_dir_path, 3),
            else => {},
        }
        host.widget_rects[host.widget_count] = .{
            .x = wc.x,
            .y = wc.y,
            .w = size[0],
            .h = size[1],
        };
        // Its private paint tile (see Host.tiles). OOM here can't be
        // recovered from — the widget would have nowhere to draw — so log
        // and leave the tile null; paintDesktop skips null tiles.
        const n = host.widget_count;
        host.tiles[n] = blk: {
            const area: usize = @as(usize, size[0]) * @as(usize, size[1]);
            break :blk host.gpa.alloc(u32, area) catch |err| {
                logging.err("widgets: could not allocate {s} tile: {}", .{ @tagName(wc.id), err });
                break :blk null;
            };
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

/// Applies the (possibly moved) widget rects to every output's input region.
fn refreshInputRegions(host: *Host) void {
    for (0..host.desktop_count) |i| setInputRegion(host, &host.desktops[i]);
}

/// Escapes a string into a JSON double-quoted value body.
fn jsonEscape(s: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '"' or ch == '\\') {
            if (n + 2 > out.len) return null;
            out[n] = '\\';
            out[n + 1] = ch;
            n += 2;
        } else if (ch >= 0x20) {
            if (n + 1 > out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

/// Writes shell.json with the current widget positions (after a drag),
/// round-tripping every other key from the config loaded at startup.
/// Temp file + rename so a crash mid-write can't corrupt the config.
fn saveConfig(host: *Host) void {
    if (shell_config_path.len == 0) return;

    const W = struct {
        buf: []u8,
        len: usize = 0,
        fn append(self: *@This(), s: []const u8) bool {
            if (self.len + s.len > self.buf.len) return false;
            @memcpy(self.buf[self.len..][0..s.len], s);
            self.len += s.len;
            return true;
        }
        fn appendFmt(self: *@This(), comptime fmt: []const u8, args: anytype) bool {
            const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return false;
            self.len += s.len;
            return true;
        }
    };

    var out: [8192]u8 = undefined;
    var w = W{ .buf = &out };
    // One scratch escape buffer, reused per field — each escaped value is
    // appended (copied into `out`) before the next escape overwrites it.
    var esc: [600]u8 = undefined;

    const font_esc = jsonEscape(g_shell_cfg.font_path, &esc) orelse return;
    if (!w.appendFmt(
        "{{\n  \"font_path\": \"{s}\",\n  \"card_bg_opacity\": {d},\n  \"card_corner_radius\": {d},\n",
        .{ font_esc, g_shell_cfg.card_bg_opacity, g_shell_cfg.corner_radius },
    )) return;
    const country_esc = jsonEscape(g_shell_cfg.holiday_country, &esc) orelse return;
    if (!w.appendFmt("  \"holiday_country\": \"{s}\",\n", .{country_esc})) return;
    const region_esc = jsonEscape(g_shell_cfg.holiday_region, &esc) orelse return;
    if (!w.appendFmt("  \"holiday_region\": \"{s}\",\n  \"widgets\": [\n", .{region_esc})) return;
    for (0..host.widget_count) |i| {
        const id = std.meta.activeTag(host.widgets[i]);
        const r = host.widget_rects[i];
        const tail: []const u8 = if (i + 1 == host.widget_count) "\n" else ",\n";
        if (!w.appendFmt(
            "    {{ \"id\": \"{s}\", \"x\": {d}, \"y\": {d} }}{s}",
            .{ @tagName(id), r.x, r.y, tail },
        )) return;
    }
    if (!w.append("  ]\n}\n")) return;

    var tmp_buf: [532]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{shell_config_path}) catch return;
    const raw_fd = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) {
        logging.warn("config: could not write {s}", .{tmp});
        return;
    }
    const fd: posix.fd_t = @intCast(raw_fd);
    var off: usize = 0;
    while (off < w.len) {
        const n = std.c.write(fd, out[off..w.len].ptr, w.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = posix.system.close(fd);
    if (off != w.len) {
        logging.warn("config: short write to {s}", .{tmp});
        return;
    }
    if (std.c.rename(tmp.ptr, shell_config_path.ptr) != 0) {
        logging.warn("config: could not rename {s} into place", .{tmp});
        return;
    }
    logging.step("config: saved widget positions to {s}", .{shell_config_path});
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
    // No explicit clear: a freshly ftruncate'd memfd reads as zeros, and
    // every widget pixel below is blitted from its tile — the untouched
    // background stays fully transparent.

    // 1) Re-render the tiles whose widgets asked for it (state change from
    //    tick/onPipe/click, or a frame-wide hover/theme change). A tile is
    //    widget-local: rect at (0, 0), so paint coordinates stay small.
    for (0..host.widget_count) |i| {
        const bit = @as(u16, 1) << @intCast(i);
        if ((host.tile_dirty & bit) == 0) continue;
        const tile = host.tiles[i] orelse continue;
        // Fresh backdrop every re-render — cards and glyph edges alpha-
        // blend, so leftover pixels from the previous render (or the
        // allocator's 0xAA fill pattern) would bleed through. Same reason
        // the old path memset the whole surface.
        @memset(tile, 0);
        const rect = host.widget_rects[i];
        const tc = widgets_mod.Canvas{
            .pixels = tile.ptr,
            .width = rect.w,
            .height = rect.h,
            .font = host.font,
            .theme = &host.theme,
        };
        const tr = widgets_mod.Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
        // The watch draws its own steel case — no frosted card behind it
        // (the case and bracelet ARE the widget chrome).
        if (std.meta.activeTag(host.widgets[i]) != .watch) {
            const fill = widgets_mod.withAlpha(
                if (host.hovered_index == i) host.theme.hover_color else host.theme.bg_color,
                host.theme.card_alpha,
            );
            tc.card(tr, fill, host.theme.border_color);
        }
        host.widgets[i].paint(tc, tr);
    }
    host.tile_dirty = 0;

    // 2) Composite every tile onto the fresh surface (positions come from
    //    the current rects, so drags just move the blits).
    for (0..host.widget_count) |i| {
        const tile = host.tiles[i] orelse continue;
        blitTile(pixels, d, host.widget_rects[i], tile);
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

/// Row-wise copy of a widget's tile onto the surface, clipped to it (a
/// widget may sit partially off-edge if an output shrinks under it).
fn blitTile(pixels: [*]u32, d: *Desktop, r: widgets_mod.Rect, tile: []const u32) void {
    const tw: i32 = @intCast(r.w);
    const th: i32 = @intCast(r.h);
    const sx0 = @max(0, -r.x);
    const sy0 = @max(0, -r.y);
    const sx1 = @min(tw, @as(i32, @intCast(d.width)) - r.x);
    const sy1 = @min(th, @as(i32, @intCast(d.height)) - r.y);
    if (sx1 <= sx0 or sy1 <= sy0) return;
    const dst_x: usize = @intCast(@max(r.x, 0) + sx0);
    const row_len: usize = @intCast(sx1 - sx0);
    var sy: i32 = sy0;
    while (sy < sy1) : (sy += 1) {
        const dst_y: usize = @intCast(@max(r.y, 0) + sy);
        const src_off: usize = @as(usize, @intCast(sy * tw)) + @as(usize, @intCast(sx0));
        const dst_off = dst_y * d.width + dst_x;
        @memcpy(pixels[dst_off .. dst_off + row_len], tile[src_off .. src_off + row_len]);
    }
}

/// State inside widget `i` changed (tick / fetch / click) — its tile must
/// re-render before the next frame.
fn markDirty(host: *Host, i: usize) void {
    host.needs_repaint = true;
    host.tile_dirty |= @as(u16, 1) << @intCast(i);
}

/// A frame-wide factor changed (hover highlight): every tile is stale.
fn markAllDirty(host: *Host) void {
    host.needs_repaint = true;
    host.tile_dirty = 0xFFFF;
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
            if (updateHover(host)) markAllDirty(host);
        },
        .leave => {
            host.pointer_desktop = null;
            // While a button is held the implicit grab keeps events flowing,
            // so a leave during a drag shouldn't (and normally can't) happen.
            if (host.drag_index == null and host.hovered_index != null) {
                host.hovered_index = null;
                markAllDirty(host);
            }
        },
        .motion => |e| {
            host.pointer_x = e.surface_x.toInt();
            host.pointer_y = e.surface_y.toInt();
            if (host.bezel_index) |i| {
                // Bezel turn in progress: the insert follows the pointer
                // around the dial. Tiles are position-independent here too —
                // only the bezel offset changed, so just re-render it.
                turnBezel(host, i);
            } else if (host.drag_index) |i| {
                // Ctrl+drag in progress: the card follows the pointer,
                // clamped to the output it's being moved on. Tiles are
                // position-independent — only the blit moves, so no
                // re-render is needed, just a new frame.
                const r = &host.widget_rects[i];
                r.x = host.pointer_x - host.drag_off_x;
                r.y = host.pointer_y - host.drag_off_y;
                clampWidget(host, i);
                host.hovered_index = i;
                host.needs_repaint = true;
            } else if (updateHover(host)) markAllDirty(host);
        },
        .button => |e| pointerButton(host, e.button, e.state == .pressed),
        .frame => {},
        .axis => {},
        .axis_source => {},
        .axis_stop => {},
        .axis_discrete => {},
    }
}

/// Left-button press/release over a widget — the body of the pointer
/// listener's button arm, split out so the self-test can drive the exact
/// same code path without synthesizing wl events. A press anywhere that
/// isn't the note being edited commits that note first (Plasma-style: the
/// focused-vs-clicking ordering can otherwise eat keystrokes).
fn pointerButton(host: *Host, btn: u32, pressed: bool) void {
    if (btn != BTN_LEFT) return;
    if (pressed) {
        host.left_down = true;
        host.press_index = host.hovered_index;
        if (host.edit_index) |ei| {
            const pi = host.press_index;
            if (pi == null or pi != ei) endEdit(host);
        }
        // Bezel ring (no Ctrl) starts a timer turn; anywhere else the press
        // is a move when Ctrl is known (see tryStartDrag) or a click on
        // release.
        if (!tryStartBezel(host)) tryStartDrag(host);
    } else {
        host.left_down = false;
        if (host.drag_index != null) {
            endDrag(host);
        } else if (host.bezel_index) |i| {
            host.bezel_index = null;
            // Settle with the release point, then arm (or clear).
            turnBezel(host, i);
            host.widgets[i].watch.releaseBezel(nowMs());
            markDirty(host, i);
        } else if (host.press_index) |i| {
            host.press_index = null;
            // A click is press + release over the same widget.
            if (host.widget_rects[i].contains(host.pointer_x, host.pointer_y)) {
                host.widgets[i].click(host.font, host.widget_rects[i], host.pointer_x, host.pointer_y);
                // Clicking a note opens the single-edit slot: the card took
                // on_demand keyboard focus, so the compositor will route key
                // events here. The widget owns text/caret; the host owns the
                // slot, the repeat clock, and the edit cadence.
                if (widgets_mod.noteSlot(&host.widgets[i]) != null) {
                    host.edit_index = i;
                    reschedule(host, i);
                }
                markDirty(host, i); // widgets flip state on click
            }
        }
    }
}

/// Press (no Ctrl) landed on the watch's bezel ring: start a circular
/// turn for the hidden timer instead of a click or a move. The press is
/// consumed — releasing arms the timer, it never reaches click().
fn tryStartBezel(host: *Host) bool {
    if (!host.left_down or host.ctrl_down) return false;
    if (host.drag_index != null or host.bezel_index != null) return false;
    const index = host.press_index orelse host.hovered_index orelse return false;
    if (std.meta.activeTag(host.widgets[index]) != .watch) return false;
    const r = host.widget_rects[index];
    if (!widgets_mod.WatchWidget.bezelHit(r, host.pointer_x, host.pointer_y)) return false;
    host.bezel_index = index;
    host.bezel_base = host.widgets[index].watch.bezel_min;
    host.bezel_last_a = widgets_mod.WatchWidget.pointerAngle(r, host.pointer_x, host.pointer_y);
    host.bezel_accum = 0;
    host.press_index = null; // consumed: a turn is not a click
    host.hovered_index = index;
    host.needs_repaint = true;
    return true;
}

/// Pointer moved mid bezel-turn: fold the swept angle into the widget's
/// resting offset (1 minute per 6°, clamped 0..59 there).
fn turnBezel(host: *Host, i: usize) void {
    const W = widgets_mod.WatchWidget;
    const r = host.widget_rects[i];
    const ctr = W.dialCenter(r);
    const dx = @as(f64, @floatFromInt(host.pointer_x)) - ctr[0];
    const dy = @as(f64, @floatFromInt(host.pointer_y)) - ctr[1];
    if (dx * dx + dy * dy < 16.0) return; // on the center pin — no angle
    const a = W.pointerAngle(r, host.pointer_x, host.pointer_y);
    var delta = a - host.bezel_last_a;
    while (delta > std.math.pi) : (delta -= 2 * std.math.pi) {}
    while (delta < -std.math.pi) : (delta += 2 * std.math.pi) {}
    host.bezel_last_a = a;
    host.bezel_accum += delta;
    if (host.widgets[i].watch.turnBezel(host.bezel_base, host.bezel_accum)) {
        markDirty(host, i);
    }
}

/// True when a Ctrl+drag may begin: button down, Ctrl held, no drag yet,
/// and the press landed on a widget. Never steals a bezel turn — Ctrl
/// pressed mid-turn leaves the bezel alone.
fn tryStartDrag(host: *Host) void {
    if (!host.left_down or !host.ctrl_down or host.drag_index != null) return;
    if (host.bezel_index != null) return;
    const index = host.press_index orelse host.hovered_index orelse return;
    const r = host.widget_rects[index];
    host.drag_index = index;
    host.drag_off_x = host.pointer_x - r.x;
    host.drag_off_y = host.pointer_y - r.y;
    host.press_index = null; // consumed: a drag is not a click
    host.hovered_index = index;
    markAllDirty(host); // hover highlight moved with the drag
}

/// Keeps widget `index` fully inside the output the pointer is on (surface
/// coordinates — outputs all share one position set per widget).
fn clampWidget(host: *Host, index: usize) void {
    const d = &host.desktops[host.pointer_desktop orelse 0];
    const r = &host.widget_rects[index];
    const max_x: i32 = @max(@as(i32, @intCast(d.width)) - @as(i32, @intCast(r.w)), 0);
    const max_y: i32 = @max(@as(i32, @intCast(d.height)) - @as(i32, @intCast(r.h)), 0);
    r.x = std.math.clamp(r.x, 0, max_x);
    r.y = std.math.clamp(r.y, 0, max_y);
}

/// Button released mid-drag: settle the position, re-arm the input regions
/// (they still cover the pre-drag location), and persist to shell.json.
fn endDrag(host: *Host) void {
    const index = host.drag_index orelse return;
    host.drag_index = null;
    clampWidget(host, index);
    host.needs_repaint = true;
    refreshInputRegions(host);
    saveConfig(host);
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, host: *Host) void {
    switch (event) {
        .keymap => |e| {
            // The keymap fd is ours to close once received (spec) — do that
            // no matter how far decoding gets.
            defer _ = posix.system.close(e.fd);
            if (e.format != .xkb_v1) return;
            const size: usize = e.size;
            const buf = host.gpa.alloc(u8, size + 2) catch return;
            defer host.gpa.free(buf);
            var got: usize = 0;
            while (got < size) {
                const n = posix.read(e.fd, buf[got..size]) catch break;
                if (n == 0) break;
                got += n;
            }
            if (got == 0) return;
            buf[got] = 0; // xkb wants a NUL-terminated string
            if (g_xkb_ctx == null) g_xkb_ctx = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS);
            const ctx = g_xkb_ctx orelse return;
            const km = xkb.xkb_keymap_new_from_string(ctx, buf[0..got:0], xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS) orelse return;
            const st = xkb.xkb_state_new(km) orelse {
                xkb.xkb_keymap_unref(km);
                return;
            };
            if (g_xkb_keymap) |old| xkb.xkb_keymap_unref(old);
            if (g_xkb_state) |old| xkb.xkb_state_unref(old);
            g_xkb_keymap = km;
            g_xkb_state = st;
            g_kb_ready = true;
            logging.step("keyboard: xkb keymap live ({d} bytes)", .{got});
        },
        // The compositor always follows enter with a modifiers event, so
        // focus changes need no handling of their own.
        .enter => {},
        .leave => {
            host.ctrl_down = false;
            host.repeat_key = null;
            // Editing a note then clicking a window (our surface loses the
            // on_demand focus) commits it, Plasma-style.
            endEdit(host);
        },
        .key => |e| onKeyboardKey(host, e.key, e.state == .pressed),
        .modifiers => |e| {
            // Control is real-mod index 2 in the depressed mask.
            const ctrl = e.mods_depressed & (1 << 2) != 0;
            host.ctrl_down = ctrl;
            // A press can precede this event (clicking takes focus first);
            // the moment Ctrl is known and the button is down over a widget,
            // turn the pending press into a drag.
            if (ctrl) tryStartDrag(host);
            // Keep xkb's modifier/group state in lockstep so UTF-32 decode
            // honors the actual layout (Shift for caps, group for altgr).
            if (g_xkb_state) |st| {
                _ = xkb.xkb_state_update_mask(st, e.mods_depressed, e.mods_latched, e.mods_locked, 0, 0, e.group);
            }
        },
        .repeat_info => |e| {
            // The compositor's auto-repeat parameters; we synthesize repeats
            // from them while editing (rate Hz, delay ms; rate 0 = no repeat).
            host.kb_rate = e.rate;
            host.kb_delay = e.delay;
        },
    }
}

fn onKeyboardKey(host: *Host, keycode: u32, pressed: bool) void {
    if (pressed) keyPress(host, keycode) else keyRelease(host, keycode);
}

fn keyRelease(host: *Host, keycode: u32) void {
    if (host.repeat_key == keycode) host.repeat_key = null;
}

/// Routes one keyboard press. Nothing happens unless a note is being edited;
/// the key is decoded through xkb into UTF-32 and handed to the note editor.
fn keyPress(host: *Host, keycode: u32) void {
    const i = host.edit_index orelse return;
    // Ctrl chords are ignored while editing (no text shortcuts) — except
    // Esc, which always commits.
    if (keycode != widgets_mod.KEY_ESC and host.ctrl_down) return;
    var utf32: u32 = 0;
    if (g_xkb_state) |st| utf32 = xkb.xkb_state_key_get_utf32(st, keycode + 8);
    const res = switch (host.widgets[i]) {
        .note1, .note2, .note3 => |*n| n.keyPress(widgets_mod.FontMeasure{ .font = host.font }, noteMaxW(host, i), keycode, utf32),
        else => .ignored,
    };
    switch (res) {
        .ignored => {},
        .handled => {
            markDirty(host, i);
            armRepeat(host, keycode);
            // The whole keystroke burst shouldn't wait out the idle cadence.
            reschedule(host, i);
        },
        .exited => {
            host.edit_index = null;
            host.repeat_key = null;
            host.repeat_next_ms = 0;
            reschedule(host, i);
            markDirty(host, i);
        },
    }
}

/// Text width available inside the note card (match NoteWidget.paint).
fn noteMaxW(host: *Host, i: usize) i64 {
    return @as(i64, @intCast(host.widget_rects[i].w)) - 2 * widgets_mod.CARD_PAD;
}

/// Set up compositor-style auto-repeat (rate Hz, delay ms) for the key that
/// just edited. Repeat fires through the poll deadline, not per event.
fn armRepeat(host: *Host, keycode: u32) void {
    if (host.kb_rate <= 0) return;
    host.repeat_key = keycode;
    host.repeat_next_ms = nowMs() + @max(host.kb_delay, 30);
}

/// Re-arm a widget's cadence from now (a note that starts editing, or gets
/// a key, wants its 500 ms blink/autosave ticks immediately).
fn reschedule(host: *Host, i: usize) void {
    host.next_tick_ms[i] = nowMs() + host.widgets[i].intervalMs();
}

/// Stop editing the editing note: commit (Esc / focus-leave / click
/// elsewhere) and hand the slot and key routing back.
fn endEdit(host: *Host) void {
    const i = host.edit_index orelse return;
    host.edit_index = null;
    host.repeat_key = null;
    host.repeat_next_ms = 0;
    switch (host.widgets[i]) {
        .note1, .note2, .note3 => |*n| {
            n.commit();
            n.endEditing();
        },
        else => {},
    }
    reschedule(host, i);
    markDirty(host, i);
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

// --- sticky-note self-test (SIMPBAR_SELFTEST=1) -----------------------------
// This box has no input-injection tool (wtype/ydotool/dotool absent,
// /dev/uinput needs root), so with the env var set the shell drives note1
// through the SAME pointer/keyboard code paths the compositor events take,
// verifies the persisted file, then restores the note's original text.
//   1. a synthetic press+release over note1 starts editing,
//   2. evdev key codes go through onKeyboardKey → xkb decode → NoteWidget,
//   3. Esc commits and note1.txt must contain exactly the typed text,
//   4. the original note text is written back so nothing is left behind.
var g_selftest = false;
var g_st_done = false;
var g_st_start_ms: i64 = 0;

fn runSelfTest(host: *Host) void {
    g_st_done = true;
    var slot_idx: ?usize = null;
    for (0..host.widget_count) |i| {
        if (widgets_mod.noteSlot(&host.widgets[i]) == 1) {
            slot_idx = i;
            break;
        }
    }
    const i = slot_idx orelse {
        logging.warn("selftest: config has no note1 — SKIP", .{});
        return;
    };
    const n = &host.widgets[i].note1;
    const orig_len = n.text_len;
    var orig_buf: [widgets_mod.NoteWidget.NOTE_MAX]u8 = undefined;
    @memcpy(orig_buf[0..orig_len], n.text()[0..orig_len]);
    const path = n.path();
    var failures: usize = 0;

    // Click into the note's first text line (question mark placement: the
    // card rect is known, the pointer is fake).
    const r = host.widget_rects[i];
    host.pointer_x = r.x + 40;
    host.pointer_y = r.y + 30;
    _ = updateHover(host);
    pointerButton(host, BTN_LEFT, true);
    pointerButton(host, BTN_LEFT, false);
    if (host.edit_index != i) {
        failures += 1;
        logging.err("selftest: click did not start editing (edit_index={?})", .{host.edit_index});
    }

    // Type "abc 123", backspace once, Enter, then Esc to commit. evdev key
    // codes: a=30 b=48 c=46 space=57 1=2 2=3 3=4 backspace=14 enter=28 esc=1.
    const seq = [_]u32{ 30, 48, 46, 57, 2, 3, 4, 14, 28, 1 };
    for (seq) |code| {
        onKeyboardKey(host, code, true);
        onKeyboardKey(host, code, false);
    }
    if (host.edit_index != null) {
        failures += 1;
        logging.err("selftest: Esc did not close editing", .{});
    }

    const saved = readFileAlloc(host.gpa, path) catch null;
    defer if (saved) |s| host.gpa.free(s);
    const want = "abc 12\n";
    if (saved) |s| {
        if (!std.mem.eql(u8, s, want)) {
            failures += 1;
            logging.err("selftest: note1.txt = \"{s}\", want \"{s}\"", .{ s, want });
        }
    } else {
        failures += 1;
        logging.err("selftest: could not read back {s}", .{path});
    }

    // Restore the original note (content in memory + on disk) and release
    // the edit slot so the desktop is exactly as it was.
    n.text_len = orig_len;
    @memcpy(n.text_buf[0..orig_len], orig_buf[0..orig_len]);
    n.caret = orig_len;
    n.scroll = 0;
    n.editing = false;
    n.dirty = false;
    host.edit_index = null;
    host.repeat_key = null;
    _ = widgets_mod.writeFileAtomicZ(path, orig_buf[0..orig_len]);
    reschedule(host, i);
    markDirty(host, i);

    if (failures == 0) {
        logging.step("SELFTEST PASS — note edit→commit round-trip ok (\"{s}\" saved, original restored)", .{want});
    } else {
        logging.err("SELFTEST FAIL — {d} failure(s); note restored to original", .{failures});
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
    defer for (host.tiles) |t| if (t) |buf| gpa.free(buf); // leak-check clean
    logging.step("widgets: {d} placed on {d} output(s)", .{ host.widget_count, globals.output_count });

    // One desktop layer surface per output (or a single compositor-picked
    // surface if the registry reported none), anchored edge-to-edge on the
    // bottom layer — above the wallpaper's background level, never below
    // it. Same-level layers stack by map order, so a freshly restarted
    // swaybg (every wallpaper change) would bury .background widgets under
    // the new wallpaper surface; .bottom always composites above it while
    // staying below windows and the bar.
    const desktop_count: usize = if (globals.output_count > 0) globals.output_count else 1;
    for (0..desktop_count) |i| {
        const surface = compositor.createSurface() catch continue;
        const output: ?*wl.Output = if (i < globals.output_count) globals.outputs[i] else null;
        const layer_surface = layer_shell.getLayerSurface(
            surface,
            output,
            .bottom,
            "simpbar-shell",
        ) catch {
            surface.destroy();
            continue;
        };
        layer_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer_surface.setExclusiveZone(0);
        // on_demand: clicking a card takes keyboard focus, which is the only
        // way a client sees modifier state — Ctrl+drag needs it. Focus
        // returns to the clicked window on its next click, like any other
        // on_demand surface; keys are otherwise ignored.
        layer_surface.setKeyboardInteractivity(.on_demand);
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

    // Keyboard exists purely for modifier state (Ctrl+drag); it gets focus
    // on_demand when a card is clicked.
    const keyboard: ?*wl.Keyboard = if (globals.seat) |seat|
        (if (globals.seat_has_keyboard) seat.getKeyboard() catch null else null)
    else
        null;
    defer if (keyboard) |kb| kb.release();
    if (keyboard) |kb| kb.setListener(*Host, keyboardListener, &host);

    g_selftest = getenv("SIMPBAR_SELFTEST") != null;
    if (g_selftest) logging.warn("selftest: SIMPBAR_SELFTEST set — note1 will be driven at startup", .{});
    g_st_start_ms = nowMs();

    // One poll slot per widget fetch pipe, after the display fd.
    var poll_fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
    } ++ [_]posix.pollfd{.{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }} ** MAX_WIDGETS;

    while (true) {
        // Refresh the pipe fds (they change across fetch cycles).
        for (poll_fds[1..]) |*pf| pf.fd = -1;
        for (0..host.widget_count) |i| {
            const widget_fd = host.widgets[i].pollFd();
            if (widget_fd < 0) continue;
            for (poll_fds[1..]) |*pf| {
                if (pf.fd < 0) {
                    pf.fd = widget_fd;
                    break;
                }
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
        // A held editing key needs its auto-repeat fired on schedule too.
        if (host.edit_index != null and host.repeat_key != null) {
            next_deadline = @min(next_deadline, host.repeat_next_ms);
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
            var pipe_ready = false;
            for (poll_fds[1..]) |pf| {
                if (pf.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                    pipe_ready = true;
                    break;
                }
            }
            if (pipe_ready) {
                for (0..host.widget_count) |i| {
                    if (host.widgets[i].onPipe()) markDirty(&host, i);
                }
            }
        }

        reapChildren();

        // Fire any widget cadences that came due.
        const now2 = nowMs();
        for (0..host.widget_count) |i| {
            if (now2 >= host.next_tick_ms[i]) {
                if (host.widgets[i].tick()) markDirty(&host, i);
                host.next_tick_ms[i] = now2 + host.widgets[i].intervalMs();
            }
        }

        // Hold-down auto-repeat while editing a note — synthesized from the
        // compositor's rate/delay so Backspace/arrows/repeated letters feel
        // like a native editor instead of a per-event text widget.
        if (host.edit_index != null and host.repeat_key != null and now2 >= host.repeat_next_ms) {
            keyPress(&host, host.repeat_key.?);
            host.repeat_next_ms = now2 + @max(@divTrunc(1000, @max(host.kb_rate, 1)), 10);
        }

        // Self-test: once the keymap is live, drive note1 through the exact
        // pointer/key paths the compositor events use, then verify the file.
        if (g_selftest and !g_st_done and g_kb_ready and now2 - g_st_start_ms > 800) {
            runSelfTest(&host);
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
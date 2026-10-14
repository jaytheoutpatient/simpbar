// Simpbar Config — GTK4/libadwaita GUI for configuring the bar's appearance
// and module layout, and for creating/pinning desktop shortcuts. Talks to
// GTK/libadwaita/GObject through welcome_gtk.zig's hand-written extern
// bindings, exactly like simpbar-welcome does (see that file for why
// @cImport of the real headers doesn't work here).
//
// File I/O and process control are done via hand-declared libc externs
// (open/read/write/close/mkdir/getenv), mirroring welcome_main.zig's own
// style rather than main.zig's posix.system-based one — this file has no
// existing precedent within itself, so it follows its closest sibling (the
// other GTK app) rather than the Wayland bar.
//
// The Appearance tab is real (Step 5): it reads ~/.config/simpbar/config.json
// on startup (or applies the same defaults main.zig's JsonAppearance struct
// does, if the file is missing/unparseable), lets the user edit colors and
// spacing live, and on every single change writes the full config back to
// disk and sends SIGUSR1 to the running bar (via its pidfile) so the change
// applies immediately — no separate Save button, matching the plan's
// explicit "the whole point of live-reload is instant feedback" design.
//
// Modules and Shortcuts tabs are still placeholders — later steps.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hypr = @import("hyprland.zig");
const hypr_pages = @import("hypr_pages.zig");
const mango_pages = @import("mango_pages.zig");
const logging = @import("logging.zig");
const desktop_entries = @import("desktop_entries.zig");

pub const panic = std.debug.FullPanic(logging.panicHandler);

extern "c" fn exit(code: c_int) noreturn;

const APP_ID = "dev.jaytheoutpatient.simpbar.Config";

// ---------------------------------------------------------------------
// libc externs (mirrors welcome_main.zig's own block)
// ---------------------------------------------------------------------

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
const POLLIN: i16 = 0x0001;

const libc_proc = struct {
    extern "c" fn fork() c_int;
};

const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------------
// Config schema — kept in exact lockstep with main.zig's own definitions.
// Duplicated rather than shared (these are two independent binaries; see
// the plan's explicit call not to share code across binaries beyond
// welcome_gtk.zig) — if the bar's schema ever changes, this block must
// change to match, or the two binaries will silently disagree.
// ---------------------------------------------------------------------

const ModuleKind = enum {
    workspaces,
    mpris,
    clock,
    launchers,
    power,
    drawer_toggle,
    volume,
    /// Tombstone: the old Wallpaper Button module (see main.zig's
    /// ModuleKind). Parses so old configs keep loading; never rendered,
    /// never listed, stripped from live_right on load.
    waypaper,
    pacman,
    tray,
    weather,
    cpu,
    ram,
    network,
    disk,
    battery,
    custom_script,
    cpu_temp,
    cava,
    /// Mango layout switcher (right-side only; hidden under Hyprland).
    layout,
};

// Every ModuleKind valid in the "right" group per main.zig's drawRightGroup
// switch (i.e. everything except workspaces/mpris/clock/launchers, which are
// left/center-only) — used by ModuleGroup.ensureKindsPresent so the Modules
// tab always shows every possible right-side module, not just whichever
// ones happen to already be in config.json. Keep this in sync with
// drawRightGroup's switch if a new right-side kind is ever added.
const RIGHT_MODULE_KINDS = [_]ModuleKind{
    .power, .drawer_toggle, .volume, .pacman, .tray,
    .weather, .cpu, .ram, .network, .disk,
    .battery, .custom_script, .cpu_temp, .cava, .layout,
};

// The kind set shared by the Left and Center groups. main.zig now draws
// both groups in config order for these four (the center composes them into
// centered segments; the left walks them as an ordered chain), so either
// group can accept any of them — the reason Left can host clock/launchers
// and Center can host workspaces/mpris. Right-group dynamic kinds
// (RIGHT_MODULE_KINDS) intentionally can't land in left/center, and these
// four can't land in right: the bar has no left-anchored renderer for a
// right-aligned module like volume, and no right-aligned renderer for a
// left-anchored workspaces — permitting such a drop would recreate the
// "moves in the GUI but the bar silently ignores it" trap.
const LEFT_CENTER_MODULE_KINDS = [_]ModuleKind{
    .workspaces, .mpris, .clock, .launchers,
};

const ModuleEntry = struct {
    kind: ModuleKind,
    enabled: bool = true,
    in_drawer: bool = false,
    interval_secs: ?u32 = null,
    label: ?[]const u8 = null,
    command: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

const LauncherButton = struct {
    label: []const u8,
    command: [:0]const u8,
    icon: ?[]const u8 = null,
    /// How this launcher renders in the bar: "label" (name only), "both"
    /// (name + icon, the default), or "icon" (icon only). Curated string
    /// choice shared with main.zig's renderer; anything unrecognized falls
    /// back to "both".
    display: []const u8 = "both",
};

const DEFAULT_LEFT = [_]ModuleEntry{
    .{ .kind = .workspaces, .enabled = true },
    .{ .kind = .mpris, .enabled = true },
};
const DEFAULT_CENTER = [_]ModuleEntry{
    .{ .kind = .launchers, .enabled = true },
    .{ .kind = .clock, .enabled = true },
};
const DEFAULT_RIGHT = [_]ModuleEntry{
    .{ .kind = .cava, .enabled = true },
    .{ .kind = .power, .enabled = true },
    .{ .kind = .drawer_toggle, .enabled = true },
    .{ .kind = .volume, .enabled = true, .in_drawer = true },
    .{ .kind = .pacman, .enabled = true, .in_drawer = true },
    .{ .kind = .tray, .enabled = true, .in_drawer = true },
    .{ .kind = .weather, .enabled = true },
};
const CENTER_LAUNCHERS = [_]LauncherButton{
    .{ .label = "\u{f0ac} Browser", .command = "simpbar-launch-browser" },
    .{ .label = "\u{f066f} Discord", .command = "simpbar-launch-discord" },
    .{ .label = "\u{f07c} Files", .command = "nautilus" },
    .{ .label = "\u{f120} Term", .command = "foot" },
    .{ .label = "\u{f1b6} Steam", .command = "steam" },
    .{ .label = "\u{f013} Config", .command = "simpbar-config" },
    .{ .label = "\u{f118} Welcome", .command = "simpbar-welcome" },
};

// Mirrors main.zig's CLOCK_FORMAT_* keys exactly — must agree between the
// two binaries for the JSON schema to round-trip correctly (this codebase's
// established no-shared-schema-code convention means these are duplicated,
// not imported).
const CLOCK_FORMAT_DATE_24H = "date_24h";
const CLOCK_FORMAT_TIME_24H = "time_24h";
const CLOCK_FORMAT_TIME_24H_SECONDS = "time_24h_seconds";
const CLOCK_FORMAT_TIME_12H = "time_12h";
const CLOCK_FORMAT_DATE_12H = "date_12h";

/// Same permissive-fallback treatment as validClockFormat in main.zig —
/// falls back to the default rather than erroring on an unrecognized value.
fn validClockFormatChoice(raw: []const u8) []const u8 {
    const known = [_][]const u8{
        CLOCK_FORMAT_DATE_24H, CLOCK_FORMAT_TIME_24H, CLOCK_FORMAT_TIME_24H_SECONDS,
        CLOCK_FORMAT_TIME_12H, CLOCK_FORMAT_DATE_12H,
    };
    for (known) |k| {
        if (std.mem.eql(u8, raw, k)) return k;
    }
    return CLOCK_FORMAT_DATE_24H;
}

const JsonAppearance = struct {
    bg_color: []const u8 = "#0F0F0F",
    text_color: []const u8 = "#DCDCDC",
    border_color: []const u8 = "#454545",
    hover_color: []const u8 = "#3A3A3A",
    module_bg_color: []const u8 = "#1E1E1E",
    cava_color: []const u8 = "#DCDCDC",
    workspace_active_color: []const u8 = "#DCDCDC",
    workspace_inactive_color: []const u8 = "#505050",
    popup_bg_color: []const u8 = "#262626",
    popup_hover_color: []const u8 = "#3A3A3A",
    popup_separator_color: []const u8 = "#444444",
    popup_disabled_color: []const u8 = "#707070",
    bezel_color: []const u8 = "#DCDCDC",
    matrix_color: []const u8 = "#00FF41",
    // "none" (default), "cava" or "matrix" — the bar background mode.
    // Matches main.zig's JsonAppearance.bg_mode exactly.
    bg_mode: []const u8 = "none",
    // Cava background wash strength 0-100. Matches main.zig exactly.
    cava_bg_strength: u8 = 35,
    // Matrix fall speed. Matches main.zig exactly.
    matrix_speed: u32 = 2,
    bar_height: u32 = 28,
    border_top_px: u32 = 2,
    border_bottom_px: u32 = 0,
    border_left_px: u32 = 0,
    border_right_px: u32 = 0,
    workspace_gap: i64 = 10,
    // Matches font.zig's FONT_PATH literal in main.zig exactly — config_main.zig
    // doesn't import font_mod (this binary has no Wayland/FreeType deps), so
    // the default has to be duplicated rather than referenced.
    font_path: []const u8 = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    bg_opacity_percent: u8 = 100,
    position: []const u8 = "bottom",
    // "taskbar" (default) or "dock" — see the Bar mode row. Matches
    // main.zig's JsonAppearance.bar_mode exactly.
    bar_mode: []const u8 = "taskbar",
    // Auto-hide the bar, collapsing to an edge strip. Matches main.zig's
    // JsonAppearance.auto_hide exactly.
    auto_hide: bool = false,
    corner_radius_px: u32 = 0,
    clock_format: []const u8 = "date_24h",
    // "" = compositor default (today's original single-bar behavior),
    // "all" = one bar per connected output, anything else = a specific
    // output name (main.zig falls back to "" if that name isn't currently
    // connected). Matches main.zig's Appearance.monitor exactly.
    monitor: []const u8 = "",
    // "matugen" (default) or "manual" — see the toggle in the Appearance
    // tab. Matches main.zig's JsonAppearance.auto_theme exactly.
    auto_theme: []const u8 = "matugen",
    // Command run on left-click of bare bar background. Matches main.zig's
    // JsonAppearance.empty_click_command exactly.
    //
    // There is no widget for this in the GUI, so it is round-tripped from disk
    // untouched: hand-edit it in config.json and every save here preserves it.
    // That round-trip is the whole reason this field has to exist in this
    // struct — buildConfigJson below writes an explicit field list rather than
    // re-serializing what it read, so any key absent from this struct is
    // silently deleted on the next save.
    empty_click_command: []const u8 = "",
    // Hover/active-pill animation master switch. Matches main.zig's
    // JsonAppearance.animations_enabled exactly.
    animations_enabled: bool = true,
    // "matugen" (default), "rainbow-puke" or "solid" — the hover/active
    // bezel style. Matches main.zig's JsonAppearance.bezel_style exactly.
    bezel_style: []const u8 = "matugen",
    // "rotating" (default), "breathing" or "solid" — the hover/active bezel
    // effect. Matches main.zig's JsonAppearance.bezel_effect exactly.
    bezel_effect: []const u8 = "rotating",
    module_pill_opacity: u8 = 100,
    module_border_width: u32 = 1,
    // Resting module pills on/off. Matches main.zig's
    // JsonAppearance.module_pills exactly.
    module_pills: bool = true,
    // Bezel rings on/off wherever they appear. Matches main.zig's
    // JsonAppearance.pill_borders exactly.
    pill_borders: bool = true,
};

const JsonModules = struct {
    left: []const ModuleEntry = &DEFAULT_LEFT,
    center: []const ModuleEntry = &DEFAULT_CENTER,
    right: []const ModuleEntry = &DEFAULT_RIGHT,
};

const JsonConfig = struct {
    appearance: JsonAppearance = .{},
    modules: JsonModules = .{},
    launchers: []const LauncherButton = &CENTER_LAUNCHERS,
};

// ---------------------------------------------------------------------
// Paths (resolved from $HOME at startup, same convention as main.zig/
// welcome_main.zig)
// ---------------------------------------------------------------------

var config_json_path_buf: [512]u8 = undefined;
var pidfile_path_buf: [512]u8 = undefined;
var matugen_type_path_buf: [512]u8 = undefined;
var widgets_disabled_path_buf: [512]u8 = undefined;
var shell_pidfile_path_buf: [512]u8 = undefined;
var config_json_path: [:0]const u8 = "";
var pidfile_path: [:0]const u8 = "";
// simpbar owns this small state file (NOT matugen's config.toml — matugen
// 4.2.0 ignores a `type` key there): the chosen scheme is read by
// /usr/bin/simpbar-matugen and passed to matugen as `--type`. See
// MATUGEN_TYPE_CHOICES below.
var matugen_type_path: [:0]const u8 = "";
// Per-widget on/off list (one widget id per line), written by the Appearance
// page's Desktop Widgets switches and read by simpbar-shell at startup.
// Missing file means all enabled. The GUI owns this file outright (unlike
// shell.json, which carries drag-persisted positions the GUI must never
// rewrite), so a full rewrite on every toggle is safe.
var widgets_disabled_path: [:0]const u8 = "";
// simpbar-shell's pidfile (written by the shell itself, same convention as
// the bar's simpbar.pid) so a widget toggle can restart it.
var shell_pidfile_path: [:0]const u8 = "";

fn resolvePaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    var dir_buf: [480]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = mkdir(dir.ptr, 0o755);
    config_json_path = std.fmt.bufPrintZ(&config_json_path_buf, "{s}/config.json", .{dir}) catch "";
    pidfile_path = std.fmt.bufPrintZ(&pidfile_path_buf, "{s}/simpbar.pid", .{dir}) catch "";
    matugen_type_path = std.fmt.bufPrintZ(&matugen_type_path_buf, "{s}/matugen-type", .{dir}) catch "";
    widgets_disabled_path = std.fmt.bufPrintZ(&widgets_disabled_path_buf, "{s}/widgets-disabled", .{dir}) catch "";
    shell_pidfile_path = std.fmt.bufPrintZ(&shell_pidfile_path_buf, "{s}/simpbar-shell.pid", .{dir}) catch "";
}

// ---------------------------------------------------------------------
// File I/O helpers
// ---------------------------------------------------------------------

/// gpa-backed whole-file read for short-lived data (the pidfile) that
/// doesn't need to outlive the call that reads it.
fn readFileAll(path: [:0]const u8) ?[]u8 {
    if (path.len == 0) return null;
    const fd = open(path, 0, 0); // O_RDONLY
    if (fd < 0) return null;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch break;
        if (list.items.len > 8 * 1024 * 1024) break;
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// Allocator-parameterized whole-file read for config.json specifically —
/// reads into `allocator` (the persistent config_arena below) so that
/// std.json's parsed strings, some of which may reference this buffer
/// directly rather than copying it, stay valid for as long as the arena
/// does (i.e. for the rest of this process's life). Using gpa + freeing
/// afterward here would risk dangling slices, the same hazard main.zig's
/// own loadConfigFromFile avoids by reading into its own parse arena.
fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    if (path.len == 0) return error.NoPath;
    const fd = open(path, 0, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try list.appendSlice(allocator, chunk[0..@intCast(n)]);
        if (list.items.len > 1024 * 1024) break;
    }
    return list.toOwnedSlice(allocator);
}

fn writeFileAll(path: [:0]const u8, data: []const u8) bool {
    if (path.len == 0) return false;
    const fd = open(path, 1 | O_CREAT | O_TRUNC, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return false;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Runs argv[0] (searched via $PATH through /usr/bin/env) and captures its
/// stdout, blocking up to timeout_ms. Mirrors welcome_main.zig's own
/// runCaptured — that file isn't shared with this one beyond welcome_gtk.zig,
/// so this is a deliberate duplicate, not a divergent reimplementation.
fn runCaptured(argv: []const [:0]const u8, timeout_ms: i32) ?[]u8 {
    if (argv.len == 0 or argv.len > 14) return null;
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return null;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const pid = libc_proc.fork();
    if (pid < 0) {
        _ = close(read_fd);
        _ = close(write_fd);
        return null;
    }
    if (pid == 0) {
        _ = close(read_fd);
        _ = dup2(write_fd, 1); // STDOUT_FILENO
        _ = close(write_fd);
        var buf: [16]?[*:0]const u8 = undefined;
        buf[0] = "/usr/bin/env";
        for (argv, 0..) |a, i| buf[i + 1] = a;
        buf[argv.len + 1] = null;
        _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
        std.c._exit(127);
    }
    _ = close(write_fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    var timed_out = false;
    while (true) {
        var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
        const pr = poll(&pfd, 1, timeout_ms);
        if (pr <= 0) {
            timed_out = true;
            break;
        }
        const n = read(read_fd, &chunk, chunk.len);
        if (n <= 0) break; // EOF or error
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            timed_out = true;
            break;
        };
        if (list.items.len > 2 * 1024 * 1024) break; // sanity cap
    }
    _ = close(read_fd);

    if (timed_out) {
        _ = std.c.kill(pid, .KILL);
        var status: c_int = undefined;
        _ = std.c.waitpid(pid, &status, 0);
        list.deinit(gpa);
        return null;
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    return list.toOwnedSlice(gpa) catch null;
}

// ---------------------------------------------------------------------
// Hex <-> GdkRGBA conversion
// ---------------------------------------------------------------------

fn hexToRgba(hex: []const u8) ?gtk.GdkRGBA {
    if (hex.len != 7 or hex[0] != '#') return null;
    const v = std.fmt.parseInt(u32, hex[1..7], 16) catch return null;
    return .{
        .red = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0,
        .green = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0,
        .blue = @as(f32, @floatFromInt(v & 0xFF)) / 255.0,
        .alpha = 1.0,
    };
}

fn rgbaToHex(c: gtk.GdkRGBA, buf: []u8) []const u8 {
    const clamp = std.math.clamp;
    const r: u32 = @intFromFloat(@round(clamp(c.red, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp(c.green, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp(c.blue, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch "#000000";
}

// ---------------------------------------------------------------------
// Live in-memory config state
// ---------------------------------------------------------------------

const ColorField = enum { bg, text, border, hover, module_bg, cava, ws_active, ws_inactive, popup_bg, popup_hover, popup_separator, popup_disabled, bezel, matrix };

const ColorSpec = struct {
    field: ColorField,
    default_hex: []const u8,
    title: [:0]const u8,
    group: enum { bar, popup },
};

// Order matches JsonAppearance's field order — kept parallel deliberately
// so index-by-declaration-order stays easy to eyeball against main.zig.
const COLOR_SPECS = [_]ColorSpec{
    .{ .field = .bg, .default_hex = "#0F0F0F", .title = "Background", .group = .bar },
    .{ .field = .text, .default_hex = "#DCDCDC", .title = "Text", .group = .bar },
    .{ .field = .border, .default_hex = "#454545", .title = "Border", .group = .bar },
    .{ .field = .hover, .default_hex = "#3A3A3A", .title = "Hover Highlight", .group = .bar },
    .{ .field = .module_bg, .default_hex = "#1E1E1E", .title = "Module Background", .group = .bar },
    .{ .field = .cava, .default_hex = "#DCDCDC", .title = "Audio Visualizer (cava)", .group = .bar },
    .{ .field = .ws_active, .default_hex = "#DCDCDC", .title = "Active Workspace", .group = .bar },
    .{ .field = .ws_inactive, .default_hex = "#505050", .title = "Inactive Workspace", .group = .bar },
    .{ .field = .popup_bg, .default_hex = "#262626", .title = "Popup Background", .group = .popup },
    .{ .field = .popup_hover, .default_hex = "#3A3A3A", .title = "Popup Hover", .group = .popup },
    .{ .field = .popup_separator, .default_hex = "#444444", .title = "Popup Separator", .group = .popup },
    .{ .field = .popup_disabled, .default_hex = "#707070", .title = "Popup Disabled Text", .group = .popup },
    .{ .field = .bezel, .default_hex = "#DCDCDC", .title = "Bezel Color", .group = .bar },
    .{ .field = .matrix, .default_hex = "#00FF41", .title = "Matrix Rain", .group = .bar },
};

var live_color_values: [COLOR_SPECS.len]gtk.GdkRGBA = undefined;
var live_bar_height: u32 = 28;
var live_border_top_px: u32 = 2;
var live_border_bottom_px: u32 = 0;
var live_border_left_px: u32 = 0;
var live_border_right_px: u32 = 0;
var live_workspace_gap: i64 = 10;
var live_bg_opacity_percent: u8 = 100;
var live_corner_radius_px: u32 = 0;
// "top" or "bottom", always a static string literal (never arena-backed),
// so — like live_font_path's own note about avoiding self-referential
// hazards — reassigning this outright on every change is always safe.
var live_position: []const u8 = "bottom";
// "taskbar" or "dock", always a static literal like live_position.
var live_bar_mode: []const u8 = "taskbar";
// Auto-hide on/off.
var live_auto_hide: bool = false;
// Same "always a static string literal, safe to reassign outright" note as
// live_position above.
var live_clock_format: []const u8 = "date_24h";
// Backed by config_arena (never reset during this GUI's single run, unlike
// main.zig's per-reload double buffer — see loadConfigFromDisk), so a plain
// slice is stable for the process's life. Reassigned outright (not copied
// into a fixed buffer) when the font dropdown's selection changes, since
// unlike ModuleRow/LauncherRow this isn't part of a struct that ever gets
// copied by value — no self-referential-pointer hazard here.
var live_font_path: []const u8 = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf";
// "", "all", or a specific monitor name — every possible source (a static
// literal for the fixed "Compositor Default"/"All Monitors" entries, a
// discovered-monitor-name buffer in monitor_entries, or an arena-backed
// value parsed from config.json) is stable for this GUI's process lifetime,
// so reassigning this outright is always safe, same reasoning as
// live_font_path above.
var live_monitor: []const u8 = "";
// "matugen" or "manual", always a static string literal (never arena-backed),
// so — like live_position's own note about avoiding self-referential
// hazards — reassigning this outright on every toggle is always safe.
var live_auto_theme: []const u8 = "matugen";
// Hover/active-pill animation master switch (static literals, same safe
// reassignment as live_auto_theme).
var live_animations_enabled: bool = true;
// Bezel style, one of BEZEL_STYLE_CHOICES below (static literals).
var live_bezel_style: []const u8 = "matugen";
// Bezel effect, one of BEZEL_EFFECT_CHOICES below (static literals).
var live_bezel_effect: []const u8 = "rotating";
// Bar background mode, one of BG_MODE_CHOICES below (static literals).
var live_bg_mode: []const u8 = "none";
// Cava background wash strength 0-100.
var live_cava_bg_strength: u8 = 35;
// Matrix fall speed, pixels per tick.
var live_matrix_speed: u32 = 2;
// Resting pill opacity 0-100.
var live_module_pill_opacity: u8 = 100;
// Bezel outline thickness in px.
var live_module_border_width: u32 = 1;
// Resting module pills on/off.
var live_module_pills: bool = true;
// Bezel rings on/off wherever they appear.
var live_pill_borders: bool = true;
// Arena-backed from config.json and stable for this GUI's process lifetime,
// same reasoning as live_monitor (which is also assigned straight from a
// parsed value) — so assigning it outright on load is safe. No widget edits
// it; it's carried through saves untouched.
var live_empty_click_command: []const u8 = "";
// matugen scheme type (one of MATUGEN_TYPE_CHOICES), always a static literal
// like live_auto_theme above. Loaded from ~/.config/simpbar/matugen-type;
// defaults to matugen's own default when that file is absent.
var live_matugen_type: []const u8 = "scheme-tonal-spot";
// Desktop widgets on/off, one bit per WIDGET_TABLE row below (bit i =
// row i). Lives outside config.json in the widgets-disabled file; default
// zero (missing file means all enabled).
var live_disabled_mask: u8 = 0;

// Module lists (Step 6) — each group is a small fixed-capacity mutable
// array, not a read-only slice into config_arena, since Modules-tab rows
// mutate entries in place (toggling a switch; for custom_script rows,
// editing label/command/interval). A ModuleRow's label/command point into
// its OWN fixed buffers rather than config_arena, since user-typed text was
// never something std.json parsed — this is self-referential but safe
// because every ModuleRow lives at a fixed address in its group's array for
// the rest of the process's life and is never copied by value after load()
// (widget callbacks are handed `&group.rows[i]` directly as GObject
// user_data, so the row itself IS the mutable state — no separate
// group+index context struct needed).
const MAX_MODULES = 24;
const MAX_ROW_TEXT = 256;

const ModuleRow = struct {
    entry: ModuleEntry = .{ .kind = .clock },
    label_buf: [MAX_ROW_TEXT]u8 = undefined,
    command_buf: [MAX_ROW_TEXT]u8 = undefined,
};

const ModuleGroup = struct {
    rows: [MAX_MODULES]ModuleRow = undefined,
    len: usize = 0,

    fn load(self: *ModuleGroup, src: []const ModuleEntry) void {
        if (src.len > self.rows.len) {
            logging.warn("config: more than {d} modules in one group, dropping the rest", .{self.rows.len});
        }
        self.len = @min(src.len, self.rows.len);
        for (0..self.len) |i| {
            // Build directly in self.rows[i] rather than a local `var row`
            // that gets copied in afterward — copying a ModuleRow by value
            // preserves label_buf/command_buf's bytes but NOT the
            // entry.label/entry.command slice pointers, which would still
            // point at the (now out-of-scope) local's buffers instead of
            // the destination's, a dangling-pointer bug that showed up as
            // garbage text in the GUI. Writing through self.rows[i] keeps
            // every pointer aimed at its own final, stable storage.
            self.rows[i] = .{ .entry = src[i] };
            if (src[i].label) |l| {
                const n = @min(l.len, self.rows[i].label_buf.len);
                @memcpy(self.rows[i].label_buf[0..n], l[0..n]);
                self.rows[i].entry.label = self.rows[i].label_buf[0..n];
            }
            if (src[i].command) |c| {
                const n = @min(c.len, self.rows[i].command_buf.len);
                @memcpy(self.rows[i].command_buf[0..n], c[0..n]);
                self.rows[i].entry.command = self.rows[i].command_buf[0..n];
            }
        }
    }

    /// Re-points every row's self-referential entry.label/entry.command
    /// slices at that row's OWN (post-move) label_buf/command_buf — the
    /// same dangling-pointer hazard load() guards against, but triggered
    /// by moveRow() copying whole ModuleRow structs between array slots
    /// during a drag-and-drop reorder (the struct's bytes move correctly,
    /// but a slice's pointer field doesn't retarget itself). Cheap and
    /// always-safe to call after any array-level move: the slice's `len`
    /// already survived the copy correctly, so this only ever needs to
    /// re-derive `ptr` from the row's own buffer.
    fn fixupPointers(self: *ModuleGroup) void {
        for (self.rows[0..self.len]) |*row| {
            if (row.entry.label) |l| row.entry.label = row.label_buf[0..l.len];
            if (row.entry.command) |c| row.entry.command = row.command_buf[0..c.len];
        }
    }

    /// Appends a synthetic, disabled placeholder row for any of `kinds` not
    /// already present in this group. Without this, a module kind that was
    /// never actually added to config.json (e.g. cpu/battery/cpu_temp — none
    /// of which are in DEFAULT_RIGHT) is simply invisible in the Modules
    /// tab, with no way to discover or enable it there at all — exactly the
    /// bug the user hit ("the cpu/uptime modules disappeared") after I reset
    /// their config.json back to plain defaults during an earlier cleanup:
    /// those modules never went away, they just had no path back into the
    /// GUI once removed from the file. Calling this after load() makes every
    /// valid kind for a group always visible/toggleable regardless of what's
    /// actually saved yet. Silently stops adding once MAX_MODULES is hit
    /// (won't happen at the group sizes actually in play here).
    fn ensureKindsPresent(self: *ModuleGroup, kinds: []const ModuleKind) void {
        for (kinds) |kind| {
            var found = false;
            for (self.rows[0..self.len]) |*row| {
                if (row.entry.kind == kind) {
                    found = true;
                    break;
                }
            }
            if (found or self.len >= self.rows.len) continue;
            self.rows[self.len] = .{ .entry = .{ .kind = kind, .enabled = false } };
            self.len += 1;
        }
    }

    /// Moves the row at `from` to end up at final index `to`, shifting
    /// everything between by one to fill the gap — the backing-array half
    /// of a drag-and-drop reorder (the caller still has to rebuild the
    /// GtkListBox's visual rows to match).
    fn moveRow(self: *ModuleGroup, from: usize, to: usize) void {
        if (from >= self.len or to >= self.len or from == to) return;
        const moved = self.rows[from];
        if (from < to) {
            var k = from;
            while (k < to) : (k += 1) self.rows[k] = self.rows[k + 1];
        } else {
            var k = from;
            while (k > to) : (k -= 1) self.rows[k] = self.rows[k - 1];
        }
        self.rows[to] = moved;
        self.fixupPointers();
    }

    /// Removes and returns the row at `idx`, shifting everything after it
    /// down by one — the half of a cross-group drag where the source group
    /// gives up the row. Returns the full row by value so the caller can
    /// hand it to the destination group's insertAt (a ModuleRow's
    /// self-referential label/command slices travel with the struct; the
    /// destination's fixupPointers then re-points them at ITS OWN copy of
    /// the buffers, exactly as load() does for a fresh module).
    fn removeAt(self: *ModuleGroup, idx: usize) ?ModuleRow {
        if (idx >= self.len) return null;
        const removed = self.rows[idx];
        var k = idx;
        while (k + 1 < self.len) : (k += 1) self.rows[k] = self.rows[k + 1];
        self.len -= 1;
        self.fixupPointers();
        return removed;
    }

    /// Inserts `row` at index `idx` (clamped to len; appends when idx >=
    /// len), shifting everything at and after it up by one. No-op returns
    /// false if the group is already full. The inserted row's slices are
    /// re-pointed at this group's own buffer copy by fixupPointers — the
    /// insertion-side half of a cross-group drag.
    fn insertAt(self: *ModuleGroup, idx_in: usize, row: ModuleRow) bool {
        if (self.len >= self.rows.len) return false;
        const idx = @min(idx_in, self.len);
        var k = self.len;
        while (k > idx) : (k -= 1) self.rows[k] = self.rows[k - 1];
        self.rows[idx] = row;
        self.len += 1;
        self.fixupPointers();
        return true;
    }

    /// Finds `ptr`'s index within this group's OWN rows array, or null if
    /// it belongs to a different group (a cross-group drag, rejected — see
    /// onModuleDrop) or is stale (points past the current .len).
    fn indexOf(self: *const ModuleGroup, ptr: *const ModuleRow) ?usize {
        const base = @intFromPtr(&self.rows[0]);
        const addr = @intFromPtr(ptr);
        if (addr < base) return null;
        const offset = addr - base;
        const elem_size = @sizeOf(ModuleRow);
        if (offset % elem_size != 0) return null;
        const idx = offset / elem_size;
        if (idx >= self.len) return null;
        return idx;
    }
};

var live_left: ModuleGroup = .{};
var live_center: ModuleGroup = .{};
var live_right: ModuleGroup = .{};

// Launchers (Step 8: the Shortcuts tab's "Pin to Bar" appends to this).
// Unlike ModuleRow, a LauncherRow does NOT store a LauncherButton with
// self-referential label/command/icon slices — it stores only the raw
// buffers and derives a fresh LauncherButton view on demand via .button().
// This sidesteps the whole dangling-pointer hazard class ModuleGroup.load()/
// fixupPointers() has to guard against (copying a struct that contains a
// slice pointing at ITS OWN other field, by value, leaves the pointer aimed
// at the old address) by construction: there's no persisted slice field
// that a copy could leave stale, since every access re-reads self's own
// current address at call time.
const MAX_LAUNCHERS = 32;

/// Per-launcher bar rendering choice (the Shortcuts tab's Pinned Launchers
/// dropdown): name only, name + icon, or icon only. The value round-trips
/// through config.json's launcher `display` field, which main.zig's
/// renderer interprets the same way — the labels here are what the dropdown
/// shows, and index order matches DISPLAY_CHOICES.
const DISPLAY_CHOICES = [_][]const u8{ "label", "both", "icon" };
const DISPLAY_LABELS = [_][*:0]const u8{ "Name", "Name + icon", "Icon" };

/// Maps a launcher's stored `display` value to its DISPLAY_CHOICES index
/// (unrecognized → "both"). Mirrors main.zig's permissive, default-falling
/// handling of curated string config fields.
fn displayIndex(display: []const u8) c_uint {
    for (DISPLAY_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, display, choice)) return @intCast(i);
    }
    return 1; // "both"
}

const LauncherRow = struct {
    label_buf: [MAX_ROW_TEXT]u8 = undefined,
    label_len: usize = 0,
    // +1: LauncherButton.command is [:0]const u8 (main.zig's Action.spawn
    // needs a real null-terminated string), so this buffer always carries
    // its own sentinel byte at command_buf[command_len].
    command_buf: [MAX_ROW_TEXT + 1]u8 = undefined,
    command_len: usize = 0,
    icon_buf: [MAX_ROW_TEXT]u8 = undefined,
    icon_len: usize = 0,
    has_icon: bool = false,
    // DISPLAY_CHOICES index ("label"/"both"/"icon") — stored by index so the
    // whole struct stays a plain value copy (no slice ownership to fix up),
    // and 1 ("both") is the default for rows that never had a choice.
    display_idx: usize = 1,

    fn button(self: *const LauncherRow) LauncherButton {
        return .{
            .label = self.label_buf[0..self.label_len],
            .command = self.command_buf[0..self.command_len :0],
            .icon = if (self.has_icon) self.icon_buf[0..self.icon_len] else null,
            .display = DISPLAY_CHOICES[self.display_idx],
        };
    }

    fn setDisplay(self: *LauncherRow, idx: c_uint) void {
        if (idx < DISPLAY_CHOICES.len) self.display_idx = idx;
    }
};

const LauncherGroup = struct {
    rows: [MAX_LAUNCHERS]LauncherRow = undefined,
    len: usize = 0,

    fn setLabel(self: *LauncherGroup, i: usize, s: []const u8) void {
        const n = @min(s.len, self.rows[i].label_buf.len);
        @memcpy(self.rows[i].label_buf[0..n], s[0..n]);
        self.rows[i].label_len = n;
    }

    fn setCommand(self: *LauncherGroup, i: usize, s: []const u8) void {
        const n = @min(s.len, self.rows[i].command_buf.len - 1);
        @memcpy(self.rows[i].command_buf[0..n], s[0..n]);
        self.rows[i].command_buf[n] = 0;
        self.rows[i].command_len = n;
    }

    fn setIcon(self: *LauncherGroup, i: usize, s: []const u8) void {
        const n = @min(s.len, self.rows[i].icon_buf.len);
        @memcpy(self.rows[i].icon_buf[0..n], s[0..n]);
        self.rows[i].icon_len = n;
        self.rows[i].has_icon = true;
    }

    fn load(self: *LauncherGroup, src: []const LauncherButton) void {
        if (src.len > self.rows.len) {
            logging.warn("config: more than {d} launchers, dropping the rest", .{self.rows.len});
        }
        self.len = @min(src.len, self.rows.len);
        for (0..self.len) |i| {
            self.rows[i] = .{};
            self.setLabel(i, src[i].label);
            self.setCommand(i, src[i].command);
            if (src[i].icon) |ic| self.setIcon(i, ic);
            self.rows[i].setDisplay(displayIndex(src[i].display));
        }
    }

    /// Appends a new pinned launcher (Shortcuts tab's "Pin to Bar"). Returns
    /// false (no-op) once MAX_LAUNCHERS is reached.
    fn append(self: *LauncherGroup, label: []const u8, command: []const u8, icon: ?[]const u8, display_idx: c_uint) bool {
        if (self.len >= self.rows.len) return false;
        const i = self.len;
        self.rows[i] = .{};
        self.setLabel(i, label);
        self.setCommand(i, command);
        if (icon) |ic| self.setIcon(i, ic);
        self.rows[i].setDisplay(display_idx);
        self.len += 1;
        return true;
    }

    /// True if any pinned launcher already runs the same command — the "Pin
    /// to Bar" flow should never create duplicates (a retried click on the
    /// same app, two .desktop files wrapping the same Exec, ...).
    fn hasCommand(self: *const LauncherGroup, command: []const u8) bool {
        for (self.rows[0..self.len]) |*row| {
            if (std.mem.eql(u8, row.button().command, command)) return true;
        }
        return false;
    }

    /// Removes the launcher at index i, sliding all later rows down. Unpin
    /// button on the Shortcuts tab's Pinned Launchers list.
    fn removeAt(self: *LauncherGroup, i: usize) void {
        if (i >= self.len) return;
        self.len -= 1;
        for (i..self.len) |k| {
            self.rows[k] = self.rows[k + 1];
        }
        self.rows[self.len] = .{}; // drop the stale duplicate
    }
};

var live_launchers: LauncherGroup = .{};

// Backs every string live_modules_*/live_launchers may point into after a
// successful parse. Never reset — this GUI parses config.json exactly once
// per run (at startup), so the arena just needs to outlive the process.
var config_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var config_loaded = false;

fn loadConfigFromDisk() void {
    if (config_loaded) return;
    config_loaded = true;
    resolvePaths();
    logging.step("config: loading {s}", .{config_json_path});

    const allocator = config_arena.allocator();
    var parsed: JsonConfig = .{};
    if (readFileAlloc(allocator, config_json_path)) |bytes| {
        parsed = std.json.parseFromSliceLeaky(JsonConfig, allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| blk: {
            logging.warn("config: could not parse {s}: {} (using defaults)", .{ config_json_path, err });
            break :blk JsonConfig{};
        };
    } else |err| {
        logging.warn("config: could not read {s}: {} (using defaults)", .{ config_json_path, err });
    }

    const j = parsed.appearance;
    const hexes = [_][]const u8{
        j.bg_color,                    j.text_color,
        j.border_color,                j.hover_color,
        j.module_bg_color,             j.cava_color,
        j.workspace_active_color,
        j.workspace_inactive_color,
        j.popup_bg_color,              j.popup_hover_color,
        j.popup_separator_color,       j.popup_disabled_color,
        j.bezel_color,                 j.matrix_color,
    };
    for (hexes, 0..) |hex, i| {
        live_color_values[i] = hexToRgba(hex) orelse hexToRgba(COLOR_SPECS[i].default_hex).?;
    }
    live_bar_height = j.bar_height;
    live_border_top_px = j.border_top_px;
    live_border_bottom_px = j.border_bottom_px;
    live_border_left_px = j.border_left_px;
    live_border_right_px = j.border_right_px;
    live_workspace_gap = j.workspace_gap;
    live_font_path = j.font_path;
    live_bg_opacity_percent = @min(j.bg_opacity_percent, 100);
    live_corner_radius_px = j.corner_radius_px;
    live_position = if (std.mem.eql(u8, j.position, "top")) "top" else "bottom";
    live_bar_mode = if (std.mem.eql(u8, j.bar_mode, "dock")) "dock" else "taskbar";
    live_auto_hide = j.auto_hide;
    live_clock_format = validClockFormatChoice(j.clock_format);
    live_monitor = j.monitor;
    live_auto_theme = if (std.mem.eql(u8, j.auto_theme, "manual")) "manual" else "matugen";
    live_empty_click_command = j.empty_click_command;
    live_animations_enabled = j.animations_enabled;
    live_bezel_style = if (std.mem.eql(u8, j.bezel_style, "rainbow-puke")) "rainbow-puke" else if (std.mem.eql(u8, j.bezel_style, "solid")) "solid" else "matugen";
    live_bezel_effect = if (std.mem.eql(u8, j.bezel_effect, "breathing")) "breathing" else if (std.mem.eql(u8, j.bezel_effect, "solid")) "solid" else "rotating";
    live_bg_mode = if (std.mem.eql(u8, j.bg_mode, "cava")) "cava" else if (std.mem.eql(u8, j.bg_mode, "matrix")) "matrix" else "none";
    live_cava_bg_strength = @min(j.cava_bg_strength, 100);
    live_matrix_speed = std.math.clamp(j.matrix_speed, 1, 6);
    live_module_pill_opacity = @min(j.module_pill_opacity, 100);
    live_module_border_width = @min(j.module_border_width, 8);
    live_module_pills = j.module_pills;
    live_pill_borders = j.pill_borders;
    // Scheme type lives in its own simpbar-owned file (not config.json, not
    // matugen's config.toml — see matugen_type_path). Ignore anything that
    // isn't a known matugen --type value rather than handing matugen junk.
    if (readFileAll(matugen_type_path)) |raw| {
        defer gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        for (MATUGEN_TYPE_CHOICES) |choice| {
            if (std.mem.eql(u8, choice, trimmed)) {
                live_matugen_type = choice;
                break;
            }
        }
    }
    // Per-widget on/off list is separate from config.json (see
    // widgets_disabled_path).
    live_disabled_mask = loadDisabledMask();

    live_left.load(parsed.modules.left);
    live_center.load(parsed.modules.center);
    live_right.load(parsed.modules.right);
    live_left.ensureKindsPresent(&LEFT_CENTER_MODULE_KINDS);
    live_center.ensureKindsPresent(&LEFT_CENTER_MODULE_KINDS);
    live_right.ensureKindsPresent(&RIGHT_MODULE_KINDS);
    // Drop tombstoned entries (see ModuleKind.waypaper): the bar skips them
    // when rendering, and leaving them in live_right would rewrite them back
    // into config.json on every save. Filtering here (rather than in load())
    // keeps load() a faithful copy and puts the migration where the other
    // kind-list repair already lives.
    stripRemovedKinds(&live_right);
    live_launchers.load(parsed.launchers);
}

/// Removes entries whose kind was retired (see ModuleKind.waypaper) from a
/// loaded group, in place, preserving order. Pure group surgery (no GUI
/// calls) so tests can pin it.
fn stripRemovedKinds(group: *ModuleGroup) void {
    var w: usize = 0;
    while (w < group.len) {
        if (group.rows[w].entry.kind == .waypaper) {
            _ = group.removeAt(w);
        } else {
            w += 1;
        }
    }
}

// ---------------------------------------------------------------------
// JSON serialization — hand-formatted rather than std.json.Stringify,
// matching main.zig's/welcome_main.zig's shared avoidance of the reworked
// std.Io.Writer surface those APIs route through.
// ---------------------------------------------------------------------

fn appendJsonString(list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try list.appendSlice(gpa, esc);
                } else {
                    try list.append(gpa, c);
                }
            },
        }
    }
    try list.append(gpa, '"');
}

fn appendJsonOptString(list: *std.ArrayList(u8), s: ?[]const u8) !void {
    if (s) |v| try appendJsonString(list, v) else try list.appendSlice(gpa, "null");
}

fn appendJsonInt(list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(gpa, text);
}

fn appendJsonOptU32(list: *std.ArrayList(u8), v: ?u32) !void {
    if (v) |x| try appendJsonInt(list, u32, x) else try list.appendSlice(gpa, "null");
}

fn appendModuleEntry(list: *std.ArrayList(u8), e: ModuleEntry) !void {
    try list.appendSlice(gpa, "{\"kind\":");
    try appendJsonString(list, @tagName(e.kind));
    try list.appendSlice(gpa, ",\"enabled\":");
    try list.appendSlice(gpa, if (e.enabled) "true" else "false");
    try list.appendSlice(gpa, ",\"in_drawer\":");
    try list.appendSlice(gpa, if (e.in_drawer) "true" else "false");
    try list.appendSlice(gpa, ",\"interval_secs\":");
    try appendJsonOptU32(list, e.interval_secs);
    try list.appendSlice(gpa, ",\"label\":");
    try appendJsonOptString(list, e.label);
    try list.appendSlice(gpa, ",\"command\":");
    try appendJsonOptString(list, e.command);
    try list.appendSlice(gpa, ",\"mode\":");
    try appendJsonOptString(list, e.mode);
    try list.appendSlice(gpa, ",\"path\":");
    try appendJsonOptString(list, e.path);
    try list.append(gpa, '}');
}

fn appendModuleGroup(list: *std.ArrayList(u8), group: *const ModuleGroup) !void {
    try list.append(gpa, '[');
    for (group.rows[0..group.len], 0..) |row, i| {
        if (i != 0) try list.append(gpa, ',');
        try appendModuleEntry(list, row.entry);
    }
    try list.append(gpa, ']');
}

fn appendLauncherButton(list: *std.ArrayList(u8), b: LauncherButton) !void {
    try list.appendSlice(gpa, "{\"label\":");
    try appendJsonString(list, b.label);
    try list.appendSlice(gpa, ",\"command\":");
    try appendJsonString(list, b.command);
    try list.appendSlice(gpa, ",\"icon\":");
    try appendJsonOptString(list, b.icon);
    try list.appendSlice(gpa, ",\"display\":");
    try appendJsonString(list, b.display);
    try list.append(gpa, '}');
}

fn appendLaunchers(list: *std.ArrayList(u8), group: *const LauncherGroup) !void {
    try list.append(gpa, '[');
    for (group.rows[0..group.len], 0..) |*row, i| {
        if (i != 0) try list.append(gpa, ',');
        try appendLauncherButton(list, row.button());
    }
    try list.append(gpa, ']');
}

fn buildConfigJson() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    try list.appendSlice(gpa, "{\"appearance\":{");
    for (COLOR_SPECS, 0..) |spec, i| {
        if (i != 0) try list.append(gpa, ',');
        // JSON key names match JsonAppearance's own field names exactly —
        // derive them from the same order/spelling rather than a second
        // hand-typed list, so a mismatch can't silently creep in.
        const key = switch (spec.field) {
            .bg => "bg_color",
            .text => "text_color",
            .border => "border_color",
            .hover => "hover_color",
            .module_bg => "module_bg_color",
            .cava => "cava_color",
            .ws_active => "workspace_active_color",
            .ws_inactive => "workspace_inactive_color",
            .popup_bg => "popup_bg_color",
            .popup_hover => "popup_hover_color",
            .popup_separator => "popup_separator_color",
            .popup_disabled => "popup_disabled_color",
            .bezel => "bezel_color",
            .matrix => "matrix_color",
        };
        try appendJsonString(&list, key);
        try list.append(gpa, ':');
        var buf: [8]u8 = undefined;
        try appendJsonString(&list, rgbaToHex(live_color_values[i], &buf));
    }
    try list.appendSlice(gpa, ",\"bar_height\":");
    try appendJsonInt(&list, u32, live_bar_height);
    try list.appendSlice(gpa, ",\"border_top_px\":");
    try appendJsonInt(&list, u32, live_border_top_px);
    try list.appendSlice(gpa, ",\"border_bottom_px\":");
    try appendJsonInt(&list, u32, live_border_bottom_px);
    try list.appendSlice(gpa, ",\"border_left_px\":");
    try appendJsonInt(&list, u32, live_border_left_px);
    try list.appendSlice(gpa, ",\"border_right_px\":");
    try appendJsonInt(&list, u32, live_border_right_px);
    try list.appendSlice(gpa, ",\"workspace_gap\":");
    try appendJsonInt(&list, i64, live_workspace_gap);
    try list.appendSlice(gpa, ",\"font_path\":");
    try appendJsonString(&list, live_font_path);
    try list.appendSlice(gpa, ",\"bg_opacity_percent\":");
    try appendJsonInt(&list, u8, live_bg_opacity_percent);
    try list.appendSlice(gpa, ",\"corner_radius_px\":");
    try appendJsonInt(&list, u32, live_corner_radius_px);
    try list.appendSlice(gpa, ",\"position\":");
    try appendJsonString(&list, live_position);
    try list.appendSlice(gpa, ",\"bar_mode\":");
    try appendJsonString(&list, live_bar_mode);
    try list.appendSlice(gpa, ",\"auto_hide\":");
    try list.appendSlice(gpa, if (live_auto_hide) "true" else "false");
    try list.appendSlice(gpa, ",\"clock_format\":");
    try appendJsonString(&list, live_clock_format);
    try list.appendSlice(gpa, ",\"monitor\":");
    try appendJsonString(&list, live_monitor);
    try list.appendSlice(gpa, ",\"auto_theme\":");
    try appendJsonString(&list, live_auto_theme);
    try list.appendSlice(gpa, ",\"empty_click_command\":");
    try appendJsonString(&list, live_empty_click_command);
    try list.appendSlice(gpa, ",\"animations_enabled\":");
    try list.appendSlice(gpa, if (live_animations_enabled) "true" else "false");
    try list.appendSlice(gpa, ",\"bezel_style\":");
    try appendJsonString(&list, live_bezel_style);
    try list.appendSlice(gpa, ",\"bezel_effect\":");
    try appendJsonString(&list, live_bezel_effect);
    try list.appendSlice(gpa, ",\"bg_mode\":");
    try appendJsonString(&list, live_bg_mode);
    try list.appendSlice(gpa, ",\"cava_bg_strength\":");
    try appendJsonInt(&list, u8, live_cava_bg_strength);
    try list.appendSlice(gpa, ",\"matrix_speed\":");
    try appendJsonInt(&list, u32, live_matrix_speed);
    try list.appendSlice(gpa, ",\"module_pill_opacity\":");
    try appendJsonInt(&list, u8, live_module_pill_opacity);
    try list.appendSlice(gpa, ",\"module_border_width\":");
    try appendJsonInt(&list, u32, live_module_border_width);
    try list.appendSlice(gpa, ",\"module_pills\":");
    try list.appendSlice(gpa, if (live_module_pills) "true" else "false");
    try list.appendSlice(gpa, ",\"pill_borders\":");
    try list.appendSlice(gpa, if (live_pill_borders) "true" else "false");

    try list.appendSlice(gpa, "},\"modules\":{\"left\":");
    try appendModuleGroup(&list, &live_left);
    try list.appendSlice(gpa, ",\"center\":");
    try appendModuleGroup(&list, &live_center);
    try list.appendSlice(gpa, ",\"right\":");
    try appendModuleGroup(&list, &live_right);
    try list.appendSlice(gpa, "},\"launchers\":");
    try appendLaunchers(&list, &live_launchers);
    try list.append(gpa, '}');

    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------
// Save + live-reload signal
// ---------------------------------------------------------------------

fn signalBar() void {
    const text = readFileAll(pidfile_path) orelse {
        logging.warn("config: no pidfile at {s} (bar not running?)", .{pidfile_path});
        return;
    };
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(c_int, trimmed, 10) catch {
        logging.warn("config: unreadable pid in {s}", .{pidfile_path});
        return;
    };
    if (std.c.kill(pid, .USR1) != 0) {
        logging.warn("config: kill(SIGUSR1) on pid {d} failed (bar not running?)", .{pid});
    }
}

/// Fire-and-forget spawn via `/usr/bin/env` (for $PATH search), detached
/// with the standard double-fork so it outlives us and doesn't leave a
/// zombie — mirrors welcome_main.zig's launchArgv. This file otherwise only
/// has runCaptured's single-fork wait-for-output shape, which isn't right
/// for "start the bar and don't wait around for it."
fn launchDetached(argv: []const [:0]const u8) void {
    if (argv.len == 0 or argv.len > 14) return;
    const pid = libc_proc.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            var buf: [16]?[*:0]const u8 = undefined;
            buf[0] = "/usr/bin/env";
            for (argv, 0..) |a, i| buf[i + 1] = a;
            buf[argv.len + 1] = null;
            _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
            std.c._exit(127);
        }
        std.c._exit(0);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

fn readPidfilePid() ?c_int {
    const text = readFileAll(pidfile_path) orelse return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(c_int, trimmed, 10) catch null;
}

/// Kills the running bar (via its pidfile, same one signalBar reads) and
/// spawns a fresh instance found on $PATH — for restart-required settings
/// (currently just Monitor) that SIGUSR1 can't apply live. Missing/stale
/// pidfile just means there's nothing to kill; still spawns a fresh bar
/// either way, matching signalBar's "no bar running is not an error" stance.
///
/// Blocks (briefly, capped) until the NEW instance has written its own
/// pidfile before returning — confirmed via live testing that skipping this
/// is a real bug, not a theoretical one: clicking Restart again while the
/// previous spawn is still mid-startup re-reads the SAME stale pidfile
/// (writePidfile() in the new process hasn't run yet), so the "kill" targets
/// nothing, and a THIRD process gets spawned on top of the still-starting
/// second one. A few fast clicks in a row produced a stack of orphaned bars
/// all bound to the same monitor. Waiting for the pidfile to actually change
/// makes each click atomic from the GUI's perspective at the cost of a brief
/// (usually well under a second) button-click hang, which is an acceptable
/// tradeoff for an inherently non-instant "restart" action.
fn restartBar() void {
    const old_pid = readPidfilePid();
    if (old_pid) |pid| _ = std.c.kill(pid, .TERM);

    launchDetached(&.{"simpbar"});

    var waited_ms: u32 = 0;
    var dummy: [1]PollFd = undefined;
    while (waited_ms < 2000) : (waited_ms += 50) {
        if (readPidfilePid()) |new_pid| {
            if (new_pid != old_pid) return;
        }
        _ = poll(&dummy, 0, 50); // portable msleep(50) — 0 fds, just the timeout
    }
}

fn onRestartBarClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    restartBar();
}

fn saveAndSignal() void {
    const bytes = buildConfigJson() catch |err| {
        logging.err("config: failed to build config.json: {}", .{err});
        return;
    };
    defer gpa.free(bytes);
    if (!writeFileAll(config_json_path, bytes)) {
        logging.err("config: failed to write {s}", .{config_json_path});
        return;
    }
    signalBar();
}

// ---------------------------------------------------------------------
// Appearance tab widgets
// ---------------------------------------------------------------------

fn onColorChanged(button: *gtk.GtkColorDialogButton, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const spec: *const ColorSpec = @ptrCast(@alignCast(user_data.?));
    const idx = for (COLOR_SPECS, 0..) |s, i| {
        if (s.field == spec.field) break i;
    } else return;
    live_color_values[idx] = gtk.gtk_color_dialog_button_get_rgba(button).*;
    saveAndSignal();
}

fn onBarHeightChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_bar_height = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onBorderTopPxChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_border_top_px = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onBorderBottomPxChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_border_bottom_px = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onBorderLeftPxChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_border_left_px = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onBorderRightPxChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_border_right_px = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onWorkspaceGapChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_workspace_gap = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onBgOpacityChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_bg_opacity_percent = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onCornerRadiusChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_corner_radius_px = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

fn onModulePillOpacityChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_module_pill_opacity = @intCast(@min(gtk.gtk_spin_button_get_value_as_int(button), 100));
    saveAndSignal();
}

fn onModuleBorderWidthChanged(button: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_module_border_width = @intCast(@min(@max(gtk.gtk_spin_button_get_value_as_int(button), 0), 8));
    saveAndSignal();
}

fn onPositionChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_position = if (gtk.adw_combo_row_get_selected(row) == 0) "top" else "bottom";
    saveAndSignal();
}

fn onBarModeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_bar_mode = if (gtk.adw_combo_row_get_selected(row) == 0) "taskbar" else "dock";
    saveAndSignal();
}

fn buildBarModeRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Bar mode");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "Taskbar spans the full edge and reserves it; dock floats with margins and lets windows slide under. Applies instantly.");

    var buf: [3]?[*:0]const u8 = .{ "Taskbar", "Dock", null };
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));
    gtk.adw_combo_row_set_selected(row, if (std.mem.eql(u8, live_bar_mode, "dock")) 1 else 0);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onBarModeChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Flips auto-hide (appearance.auto_hide): the bar collapses to a 2px hint
/// strip at the screen edge ~300ms after the pointer leaves, releasing its
/// exclusive zone so windows use the space; touching or clicking the strip
/// brings it straight back.
fn onAutoHideChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_auto_hide = gtk.gtk_switch_get_active(sw) != 0;
    saveAndSignal();
}

fn buildAutoHideRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Auto-hide");
    gtk.adw_action_row_set_subtitle(row, "Collapse the bar to a thin edge strip when the pointer leaves, and bring it back on touch. Works in taskbar and dock mode.");
    gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (live_auto_hide) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onAutoHideChanged), null, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn buildPositionRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Position");

    var buf: [3]?[*:0]const u8 = .{ "Top", "Bottom", null };
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));
    gtk.adw_combo_row_set_selected(row, if (std.mem.eql(u8, live_position, "top")) 0 else 1);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onPositionChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

const CLOCK_FORMAT_CHOICES = [_][]const u8{
    CLOCK_FORMAT_DATE_24H, CLOCK_FORMAT_TIME_24H, CLOCK_FORMAT_TIME_24H_SECONDS,
    CLOCK_FORMAT_TIME_12H, CLOCK_FORMAT_DATE_12H,
};
const CLOCK_FORMAT_LABELS = [_][*:0]const u8{
    "24-hour with date", "24-hour", "24-hour with seconds", "12-hour", "12-hour with date",
};

fn onClockFormatChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx < CLOCK_FORMAT_CHOICES.len) live_clock_format = CLOCK_FORMAT_CHOICES[idx];
    saveAndSignal();
}

/// Toggles the bar's matugen auto-theming (appearance.auto_theme). While
/// ON, bar colors come from matugen's ~/.config/simpbar/matugen.json (which
/// the wallpaper hook regenerates) and override the color pickers below,
/// which stay editable but dormant — this switch is the on/off knob. ON
/// with no matugen.json present just leaves the picker colors in charge, so
/// the default state is harmless for anyone without matugen set up.
fn onAutoThemeChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_auto_theme = if (gtk.gtk_switch_get_active(sw) != 0) "matugen" else "manual";
    saveAndSignal();
}

fn buildAutoThemeRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Auto-theme with matugen");
    gtk.adw_action_row_set_subtitle(row, "Recolor the bar from the wallpaper via matugen as soon as it generates a scheme (and on every wallpaper change). Turning this off uses the colors below instead.");
    gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (std.mem.eql(u8, live_auto_theme, "matugen")) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onAutoThemeChanged), null, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// matugen's own `--type` values (from `matugen --help`'s possible values).
// The bar never interprets these — simpbar-matugen passes the chosen one to
// matugen, which derives the palette the bar then merges in. Values must stay
// byte-for-byte in sync with matugen; labels are just what the user reads.
const MATUGEN_TYPE_CHOICES = [_][]const u8{
    "scheme-tonal-spot", "scheme-content",     "scheme-expressive", "scheme-fidelity",
    "scheme-fruit-salad", "scheme-monochrome", "scheme-neutral",   "scheme-rainbow",
    "scheme-vibrant",    "scheme-smart",
};
const MATUGEN_TYPE_LABELS = [_][*:0]const u8{
    "Tonal spot (default)", "Content", "Expressive", "Fidelity",
    "Fruit salad",          "Monochrome", "Neutral", "Rainbow",
    "Vibrant",              "Smart",
};

/// Persists the chosen scheme to ~/.config/simpbar/matugen-type and runs the
/// helper (which re-renders matugen.json with `matugen --type <scheme>` and
/// SIGUSR1-reloads the bar via matugen's post_hook) so the change shows up
/// right away instead of waiting for the next wallpaper switch. Independent
/// of the auto-theme switch: it only visibly matters while that's ON, but
/// picking a scheme needn't flip it.
fn onMatugenTypeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= MATUGEN_TYPE_CHOICES.len) return;
    live_matugen_type = MATUGEN_TYPE_CHOICES[idx];
    if (writeFileAll(matugen_type_path, live_matugen_type)) {
        launchDetached(&.{"simpbar-matugen"});
    } else {
        logging.err("config: could not write {s}", .{matugen_type_path});
    }
}

fn buildMatugenTypeRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Matugen color scheme");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "The Material You palette matugen derives from the wallpaper. Changing this regenerates the scheme immediately.");

    var buf: [MATUGEN_TYPE_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (MATUGEN_TYPE_LABELS, 0..) |label, i| buf[i] = label;
    buf[MATUGEN_TYPE_LABELS.len] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));

    var selected_idx: c_uint = 0;
    for (MATUGEN_TYPE_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, choice, live_matugen_type)) selected_idx = @intCast(i);
    }
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onMatugenTypeChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Flips the hover/active-pill animation master switch
/// (appearance.animations_enabled). Off = highlights snap instantly and the
/// bezel sits still; the look is unchanged, only the motion stops.
fn onAnimationsEnabledChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_animations_enabled = gtk.gtk_switch_get_active(sw) != 0;
    saveAndSignal();
}

fn buildAnimationsRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Animations");
    gtk.adw_action_row_set_subtitle(row, "Fade the hover highlight and active-workspace pill, and move the bezel. Turning this off snaps highlights instantly and freezes the bezel.");
    gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (live_animations_enabled) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onAnimationsEnabledChanged), null, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// Bezel style choices (values must stay byte-for-byte in sync with main.zig's
// BEZEL_STYLE_* — they are written straight into config.json).
const BEZEL_STYLE_CHOICES = [_][]const u8{ "matugen", "rainbow-puke", "solid" };
const BEZEL_STYLE_LABELS = [_][*:0]const u8{ "Matugen", "Rainbow puke", "Solid" };

// Bezel effect choices (values must stay byte-for-byte in sync with
// main.zig's BEZEL_EFFECT_* — they are written straight into config.json).
const BEZEL_EFFECT_CHOICES = [_][]const u8{ "rotating", "breathing", "solid" };

// Background mode choices (values must stay byte-for-byte in sync with
// main.zig's BG_MODE_* — they are written straight into config.json).
const BG_MODE_CHOICES = [_][]const u8{ "none", "cava", "matrix" };
const BG_MODE_LABELS = [_][*:0]const u8{ "None", "Cava", "Matrix" };

/// Picks the bar background mode (appearance.bg_mode). Applies on the next
/// SIGUSR1 reload like every other config.json change.
fn onBgModeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= BG_MODE_CHOICES.len) return;
    live_bg_mode = BG_MODE_CHOICES[idx];
    saveAndSignal();
}

fn buildBgModeRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Background effect");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "Animated backdrop behind the modules. Cava follows the music; Matrix rains on its own.");

    var buf: [BG_MODE_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (BG_MODE_LABELS, 0..) |label, i| buf[i] = label;
    buf[BG_MODE_LABELS.len] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));

    var selected_idx: c_uint = 0;
    for (BG_MODE_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, choice, live_bg_mode)) selected_idx = @intCast(i);
    }
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onBgModeChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Sets the cava background wash strength (appearance.cava_bg_strength).
fn onCavaBgStrengthChanged(spin: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_cava_bg_strength = @intCast(@min(gtk.gtk_spin_button_get_value_as_int(spin), 100));
    saveAndSignal();
}

/// Sets the matrix fall speed (appearance.matrix_speed).
fn onMatrixSpeedChanged(spin: *gtk.GtkSpinButton, _: ?*anyopaque) callconv(.c) void {
    live_matrix_speed = @as(u32, @intCast(gtk.gtk_spin_button_get_value_as_int(spin)));
    saveAndSignal();
}
const BEZEL_EFFECT_LABELS = [_][*:0]const u8{ "Rotating", "Breathing", "Solid" };

/// Picks the hover/active bezel effect (appearance.bezel_effect). Applies on
/// the next SIGUSR1 reload like every other config.json change.
fn onBezelEffectChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= BEZEL_EFFECT_CHOICES.len) return;
    live_bezel_effect = BEZEL_EFFECT_CHOICES[idx];
    saveAndSignal();
}

fn buildBezelEffectRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Bezel effect");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "How the bezel moves: travel around the pill, gently swell in place, or sit still.");

    var buf: [BEZEL_EFFECT_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (BEZEL_EFFECT_LABELS, 0..) |label, i| buf[i] = label;
    buf[BEZEL_EFFECT_LABELS.len] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));

    var selected_idx: c_uint = 0;
    for (BEZEL_EFFECT_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, choice, live_bezel_effect)) selected_idx = @intCast(i);
    }
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onBezelEffectChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Picks the hover/active bezel style (appearance.bezel_style). Applies on
/// the next SIGUSR1 reload like every other config.json change.
fn onBezelStyleChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= BEZEL_STYLE_CHOICES.len) return;
    live_bezel_style = BEZEL_STYLE_CHOICES[idx];
    saveAndSignal();
}

fn buildBezelStyleRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Bezel style");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "What the bezel ring wears: the wallpaper palette traveling around, the full hue wheel, or one solid Bezel Color (under Bar Colors).");

    var buf: [BEZEL_STYLE_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (BEZEL_STYLE_LABELS, 0..) |label, i| buf[i] = label;
    buf[BEZEL_STYLE_LABELS.len] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));

    var selected_idx: c_uint = 0;
    for (BEZEL_STYLE_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, choice, live_bezel_style)) selected_idx = @intCast(i);
    }
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onBezelStyleChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Flips resting module pills on/off (appearance.module_pills). Off =
/// modules sit directly on the bar background; hover/active treatments
/// still draw their own pill when lit.
fn onModulePillsChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_module_pills = gtk.gtk_switch_get_active(sw) != 0;
    saveAndSignal();
}

fn buildModulePillsRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Module pills");
    gtk.adw_action_row_set_subtitle(row, "Give every module its own pill background. Turning this off leaves modules directly on the bar background.");
    gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (live_module_pills) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onModulePillsChanged), null, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Flips bezel rings on/off wherever they appear — resting pills, hover,
/// active workspace, popup rows (appearance.pill_borders). Off = flat fills
/// and dash only, no rings.
fn onPillBordersChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_pill_borders = gtk.gtk_switch_get_active(sw) != 0;
    saveAndSignal();
}

fn buildPillBordersRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Pill borders");
    gtk.adw_action_row_set_subtitle(row, "Draw the bezel ring around pills. Turning this off leaves flat fills with no rings anywhere.");
    gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (live_pill_borders) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onPillBordersChanged), null, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

/// Reads the per-widget on/off list (one widget id per line) into a mask
/// over WIDGET_TABLE below (bit i = row i). Missing/unreadable file means
/// zero (all enabled), matching the shell's own default — a fresh install
/// has no file.
fn loadDisabledMask() u8 {
    const raw = readFileAll(widgets_disabled_path) orelse return 0;
    defer gpa.free(raw);
    var mask: u8 = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const id = std.mem.trim(u8, line, " \t\r");
        if (id.len == 0) continue;
        for (WIDGET_TABLE, 0..) |w, i| {
            if (std.mem.eql(u8, w.id, id)) {
                mask |= @as(u8, 1) << @as(u3, @intCast(i));
                break;
            }
        }
    }
    return mask;
}

/// Rewrites the on/off list from the live mask, one id per line in table
/// order. The GUI owns this file outright (unlike shell.json), so a full
/// rewrite is safe — widget positions live in shell.json and are untouched.
fn saveDisabledMask() void {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (WIDGET_TABLE, 0..) |w, i| {
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i));
        if (live_disabled_mask & bit == 0) continue;
        const line = std.fmt.bufPrint(buf[len..], "{s}\n", .{w.id}) catch break;
        len += line.len;
    }
    if (!writeFileAll(widgets_disabled_path, buf[0..len])) {
        logging.err("config: could not write {s}", .{widgets_disabled_path});
    }
}

/// The shell's PID from its pidfile, or null when it isn't running (or the
/// pidfile is missing/stale). Mirrors readPidfilePid for the bar.
fn readShellPid() ?c_int {
    const text = readFileAll(shell_pidfile_path) orelse return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(c_int, trimmed, 10) catch null;
}

/// Restarts the widgets so a per-widget toggle takes effect: the shell only
/// reads the on/off list at startup, so kill + spawn is the apply step.
/// Unlike restartBar there is deliberately no pidfile-change wait — the
/// shell's control-socket probe makes two daemons impossible (a redundant
/// spawn just exits 0), so rapid toggles can't stack orphans, and the kill
/// needs no grace period (the shell installs no SIGTERM handler, so default
/// disposition terminates it long before the new instance reaches its own
/// socket probe after config/font/Wayland init).
fn restartShell() void {
    if (readShellPid()) |pid| {
        _ = std.c.kill(pid, .TERM);
    } else {
        // No pidfile (shell predating pidfiles, or none running): exact-name
        // pkill covers the live-but-untracked case; a miss is a silent no-op.
        launchDetached(&.{ "pkill", "-x", "simpbar-shell" });
    }
    launchDetached(&.{"simpbar-shell"});
}

/// One desktop widget's row in the Desktop Widgets group. `id` is the exact
/// shell.json/control id the shell itself uses (see WidgetId) — it is what
/// lands in the widgets-disabled file, so it must stay byte-for-byte in sync
/// with the shell. The mask bit is the row index (GUI-internal only; the
/// file stores names, never bits).
const WidgetToggle = struct {
    id: []const u8,
    title: [:0]const u8,
    subtitle: [:0]const u8,
};

const WIDGET_TABLE = [_]WidgetToggle{
    .{ .id = "clock", .title = "Clock", .subtitle = "Digital clock card" },
    .{ .id = "weather", .title = "Weather", .subtitle = "Weather card" },
    .{ .id = "media", .title = "Media", .subtitle = "Now-playing card with cover art and controls" },
    .{ .id = "system", .title = "System", .subtitle = "System stats card" },
    .{ .id = "calendar", .title = "Calendar", .subtitle = "Calendar card with reminders" },
    .{ .id = "watch", .title = "Watch", .subtitle = "Analog watch" },
    .{ .id = "note1", .title = "Sticky note", .subtitle = "Sticky note card" },
};

/// Flips one desktop widget off/on: updates the live mask, persists the
/// on/off list, and restarts the shell so the change shows up right away.
/// The widget index arrives as the signal's user_data (see buildWidgetRows).
/// Independent of config.json — intentionally not routed through
/// saveAndSignal.
fn onWidgetEnabledChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const idx: usize = @intFromPtr(user_data.?);
    if (idx >= WIDGET_TABLE.len) return;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(idx));
    if (gtk.gtk_switch_get_active(sw) != 0) {
        live_disabled_mask &= ~bit;
    } else {
        live_disabled_mask |= bit;
    }
    saveDisabledMask();
    restartShell();
}

fn buildWidgetRows(group: *gtk.AdwPreferencesGroup) void {
    for (WIDGET_TABLE, 0..) |w, i| {
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i));
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), w.title);
        gtk.adw_action_row_set_subtitle(row, w.subtitle);
        gtk.adw_action_row_set_icon_name(row, "applications-graphics-symbolic");

        const sw = gtk.gtk_switch_new();
        gtk.gtk_switch_set_active(sw, if (live_disabled_mask & bit == 0) 1 else 0);
        gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onWidgetEnabledChanged), @ptrFromInt(i), null, 0);

        gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
}

fn buildClockFormatRow(group: *gtk.AdwPreferencesGroup) void {
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Clock Format");

    var buf: [CLOCK_FORMAT_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (CLOCK_FORMAT_LABELS, 0..) |label, i| buf[i] = label;
    buf[CLOCK_FORMAT_LABELS.len] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));

    var selected_idx: c_uint = 0;
    for (CLOCK_FORMAT_CHOICES, 0..) |choice, i| {
        if (std.mem.eql(u8, choice, live_clock_format)) selected_idx = @intCast(i);
    }
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onClockFormatChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn addColorRow(group: *gtk.AdwPreferencesGroup, spec: *const ColorSpec, idx: usize) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), spec.title);

    const dialog = gtk.gtk_color_dialog_new();
    const button = gtk.gtk_color_dialog_button_new(dialog);
    gtk.gtk_color_dialog_button_set_rgba(button, &live_color_values[idx]);
    gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(button), "notify::rgba", @ptrCast(&onColorChanged), @constCast(@ptrCast(spec)), null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(button));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn addSpinRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, initial: f64, callback: gtk.GCallback) void {
    addSpinRowCtx(group, title, min, max, initial, callback, null);
}

fn addSpinRowCtx(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, initial: f64, callback: gtk.GCallback, user_data: ?*anyopaque) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);

    const spin = gtk.gtk_spin_button_new_with_range(min, max, 1);
    gtk.gtk_spin_button_set_value(spin, initial);
    gtk.gtk_widget_set_valign(@ptrCast(spin), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(spin), "value-changed", callback, user_data, null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(spin));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// Font selection — discovers installed Nerd Font families via `fc-list`
// (fontconfig) and lets the Appearance tab pick one. Restricted to Nerd
// Font variants specifically, not every font on the system: the bar
// renders icon glyphs (workspace numbers, launcher pins, power button, ...)
// from Private-Use-Area codepoints that only a Nerd Font patched typeface
// actually contains — picking an arbitrary font would silently break most
// of the bar's icon rendering.
// ---------------------------------------------------------------------

const MAX_FONT_ENTRIES = 64;
const MAX_FONT_NAME = 96;
const MAX_FONT_PATH = 512;

const NerdFontEntry = struct {
    family_buf: [MAX_FONT_NAME:0]u8 = undefined,
    family_len: usize = 0,
    path_buf: [MAX_FONT_PATH]u8 = undefined,
    path_len: usize = 0,
    // Every entry here has "nerd font" in its family name (that's the whole
    // filter discoverNerdFonts applies), so that part of the name never
    // actually distinguishes one entry from another in the dropdown — only
    // the part before it does. Stripping it frees up real horizontal room
    // for the part that matters, computed once here rather than re-derived
    // on every dropdown open.
    display_buf: [MAX_FONT_NAME:0]u8 = undefined,
    display_len: usize = 0,

    fn family(self: *const NerdFontEntry) [:0]const u8 {
        return self.family_buf[0..self.family_len :0];
    }
    fn path(self: *const NerdFontEntry) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    fn display(self: *const NerdFontEntry) [:0]const u8 {
        return self.display_buf[0..self.display_len :0];
    }
    fn setFamily(self: *NerdFontEntry, s: []const u8) void {
        const n = @min(s.len, MAX_FONT_NAME);
        @memcpy(self.family_buf[0..n], s[0..n]);
        self.family_buf[n] = 0;
        self.family_len = n;
        var tmp: [MAX_FONT_NAME]u8 = undefined;
        self.setDisplay(shortenFontName(self.family_buf[0..n], &tmp));
    }
    fn setPath(self: *NerdFontEntry, s: []const u8) void {
        const n = @min(s.len, MAX_FONT_PATH);
        @memcpy(self.path_buf[0..n], s[0..n]);
        self.path_len = n;
    }
    fn setDisplay(self: *NerdFontEntry, s: []const u8) void {
        const n = @min(s.len, MAX_FONT_NAME);
        @memcpy(self.display_buf[0..n], s[0..n]);
        self.display_buf[n] = 0;
        self.display_len = n;
    }
};

/// Splices the redundant " Nerd Font" phrase out of a family name, case-
/// insensitively, while PRESERVING any trailing variant qualifier that
/// follows it (" Mono" / " Propo") — that qualifier is real information that
/// distinguishes entries from each other (this machine has separate
/// "JetBrainsMono Nerd Font", "...Nerd Font Mono", and "...Nerd Font Propo"
/// entries), unlike "Nerd Font" itself, which every entry has by
/// construction (discoverNerdFonts only keeps families containing it) and
/// so never distinguishes anything. E.g. "JetBrainsMono Nerd Font Mono" →
/// "JetBrainsMono Mono", not just "JetBrainsMono" (which would then be
/// indistinguishable from the plain "JetBrainsMono Nerd Font" entry).
/// Writes into `buf` since splicing out a middle chunk while keeping what
/// comes after isn't a plain sub-slice of the original. Falls back to the
/// untrimmed name if " Nerd Font" isn't found (shouldn't happen given the
/// filter above, but never worse than what was shown before this change).
fn shortenFontName(name: []const u8, buf: []u8) []const u8 {
    const needle = " Nerd Font";
    var at: ?usize = null;
    var i: usize = 0;
    while (i + needle.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + needle.len], needle)) {
            at = i;
            break;
        }
    }
    const pos = at orelse return name;
    const prefix = name[0..pos];
    const suffix = name[pos + needle.len ..]; // "", " Mono", or " Propo"
    const n = @min(prefix.len + suffix.len, buf.len);
    const prefix_copied = @min(prefix.len, n);
    @memcpy(buf[0..prefix_copied], prefix[0..prefix_copied]);
    if (prefix_copied < n) {
        @memcpy(buf[prefix_copied..n], suffix[0 .. n - prefix_copied]);
    }
    return buf[0..n];
}

var font_entries: [MAX_FONT_ENTRIES]NerdFontEntry = undefined;
var font_entry_count: usize = 0;

/// Plain case-insensitive substring search — std.ascii has eqlIgnoreCase
/// (exact match) but nothing for "does this string contain that one"
/// ignoring case, so a short manual scan is simplest here.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn nerdFontEntryLessThan(_: void, a: NerdFontEntry, b: NerdFontEntry) bool {
    return std.mem.lessThan(u8, a.family(), b.family());
}

/// Runs `fc-list` once, parses its "path: family1,family2:style=s1,s2" line
/// format (verified against this machine's real output before writing this
/// parser), keeps only families whose name contains "nerd font", dedupes by
/// family (preferring a Regular-style file when more than one is found for
/// the same family), and sorts the result alphabetically. On any failure
/// (fc-list missing, no output, ...) leaves font_entry_count at 0 — the
/// dropdown degrades to just showing the currently-configured font rather
/// than crashing the Appearance tab.
fn discoverNerdFonts() void {
    font_entry_count = 0;
    const output = runCaptured(&.{"fc-list"}, 3000) orelse return;
    defer gpa.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon_space = std.mem.indexOf(u8, line, ": ") orelse continue;
        const path = line[0..colon_space];
        const rest = line[colon_space + 2 ..];
        const style_marker = std.mem.indexOf(u8, rest, ":style=") orelse continue;
        const families_part = rest[0..style_marker];
        const style_part = rest[style_marker + ":style=".len ..];

        // Only the first comma-separated family alias — same convention
        // fc-list itself lists first (the "primary" name).
        const first_family_end = std.mem.indexOfScalar(u8, families_part, ',') orelse families_part.len;
        const fam = families_part[0..first_family_end];
        if (!containsIgnoreCase(fam, "nerd font")) continue;
        // Only the FIRST style token, exact match — fontconfig lists
        // "Regular" as a SECOND alias on plenty of non-Regular-weight files
        // too (e.g. "style=ExtraBold,Regular", "style=Thin,Regular" — that
        // second "Regular" means "upright, not italic," not "the Regular
        // weight"), so a substring/contains check across the whole style
        // list picks whichever such file happens to be seen last. Confirmed
        // via this machine's real fc-list output before fixing.
        const first_style_end = std.mem.indexOfScalar(u8, style_part, ',') orelse style_part.len;
        const is_regular = std.ascii.eqlIgnoreCase(style_part[0..first_style_end], "Regular");

        var existing: ?*NerdFontEntry = null;
        for (font_entries[0..font_entry_count]) |*e| {
            if (std.mem.eql(u8, e.family(), fam)) {
                existing = e;
                break;
            }
        }
        if (existing) |e| {
            if (is_regular) e.setPath(path);
            continue;
        }
        if (font_entry_count >= MAX_FONT_ENTRIES) continue;
        const entry = &font_entries[font_entry_count];
        entry.setFamily(fam);
        entry.setPath(path);
        font_entry_count += 1;
    }

    std.sort.insertion(NerdFontEntry, font_entries[0..font_entry_count], {}, nerdFontEntryLessThan);
}

fn onFontChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= font_entry_count) return;
    live_font_path = font_entries[idx].path();
    saveAndSignal();
}

fn buildFontRow(group: *gtk.AdwPreferencesGroup) void {
    discoverNerdFonts();

    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Font");

    if (font_entry_count == 0) {
        // fc-list found nothing usable — still show a functional (if
        // single-choice) row naming whatever's currently configured,
        // rather than an empty/broken dropdown.
        var buf: [2]?[*:0]const u8 = .{ null, null };
        var name_buf: [MAX_FONT_NAME:0]u8 = undefined;
        const n = @min(live_font_path.len, MAX_FONT_NAME);
        @memcpy(name_buf[0..n], live_font_path[0..n]);
        name_buf[n] = 0;
        buf[0] = name_buf[0..n :0].ptr;
        gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
        return;
    }

    var buf: [MAX_FONT_ENTRIES + 1]?[*:0]const u8 = undefined;
    var selected_idx: c_uint = 0;
    for (font_entries[0..font_entry_count], 0..) |*e, i| {
        buf[i] = e.display().ptr;
        if (std.mem.eql(u8, e.path(), live_font_path)) selected_idx = @intCast(i);
    }
    buf[font_entry_count] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onFontChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// Monitor selection — discovers connected outputs via the running
// compositor's IPC (`hyprctl monitors -j` on Hyprland, `mmsg get
// all-monitors` on MangoWM; the only live-system-query mechanism in this
// file, same runCaptured fork/exec/pipe-capture already used for fc-list
// above; NOT std.json — this file hand-parses external command output
// everywhere, matching main.zig's own hand-rolled substring-scan style for
// compositor JSON).
// Restart-required, unlike every other Appearance control: creating/
// destroying Wayland surfaces live is out of scope (see the plan), so this
// only takes effect the next time the bar process starts.
// ---------------------------------------------------------------------

const MAX_MONITOR_ENTRIES = 8;
const MAX_MONITOR_NAME = 64;

const MonitorEntry = struct {
    name_buf: [MAX_MONITOR_NAME:0]u8 = undefined,
    name_len: usize = 0,

    fn name(self: *const MonitorEntry) [:0]const u8 {
        return self.name_buf[0..self.name_len :0];
    }
    fn setName(self: *MonitorEntry, s: []const u8) void {
        const n = @min(s.len, MAX_MONITOR_NAME);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_buf[n] = 0;
        self.name_len = n;
    }
};

var monitor_entries: [MAX_MONITOR_ENTRIES]MonitorEntry = undefined;
var monitor_entry_count: usize = 0;

/// Runs `hyprctl monitors -j`, extracts each monitor's `"name"` field via a
/// brace-depth-tracking scan (NOT a plain substring search for `"name":` —
/// hyprctl's real output nests a SECOND, unrelated `"name"` field inside
/// each monitor's `"activeWorkspace"`/`"specialWorkspace"` sub-objects, e.g.
/// `"activeWorkspace": { "id": 5, "name": "5" }` — a naive scan would
/// capture "5" instead of "DP-3". Only the first `"name"` encountered while
/// exactly one level of `{`/`}` deep (i.e. directly inside one monitor's own
/// top-level object, not a nested one) is accepted; verified against this
/// machine's real `hyprctl monitors -j` output — a pretty-printed JSON array
/// where each monitor object lists `"id"`, `"name"`, `"description"`, ...
/// before the nested workspace objects, and the key uses `"name": "DP-3"`
/// (a space after the colon), not `"name":"DP-3"`. On any failure (hyprctl
/// missing, no monitors, unparseable) leaves monitor_entry_count at 0 — the
/// dropdown degrades to just its two fixed entries rather than crashing.
fn discoverMonitors() void {
    monitor_entry_count = 0;
    const mango = getenv("MANGO_INSTANCE_SIGNATURE") != null;
    const argv: []const [:0]const u8 = if (mango)
        &.{ "mmsg", "get", "all-monitors" }
    else
        &.{ "hyprctl", "monitors", "-j" };
    const output = runCaptured(argv, 3000) orelse return;
    defer gpa.free(output);

    const needle = "\"name\"";
    var depth: usize = 0;
    var captured_this_object = false;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const c = output[i];
        if (c == '{') {
            depth += 1;
            if (depth == 1) captured_this_object = false;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth != 1 or captured_this_object) continue;
        if (i + needle.len > output.len or !std.mem.eql(u8, output[i .. i + needle.len], needle)) continue;

        // Found the key at the right depth — skip past `"name"`, whitespace,
        // the colon, more whitespace, then the opening quote of the value.
        var j = i + needle.len;
        while (j < output.len and (output[j] == ' ' or output[j] == '\t')) : (j += 1) {}
        if (j >= output.len or output[j] != ':') continue;
        j += 1;
        while (j < output.len and (output[j] == ' ' or output[j] == '\t')) : (j += 1) {}
        if (j >= output.len or output[j] != '"') continue;
        j += 1;
        const value_start = j;
        while (j < output.len and output[j] != '"') : (j += 1) {}
        if (j >= output.len) continue;
        const value = output[value_start..j];

        captured_this_object = true;
        if (monitor_entry_count < MAX_MONITOR_ENTRIES) {
            monitor_entries[monitor_entry_count].setName(value);
            monitor_entry_count += 1;
        }
        i = j; // resume scanning right after the closing quote
    }
}

fn onMonitorChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx == 0) {
        live_monitor = "";
    } else if (idx == 1) {
        live_monitor = "all";
    } else {
        const entry_idx = idx - 2;
        if (entry_idx >= monitor_entry_count) return;
        live_monitor = monitor_entries[entry_idx].name();
    }
    saveAndSignal();
}

fn buildMonitorRow(group: *gtk.AdwPreferencesGroup) void {
    discoverMonitors();

    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Monitor");
    gtk.adw_action_row_set_subtitle(@ptrCast(row), "Takes effect on the next bar restart, not live");

    var buf: [MAX_MONITOR_ENTRIES + 3]?[*:0]const u8 = undefined;
    buf[0] = "Compositor Default";
    buf[1] = "All Monitors";
    // Defaults to 0 ("Compositor Default") — also the correct fallback for
    // an unmatched specific-name value (main.zig itself falls back to ""
    // behavior in that case, so preselecting "Compositor Default" here is
    // consistent with what the bar will actually do).
    var selected_idx: c_uint = if (std.mem.eql(u8, live_monitor, "all")) 1 else 0;
    for (monitor_entries[0..monitor_entry_count], 0..) |*e, i| {
        buf[i + 2] = e.name().ptr;
        if (std.mem.eql(u8, e.name(), live_monitor)) selected_idx = @intCast(i + 2);
    }
    buf[monitor_entry_count + 2] = null;
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&buf))));
    gtk.adw_combo_row_set_selected(row, selected_idx);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", @ptrCast(&onMonitorChanged), null, null, 0);

    gtk.adw_preferences_group_add(group, @ptrCast(row));

    // Restart-required settings (currently just Monitor) can't apply via the
    // usual SIGUSR1 live-reload — this is the one-click way to actually pick
    // them up, instead of needing a terminal to kill+relaunch the bar.
    const restart_row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(restart_row), "Restart Bar");
    gtk.adw_action_row_set_subtitle(@ptrCast(restart_row), "Applies Monitor (and anything else restart-required) right now");
    const restart_button = gtk.gtk_button_new_with_label("Restart");
    gtk.gtk_widget_set_valign(@ptrCast(restart_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(restart_button), "clicked", @ptrCast(&onRestartBarClicked), null, null, 0);
    gtk.adw_action_row_add_suffix(restart_row, @ptrCast(restart_button));
    gtk.adw_preferences_group_add(group, @ptrCast(restart_row));
}

fn buildAppearancePage() *gtk.GtkBox {
    loadConfigFromDisk();

    const outer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(outer), 24);

    const theming_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(theming_group, "Theming");
    buildAutoThemeRow(theming_group);
    buildMatugenTypeRow(theming_group);
    gtk.gtk_box_append(outer, @ptrCast(theming_group));

    const animation_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(animation_group, "Animation");
    buildAnimationsRow(animation_group);
    buildBezelStyleRow(animation_group);
    buildBezelEffectRow(animation_group);
    buildModulePillsRow(animation_group);
    buildPillBordersRow(animation_group);
    addSpinRow(animation_group, "Module pill opacity (%)", 0, 100, @floatFromInt(live_module_pill_opacity), @ptrCast(&onModulePillOpacityChanged));
    addSpinRow(animation_group, "Pill border width (px)", 0, 8, @floatFromInt(live_module_border_width), @ptrCast(&onModuleBorderWidthChanged));
    gtk.gtk_box_append(outer, @ptrCast(animation_group));

    const widgets_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(widgets_group, "Desktop Widgets");
    buildWidgetRows(widgets_group);
    gtk.gtk_box_append(outer, @ptrCast(widgets_group));

    const bar_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(bar_group, "Bar Colors");
    for (&COLOR_SPECS, 0..) |*spec, i| {
        if (spec.group == .bar) addColorRow(bar_group, spec, i);
    }
    gtk.gtk_box_append(outer, @ptrCast(bar_group));

    const popup_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(popup_group, "Popup Menu Colors");
    for (&COLOR_SPECS, 0..) |*spec, i| {
        if (spec.group == .popup) addColorRow(popup_group, spec, i);
    }
    gtk.gtk_box_append(outer, @ptrCast(popup_group));

    const position_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(position_group, "Position and Clock");
    buildPositionRow(position_group);
    buildBarModeRow(position_group);
    buildAutoHideRow(position_group);
    buildClockFormatRow(position_group);
    buildMonitorRow(position_group);
    gtk.gtk_box_append(outer, @ptrCast(position_group));

    const spacing_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(spacing_group, "Spacing");
    addSpinRow(spacing_group, "Bar Height (px)", 16, 64, @floatFromInt(live_bar_height), @ptrCast(&onBarHeightChanged));
    addSpinRow(spacing_group, "Workspace Gap (px)", 0, 32, @floatFromInt(live_workspace_gap), @ptrCast(&onWorkspaceGapChanged));
    gtk.gtk_box_append(outer, @ptrCast(spacing_group));

    const border_group = gtk.adw_preferences_group_new();
    // Not "Border & Corners" — AdwPreferencesGroup titles are parsed as
    // Pango markup, and a bare "&" breaks that parser (confirmed via a real
    // launch-test GTK-WARNING, not guessed).
    gtk.adw_preferences_group_set_title(border_group, "Borders and Corners");
    addSpinRow(border_group, "Top Border (px)", 0, 8, @floatFromInt(live_border_top_px), @ptrCast(&onBorderTopPxChanged));
    addSpinRow(border_group, "Bottom Border (px)", 0, 8, @floatFromInt(live_border_bottom_px), @ptrCast(&onBorderBottomPxChanged));
    addSpinRow(border_group, "Left Border (px)", 0, 8, @floatFromInt(live_border_left_px), @ptrCast(&onBorderLeftPxChanged));
    addSpinRow(border_group, "Right Border (px)", 0, 8, @floatFromInt(live_border_right_px), @ptrCast(&onBorderRightPxChanged));
    addSpinRow(border_group, "Corner Radius (px)", 0, 20, @floatFromInt(live_corner_radius_px), @ptrCast(&onCornerRadiusChanged));
    gtk.gtk_box_append(outer, @ptrCast(border_group));

    const transparency_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(transparency_group, "Transparency");
    gtk.adw_preferences_group_set_description(transparency_group, "Lowering this fades the bar's background and borders through to what's behind it, down to invisible at 0 — modules, pills and text stay fully visible, floating over the wallpaper. For an actual blur (not just a plain see-through cutout), turn on Bar Blur in your compositor's settings page.");
    addSpinRow(transparency_group, "Background Opacity (%)", 0, 100, @floatFromInt(live_bg_opacity_percent), @ptrCast(&onBgOpacityChanged));
    gtk.gtk_box_append(outer, @ptrCast(transparency_group));

    const background_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(background_group, "Background Effect");
    gtk.adw_preferences_group_set_description(background_group, "What paints behind the modules: nothing, the audio visualizer wash (uses the Audio Visualizer color under Bar Colors), or cmatrix-style glyph rain (uses the Matrix Rain color). Effects need a visible background — at 0% opacity above there is nothing to paint on.");
    buildBgModeRow(background_group);
    addSpinRow(background_group, "Cava Strength (%)", 0, 100, @floatFromInt(live_cava_bg_strength), @ptrCast(&onCavaBgStrengthChanged));
    addSpinRow(background_group, "Matrix Speed", 1, 6, @floatFromInt(live_matrix_speed), @ptrCast(&onMatrixSpeedChanged));
    gtk.gtk_box_append(outer, @ptrCast(background_group));

    const font_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(font_group, "Font");
    gtk.adw_preferences_group_set_description(font_group, "Only Nerd Font variants are listed \u{2014} the bar's icons need Nerd Font glyph coverage.");
    buildFontRow(font_group);
    gtk.gtk_box_append(outer, @ptrCast(font_group));

    return outer;
}

// ---------------------------------------------------------------------
// Shortcuts tab (Step 8) — a generic .desktop launcher creator, plus
// pinning a created shortcut into the bar's launcher row.
//
// Exec is a plain command string with NO %f/%u field-code support — an
// explicit scope cut, not an oversight: "Pin to Bar" copies Exec verbatim
// into a LauncherButton.command that main.zig's spawnDetached execs as-is,
// with nothing to substitute a field code with. Restricting shortcut
// CREATION to this same plain-command form (rather than also letting the
// user pick/import an arbitrary pre-existing .desktop file, which could
// easily contain %f/%u from some other app's installer) is what keeps every
// pinnable shortcut guaranteed field-code-free without needing to parse and
// strip Exec= at pin time.
// ---------------------------------------------------------------------

var applications_dir_buf: [480]u8 = undefined;
var applications_dir: [:0]const u8 = "";
var applications_dir_resolved = false;

fn resolveApplicationsDir() void {
    if (applications_dir_resolved) return;
    applications_dir_resolved = true;
    const home = std.mem.span(getenv("HOME") orelse "/root");
    var dir_buf: [440]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.local/share/applications", .{home}) catch return;
    _ = mkdir(dir.ptr, 0o755);
    applications_dir = std.fmt.bufPrintZ(&applications_dir_buf, "{s}", .{dir}) catch "";
}

/// Name -> filesystem-safe slug: lowercased alphanumerics with runs of
/// anything else collapsed to a single hyphen, matching the style of the
/// repo's own hand-named `simpbar-welcome.desktop`. Falls back to a fixed
/// name if the input is empty or entirely non-alphanumeric (e.g. all emoji).
fn slugify(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_hyphen = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_hyphen and n > 0 and n < buf.len) {
                buf[n] = '-';
                n += 1;
            }
            pending_hyphen = false;
            if (n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
        } else {
            pending_hyphen = true;
        }
    }
    if (n == 0) return "shortcut";
    return buf[0..n];
}

fn appendDesktopField(list: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try list.appendSlice(gpa, key);
    try list.appendSlice(gpa, value);
    try list.append(gpa, '\n');
}

/// Field order matches the repo's canonical /home/jay/simpbar/simpbar-welcome.desktop
/// template exactly (install.sh's own inline-generated copy is missing
/// StartupNotify — that's drift in install.sh, not something to replicate).
fn buildDesktopFile(name: []const u8, comment: []const u8, exec: []const u8, icon: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "[Desktop Entry]\n");
    try appendDesktopField(&list, "Type=", "Application");
    try appendDesktopField(&list, "Name=", name);
    if (comment.len > 0) try appendDesktopField(&list, "Comment=", comment);
    try appendDesktopField(&list, "Exec=", exec);
    if (icon.len > 0) try appendDesktopField(&list, "Icon=", icon);
    try appendDesktopField(&list, "Terminal=", "false");
    try appendDesktopField(&list, "Categories=", "Settings;");
    try appendDesktopField(&list, "StartupNotify=", "true");
    return list.toOwnedSlice(gpa);
}

// Shortcuts created this session, eligible for "Pin to Bar" — a plain
// fixed-capacity array of raw buffers (same shape/reasoning as LauncherRow
// above: no self-referential slice fields, views derived on demand), tagged
// as GObject user_data by stable address so each row's button callback can
// read straight back through to its own backing storage.
const MAX_SESSION_SHORTCUTS = 32;

const SessionShortcut = struct {
    name_buf: [MAX_ROW_TEXT]u8 = undefined,
    name_len: usize = 0,
    exec_buf: [MAX_ROW_TEXT]u8 = undefined,
    exec_len: usize = 0,
    icon_buf: [MAX_ROW_TEXT]u8 = undefined,
    icon_len: usize = 0,
    has_icon: bool = false,

    fn name(self: *const SessionShortcut) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn exec(self: *const SessionShortcut) []const u8 {
        return self.exec_buf[0..self.exec_len];
    }
    fn icon(self: *const SessionShortcut) ?[]const u8 {
        return if (self.has_icon) self.icon_buf[0..self.icon_len] else null;
    }
};

var session_shortcuts: [MAX_SESSION_SHORTCUTS]SessionShortcut = undefined;
var session_shortcuts_len: usize = 0;

var g_name_entry: ?*gtk.GtkEntry = null;
var g_comment_entry: ?*gtk.GtkEntry = null;
var g_exec_entry: ?*gtk.GtkEntry = null;
var g_icon_entry: ?*gtk.GtkEntry = null;
var g_icon_preview: ?*gtk.GtkImage = null;
var g_shortcuts_listbox: ?*gtk.GtkListBox = null;

fn entryText(entry: *gtk.GtkEntry) []const u8 {
    return std.mem.span(gtk.gtk_entry_buffer_get_text(gtk.gtk_entry_get_buffer(entry)));
}

fn onIconEntryChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const image = g_icon_preview orelse return;
    const text = std.mem.span(gtk.gtk_entry_buffer_get_text(buffer));
    if (text.len == 0) {
        gtk.gtk_image_set_from_icon_name(image, "application-x-executable-symbolic");
        return;
    }
    var buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const n = @min(text.len, MAX_ROW_TEXT);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_image_set_from_icon_name(image, buf[0..n :0].ptr);
}

fn onRemoveLauncherClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const row_ptr: *const LauncherRow = @ptrCast(@alignCast(user_data.?));
    // The row's address inside the fixed live_launchers array IS its index —
    // pointer subtraction is stable across repopulations (the array never
    // reallocates), which a captured index would not be.
    const idx = (@intFromPtr(row_ptr) - @intFromPtr(&live_launchers.rows[0])) / @sizeOf(LauncherRow);
    if (idx >= live_launchers.len) return;
    live_launchers.removeAt(idx);
    populatePinnedLaunchers();
    saveAndSignal();
}

fn onPinToBarClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const ss: *const SessionShortcut = @ptrCast(@alignCast(user_data.?));
    if (live_launchers.hasCommand(ss.exec())) {
        logging.warn("shortcuts: this app is already pinned ({s}), not duplicating", .{ss.exec()});
        return;
    }
    if (!live_launchers.append(ss.name(), ss.exec(), ss.icon(), 1)) {
        logging.warn("shortcuts: launcher list is full ({d} max), not pinning", .{MAX_LAUNCHERS});
        return;
    }
    populatePinnedLaunchers();
    saveAndSignal();
}

fn addSessionShortcutRow(ss: *SessionShortcut) void {
    const listbox = g_shortcuts_listbox orelse return;
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), @as([:0]const u8, blk: {
        // AdwPreferencesRow's title wants a null-terminated string; ss.name()
        // is a plain slice into name_buf, which isn't itself sentinel-
        // terminated, so route through the same scratch-copy-with-sentinel
        // pattern setEntryText already uses.
        var buf: [MAX_ROW_TEXT + 1]u8 = undefined;
        const n = @min(ss.name().len, MAX_ROW_TEXT);
        @memcpy(buf[0..n], ss.name()[0..n]);
        buf[n] = 0;
        break :blk buf[0..n :0];
    }));
    if (ss.exec().len > 0) {
        var buf: [MAX_ROW_TEXT + 1]u8 = undefined;
        const n = @min(ss.exec().len, MAX_ROW_TEXT);
        @memcpy(buf[0..n], ss.exec()[0..n]);
        buf[n] = 0;
        gtk.adw_action_row_set_subtitle(row, buf[0..n :0].ptr);
    }

    const pin_button = gtk.gtk_button_new_with_label("Pin to Bar");
    gtk.gtk_widget_set_valign(@ptrCast(pin_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(pin_button), "clicked", @ptrCast(&onPinToBarClicked), @ptrCast(ss), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(pin_button));

    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn onCreateShortcutClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const name_entry = g_name_entry orelse return;
    const exec_entry = g_exec_entry orelse return;
    const name = entryText(name_entry);
    const exec = entryText(exec_entry);
    if (name.len == 0 or exec.len == 0) {
        logging.warn("shortcuts: Name and Exec are both required, not creating", .{});
        return;
    }
    const comment = if (g_comment_entry) |e| entryText(e) else "";
    const icon = if (g_icon_entry) |e| entryText(e) else "";

    resolveApplicationsDir();
    var slug_buf: [MAX_ROW_TEXT]u8 = undefined;
    const slug = slugify(name, &slug_buf);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.desktop", .{ applications_dir, slug }) catch {
        logging.warn("shortcuts: slug too long, not creating", .{});
        return;
    };

    const contents = buildDesktopFile(name, comment, exec, icon) catch |err| {
        logging.err("shortcuts: failed to build .desktop contents: {}", .{err});
        return;
    };
    defer gpa.free(contents);
    if (!writeFileAll(path, contents)) {
        logging.err("shortcuts: failed to write {s}", .{path});
        return;
    }

    if (session_shortcuts_len >= session_shortcuts.len) {
        logging.warn("shortcuts: {d} created this session already, not tracking any more (file was still written)", .{session_shortcuts.len});
        return;
    }
    const ss = &session_shortcuts[session_shortcuts_len];
    session_shortcuts_len += 1;
    ss.* = .{};
    ss.name_len = @min(name.len, ss.name_buf.len);
    @memcpy(ss.name_buf[0..ss.name_len], name[0..ss.name_len]);
    ss.exec_len = @min(exec.len, ss.exec_buf.len);
    @memcpy(ss.exec_buf[0..ss.exec_len], exec[0..ss.exec_len]);
    if (icon.len > 0) {
        ss.icon_len = @min(icon.len, ss.icon_buf.len);
        @memcpy(ss.icon_buf[0..ss.icon_len], icon[0..ss.icon_len]);
        ss.has_icon = true;
    }
    addSessionShortcutRow(ss);

    // Clear the form for the next shortcut.
    setEntryText(gtk.gtk_entry_get_buffer(name_entry), "");
    if (g_comment_entry) |e| setEntryText(gtk.gtk_entry_get_buffer(e), "");
    setEntryText(gtk.gtk_entry_get_buffer(exec_entry), "");
    if (g_icon_entry) |e| setEntryText(gtk.gtk_entry_get_buffer(e), "");
}

// Installed Applications picker — "Pin to Bar" with real app icons.
//
// Enumerates every pinnable .desktop file (desktop_entries.zig) once at page
// build and renders each as a row with its freedesktop icon + a Pin button,
// reusing SessionShortcut as the row's backing storage (same label/exec/icon
// buffers; onPinToBarClicked already reads exactly those fields). Pinning
// saves the field-code-stripped Exec and the theme Icon= name, so the bar
// renders the real app icon next to the label instead of a nerd-font glyph.
const MAX_INSTALLED_APPS = 256;

var installed_apps: [MAX_INSTALLED_APPS]SessionShortcut = undefined;
var installed_apps_len: usize = 0;
var g_apps_listbox: ?*gtk.GtkListBox = null;
var g_pinned_listbox: ?*gtk.GtkListBox = null;

fn fillInstalledApp(row: *SessionShortcut, entry: desktop_entries.DesktopEntry) void {
    row.* = .{};
    row.name_len = @min(entry.name.len, row.name_buf.len);
    @memcpy(row.name_buf[0..row.name_len], entry.name[0..row.name_len]);
    row.exec_len = @min(entry.exec.len, row.exec_buf.len);
    @memcpy(row.exec_buf[0..row.exec_len], entry.exec[0..row.exec_len]);
    if (entry.icon.len > 0) {
        row.icon_len = @min(entry.icon.len, row.icon_buf.len);
        @memcpy(row.icon_buf[0..row.icon_len], entry.icon[0..row.icon_len]);
        row.has_icon = true;
    }
}

/// One row of the Shortcuts tab's "Pinned Launchers" list: a live_launchers
/// row mirrored in the GUI with an Unpin suffix button plus a per-launcher
/// display-mode dropdown (Name / Name + icon / Icon). populatePinnedLaunchers()
/// rebuilds the whole list after any pin/unpin, so a captured index would
/// dangle — the Unpin button and dropdown's user_data are instead the row's
/// own stable address inside the fixed live_launchers array.
fn addPinnedLauncherRow(i: usize) void {
    const listbox = g_pinned_listbox orelse return;
    const row = gtk.adw_action_row_new();
    const lrow = &live_launchers.rows[i];
    const lbtn = lrow.button();

    var title_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const n = @min(lbtn.label.len, MAX_ROW_TEXT);
    @memcpy(title_buf[0..n], lbtn.label[0..n]);
    title_buf[n] = 0;
    gtk.adw_preferences_row_set_title(@ptrCast(row), title_buf[0..n :0]);

    var exec_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const m = @min(lbtn.command.len, MAX_ROW_TEXT);
    @memcpy(exec_buf[0..m], lbtn.command[0..m]);
    exec_buf[m] = 0;
    gtk.adw_action_row_set_subtitle(row, exec_buf[0..m :0].ptr);

    if (lbtn.icon) |ic| {
        var icon_z_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
        const k = @min(ic.len, MAX_ROW_TEXT);
        @memcpy(icon_z_buf[0..k], ic[0..k]);
        icon_z_buf[k] = 0;
        const image = gtk.gtk_image_new_from_icon_name(icon_z_buf[0..k :0]);
        gtk.gtk_image_set_pixel_size(image, 28);
        gtk.adw_action_row_add_prefix(row, @ptrCast(image));
    }

    var labels: [DISPLAY_LABELS.len + 1]?[*:0]const u8 = undefined;
    for (DISPLAY_LABELS, 0..) |label, li| labels[li] = label;
    labels[DISPLAY_LABELS.len] = null;
    const dd = gtk.gtk_drop_down_new_from_strings(&labels) orelse {
        const unpin_button = gtk.gtk_button_new_with_label("Unpin");
        gtk.gtk_widget_set_valign(@ptrCast(unpin_button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(unpin_button), "clicked", @ptrCast(&onRemoveLauncherClicked), @ptrCast(lrow), null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(unpin_button));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
        return;
    };
    gtk.gtk_drop_down_set_selected(dd, @intCast(lrow.display_idx));
    gtk.gtk_widget_set_valign(@ptrCast(dd), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(dd), "notify::selected", @ptrCast(&onLauncherDisplayChanged), @ptrCast(lrow), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(dd));

    const unpin_button = gtk.gtk_button_new_with_label("Unpin");
    gtk.gtk_widget_set_valign(@ptrCast(unpin_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(unpin_button), "clicked", @ptrCast(&onRemoveLauncherClicked), @ptrCast(lrow), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(unpin_button));

    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

/// The per-launcher display-mode dropdown changed on a Pinned Launchers
/// row. `user_data` is the row's stable address in the live_launchers array
/// (same convention as onRemoveLauncherClicked); the selected index maps
/// straight onto DISPLAY_CHOICES, so this just stores it and persists.
fn onLauncherDisplayChanged(dd: *gtk.GtkDropDown, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const lrow: *LauncherRow = @ptrCast(@alignCast(user_data.?));
    lrow.setDisplay(gtk.gtk_drop_down_get_selected(dd));
    saveAndSignal();
}

fn populatePinnedLaunchers() void {
    const listbox = g_pinned_listbox orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (0..live_launchers.len) |i| addPinnedLauncherRow(i);
}

fn addInstalledAppRow(a: *SessionShortcut) void {
    const listbox = g_apps_listbox orelse return;
    const row = gtk.adw_action_row_new();
    // Title/subtitle want zero-terminated strings; a's buffers aren't
    // sentinel-terminated, so route through scratch copies (same pattern as
    // addSessionShortcutRow / setEntryText).
    var title_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const n = @min(a.name().len, MAX_ROW_TEXT);
    @memcpy(title_buf[0..n], a.name()[0..n]);
    title_buf[n] = 0;
    gtk.adw_preferences_row_set_title(@ptrCast(row), title_buf[0..n :0]);
    if (a.exec().len > 0) {
        var exec_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
        const m = @min(a.exec().len, MAX_ROW_TEXT);
        @memcpy(exec_buf[0..m], a.exec()[0..m]);
        exec_buf[m] = 0;
        gtk.adw_action_row_set_subtitle(row, exec_buf[0..m :0].ptr);
    }

    var icon_z_buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const icon_z: [:0]const u8 = if (a.icon()) |ic| blk: {
        const k = @min(ic.len, MAX_ROW_TEXT);
        @memcpy(icon_z_buf[0..k], ic[0..k]);
        icon_z_buf[k] = 0;
        break :blk icon_z_buf[0..k :0];
    } else "application-x-executable";
    const image = gtk.gtk_image_new_from_icon_name(icon_z);
    gtk.gtk_image_set_pixel_size(image, 28);
    gtk.adw_action_row_add_prefix(row, @ptrCast(image));

    const pin_button = gtk.gtk_button_new_with_label("Pin");
    gtk.gtk_widget_set_valign(@ptrCast(pin_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(pin_button), "clicked", @ptrCast(&onPinToBarClicked), @ptrCast(a), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(pin_button));

    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn populateInstalledApps() void {
    var entries: std.ArrayList(desktop_entries.DesktopEntry) = .empty;
    defer entries.deinit(gpa);
    // gpa (the process default allocator) is fine here: every parsed string
    // is only read to copy into the stable SessionShortcut buffers above,
    // then the whole list is freed at once.
    desktop_entries.enumerateInstalledApps(gpa, &entries) catch |err| {
        logging.warn("apps: failed to enumerate installed applications: {}", .{err});
        return;
    };
    for (entries.items) |entry| {
        if (installed_apps_len >= installed_apps.len) break;
        const a = &installed_apps[installed_apps_len];
        fillInstalledApp(a, entry);
        installed_apps_len += 1;
        addInstalledAppRow(a);
    }
}

fn addShortcutFormEntry(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, width: c_int) *gtk.GtkEntry {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), width, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
    return entry;
}

fn buildShortcutsPage() *gtk.GtkBox {
    loadConfigFromDisk();

    const outer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(outer), 24);

    const form_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(form_group, "New Shortcut");
    gtk.adw_preferences_group_set_description(form_group, "Creates a .desktop launcher (shows up in the app menu / rofi) — Exec is a plain command, no %f/%u placeholders.");

    g_name_entry = addShortcutFormEntry(form_group, "Name", 220);
    g_comment_entry = addShortcutFormEntry(form_group, "Comment", 260);
    g_exec_entry = addShortcutFormEntry(form_group, "Exec (command)", 260);

    const icon_row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(icon_row), "Icon (theme name)");
    const icon_suffix = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const icon_entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(icon_entry), 200, -1);
    gtk.gtk_widget_set_valign(@ptrCast(icon_entry), gtk.ALIGN_CENTER);
    g_icon_entry = icon_entry;
    const icon_preview = gtk.gtk_image_new_from_icon_name("application-x-executable-symbolic");
    gtk.gtk_image_set_pixel_size(icon_preview, 24);
    g_icon_preview = icon_preview;
    _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(icon_entry)), "notify::text", @ptrCast(&onIconEntryChanged), null, null, 0);
    gtk.gtk_box_append(icon_suffix, @ptrCast(icon_entry));
    gtk.gtk_box_append(icon_suffix, @ptrCast(icon_preview));
    gtk.adw_action_row_add_suffix(icon_row, @ptrCast(icon_suffix));
    gtk.adw_preferences_group_add(form_group, @ptrCast(icon_row));

    const create_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_halign(@ptrCast(create_row), gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(@ptrCast(create_row), 6);
    const create_button = gtk.gtk_button_new_with_label("Create Shortcut");
    gtk.gtk_widget_add_css_class(@ptrCast(create_button), "suggested-action");
    _ = gtk.g_signal_connect_data(@ptrCast(create_button), "clicked", @ptrCast(&onCreateShortcutClicked), null, null, 0);
    gtk.gtk_box_append(create_row, @ptrCast(create_button));

    gtk.gtk_box_append(outer, @ptrCast(form_group));
    gtk.gtk_box_append(outer, @ptrCast(create_row));

    const pinned_heading = gtk.gtk_label_new("Pinned Launchers");
    gtk.gtk_widget_add_css_class(@ptrCast(pinned_heading), "heading");
    gtk.gtk_label_set_xalign(pinned_heading, 0);
    gtk.gtk_widget_set_margin_top(@ptrCast(pinned_heading), 12);
    gtk.gtk_box_append(outer, @ptrCast(pinned_heading));

    const pinned_listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(pinned_listbox), "boxed-list");
    g_pinned_listbox = pinned_listbox;
    gtk.gtk_box_append(outer, @ptrCast(pinned_listbox));
    populatePinnedLaunchers();

    const list_heading = gtk.gtk_label_new("Shortcuts (this session)");
    gtk.gtk_widget_add_css_class(@ptrCast(list_heading), "heading");
    gtk.gtk_label_set_xalign(list_heading, 0);
    gtk.gtk_widget_set_margin_top(@ptrCast(list_heading), 12);
    gtk.gtk_box_append(outer, @ptrCast(list_heading));

    const listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(listbox), "boxed-list");
    g_shortcuts_listbox = listbox;
    gtk.gtk_box_append(outer, @ptrCast(listbox));

    const apps_heading = gtk.gtk_label_new("Installed Applications");
    gtk.gtk_widget_add_css_class(@ptrCast(apps_heading), "heading");
    gtk.gtk_label_set_xalign(apps_heading, 0);
    gtk.gtk_widget_set_margin_top(@ptrCast(apps_heading), 12);
    gtk.gtk_box_append(outer, @ptrCast(apps_heading));

    const apps_listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(apps_listbox), "boxed-list");
    g_apps_listbox = apps_listbox;
    gtk.gtk_box_append(outer, @ptrCast(apps_listbox));
    populateInstalledApps();

    return outer;
}

// ---------------------------------------------------------------------
// Modules tab widgets (Step 6: switches + custom-script fields; Step 7:
// real drag-and-drop reordering). Each group ("Left"/"Center"/"Right" plus
// a "Drawer" filtered view over the right group) is an application-owned GtkListBox (styled with libadwaita's "boxed-list"
// CSS class to keep the same rounded-card look AdwPreferencesGroup gives
// the Appearance tab) rather than an AdwPreferencesGroup — AdwPreferences-
// Group manages its rows via an internal GtkListBox that isn't exposed to
// application code, so there's no way to call gtk_list_box_get_row_at_y /
// remove_all on it from outside, both of which drag-and-drop needs.
// AdwActionRow (via AdwPreferencesRow) is itself a GtkListBoxRow subclass,
// so gtk_list_box_append(listbox, action_row) works exactly the same way
// adw_preferences_group_add did.
// ---------------------------------------------------------------------

fn moduleKindDisplayName(kind: ModuleKind) [:0]const u8 {
    return switch (kind) {
        .workspaces => "Workspaces",
        .mpris => "Media Controls",
        .clock => "Clock",
        .launchers => "Pinned Launchers",
        .power => "Power Button",
        .drawer_toggle => "Drawer Toggle",
        .volume => "Volume",
        .waypaper => "Wallpaper Button", // tombstone: never listed, kept for the switch's exhaustiveness
        .pacman => "Package Updates",
        .tray => "System Tray",
        .weather => "Weather",
        .cpu => "CPU Usage",
        .ram => "RAM Usage",
        .network => "Network",
        .disk => "Disk Usage",
        .battery => "Battery",
        .custom_script => "Custom Script",
        .cpu_temp => "CPU Temperature",
        .cava => "Audio Visualizer",
        .layout => "Mango Layout",
    };
}

/// Copies `text` into a local zero-terminated buffer and hands it to
/// gtk_entry_buffer_set_text — the buffer's own label_buf/command_buf
/// (ModuleRow's fields) aren't zero-terminated (they're plain length-
/// tracked byte buffers, matching every other buffer in this file), so
/// initializing a GtkEntryBuffer's displayed text needs its own scratch
/// copy with a sentinel.
fn setEntryText(buffer: *gtk.GtkEntryBuffer, text: []const u8) void {
    var buf: [MAX_ROW_TEXT + 1]u8 = undefined;
    const n = @min(text.len, MAX_ROW_TEXT);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_entry_buffer_set_text(buffer, buf[0..n :0].ptr, @intCast(n));
}

fn onModuleEnabledChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const row: *ModuleRow = @ptrCast(@alignCast(user_data.?));
    row.entry.enabled = gtk.gtk_switch_get_active(sw) != 0;
    saveAndSignal();
}

fn onCustomLabelChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const row: *ModuleRow = @ptrCast(@alignCast(user_data.?));
    const text = std.mem.span(gtk.gtk_entry_buffer_get_text(buffer));
    const n = @min(text.len, row.label_buf.len);
    @memcpy(row.label_buf[0..n], text[0..n]);
    row.entry.label = row.label_buf[0..n];
    saveAndSignal();
}

fn onCustomCommandChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const row: *ModuleRow = @ptrCast(@alignCast(user_data.?));
    const text = std.mem.span(gtk.gtk_entry_buffer_get_text(buffer));
    const n = @min(text.len, row.command_buf.len);
    @memcpy(row.command_buf[0..n], text[0..n]);
    row.entry.command = row.command_buf[0..n];
    saveAndSignal();
}

fn onCustomIntervalChanged(button: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    const row: *ModuleRow = @ptrCast(@alignCast(user_data.?));
    row.entry.interval_secs = @intCast(gtk.gtk_spin_button_get_value_as_int(button));
    saveAndSignal();
}

/// Bundles a group's backing array with the live GtkListBox displaying it,
/// so the "drop" handler (which only gets whatever user_data it was
/// connected with) can both look up the dragged row's index AND rebuild
/// the right listbox afterward. One of these per group, filled in once at
/// construction time in addModuleGroupSection and never moved again — the
/// drop target's connected user_data points at it for the process's life.
const GroupCtx = struct {
    group: *ModuleGroup,
    listbox: *gtk.GtkListBox,
    reorderable: bool,
    /// The module kinds this group may hold — with cross-group drag, a drop
    /// whose source kind the destination can't legally render is rejected
    /// (rather than persisted and silently ignored by the bar). Left and
    /// Center both allow LEFT_CENTER_MODULE_KINDS; Right allows
    /// RIGHT_MODULE_KINDS.
    allowed: []const ModuleKind,
    /// Which slice of the backing array this section displays. Left/Center
    /// show everything; Right shows only the bar's own modules while the
    /// Drawer section shows the toggle plus in_drawer entries (see
    /// buildModulesPage) — both views share live_right, so a drag between
    /// them just flips the entry's in_drawer flag (handled in onModuleDrop).
    view: ModuleView = .all,
};

/// One Modules-tab section's slice of its backing ModuleGroup.
const ModuleView = enum {
    all, // every entry (Left, Center)
    right_bar, // right entries with in_drawer == false, minus the toggle
    drawer, // the toggle plus right entries with in_drawer == true
};

/// Whether `entry` belongs in a section showing `view`.
fn viewShows(view: ModuleView, entry: *const ModuleEntry) bool {
    return switch (view) {
        .all => true,
        .right_bar => !entry.in_drawer and entry.kind != .drawer_toggle,
        .drawer => entry.in_drawer or entry.kind == .drawer_toggle,
    };
}
var left_ctx: GroupCtx = undefined;
var center_ctx: GroupCtx = undefined;
var right_ctx: GroupCtx = undefined;
var drawer_ctx: GroupCtx = undefined;

const MODULE_ROW_DATA_KEY = "simpbar-module-row";

/// GtkDragSource "prepare" — real signature verified against the installed
/// Gtk-4.0.gir (GdkContentProvider* (GtkDragSource*, gdouble, gdouble,
/// gpointer)). `user_data` is the dragged AdwActionRow's own ModuleRow
/// pointer (stable for the row's lifetime — see the GroupCtx doc comment
/// on why that's safe here). Boxes it in a G_TYPE_POINTER GValue; GTK
/// copies the GValue into the content provider it creates, so the local
/// `value` going out of scope when this returns is fine.
fn onModuleDragPrepare(_: *gtk.GtkDragSource, user_data: ?*anyopaque) callconv(.c) ?*gtk.GdkContentProvider {
    const row_ptr = user_data orelse return null;
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.G_TYPE_POINTER);
    gtk.g_value_set_pointer(&value, row_ptr);
    return gtk.gdk_content_provider_new_for_value(&value);
}

/// Returns the GroupCtx whose group owns `row`, scanning the live groups —
/// the drop handler needs the SOURCE group's ctx (to removeAt from its
/// array and rebuild its listbox) even though the signal only carries the
/// destination's. Right and Drawer share one backing array but are separate
/// views, so a Right↔Drawer drag reports two different ctxs over the same
/// group (onModuleDrop adjusts for that). Null when the pointer is stale
/// (from before a rebuild) or belongs to some other widget's data.
fn groupCtxOwning(row: *const ModuleRow) ?*GroupCtx {
    const candidates = [_]*GroupCtx{ &left_ctx, &center_ctx, &right_ctx, &drawer_ctx };
    for (candidates) |c| {
        if (c.group.indexOf(row) != null) return c;
    }
    return null;
}

/// GtkDropTarget "drop" — real signature verified against the installed
/// Gtk-4.0.gir (gboolean (GtkDropTarget*, const GValue*, gdouble x,
/// gdouble y, gpointer)). `user_data` is this listbox's GroupCtx (the
/// DESTINATION of the drag). Supports both within-group reordering (the
/// existing moveRow path, source == destination) and cross-group moves:
/// the source row is located among all three groups, its kind checked
/// against the destination's allowed set, then removeAt+insertAt transfers
/// it (both affected listboxes rebuilt, config saved + bar signaled). A
/// drop whose kind the destination group can't render is rejected outright
/// — persisting it would let the bar silently ignore it.
fn onModuleDrop(_: *gtk.GtkDropTarget, value: *const gtk.GValue, _: f64, y: f64, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *GroupCtx = @ptrCast(@alignCast(user_data.?));
    const raw = gtk.g_value_get_pointer(value) orelse return 0;
    const source_row: *ModuleRow = @ptrCast(@alignCast(raw));

    const src_ctx = groupCtxOwning(source_row) orelse return 0;

    // Destination insertion index: dropping below the last row appends.
    // Resolved pre-removal against the destination's rows (row pointers go
    // stale across removeAt/insertAt's memmoves, so nothing below may
    // re-derive an index from a widget tag).
    var to_pre: usize = ctx.group.len;
    if (gtk.gtk_list_box_get_row_at_y(ctx.listbox, @intFromFloat(y))) |target_widget| {
        if (gtk.g_object_get_data(@ptrCast(target_widget), MODULE_ROW_DATA_KEY)) |tp| {
            const target_row: *ModuleRow = @ptrCast(@alignCast(tp));
            if (ctx.group.indexOf(target_row)) |idx| to_pre = idx;
        }
    }

    if (src_ctx == ctx) {
        // Same-group reorder — existing behavior. Drop on a row = land at
        // that row's index; below the last row = move to the end.
        const from = src_ctx.group.indexOf(source_row) orelse return 0;
        var to = to_pre;
        if (to >= src_ctx.group.len) to = src_ctx.group.len - 1;
        if (from != to) {
            src_ctx.group.moveRow(from, to);
            rebuildGroupListBox(src_ctx);
            saveAndSignal();
        }
        return 1;
    }

    // Cross-group: the source kind must be drawable by the destination
    // group. Left and Center share LEFT_CENTER_MODULE_KINDS; Right only
    // takes RIGHT_MODULE_KINDS — anything else (e.g. volume → left, or
    // workspaces → right) is a placement the bar can't render, so it's
    // rejected rather than persisted into config.json to be silently
    // ignored.
    const kind = source_row.entry.kind;
    var allowed = false;
    for (ctx.allowed) |k| {
        if (k == kind) {
            allowed = true;
            break;
        }
    }
    if (!allowed) {
        logging.warn("config: {s} can't be moved here — this group doesn't render it", .{moduleKindDisplayName(kind)});
        return 0;
    }

    const from = src_ctx.group.indexOf(source_row) orelse return 0;
    var removed = src_ctx.group.removeAt(from) orelse return 0;
    // Drawer assignment: crossing into the Drawer view flags the entry so it
    // only renders while the drawer is open; crossing into the Right view
    // unflags it back onto the bar. The toggle itself keeps its flag (it is
    // always shown in the Drawer section but renders on the bar).
    if (ctx == &drawer_ctx and removed.entry.kind != .drawer_toggle) removed.entry.in_drawer = true;
    if (ctx == &right_ctx) removed.entry.in_drawer = false;
    // `to` was resolved pre-removal against the destination's rows; when
    // source and destination share one backing array (a Right↔Drawer move),
    // the removal shifted everything past `from` down by one.
    var to = to_pre;
    if (src_ctx.group == ctx.group and from < to) to -= 1;
    if (!ctx.group.insertAt(to, removed)) {
        // Destination full — put the row back where it came from and abort.
        _ = src_ctx.group.insertAt(from, removed);
        logging.warn("config: destination group is full (max {d} modules), move rejected", .{MAX_MODULES});
        return 0;
    }
    rebuildGroupListBox(src_ctx);
    rebuildGroupListBox(ctx);
    saveAndSignal();
    return 1;
}

fn addModuleRow(listbox: *gtk.GtkListBox, row: *ModuleRow, reorderable: bool) void {
    const arow = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(arow), moduleKindDisplayName(row.entry.kind));

    if (row.entry.kind == .custom_script) {
        const label_entry = gtk.gtk_entry_new();
        gtk.gtk_widget_set_size_request(@ptrCast(label_entry), 100, -1);
        gtk.gtk_widget_set_valign(@ptrCast(label_entry), gtk.ALIGN_CENTER);
        const label_buffer = gtk.gtk_entry_get_buffer(label_entry);
        setEntryText(label_buffer, row.entry.label orelse "");
        _ = gtk.g_signal_connect_data(@ptrCast(label_buffer), "notify::text", @ptrCast(&onCustomLabelChanged), @ptrCast(row), null, 0);
        gtk.adw_action_row_add_suffix(arow, @ptrCast(label_entry));

        const command_entry = gtk.gtk_entry_new();
        gtk.gtk_widget_set_size_request(@ptrCast(command_entry), 200, -1);
        gtk.gtk_widget_set_valign(@ptrCast(command_entry), gtk.ALIGN_CENTER);
        const command_buffer = gtk.gtk_entry_get_buffer(command_entry);
        setEntryText(command_buffer, row.entry.command orelse "");
        _ = gtk.g_signal_connect_data(@ptrCast(command_buffer), "notify::text", @ptrCast(&onCustomCommandChanged), @ptrCast(row), null, 0);
        gtk.adw_action_row_add_suffix(arow, @ptrCast(command_entry));

        const interval_spin = gtk.gtk_spin_button_new_with_range(1, 3600, 1);
        gtk.gtk_widget_set_valign(@ptrCast(interval_spin), gtk.ALIGN_CENTER);
        gtk.gtk_spin_button_set_value(interval_spin, @floatFromInt(row.entry.interval_secs orelse 10));
        _ = gtk.g_signal_connect_data(@ptrCast(interval_spin), "value-changed", @ptrCast(&onCustomIntervalChanged), @ptrCast(row), null, 0);
        gtk.adw_action_row_add_suffix(arow, @ptrCast(interval_spin));
    }

    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (row.entry.enabled) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onModuleEnabledChanged), @ptrCast(row), null, 0);
    gtk.adw_action_row_add_suffix(arow, @ptrCast(sw));

    gtk.gtk_list_box_append(listbox, @ptrCast(arow));

    // Tag the row widget with its backing ModuleRow so onModuleDrop can
    // recover it from gtk_list_box_get_row_at_y's result, and make the
    // whole row a drag source carrying that same pointer as its payload.
    // Whole-row dragging (rather than a dedicated handle) is a deliberate
    // v1 simplification — GTK4's drag threshold means a plain click still
    // reaches the switch/entry children fine, only a real drag gesture
    // triggers reordering. Every module row is a drag source now (all three
    // groups are both drag sources and drop targets since cross-group
    // moves landed).
    gtk.g_object_set_data(@ptrCast(arow), MODULE_ROW_DATA_KEY, @ptrCast(row));
    if (reorderable) {
        const drag_source = gtk.gtk_drag_source_new();
        gtk.gtk_drag_source_set_actions(drag_source, gtk.GDK_ACTION_MOVE);
        _ = gtk.g_signal_connect_data(@ptrCast(drag_source), "prepare", @ptrCast(&onModuleDragPrepare), @ptrCast(row), null, 0);
        gtk.gtk_widget_add_controller(@ptrCast(arow), @ptrCast(drag_source));
    }
}

/// Tears down and rebuilds every row in a group's listbox from scratch in
/// its current (post-move) order — simpler and far less error-prone than
/// surgically removing/reinserting just the one moved row while trying to
/// keep every other row's widgets, drag sources, and signal connections
/// alive, at the cost of recreating widgets on every drop (reorders are a
/// low-frequency user action, not a hot path). Renders only the ctx's view
/// slice (the Right and Drawer sections each show part of live_right).
fn rebuildGroupListBox(ctx: *GroupCtx) void {
    gtk.gtk_list_box_remove_all(ctx.listbox);
    for (0..ctx.group.len) |i| {
        if (!viewShows(ctx.view, &ctx.group.rows[i].entry)) continue;
        addModuleRow(ctx.listbox, &ctx.group.rows[i], ctx.reorderable);
    }
}

/// Builds one group's section in the Modules tab: a heading, an optional
/// one-line subtitle, a boxed-list, a drop target (every group is one now —
/// Left/Right/Center all accept cross-group drops), and one draggable row
/// per module in this view's slice. `allowed` is the set of module kinds
/// this group can legally hold (see GroupCtx.allowed); drops of any other
/// kind are rejected by onModuleDrop, so a drop can never land in a group
/// where main.zig has no renderer for it.
fn addModuleGroupSection(outer: *gtk.GtkBox, title: [:0]const u8, mgroup: *ModuleGroup, ctx: *GroupCtx, allowed: []const ModuleKind, view: ModuleView, subtitle: ?[:0]const u8) void {
    const heading = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(@ptrCast(heading), "heading");
    gtk.gtk_label_set_xalign(heading, 0);
    gtk.gtk_box_append(outer, @ptrCast(heading));

    if (subtitle) |st| {
        const sub = gtk.gtk_label_new(st);
        gtk.gtk_widget_add_css_class(@ptrCast(sub), "dim-label");
        gtk.gtk_label_set_xalign(sub, 0);
        gtk.gtk_label_set_wrap(sub, 1);
        gtk.gtk_box_append(outer, @ptrCast(sub));
    }

    const listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(listbox), "boxed-list");
    // Give every listbox a generous minimum height regardless of how few
    // rows it holds — a short group is an easy-to-overshoot drop target
    // since GtkDropTarget only fires "drop" while the pointer is still
    // over the widget it's attached to. Padding the listbox's own minimum
    // size out to a fixed floor gives every group a comparably forgiving
    // drop zone without needing to move the drop target onto a different
    // (larger) widget and translate coordinates between them.
    gtk.gtk_widget_set_size_request(@ptrCast(listbox), -1, 160);
    ctx.* = .{ .group = mgroup, .listbox = listbox, .reorderable = true, .allowed = allowed, .view = view };

    const drop_target = gtk.gtk_drop_target_new(gtk.G_TYPE_POINTER, gtk.GDK_ACTION_MOVE);
    _ = gtk.g_signal_connect_data(@ptrCast(drop_target), "drop", @ptrCast(&onModuleDrop), @ptrCast(ctx), null, 0);
    gtk.gtk_widget_add_controller(@ptrCast(listbox), @ptrCast(drop_target));

    for (0..mgroup.len) |i| {
        if (!viewShows(view, &mgroup.rows[i].entry)) continue;
        addModuleRow(listbox, &mgroup.rows[i], true);
    }
    gtk.gtk_box_append(outer, @ptrCast(listbox));
}

fn buildModulesPage() *gtk.GtkBox {
    loadConfigFromDisk();

    const outer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(outer), 24);

    addModuleGroupSection(outer, "Left", &live_left, &left_ctx, &LEFT_CENTER_MODULE_KINDS, .all, null);
    addModuleGroupSection(outer, "Center", &live_center, &center_ctx, &LEFT_CENTER_MODULE_KINDS, .all, null);
    addModuleGroupSection(outer, "Right", &live_right, &right_ctx, &RIGHT_MODULE_KINDS, .right_bar, "Modules pinned to the bar's right edge, always visible.");
    addModuleGroupSection(outer, "Drawer", &live_right, &drawer_ctx, &RIGHT_MODULE_KINDS, .drawer, "The toggle button plus modules that appear when it opens. Drag modules between Right and Drawer to assign them.");

    return outer;
}

// ---------------------------------------------------------------------
// Window / application — structure mirrors welcome_main.zig's buildWindow.
// ---------------------------------------------------------------------

const PAGE_NAMES = [_][:0]const u8{ "Appearance", "Modules", "Shortcuts" };
const PAGE_ICONS = [_][:0]const u8{ "applications-graphics-symbolic", "view-list-symbolic", "user-bookmarks-symbolic" };
const BAR_COUNT = PAGE_NAMES.len;

// "Bar" pages + compositor pages, in sidebar order. The compositor section is
// Hyprland on Hyprland and Mango on MangoWM; both decks have the same number
// of pages (9), so only the names/icons and the section header change at
// runtime. The header rows ("Bar" / "Hyprland"|"Mango") are inserted between
// the two groups at build time.
const SB_COUNT = BAR_COUNT + hypr_pages.pages.names.len;
var g_sb_names: [SB_COUNT][:0]const u8 = undefined;
var g_sb_icons: [SB_COUNT][:0]const u8 = undefined;

fn setupSidebarNames() void {
    for (PAGE_NAMES, 0..) |n, i| {
        g_sb_names[i] = n;
        g_sb_icons[i] = PAGE_ICONS[i];
    }
    const names = if (hypr_pages.g_mango) &mango_pages.pages.names else &hypr_pages.pages.names;
    const icons = if (hypr_pages.g_mango) &mango_pages.pages.icons else &hypr_pages.pages.icons;
    for (names.*, 0..) |n, i| g_sb_names[BAR_COUNT + i] = n;
    for (icons.*, 0..) |ic, i| g_sb_icons[BAR_COUNT + i] = ic;
}

var g_sidebar_rows: [SB_COUNT]*gtk.GtkListBoxRow = undefined;
var g_content_stack: ?*gtk.GtkStack = null;
var g_window: ?*gtk.AdwApplicationWindow = null;

fn onSidebarRowSelected(_: *gtk.GtkListBox, row: ?*gtk.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const r = row orelse return;
    for (g_sidebar_rows, 0..) |sr, i| {
        if (sr == r) {
            gtk.gtk_stack_set_visible_child_name(g_content_stack.?, g_sb_names[i]);
            return;
        }
    }
}

fn addSidebarRow(sidebar_list: *gtk.GtkListBox, name: [:0]const u8, icon: [:0]const u8, selectable: bool, index: usize) void {
    const row = gtk.gtk_list_box_row_new();
    hg.gtk_list_box_row_set_selectable(row, if (selectable) 1 else 0);
    if (!selectable) {
        gtk.gtk_widget_add_css_class(@ptrCast(row), "dim-label");
    }
    const row_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_top(@ptrCast(row_box), if (selectable) 8 else 4);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(row_box), if (selectable) 8 else 4);
    gtk.gtk_widget_set_margin_start(@ptrCast(row_box), 12);
    gtk.gtk_widget_set_margin_end(@ptrCast(row_box), 12);
    if (selectable and icon.len != 0) {
        gtk.gtk_box_append(row_box, @ptrCast(gtk.gtk_image_new_from_icon_name(icon)));
    }
    const label = gtk.gtk_label_new(name);
    gtk.gtk_label_set_xalign(label, 0);
    gtk.gtk_box_append(row_box, @ptrCast(label));
    gtk.gtk_list_box_row_set_child(row, @ptrCast(row_box));
    gtk.gtk_list_box_append(sidebar_list, @ptrCast(row));
    if (selectable) g_sidebar_rows[index] = row;
}

fn onReloadClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    _ = hypr.reloadHyprland();
}

fn onReloadMangoClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    mango_pages.reload();
}

fn buildWindow(app: *anyopaque) *gtk.AdwApplicationWindow {
    hypr_pages.init();
    if (hypr_pages.g_mango) {
        mango_pages.init();
    }
    setupSidebarNames();
    const section_title: [:0]const u8 = if (hypr_pages.g_mango) "Mango" else "Hyprland";

    const window = gtk.adw_application_window_new(app);
    gtk.gtk_window_set_title(@ptrCast(window), "Simpbar Config");
    // Widened from the original 700 — Nerd Font family names ("JetBrainsMonoNL
    // Nerd Font", etc.) were getting truncated in the font dropdown at 700px,
    // making it impossible to tell entries apart well enough to pick one.
    gtk.gtk_window_set_default_size(@ptrCast(window), 1000, 600);

    const split_view = gtk.adw_navigation_split_view_new();

    const sidebar_list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(sidebar_list), "navigation-sidebar");
    gtk.gtk_list_box_set_selection_mode(sidebar_list, gtk.SELECTION_SINGLE);

    const bar_pages = [_]*gtk.GtkBox{
        buildAppearancePage(),
        buildModulesPage(),
        buildShortcutsPage(),
    };

    const content_stack = gtk.gtk_stack_new();
    gtk.gtk_stack_set_transition_type(content_stack, gtk.STACK_TRANSITION_CROSSFADE);
    gtk.gtk_widget_set_vexpand(@ptrCast(content_stack), 1);
    gtk.gtk_widget_set_hexpand(@ptrCast(content_stack), 1);
    g_content_stack = content_stack;

    addSidebarRow(sidebar_list, "Bar", "", false, SB_COUNT);
    for (0..BAR_COUNT) |i| {
        addSidebarRow(sidebar_list, PAGE_NAMES[i], PAGE_ICONS[i], true, i);
    }
    addSidebarRow(sidebar_list, section_title, "", false, SB_COUNT);
    for (BAR_COUNT..SB_COUNT) |i| {
        addSidebarRow(sidebar_list, g_sb_names[i], g_sb_icons[i], true, i);
    }

    const sec_widgets = if (hypr_pages.g_mango) mango_pages.pages.widgets() else hypr_pages.pages.widgets();
    var page_widgets: [SB_COUNT]*gtk.GtkBox = undefined;
    for (bar_pages, 0..) |p, i| page_widgets[i] = p;
    for (sec_widgets, 0..) |p, i| page_widgets[BAR_COUNT + i] = p;

    for (g_sb_names, 0..) |name, i| {
        const scrolled = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
        gtk.gtk_widget_set_vexpand(@ptrCast(scrolled), 1);
        gtk.gtk_widget_set_hexpand(@ptrCast(scrolled), 1);
        gtk.gtk_scrolled_window_set_child(scrolled, @ptrCast(page_widgets[i]));
        _ = gtk.gtk_stack_add_named(content_stack, @ptrCast(scrolled), name);
    }

    _ = gtk.g_signal_connect_data(@ptrCast(sidebar_list), "row-selected", @ptrCast(&onSidebarRowSelected), null, null, 0);

    const sidebar_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(sidebar_toolbar, @ptrCast(gtk.adw_header_bar_new()));
    gtk.adw_toolbar_view_set_content(sidebar_toolbar, @ptrCast(sidebar_list));
    const sidebar_page = gtk.adw_navigation_page_new(@ptrCast(sidebar_toolbar), "Simpbar Config");
    gtk.adw_navigation_split_view_set_sidebar(split_view, sidebar_page);


    const content_header_bar = gtk.adw_header_bar_new();
    if (hypr_pages.g_mango) {
        const reload_btn = gtk.gtk_button_new_with_label("Reload Mango");
        _ = gtk.g_signal_connect_data(@ptrCast(reload_btn), "clicked", @ptrCast(&onReloadMangoClicked), null, null, 0);
        hg.adw_header_bar_pack_end(content_header_bar, @ptrCast(reload_btn));
    } else { // hyprctl reload is meaningless under MangoWM
        const reload_btn = gtk.gtk_button_new_with_label("Reload Hyprland");
        _ = gtk.g_signal_connect_data(@ptrCast(reload_btn), "clicked", @ptrCast(&onReloadClicked), null, null, 0);
        hg.adw_header_bar_pack_end(content_header_bar, @ptrCast(reload_btn));
    }
    const content_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(content_toolbar, @ptrCast(content_header_bar));
    gtk.adw_toolbar_view_set_content(content_toolbar, @ptrCast(content_stack));
    const content_page = gtk.adw_navigation_page_new(@ptrCast(content_toolbar), "");
    gtk.adw_navigation_split_view_set_content(split_view, content_page);

    gtk.adw_application_window_set_content(window, @ptrCast(split_view));

    gtk.gtk_list_box_select_row(sidebar_list, gtk.gtk_list_box_get_row_at_index(sidebar_list, 1));

    return window;
}

fn onAppActivate(app: *gtk.GApplication, _: ?*anyopaque) callconv(.c) void {
    // The system-wide icon theme doesn't have full coverage of generic
    // symbolic icon names — force Adwaita for this app specifically, same
    // as simpbar-welcome does, without touching the system-wide setting.
    if (gtk.gtk_settings_get_default()) |settings| {
        gtk.g_object_set(@ptrCast(settings), "gtk-icon-theme-name", @as([*:0]const u8, "Adwaita"), @as(?*anyopaque, null));
    }

    if (g_window == null) {
        g_window = buildWindow(@ptrCast(app));
    }
    gtk.gtk_window_present(@ptrCast(g_window.?));
    logging.step("window shown", .{});
}

pub fn main() void {
    logging.init("simpbar-config");
    realMain() catch |err| {
        logging.err("fatal: {s}", .{@errorName(err)});
        logging.crash("fatal error: {s}", .{@errorName(err)});
        logging.dumpCurrentStack();
        std.process.exit(1);
    };
}

fn realMain() !void {
    logging.step("starting up", .{});
    const app = gtk.adw_application_new(APP_ID, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&onAppActivate), null, null, 0);
    const code = gtk.g_application_run(@ptrCast(app), 0, null);
    logging.step("gtk main loop exited with code {d}", .{code});
    exit(code);
}

// ---------------------------------------------------------------------
// Tests — drawer/right view separation (pure data logic, no display).
// Run: zig test src/config_main.zig -lc -fllvm -flld <gtk libs, see below>
// ---------------------------------------------------------------------

test "drawer view separation" {
    const t = std.testing;
    // Backing right group: toggle, weather (bar), volume + pacman (drawer).
    var g: ModuleGroup = .{};
    const kinds = [_]ModuleKind{ .drawer_toggle, .weather, .volume, .pacman };
    const drawer = [_]bool{ false, false, true, true };
    for (kinds, 0..) |k, i| {
        g.rows[i] = .{ .entry = .{ .kind = k, .enabled = true, .in_drawer = drawer[i] } };
    }
    g.len = kinds.len;

    // Right view: bar modules only, no toggle.
    var right_shown: usize = 0;
    var right_kind: ModuleKind = .weather;
    for (g.rows[0..g.len]) |*row| {
        if (!viewShows(.right_bar, &row.entry)) continue;
        right_shown += 1;
        right_kind = row.entry.kind;
    }
    try t.expectEqual(@as(usize, 1), right_shown);
    try t.expectEqual(ModuleKind.weather, right_kind);

    // Drawer view: toggle + flagged entries.
    var drawer_kinds: [4]ModuleKind = undefined;
    var drawer_n: usize = 0;
    for (g.rows[0..g.len]) |*row| {
        if (!viewShows(.drawer, &row.entry)) continue;
        drawer_kinds[drawer_n] = row.entry.kind;
        drawer_n += 1;
    }
    try t.expectEqual(@as(usize, 3), drawer_n);
    try t.expectEqual(ModuleKind.drawer_toggle, drawer_kinds[0]);
    try t.expectEqual(ModuleKind.volume, drawer_kinds[1]);
    try t.expectEqual(ModuleKind.pacman, drawer_kinds[2]);

    // Simulate a Right→Drawer drop of weather below pacman: remove at 1,
    // flag it, insert at the drawer's end (backing index 3 post-removal).
    var moved = g.removeAt(1) orelse return error.TestUnexpectedResult;
    moved.entry.in_drawer = true;
    try t.expect(g.insertAt(3, moved));
    try t.expectEqual(@as(usize, 4), g.len);
    try t.expectEqual(ModuleKind.drawer_toggle, g.rows[0].entry.kind);
    try t.expectEqual(ModuleKind.volume, g.rows[1].entry.kind);
    try t.expectEqual(ModuleKind.pacman, g.rows[2].entry.kind);
    try t.expectEqual(ModuleKind.weather, g.rows[3].entry.kind);
    try t.expect(g.rows[3].entry.in_drawer);
    // Weather left the Right view and joined the Drawer view.
    try t.expect(!viewShows(.right_bar, &g.rows[3].entry));
    try t.expect(viewShows(.drawer, &g.rows[3].entry));

    // Same-backing index adjustment: dropping onto backing index 3 after
    // removing index 1 lands at 2.
    var to: usize = 3;
    if (1 < to) to -= 1;
    try t.expectEqual(@as(usize, 2), to);
}

test "tombstoned kinds strip cleanly" {
    const t = std.testing;
    var g: ModuleGroup = .{};
    const kinds = [_]ModuleKind{ .weather, .waypaper, .volume, .waypaper, .pacman };
    for (kinds, 0..) |k, i| {
        g.rows[i] = .{ .entry = .{ .kind = k, .enabled = true } };
    }
    g.len = kinds.len;
    stripRemovedKinds(&g);
    try t.expectEqual(@as(usize, 3), g.len);
    try t.expectEqual(ModuleKind.weather, g.rows[0].entry.kind);
    try t.expectEqual(ModuleKind.volume, g.rows[1].entry.kind);
    try t.expectEqual(ModuleKind.pacman, g.rows[2].entry.kind);
    // Idempotent: nothing left to strip.
    stripRemovedKinds(&g);
    try t.expectEqual(@as(usize, 3), g.len);
}


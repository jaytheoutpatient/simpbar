// Simpbar Config — Hyprland settings state: model, JSON persistence, and
// generation of the managed Lua snippet that Hyprland loads.
//
// Design (chosen with the user):
//   - simpbar-config owns `~/.config/simpbar/hyprland.json` — the source of
//     truth. The generated file it drives is `~/.config/hypr/hyprland-simpbar.lua`,
//     which the user's `hyprland.lua` picks up via `pcall(require, "hyprland-simpbar")`
//     (injected idempotently by bootstrapping; the user's own config is never
//     otherwise touched).
//   - Keeping a JSON state file (rather than re-parsing Lua) matches how the
//     bar handles its own config, and sidesteps hand-parsing Lua in Zig.
//   - Every edit writes JSON + regenerates the Lua immediately; applying it to
//     the running compositor is either Hyprland's config auto-reload (default,
//     watches the config dir) or the explicit "Reload Hyprland" action.
//
// Mirrors config_main.zig's style: libc externs for file I/O, gpa-backed
// allocations, hand-formatted JSON (no std.json.Stringify), fixed-size
// capacity arrays for every list so row widgets can live at stable addresses
// and be handed to GTK callbacks as user_data (the same pattern the bar's
// own ModuleGroup/LauncherGroup use).

const std = @import("std");

// ---------------------------------------------------------------------
// libc externs (self-contained, same block shape as config_main.zig)
// ---------------------------------------------------------------------

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

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
// Paths
// ---------------------------------------------------------------------

const MAX_PATH = 512;
const JSON_REL = "/.config/simpbar/hyprland.json";
const LUA_REL = "/.config/hypr/hyprland-simpbar.lua";
const MAIN_CONFIG_REL = "/.config/hypr/hyprland.lua";
const REQUIRED_MARKER_LINE = "pcall(require, \"hyprland-simpbar\")";

var state_json_path: [MAX_PATH:0]u8 = undefined;
var managed_lua_path: [MAX_PATH:0]u8 = undefined;
var main_config_path: [MAX_PATH:0]u8 = undefined;
var home_slice: []const u8 = "";

fn resolveBase() []const u8 {
    if (home_slice.len != 0) return home_slice;
    home_slice = std.mem.span(getenv("HOME") orelse "/root");
    return home_slice;
}

fn initPaths() void {
    const home = resolveBase();
    _ = std.fmt.bufPrintZ(&state_json_path, "{s}{s}", .{ home, JSON_REL }) catch {};
    _ = std.fmt.bufPrintZ(&managed_lua_path, "{s}{s}", .{ home, LUA_REL }) catch {};
    _ = std.fmt.bufPrintZ(&main_config_path, "{s}{s}", .{ home, MAIN_CONFIG_REL }) catch {};

    var config_dir: [MAX_PATH]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&config_dir, "{s}/.config/simpbar", .{home}) catch return;
    _ = mkdir(dir.ptr, 0o755);
}

// ---------------------------------------------------------------------
// File I/O helpers
// ---------------------------------------------------------------------

fn readFileAll(path: [:0]const u8) ?[]u8 {
    if (path.len == 0) return null;
    const fd = open(path, 0, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch break;
        if (list.items.len > 4 * 1024 * 1024) break;
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn writeFileAll(path: [:0]const u8, data: []const u8) bool {
    if (path.len == 0) return false;
    const fd = open(path, 1 | O_CREAT | O_TRUNC, 0o644);
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

/// Atomic write via a same-directory temp file + rename. Worth it for the
/// generated Lua: Hyprland's config auto-reload watches the config dir and
/// could observe a half-written file mid-write otherwise.
fn writeFileAtomic(path: [:0]const u8, data: []const u8) bool {
    if (path.len == 0) return false;
    const dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse return false];
    var tmp_buf: [MAX_PATH]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.simpbar-tmp-{d}", .{ dir, std.c.getpid() }) catch return false;
    if (!writeFileAll(tmp, data)) {
        _ = unlink(tmp);
        return false;
    }
    if (rename(tmp, path) != 0) {
        _ = unlink(tmp);
        return false;
    }
    return true;
}

fn runQuiet(argv: []const []const u8, timeout_ms: i32) bool {
    if (argv.len == 0 or argv.len > 12) return false;
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return false;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const pid = libc_proc.fork();
    if (pid < 0) {
        _ = close(read_fd);
        _ = close(write_fd);
        return false;
    }
    if (pid == 0) {
        _ = close(read_fd);
        _ = dup2(write_fd, 1);
        _ = dup2(write_fd, 2);
        _ = close(write_fd);
        var buf: [13]?[*:0]const u8 = undefined;
        buf[0] = "/usr/bin/env";
        var z: [12][MAX_PATH]u8 = undefined;
        for (argv, 0..) |a, i| {
            const n = @min(a.len, MAX_PATH - 1);
            @memcpy(z[i][0..n], a[0..n]);
            z[i][n] = 0;
            buf[i + 1] = z[i][0..n :0].ptr;
        }
        buf[argv.len + 1] = null;
        _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
        std.c._exit(127);
    }
    _ = close(write_fd);

    var chunk: [1024]u8 = undefined;
    var timed_out = false;
    while (true) {
        var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
        const pr = poll(&pfd, 1, timeout_ms);
        if (pr <= 0) {
            timed_out = true;
            break;
        }
        const n = read(read_fd, &chunk, chunk.len);
        if (n <= 0) break;
    }
    _ = close(read_fd);
    if (timed_out) {
        _ = std.c.kill(pid, .KILL);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    return !timed_out;
}

// ---------------------------------------------------------------------
// Text buffer — the model's only string type. Fixed-capacity so every
// row (and its field) lives at a stable address for the process's life,
// exactly like config_main.zig's ModuleRow/LAB_buf pattern; never copied
// by value once a widget callback has been handed `&row`.
// ---------------------------------------------------------------------

pub const Text = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Text, s: []const u8) void {
        const fld = &(self.*.buf);
        const n = @min(s.len, fld.len);
        @memcpy(fld[0..n], s[0..n]);
        self.len = n;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Text) bool {
        return self.len == 0;
    }

    /// Short description for list subtitles / fallback names.
    pub fn preview(self: *const Text, max: usize) []const u8 {
        return self.buf[0..@min(self.len, max)];
    }
};

fn textFromSlice(t: *Text, s: []const u8) void {
    t.set(s);
}

// ---------------------------------------------------------------------
// Capacity constants
// ---------------------------------------------------------------------

pub const MAX_MONITORS = 8;
pub const MAX_BINDS = 64;
pub const MAX_RULES = 48;
pub const MAX_AUTOSTART = 48;
pub const MAX_ENV = 48;
pub const MAX_CURVES = 24;
pub const MAX_LEAVES = 24;

// ---------------------------------------------------------------------
// General appearance/settings
// ---------------------------------------------------------------------

pub const LayoutChoice = enum { master, dwindle, scrolling };

pub const General = struct {
    gaps_in: i32 = 1,
    gaps_out: i32 = 1,
    border_size: i32 = 1,
    rounding: i32 = 0,
    rounding_power: f64 = 0.0,
    active_opacity: f64 = 1.0,
    inactive_opacity: f64 = 1.0,
    allow_tearing: bool = false,
    layout: LayoutChoice = .master,

    blur_enabled: bool = true,
    blur_size: i32 = 8,
    blur_passes: i32 = 1,
    blur_vibrancy: f64 = 0.1696,
    blur_noise: f64 = 0.0117,
    blur_new_optimizations: bool = true,

    shadow_enabled: bool = true,
    shadow_range: i32 = 4,
    shadow_render_power: i32 = 3,
    shadow_color: Text = .{},

    active_border: Text = .{},
    inactive_border: Text = .{},
};

pub const Input = struct {
    kb_layout: Text = .{},
    kb_variant: Text = .{},
    follow_mouse: i32 = 1,
    accel_profile: Text = .{},
    sensitivity: f64 = 0.0,
    natural_scroll: bool = false,
};

// ---------------------------------------------------------------------
// Monitors
// ---------------------------------------------------------------------

pub const Monitor = struct {
    enabled: bool = true,
    output: Text = .{},
    mode: Text = .{},
    position: Text = .{},
    scale: Text = .{},
    vrr: i32 = -1,
};

// ---------------------------------------------------------------------
// Animations / curves
// ---------------------------------------------------------------------

pub const CurveType = enum { bezier, spring };

pub const Curve = struct {
    name: Text = .{},
    ctype: CurveType = .bezier,
    x1: f64 = 0.0, y1: f64 = 0.0,
    x2: f64 = 1.0, y2: f64 = 1.0,
    mass: f64 = 1.0,
    stiffness: f64 = 60.0,
    dampening: f64 = 20.0,
};

pub const Leaf = struct {
    leaf: Text = .{},
    enabled: bool = true,
    speed: f64 = 4.0,
    curve: Text = .{}, // references a Curve name (or "default")
    style: Text = .{},
};

pub const Animations = struct {
    enabled: bool = true,
    curves: [MAX_CURVES]Curve = undefined,
    curves_len: usize = 0,
    leaves: [MAX_LEAVES]Leaf = undefined,
    leaves_len: usize = 0,
};

// ---------------------------------------------------------------------
// Keybinds
// ---------------------------------------------------------------------

pub const BindAction = enum {
    exec,
    close,
    toggle_float,
    pseudo,
    toggle_fullscreen,
    center,
    pin,
    drag,
    resize,
    focus_dir,
    focus_workspace,
    move_dir,
    move_workspace,
    layout,
    toggle_special,
    exit,

    pub fn displayName(self: BindAction) [:0]const u8 {
        return switch (self) {
            .exec => "Exec command",
            .close => "Close window",
            .toggle_float => "Toggle floating",
            .pseudo => "Toggle pseudo-tiling",
            .toggle_fullscreen => "Toggle fullscreen",
            .center => "Center window",
            .pin => "Toggle pinning",
            .drag => "Drag (move) window",
            .resize => "Resize window",
            .focus_dir => "Focus direction",
            .focus_workspace => "Focus workspace",
            .move_dir => "Move window direction",
            .move_workspace => "Move window to workspace",
            .layout => "Layout message",
            .toggle_special => "Toggle special workspace",
            .exit => "Exit Hyprland",
        };
    }
};

pub const Bind = struct {
    enabled: bool = true,
    combo: Text = .{},
    action: BindAction = .exec,
    arg: Text = .{},
    locked: bool = false,
    repeating: bool = false,
    mouse: bool = false,
};

// ---------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------

pub const WindowRule = struct {
    enabled: bool = true,
    name: Text = .{},
    class: Text = .{},
    title: Text = .{},
    app_id: Text = .{},
    workspace: Text = .{},
    // -1 = unset/any, 0 = false, 1 = true
    xwayland: i32 = -1,
    float_state: i32 = -1,
    opts: Text = .{}, // comma-separated "float, size 400 500, move 20 monitor_h-120"
};

pub const WorkspaceRule = struct {
    enabled: bool = true,
    workspace: Text = .{},
    monitor: Text = .{},
    opts: Text = .{},
};

pub const LayerRule = struct {
    enabled: bool = true,
    name: Text = .{},
    namespace: Text = .{},
    opts: Text = .{},
};

// ---------------------------------------------------------------------
// Autostart / env
// ---------------------------------------------------------------------

pub const EnvVar = struct {
    key: Text = .{},
    value: Text = .{},
};

// ---------------------------------------------------------------------
// Full state
// ---------------------------------------------------------------------

pub const HyprState = struct {
    general: General = .{},
    input: Input = .{},
    anim: Animations = .{},
    monitors: [MAX_MONITORS]Monitor = undefined,
    monitors_len: usize = 0,
    binds: [MAX_BINDS]Bind = undefined,
    binds_len: usize = 0,
    wrules: [MAX_RULES]WindowRule = undefined,
    wrules_len: usize = 0,
    wsrules: [MAX_RULES]WorkspaceRule = undefined,
    wsrules_len: usize = 0,
    lrules: [MAX_RULES]LayerRule = undefined,
    lrules_len: usize = 0,
    autostart: [MAX_AUTOSTART]Text = undefined,
    autostart_len: usize = 0,
    envs: [MAX_ENV]EnvVar = undefined,
    envs_len: usize = 0,
};

pub var state: HyprState = .{};
var state_loaded = false;
var bootstrapped = false;

// Default curve/leaf set mirroring Hyprland's generated example config, so
// the Animations page is immediately usable and its output matches what
// Hyprland ships by default.
const DEFAULT_CURVES = [_]struct { name: []const u8, ctype: CurveType, x1: f64, y1: f64, x2: f64, y2: f64, mass: f64, stiffness: f64, dampening: f64 }{
    .{ .name = "easeOutQuint", .ctype = .bezier, .x1 = 0.23, .y1 = 1, .x2 = 0.32, .y2 = 1, .mass = 1, .stiffness = 1, .dampening = 1 },
    .{ .name = "easeInOutCubic", .ctype = .bezier, .x1 = 0.65, .y1 = 0.05, .x2 = 0.36, .y2 = 1, .mass = 1, .stiffness = 1, .dampening = 1 },
    .{ .name = "linear", .ctype = .bezier, .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .mass = 1, .stiffness = 1, .dampening = 1 },
    .{ .name = "almostLinear", .ctype = .bezier, .x1 = 0.5, .y1 = 0.5, .x2 = 0.75, .y2 = 1, .mass = 1, .stiffness = 1, .dampening = 1 },
    .{ .name = "quick", .ctype = .bezier, .x1 = 0.15, .y1 = 0, .x2 = 0.1, .y2 = 1, .mass = 1, .stiffness = 1, .dampening = 1 },
    .{ .name = "easy", .ctype = .spring, .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0, .mass = 1, .stiffness = 71.2633, .dampening = 15.8273644 },
};

const DEFAULT_LEAVES = [_]struct { leaf: []const u8, speed: f64, curve: []const u8, style: []const u8 }{
    .{ .leaf = "global", .speed = 10, .curve = "default", .style = "" },
    .{ .leaf = "border", .speed = 5.39, .curve = "easeOutQuint", .style = "" },
    .{ .leaf = "windows", .speed = 4.79, .curve = "easy", .style = "" },
    .{ .leaf = "windowsIn", .speed = 4.1, .curve = "easy", .style = "popin 87%" },
    .{ .leaf = "windowsOut", .speed = 1.49, .curve = "linear", .style = "popin 87%" },
    .{ .leaf = "fadeIn", .speed = 1.73, .curve = "almostLinear", .style = "" },
    .{ .leaf = "fadeOut", .speed = 1.46, .curve = "almostLinear", .style = "" },
    .{ .leaf = "fade", .speed = 3.03, .curve = "quick", .style = "" },
    .{ .leaf = "layers", .speed = 3.81, .curve = "easeOutQuint", .style = "" },
    .{ .leaf = "layersIn", .speed = 4, .curve = "easeOutQuint", .style = "fade" },
    .{ .leaf = "layersOut", .speed = 1.5, .curve = "linear", .style = "fade" },
    .{ .leaf = "fadeLayersIn", .speed = 1.79, .curve = "almostLinear", .style = "" },
    .{ .leaf = "fadeLayersOut", .speed = 1.39, .curve = "almostLinear", .style = "" },
    .{ .leaf = "workspaces", .speed = 1.94, .curve = "almostLinear", .style = "fade" },
    .{ .leaf = "workspacesIn", .speed = 1.21, .curve = "almostLinear", .style = "fade" },
    .{ .leaf = "workspacesOut", .speed = 1.94, .curve = "almostLinear", .style = "fade" },
    .{ .leaf = "zoomFactor", .speed = 7, .curve = "quick", .style = "" },
};

fn seedDefaults() void {
    state = .{};
    var cbuf: [MAX_CURVES]Curve = undefined;
    for (DEFAULT_CURVES, 0..) |d, i| {
        cbuf[i] = .{ .ctype = d.ctype, .x1 = d.x1, .y1 = d.y1, .x2 = d.x2, .y2 = d.y2, .mass = d.mass, .stiffness = d.stiffness, .dampening = d.dampening };
        cbuf[i].name.set(d.name);
    }
    state.anim.curves = cbuf;
    state.anim.curves_len = DEFAULT_CURVES.len;

    var lbuf: [MAX_LEAVES]Leaf = undefined;
    for (DEFAULT_LEAVES, 0..) |d, i| {
        lbuf[i] = .{ .enabled = true, .speed = d.speed };
        lbuf[i].leaf.set(d.leaf);
        lbuf[i].curve.set(d.curve);
        lbuf[i].style.set(d.style);
    }
    state.anim.leaves = lbuf;
    state.anim.leaves_len = DEFAULT_LEAVES.len;

    state.general.shadow_color.set("0xee1a1a1a");
    state.general.active_border.set("#dcdcdc");
    state.general.inactive_border.set("#454545");
    state.input.kb_layout.set("us");
    state.input.kb_variant.set("");
    state.input.accel_profile.set("flat");
}

// ---------------------------------------------------------------------
// JSON persistence — hand-formatted, matching config_main.zig's approach.
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

fn appendText(list: *std.ArrayList(u8), t: Text) !void {
    try appendJsonString(list, t.slice());
}

fn appendInt(list: *std.ArrayList(u8), v: i64) !void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(gpa, text);
}

fn appendFloat(list: *std.ArrayList(u8), v: f64) !void {
    if (v == @floor(v) and @abs(v) < 1e15) {
        var buf: [32]u8 = undefined;
        // integer-valued floats serialize as "3.0" so the type is preserved.
        const text = std.fmt.bufPrint(&buf, "{d:.1}", .{v}) catch unreachable;
        try list.appendSlice(gpa, text);
    } else {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
        try list.appendSlice(gpa, text);
    }
}

fn appendBool(list: *std.ArrayList(u8), v: bool) !void {
    try list.appendSlice(gpa, if (v) "true" else "false");
}

fn buildStateJson() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    try list.appendSlice(gpa, "{\"general\":{");
    try list.appendSlice(gpa, "\"gaps_in\":"); try appendInt(&list, state.general.gaps_in);
    try list.appendSlice(gpa, ",\"gaps_out\":"); try appendInt(&list, state.general.gaps_out);
    try list.appendSlice(gpa, ",\"border_size\":"); try appendInt(&list, state.general.border_size);
    try list.appendSlice(gpa, ",\"rounding\":"); try appendInt(&list, state.general.rounding);
    try list.appendSlice(gpa, ",\"rounding_power\":"); try appendFloat(&list, state.general.rounding_power);
    try list.appendSlice(gpa, ",\"active_opacity\":"); try appendFloat(&list, state.general.active_opacity);
    try list.appendSlice(gpa, ",\"inactive_opacity\":"); try appendFloat(&list, state.general.inactive_opacity);
    try list.appendSlice(gpa, ",\"allow_tearing\":"); try appendBool(&list, state.general.allow_tearing);
    try list.appendSlice(gpa, ",\"layout\":"); try appendJsonString(&list, @tagName(state.general.layout));
    try list.appendSlice(gpa, ",\"blur_enabled\":"); try appendBool(&list, state.general.blur_enabled);
    try list.appendSlice(gpa, ",\"blur_size\":"); try appendInt(&list, state.general.blur_size);
    try list.appendSlice(gpa, ",\"blur_passes\":"); try appendInt(&list, state.general.blur_passes);
    try list.appendSlice(gpa, ",\"blur_vibrancy\":"); try appendFloat(&list, state.general.blur_vibrancy);
    try list.appendSlice(gpa, ",\"shadow_enabled\":"); try appendBool(&list, state.general.shadow_enabled);
    try list.appendSlice(gpa, ",\"shadow_range\":"); try appendInt(&list, state.general.shadow_range);
    try list.appendSlice(gpa, ",\"shadow_render_power\":"); try appendInt(&list, state.general.shadow_render_power);
    try list.appendSlice(gpa, ",\"shadow_color\":"); try appendText(&list, state.general.shadow_color);
    try list.appendSlice(gpa, ",\"active_border\":"); try appendText(&list, state.general.active_border);
    try list.appendSlice(gpa, ",\"inactive_border\":"); try appendText(&list, state.general.inactive_border);
    try list.appendSlice(gpa, "},\"input\":{");
    try list.appendSlice(gpa, "\"kb_layout\":"); try appendText(&list, state.input.kb_layout);
    try list.appendSlice(gpa, ",\"kb_variant\":"); try appendText(&list, state.input.kb_variant);
    try list.appendSlice(gpa, ",\"follow_mouse\":"); try appendInt(&list, state.input.follow_mouse);
    try list.appendSlice(gpa, ",\"accel_profile\":"); try appendText(&list, state.input.accel_profile);
    try list.appendSlice(gpa, ",\"sensitivity\":"); try appendFloat(&list, state.input.sensitivity);
    try list.appendSlice(gpa, ",\"natural_scroll\":"); try appendBool(&list, state.input.natural_scroll);
    try list.appendSlice(gpa, "},\"animations\":{");
    try list.appendSlice(gpa, "\"enabled\":"); try appendBool(&list, state.anim.enabled);
    try list.appendSlice(gpa, ",\"curves\":[");
    for (state.anim.curves[0..state.anim.curves_len], 0..) |*c, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"name\":"); try appendText(&list, c.name);
        try list.appendSlice(gpa, ",\"type\":"); try appendJsonString(&list, @tagName(c.ctype));
        try list.appendSlice(gpa, ",\"x1\":"); try appendFloat(&list, c.x1);
        try list.appendSlice(gpa, ",\"y1\":"); try appendFloat(&list, c.y1);
        try list.appendSlice(gpa, ",\"x2\":"); try appendFloat(&list, c.x2);
        try list.appendSlice(gpa, ",\"y2\":"); try appendFloat(&list, c.y2);
        try list.appendSlice(gpa, ",\"mass\":"); try appendFloat(&list, c.mass);
        try list.appendSlice(gpa, ",\"stiffness\":"); try appendFloat(&list, c.stiffness);
        try list.appendSlice(gpa, ",\"dampening\":"); try appendFloat(&list, c.dampening);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"leaves\":[");
    for (state.anim.leaves[0..state.anim.leaves_len], 0..) |*l, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"leaf\":"); try appendText(&list, l.leaf);
        try list.appendSlice(gpa, ",\"enabled\":"); try appendBool(&list, l.enabled);
        try list.appendSlice(gpa, ",\"speed\":"); try appendFloat(&list, l.speed);
        try list.appendSlice(gpa, ",\"curve\":"); try appendText(&list, l.curve);
        try list.appendSlice(gpa, ",\"style\":"); try appendText(&list, l.style);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "]},\"monitors\":[");
    for (state.monitors[0..state.monitors_len], 0..) |*m, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"enabled\":"); try appendBool(&list, m.enabled);
        try list.appendSlice(gpa, ",\"output\":"); try appendText(&list, m.output);
        try list.appendSlice(gpa, ",\"mode\":"); try appendText(&list, m.mode);
        try list.appendSlice(gpa, ",\"position\":"); try appendText(&list, m.position);
        try list.appendSlice(gpa, ",\"scale\":"); try appendText(&list, m.scale);
        try list.appendSlice(gpa, ",\"vrr\":"); try appendInt(&list, m.vrr);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"binds\":[");
    for (state.binds[0..state.binds_len], 0..) |*b, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"enabled\":"); try appendBool(&list, b.enabled);
        try list.appendSlice(gpa, ",\"combo\":"); try appendText(&list, b.combo);
        try list.appendSlice(gpa, ",\"action\":"); try appendJsonString(&list, @tagName(b.action));
        try list.appendSlice(gpa, ",\"arg\":"); try appendText(&list, b.arg);
        try list.appendSlice(gpa, ",\"locked\":"); try appendBool(&list, b.locked);
        try list.appendSlice(gpa, ",\"repeating\":"); try appendBool(&list, b.repeating);
        try list.appendSlice(gpa, ",\"mouse\":"); try appendBool(&list, b.mouse);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"window_rules\":[");
    for (state.wrules[0..state.wrules_len], 0..) |*r, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"enabled\":"); try appendBool(&list, r.enabled);
        try list.appendSlice(gpa, ",\"name\":"); try appendText(&list, r.name);
        try list.appendSlice(gpa, ",\"class\":"); try appendText(&list, r.class);
        try list.appendSlice(gpa, ",\"title\":"); try appendText(&list, r.title);
        try list.appendSlice(gpa, ",\"app_id\":"); try appendText(&list, r.app_id);
        try list.appendSlice(gpa, ",\"workspace\":"); try appendText(&list, r.workspace);
        try list.appendSlice(gpa, ",\"xwayland\":"); try appendInt(&list, r.xwayland);
        try list.appendSlice(gpa, ",\"float_state\":"); try appendInt(&list, r.float_state);
        try list.appendSlice(gpa, ",\"opts\":"); try appendText(&list, r.opts);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"workspace_rules\":[");
    for (state.wsrules[0..state.wsrules_len], 0..) |*r, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"enabled\":"); try appendBool(&list, r.enabled);
        try list.appendSlice(gpa, ",\"workspace\":"); try appendText(&list, r.workspace);
        try list.appendSlice(gpa, ",\"monitor\":"); try appendText(&list, r.monitor);
        try list.appendSlice(gpa, ",\"opts\":"); try appendText(&list, r.opts);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"layer_rules\":[");
    for (state.lrules[0..state.lrules_len], 0..) |*r, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"enabled\":"); try appendBool(&list, r.enabled);
        try list.appendSlice(gpa, ",\"name\":"); try appendText(&list, r.name);
        try list.appendSlice(gpa, ",\"namespace\":"); try appendText(&list, r.namespace);
        try list.appendSlice(gpa, ",\"opts\":"); try appendText(&list, r.opts);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "],\"autostart\":[");
    for (state.autostart[0..state.autostart_len], 0..) |*a, i| {
        if (i != 0) try list.append(gpa, ',');
        try appendText(&list, a.*);
    }
    try list.appendSlice(gpa, "],\"env\":[");
    for (state.envs[0..state.envs_len], 0..) |*e, i| {
        if (i != 0) try list.append(gpa, ',');
        try list.appendSlice(gpa, "{\"key\":"); try appendText(&list, e.key);
        try list.appendSlice(gpa, ",\"value\":"); try appendText(&list, e.value);
        try list.append(gpa, '}');
    }
    try list.appendSlice(gpa, "]}");

    return list.toOwnedSlice(gpa);
}

// --- Parse side ---

const JsonString = []const u8;

fn JsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn JsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jsonStr(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |s| s,
        else => "",
    };
}

fn optStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return jsonStr(obj.get(key) orelse return "");
}

fn optInt(obj: std.json.ObjectMap, key: []const u8, fallback: i32) i32 {
    const v = obj.get(key) orelse return fallback;
    return @intCast(JsonInt(v) orelse fallback);
}

fn optBool(obj: std.json.ObjectMap, key: []const u8, fallback: bool) bool {
    const v = obj.get(key) orelse return fallback;
    return JsonBool(v) orelse fallback;
}

fn optFloat(obj: std.json.ObjectMap, key: []const u8, fallback: f64) f64 {
    const v = obj.get(key) orelse return fallback;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => fallback,
    };
}

fn parseCurve(obj: std.json.ObjectMap, out: *Curve) void {
    out.* = .{};
    out.name.set(optStr(obj, "name"));
    out.ctype = if (std.mem.eql(u8, optStr(obj, "type"), "spring")) .spring else .bezier;
    out.x1 = optFloat(obj, "x1", 0);
    out.y1 = optFloat(obj, "y1", 0);
    out.x2 = optFloat(obj, "x2", 1);
    out.y2 = optFloat(obj, "y2", 1);
    out.mass = optFloat(obj, "mass", 1);
    out.stiffness = optFloat(obj, "stiffness", 60);
    out.dampening = optFloat(obj, "dampening", 20);
}

fn parseLeaf(obj: std.json.ObjectMap, out: *Leaf) void {
    out.* = .{ .enabled = optBool(obj, "enabled", true), .speed = optFloat(obj, "speed", 4) };
    out.leaf.set(optStr(obj, "leaf"));
    out.curve.set(optStr(obj, "curve"));
    out.style.set(optStr(obj, "style"));
}

fn parseMonitor(obj: std.json.ObjectMap, out: *Monitor) void {
    out.* = .{ .enabled = optBool(obj, "enabled", true), .vrr = optInt(obj, "vrr", -1) };
    out.output.set(optStr(obj, "output"));
    out.mode.set(optStr(obj, "mode"));
    out.position.set(optStr(obj, "position"));
    out.scale.set(optStr(obj, "scale"));
}

fn parseBind(obj: std.json.ObjectMap, out: *Bind) void {
    out.* = .{
        .enabled = optBool(obj, "enabled", true),
        .locked = optBool(obj, "locked", false),
        .repeating = optBool(obj, "repeating", false),
        .mouse = optBool(obj, "mouse", false),
    };
    out.combo.set(optStr(obj, "combo"));
    const aname = optStr(obj, "action");
    out.action = std.meta.stringToEnum(BindAction, aname) orelse .exec;
    out.arg.set(optStr(obj, "arg"));
}

fn parseWindowRule(obj: std.json.ObjectMap, out: *WindowRule) void {
    out.* = .{
        .enabled = optBool(obj, "enabled", true),
        .xwayland = optInt(obj, "xwayland", -1),
        .float_state = optInt(obj, "float_state", -1),
    };
    out.name.set(optStr(obj, "name"));
    out.class.set(optStr(obj, "class"));
    out.title.set(optStr(obj, "title"));
    out.app_id.set(optStr(obj, "app_id"));
    out.workspace.set(optStr(obj, "workspace"));
    out.opts.set(optStr(obj, "opts"));
}

fn parseWorkspaceRule(obj: std.json.ObjectMap, out: *WorkspaceRule) void {
    out.* = .{ .enabled = optBool(obj, "enabled", true) };
    out.workspace.set(optStr(obj, "workspace"));
    out.monitor.set(optStr(obj, "monitor"));
    out.opts.set(optStr(obj, "opts"));
}

fn parseLayerRule(obj: std.json.ObjectMap, out: *LayerRule) void {
    out.* = .{ .enabled = optBool(obj, "enabled", true) };
    out.name.set(optStr(obj, "name"));
    out.namespace.set(optStr(obj, "namespace"));
    out.opts.set(optStr(obj, "opts"));
}

fn parseEnv(obj: std.json.ObjectMap, out: *EnvVar) void {
    out.* = .{};
    out.key.set(optStr(obj, "key"));
    out.value.set(optStr(obj, "value"));
}

fn loadStateFromDiskRaw(raw: []const u8) void {
    seedDefaults();
    const tree = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return;
    defer tree.deinit();

    const root = tree.value;
    if (root != .object) return;
    const obj = root.object;

    if (obj.get("general")) |gv| {
        if (gv == .object) {
            const g = gv.object;
            state.general.gaps_in = optInt(g, "gaps_in", 1);
            state.general.gaps_out = optInt(g, "gaps_out", 1);
            state.general.border_size = optInt(g, "border_size", 1);
            state.general.rounding = optInt(g, "rounding", 0);
            state.general.rounding_power = optFloat(g, "rounding_power", 0);
            state.general.active_opacity = optFloat(g, "active_opacity", 1);
            state.general.inactive_opacity = optFloat(g, "inactive_opacity", 1);
            state.general.allow_tearing = optBool(g, "allow_tearing", false);
            const layout_name = optStr(g, "layout");
            state.general.layout = std.meta.stringToEnum(LayoutChoice, layout_name) orelse .master;
            state.general.blur_enabled = optBool(g, "blur_enabled", true);
            state.general.blur_size = optInt(g, "blur_size", 8);
            state.general.blur_passes = optInt(g, "blur_passes", 1);
            state.general.blur_vibrancy = optFloat(g, "blur_vibrancy", 0.1696);
            state.general.blur_noise = optFloat(g, "blur_noise", 0.0117);
            state.general.blur_new_optimizations = optBool(g, "blur_new_optimizations", true);
            state.general.shadow_enabled = optBool(g, "shadow_enabled", true);
            state.general.shadow_range = optInt(g, "shadow_range", 4);
            state.general.shadow_render_power = optInt(g, "shadow_render_power", 3);
            state.general.shadow_color.set(optStr(g, "shadow_color"));
            state.general.active_border.set(optStr(g, "active_border"));
            state.general.inactive_border.set(optStr(g, "inactive_border"));
        }
    }

    if (obj.get("input")) |iv| {
        if (iv == .object) {
            const input = iv.object;
            state.input.kb_layout.set(optStr(input, "kb_layout"));
            state.input.kb_variant.set(optStr(input, "kb_variant"));
            state.input.follow_mouse = optInt(input, "follow_mouse", 1);
            state.input.accel_profile.set(optStr(input, "accel_profile"));
            state.input.sensitivity = optFloat(input, "sensitivity", 0);
            state.input.natural_scroll = optBool(input, "natural_scroll", false);
        }
    }

    if (obj.get("animations")) |av| {
        if (av == .object) {
            const anim = av.object;
            state.anim.enabled = optBool(anim, "enabled", true);
            state.anim.curves_len = 0;
            if (anim.get("curves")) |cv| {
                if (cv == .array) {
                    for (cv.array.items) |cv_item| {
                        if (cv_item == .object and state.anim.curves_len < MAX_CURVES) {
                            parseCurve(cv_item.object, &state.anim.curves[state.anim.curves_len]);
                            state.anim.curves_len += 1;
                        }
                    }
                }
            }
            state.anim.leaves_len = 0;
            if (anim.get("leaves")) |lv| {
                if (lv == .array) {
                    for (lv.array.items) |lv_item| {
                        if (lv_item == .object and state.anim.leaves_len < MAX_LEAVES) {
                            parseLeaf(lv_item.object, &state.anim.leaves[state.anim.leaves_len]);
                            state.anim.leaves_len += 1;
                        }
                    }
                }
            }
        }
    }

    state.monitors_len = 0;
    if (obj.get("monitors")) |mv| {
        if (mv == .array) {
            for (mv.array.items) |m_item| {
                if (m_item == .object and state.monitors_len < MAX_MONITORS) {
                    parseMonitor(m_item.object, &state.monitors[state.monitors_len]);
                    state.monitors_len += 1;
                }
            }
        }
    }

    state.binds_len = 0;
    if (obj.get("binds")) |bv| {
        if (bv == .array) {
            for (bv.array.items) |b_item| {
                if (b_item == .object and state.binds_len < MAX_BINDS) {
                    parseBind(b_item.object, &state.binds[state.binds_len]);
                    state.binds_len += 1;
                }
            }
        }
    }

    state.wrules_len = 0;
    if (obj.get("window_rules")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |r_item| {
                if (r_item == .object and state.wrules_len < MAX_RULES) {
                    parseWindowRule(r_item.object, &state.wrules[state.wrules_len]);
                    state.wrules_len += 1;
                }
            }
        }
    }

    state.wsrules_len = 0;
    if (obj.get("workspace_rules")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |r_item| {
                if (r_item == .object and state.wsrules_len < MAX_RULES) {
                    parseWorkspaceRule(r_item.object, &state.wsrules[state.wsrules_len]);
                    state.wsrules_len += 1;
                }
            }
        }
    }

    state.lrules_len = 0;
    if (obj.get("layer_rules")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |r_item| {
                if (r_item == .object and state.lrules_len < MAX_RULES) {
                    parseLayerRule(r_item.object, &state.lrules[state.lrules_len]);
                    state.lrules_len += 1;
                }
            }
        }
    }

    state.autostart_len = 0;
    if (obj.get("autostart")) |av2| {
        if (av2 == .array) {
            for (av2.array.items) |a_item| {
                if (state.autostart_len < MAX_AUTOSTART) {
                    state.autostart[state.autostart_len].set(jsonStr(a_item));
                    state.autostart_len += 1;
                }
            }
        }
    }

    state.envs_len = 0;
    if (obj.get("env")) |ev| {
        if (ev == .array) {
            for (ev.array.items) |e_item| {
                if (e_item == .object and state.envs_len < MAX_ENV) {
                    parseEnv(e_item.object, &state.envs[state.envs_len]);
                    state.envs_len += 1;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------

pub fn pathsInitialized() bool {
    return state_json_path[0] != 0;
}

/// Loads state (or seeds defaults if no state file exists yet). Must be
/// called from the UI before building pages.
pub fn loadOrInit() void {
    if (state_loaded) return;
    state_loaded = true;
    initPaths();
    const raw = readFileAll(&state_json_path) orelse {
        seedDefaults();
        return;
    };
    defer gpa.free(raw);
    loadStateFromDiskRaw(raw);
}

/// Writes state JSON + regenerates the managed Lua. Returns true on success.
pub fn saveAll() bool {
    if (!pathsInitialized()) initPaths();

    const json_bytes = buildStateJson() catch return false;
    defer gpa.free(json_bytes);
    if (!writeFileAtomic(&state_json_path, json_bytes)) {
        std.debug.print("hypr: failed to write {s}\n", .{std.mem.span(@as([*:0]const u8, &state_json_path))});
        return false;
    }

    const lua_bytes = buildManagedLua() catch {
        std.debug.print("hypr: failed to generate managed Lua\n", .{});
        return false;
    };
    defer gpa.free(lua_bytes);
    if (!writeFileAtomic(&managed_lua_path, lua_bytes)) {
        std.debug.print("hypr: failed to write {s}\n", .{std.mem.span(@as([*:0]const u8, &managed_lua_path))});
        return false;
    }
    return true;
}

/// Ensures `hyprland.lua` requires the generated snippet. Idempotent.
pub fn ensureBootstrapped() bool {
    if (bootstrapped) return true;
    initPaths();
    const raw = readFileAll(&main_config_path) orelse {
        std.debug.print("hypr: no {s} to bootstrap (fine — install.sh adds it)\n", .{std.mem.span(@as([*:0]const u8, &main_config_path))});
        bootstrapped = true;
        return true;
    };
    defer gpa.free(raw);

    if (std.mem.indexOf(u8, raw, REQUIRED_MARKER_LINE) != null) {
        bootstrapped = true;
        return true;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    buf.appendSlice(gpa, raw) catch return false;
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        buf.append(gpa, '\n') catch return false;
    }
    buf.appendSlice(gpa, "\n-- Load simpbar-config's managed Hyprland settings:\n-- Simpbar Config\n") catch return false;
    buf.appendSlice(gpa, REQUIRED_MARKER_LINE) catch return false;
    buf.append(gpa, '\n') catch return false;

    if (!writeFileAtomic(&main_config_path, buf.items)) return false;
    bootstrapped = true;
    return true;
}

/// Runs `hyprctl reload` to apply the regenerated config now. Blocking but
/// fast; usable from a button callback.
pub fn reloadHyprland() bool {
    return runQuiet(&.{ "hyprctl", "reload" }, 5000);
}

/// Like runQuiet but captures stdout into an allocated buffer (returned, or
/// null on any failure / timeout / empty output). Used by the Monitors page
/// to discover connected output names via `hyprctl monitors -j`. The caller
/// owns the returned slice (gpa).
pub fn captureOutput(argv: []const []const u8, timeout_ms: i32) ?[]u8 {
    if (argv.len == 0 or argv.len > 12) return null;
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
        _ = dup2(write_fd, 1);
        _ = close(write_fd);
        var buf: [13]?[*:0]const u8 = undefined;
        buf[0] = "/usr/bin/env";
        var z: [12][MAX_PATH]u8 = undefined;
        for (argv, 0..) |a, i| {
            const n = @min(a.len, MAX_PATH - 1);
            @memcpy(z[i][0..n], a[0..n]);
            z[i][n] = 0;
            buf[i + 1] = z[i][0..n :0].ptr;
        }
        buf[argv.len + 1] = null;
        _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
        std.c._exit(127);
    }
    _ = close(write_fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [1024]u8 = undefined;
    var timed_out = false;
    while (true) {
        var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
        const pr = poll(&pfd, 1, timeout_ms);
        if (pr <= 0) {
            timed_out = true;
            break;
        }
        const n = read(read_fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            timed_out = true;
            break;
        };
        if (list.items.len > 2 * 1024 * 1024) break;
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

pub fn isBootstrapped() bool {
    return bootstrapped;
}

// ---------------------------------------------------------------------
// Managed Lua generation
// ---------------------------------------------------------------------

fn appendLuaString(list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            else => try list.append(gpa, c),
        }
    }
    try list.append(gpa, '"');
}

fn indent(list: *std.ArrayList(u8), depth: usize) !void {
    _ = depth;
    try list.appendSlice(gpa, "\t");
}

/// Converts a stored hex color ("#rrggbb" or "0xrrggbbaa") to Hyprland's
/// "rgba(r,g,b,a)" palette form. Unknown strings pass through unchanged.
fn rgbaFromHex(hex: []const u8, buf: []u8) []const u8 {
    var strip = hex;
    if (strip.len > 0 and strip[0] == '#') {
        strip = strip[1..];
    } else if (std.mem.startsWith(u8, strip, "0x")) {
        strip = strip[2..];
    }
    if (strip.len != 6 and strip.len != 8) return hex;
    const v = std.fmt.parseInt(u32, strip, 16) catch return hex;
    const r: u32 = (v >> 16) & 0xFF;
    const g: u32 = (v >> 8) & 0xFF;
    const b: u32 = v & 0xFF;
    const a_num = if (strip.len == 8) (v >> 24) & 0xFF else 255;
    const a = @as(f64, @floatFromInt(a_num)) / 255.0;
    return std.fmt.bufPrint(buf, "rgba({d},{d},{d},{d:.2})", .{ r, g, b, a }) catch hex;
}

fn appendLuaNumber(list: *std.ArrayList(u8), v: f64) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(gpa, text);
}

fn appendLuaConfigBlock(list: *std.ArrayList(u8)) !void {
    try list.appendSlice(gpa, "hl.config({\n");

    try list.appendSlice(gpa, "\tgeneral = {\n");
    try list.appendSlice(gpa, "\t\tgaps_in = "); try appendInt(list, state.general.gaps_in);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tgaps_out = "); try appendInt(list, state.general.gaps_out);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tborder_size = "); try appendInt(list, state.general.border_size);
    try list.append(gpa, ',');
    var color_buf: [64]u8 = undefined;
    try list.appendSlice(gpa, "\n\t\tcol = {\n\t\t\tactive_border = { colors = { ");
    try appendLuaString(list, rgbaFromHex(state.general.active_border.slice(), &color_buf));
    try list.appendSlice(gpa, " } },\n\t\t\tinactive_border = ");
    try appendLuaString(list, rgbaFromHex(state.general.inactive_border.slice(), &color_buf));
    try list.appendSlice(gpa, ",\n\t\t},\n");
    try list.appendSlice(gpa, "\t\tallow_tearing = "); try appendBool(list, state.general.allow_tearing);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tlayout = "); try appendLuaString(list, @tagName(state.general.layout));
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t},\n");

    try list.appendSlice(gpa, "\tdecoration = {\n");
    try list.appendSlice(gpa, "\t\trounding = "); try appendInt(list, state.general.rounding);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\trounding_power = "); try appendLuaNumber(list, state.general.rounding_power);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tactive_opacity = "); try appendLuaNumber(list, state.general.active_opacity);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tinactive_opacity = "); try appendLuaNumber(list, state.general.inactive_opacity);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tshadow = {\n\t\t\tenabled = "); try appendBool(list, state.general.shadow_enabled);
    try list.appendSlice(gpa, ",\n\t\t\trange = "); try appendInt(list, state.general.shadow_range);
    try list.appendSlice(gpa, ",\n\t\t\trender_power = "); try appendInt(list, state.general.shadow_render_power);
    try list.appendSlice(gpa, ",\n\t\t\tcolor = "); try appendLuaString(list, state.general.shadow_color.slice());
    try list.appendSlice(gpa, ",\n\t\t},\n");
    try list.appendSlice(gpa, "\t\tblur = {\n\t\t\tenabled = "); try appendBool(list, state.general.blur_enabled);
    try list.appendSlice(gpa, ",\n\t\t\tsize = "); try appendInt(list, state.general.blur_size);
    try list.appendSlice(gpa, ",\n\t\t\tpasses = "); try appendInt(list, state.general.blur_passes);
    try list.appendSlice(gpa, ",\n\t\t\tvibrancy = "); try appendLuaNumber(list, state.general.blur_vibrancy);
    try list.appendSlice(gpa, ",\n\t\t},\n\t},\n");

    try list.appendSlice(gpa, "\tanimations = { enabled = "); try appendBool(list, state.anim.enabled);
    try list.appendSlice(gpa, " },\n");

    try list.appendSlice(gpa, "\tinput = {\n");
    try list.appendSlice(gpa, "\t\tkb_layout = "); try appendLuaString(list, state.input.kb_layout.slice());
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tkb_variant = "); try appendLuaString(list, state.input.kb_variant.slice());
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tfollow_mouse = "); try appendInt(list, state.input.follow_mouse);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\taccel_profile = "); try appendLuaString(list, state.input.accel_profile.slice());
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\tsensitivity = "); try appendLuaNumber(list, state.input.sensitivity);
    try list.append(gpa, ',');
    try list.appendSlice(gpa, "\n\t\ttouchpad = { natural_scroll = "); try appendBool(list, state.input.natural_scroll);
    try list.appendSlice(gpa, " },\n\t},\n");

    try list.appendSlice(gpa, "\tmisc = {\n\t\tforce_default_wallpaper = 0,\n\t\tdisable_hyprland_logo = true,\n\t},\n");
    try list.appendSlice(gpa, "})\n");
}

fn appendCurves(list: *std.ArrayList(u8)) !void {
    for (state.anim.curves[0..state.anim.curves_len]) |*c| {
        if (c.name.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.curve(");
        try appendLuaString(list, c.name.slice());
        try list.appendSlice(gpa, ", { type = ");
        if (c.ctype == .bezier) {
            try list.appendSlice(gpa, "\"bezier\", points = { { ");
            var b: [32]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.x1}) catch unreachable);
            try list.appendSlice(gpa, ", ");
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.y1}) catch unreachable);
            try list.appendSlice(gpa, " }, { ");
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.x2}) catch unreachable);
            try list.appendSlice(gpa, ", ");
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.y2}) catch unreachable);
            try list.appendSlice(gpa, " } } }");
        } else {
            try list.appendSlice(gpa, "\"spring\", mass = ");
            var b: [32]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.mass}) catch unreachable);
            try list.appendSlice(gpa, ", stiffness = ");
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.stiffness}) catch unreachable);
            try list.appendSlice(gpa, ", dampening = ");
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{c.dampening}) catch unreachable);
            try list.appendSlice(gpa, " }");
        }
        try list.appendSlice(gpa, ")\n");
    }
}

fn appendLeaves(list: *std.ArrayList(u8)) !void {
    for (state.anim.leaves[0..state.anim.leaves_len]) |*l| {
        if (l.leaf.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.animation({ leaf = ");
        try appendLuaString(list, l.leaf.slice());
        try list.appendSlice(gpa, ", enabled = ");
        try appendBool(list, l.enabled);
        try list.appendSlice(gpa, ", speed = ");
        var b: [32]u8 = undefined;
        try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{l.speed}) catch unreachable);
        if (std.mem.eql(u8, l.curve.slice(), "default")) {
            try list.appendSlice(gpa, ", bezier = \"default\"");
        } else {
            const is_spring = blk: {
                for (state.anim.curves[0..state.anim.curves_len]) |*c| {
                    if (std.mem.eql(u8, c.name.slice(), l.curve.slice())) {
                        break :blk c.ctype == .spring;
                    }
                }
                break :blk false;
            };
            if (is_spring) {
                try list.appendSlice(gpa, ", spring = ");
            } else {
                try list.appendSlice(gpa, ", bezier = ");
            }
            try appendLuaString(list, l.curve.slice());
        }
        if (!l.style.isEmpty()) {
            try list.appendSlice(gpa, ", style = ");
            try appendLuaString(list, l.style.slice());
        }
        try list.appendSlice(gpa, " })\n");
    }
}

fn appendMonitors(list: *std.ArrayList(u8)) !void {
    for (state.monitors[0..state.monitors_len]) |*m| {
        if (m.output.isEmpty() or !m.enabled) continue;
        try list.appendSlice(gpa, "hl.monitor({\n\toutput = ");
        try appendLuaString(list, m.output.slice());
        try list.appendSlice(gpa, ",\n\tmode = ");
        try appendLuaString(list, m.mode.slice());
        try list.appendSlice(gpa, ",\n\tposition = ");
        try appendLuaString(list, m.position.slice());
        try list.appendSlice(gpa, ",\n\tscale = ");
        try appendLuaString(list, m.scale.slice());
        try list.append(gpa, ',');
        if (m.vrr >= 0) {
            try list.appendSlice(gpa, "\n\tvrr = ");
            var b: [8]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{m.vrr}) catch unreachable);
        }
        try list.appendSlice(gpa, "\n})\n");
    }
}

fn bindDisplayName(b: *const Bind) [:0]const u8 {
    return b.action.displayName();
}

fn appendBinds(list: *std.ArrayList(u8)) !void {
    for (state.binds[0..state.binds_len]) |*b| {
        if (!b.enabled or b.combo.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.bind(");
        try appendLuaString(list, b.combo.slice());
        try list.appendSlice(gpa, ", ");
        switch (b.action) {
            .exec => {
                try list.appendSlice(gpa, "hl.dsp.exec_cmd(");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, ")");
            },
            .close => try list.appendSlice(gpa, "hl.dsp.window.close()"),
            .toggle_float => try list.appendSlice(gpa, "hl.dsp.window.float({ action = \"toggle\" })"),
            .pseudo => try list.appendSlice(gpa, "hl.dsp.window.pseudo()"),
            .toggle_fullscreen => try list.appendSlice(gpa, "hl.dsp.window.fullscreen({ action = \"toggle\" })"),
            .center => try list.appendSlice(gpa, "hl.dsp.window.center()"),
            .pin => try list.appendSlice(gpa, "hl.dsp.window.pin({ action = \"toggle\" })"),
            .drag => try list.appendSlice(gpa, "hl.dsp.window.drag()"),
            .resize => try list.appendSlice(gpa, "hl.dsp.window.resize()"),
            .focus_dir => {
                try list.appendSlice(gpa, "hl.dsp.focus({ direction = ");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, " })");
            },
            .focus_workspace => {
                try list.appendSlice(gpa, "hl.dsp.focus({ workspace = ");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, " })");
            },
            .move_dir => {
                try list.appendSlice(gpa, "hl.dsp.window.move({ direction = ");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, " })");
            },
            .move_workspace => {
                try list.appendSlice(gpa, "hl.dsp.window.move({ workspace = ");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, " })");
            },
            .layout => {
                try list.appendSlice(gpa, "hl.dsp.layout(");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, ")");
            },
            .toggle_special => {
                try list.appendSlice(gpa, "hl.dsp.workspace.toggle_special(");
                try appendLuaString(list, b.arg.slice());
                try list.appendSlice(gpa, ")");
            },
            .exit => try list.appendSlice(gpa, "hl.dsp.exit()"),
        }
        var has_flags = false;
        if (b.locked or b.repeating or b.mouse) {
            try list.appendSlice(gpa, ", { ");
        }
        if (b.locked) {
            try list.appendSlice(gpa, "locked = true");
            has_flags = true;
        }
        if (b.repeating) {
            if (has_flags) try list.appendSlice(gpa, ", ");
            try list.appendSlice(gpa, "repeating = true");
            has_flags = true;
        }
        if (b.mouse) {
            if (has_flags) try list.appendSlice(gpa, ", ");
            try list.appendSlice(gpa, "mouse = true");
            has_flags = true;
        }
        const desc = bindDisplayName(b);
        if (desc.len > 0) {
            if (!has_flags) {
                try list.appendSlice(gpa, ", {");
            } else {
                try list.appendSlice(gpa, ", ");
            }
            try list.appendSlice(gpa, "description = ");
            try appendLuaString(list, desc);
            has_flags = true;
        }
        if (has_flags) try list.appendSlice(gpa, " }");
        try list.appendSlice(gpa, ")\n");
    }
}

fn appendAutostart(list: *std.ArrayList(u8)) !void {
    if (state.autostart_len == 0) return;
    try list.appendSlice(gpa, "hl.on(\"hyprland.start\", function()\n");
    for (state.autostart[0..state.autostart_len]) |*a| {
        if (a.isEmpty()) continue;
        try list.appendSlice(gpa, "\thl.exec_cmd(");
        try appendLuaString(list, a.slice());
        try list.appendSlice(gpa, ")\n");
    }
    try list.appendSlice(gpa, "end)\n");
}

fn appendEnv(list: *std.ArrayList(u8)) !void {
    for (state.envs[0..state.envs_len]) |*e| {
        if (e.key.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.env(");
        try appendLuaString(list, e.key.slice());
        try list.appendSlice(gpa, ", ");
        try appendLuaString(list, e.value.slice());
        try list.appendSlice(gpa, ")\n");
    }
}

fn appendWindowRules(list: *std.ArrayList(u8)) !void {
    for (state.wrules[0..state.wrules_len]) |*r| {
        if (!r.enabled) continue;
        try list.appendSlice(gpa, "hl.window_rule({\n");
        if (!r.name.isEmpty()) {
            try list.appendSlice(gpa, "\tname = ");
            try appendLuaString(list, r.name.slice());
            try list.appendSlice(gpa, ",\n");
        }
        // match table with only non-empty / non-"any" criteria
        try list.appendSlice(gpa, "\tmatch = {");
        var first = true;
        if (!r.class.isEmpty()) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, " class = ");
            try appendLuaString(list, r.class.slice());
            first = false;
        }
        if (!r.title.isEmpty()) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, " title = ");
            try appendLuaString(list, r.title.slice());
            first = false;
        }
        if (!r.app_id.isEmpty()) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, " app_id = ");
            try appendLuaString(list, r.app_id.slice());
            first = false;
        }
        if (!r.workspace.isEmpty()) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, " workspace = ");
            try appendLuaString(list, r.workspace.slice());
            first = false;
        }
        if (r.xwayland == 0 or r.xwayland == 1) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, if (r.xwayland == 1) " xwayland = true" else " xwayland = false");
            first = false;
        }
        if (r.float_state == 0 or r.float_state == 1) {
            if (!first) try list.append(gpa, ',');
            try list.appendSlice(gpa, if (r.float_state == 1) " float = true" else " float = false");
            first = false;
        }
        try list.appendSlice(gpa, " },\n");
        try appendRuleOptions(list, r.opts.slice());
        try list.appendSlice(gpa, "})\n");
    }
}

fn appendWorkspaceRules(list: *std.ArrayList(u8)) !void {
    for (state.wsrules[0..state.wsrules_len]) |*r| {
        if (!r.enabled or r.workspace.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.workspace_rule({ workspace = ");
        try appendLuaString(list, r.workspace.slice());
        if (!r.monitor.isEmpty()) {
            try list.appendSlice(gpa, ", monitor = ");
            try appendLuaString(list, r.monitor.slice());
        }
        if (r.opts.len > 0) {
            try list.appendSlice(gpa, ",\n");
        }
        try appendRuleOptions(list, r.opts.slice());
        try list.appendSlice(gpa, "})\n");
    }
}

fn appendLayerRules(list: *std.ArrayList(u8)) !void {
    for (state.lrules[0..state.lrules_len]) |*r| {
        if (!r.enabled or r.namespace.isEmpty()) continue;
        try list.appendSlice(gpa, "hl.layer_rule({\n");
        if (!r.name.isEmpty()) {
            try list.appendSlice(gpa, "\tname = ");
            try appendLuaString(list, r.name.slice());
            try list.appendSlice(gpa, ",\n");
        }
        try list.appendSlice(gpa, "\tmatch = { namespace = ");
        try appendLuaString(list, r.namespace.slice());
        try list.appendSlice(gpa, " },\n");
        try appendRuleOptions(list, r.opts.slice());
        try list.appendSlice(gpa, "})\n");
    }
}

/// Emits `key = value` pairs for a comma-separated option string (the text
/// the rule dialogs store). Grammar:
///   "float"            -> float = true
///   "ignore_alpha 0.5" -> ignore_alpha = 0.5
///   "size 400 500"     -> size = { 400, 500 }
///   "move 20 x-100"    -> move = "20 x-100"
fn appendRuleOptions(list: *std.ArrayList(u8), opts: []const u8) !void {
    var it = std.mem.splitScalar(u8, opts, ',');
    while (it.next()) |raw| {
        const opt = std.mem.trim(u8, raw, " \t");
        if (opt.len == 0) continue;
        const sp = std.mem.indexOfAny(u8, opt, " \t");
        const key = if (sp) |p| opt[0..p] else opt;
        const rest = if (sp) |p| std.mem.trim(u8, opt[p..], " \t") else "";

        try list.appendSlice(gpa, "\t");
        try list.appendSlice(gpa, key);
        try list.appendSlice(gpa, " = ");
        if (rest.len == 0) {
            try list.appendSlice(gpa, "true,\n");
            continue;
        }
        // numeric tokens become a list; anything else a string.
        var all_numeric = true;
        var n_count: usize = 0;
        var tok_iter = std.mem.splitScalar(u8, rest, ' ');
        while (tok_iter.next()) |ttok| {
            if (ttok.len == 0) continue;
            n_count += 1;
            all_numeric = all_numeric and std.fmt.parseFloat(f64, ttok) != error.InvalidCharacter;
        }
        if (all_numeric and n_count > 1) {
            try list.appendSlice(gpa, "{ ");
            var first = true;
            var tok_iter2 = std.mem.splitScalar(u8, rest, ' ');
            while (tok_iter2.next()) |ttok| {
                if (ttok.len == 0) continue;
                if (!first) try list.appendSlice(gpa, ", ");
                first = false;
                try list.appendSlice(gpa, ttok);
            }
            try list.appendSlice(gpa, " },\n");
        } else if (all_numeric and n_count == 1) {
            try list.appendSlice(gpa, rest);
            try list.appendSlice(gpa, ",\n");
        } else {
            try appendLuaString(list, rest);
            try list.appendSlice(gpa, ",\n");
        }
    }
}

fn buildManagedLua() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "-- Generated by simpbar-config. Do not edit by hand.\n");
    try list.appendSlice(gpa, "-- State lives in ~/.config/simpbar/hyprland.json.\n\n");

    try appendLuaConfigBlock(&list);
    try list.append(gpa, '\n');
    try appendCurves(&list);
    try appendLeaves(&list);
    try list.append(gpa, '\n');
    try appendMonitors(&list);
    try appendBinds(&list);
    try list.append(gpa, '\n');
    try appendWindowRules(&list);
    try appendWorkspaceRules(&list);
    try appendLayerRules(&list);
    try list.append(gpa, '\n');
    try appendEnv(&list);
    try appendAutostart(&list);

    return list.toOwnedSlice(gpa);
}
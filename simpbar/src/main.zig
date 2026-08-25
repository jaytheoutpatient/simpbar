const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const xdg = wayland.client.xdg;

const dbus = @import("dbus.zig");
const font_mod = @import("font.zig");
const icontheme = @import("icontheme.zig");
const dbusmenu = @import("dbusmenu.zig");

// Linux reuses O_CLOEXEC's bit position for every *_CLOEXEC flag regardless
// of which call it's combined with (SOCK_CLOEXEC, TFD_CLOEXEC, ...) — one
// shared constant for all of them, applied to every fd that outlives a
// single draw/fetch cycle. Without it, forked subprocesses (launcher
// clicks, weather/pacman/mpris/tray fetches) inherit a duplicate of
// whichever fd, and if that subprocess outlives us (a spawned terminal,
// browser, ...), things like the D-Bus connection look alive to the bus
// daemon long after we're gone — see the StatusNotifierWatcher-stuck-on-a-
// dead-PID incident this fixed.
const CLOEXEC: u32 = 0o2000000;

/// Sets CLOEXEC on an fd we didn't get to create with the flag baked in
/// (the Wayland display socket, opened internally by libwayland-client).
fn setCloexec(fd: posix.fd_t) void {
    _ = std.c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}
// waybar's config had a 10px margin-left/margin-right here; simpbar spans the
// full monitor width edge-to-edge instead.
const MARGIN_SIDE: i32 = 0;

const WORKSPACE_LEFT_MARGIN: i64 = 8;

// Spacing for the custom/* launcher buttons and custom/power.
const LAUNCHER_GAP: i64 = 16;
const RIGHT_MARGIN: i64 = 8;

// getenv is enough here; no need for std.process's env-map machinery.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// std.c doesn't expose socket()/connect() publicly in this Zig version
// (they're kept as private helpers for its own Io implementation), so we
// bind straight to libc ourselves — same approach as the time/timerfd
// bindings above.
const libc_sock = struct {
    extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
    extern "c" fn connect(sockfd: c_int, addr: *const anyopaque, addrlen: c_uint) c_int;
};

// Minimal libc time bindings — enough for a real local-time clock without
// pulling in a full @cImport of <time.h>. Layout matches glibc's `struct tm`
// (the tm_gmtoff/tm_zone tail is a glibc extension, present on Linux x86_64).
const libc_time = struct {
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;

    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
};

/// Connects a Unix domain socket to `path` (used for both Hyprland IPC
/// sockets: the request/response `.socket.sock` and the event-stream
/// `.socket2.sock`).
fn connectUnixSocket(path: []const u8) !posix.fd_t {
    const raw_fd = libc_sock.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | CLOEXEC, 0);
    if (raw_fd < 0) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw_fd);
    errdefer _ = posix.system.close(fd);

    var addr: std.os.linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    if (libc_sock.connect(fd, &addr, @sizeOf(std.os.linux.sockaddr.un)) != 0) {
        return error.ConnectFailed;
    }
    return fd;
}

/// Sends `command` to the Hyprland IPC socket at `sock_path` and returns its
/// full response. Hyprland closes the connection after replying, so this is
/// a fresh connection per request — the same pattern `hyprctl` itself uses.
fn hyprctlRequest(gpa: std.mem.Allocator, sock_path: []const u8, command: []const u8) ![]u8 {
    const fd = try connectUnixSocket(sock_path);
    defer _ = posix.system.close(fd);

    var written: usize = 0;
    while (written < command.len) {
        const n = std.c.write(fd, command[written..].ptr, command.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

/// Finds the first `"id": N` in a Hyprland JSON reply. Hyprland's IDs are
/// the only `id` key in its workspace JSON (`monitorID` etc. don't match the
/// literal `"id":`), so a plain substring scan is enough — no need to pull
/// in a full JSON parser for one integer field.
fn extractFirstId(json_text: []const u8) ?i32 {
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, json_text, needle) orelse return null;
    return parseIdAt(json_text, pos + needle.len);
}

fn parseIdAt(text: []const u8, start_pos: usize) ?i32 {
    var i = start_pos;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(i32, text[start..i], 10) catch null;
}

const Workspace = struct { id: i32, active: bool };

fn workspaceLessThan(_: void, a: Workspace, b: Workspace) bool {
    return a.id < b.id;
}

/// Tracks Hyprland's workspace list via IPC, matching waybar's
/// "hyprland/workspaces" module ("all-outputs": true, "sort-by-number": true,
/// "active-only": false from ~/.config/waybar/config).
const Workspaces = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Workspace),
    sock_path_buf: [108]u8 = undefined,
    sock_path_len: usize,

    fn init(gpa: std.mem.Allocator, sock_path: []const u8) !Workspaces {
        var self = Workspaces{
            .gpa = gpa,
            .list = .empty,
            .sock_path_len = sock_path.len,
        };
        @memcpy(self.sock_path_buf[0..sock_path.len], sock_path);
        self.refresh() catch |err| {
            std.debug.print("workspaces: initial refresh failed: {}\n", .{err});
        };
        return self;
    }

    fn deinit(self: *Workspaces) void {
        self.list.deinit(self.gpa);
    }

    fn sockPath(self: *const Workspaces) []const u8 {
        return self.sock_path_buf[0..self.sock_path_len];
    }

    fn refresh(self: *Workspaces) !void {
        const ws_json = try hyprctlRequest(self.gpa, self.sockPath(), "j/workspaces");
        defer self.gpa.free(ws_json);
        const active_json = try hyprctlRequest(self.gpa, self.sockPath(), "j/activeworkspace");
        defer self.gpa.free(active_json);

        const active_id = extractFirstId(active_json) orelse -1;

        self.list.clearRetainingCapacity();
        const needle = "\"id\":";
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, ws_json, idx, needle)) |pos| {
            const after = pos + needle.len;
            if (parseIdAt(ws_json, after)) |id| {
                try self.list.append(self.gpa, .{ .id = id, .active = id == active_id });
            }
            idx = after;
        }
        std.sort.insertion(Workspace, self.list.items, {}, workspaceLessThan);
    }

    /// Fire-and-forget a plain (non-JSON) hyprctl command, e.g.
    /// "dispatch hl.dsp.focus({ workspace = 2 })" — this instance's IPC
    /// socket routes `dispatch` through a Lua eval bridge (see
    /// ~/.config/hypr/hyprland.lua), not stock hyprctl syntax. The resulting
    /// workspace change comes back to us as an event on .socket2.sock, which
    /// triggers the normal refresh+redraw — no need to update local state
    /// here.
    fn dispatchCommand(self: *const Workspaces, command: []const u8) !void {
        if (self.sock_path_len == 0) return error.NoHyprland;
        const resp = try hyprctlRequest(self.gpa, self.sockPath(), command);
        self.gpa.free(resp);
    }
};

/// A click-through rectangle (currently horizontal-only, since the whole bar
/// is one row) mapped to an action, recomputed on every draw since module
/// layout can shift (e.g. workspaces being created/destroyed).
const MprisControl = enum { previous, play_pause, next };

const Action = union(enum) {
    switch_workspace: i32,
    spawn: [:0]const u8,
    toggle_drawer,
    activate_tray: usize,
    context_menu_tray: usize,
    mpris_control: MprisControl,
};

const ClickRegion = struct {
    x_start: i32,
    x_end: i32,
    action: Action, // left click
    right_action: ?Action = null, // right click; most regions don't have one
};

const MAX_CLICK_REGIONS = 32;

const ClickRegions = struct {
    items: [MAX_CLICK_REGIONS]ClickRegion = undefined,
    len: usize = 0,

    fn clear(self: *ClickRegions) void {
        self.len = 0;
    }

    fn add(self: *ClickRegions, x_start: i32, x_end: i32, action: Action) void {
        self.addWithRight(x_start, x_end, action, null);
    }

    fn addWithRight(self: *ClickRegions, x_start: i32, x_end: i32, action: Action, right_action: ?Action) void {
        if (self.len >= self.items.len) return; // scaffold-sized; fine for now
        self.items[self.len] = .{ .x_start = x_start, .x_end = x_end, .action = action, .right_action = right_action };
        self.len += 1;
    }

    fn hitTest(self: *const ClickRegions, x: i32) ?*const ClickRegion {
        for (self.items[0..self.len]) |*r| {
            if (x >= r.x_start and x < r.x_end) return r;
        }
        return null;
    }
};

// fork() is kept as a private helper inside std.c too (see the socket()
// comment above) — bind it ourselves.
const libc_proc = struct {
    extern "c" fn fork() c_int;
};

/// Runs `command` through `sh -c`, detached via the standard double-fork so
/// it survives us and doesn't leave a zombie — the same thing waybar itself
/// does for "on-click" commands.
fn spawnDetached(command: [:0]const u8) void {
    const pid = libc_proc.fork();
    if (pid < 0) return; // fork failed; nothing sensible to do about it
    if (pid == 0) {
        // First child: fork again immediately and exit, so the real
        // process (the grandchild) reparents to init instead of staying
        // under us. Uses _exit, not exit/return, to skip re-running any of
        // main()'s cleanup (Wayland disconnect, allocator deinit, ...) —
        // this process shares those fds with the parent, which still needs
        // them.
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr, null };
            _ = std.c.execve("/bin/sh", &argv, std.c.environ);
            std.c._exit(127); // execve only returns on failure
        }
        std.c._exit(0);
    }
    // Parent: reap the immediate child above, which exits right away —
    // this wait is not the long-lived spawned process.
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

/// Runs `playerctl -p <player> <command>` detached, targeting the exact
/// player currently shown by the mpris widget rather than playerctl's
/// no-target default (which acts on every running player at once — not
/// what a click on "this track's" controls should do). Goes straight to
/// execve with a real argv instead of spawnDetached's `sh -c` — `player`
/// comes from a D-Bus bus-name component (restricted to
/// [A-Za-z0-9_.-] by spec) so shell interpolation would be safe anyway,
/// but skipping the shell entirely sidesteps the question.
fn spawnPlayerctlCommand(player: []const u8, command: [*:0]const u8) void {
    var player_buf: [128]u8 = undefined;
    if (player.len == 0 or player.len >= player_buf.len) return;
    @memcpy(player_buf[0..player.len], player);
    player_buf[player.len] = 0;
    const player_z: [:0]const u8 = player_buf[0..player.len :0];

    const pid = libc_proc.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            // Routed through /usr/bin/env for PATH search, same as
            // startWeatherFetch/startVolumeFetch — execvp isn't bound here.
            var argv = [_:null]?[*:0]const u8{ "env", "playerctl", "-p", player_z.ptr, command, null };
            _ = std.c.execve("/usr/bin/env", &argv, std.c.environ);
            std.c._exit(127);
        }
        std.c._exit(0);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

const LauncherButton = struct {
    label: []const u8,
    command: [:0]const u8,
    // Not yet rendered by the bar (the font only draws label glyphs) —
    // carried through config for forward-compat with an icon-aware GUI/
    // pinning flow added in a later step.
    icon: ?[]const u8 = null,
};

// The custom/* launcher buttons from ~/.config/waybar/config's
// "modules-center", minus their icons (our font is uppercase-only for now).
// Labels are the words from each module's "format", commands from
// "on-click".
// Labels/icons copied verbatim from ~/.config/waybar/config's "format"
// strings (most of these have no icon at all in the real config — only
// custom/rofi does; the rest are plain text).
const CENTER_LAUNCHERS = [_]LauncherButton{
    .{ .label = "\u{f0c9} Menu", .command = "nwg-drawer" }, // custom/rofi
    .{ .label = "\u{f0ac} Browser", .command = "simpbar-launch-browser" }, // fa-globe
    .{ .label = "\u{f066f} Discord", .command = "simpbar-launch-discord" }, // nf-md-discord
    .{ .label = "\u{f07c} Files", .command = "nautilus" }, // fa-folder-open
    .{ .label = "\u{f120} Term", .command = "foot" }, // fa-terminal
    .{ .label = "\u{f1b6} Steam", .command = "steam" }, // fa-steam
    .{ .label = "\u{f013} HyprMod", .command = "hyprmod" }, // fa-cog
    .{ .label = "\u{f118} Welcome", .command = "simpbar-welcome" }, // fa-smile-o
};

// custom/power from "modules-right" — icon only in the real config, no text.
const POWER_BUTTON = LauncherButton{ .label = "\u{f0425}", .command = "wlogout" };

// custom/waypaper, one of the "group/tray-expander" drawer's children.
// Icon only in the real config, no text.
const WAYPAPER_BUTTON = LauncherButton{ .label = "\u{f030}", .command = "waypaper" };

// Real config's drawer toggle glyph (▾) — doesn't flip direction when
// expanded like the real one's rotating chevron does, but it's the actual
// character now instead of a stand-in letter.
const DRAWER_TOGGLE_LABEL = "\u{25be}";

// --- runtime config (module layout, appearance, launcher pins) -----------
//
// Loaded once at startup into `current_config` and (in a later step)
// replaced wholesale on a reload signal. `defaultConfig()` below reproduces
// today's exact hardcoded layout/order/colors, so a bar with no config file
// on disk yet (or one that fails to parse, once real JSON reading lands)
// behaves identically to this bar as it existed before any of this was
// added — see loadConfig().

const ModuleKind = enum {
    workspaces,
    mpris,
    clock,
    launchers,
    power,
    drawer_toggle,
    volume,
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
};

/// One entry in a left/center/right module list. Flat + all-optional
/// (beyond kind/enabled) rather than a tagged union, since std.json's
/// reflection-based parser (used starting in a later step) handles a flat
/// struct with optional fields directly, with no hand-written jsonParse.
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

const Appearance = struct {
    bg_color: u32,
    text_color: u32,
    border_color: u32,
    hover_color: u32,
    workspace_active_color: u32,
    workspace_inactive_color: u32,
    popup_bg_color: u32,
    popup_hover_color: u32,
    popup_separator_color: u32,
    popup_disabled_color: u32,
    bar_height: u32,
    /// Four independent edges (px), replacing the old single top-only
    /// border_px — which edge "faces the desktop" flips with `position`, but
    /// these are deliberately NOT auto-selected based on that: the user can
    /// have borders on any combination of sides regardless of anchor.
    border_top_px: u32,
    border_bottom_px: u32,
    border_left_px: u32,
    border_right_px: u32,
    workspace_gap: i64,
    font_path: []const u8,
    /// 0-100. Only the background fill's alpha varies with this — text,
    /// icons, and the border stay at their own configured (always fully
    /// opaque) colors, matching the typical "frosted glass" look rather than
    /// fading everything uniformly. Meant to be paired with the "simpbar"
    /// layer-shell namespace's Hyprland-side blur rule (hyprland.lua), since
    /// an app can't blur what's behind its own surface on Wayland — without
    /// that rule this is just a plain transparent cutout, not a blur.
    bg_opacity_percent: u8,
    /// "top" or "bottom" — which screen edge the layer-shell surface anchors
    /// to. Anything else falls back to "bottom" (today's only behavior)
    /// rather than erroring, same permissive-fallback spirit as every other
    /// config field.
    position: []const u8,
    /// Rounds all 4 corners by this many px, applied as the very last step
    /// of every draw (after background/borders/every module), by zeroing
    /// out (fully transparent, not just recolored) whichever corner pixels
    /// fall outside each corner's rounding circle. 0 = today's square
    /// corners. Clamped at draw time to at most half the shorter of
    /// bar.width/bar.height, since a bigger radius makes the corner math
    /// degenerate.
    corner_radius_px: u32,
    /// One of the CLOCK_FORMAT_* keys below. Unrecognized values fall back
    /// to "date_24h" (today's only-ever behavior) rather than erroring, same
    /// permissive-fallback spirit as `position`.
    clock_format: []const u8,
    /// Which output(s) to run a bar surface on. "" (default) = today's exact
    /// behavior (compositor picks whichever output it hands us first, one
    /// bar). "all" = one independent bar surface per currently-connected
    /// output. Anything else = the specific output name to target (e.g.
    /// "DP-1"); if no connected output currently has that name, main()
    /// falls back to "" behavior (single default bar) rather than showing no
    /// bar at all. Takes effect on the next bar restart, not live via
    /// SIGUSR1 — creating/destroying Wayland surfaces at runtime is a much
    /// bigger, riskier change than anything else this config drives live.
    monitor: []const u8,
};

// Curated clock-format presets (not a full strftime-style parser — matches
// this codebase's established "curated dropdown, not free-form input"
// pattern already used for network `mode`/`font_path`/`position`).
const CLOCK_FORMAT_DATE_24H = "date_24h"; // "DD - HH:MM" — today's default, unchanged
const CLOCK_FORMAT_TIME_24H = "time_24h"; // "HH:MM"
const CLOCK_FORMAT_TIME_24H_SECONDS = "time_24h_seconds"; // "HH:MM:SS"
const CLOCK_FORMAT_TIME_12H = "time_12h"; // "hh:mm AM/PM"
const CLOCK_FORMAT_DATE_12H = "date_12h"; // "DD - hh:mm AM/PM"

const ModuleLists = struct {
    left: []const ModuleEntry,
    center: []const ModuleEntry,
    right: []const ModuleEntry,
};

const Config = struct {
    appearance: Appearance,
    modules: ModuleLists,
    launchers: []const LauncherButton,
};

// Today's exact hardcoded layout/order — see the header comment above.
const DEFAULT_LEFT = [_]ModuleEntry{
    .{ .kind = .workspaces, .enabled = true },
    .{ .kind = .mpris, .enabled = true },
};
const DEFAULT_CENTER = [_]ModuleEntry{
    .{ .kind = .launchers, .enabled = true },
    .{ .kind = .clock, .enabled = true },
};
const DEFAULT_RIGHT = [_]ModuleEntry{
    .{ .kind = .power, .enabled = true },
    .{ .kind = .drawer_toggle, .enabled = true },
    .{ .kind = .volume, .enabled = true, .in_drawer = true },
    .{ .kind = .waypaper, .enabled = true, .in_drawer = true },
    .{ .kind = .pacman, .enabled = true, .in_drawer = true },
    .{ .kind = .tray, .enabled = true, .in_drawer = true },
    .{ .kind = .weather, .enabled = true },
};

fn defaultConfig() Config {
    return .{
        .appearance = .{
            // Colors lifted from ~/.config/waybar/style.css (0xAARRGGBB),
            // same values this file hardcoded before runtime config existed.
            .bg_color = 0xFF0F0F0F, // window#waybar background-color
            .text_color = 0xFFDCDCDC, // general label color, rgba(220,220,220,1)
            .border_color = 0xFF454545, // window#waybar border-color, rgba(69,69,69,1)
            .hover_color = 0xFF3A3A3A, // same shade as popup_hover_color, for the bar's own clickable buttons
            .workspace_active_color = 0xFFDCDCDC, // #workspaces button.active, rgba(220,220,220,1)
            .workspace_inactive_color = 0xFF505050, // #workspaces button, rgba(80,80,80,1)
            .popup_bg_color = 0xFF262626,
            .popup_hover_color = 0xFF3A3A3A,
            .popup_separator_color = 0xFF444444,
            .popup_disabled_color = 0xFF707070,
            .bar_height = 28,
            .border_top_px = 2, // window#waybar border-width: 2px 0px 0px 0px
            .border_bottom_px = 0,
            .border_left_px = 0,
            .border_right_px = 0,
            .workspace_gap = 10,
            .font_path = font_mod.FONT_PATH,
            .bg_opacity_percent = 100,
            .position = "bottom",
            .corner_radius_px = 0,
            .clock_format = CLOCK_FORMAT_DATE_24H,
            .monitor = "",
        },
        .modules = .{
            .left = &DEFAULT_LEFT,
            .center = &DEFAULT_CENTER,
            .right = &DEFAULT_RIGHT,
        },
        .launchers = &CENTER_LAUNCHERS,
    };
}

var current_config: Config = undefined;

/// Looks up `kind`'s `enabled` flag in `entries`; defaults to shown (true)
/// if `kind` isn't present at all, so a partially-specified config doesn't
/// silently hide modules it never mentioned.
fn isModuleEnabled(entries: []const ModuleEntry, kind: ModuleKind) bool {
    for (entries) |e| {
        if (e.kind == kind) return e.enabled;
    }
    return true;
}

// --- config file I/O + JSON schema ----------------------------------------
//
// ~/.config/simpbar/config.json, read once at startup and re-read whenever
// SIGUSR1 arrives (see main()'s event loop). File I/O goes through
// posix.system (== std.c when libc is linked, same as the posix.system.close
// calls already used throughout this file for fds) rather than std.fs, for
// the same reason the rest of this file avoids Zig 0.16's reworked
// std.fs/std.Io surface — posix.zig in this version doesn't expose a plain
// open()/write()/mkdir() the way it does read()/poll()/signalfd(), only
// openat() (which needs a dirfd) and the raw libc-backed `system` namespace,
// so `system` is what's used here instead of hand-declaring new externs
// (welcome_main.zig's approach, which predates posix.system being available
// as an option in this file).

var config_json_path_buf: [512]u8 = undefined;
var pidfile_path_buf: [512]u8 = undefined;
var config_json_path: [:0]const u8 = "";
var pidfile_path: [:0]const u8 = "";

/// Resolves ~/.config/simpbar/{config.json,simpbar.pid} from $HOME, creating
/// ~/.config/simpbar first if it doesn't exist yet (best-effort — mkdir's
/// result is intentionally ignored; if the directory truly can't be created,
/// the open() calls below will fail instead, and that failure path is
/// already handled). Mirrors welcome_main.zig's resolvePaths() pattern.
fn resolveConfigPaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    var dir_buf: [480]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o755);
    config_json_path = std.fmt.bufPrintZ(&config_json_path_buf, "{s}/config.json", .{dir}) catch "";
    pidfile_path = std.fmt.bufPrintZ(&pidfile_path_buf, "{s}/simpbar.pid", .{dir}) catch "";
}

/// Writes this process's PID to ~/.config/simpbar/simpbar.pid so the (future)
/// config GUI knows what to `kill -USR1` to trigger a live reload. Best
/// effort — a missing/stale pidfile just means a reload signal won't reach
/// us, not a reason to fail startup.
fn writePidfile() void {
    if (pidfile_path.len == 0) return;
    const raw_fd = posix.system.open(pidfile_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) return;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()}) catch return;
    var off: usize = 0;
    while (off < text.len) {
        const n = posix.system.write(fd, text[off..].ptr, text.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// Reads all of `path` into memory allocated from `allocator`. Small sanity
/// cap since config.json is never going to legitimately be large.
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
        if (list.items.len > 1024 * 1024) break; // sanity cap; config.json is tiny
    }
    return list.toOwnedSlice(allocator);
}

/// Converts a "#RRGGBB" hex string (as written by the config GUI / hand-
/// edited by a user) into this file's internal 0xAARRGGBB u32 form, alpha
/// forced to 0xFF — every color this bar draws is fully opaque today, so
/// there's nothing for the user-facing format to control there.
fn parseHexColor(s: []const u8) !u32 {
    if (s.len != 7 or s[0] != '#') return error.InvalidColor;
    const rgb = try std.fmt.parseInt(u32, s[1..7], 16);
    return 0xFF000000 | rgb;
}

// JSON-facing shape of "appearance" — colors arrive as hex strings (parsed
// via parseHexColor below), everything else matches Appearance's fields
// directly. Every field has a default matching defaultConfig()'s values, so
// a config.json that only overrides e.g. bg_color doesn't need to spell out
// every other color too.
const JsonAppearance = struct {
    bg_color: []const u8 = "#0F0F0F",
    text_color: []const u8 = "#DCDCDC",
    border_color: []const u8 = "#454545",
    hover_color: []const u8 = "#3A3A3A",
    workspace_active_color: []const u8 = "#DCDCDC",
    workspace_inactive_color: []const u8 = "#505050",
    popup_bg_color: []const u8 = "#262626",
    popup_hover_color: []const u8 = "#3A3A3A",
    popup_separator_color: []const u8 = "#444444",
    popup_disabled_color: []const u8 = "#707070",
    bar_height: u32 = 28,
    border_top_px: u32 = 2,
    border_bottom_px: u32 = 0,
    border_left_px: u32 = 0,
    border_right_px: u32 = 0,
    workspace_gap: i64 = 10,
    font_path: []const u8 = font_mod.FONT_PATH,
    bg_opacity_percent: u8 = 100,
    position: []const u8 = "bottom",
    corner_radius_px: u32 = 0,
    clock_format: []const u8 = CLOCK_FORMAT_DATE_24H,
    monitor: []const u8 = "",
};

// JSON-facing shape of "modules" — ModuleEntry's own fields already match
// the schema exactly (kind parses straight from a JSON string via std.json's
// enum support, matching ModuleKind's tag names), so no separate JSON-only
// module-entry type is needed. Defaults to today's hardcoded layout, so a
// config.json that only overrides "appearance" doesn't wipe out every
// module the moment it's read.
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

/// Two persistent arenas backing successfully-parsed Configs, used as a
/// double buffer: `config_arenas[config_arena_active]` backs whatever
/// `current_config` currently points to, and every load parses into the
/// *other* (inactive) arena, only flipping `config_arena_active` to it once
/// parsing has fully succeeded. This is required, not cosmetic — a single
/// shared arena reset unconditionally at the start of every load (including
/// reloads) frees the *live* config's memory before the new parse is known
/// to succeed, so a failed reload (missing/malformed file) leaves
/// `current_config` pointing at freed/reused memory and segfaults on the
/// next draw. Swapping only on success means a failed reload never touches
/// the arena backing the config still in use.
var config_arenas = [2]std.heap.ArenaAllocator{
    std.heap.ArenaAllocator.init(std.heap.page_allocator),
    std.heap.ArenaAllocator.init(std.heap.page_allocator),
};
var config_arena_active: usize = 0;

/// Copies `path` into `buf` with a null terminator and returns a
/// sentinel-terminated view of it — font_mod.Font.init needs `[:0]const u8`,
/// but Appearance.font_path (like every other config-sourced string) is a
/// plain `[]const u8` from config_arena, not necessarily null-terminated.
/// Returns null if `path` doesn't fit in `buf`.
fn fontPathZ(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn parseAppearance(j: JsonAppearance) ?Appearance {
    return Appearance{
        .bg_color = parseHexColor(j.bg_color) catch return null,
        .text_color = parseHexColor(j.text_color) catch return null,
        .border_color = parseHexColor(j.border_color) catch return null,
        .hover_color = parseHexColor(j.hover_color) catch return null,
        .workspace_active_color = parseHexColor(j.workspace_active_color) catch return null,
        .workspace_inactive_color = parseHexColor(j.workspace_inactive_color) catch return null,
        .popup_bg_color = parseHexColor(j.popup_bg_color) catch return null,
        .popup_hover_color = parseHexColor(j.popup_hover_color) catch return null,
        .popup_separator_color = parseHexColor(j.popup_separator_color) catch return null,
        .popup_disabled_color = parseHexColor(j.popup_disabled_color) catch return null,
        .bar_height = j.bar_height,
        .border_top_px = j.border_top_px,
        .border_bottom_px = j.border_bottom_px,
        .border_left_px = j.border_left_px,
        .border_right_px = j.border_right_px,
        .workspace_gap = j.workspace_gap,
        .font_path = j.font_path,
        .bg_opacity_percent = @min(j.bg_opacity_percent, 100),
        .position = if (std.mem.eql(u8, j.position, "top")) "top" else "bottom",
        .corner_radius_px = j.corner_radius_px,
        .clock_format = validClockFormat(j.clock_format),
        // No validation against currently-connected outputs here — parsing
        // happens before Wayland registry discovery has run, so there's
        // nothing to validate against yet. main()'s target-output-selection
        // step (after outputs are discovered) is what falls back to ""
        // behavior for a name that doesn't match any connected output.
        .monitor = j.monitor,
    };
}

/// Returns `raw` unchanged if it's one of the recognized CLOCK_FORMAT_*
/// keys, else falls back to the default — same permissive-fallback
/// treatment `position` already gets, so a stale/mistyped value in a
/// hand-edited config.json never crashes or blanks the clock.
fn validClockFormat(raw: []const u8) []const u8 {
    const known = [_][]const u8{
        CLOCK_FORMAT_DATE_24H, CLOCK_FORMAT_TIME_24H, CLOCK_FORMAT_TIME_24H_SECONDS,
        CLOCK_FORMAT_TIME_12H, CLOCK_FORMAT_DATE_12H,
    };
    for (known) |k| {
        if (std.mem.eql(u8, raw, k)) return k;
    }
    return CLOCK_FORMAT_DATE_24H;
}

/// Reads + parses ~/.config/simpbar/config.json. Returns null on ANY
/// failure (missing file, unreadable, malformed JSON, bad color hex, ...) —
/// callers decide what null means: loadConfig() (startup) falls back to
/// defaultConfig(), while the SIGUSR1 reload handler in main() instead keeps
/// whatever current_config already is, so a bad edit never reverts a
/// working bar to defaults and never crashes it.
fn loadConfigFromFile() ?Config {
    // Parse into the INACTIVE arena — config_arenas[config_arena_active]
    // backs the live current_config and must not be touched unless/until
    // this parse fully succeeds (see the arena doc comment above).
    const next_index = 1 - config_arena_active;
    _ = config_arenas[next_index].reset(.free_all);
    const allocator = config_arenas[next_index].allocator();

    const bytes = readFileAlloc(allocator, config_json_path) catch |err| {
        std.debug.print("config: could not read {s}: {}\n", .{ config_json_path, err });
        return null;
    };

    const parsed = std.json.parseFromSliceLeaky(JsonConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("config: could not parse {s}: {}\n", .{ config_json_path, err });
        return null;
    };

    const appearance = parseAppearance(parsed.appearance) orelse {
        std.debug.print("config: bad color value in {s}\n", .{config_json_path});
        return null;
    };

    config_arena_active = next_index;
    return Config{
        .appearance = appearance,
        .modules = .{
            .left = parsed.modules.left,
            .center = parsed.modules.center,
            .right = parsed.modules.right,
        },
        .launchers = parsed.launchers,
    };
}

/// Startup load only: the real file if present and valid, else
/// defaultConfig() — so a bar with no config.json on disk yet behaves
/// exactly like it always has. Reloads (SIGUSR1) call loadConfigFromFile()
/// directly instead, specifically to skip this fallback — see its doc
/// comment.
fn loadConfig() Config {
    return loadConfigFromFile() orelse defaultConfig();
}

// --- tray (org.kde.StatusNotifierItem via a hand-rolled D-Bus client) -----
//
// Nothing on this system currently hosts org.kde.StatusNotifierWatcher, so
// we have to BE it (not just read from one): RegisterStatusNotifierItem is
// an incoming method call we must answer, not something we poll for. Apps
// already running when we start (Discord, Steam, ...) will have already
// tried and given up before we existed, so they need restarting to notice
// us — this is a real limitation, not a bug to chase.
//
// Icons: only IconPixmap (raw ARGB32 bytes, already in the item's D-Bus
// reply) is supported. IconName would need freedesktop icon-theme lookup
// plus PNG/SVG decoding — real image decoding is out of scope here.

const MAX_TRAY_ITEMS = 6;
const TRAY_ICON_SIZE = 14; // roughly matches the font's glyph height
const TRAY_REFRESH_SECONDS: i64 = 2; // one item's icon refreshed per tick

const TrayItem = struct {
    bus_name_buf: [64]u8 = undefined,
    bus_name_len: usize = 0,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    pixels: [TRAY_ICON_SIZE * TRAY_ICON_SIZE]u32 = [_]u32{0} ** (TRAY_ICON_SIZE * TRAY_ICON_SIZE),
    has_icon: bool = false,
    fail_count: u32 = 0,

    fn busName(self: *const TrayItem) []const u8 {
        return self.bus_name_buf[0..self.bus_name_len];
    }
    fn itemPath(self: *const TrayItem) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn set(self: *TrayItem, bus_name: []const u8, path: []const u8) void {
        self.bus_name_len = @min(bus_name.len, self.bus_name_buf.len);
        @memcpy(self.bus_name_buf[0..self.bus_name_len], bus_name[0..self.bus_name_len]);
        self.path_len = @min(path.len, self.path_buf.len);
        @memcpy(self.path_buf[0..self.path_len], path[0..self.path_len]);
        self.has_icon = false;
        self.fail_count = 0;
    }
};

/// Nearest-neighbor downscale of a StatusNotifierItem icon (network-byte-
/// order — i.e. big-endian — ARGB32 bytes, per the SNI spec) into our own
/// little-endian-word 0xAARRGGBB pixel buffer at a fixed square size.
fn downscaleArgb(src: []const u8, src_w: u32, src_h: u32, dst: []u32, dst_size: u32) void {
    if (src_w == 0 or src_h == 0) return;
    for (0..dst_size) |dy| {
        const sy = @min(src_h - 1, dy * src_h / dst_size);
        for (0..dst_size) |dx| {
            const sx = @min(src_w - 1, dx * src_w / dst_size);
            const idx = (sy * src_w + sx) * 4;
            if (idx + 4 > src.len) {
                dst[dy * dst_size + dx] = 0;
                continue;
            }
            const a = src[idx];
            const r = src[idx + 1];
            const g = src[idx + 2];
            const b = src[idx + 3];
            dst[dy * dst_size + dx] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        }
    }
}

/// Fetches org.kde.StatusNotifierItem's IconName property (a themed icon
/// name, e.g. "steam_tray_mono") for one item, resolves it to a real file
/// via icontheme.resolveIconPath, decodes it, and centers it into
/// `item.pixels` — the fallback for apps (Steam, Spotify, ...) that don't
/// embed raw pixel data via IconPixmap.
fn fetchIconByName(gpa: std.mem.Allocator, c: *dbus.Connection, item: *TrayItem) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    try dbus.appendStringLike(&body, std.heap.page_allocator, "org.kde.StatusNotifierItem");
    try dbus.appendStringLike(&body, std.heap.page_allocator, "IconName");
    const reply = try c.call(.{
        .destination = item.busName(),
        .path = item.itemPath(),
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
    }, .{ .bytes = body.items, .signature = "ss" });
    defer reply.deinit();
    var r = reply.bodyReader();
    _ = try r.readSignature();
    const name = try r.readStringLike();
    if (name.len == 0) return error.NoIconName;

    var path_buf: [512]u8 = undefined;
    const path_slice = icontheme.resolveIconPath(name, &path_buf) orelse return error.IconNotFound;
    var path_z_buf: [512]u8 = undefined;
    @memcpy(path_z_buf[0..path_slice.len], path_slice);
    path_z_buf[path_slice.len] = 0;
    const path_z: [:0]const u8 = path_z_buf[0..path_slice.len :0];

    const decoded = try icontheme.decodeIcon(gpa, path_z, TRAY_ICON_SIZE);
    defer gpa.free(decoded.pixels);
    icontheme.copyIntoIconBuffer(decoded, &item.pixels, TRAY_ICON_SIZE);
    item.has_icon = true;
}

/// Fetches org.kde.StatusNotifierItem's IconPixmap property for one item
/// and downscales whichever entry is the best fit into `item.pixels`.
fn fetchIconPixmap(c: *dbus.Connection, item: *TrayItem) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    try dbus.appendStringLike(&body, std.heap.page_allocator, "org.kde.StatusNotifierItem");
    try dbus.appendStringLike(&body, std.heap.page_allocator, "IconPixmap");

    const reply = try c.call(.{
        .destination = item.busName(),
        .path = item.itemPath(),
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
    }, .{ .bytes = body.items, .signature = "ss" });
    defer reply.deinit();

    var r = reply.bodyReader();
    const sig = try r.readSignature(); // the variant's inner signature
    if (sig.len == 0 or sig[0] != 'a') return error.UnexpectedType;

    const array_bytes = try r.readU32();
    try r.alignTo(8);
    const array_end = r.pos + array_bytes;
    if (array_end > r.bytes.len) return error.Truncated;

    var best_w: i32 = 0;
    var best_h: i32 = 0;
    var best_pixels: []const u8 = &.{};

    while (r.pos < array_end) {
        try r.alignTo(8);
        const w = try r.readI32();
        const h = try r.readI32();
        const byte_len = try r.readU32();
        if (r.pos + byte_len > r.bytes.len) return error.Truncated;
        const pixel_bytes = r.bytes[r.pos..][0..byte_len];
        r.pos += byte_len;

        // Prefer the smallest icon that's still >= our render size (less
        // downscaling blur); fall back to the largest option if every
        // choice offered is smaller than that.
        if (best_w == 0 or (w >= TRAY_ICON_SIZE and (best_w < TRAY_ICON_SIZE or w < best_w))) {
            best_w = w;
            best_h = h;
            best_pixels = pixel_bytes;
        }
    }

    if (best_w == 0 or best_h == 0) return error.NoIcon;
    downscaleArgb(best_pixels, @intCast(best_w), @intCast(best_h), &item.pixels, TRAY_ICON_SIZE);
    item.has_icon = true;
}

/// Hosts org.kde.StatusNotifierWatcher (the registration point tray icons
/// call into) and tracks whatever registers, refreshing icons and handling
/// clicks (Activate). Degrades to "no tray" — not a crash — if the bus
/// connection fails or the name is already taken by something else.
const Tray = struct {
    gpa: std.mem.Allocator,
    conn: ?dbus.Connection = null,
    items: [MAX_TRAY_ITEMS]TrayItem = [_]TrayItem{.{}} ** MAX_TRAY_ITEMS,
    item_count: usize = 0,
    refresh_index: usize = 0,

    fn init(gpa: std.mem.Allocator) Tray {
        var self = Tray{ .gpa = gpa };
        var conn = dbus.Connection.connect() catch |err| {
            std.debug.print("tray: dbus connect failed: {}\n", .{err});
            return self;
        };
        requestWatcherName(&conn) catch |err| {
            std.debug.print("tray: could not become StatusNotifierWatcher: {}\n", .{err});
            conn.close();
            return self;
        };
        self.conn = conn;
        return self;
    }

    fn deinit(self: *Tray) void {
        if (self.conn) |*c| c.close();
    }

    fn pollFd(self: *const Tray) posix.fd_t {
        return if (self.conn) |c| c.fd else -1;
    }

    fn findItem(self: *Tray, bus_name: []const u8) ?*TrayItem {
        for (self.items[0..self.item_count]) |*it| {
            if (std.mem.eql(u8, it.busName(), bus_name)) return it;
        }
        return null;
    }

    fn addItem(self: *Tray, bus_name: []const u8, path: []const u8) void {
        if (self.findItem(bus_name)) |existing| {
            existing.set(bus_name, path);
            return;
        }
        if (self.item_count >= self.items.len) return; // scaffold-sized; fine for now
        self.items[self.item_count].set(bus_name, path);
        self.item_count += 1;
    }

    fn removeItem(self: *Tray, index: usize) void {
        var i = index;
        while (i + 1 < self.item_count) : (i += 1) self.items[i] = self.items[i + 1];
        self.item_count -= 1;
    }

    /// Call when poll() reports the D-Bus fd readable. Handles exactly one
    /// message: RegisterStatusNotifierItem calls are acked and tracked,
    /// everything else (signals we didn't ask for, e.g.) is dropped.
    fn onReadable(self: *Tray) void {
        const c: *dbus.Connection = if (self.conn) |*conn| conn else return;
        const msg = c.readMessage(std.heap.page_allocator) catch |err| {
            std.debug.print("tray: dbus connection lost: {}\n", .{err});
            c.close();
            self.conn = null;
            return;
        };
        defer msg.deinit();
        if (msg.msg_type != .method_call) return;
        const member = msg.member orelse return;
        if (!std.mem.eql(u8, member, "RegisterStatusNotifierItem")) {
            if (std.mem.eql(u8, member, "Introspect")) {
                const sender = msg.sender orelse return;
                const introspect_xml =
                    \\<node>
                    \\<interface name="org.kde.StatusNotifierWatcher">
                    \\<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
                    \\<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
                    \\<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
                    \\</interface>
                    \\<interface name="org.freedesktop.DBus.Properties">
                    \\<method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
                    \\<method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
                    \\</interface>
                    \\</node>
                ;
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(std.heap.page_allocator);
                dbus.appendStringLike(&body, std.heap.page_allocator, introspect_xml) catch return;
                c.send(.method_return, .{ .reply_serial = msg.serial, .destination = sender, .signature = "s" }, .{ .bytes = body.items, .signature = "s" }) catch {};
            } else if (msg.interface != null and std.mem.eql(u8, msg.interface.?, "org.freedesktop.DBus.Properties") and
                (std.mem.eql(u8, member, "Get") or std.mem.eql(u8, member, "GetAll")))
            {
                // Real SNI hosts (KDE, most trays) answer these, and most
                // D-Bus client libraries (GDBus among them — almost
                // certainly what Electron's built-in SNI client uses)
                // bootstrap a remote object with GetAll before ever calling
                // RegisterStatusNotifierItem. Leaving Get unanswered meant
                // the caller just hung; leaving GetAll erroring out (or
                // silently dropped, as both were before this) likely killed
                // registration before it ever started.
                if (std.mem.eql(u8, member, "Get")) {
                    self.handleGetProperty(c, &msg) catch |err| std.debug.print("tray: Get failed: {}\n", .{err});
                } else {
                    self.handleGetAllProperties(c, &msg) catch |err| std.debug.print("tray: GetAll failed: {}\n", .{err});
                }
            } else {
                const sender = msg.sender orelse return;
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(std.heap.page_allocator);
                dbus.appendStringLike(&body, std.heap.page_allocator, "Unknown method") catch return;
                c.send(.error_reply, .{
                    .reply_serial = msg.serial,
                    .destination = sender,
                    .error_name = "org.freedesktop.DBus.Error.UnknownMethod",
                }, .{ .bytes = body.items, .signature = "s" }) catch {};
            }
            return;
        }
        const sender = msg.sender orelse return;

        var item_path: []const u8 = "/StatusNotifierItem"; // widely-used default
        var body_r = msg.bodyReader();
        if (body_r.readStringLike()) |s| {
            if (s.len > 0 and s[0] == '/') {
                item_path = s;
            } else if (std.mem.indexOfScalar(u8, s, '/')) |slash_idx| {
                // Some hosts (Electron/Chromium among them) pass
                // "<well-known-bus-name>/<object-path>" concatenated into
                // one string instead of a bare path (e.g.
                // "org.freedesktop.StatusNotifierItem-254871-1/StatusNotifierItem/1")
                // — split at the first '/' and keep the object-path half.
                // Getting this wrong silently pointed every icon fetch at
                // the wrong object, which looked identical to the item
                // just never having a working icon before it got dropped
                // for repeated fetch failures.
                item_path = s[slash_idx..];
            }
        } else |_| {}
        self.addItem(sender, item_path);

        c.send(.method_return, .{ .reply_serial = msg.serial, .destination = sender }, .{}) catch |err| {
            std.debug.print("tray: failed to ack registration: {}\n", .{err});
        };
    }

    /// Answers org.freedesktop.DBus.Properties.Get on our own
    /// StatusNotifierWatcher object. Some tray clients (Vesktop among
    /// them) check IsStatusNotifierHostRegistered before or around calling
    /// RegisterStatusNotifierItem, so leaving this unanswered stalls
    /// registration even though we're up and listening.
    fn handleGetProperty(self: *Tray, c: *dbus.Connection, msg: *const dbus.Message) !void {
        const sender = msg.sender orelse return;
        var r = msg.bodyReader();
        _ = try r.readStringLike(); // interface name — we only ever host one
        const prop = try r.readStringLike();

        const gpa = std.heap.page_allocator;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);

        if (std.mem.eql(u8, prop, "IsStatusNotifierHostRegistered")) {
            try dbus.appendSignature(&body, gpa, "b");
            try dbus.appendU32(&body, gpa, 1);
        } else if (std.mem.eql(u8, prop, "RegisteredStatusNotifierItems")) {
            try dbus.appendSignature(&body, gpa, "as");
            try dbus.appendU32(&body, gpa, 0); // array length in bytes, patched below
            const len_offset = body.items.len - 4;
            try dbus.alignTo(&body, gpa, 4);
            const start = body.items.len;
            for (self.items[0..self.item_count]) |*item| {
                try dbus.appendStringLike(&body, gpa, item.busName());
            }
            const array_len: u32 = @intCast(body.items.len - start);
            std.mem.writeInt(u32, body.items[len_offset..][0..4], array_len, .little);
        } else {
            c.send(.error_reply, .{
                .reply_serial = msg.serial,
                .destination = sender,
                .error_name = "org.freedesktop.DBus.Error.UnknownProperty",
            }, .{}) catch {};
            return;
        }

        c.send(.method_return, .{ .reply_serial = msg.serial, .destination = sender, .signature = "v" }, .{ .bytes = body.items, .signature = "v" }) catch {};
    }

    /// Answers org.freedesktop.DBus.Properties.GetAll — most D-Bus client
    /// libraries (GDBus included) bootstrap a remote object with GetAll
    /// before calling any of its real methods, so a host that only answers
    /// individual Get calls can still stall every client that does this.
    fn handleGetAllProperties(self: *Tray, c: *dbus.Connection, msg: *const dbus.Message) !void {
        const sender = msg.sender orelse return;
        const gpa = std.heap.page_allocator;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);

        try dbus.appendU32(&body, gpa, 0); // outer array length in bytes, patched below
        const len_offset = body.items.len - 4;
        try dbus.alignTo(&body, gpa, 8); // dict entries align like structs
        const start = body.items.len;

        try dbus.alignTo(&body, gpa, 8);
        try dbus.appendStringLike(&body, gpa, "IsStatusNotifierHostRegistered");
        try dbus.appendSignature(&body, gpa, "b");
        try dbus.appendU32(&body, gpa, 1);

        try dbus.alignTo(&body, gpa, 8);
        try dbus.appendStringLike(&body, gpa, "RegisteredStatusNotifierItems");
        try dbus.appendSignature(&body, gpa, "as");
        try dbus.appendU32(&body, gpa, 0); // inner array length, patched below
        const inner_len_offset = body.items.len - 4;
        try dbus.alignTo(&body, gpa, 4);
        const inner_start = body.items.len;
        for (self.items[0..self.item_count]) |*item| {
            try dbus.appendStringLike(&body, gpa, item.busName());
        }
        const inner_len: u32 = @intCast(body.items.len - inner_start);
        std.mem.writeInt(u32, body.items[inner_len_offset..][0..4], inner_len, .little);

        const array_len: u32 = @intCast(body.items.len - start);
        std.mem.writeInt(u32, body.items[len_offset..][0..4], array_len, .little);

        c.send(.method_return, .{ .reply_serial = msg.serial, .destination = sender, .signature = "a{sv}" }, .{ .bytes = body.items, .signature = "a{sv}" }) catch {};
    }

    /// Refreshes one item's icon per call (round-robin), so a periodic
    /// tick spreads the blocking D-Bus round-trips out instead of doing
    /// them all at once. Drops an item after a few consecutive failures
    /// (it's probably closed and its bus name is gone).
    fn refreshOne(self: *Tray) void {
        if (self.item_count == 0) return;
        const c: *dbus.Connection = if (self.conn) |*conn| conn else return;
        if (self.refresh_index >= self.item_count) self.refresh_index = 0;
        const idx = self.refresh_index;
        self.refresh_index += 1;

        fetchIconPixmap(c, &self.items[idx]) catch {
            // No raw pixel data (common for apps like Steam/Spotify) — try
            // resolving IconName to a real theme icon file instead.
            fetchIconByName(self.gpa, c, &self.items[idx]) catch {
                self.items[idx].fail_count += 1;
                // Dropped after repeated failures of *both* — probably
                // closed (bus name gone), since a stable app would succeed
                // via one path or the other every cycle.
                if (self.items[idx].fail_count >= 3) {
                    self.removeItem(idx);
                    self.refresh_index = idx;
                }
                return;
            };
        };
        self.items[idx].fail_count = 0;
    }

    /// Activate (left click) and ContextMenu (right click) are both
    /// "member(x, y)" calls on the item with no meaningful reply — real
    /// screen coordinates would matter for where the app draws its context
    /// menu, but 0,0 is fine here since we don't have that geometry handy.
    fn sendXYCall(self: *Tray, index: usize, member: []const u8) void {
        if (index >= self.item_count) return;
        const c: *dbus.Connection = if (self.conn) |*conn| conn else return;
        const item = &self.items[index];
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(std.heap.page_allocator);
        dbus.appendI32(&body, std.heap.page_allocator, 0) catch return;
        dbus.appendI32(&body, std.heap.page_allocator, 0) catch return;
        c.send(.method_call, .{
            .path = item.itemPath(),
            .interface = "org.kde.StatusNotifierItem",
            .member = member,
            .destination = item.busName(),
        }, .{ .bytes = body.items, .signature = "ii" }) catch |err| {
            std.debug.print("tray: {s} failed: {}\n", .{ member, err });
        };
    }

    fn activate(self: *Tray, index: usize) void {
        self.sendXYCall(index, "Activate");
    }

    fn contextMenu(self: *Tray, index: usize) void {
        self.sendXYCall(index, "ContextMenu");
    }

    // TEMPORARY — validating dbusmenu.zig's recursive parser against a
    // real menu (Steam's) before writing any popup UI around it.
};

fn requestWatcherName(c: *dbus.Connection) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    try dbus.appendStringLike(&body, std.heap.page_allocator, "org.kde.StatusNotifierWatcher");
    try dbus.appendU32(&body, std.heap.page_allocator, 4); // DBUS_NAME_FLAG_DO_NOT_QUEUE

    const reply = try c.call(.{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "RequestName",
    }, .{ .bytes = body.items, .signature = "su" });
    defer reply.deinit();

    var r = reply.bodyReader();
    const result = try r.readU32();
    if (result != 1) return error.NameTaken; // 1 == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER
}

// --- DBusMenu popup (right-click context menus for tray items that only
// expose a Menu property — Steam, Spotify — instead of Activate/ContextMenu
// methods) -------------------------------------------------------------

const POPUP_ROW_HEIGHT: i32 = 20;
const POPUP_SEPARATOR_HEIGHT: i32 = 7;
const POPUP_PADDING_X: i32 = 10;
const POPUP_MIN_WIDTH: i32 = 80;
const POPUP_MAX_WIDTH: i32 = 320;
const MAX_POPUP_ROWS = 40;

const PopupRow = struct {
    y_start: i32,
    y_end: i32,
    /// dbusmenu item id to send a "clicked" Event for, or null for rows
    /// that aren't independently clickable (separators, submenu headers —
    /// there's no drill-down navigation in this scaffold, so a submenu
    /// header just isn't actionable).
    item_id: ?i32,
};

/// One open right-click context menu, backed by a real xdg_popup surface
/// (parented to our layer-shell bar via zwlr_layer_surface_v1::get_popup).
/// Only the top-level items are shown — no submenu drill-down, which costs
/// nothing for the apps actually tested against (Steam's menu is flat).
const PopupMenu = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    popup: *xdg.Popup,
    dest_buf: [64]u8 = undefined,
    dest_len: usize = 0,
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    menu: dbusmenu.DbusMenu,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    rows: [MAX_POPUP_ROWS]PopupRow = undefined,
    row_count: usize = 0,

    fn dest(self: *const PopupMenu) []const u8 {
        return self.dest_buf[0..self.dest_len];
    }
    fn path(self: *const PopupMenu) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn hitTestRow(self: *const PopupMenu, y: i32) ?PopupRow {
        for (self.rows[0..self.row_count]) |row| {
            if (y >= row.y_start and y < row.y_end) return row;
        }
        return null;
    }
};

/// Right-click on a tray item: fetches its Menu property; if present,
/// builds and shows a real popup listing the top-level items. Falls back to
/// a plain ContextMenu(0,0) call (the pre-DBusMenu behavior) if there's no
/// Menu property or fetching/parsing it fails — some items genuinely do
/// implement ContextMenu directly (Vesktop does).
fn openTrayContextMenu(bar: *Bar, tray_index: usize) void {
    if (bar.popup != null) return; // one at a time
    if (tray_index >= bar.tray.item_count) return;
    const item = &bar.tray.items[tray_index];
    const c: *dbus.Connection = if (bar.tray.conn) |*conn| conn else return;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    dbus.appendStringLike(&body, std.heap.page_allocator, "org.kde.StatusNotifierItem") catch return;
    dbus.appendStringLike(&body, std.heap.page_allocator, "Menu") catch return;
    const reply = c.call(.{
        .destination = item.busName(),
        .path = item.itemPath(),
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
    }, .{ .bytes = body.items, .signature = "ss" }) catch {
        bar.tray.contextMenu(tray_index);
        return;
    };
    defer reply.deinit();
    var r = reply.bodyReader();
    _ = r.readSignature() catch return;
    const menu_path = r.readStringLike() catch return;
    if (menu_path.len == 0) {
        bar.tray.contextMenu(tray_index);
        return;
    }

    const menu = dbusmenu.fetchMenu(c, item.busName(), menu_path) catch {
        bar.tray.contextMenu(tray_index);
        return;
    };

    const wm_base = bar.wm_base orelse return;
    const surface = bar.compositor.createSurface() catch return;
    const xdg_surface = wm_base.getXdgSurface(surface) catch {
        surface.destroy();
        return;
    };
    const positioner = wm_base.createPositioner() catch {
        xdg_surface.destroy();
        surface.destroy();
        return;
    };
    defer positioner.destroy();

    var top_idx: [MAX_POPUP_ROWS]usize = undefined;
    const top_children = menu.childrenOf(0, &top_idx);

    var max_w: i32 = POPUP_MIN_WIDTH;
    for (top_children) |idx| {
        const it = &menu.items[idx];
        if (it.is_separator) continue;
        const w: i32 = @intCast(textPixelWidth(bar.font, it.label()) + POPUP_PADDING_X * 2);
        if (w > max_w) max_w = w;
    }
    if (max_w > POPUP_MAX_WIDTH) max_w = POPUP_MAX_WIDTH;
    var total_h: i32 = 0;
    for (top_children) |idx| {
        total_h += if (menu.items[idx].is_separator) POPUP_SEPARATOR_HEIGHT else POPUP_ROW_HEIGHT;
    }
    if (total_h < POPUP_ROW_HEIGHT) total_h = POPUP_ROW_HEIGHT;

    positioner.setSize(max_w, total_h);
    // Anchor a thin rect at the clicked x position, spanning the bar's full
    // height — the popup opens above it (bar is bottom-anchored), sliding
    // to stay on-screen horizontally if it would run off either edge.
    const anchor_x: i32 = @max(0, bar.pointer_x - 4);
    positioner.setAnchorRect(anchor_x, 0, 8, @intCast(bar.height));
    positioner.setAnchor(.top);
    positioner.setGravity(.top);
    positioner.setConstraintAdjustment(.{ .slide_x = true, .slide_y = true, .flip_y = true });

    const popup = xdg_surface.getPopup(null, positioner) catch {
        xdg_surface.destroy();
        surface.destroy();
        return;
    };
    bar.layer_surface.getPopup(popup);

    var pm = PopupMenu{
        .surface = surface,
        .xdg_surface = xdg_surface,
        .popup = popup,
        .menu = menu,
    };
    pm.dest_len = @min(item.busName().len, pm.dest_buf.len);
    @memcpy(pm.dest_buf[0..pm.dest_len], item.busName()[0..pm.dest_len]);
    pm.path_len = @min(menu_path.len, pm.path_buf.len);
    @memcpy(pm.path_buf[0..pm.path_len], menu_path[0..pm.path_len]);
    bar.popup = pm;

    xdg_surface.setListener(*Bar, popupXdgSurfaceListener, bar);
    popup.setListener(*Bar, popupEventListener, bar);
    if (bar.seat) |seat| popup.grab(seat, bar.last_pointer_serial);

    surface.commit(); // initial null commit — triggers the first configure
}

fn closePopup(bar: *Bar) void {
    var pm = bar.popup orelse return;
    pm.popup.destroy();
    pm.xdg_surface.destroy();
    pm.surface.destroy();
    bar.popup = null;
    // Defensive — the compositor should send a real .leave for the
    // destroyed popup surface, but don't leave a stray click on the main
    // bar misrouted in the meantime if that's ever not synchronous.
    bar.pointer_over_popup = false;
}

fn popupXdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, bar: *Bar) void {
    switch (event) {
        .configure => |cfg| {
            xdg_surface.ackConfigure(cfg.serial);
            var pm = &(bar.popup orelse return);
            pm.configured = true;
            drawPopup(bar) catch |err| std.debug.print("popup draw failed: {}\n", .{err});
        },
    }
}

fn popupEventListener(_: *xdg.Popup, event: xdg.Popup.Event, bar: *Bar) void {
    switch (event) {
        .configure => |cfg| {
            var pm = &(bar.popup orelse return);
            pm.width = @intCast(@max(1, cfg.width));
            pm.height = @intCast(@max(1, cfg.height));
        },
        .popup_done => closePopup(bar),
        .repositioned => {},
    }
}

/// Renders the popup's menu rows into a fresh SHM buffer and commits it —
/// the same pattern as drawAndCommit, just for the popup's own surface and
/// a much simpler (single-column list) layout. Also (re)populates
/// `rows` for hit-testing hover/click.
fn drawPopup(bar: *Bar) !void {
    var pm = &(bar.popup orelse return);
    if (!pm.configured or pm.width == 0 or pm.height == 0) return;

    const stride = pm.width * 4;
    const size: usize = @as(usize, stride) * pm.height;

    const fd = try posix.memfd_create("simpbar-popup", 0);
    defer _ = posix.system.close(fd);
    switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
        .SUCCESS => {},
        else => return error.FTruncateFailed,
    }
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    const pixels: [*]u32 = @ptrCast(@alignCast(data.ptr));
    @memset(pixels[0 .. size / 4], current_config.appearance.popup_bg_color);

    var top_idx: [MAX_POPUP_ROWS]usize = undefined;
    const top_children = pm.menu.childrenOf(0, &top_idx);

    pm.row_count = 0;
    var y: i32 = 0;
    for (top_children) |idx| {
        const it = &pm.menu.items[idx];
        const row_h: i32 = if (it.is_separator) POPUP_SEPARATOR_HEIGHT else POPUP_ROW_HEIGHT;
        const y_start = y;
        const y_end = y + row_h;

        if (pm.row_count < pm.rows.len) {
            pm.rows[pm.row_count] = .{
                .y_start = y_start,
                .y_end = y_end,
                .item_id = if (it.is_separator or it.has_children or !it.enabled) null else it.id,
            };
            pm.row_count += 1;
        }

        if (it.is_separator) {
            const line_y = y_start + @divTrunc(row_h, 2);
            if (line_y >= 0 and line_y < pm.height) {
                var x: u32 = 0;
                while (x < pm.width) : (x += 1) pixels[@as(u32, @intCast(line_y)) * pm.width + x] = current_config.appearance.popup_separator_color;
            }
        } else {
            const hovered = pm.pointer_y >= y_start and pm.pointer_y < y_end;
            if (hovered and it.enabled) {
                var py: i32 = y_start;
                while (py < y_end and py < pm.height) : (py += 1) {
                    if (py < 0) continue;
                    var x: u32 = 0;
                    while (x < pm.width) : (x += 1) pixels[@as(u32, @intCast(py)) * pm.width + x] = current_config.appearance.popup_hover_color;
                }
            }
            const color = if (it.enabled) current_config.appearance.text_color else current_config.appearance.popup_disabled_color;
            const baseline = y_start + @divTrunc(row_h + bar.font.ascentPx() - bar.font.descentPx(), 2);
            var x0: i64 = POPUP_PADDING_X;
            var ci: usize = 0;
            while (nextUtf8Codepoint(it.label(), &ci)) |cp| {
                x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, color, 0, pm.width);
            }
        }

        y = y_end;
    }

    const pool = try bar.shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const buffer = try pool.createBuffer(0, @intCast(pm.width), @intCast(pm.height), @intCast(stride), .argb8888);
    defer buffer.destroy();
    pm.surface.attach(buffer, 0, 0);
    pm.surface.damageBuffer(0, 0, @intCast(pm.width), @intCast(pm.height));
    pm.surface.commit();
}

const MAX_OUTPUTS = 8;

/// One connected monitor discovered via the registry. `name`/`description`
/// are core wl_output v4 events (already the version this file binds at) —
/// no xdg-output protocol extension needed to get a human-readable connector
/// name like "DP-1". The name arrives asynchronously right after binding;
/// by the time main()'s existing second roundtrip finishes (already done
/// there for wl_seat's capabilities event, for the same reason), every
/// output's name has had a chance to arrive too.
const OutputInfo = struct {
    output: *wl.Output,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,

    fn name(self: *const OutputInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

fn outputListener(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
    switch (event) {
        .name => |n| {
            const s = std.mem.sliceTo(n.name, 0);
            info.name_len = @min(s.len, info.name_buf.len);
            @memcpy(info.name_buf[0..info.name_len], s[0..info.name_len]);
        },
        else => {},
    }
}

/// Globals we collect while walking the registry. Filled in as events
/// arrive, then used once the initial roundtrip finishes.
const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    outputs: [MAX_OUTPUTS]OutputInfo = undefined,
    output_count: usize = 0,
    seat: ?*wl.Seat = null,
    seat_has_pointer: bool = false,
    wm_base: ?*xdg.WmBase = null, // needed for xdg_popup (the DBusMenu context menu surface)
};

/// State for the single bar surface, threaded through the layer_surface
/// configure callback so we know the size to allocate + draw.
const Bar = struct {
    shm: *wl.Shm,
    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    workspaces: *Workspaces,
    weather: *PolledCommand,
    pacman: *PolledCommand,
    volume: *PolledCommand,
    mpris: *PolledCommand,
    tray: *Tray,
    font: *font_mod.Font,
    compositor: *wl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*wl.Seat,
    width: u32 = 0,
    height: u32,
    configured: bool = false,
    click_regions: ClickRegions = .{},
    pointer_x: i32 = -1,
    pointer_over_popup: bool = false,
    last_pointer_serial: u32 = 0,
    drawer_expanded: bool = false, // target state, flipped instantly on click
    drawer_anim: f32 = 0.0, // 0=collapsed..1=expanded, eased toward drawer_expanded each tick
    mpris_scroll_step: i64 = 0,
    mpris_prev_buf: [64]u8 = undefined,
    mpris_prev_len: usize = 0,
    mpris_player_buf: [128]u8 = undefined,
    mpris_player_len: usize = 0,
    popup: ?PopupMenu = null,
};

/// (Re-)applies the layer-shell anchor/size/exclusive-zone/margin from
/// current_config and commits — called once at startup, and again from the
/// SIGUSR1 reload handler whenever `position` or `bar_height` changes. This
/// does NOT block for the resulting configure event (that would stall the
/// whole event loop on a reload) — it just re-issues the requests and
/// commits; layerSurfaceListener's existing .configure handler already
/// updates bar.width/bar.height and redraws whenever the compositor
/// responds, the same as it does for the initial configure and for any
/// compositor-initiated resize, so no separate handling is needed here.
fn applyLayerGeometry(bar: *Bar) void {
    if (std.mem.eql(u8, current_config.appearance.position, "top")) {
        bar.layer_surface.setAnchor(.{ .top = true, .left = true, .right = true });
    } else {
        bar.layer_surface.setAnchor(.{ .bottom = true, .left = true, .right = true });
    }
    bar.layer_surface.setSize(0, current_config.appearance.bar_height);
    bar.layer_surface.setExclusiveZone(@intCast(current_config.appearance.bar_height));
    bar.layer_surface.setMargin(0, MARGIN_SIDE, 0, MARGIN_SIDE);
    bar.surface.commit();
}

/// Redraws every currently-running bar, logging (not propagating) any
/// individual failure — matches every existing single-bar
/// `drawAndCommit(&bar) catch |err| { ... }` call site's error handling,
/// just applied across however many bars are actually running (1, in the
/// default single-monitor case; N when "monitor": "all" is configured)
/// instead of assuming exactly one.
fn drawAllBars(bars: []Bar) void {
    for (bars) |*b| {
        drawAndCommit(b) catch |err| {
            std.debug.print("draw failed: {}\n", .{err});
        };
    }
}

pub fn main() !void {
    resolveConfigPaths();
    current_config = loadConfig();
    writePidfile();

    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app_font = init_font: {
        var buf: [512]u8 = undefined;
        const path_z = fontPathZ(current_config.appearance.font_path, &buf) orelse font_mod.FONT_PATH;
        break :init_font font_mod.Font.init(gpa, path_z, FONT_PIXEL_SIZE) catch |err| blk: {
            // A user-configured font_path that fails to load (bad path, not
            // actually a font file, ...) shouldn't take the whole bar down —
            // fall back to the built-in default, matching every other
            // "never let a bad config value crash the bar" convention here.
            std.debug.print("font: could not load {s}: {} — falling back to {s}\n", .{ path_z, err, font_mod.FONT_PATH });
            break :blk try font_mod.Font.init(gpa, font_mod.FONT_PATH, FONT_PIXEL_SIZE);
        };
    };
    defer app_font.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    setCloexec(display.getFd());

    const registry = try display.getRegistry();

    var globals = Globals{};
    registry.setListener(*Globals, registryListener, &globals);

    // First roundtrip: server sends us the global list, and we bind them
    // (including wl_seat) as we see each one.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    // Second roundtrip: lets the objects we just bound push their own
    // initial state — specifically wl_seat's "capabilities" event, which
    // the server only sends once it's processed our bind request, and that
    // request may not have even reached the server until partway through
    // the first roundtrip's dispatch loop (it's issued reactively, while
    // handling that roundtrip's incoming "global" events).
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = globals.compositor orelse return error.NoCompositor;
    const shm = globals.shm orelse return error.NoShm;
    const layer_shell = globals.layer_shell orelse return error.NoLayerShell;

    // Resolve which output(s) to run a bar surface on from
    // current_config.appearance.monitor: "" = a single bar, compositor picks
    // (today's exact behavior — pass null to get_layer_surface); "all" = one
    // independent bar per currently-connected output; anything else = the
    // one connected output with that name, falling back to "" behavior if no
    // connected output currently has it (renamed/unplugged since it was
    // configured) — never show zero bars over a stale/bad monitor setting,
    // same permissive-fallback spirit as every other config field.
    const monitor_cfg = current_config.appearance.monitor;
    var target_outputs: [MAX_OUTPUTS]?*wl.Output = undefined;
    var target_count: usize = 0;
    if (std.mem.eql(u8, monitor_cfg, "all")) {
        for (globals.outputs[0..globals.output_count]) |*info| {
            target_outputs[target_count] = info.output;
            target_count += 1;
        }
        if (target_count == 0) {
            target_outputs[0] = null; // nothing discovered; fall back to default single bar
            target_count = 1;
        }
    } else if (monitor_cfg.len > 0) {
        var found: ?*wl.Output = null;
        for (globals.outputs[0..globals.output_count]) |*info| {
            if (std.mem.eql(u8, info.name(), monitor_cfg)) {
                found = info.output;
                break;
            }
        }
        target_outputs[0] = found; // null (not found) == compositor-picks, same as "" case
        target_count = 1;
    } else {
        target_outputs[0] = null;
        target_count = 1;
    }

    // Hyprland-specific, matching waybar's "hyprland/workspaces" module.
    // Both IPC sockets live at $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.
    var hypr_sock_dir_buf: [92]u8 = undefined;
    const hypr_sock_dir: ?[]const u8 = blk: {
        const runtime_dir = std.mem.sliceTo(getenv("XDG_RUNTIME_DIR") orelse break :blk null, 0);
        const instance_sig = std.mem.sliceTo(getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse break :blk null, 0);
        break :blk std.fmt.bufPrint(&hypr_sock_dir_buf, "{s}/hypr/{s}", .{ runtime_dir, instance_sig }) catch null;
    };

    var cmd_sock_path_buf: [108]u8 = undefined;
    var workspaces: Workspaces = blk: {
        const empty = Workspaces{ .gpa = gpa, .list = .empty, .sock_path_len = 0 };
        const dir = hypr_sock_dir orelse break :blk empty;
        const cmd_path = std.fmt.bufPrint(&cmd_sock_path_buf, "{s}/.socket.sock", .{dir}) catch break :blk empty;
        break :blk Workspaces.init(gpa, cmd_path) catch empty;
    };
    defer workspaces.deinit();

    var event_sock_path_buf: [108]u8 = undefined;
    const hypr_event_fd: posix.fd_t = if (hypr_sock_dir) |dir| blk: {
        const event_path = std.fmt.bufPrint(&event_sock_path_buf, "{s}/.socket2.sock", .{dir}) catch break :blk -1;
        break :blk connectUnixSocket(event_path) catch -1;
    } else -1;
    defer if (hypr_event_fd >= 0) {
        _ = posix.system.close(hypr_event_fd);
    };

    var weather: PolledCommand = .{};
    startWeatherFetch(&weather);
    var pacman_updates: PolledCommand = .{};
    startPacmanFetch(&pacman_updates);
    var volume: PolledCommand = .{};
    startVolumeFetch(&volume);
    var mpris: PolledCommand = .{};
    startMprisFetch(&mpris);
    var tray = Tray.init(gpa);
    defer tray.deinit();

    // One Bar per target output, sharing every pointer to global/system
    // state (weather, tray, font, workspaces, ...) below — only the fields
    // that are genuinely per-surface (surface handle, click regions,
    // pointer/hover state, drawer animation, popup) differ per instance.
    // Individual surface/layer_surface objects are deliberately not
    // `defer`-destroyed here: this is a long-running daemon whose only exit
    // paths are `std.process.exit(0)` (which skips defers entirely) or a
    // hard error during this very setup, in which case the OS reclaims
    // everything on process exit anyway — matching the original single-bar
    // code's defers, which likewise never actually ran in practice.
    var bars: [MAX_OUTPUTS]Bar = undefined;
    var bar_count: usize = 0;
    for (target_outputs[0..target_count]) |target_output| {
        const surface = compositor.createSurface() catch continue;
        const layer_surface = layer_shell.getLayerSurface(
            surface,
            target_output,
            .top, // layer: show above normal windows
            "simpbar",
        ) catch {
            surface.destroy();
            continue;
        };
        bars[bar_count] = .{
            .shm = shm,
            .surface = surface,
            .layer_surface = layer_surface,
            .workspaces = &workspaces,
            .weather = &weather,
            .pacman = &pacman_updates,
            .volume = &volume,
            .mpris = &mpris,
            .tray = &tray,
            .font = &app_font,
            .compositor = compositor,
            .wm_base = globals.wm_base,
            .seat = globals.seat,
            .height = current_config.appearance.bar_height,
        };
        layer_surface.setListener(*Bar, layerSurfaceListener, &bars[bar_count]);
        bar_count += 1;
    }
    if (bar_count == 0) return error.NoBarSurfaceCreated;

    // Click handling: get a pointer off the seat (if the compositor gave us
    // one) and route button-press events through whichever bar (of possibly
    // several) is currently under it, via a shared BarRouter — see
    // pointerListener's doc comment for why a single wl_pointer object must
    // route to multiple bars rather than each bar getting its own.
    var bar_router = BarRouter{ .bars = bars[0..bar_count] };
    const pointer: ?*wl.Pointer = if (globals.seat) |seat|
        (if (globals.seat_has_pointer) seat.getPointer() catch null else null)
    else
        null;
    defer if (pointer) |p| p.release();
    if (pointer) |p| p.setListener(*BarRouter, pointerListener, &bar_router);

    // Anchor every bar to the configured edge and stretch full width (0 =
    // "as wide as the output"). Reserve the height (+ side margins) so
    // windows don't overlap the bar.
    for (bars[0..bar_count]) |*b| applyLayerGeometry(b);

    // Block until every bar's compositor has sent its first configure
    // event, which is where we learn the actual width to allocate a buffer
    // for.
    while (true) {
        var all_configured = true;
        for (bars[0..bar_count]) |*b| {
            if (!b.configured) all_configured = false;
        }
        if (all_configured) break;
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    const timer_fd = try createIntervalTimer(1);
    const weather_timer_fd = try createIntervalTimer(WEATHER_REFRESH_SECONDS);
    defer _ = posix.system.close(weather_timer_fd);
    defer if (weather.pending_fd >= 0) {
        _ = posix.system.close(weather.pending_fd);
    };
    const pacman_timer_fd = try createIntervalTimer(PACMAN_REFRESH_SECONDS);
    defer _ = posix.system.close(pacman_timer_fd);
    defer if (pacman_updates.pending_fd >= 0) {
        _ = posix.system.close(pacman_updates.pending_fd);
    };
    const volume_timer_fd = try createIntervalTimer(VOLUME_REFRESH_SECONDS);
    defer _ = posix.system.close(volume_timer_fd);
    defer if (volume.pending_fd >= 0) {
        _ = posix.system.close(volume.pending_fd);
    };
    const mpris_timer_fd = try createIntervalTimer(MPRIS_REFRESH_SECONDS);
    defer _ = posix.system.close(mpris_timer_fd);
    defer if (mpris.pending_fd >= 0) {
        _ = posix.system.close(mpris.pending_fd);
    };
    const scroll_timer_fd = try createMsIntervalTimer(SCROLL_INTERVAL_MS);
    defer _ = posix.system.close(scroll_timer_fd);
    const tray_timer_fd = try createIntervalTimer(TRAY_REFRESH_SECONDS);
    defer _ = posix.system.close(tray_timer_fd);
    defer _ = posix.system.close(timer_fd);

    // SIGUSR1 live-reload: block the signal (so it queues instead of using
    // its default terminate disposition) and read it via a signalfd, same
    // multiplexed-in-poll() shape as every timerfd above. A failure here
    // (vanishingly unlikely — signalfd() only fails on fd/memory exhaustion)
    // just means live-reload doesn't work this run; not worth failing
    // startup over.
    var sigusr1_mask = posix.sigemptyset();
    posix.sigaddset(&sigusr1_mask, .USR1);
    posix.sigprocmask(posix.SIG.BLOCK, &sigusr1_mask, null);
    const sigusr1_fd = posix.signalfd(-1, &sigusr1_mask, std.os.linux.SFD.CLOEXEC) catch |err| blk: {
        std.debug.print("signalfd(SIGUSR1) failed, live config reload disabled: {}\n", .{err});
        break :blk -1;
    };
    defer if (sigusr1_fd >= 0) {
        _ = posix.system.close(sigusr1_fd);
    };

    // New modules (Step 3): cpu/ram share one timer; battery/disk/network
    // each get their own; network's "ssid" mode additionally needs a
    // PolledCommand pipe-fd pair like weather/pacman/volume/mpris above.
    // interval_secs is honored where a single config entry unambiguously
    // determines it (disk/battery/network-speed/network-ssid; cpu/ram share
    // one timer, resolved from whichever of the two entries specifies an
    // override first) — NOT for custom scripts' own intervals, which are
    // resolved separately below since there can be several of them.
    const sysstats_interval: i64 = blk: {
        if (findRightEntry(.cpu)) |e| {
            if (e.interval_secs) |s| break :blk @intCast(s);
        }
        if (findRightEntry(.ram)) |e| {
            if (e.interval_secs) |s| break :blk @intCast(s);
        }
        break :blk SYSSTATS_REFRESH_SECONDS;
    };
    const battery_interval: i64 = if (findRightEntry(.battery)) |e|
        (if (e.interval_secs) |s| @intCast(s) else BATTERY_REFRESH_SECONDS)
    else
        BATTERY_REFRESH_SECONDS;
    const disk_interval: i64 = if (findRightEntry(.disk)) |e|
        (if (e.interval_secs) |s| @intCast(s) else DISK_REFRESH_SECONDS)
    else
        DISK_REFRESH_SECONDS;
    const network_entry_interval: ?i64 = if (findRightEntry(.network)) |e|
        (if (e.interval_secs) |s| @intCast(s) else null)
    else
        null;
    const netspeed_interval: i64 = network_entry_interval orelse NET_SPEED_REFRESH_SECONDS;
    const netssid_interval: i64 = network_entry_interval orelse NET_SSID_REFRESH_SECONDS;

    const sysstats_timer_fd = try createIntervalTimer(sysstats_interval);
    defer _ = posix.system.close(sysstats_timer_fd);
    const battery_timer_fd = try createIntervalTimer(battery_interval);
    defer _ = posix.system.close(battery_timer_fd);
    const disk_timer_fd = try createIntervalTimer(disk_interval);
    defer _ = posix.system.close(disk_timer_fd);
    const netspeed_timer_fd = try createIntervalTimer(netspeed_interval);
    defer _ = posix.system.close(netspeed_timer_fd);
    const netssid_timer_fd = try createIntervalTimer(netssid_interval);
    defer _ = posix.system.close(netssid_timer_fd);
    defer if (net_ssid.pending_fd >= 0) {
        _ = posix.system.close(net_ssid.pending_fd);
    };

    findBattery();
    findCpuTempSensor();
    sampleSysStats(); // first sample has no delta yet (cpu_pct stays 0 until the next tick); ram_pct/cpu_temp are valid immediately
    sampleDisk();
    sampleNetSpeed();
    startNetSsidFetch(&net_ssid);

    initCustomScripts();
    var custom_script_timer_fds: [MAX_CUSTOM_SCRIPTS]posix.fd_t = [_]posix.fd_t{-1} ** MAX_CUSTOM_SCRIPTS;
    for (0..custom_script_count) |i| {
        custom_script_timer_fds[i] = createIntervalTimer(custom_script_intervals[i]) catch -1;
        if (custom_script_timer_fds[i] >= 0) startCustomScriptFetch(&custom_scripts[i], customScriptCommand(i));
    }
    defer for (0..MAX_CUSTOM_SCRIPTS) |i| {
        if (custom_script_timer_fds[i] >= 0) _ = posix.system.close(custom_script_timer_fds[i]);
        if (custom_scripts[i].pending_fd >= 0) _ = posix.system.close(custom_scripts[i].pending_fd);
    };

    // Main event loop: multiplex the Wayland display fd (compositor events),
    // a 1s timerfd (clock ticks), and the Hyprland event socket (workspace
    // changes) — a negative fd (Hyprland not running) is simply ignored by
    // poll(). Each redraws the same buffer; more modules later just mean
    // more fds feeding into the same poll() call.
    var poll_fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = hypr_event_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = weather_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // weather.pending_fd, refreshed below
        .{ .fd = pacman_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // pacman_updates.pending_fd
        .{ .fd = volume_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // volume.pending_fd
        .{ .fd = mpris_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // mpris.pending_fd
        .{ .fd = scroll_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // tray.pollFd(), refreshed below
        .{ .fd = tray_timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sigusr1_fd, .events = posix.POLL.IN, .revents = 0 }, // [14]
        .{ .fd = sysstats_timer_fd, .events = posix.POLL.IN, .revents = 0 }, // [15]
        .{ .fd = battery_timer_fd, .events = posix.POLL.IN, .revents = 0 }, // [16]
        .{ .fd = disk_timer_fd, .events = posix.POLL.IN, .revents = 0 }, // [17]
        .{ .fd = netspeed_timer_fd, .events = posix.POLL.IN, .revents = 0 }, // [18]
        .{ .fd = netssid_timer_fd, .events = posix.POLL.IN, .revents = 0 }, // [19]
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [20] net_ssid.pending_fd, refreshed below
        .{ .fd = custom_script_timer_fds[0], .events = posix.POLL.IN, .revents = 0 }, // [21]
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [22] custom_scripts[0].pending_fd, refreshed below
        .{ .fd = custom_script_timer_fds[1], .events = posix.POLL.IN, .revents = 0 }, // [23]
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [24] custom_scripts[1].pending_fd, refreshed below
        .{ .fd = custom_script_timer_fds[2], .events = posix.POLL.IN, .revents = 0 }, // [25]
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [26] custom_scripts[2].pending_fd, refreshed below
        .{ .fd = custom_script_timer_fds[3], .events = posix.POLL.IN, .revents = 0 }, // [27]
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [28] custom_scripts[3].pending_fd, refreshed below
    };
    comptime {
        if (MAX_CUSTOM_SCRIPTS != 4) @compileError("poll_fds' custom-script slots [21..28] are hand-unrolled for MAX_CUSTOM_SCRIPTS == 4; update both if that changes");
    }

    while (true) {
        // Flush any outstanding requests (e.g. from the last commit) before
        // blocking, since dispatch() alone doesn't guarantee a flush.
        _ = display.flush();
        poll_fds[4].fd = weather.pending_fd; // changes across fetch cycles
        poll_fds[6].fd = pacman_updates.pending_fd;
        poll_fds[8].fd = volume.pending_fd;
        poll_fds[10].fd = mpris.pending_fd;
        poll_fds[12].fd = tray.pollFd(); // -1 if the tray failed to set up; poll() ignores it
        poll_fds[20].fd = net_ssid.pending_fd;
        poll_fds[22].fd = custom_scripts[0].pending_fd;
        poll_fds[24].fd = custom_scripts[1].pending_fd;
        poll_fds[26].fd = custom_scripts[2].pending_fd;
        poll_fds[28].fd = custom_scripts[3].pending_fd;

        _ = try posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(timer_fd, std.mem.asBytes(&expirations)) catch {};
            // A child (curl, from a weather fetch) reaching pipe-EOF and
            // becoming reapable via waitpid() aren't perfectly atomic — a
            // waitpid() called right at EOF can still see "not yet exited"
            // (returns 0). Piggyback on this once-a-second tick instead of
            // reaping exactly at EOF, so it's retried until it succeeds.
            reapChildren();
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[2].revents & posix.POLL.IN != 0) {
            // Don't bother parsing which event(s) arrived — just drain
            // what's queued and re-fetch the full workspace list. Simpler
            // than tracking Hyprland's various workspace event payloads,
            // and cheap enough for something that only fires on user action.
            var drain_buf: [4096]u8 = undefined;
            _ = posix.read(hypr_event_fd, &drain_buf) catch {};
            workspaces.refresh() catch |err| {
                std.debug.print("workspaces refresh failed: {}\n", .{err});
            };
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[3].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(weather_timer_fd, std.mem.asBytes(&expirations)) catch {};
            startWeatherFetch(&weather);
        }
        // POLLHUP (not just POLLIN) needs to trigger a read attempt too:
        // once a pipe is fully drained and its write end has closed, Linux
        // reports HUP-only on later poll() calls — the POLLIN|read()==0
        // transition only appears on the one call where that edge happens,
        // which we can miss if the last chunk of real data arrived in an
        // earlier, separate POLLIN wakeup. (Same reasoning applies to the
        // pacman/volume blocks below.)
        if (poll_fds[4].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (weather.onReadable()) {
                _ = posix.system.close(weather.pending_fd);
                weather.pending_fd = -1;
                // Not reaped here — see the once-a-second tick above.
                drawAllBars(bars[0..bar_count]);
            }
        }
        if (poll_fds[5].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(pacman_timer_fd, std.mem.asBytes(&expirations)) catch {};
            startPacmanFetch(&pacman_updates);
        }
        if (poll_fds[6].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (pacman_updates.onReadable()) {
                _ = posix.system.close(pacman_updates.pending_fd);
                pacman_updates.pending_fd = -1;
                drawAllBars(bars[0..bar_count]);
            }
        }
        if (poll_fds[7].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(volume_timer_fd, std.mem.asBytes(&expirations)) catch {};
            startVolumeFetch(&volume);
        }
        if (poll_fds[8].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (volume.onReadable()) {
                _ = posix.system.close(volume.pending_fd);
                volume.pending_fd = -1;
                drawAllBars(bars[0..bar_count]);
            }
        }
        if (poll_fds[9].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(mpris_timer_fd, std.mem.asBytes(&expirations)) catch {};
            startMprisFetch(&mpris);
        }
        if (poll_fds[10].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (mpris.onReadable()) {
                _ = posix.system.close(mpris.pending_fd);
                mpris.pending_fd = -1;
                drawAllBars(bars[0..bar_count]);
            }
        }
        if (poll_fds[11].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(scroll_timer_fd, std.mem.asBytes(&expirations)) catch {};
            // Only bother animating (and redrawing) when there's actually
            // something to show — no point burning a redraw every 60ms
            // while nothing's playing and the drawer's fade isn't mid-flight.
            // mpris_scroll_step/drawer_anim are per-bar state (each bar's
            // own scroll position/fade progresses independently), so this
            // loops over every bar rather than updating one shared value.
            for (bars[0..bar_count]) |*b| {
                var needs_redraw = false;
                if (b.mpris.text().len > 0) {
                    b.mpris_scroll_step += SCROLL_STEP_PX;
                    needs_redraw = true;
                }
                const drawer_target: f32 = if (b.drawer_expanded) 1.0 else 0.0;
                if (b.drawer_anim != drawer_target) {
                    b.drawer_anim = if (b.drawer_anim < drawer_target)
                        @min(drawer_target, b.drawer_anim + DRAWER_ANIM_STEP)
                    else
                        @max(drawer_target, b.drawer_anim - DRAWER_ANIM_STEP);
                    needs_redraw = true;
                }
                if (needs_redraw) {
                    drawAndCommit(b) catch |err| {
                        std.debug.print("draw failed: {}\n", .{err});
                    };
                }
            }
        }
        if (poll_fds[12].revents & posix.POLL.IN != 0) {
            tray.onReadable(); // shared: one D-Bus connection/icon set for every bar
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[13].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(tray_timer_fd, std.mem.asBytes(&expirations)) catch {};
            tray.refreshOne();
            // drawer_anim, not drawer_expanded — icons are still visible
            // (fading) partway through a collapse even once drawer_expanded
            // has already flipped back to false. Per-bar: each bar's own
            // drawer independently decides whether it needs a redraw.
            for (bars[0..bar_count]) |*b| {
                if (b.drawer_anim > 0.0) {
                    drawAndCommit(b) catch |err| {
                        std.debug.print("draw failed: {}\n", .{err});
                    };
                }
            }
        }
        if (poll_fds[14].revents & posix.POLL.IN != 0) {
            var siginfo: std.os.linux.signalfd_siginfo = undefined;
            _ = posix.read(sigusr1_fd, std.mem.asBytes(&siginfo)) catch {};
            // Unlike the startup load, a reload NEVER falls back to
            // defaultConfig() — a config.json that's momentarily missing or
            // malformed (mid-edit, a bad hand-edit, a GUI bug) should leave
            // the bar exactly as it was, not silently discard the user's
            // working config.
            if (loadConfigFromFile()) |cfg| {
                const old_font_path = current_config.appearance.font_path;
                const font_changed = !std.mem.eql(u8, old_font_path, cfg.appearance.font_path);
                const old_position = current_config.appearance.position;
                const old_bar_height = current_config.appearance.bar_height;
                const geometry_changed = !std.mem.eql(u8, old_position, cfg.appearance.position) or
                    old_bar_height != cfg.appearance.bar_height;
                current_config = cfg;
                std.debug.print("config: reloaded {s}\n", .{config_json_path});

                // Closes a previously-known gap: bar_height (and now
                // position) used to only take effect on the next bar
                // restart. Re-issuing these layer-shell requests + a commit
                // is cheap and async — see applyLayerGeometry's doc comment
                // for why this doesn't need to block on the resulting
                // configure event here.
                if (geometry_changed) {
                    for (bars[0..bar_count]) |*b| applyLayerGeometry(b);
                }

                // Try loading the NEW font before touching the old one — if
                // the configured path is bad (missing file, not actually a
                // font, ...) this leaves app_font exactly as it was rather
                // than tearing down a working font for a broken one. Note
                // current_config.appearance.font_path can end up saying a
                // path that isn't actually what's rendering if this fails —
                // an accepted, minor inconsistency in exchange for never
                // breaking bar text/icons on a bad font selection.
                if (font_changed) {
                    var font_buf: [512]u8 = undefined;
                    if (fontPathZ(current_config.appearance.font_path, &font_buf)) |path_z| {
                        if (font_mod.Font.init(gpa, path_z, FONT_PIXEL_SIZE)) |new_font| {
                            app_font.deinit();
                            app_font = new_font;
                        } else |err| {
                            std.debug.print("font: could not load {s}: {} — keeping current font\n", .{ path_z, err });
                        }
                    } else {
                        std.debug.print("font: path too long, keeping current font\n", .{});
                    }
                }

                // Custom-script commands/intervals live in stable buffers
                // separate from current_config (see initCustomScripts' doc
                // comment) — a reload must re-resolve them too, or an
                // edited/added/removed custom script would only take effect
                // on the next bar restart. Unconditionally reset every slot
                // (simpler than diffing what changed, and just as correct
                // since this only runs on an explicit user save, not every
                // frame): abandon any in-flight fetch, clear stale text,
                // recreate each slot's timerfd at its (possibly new)
                // interval, and kick off a fresh fetch for whatever's now
                // configured.
                initCustomScripts();
                for (0..MAX_CUSTOM_SCRIPTS) |i| {
                    if (custom_scripts[i].pending_fd >= 0) {
                        _ = posix.system.close(custom_scripts[i].pending_fd);
                        custom_scripts[i].pending_fd = -1;
                    }
                    custom_scripts[i].text_len = 0;
                    custom_scripts[i].read_len = 0;

                    if (custom_script_timer_fds[i] >= 0) _ = posix.system.close(custom_script_timer_fds[i]);
                    custom_script_timer_fds[i] = -1;
                    if (i < custom_script_count) {
                        custom_script_timer_fds[i] = createIntervalTimer(custom_script_intervals[i]) catch -1;
                        if (custom_script_timer_fds[i] >= 0) startCustomScriptFetch(&custom_scripts[i], customScriptCommand(i));
                    }
                    poll_fds[21 + i * 2].fd = custom_script_timer_fds[i];
                }

                drawAllBars(bars[0..bar_count]);
            } else {
                std.debug.print("config: reload failed, keeping previous config\n", .{});
            }
        }
        if (poll_fds[15].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(sysstats_timer_fd, std.mem.asBytes(&expirations)) catch {};
            sampleSysStats();
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[16].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(battery_timer_fd, std.mem.asBytes(&expirations)) catch {};
            sampleBattery();
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[17].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(disk_timer_fd, std.mem.asBytes(&expirations)) catch {};
            sampleDisk();
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[18].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(netspeed_timer_fd, std.mem.asBytes(&expirations)) catch {};
            sampleNetSpeed();
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[19].revents & posix.POLL.IN != 0) {
            var expirations: u64 = undefined;
            _ = posix.read(netssid_timer_fd, std.mem.asBytes(&expirations)) catch {};
            startNetSsidFetch(&net_ssid);
        }
        if (poll_fds[20].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (net_ssid.onReadable()) {
                _ = posix.system.close(net_ssid.pending_fd);
                net_ssid.pending_fd = -1;
                drawAllBars(bars[0..bar_count]);
            }
        }
        for (0..MAX_CUSTOM_SCRIPTS) |i| {
            const timer_slot = 21 + i * 2;
            const pending_slot = 22 + i * 2;
            if (poll_fds[timer_slot].revents & posix.POLL.IN != 0) {
                var expirations: u64 = undefined;
                _ = posix.read(custom_script_timer_fds[i], std.mem.asBytes(&expirations)) catch {};
                if (i < custom_script_count) startCustomScriptFetch(&custom_scripts[i], customScriptCommand(i));
            }
            if (poll_fds[pending_slot].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                if (custom_scripts[i].onReadable()) {
                    _ = posix.system.close(custom_scripts[i].pending_fd);
                    custom_scripts[i].pending_fd = -1;
                    drawAllBars(bars[0..bar_count]);
                }
            }
        }
    }
}

/// Creates a timerfd that fires every `seconds`, forever.
fn createIntervalTimer(seconds: i64) !posix.fd_t {
    return createMsIntervalTimer(seconds * 1000);
}

/// Creates a timerfd that fires every `ms` milliseconds, forever — the mpris
/// scroll animation needs sub-second granularity the seconds-only version
/// above can't express.
fn createMsIntervalTimer(ms: i64) !posix.fd_t {
    const raw_fd = std.c.timerfd_create(.REALTIME, @intCast(CLOEXEC));
    if (raw_fd < 0) return error.TimerCreateFailed;
    const fd: posix.fd_t = @intCast(raw_fd);

    const interval = std.os.linux.timespec{
        .sec = @divTrunc(ms, 1000),
        .nsec = @mod(ms, 1000) * 1_000_000,
    };
    const spec = std.os.linux.itimerspec{ .it_interval = interval, .it_value = interval };
    if (std.c.timerfd_settime(fd, 0, &spec, null) != 0) return error.TimerSetFailed;

    return fd;
}

/// Reaps any finished detached children (weather's `curl` fetches; the
/// double-forked launcher grandchildren reparent to init and never need
/// this) so they don't pile up as zombies.
fn reapChildren() void {
    while (true) {
        var status: c_int = undefined;
        const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        if (pid <= 0) break;
    }
}

/// Runs a command on a timer and captures its stdout over a pipe, without
/// blocking the main loop — `pending_fd` (once set) is just another fd in
/// the poll() set, read from only when readable. Shared by custom/weather
/// and custom/pacman (and wireplumber's polled `wpctl` read), which only
/// differ in what they exec and how often.
const PolledCommand = struct {
    text_buf: [64]u8 = undefined,
    text_len: usize = 0,
    read_buf: [256]u8 = undefined,
    read_len: usize = 0,
    pending_fd: posix.fd_t = -1,

    fn text(self: *const PolledCommand) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// `path`/`argv` describe the exec — e.g. `/usr/bin/env` +
    /// `{"env","curl","-s",url,null}` (PATH search via env, since execvp
    /// isn't bound here), or `/bin/sh` + `{"sh","-c",script,null}` for
    /// anything needing shell features like a pipe.
    fn startFetch(self: *PolledCommand, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
        if (self.pending_fd >= 0) return; // previous fetch still in flight
        self.read_len = 0;

        var pipe_fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return;
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];
        // read_fd is what persists (as pending_fd) across poll iterations
        // until the fetch completes — CLOEXEC so a launcher click during
        // that window doesn't leak it into the spawned app.
        setCloexec(read_fd);

        const pid = libc_proc.fork();
        if (pid < 0) {
            _ = posix.system.close(read_fd);
            _ = posix.system.close(write_fd);
            return;
        }
        if (pid == 0) {
            _ = std.c.dup2(write_fd, 1);
            _ = posix.system.close(write_fd);
            _ = posix.system.close(read_fd);
            _ = std.c.execve(path, argv, std.c.environ);
            std.c._exit(127);
        }
        _ = posix.system.close(write_fd);
        self.pending_fd = read_fd;
    }

    /// Call when poll() reports `pending_fd` readable. Returns true once
    /// the fetch is complete (EOF) — caller should then close `pending_fd`
    /// and reset it to -1. (Reaping the child happens on the 1s clock tick,
    /// not here — see the comment at that call site.)
    fn onReadable(self: *PolledCommand) bool {
        var chunk: [256]u8 = undefined;
        const n = posix.read(self.pending_fd, &chunk) catch return true;
        if (n == 0) {
            const trimmed = std.mem.trim(u8, self.read_buf[0..self.read_len], " \t\r\n");
            self.text_len = @min(trimmed.len, self.text_buf.len);
            @memcpy(self.text_buf[0..self.text_len], trimmed[0..self.text_len]);
            return true;
        }
        const copy_len = @min(n, self.read_buf.len - self.read_len);
        @memcpy(self.read_buf[self.read_len..][0..copy_len], chunk[0..copy_len]);
        self.read_len += copy_len;
        return false;
    }
};

// --- new modules: cpu/ram/battery/disk/network/custom-script --------------
//
// Unlike weather/pacman/volume/mpris (state lives on Bar, passed as explicit
// params down to drawRightGroup), these six follow current_config's own
// precedent instead: package-level vars, read directly by drawRightGroup's
// switch cases. Threading six more parameters through drawAndCommit's and
// drawRightGroup's signatures would just be boilerplate — these modules'
// "current value" is exactly the same kind of global, rarely-changing,
// read-only-during-a-frame state current_config already is.

const SYSSTATS_REFRESH_SECONDS: i64 = 2;
const BATTERY_REFRESH_SECONDS: i64 = 15;
const DISK_REFRESH_SECONDS: i64 = 30;
const NET_SPEED_REFRESH_SECONDS: i64 = 5;
const NET_SSID_REFRESH_SECONDS: i64 = 10;
const MAX_CUSTOM_SCRIPTS = 4;
const CUSTOM_SCRIPT_DEFAULT_INTERVAL_SECONDS: i64 = 10;

/// Looks up the first ModuleEntry of `kind` in current_config.modules.right,
/// if any — lets the new direct-read modules (disk/network/cpu/ram) pick up
/// user-configured settings (path/mode/interval_secs) without those needing
/// to be threaded through the timer-setup call chain in main().
fn findRightEntry(kind: ModuleKind) ?ModuleEntry {
    for (current_config.modules.right) |e| {
        if (e.kind == kind) return e;
    }
    return null;
}

/// Reads up to buf.len bytes of a small /proc or /sys pseudo-file directly
/// into a caller-supplied fixed buffer — no allocation, for the tiny
/// single-read files these modules need (readFileAlloc's arena round-trip
/// would be overkill for a one-line file read every couple seconds).
fn readSmallFile(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return null;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    const n = posix.read(fd, buf) catch return null;
    return buf[0..n];
}

// --- CPU + RAM (one shared timer; both are direct /proc reads) ---

var sys_stats: SysStats = .{};

const SysStats = struct {
    have_prev: bool = false,
    prev_total: u64 = 0,
    prev_idle: u64 = 0,
    cpu_pct: u32 = 0,
    ram_pct: u32 = 0,
};

fn sampleSysStats() void {
    sampleCpu();
    sampleRam();
    sampleCpuTemp();
}

/// Utilization since the LAST sample (not since boot) — needs one persisted
/// previous reading, so the first call after startup always reports 0%
/// (have_prev is still false) until the second tick has something to diff
/// against. Parses /proc/stat's "cpu  <user> <nice> <system> <idle>
/// <iowait> <irq> <softirq> [steal guest guest_nice]" line — fields beyond
/// idle/iowait all count toward "total" the same as the standard
/// 100*(1-idle/total) utilization formula.
fn sampleCpu() void {
    var buf: [512]u8 = undefined;
    const text = readSmallFile("/proc/stat", &buf) orelse return;
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..line_end];
    if (!std.mem.startsWith(u8, line, "cpu ")) return;

    var fields: [10]u64 = [_]u64{0} ** 10;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
    while (it.next()) |tok| {
        if (count >= fields.len) break;
        fields[count] = std.fmt.parseInt(u64, tok, 10) catch 0;
        count += 1;
    }
    if (count < 4) return;

    const idle = fields[3] + (if (count > 4) fields[4] else 0);
    var total: u64 = 0;
    for (fields[0..count]) |v| total += v;

    if (sys_stats.have_prev) {
        const total_delta = total -% sys_stats.prev_total;
        const idle_delta = idle -% sys_stats.prev_idle;
        if (total_delta > 0) {
            const used_delta = if (idle_delta > total_delta) 0 else total_delta - idle_delta;
            sys_stats.cpu_pct = @intCast(@min(100, used_delta * 100 / total_delta));
        }
    }
    sys_stats.prev_total = total;
    sys_stats.prev_idle = idle;
    sys_stats.have_prev = true;
}

fn sampleRam() void {
    var buf: [4096]u8 = undefined;
    const text = readSmallFile("/proc/meminfo", &buf) orelse return;
    const total = parseMeminfoField(text, "MemTotal:") orelse return;
    const avail = parseMeminfoField(text, "MemAvailable:") orelse return;
    if (total == 0) return;
    const used = if (avail > total) 0 else total - avail;
    sys_stats.ram_pct = @intCast(@min(100, used * 100 / total));
}

/// Scans `text` for a "<key>   <number> kB" line (/proc/meminfo's format)
/// and returns the number — hand-rolled in the same substring-scan style as
/// extractFirstId/parseVolumePercent above.
fn parseMeminfoField(text: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, text, key) orelse return null;
    var i = pos + key.len;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, text[start..i], 10) catch null;
}

// --- Battery ---

var battery_state: BatteryState = .{};

const BatteryState = struct {
    found: bool = false,
    scanned: bool = false,
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,
    capacity: u32 = 0,
    charging: bool = false,

    fn path(self: *const BatteryState) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

// Directory scanning has no existing precedent in this file (config/pidfile
// I/O only ever opens a known path directly) — hand-bound the same way
// libc_sock/libc_time/libc_proc above bind whatever libc call this codebase
// needs that isn't exposed by std.c/std.posix directly. Dirent matches
// glibc's 64-bit struct dirent64 layout on Linux x86_64.
const libc_dir = struct {
    const DIR = opaque {};
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*LibcDirent;
    extern "c" fn closedir(dir: *DIR) c_int;
};

const LibcDirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

/// Scans /sys/class/power_supply once for a BAT* entry — its name isn't
/// always "BAT0" (BAT1, BATC, etc. all appear on real hardware) — and caches
/// the path. If none is found (a desktop machine), battery_state.found stays
/// false forever and the battery module quietly draws nothing when enabled,
/// same "quietly absent" behavior weather/pacman already have on failure,
/// rather than rescanning every tick.
fn findBattery() void {
    battery_state.scanned = true;
    const dir = libc_dir.opendir("/sys/class/power_supply") orelse return;
    defer _ = libc_dir.closedir(dir);
    while (libc_dir.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.d_name, 0);
        if (!std.mem.startsWith(u8, name, "BAT")) continue;
        const p = std.fmt.bufPrint(&battery_state.path_buf, "/sys/class/power_supply/{s}", .{name}) catch return;
        battery_state.path_len = p.len;
        battery_state.found = true;
        return;
    }
}

fn sampleBattery() void {
    if (!battery_state.scanned) findBattery();
    if (!battery_state.found) return;

    var cap_path_buf: [128]u8 = undefined;
    const cap_path = std.fmt.bufPrintZ(&cap_path_buf, "{s}/capacity", .{battery_state.path()}) catch return;
    var cap_text_buf: [16]u8 = undefined;
    if (readSmallFile(cap_path, &cap_text_buf)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        battery_state.capacity = std.fmt.parseInt(u32, trimmed, 10) catch battery_state.capacity;
    }

    var status_path_buf: [128]u8 = undefined;
    const status_path = std.fmt.bufPrintZ(&status_path_buf, "{s}/status", .{battery_state.path()}) catch return;
    var status_text_buf: [32]u8 = undefined;
    if (readSmallFile(status_path, &status_text_buf)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        battery_state.charging = std.mem.eql(u8, trimmed, "Charging") or std.mem.eql(u8, trimmed, "Full");
    }
}

// --- CPU temperature (hwmon) ---
//
// Deliberately NOT /sys/class/thermal/thermal_zone* — confirmed via direct
// testing that this system has zero thermal zones registered there at all,
// despite having a perfectly good sensor. hwmon is what `sensors` and every
// real system monitor actually reads, so that's what this uses too.

var cpu_temp_state: CpuTempState = .{};

const CpuTempState = struct {
    found: bool = false,
    scanned: bool = false,
    // Full path straight to the chosen tempN_input file (unlike
    // battery_state.path(), which is a directory other paths get appended
    // to) — this is already the file to read, nothing more to build.
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,
    millidegrees_c: i32 = 0,

    fn path(self: *const CpuTempState) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Scans /sys/class/hwmon once for a device whose driver `name` is a known
/// CPU-temp sensor ("k10temp" AMD, "coretemp" Intel — deliberately narrow;
/// this machine also has "nvme" and "amdgpu" hwmon devices that must NOT
/// match). Within that device, prefers whichever tempN_input has a label of
/// "Tctl", "Tdie", or "Package id 0" — the conventional "the" CPU
/// temperature reading (confirmed on this machine: hwmon3 is k10temp,
/// temp1_input=41375 with temp1_label="Tctl", i.e. 41.375°C) — falling back
/// to the first temp*_input found with no label check if none of those
/// labels turn up. If no matching hwmon device exists at all (older driver,
/// unsupported CPU), cpu_temp_state.found stays false forever and the
/// module quietly draws nothing when enabled, same "quietly absent"
/// behavior battery/network-ssid already have on missing hardware, rather
/// than rescanning every tick.
fn findCpuTempSensor() void {
    cpu_temp_state.scanned = true;
    const dir = libc_dir.opendir("/sys/class/hwmon") orelse return;
    defer _ = libc_dir.closedir(dir);
    while (libc_dir.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.d_name, 0);
        if (!std.mem.startsWith(u8, name, "hwmon")) continue;

        var name_path_buf: [96]u8 = undefined;
        const name_path = std.fmt.bufPrintZ(&name_path_buf, "/sys/class/hwmon/{s}/name", .{name}) catch continue;
        var driver_buf: [32]u8 = undefined;
        const driver_raw = readSmallFile(name_path, &driver_buf) orelse continue;
        const driver = std.mem.trim(u8, driver_raw, " \t\r\n");
        if (!std.mem.eql(u8, driver, "k10temp") and !std.mem.eql(u8, driver, "coretemp")) continue;

        var fallback_buf: [96]u8 = undefined;
        var fallback_len: usize = 0;
        var n: usize = 1;
        while (n <= 8) : (n += 1) {
            var input_path_buf: [96]u8 = undefined;
            const input_path = std.fmt.bufPrintZ(&input_path_buf, "/sys/class/hwmon/{s}/temp{d}_input", .{ name, n }) catch break;
            var label_path_buf: [96]u8 = undefined;
            const label_path = std.fmt.bufPrintZ(&label_path_buf, "/sys/class/hwmon/{s}/temp{d}_label", .{ name, n }) catch break;
            var label_buf: [32]u8 = undefined;
            const label_raw = readSmallFile(label_path, &label_buf);

            if (fallback_len == 0) {
                // First temp*_input seen at all for this device, regardless
                // of label (or lack of one) — the ultimate fallback if no
                // preferred label ever turns up below.
                fallback_len = @min(input_path.len, fallback_buf.len);
                @memcpy(fallback_buf[0..fallback_len], input_path[0..fallback_len]);
            }
            if (label_raw) |lr| {
                const label = std.mem.trim(u8, lr, " \t\r\n");
                if (std.mem.eql(u8, label, "Tctl") or std.mem.eql(u8, label, "Tdie") or std.mem.eql(u8, label, "Package id 0")) {
                    cpu_temp_state.path_len = @min(input_path.len, cpu_temp_state.path_buf.len);
                    @memcpy(cpu_temp_state.path_buf[0..cpu_temp_state.path_len], input_path[0..cpu_temp_state.path_len]);
                    cpu_temp_state.found = true;
                    return;
                }
            }
        }
        if (fallback_len > 0) {
            cpu_temp_state.path_len = fallback_len;
            @memcpy(cpu_temp_state.path_buf[0..fallback_len], fallback_buf[0..fallback_len]);
            cpu_temp_state.found = true;
            return;
        }
    }
}

fn sampleCpuTemp() void {
    if (!cpu_temp_state.scanned) findCpuTempSensor();
    if (!cpu_temp_state.found) return;
    var path_buf: [96:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{cpu_temp_state.path()}) catch return;
    var text_buf: [16]u8 = undefined;
    if (readSmallFile(path_z, &text_buf)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        cpu_temp_state.millidegrees_c = std.fmt.parseInt(i32, trimmed, 10) catch cpu_temp_state.millidegrees_c;
    }
}

// --- Disk usage ---

var disk_pct: u32 = 0;

// Not exposed by std.c/std.posix in this Zig version — hand-bound the same
// way the rest of this section binds libc calls that aren't. Statvfs
// mirrors glibc's real struct statvfs layout on Linux x86_64 (including the
// trailing __f_spare reserved words) so statvfs() doesn't write past the
// end of a too-small struct.
const libc_fs = struct {
    extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;
};

const Statvfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    f_spare: [6]i32,
};

/// Samples disk usage for the configured `.disk` module's `path` (default
/// "/" if unset, or if no `.disk` entry is configured at all).
fn sampleDisk() void {
    const path = if (findRightEntry(.disk)) |e| (e.path orelse "/") else "/";
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
    var stat: Statvfs = undefined;
    if (libc_fs.statvfs(path_z.ptr, &stat) != 0) return;
    if (stat.f_blocks == 0) return;
    const used = stat.f_blocks - stat.f_bfree;
    disk_pct = @intCast(@min(100, used * 100 / stat.f_blocks));
}

// --- Network (two modes: direct-read "speed", subprocess "ssid") ---
//
// Both mechanisms always run regardless of which mode is currently
// configured — cheaper than teaching a config reload to tear down/rebuild
// timerfds when `mode` changes, and both are individually cheap (one /proc
// read, one occasional nmcli call). drawRightGroup just picks which
// precomputed value to show based on entry.mode, read fresh every frame.

var net_speed_state: NetSpeedState = .{};
var net_ssid: PolledCommand = .{};

const NetSpeedState = struct {
    have_prev: bool = false,
    prev_rx: u64 = 0,
    prev_tx: u64 = 0,
    prev_time: i64 = 0,
    text_buf: [24]u8 = undefined,
    text_len: usize = 0,

    fn text(self: *const NetSpeedState) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// Sums rx+tx bytes across every /proc/net/dev interface except loopback,
/// and turns the delta since the last sample into a bytes/sec rate. Skips
/// the 8 fields between an interface's rx-bytes and tx-bytes columns
/// (packets/errs/drop/fifo/frame/compressed/multicast) per /proc/net/dev's
/// documented column layout.
fn sampleNetSpeed() void {
    var buf: [4096]u8 = undefined;
    const text = readSmallFile("/proc/net/dev", &buf) orelse return;

    var rx_total: u64 = 0;
    var tx_total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface = std.mem.trim(u8, line[0..colon], " \t");
        if (iface.len == 0 or std.mem.eql(u8, iface, "lo")) continue;

        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx_bytes = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        // Receive side after rx_bytes: packets, errs, drop, fifo, frame,
        // compressed, multicast (7 columns) — tx_bytes is the 8th token
        // after rx_bytes (verified against this machine's real
        // /proc/net/dev: field 9 overall == tx_bytes, field 8 == multicast).
        var skipped: usize = 0;
        var tx_bytes: u64 = 0;
        var found_tx = false;
        while (fields.next()) |tok| {
            skipped += 1;
            if (skipped == 8) {
                tx_bytes = std.fmt.parseInt(u64, tok, 10) catch 0;
                found_tx = true;
                break;
            }
        }
        if (!found_tx) continue;
        rx_total += rx_bytes;
        tx_total += tx_bytes;
    }

    const now = libc_time.time(null);
    if (net_speed_state.have_prev) {
        const dt = now - net_speed_state.prev_time;
        if (dt > 0) {
            const rx_delta = rx_total -% net_speed_state.prev_rx;
            const tx_delta = tx_total -% net_speed_state.prev_tx;
            const bytes_per_sec = (rx_delta + tx_delta) / @as(u64, @intCast(dt));
            const label = formatByteRate(bytes_per_sec, &net_speed_state.text_buf);
            net_speed_state.text_len = label.len;
        }
    }
    net_speed_state.prev_rx = rx_total;
    net_speed_state.prev_tx = tx_total;
    net_speed_state.prev_time = now;
    net_speed_state.have_prev = true;
}

/// Formats a bytes/sec rate as "N KB/s" below 1MB/s, "N.N MB/s" above.
fn formatByteRate(bytes_per_sec: u64, buf: []u8) []const u8 {
    if (bytes_per_sec >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes_per_sec)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{mb}) catch "";
    }
    const kb = bytes_per_sec / 1024;
    return std.fmt.bufPrint(buf, "{d} KB/s", .{kb}) catch "";
}

fn startNetSsidFetch(cmd: *PolledCommand) void {
    var argv = [_:null]?[*:0]const u8{ "env", "nmcli", "-t", "-f", "active,ssid", "dev", "wifi", null };
    cmd.startFetch("/usr/bin/env", &argv);
}

/// Parses `nmcli -t -f active,ssid dev wifi`'s output (one "yes:SSID" or
/// "no:SSID" line per visible network) for the active connection's SSID. If
/// nmcli isn't installed, execve inside startFetch's forked child fails
/// (exits 127) and this pipeline just never produces any text — same silent
/// degradation weather/pacman already have when their command is missing;
/// install.sh doesn't guarantee NetworkManager is what's installed.
fn parseSsid(raw: []const u8, buf: []u8) []const u8 {
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "yes:")) continue;
        const ssid = line[4..];
        const len = @min(ssid.len, buf.len);
        @memcpy(buf[0..len], ssid[0..len]);
        return buf[0..len];
    }
    return "";
}

// --- Custom scripts (up to MAX_CUSTOM_SCRIPTS, each its own PolledCommand) ---
//
// Which commands run and at what interval is resolved from current_config
// via initCustomScripts, copied into stable buffers here, decoupled from
// config_arena. Called once at startup and again on every successful SIGUSR1
// reload (see that branch in main()'s event loop, which also recreates each
// slot's timerfd and kicks off a fresh fetch) — so adding, removing, or
// editing a custom script's command/interval takes effect live, same as
// every other module. bar_height is the one appearance field that still
// needs a bar restart (see main()'s comment on that), not this.

var custom_scripts: [MAX_CUSTOM_SCRIPTS]PolledCommand = [_]PolledCommand{.{}} ** MAX_CUSTOM_SCRIPTS;
var custom_script_commands: [MAX_CUSTOM_SCRIPTS][256]u8 = undefined;
var custom_script_command_lens: [MAX_CUSTOM_SCRIPTS]usize = [_]usize{0} ** MAX_CUSTOM_SCRIPTS;
var custom_script_intervals: [MAX_CUSTOM_SCRIPTS]i64 = [_]i64{CUSTOM_SCRIPT_DEFAULT_INTERVAL_SECONDS} ** MAX_CUSTOM_SCRIPTS;
var custom_script_count: usize = 0;

fn customScriptCommand(index: usize) []const u8 {
    return custom_script_commands[index][0..custom_script_command_lens[index]];
}

fn initCustomScripts() void {
    custom_script_count = 0;
    for (current_config.modules.right) |entry| {
        if (entry.kind != .custom_script) continue;
        if (custom_script_count >= MAX_CUSTOM_SCRIPTS) {
            std.debug.print("config: more than {d} custom_script entries, ignoring the rest\n", .{MAX_CUSTOM_SCRIPTS});
            break;
        }
        const command = entry.command orelse continue;
        const idx = custom_script_count;
        const len = @min(command.len, custom_script_commands[idx].len);
        @memcpy(custom_script_commands[idx][0..len], command[0..len]);
        custom_script_command_lens[idx] = len;
        custom_script_intervals[idx] = if (entry.interval_secs) |s| @intCast(s) else CUSTOM_SCRIPT_DEFAULT_INTERVAL_SECONDS;
        custom_script_count += 1;
    }
}

fn startCustomScriptFetch(cmd: *PolledCommand, command: []const u8) void {
    var buf: [256]u8 = undefined;
    if (command.len >= buf.len) return;
    @memcpy(buf[0..command.len], command);
    buf[command.len] = 0;
    const command_z: [:0]const u8 = buf[0..command.len :0];
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", command_z.ptr, null };
    cmd.startFetch("/bin/sh", &argv);
}

const WEATHER_URL = "https://wttr.in/?format=1";
const WEATHER_REFRESH_SECONDS: i64 = 1200; // matches "interval": 1200 in ~/.config/waybar/config
const PACMAN_REFRESH_SECONDS: i64 = 3600; // matches custom/pacman's "interval": 3600
const VOLUME_REFRESH_SECONDS: i64 = 5; // wireplumber has no interval (event-driven); polled here instead
const MPRIS_REFRESH_SECONDS: i64 = 2; // mpris has no interval either (also event-driven); polled here instead
const SCROLL_INTERVAL_MS: i64 = 60; // mpris ticker animation tick, shared with the drawer fade below
const SCROLL_STEP_PX: i64 = 1; // ...and how far it advances per tick (~17px/s)
const DRAWER_ANIM_STEP: f32 = 0.25; // fraction of the fade per SCROLL_INTERVAL_MS tick (~240ms full fade)

fn startWeatherFetch(cmd: *PolledCommand) void {
    // Routed through /usr/bin/env for PATH search — no execvp binding here.
    var argv = [_:null]?[*:0]const u8{ "env", "curl", "-s", WEATHER_URL, null };
    cmd.startFetch("/usr/bin/env", &argv);
}

fn startPacmanFetch(cmd: *PolledCommand) void {
    // Needs a real shell for the pipe (checkupdates | wc -l).
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", "checkupdates | wc -l", null };
    cmd.startFetch("/bin/sh", &argv);
}

fn startVolumeFetch(cmd: *PolledCommand) void {
    var argv = [_:null]?[*:0]const u8{ "env", "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@", null };
    cmd.startFetch("/usr/bin/env", &argv);
}

// Finds the first playerctl-visible player that's actually Playing or
// Paused and prints "PLAYER|STATUS|ARTIST - TITLE" (the player name is
// used to target play/pause/prev/next clicks at this exact player via
// spawnPlayerctlCommand, not just for display). Deliberately not filtered
// by player name (~/.config/waybar/config's old "mpris" module ignored
// "firefox" entirely, which also hides every Firefox-family browser tab —
// Zen Browser registers as "firefox.instance_<pid>" too, same as vanilla
// Firefox) — instead skips Stopped entries, which is what that filter was
// really working around: Firefox-family browsers leave a stale "Stopped"
// MPRIS entry with the last tab's title lingering after the tab closes.
// No output at all if every visible player is Stopped/none exist — same
// as the real module in that case.
const MPRIS_SCRIPT =
    \\for p in $(playerctl -l 2>/dev/null); do
    \\  out=$(playerctl -p "$p" metadata --format "{{status}}|{{artist}} - {{title}}" 2>/dev/null) || continue
    \\  case "$out" in Stopped\|*) continue;; esac
    \\  printf '%s|%s' "$p" "$out"
    \\  break
    \\done
;

fn startMprisFetch(cmd: *PolledCommand) void {
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", MPRIS_SCRIPT, null };
    cmd.startFetch("/bin/sh", &argv);
}

/// Parses wpctl's "Volume: 1.00" into a "100" percentage string written
/// into `buf`. Hand-rolled integer parsing (assumes exactly the two decimal
/// places wpctl always prints) rather than std.fmt.parseFloat, to sidestep
/// yet another moving-target stdlib API.
fn parseVolumePercent(text: []const u8, buf: []u8) []const u8 {
    const prefix = "Volume: ";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return "";
    const rest = std.mem.trim(u8, text[idx + prefix.len ..], " \t\r\n");
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return "";
    const whole = std.fmt.parseInt(i64, rest[0..dot], 10) catch return "";
    var frac_str = rest[dot + 1 ..];
    if (frac_str.len > 2) frac_str = frac_str[0..2];
    const frac = std.fmt.parseInt(i64, frac_str, 10) catch 0;
    const frac_scaled = if (frac_str.len == 1) frac * 10 else frac;
    return std.fmt.bufPrint(buf, "{d}", .{whole * 100 + frac_scaled}) catch "";
}

/// Turns MPRIS_SCRIPT's "STATUS|ARTIST - TITLE" into "STATUS ARTIST -
/// TITLE" for display (drawMpris uppercases it at draw time).
/// Encodes one codepoint as UTF-8 into `out` (needs >= 4 bytes), returning
/// how many bytes were written. Zig's `\u{}` string escape only works for
/// compile-time-known codepoints, and this one comes from a runtime lookup
/// table — hand-rolled for the same reason as nextUtf8Codepoint above.
fn utf8Encode(cp: u32, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Maps wttr.in's emoji (Miscellaneous Symbols / Emoji blocks — mostly
/// *not* covered by this Nerd Font, confirmed by probing FT_Get_Char_Index
/// directly) to an equivalent icon from the Nerd Font's weather-icons pack
/// (U+E300-U+E3E3, verified present) that actually renders.
fn wttrIconFor(cp: u32) ?u32 {
    return switch (cp) {
        0x2600 => 0xE30D, // ☀ sunny/clear
        0x26C5 => 0xE302, // ⛅ partly cloudy
        0x2601 => 0xE335, // ☁ cloudy
        0x1F326 => 0xE304, // 🌦 partly cloudy w/ rain
        0x1F327 => 0xE319, // 🌧 rain
        0x26C8 => 0xE31D, // ⛈ thunderstorm
        0x1F329 => 0xE31D, // 🌩 lightning
        0x1F328 => 0xE31A, // 🌨 snow shower
        0x2744 => 0xE31A, // ❄ snowflake
        0x1F32B => 0xE313, // 🌫 fog
        0x1F4A8 => 0xE34B, // 💨 windy
        0x1F32A => 0xE351, // 🌪 tornado
        0x1F32C => 0xE34B, // 🌬 wind blowing face
        else => null,
    };
}

/// Turns wttr.in's "<emoji> <temp>" into "<nf-icon> <temp>". Falls back to
/// the raw (trimmed) text unchanged if the leading symbol isn't one of the
/// recognized condition emoji, rather than guessing.
fn formatWeatherText(raw: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";

    var i: usize = 0;
    const cp = nextUtf8Codepoint(trimmed, &i) orelse return trimmed[0..@min(trimmed.len, buf.len)];
    const icon = wttrIconFor(cp) orelse return trimmed[0..@min(trimmed.len, buf.len)];

    // Skip past any variation-selector/ZWJ codepoints attached to the same
    // emoji cluster (wttr.in's sun is "☀️" = U+2600 + U+FE0F) before the
    // plain-text temperature begins.
    while (i < trimmed.len) {
        const save = i;
        const next_cp = nextUtf8Codepoint(trimmed, &i) orelse break;
        if (next_cp == 0xFE0F or next_cp == 0x200D) continue;
        i = save;
        break;
    }
    const rest = std.mem.trim(u8, trimmed[i..], " \t\r\n");

    var icon_bytes: [4]u8 = undefined;
    const icon_len = utf8Encode(icon, &icon_bytes);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ icon_bytes[0..icon_len], rest }) catch rest;
}

/// Strips the "STATUS|" prefix off `raw`, leaving just "ARTIST - TITLE".
/// Status is shown by drawMprisControls' play/pause glyph now, not
/// duplicated here as a text icon.
fn formatMprisText(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len == 0) return "";
    const sep = std.mem.indexOfScalar(u8, raw, '|') orelse return raw[0..@min(raw.len, buf.len)];
    const rest = raw[sep + 1 ..];
    return rest[0..@min(rest.len, buf.len)];
}

/// Reads the current local wall-clock time, formatted per
/// current_config.appearance.clock_format (one of the CLOCK_FORMAT_* keys).
/// Default ("date_24h") matches waybar's "clock#1" module format
/// (`{:%d - %H:%M}`) from ~/.config/waybar/config — the only format this
/// bar ever had before clock_format existed.
fn currentTimeText(buf: []u8) ![]u8 {
    const now = libc_time.time(null);
    var tm: libc_time.Tm = undefined;
    _ = libc_time.localtime_r(&now, &tm);
    // Cast to unsigned: {d:0>2} on a zero-padded *signed* int prints an
    // explicit sign (to disambiguate the padding), which the old blocky
    // font silently ate as an unmapped '+' — real font rendering exposed it.
    const mday: u32 = @intCast(tm.mday);
    const hour24: u32 = @intCast(tm.hour);
    const min: u32 = @intCast(tm.min);
    const sec: u32 = @intCast(tm.sec);

    const format = current_config.appearance.clock_format;
    if (std.mem.eql(u8, format, CLOCK_FORMAT_TIME_24H)) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour24, min });
    } else if (std.mem.eql(u8, format, CLOCK_FORMAT_TIME_24H_SECONDS)) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour24, min, sec });
    } else if (std.mem.eql(u8, format, CLOCK_FORMAT_TIME_12H) or std.mem.eql(u8, format, CLOCK_FORMAT_DATE_12H)) {
        // hour24==0 (midnight) displays as 12 AM; hour24==12 (noon) displays
        // as 12 PM; everything else is the usual mod-12 wrap.
        const hour12: u32 = if (hour24 == 0) 12 else if (hour24 > 12) hour24 - 12 else hour24;
        const suffix: []const u8 = if (hour24 < 12) "AM" else "PM";
        if (std.mem.eql(u8, format, CLOCK_FORMAT_DATE_12H)) {
            return std.fmt.bufPrint(buf, "{d:0>2} - {d:0>2}:{d:0>2} {s}", .{ mday, hour12, min, suffix });
        }
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2} {s}", .{ hour12, min, suffix });
    }
    // CLOCK_FORMAT_DATE_24H, or anything unrecognized (shouldn't happen —
    // validClockFormat already normalizes this at config-load time, but this
    // function doesn't re-check, so stay defensive rather than assume).
    return std.fmt.bufPrint(buf, "{d:0>2} - {d:0>2}:{d:0>2}", .{ mday, hour24, min });
}

const FONT_PIXEL_SIZE: u32 = 11;

/// Decodes one UTF-8 codepoint starting at `i.*`, advancing it past the
/// codepoint's bytes. Hand-rolled rather than std.unicode's iterator to
/// avoid depending on yet another stdlib surface that's shifted this
/// session (ArrayList, Io, net, ...) — this is a handful of lines and won't
/// move. Malformed leading bytes are skipped as a single byte (mapped to a
/// space) rather than erroring, since this only ever runs on text we
/// already trust (our own formatting, or playerctl/curl output).
fn nextUtf8Codepoint(text: []const u8, i: *usize) ?u32 {
    if (i.* >= text.len) return null;
    const b0 = text[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    if (b0 & 0xE0 == 0xC0 and i.* + 1 < text.len) {
        const cp = (@as(u32, b0 & 0x1F) << 6) | (text[i.* + 1] & 0x3F);
        i.* += 2;
        return cp;
    }
    if (b0 & 0xF0 == 0xE0 and i.* + 2 < text.len) {
        const cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, text[i.* + 1] & 0x3F) << 6) | (text[i.* + 2] & 0x3F);
        i.* += 3;
        return cp;
    }
    if (b0 & 0xF8 == 0xF0 and i.* + 3 < text.len) {
        const cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, text[i.* + 1] & 0x3F) << 12) | (@as(u32, text[i.* + 2] & 0x3F) << 6) | (text[i.* + 3] & 0x3F);
        i.* += 4;
        return cp;
    }
    i.* += 1;
    return ' ';
}

/// Alpha-blends `color` over whatever's already at `dst`, weighted by
/// FreeType's 8-bit anti-aliased coverage value.
fn blendPixel(dst: u32, color: u32, coverage: u8) u32 {
    if (coverage == 255) return color;
    const a: u32 = coverage;
    const inv: u32 = 255 - a;
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const cr = (color >> 16) & 0xFF;
    const cg = (color >> 8) & 0xFF;
    const cb = color & 0xFF;
    const r = (cr * a + dr * inv) / 255;
    const g = (cg * a + dg * inv) / 255;
    const b = (cb * a + db * inv) / 255;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Draws one glyph with its pen origin at (`pen_x`, `baseline_y`),
/// alpha-blended against the buffer's existing contents. Pixels outside
/// [`clip_x_min`, `clip_x_max`) are skipped in addition to the usual
/// buffer-bounds check — needed for pixel-accurate clipping where a glyph
/// straddles a scroll boundary (drawMpris); every other caller just passes
/// the full buffer width. Returns the glyph's advance width, so callers
/// walk the pen forward without needing a separate width lookup.
fn drawGlyphAt(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    pen_x: i64,
    baseline_y: i64,
    codepoint: u32,
    color: u32,
    clip_x_min: i64,
    clip_x_max: i64,
) i64 {
    const g = font.glyph(codepoint) catch return 0;
    const x0 = pen_x + g.bitmap_left;
    const y0 = baseline_y - g.bitmap_top;
    for (0..g.height) |row| {
        for (0..g.width) |col| {
            const coverage = g.pixels[row * g.width + col];
            if (coverage == 0) continue;
            const px = x0 + @as(i64, @intCast(col));
            const py = y0 + @as(i64, @intCast(row));
            if (px < clip_x_min or px >= clip_x_max or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= buf_width or pyu >= buf_height) continue;
            const idx = pyu * buf_width + pxu;
            pixels[idx] = blendPixel(pixels[idx], color, coverage);
        }
    }
    return g.advance_x;
}

/// Sum of each codepoint's advance width in `text`.
fn textPixelWidth(font: *font_mod.Font, text: []const u8) i64 {
    var total: i64 = 0;
    var i: usize = 0;
    while (nextUtf8Codepoint(text, &i)) |cp| {
        total += (font.glyph(cp) catch continue).advance_x;
    }
    return total;
}

/// Baseline y-coordinate that vertically centers this font's line height
/// (ascent + descent) within a `buf_height`-tall buffer.
fn baselineY(buf_height: u32, font: *const font_mod.Font) i64 {
    const line_height = font.ascentPx() + font.descentPx();
    const top = @divTrunc(@as(i64, @intCast(buf_height)) - line_height, 2);
    return top + font.ascentPx();
}

/// Draws workspace numbers left-aligned, active one highlighted — matching
/// waybar's "hyprland/workspaces" module colors (#workspaces button /
/// button.active in ~/.config/waybar/style.css). Also populates
/// `click_regions` with each workspace's clickable x-range, since layout
/// shifts as workspaces come and go. Assumes the caller has already cleared
/// `click_regions` for this frame.
/// Returns the x position just past the last workspace drawn, so
/// `drawMpris` (next in "modules-left") can continue from there.
fn drawWorkspaces(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    workspaces: []const Workspace,
    pointer_x: i32,
    click_regions: *ClickRegions,
) i64 {
    // If disabled via config, don't draw or register click regions, but
    // still hand back a sane starting x for the mpris chain that follows.
    if (!isModuleEnabled(current_config.modules.left, .workspaces)) return WORKSPACE_LEFT_MARGIN;

    const y0: i64 = baselineY(buf_height, font);
    const workspace_gap = current_config.appearance.workspace_gap;

    var x0: i64 = WORKSPACE_LEFT_MARGIN;
    var id_buf: [8]u8 = undefined;
    for (workspaces) |ws| {
        const color = if (ws.active) current_config.appearance.workspace_active_color else current_config.appearance.workspace_inactive_color;
        const text = std.fmt.bufPrint(&id_buf, "{d}", .{ws.id}) catch continue;
        const region_start = x0;
        // Half the gap on each side, so there's no dead zone between numbers
        // — same bounds for the hover highlight as for the click region.
        const hover_start = region_start - @divTrunc(workspace_gap, 2);
        const hover_end = region_start + textPixelWidth(font, text) + @divTrunc(workspace_gap, 2);
        _ = drawHoverHighlight(pixels, buf_width, buf_height, hover_start, hover_end, pointer_x);
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, color, 0, buf_width);
        }
        click_regions.add(@intCast(hover_start), @intCast(hover_end), .{ .switch_workspace = ws.id });
        x0 += workspace_gap;
    }
    return x0;
}

const MPRIS_CONTROL_GAP: i64 = 6; // spacing between the three control glyphs, and before the track text

/// Draws the previous/play-pause/next glyphs immediately before the mpris
/// track text, each a small click region targeting whichever player is
/// currently shown (via spawnPlayerctlCommand — not playerctl's no-target
/// default, which would act on every running player at once). Only called
/// when there's an active player to control; the play-pause glyph mirrors
/// the status icon already shown in the track text (pause glyph while
/// Playing, play glyph otherwise) so it always shows the action a click
/// performs, not the current state.
fn drawMprisControls(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    x0_start: i64,
    playing: bool,
    pointer_x: i32,
    click_regions: *ClickRegions,
) i64 {
    const y0: i64 = baselineY(buf_height, font);
    var x0 = x0_start;
    const buttons = [_]struct { icon: u32, action: MprisControl }{
        .{ .icon = 0xf048, .action = .previous }, // nf-fa-step_backward
        .{ .icon = if (playing) 0xf04c else 0xf04b, .action = .play_pause }, // pause : play
        .{ .icon = 0xf051, .action = .next }, // nf-fa-step_forward
    };
    for (buttons) |btn| {
        const region_start = x0;
        // Measuring via font.glyph directly (rather than drawing first)
        // lets the highlight go down before the glyph — same cached
        // lookup drawGlyphAt makes right after, so no extra rasterizing.
        const advance = if (font.glyph(btn.icon)) |g| g.advance_x else |_| 0;
        _ = drawHoverHighlight(pixels, buf_width, buf_height, region_start - 2, region_start + advance + 2, pointer_x);
        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, btn.icon, current_config.appearance.text_color, 0, buf_width);
        click_regions.add(@intCast(region_start - 2), @intCast(x0 + 2), .{ .mpris_control = btn.action });
        x0 += MPRIS_CONTROL_GAP;
    }
    return x0;
}

// Blank stretch between one loop of the ticker and the next repetition of
// the same text, so they don't run into each other.
const MPRIS_TICKER_GAP = "     ";

/// Draws mpris text between `x0_start` and `x_limit`, matching "mpris" in
/// "modules-left" (after "hyprland/workspaces") — as a continuous ticker,
/// always scrolling regardless of whether the text would fit statically
/// (a deliberate style choice, not just overflow handling). `scroll_step`
/// (advanced on a fast timer elsewhere) is the position within one
/// text+gap cycle; enough repetitions of "text+gap" are drawn back to back
/// to fill the visible window, so as one copy scrolls fully off the left
/// the next is already sliding in from the right — no dead pause waiting
/// for a single copy to loop back around. Pixel-accurate clipping (via
/// drawGlyphAt's clip params, not a whole-glyph skip) keeps the sliding
/// text from ever spilling past `x_limit` even mid-glyph.
fn drawMpris(pixels: [*]u32, buf_width: u32, buf_height: u32, font: *font_mod.Font, x0_start: i64, x_limit: i64, mpris_text: []const u8, scroll_step: i64) void {
    if (mpris_text.len == 0) return;
    const y0: i64 = baselineY(buf_height, font);
    const window_start = x0_start + LAUNCHER_GAP;
    if (x_limit <= window_start) return;

    const text_width = textPixelWidth(font, mpris_text);
    const gap_width = textPixelWidth(font, MPRIS_TICKER_GAP);
    const cycle_len = text_width + gap_width;
    if (cycle_len <= 0) return;
    const pos_in_cycle = @mod(scroll_step, cycle_len);

    var copy_start = window_start - pos_in_cycle;
    while (copy_start < x_limit) : (copy_start += cycle_len) {
        var x0 = copy_start;
        var i: usize = 0;
        while (nextUtf8Codepoint(mpris_text, &i)) |cp| {
            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, window_start, x_limit);
        }
    }
}

/// Draws the launcher buttons + clock as one centered group, matching
/// waybar's "modules-center" (the whole group is centered together, not
/// each item individually). Registers a click region per launcher button;
/// the clock itself isn't clickable here (real config's clock#1 opens
/// gnome-calendar on click — skipped for now).
const MAX_CENTER_SEGMENTS = 16;

/// One drawable piece of the center group — either a pinned launcher button
/// (clickable, `command` set) or the clock text (not clickable, `command`
/// null). `gap_after` is the horizontal space to leave after this segment
/// before the next one.
const CenterSegment = struct {
    label: []const u8,
    command: ?[:0]const u8 = null,
    gap_after: i64 = 0,
};

const CenterSegments = struct {
    items: [MAX_CENTER_SEGMENTS]CenterSegment = undefined,
    len: usize = 0,
};

/// Expands `current_config.modules.center` (in config order) into a flat
/// list of drawable segments — the single source of truth both the width-
/// measuring pass (`centerGroupWidth`) and the actual draw pass
/// (`drawCenterGroup`) consume, so the two can never drift out of the
/// pixel-identical sync `centerGroupStartX`'s doc comment warns about.
fn composeCenterSegments(time_text: []const u8) CenterSegments {
    var result: CenterSegments = .{};
    for (current_config.modules.center) |entry| {
        if (!entry.enabled) continue;
        switch (entry.kind) {
            .clock => {
                if (result.len < result.items.len) {
                    result.items[result.len] = .{ .label = time_text, .command = null, .gap_after = 0 };
                    result.len += 1;
                }
            },
            .launchers => {
                for (current_config.launchers) |btn| {
                    if (result.len >= result.items.len) break;
                    result.items[result.len] = .{ .label = btn.label, .command = btn.command, .gap_after = LAUNCHER_GAP };
                    result.len += 1;
                }
            },
            else => {}, // not a valid center-group module kind; ignore defensively
        }
    }
    return result;
}

fn centerGroupWidth(font: *font_mod.Font, time_text: []const u8) i64 {
    const segs = composeCenterSegments(time_text);
    var total: i64 = 0;
    for (segs.items[0..segs.len]) |seg| total += textPixelWidth(font, seg.label) + seg.gap_after;
    return total;
}

/// x position of the center group's left edge — the boundary drawMpris
/// must stay clear of (it grows rightward from the workspaces and would
/// otherwise run into this pixel-for-pixel identical calculation).
fn centerGroupStartX(buf_width: u32, font: *font_mod.Font, time_text: []const u8) i64 {
    return @divTrunc(@as(i64, @intCast(buf_width)) - centerGroupWidth(font, time_text), 2);
}

fn drawCenterGroup(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    time_text: []const u8,
    pointer_x: i32,
    click_regions: *ClickRegions,
) void {
    const y0: i64 = baselineY(buf_height, font);
    var x0: i64 = centerGroupStartX(buf_width, font, time_text);
    const segs = composeCenterSegments(time_text);

    for (segs.items[0..segs.len]) |seg| {
        if (seg.command) |cmd| {
            const region_start = x0;
            const hover_start = region_start - @divTrunc(LAUNCHER_GAP, 2);
            const hover_end = region_start + textPixelWidth(font, seg.label) + @divTrunc(LAUNCHER_GAP, 2);
            _ = drawHoverHighlight(pixels, buf_width, buf_height, hover_start, hover_end, pointer_x);
            var i: usize = 0;
            while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
            }
            click_regions.add(@intCast(hover_start), @intCast(hover_end), .{ .spawn = cmd });
        } else {
            var i: usize = 0;
            while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
            }
        }
        x0 += seg.gap_after;
    }
}

/// Draws `label` ending at `x_end` (its right edge), returns the x
/// coordinate of its left edge — so callers can chain right-to-left layout
/// by feeding each call's result in as the next one's `x_end`. Registers a
/// click region (with a few px of padding) when `action` is given.
fn drawRightAligned(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    y0: i64,
    x_end: i64,
    label: []const u8,
    color: u32,
    action: ?Action,
    pointer_x: i32,
    click_regions: *ClickRegions,
) i64 {
    const region_start = x_end - textPixelWidth(font, label);
    // Only clickable labels (action != null) get a hover highlight — a
    // static readout like the volume/pacman text shouldn't look pressable.
    if (action != null) {
        _ = drawHoverHighlight(pixels, buf_width, buf_height, region_start - 4, x_end + 4, pointer_x);
    }
    var x0 = region_start;
    var i: usize = 0;
    while (nextUtf8Codepoint(label, &i)) |cp| {
        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, color, 0, buf_width);
    }
    if (action) |a| {
        click_regions.add(@intCast(region_start - 4), @intCast(x0 + 4), a);
    }
    return region_start;
}

/// Fills a full-height rect between `x_start`/`x_end` with the configured
/// hover color when
/// `pointer_x` falls inside it — the same treatment the popup menu already
/// gives its hovered row, applied to the bar's own buttons. Callers draw
/// this *before* their glyphs so text/icons land on top. Returns whether it
/// hovered, in case a caller also wants to react (none currently do).
fn drawHoverHighlight(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64, pointer_x: i32) bool {
    if (pointer_x < x_start or pointer_x >= x_end) return false;
    const xs: usize = @intCast(@max(0, x_start));
    const xe: usize = @intCast(@min(@as(i64, @intCast(buf_width)), x_end));
    var y: u32 = 0;
    while (y < buf_height) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) pixels[y * buf_width + x] = current_config.appearance.hover_color;
    }
    return true;
}

/// Linearly interpolates between two 0xAARRGGBB colors (alpha always comes
/// out 0xFF — everything drawn here is opaque, just tinted toward `from`).
/// Used to fade the tray drawer's contents in/out by blending toward the
/// bar's own background color rather than actually varying alpha, since
/// blendPixel's blend weight is driven by glyph/icon coverage, not color.
fn lerpColor(from: u32, to: u32, t: f32) u32 {
    const tc = std.math.clamp(t, 0.0, 1.0);
    const fr: f32 = @floatFromInt((from >> 16) & 0xFF);
    const fg: f32 = @floatFromInt((from >> 8) & 0xFF);
    const fb: f32 = @floatFromInt(from & 0xFF);
    const tr: f32 = @floatFromInt((to >> 16) & 0xFF);
    const tg: f32 = @floatFromInt((to >> 8) & 0xFF);
    const tb: f32 = @floatFromInt(to & 0xFF);
    const r: u32 = @intFromFloat(fr + (tr - fr) * tc);
    const g: u32 = @intFromFloat(fg + (tg - fg) * tc);
    const b: u32 = @intFromFloat(fb + (tb - fb) * tc);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Blits a small ARGB icon (already downscaled to TRAY_ICON_SIZE) with its
/// right edge at `x_end`, vertically centered. `progress` (0-1) scales each
/// pixel's own alpha for the drawer's fade animation — real blending here
/// (via blendPixel), not the hard alpha cutoff a static icon would get
/// away with, since a faded-in icon needs to show through partially.
fn drawTrayIconEndingAt(pixels: [*]u32, buf_width: u32, buf_height: u32, x_end: i64, icon: []const u32, progress: f32, pointer_x: i32) i64 {
    const x0 = x_end - TRAY_ICON_SIZE;
    const y0 = @divTrunc(@as(i64, @intCast(buf_height)) - TRAY_ICON_SIZE, 2);
    const p = std.math.clamp(progress, 0.0, 1.0);
    // Same -2/+2 padding as the click region this icon gets at the call
    // site, so the highlight and the clickable area agree.
    _ = drawHoverHighlight(pixels, buf_width, buf_height, x0 - 2, x_end + 2, pointer_x);
    for (0..TRAY_ICON_SIZE) |iy| {
        for (0..TRAY_ICON_SIZE) |ix| {
            const px = x0 + @as(i64, @intCast(ix));
            const py = y0 + @as(i64, @intCast(iy));
            if (px < 0 or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= buf_width or pyu >= buf_height) continue;
            const src = icon[iy * TRAY_ICON_SIZE + ix];
            const src_alpha: f32 = @floatFromInt(src >> 24);
            const coverage: u8 = @intFromFloat(std.math.clamp(src_alpha * p, 0.0, 255.0));
            if (coverage == 0) continue;
            const idx = pyu * buf_width + pxu;
            pixels[idx] = blendPixel(pixels[idx], src, coverage);
        }
    }
    return x0;
}

/// Draws `current_config.modules.right` in config order, right-to-left from
/// the bar's edge — today's default order reproduces the original
/// hardcoded sequence exactly: custom/power, then the group/tray-expander
/// drawer (a "▾" toggle; expanded reveals custom/pacman, custom/waypaper, a
/// polled wireplumber volume reading, and any tray icons), then
/// custom/weather. An entry with `in_drawer == true` is only drawn while
/// `drawer_anim > 0` (0 = fully collapsed, 1 = fully expanded, animated
/// over a few frames by the caller), fading toward the bar's background
/// color as it goes, so expanding/collapsing is a quick fade rather than an
/// instant on/off. `first` tracks whether anything has been drawn yet in
/// this pass, since only the very first drawn item skips the leading
/// LAUNCHER_GAP that every subsequent one gets — this generalizes the
/// original code's fixed "gap before every call except the first" pattern
/// to an arbitrary enabled/disabled subset.
fn drawRightGroup(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    weather_text: []const u8,
    pacman_text: []const u8,
    volume_text: []const u8,
    drawer_anim: f32,
    tray: *const Tray,
    pointer_x: i32,
    click_regions: *ClickRegions,
) void {
    const y0: i64 = baselineY(buf_height, font);
    var x_end: i64 = @as(i64, @intCast(buf_width)) - RIGHT_MARGIN;
    var first = true;
    var custom_script_draw_index: usize = 0;
    const text_color = current_config.appearance.text_color;
    const drawer_color = lerpColor(current_config.appearance.bg_color, text_color, drawer_anim);

    for (current_config.modules.right) |entry| {
        if (!entry.enabled) continue;
        if (entry.in_drawer and drawer_anim <= 0.0) continue;
        // Unlike the original hardcoded modules (which each had a fixed
        // in-drawer-or-not identity baked into which call site drew them),
        // these six can be placed in or out of the drawer via config, so
        // their color is resolved from entry.in_drawer instead of being
        // hardcoded per-kind.
        const color = if (entry.in_drawer) drawer_color else text_color;

        switch (entry.kind) {
            .power => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, POWER_BUTTON.label, text_color, .{ .spawn = POWER_BUTTON.command }, pointer_x, click_regions);
            },
            .drawer_toggle => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, DRAWER_TOGGLE_LABEL, text_color, .toggle_drawer, pointer_x, click_regions);
            },
            .volume => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                // Volume icon tiers match wireplumber's real "default"
                // format-icons array (low/medium/high, U+F026/F027/F028).
                const vol_pct = std.fmt.parseInt(u32, volume_text, 10) catch 0;
                const vol_icon: []const u8 = if (vol_pct >= 67) "\u{f028}" else if (vol_pct >= 34) "\u{f027}" else "\u{f026}";
                var vol_buf: [24]u8 = undefined;
                const vol_label = std.fmt.bufPrint(&vol_buf, "{s} {s}", .{ vol_icon, volume_text }) catch vol_icon;
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, vol_label, drawer_color, null, pointer_x, click_regions);
            },
            .waypaper => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, WAYPAPER_BUTTON.label, drawer_color, .{ .spawn = WAYPAPER_BUTTON.command }, pointer_x, click_regions);
            },
            .pacman => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                // custom/pacman's real format is "<big>ᗧ</big> {}" (Pac-Man
                // glyph + count, no "UPD" text) — that exact character
                // (U+15E7) isn't in this Nerd Font, so an Arch Linux logo
                // glyph stands in instead (pacman being Arch's package
                // manager, at least in the same spirit).
                var pac_buf: [24]u8 = undefined;
                const pac_label = std.fmt.bufPrint(&pac_buf, "\u{f303} {s}", .{pacman_text}) catch "\u{f303}";
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, pac_label, drawer_color, null, pointer_x, click_regions);
            },
            .tray => {
                // icon-only items, no text label; skipped entirely if an
                // item hasn't gotten its first successful icon fetch yet.
                for (tray.items[0..tray.item_count], 0..) |item, i| {
                    if (!item.has_icon) continue;
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    const icon_left = drawTrayIconEndingAt(pixels, buf_width, buf_height, x_end, &item.pixels, drawer_anim, pointer_x);
                    click_regions.addWithRight(@intCast(icon_left - 2), @intCast(x_end + 2), .{ .activate_tray = i }, .{ .context_menu_tray = i });
                    x_end = icon_left;
                }
            },
            .weather => {
                // No click region: the real config only wires up a
                // right-click (format-alt-click), which this scaffold
                // doesn't distinguish from left-click yet.
                if (weather_text.len > 0) {
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, weather_text, text_color, null, pointer_x, click_regions);
                }
            },
            .cpu => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                var cpu_buf: [24]u8 = undefined;
                const cpu_label = std.fmt.bufPrint(&cpu_buf, "\u{f2db} {d}%", .{sys_stats.cpu_pct}) catch "\u{f2db}";
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, cpu_label, color, null, pointer_x, click_regions);
            },
            .ram => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                var ram_buf: [24]u8 = undefined;
                const ram_label = std.fmt.bufPrint(&ram_buf, "\u{f538} {d}%", .{sys_stats.ram_pct}) catch "\u{f538}";
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, ram_label, color, null, pointer_x, click_regions);
            },
            .disk => {
                if (!first) x_end -= LAUNCHER_GAP;
                first = false;
                var disk_buf: [24]u8 = undefined;
                const disk_label = std.fmt.bufPrint(&disk_buf, "\u{f0a0} {d}%", .{disk_pct}) catch "\u{f0a0}";
                x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, disk_label, color, null, pointer_x, click_regions);
            },
            .battery => {
                if (battery_state.found) {
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    var bat_buf: [24]u8 = undefined;
                    const bat_icon: []const u8 = if (battery_state.charging) "\u{f0e7}" else "\u{f240}";
                    const bat_label = std.fmt.bufPrint(&bat_buf, "{s} {d}%", .{ bat_icon, battery_state.capacity }) catch bat_icon;
                    x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, bat_label, color, null, pointer_x, click_regions);
                }
            },
            .cpu_temp => {
                if (cpu_temp_state.found) {
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    var temp_buf: [24]u8 = undefined;
                    const celsius = @divTrunc(cpu_temp_state.millidegrees_c, 1000);
                    const temp_label = std.fmt.bufPrint(&temp_buf, "\u{f2c9} {d}\u{00b0}C", .{celsius}) catch "\u{f2c9}";
                    x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, temp_label, color, null, pointer_x, click_regions);
                }
            },
            .network => {
                const mode = entry.mode orelse "speed";
                var ssid_buf: [40]u8 = undefined;
                const value: []const u8 = if (std.mem.eql(u8, mode, "ssid"))
                    parseSsid(net_ssid.text(), &ssid_buf)
                else
                    net_speed_state.text();
                if (value.len > 0) {
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    var net_buf: [48]u8 = undefined;
                    const net_label = std.fmt.bufPrint(&net_buf, "\u{f1eb} {s}", .{value}) catch "\u{f1eb}";
                    x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, net_label, color, null, pointer_x, click_regions);
                }
            },
            .custom_script => {
                defer custom_script_draw_index += 1;
                if (custom_script_draw_index < custom_script_count) {
                    const text = custom_scripts[custom_script_draw_index].text();
                    if (text.len > 0) {
                        if (!first) x_end -= LAUNCHER_GAP;
                        first = false;
                        var script_buf: [96]u8 = undefined;
                        const label = entry.label orelse "";
                        const script_label = if (label.len > 0)
                            std.fmt.bufPrint(&script_buf, "{s}: {s}", .{ label, text }) catch text
                        else
                            text;
                        x_end = drawRightAligned(pixels, buf_width, buf_height, font, y0, x_end, script_label, color, null, pointer_x, click_regions);
                    }
                }
            },
            .workspaces, .mpris, .clock, .launchers => {}, // not valid in the right group; ignore defensively
        }
    }
}

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
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                if (globals.output_count >= globals.outputs.len) return; // MAX_OUTPUTS reached; ignore the rest
                const output = registry.bind(g.name, wl.Output, 4) catch return;
                globals.outputs[globals.output_count] = .{ .output = output };
                const info = &globals.outputs[globals.output_count];
                globals.output_count += 1;
                output.setListener(*OutputInfo, outputListener, info);
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                const seat = registry.bind(g.name, wl.Seat, 7) catch return;
                globals.seat = seat;
                seat.setListener(*Globals, seatListener, globals);
            } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                const wm_base = registry.bind(g.name, xdg.WmBase, 3) catch return;
                globals.wm_base = wm_base;
                wm_base.setListener(*Globals, wmBaseListener, globals);
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Globals) void {
    switch (event) {
        // Compositors kill unresponsive clients over this — must reply.
        .ping => |p| wm_base.pong(p.serial),
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, globals: *Globals) void {
    switch (event) {
        .capabilities => |caps| globals.seat_has_pointer = caps.capabilities.pointer,
        .name => {},
    }
}

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;

/// There is exactly ONE wl_pointer object for the whole client (confirmed:
/// wl.Seat.getPointer() is called once in main(), regardless of how many
/// Bar surfaces exist) — its .enter/.leave events carry which surface the
/// pointer just entered/left, but .motion/.button don't repeat that, so this
/// listener has to remember which Bar (by index into a shared slice) is
/// currently focused and route subsequent events to it. `current` is that
/// remembered index; null means the pointer isn't over any of our surfaces.
const BarRouter = struct {
    bars: []Bar,
    current: ?usize = null,
};

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, router: *BarRouter) void {
    switch (event) {
        .enter => |e| {
            // Match the entered surface against every bar's own surface AND
            // its (at most one, at a time) open popup surface — a single
            // wl_pointer only ever focuses one surface at a time, same
            // reasoning the single-bar version already relied on, just
            // scanning across N candidate bars instead of assuming one.
            const found: ?usize = blk: {
                for (router.bars, 0..) |*b, i| {
                    if (b.surface == e.surface) break :blk i;
                    if (b.popup) |*pm| {
                        if (pm.surface == e.surface) break :blk i;
                    }
                }
                break :blk null;
            };
            router.current = found;
            const bar = &router.bars[found orelse return]; // entered a surface we don't own — shouldn't happen

            bar.pointer_over_popup = if (bar.popup) |*pm| e.surface == pm.surface else false;
            if (bar.pointer_over_popup) {
                bar.popup.?.pointer_x = e.surface_x.toInt();
                bar.popup.?.pointer_y = e.surface_y.toInt();
            } else {
                bar.pointer_x = e.surface_x.toInt();
                // Redraw for the hover highlight — entering already over a
                // button (e.g. the pointer didn't move but focus/workspace
                // did) needs this same as motion does below.
                drawAndCommit(bar) catch |err| {
                    std.debug.print("draw failed: {}\n", .{err});
                };
            }
        },
        .leave => {
            const bar = &router.bars[router.current orelse return];
            if (bar.pointer_over_popup) {
                if (bar.popup) |*pm| {
                    pm.pointer_x = -1;
                    pm.pointer_y = -1;
                    drawPopup(bar) catch {};
                }
            } else {
                bar.pointer_x = -1;
                drawAndCommit(bar) catch |err| { // clears any lingering hover highlight
                    std.debug.print("draw failed: {}\n", .{err});
                };
            }
            // The pointer just left the only surface we knew it was over —
            // Wayland always sends leave for the old surface before enter
            // for a new one, so there's no "which bar is it now" to track
            // until the next .enter arrives.
            router.current = null;
        },
        .motion => |e| {
            const bar = &router.bars[router.current orelse return];
            if (bar.pointer_over_popup) {
                if (bar.popup) |*pm| {
                    pm.pointer_x = e.surface_x.toInt();
                    const new_y = e.surface_y.toInt();
                    if (new_y != pm.pointer_y) {
                        pm.pointer_y = new_y;
                        drawPopup(bar) catch {}; // redraw for hover highlight
                    }
                }
            } else {
                // Only redraw when the hovered button actually changes —
                // motion fires on every pixel of movement, but the
                // highlight only needs to update when it'd look different.
                const old_region = bar.click_regions.hitTest(bar.pointer_x);
                bar.pointer_x = e.surface_x.toInt();
                const new_region = bar.click_regions.hitTest(bar.pointer_x);
                if (old_region != new_region) {
                    drawAndCommit(bar) catch |err| {
                        std.debug.print("draw failed: {}\n", .{err});
                    };
                }
            }
        },
        .button => |e| {
            const bar = &router.bars[router.current orelse return];
            bar.last_pointer_serial = e.serial;
            if (e.state != .pressed) return;

            if (bar.pointer_over_popup) {
                if (e.button != BTN_LEFT) return;
                const pm = &(bar.popup orelse return);
                const row = pm.hitTestRow(pm.pointer_y) orelse return;
                if (row.item_id) |id| {
                    var dest_buf: [64]u8 = undefined;
                    var path_buf: [128]u8 = undefined;
                    const dest_len = pm.dest().len;
                    const path_len = pm.path().len;
                    @memcpy(dest_buf[0..dest_len], pm.dest());
                    @memcpy(path_buf[0..path_len], pm.path());
                    if (bar.tray.conn) |*c| {
                        dbusmenu.sendClickEvent(c, dest_buf[0..dest_len], path_buf[0..path_len], id);
                    }
                }
                closePopup(bar);
                return;
            }

            const region = bar.click_regions.hitTest(bar.pointer_x) orelse return;
            if (e.button == BTN_LEFT) {
                handleAction(bar, region.action);
            } else if (e.button == BTN_RIGHT) {
                if (region.right_action) |ra| handleAction(bar, ra);
            }
        },
        else => {},
    }
}

fn handleAction(bar: *Bar, action: Action) void {
    switch (action) {
        .switch_workspace => |id| {
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "dispatch hl.dsp.focus({{ workspace = {d} }})", .{id}) catch return;
            bar.workspaces.dispatchCommand(cmd) catch |err| {
                std.debug.print("workspace switch failed: {}\n", .{err});
            };
        },
        .spawn => |command| spawnDetached(command),
        .toggle_drawer => {
            // Only flips the target — bar.drawer_anim eases toward it on
            // the scroll timer's tick (see its handler), producing the
            // fade instead of an instant on/off. This redraw won't show
            // the change yet (anim hasn't moved), but keeps behavior from
            // depending purely on timer timing for the first frame.
            bar.drawer_expanded = !bar.drawer_expanded;
            drawAndCommit(bar) catch |err| {
                std.debug.print("draw failed: {}\n", .{err});
            };
        },
        .activate_tray => |index| bar.tray.activate(index),
        .context_menu_tray => |index| openTrayContextMenu(bar, index),
        .mpris_control => |ctl| {
            if (bar.mpris_player_len == 0) return;
            const cmd: [*:0]const u8 = switch (ctl) {
                .previous => "previous",
                .play_pause => "play-pause",
                .next => "next",
            };
            spawnPlayerctlCommand(bar.mpris_player_buf[0..bar.mpris_player_len], cmd);
        },
    }
}

fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    bar: *Bar,
) void {
    switch (event) {
        .configure => |cfg| {
            layer_surface.ackConfigure(cfg.serial);
            bar.width = if (cfg.width > 0) cfg.width else 1;
            bar.height = if (cfg.height > 0) cfg.height else current_config.appearance.bar_height;
            bar.configured = true;
            drawAndCommit(bar) catch |err| {
                std.debug.print("draw failed: {}\n", .{err});
            };
        },
        .closed => {
            std.process.exit(0);
        },
    }
}

/// Allocate an anonymous shared-memory buffer, fill it with a solid color,
/// attach it to the surface, and commit. This is the whole "renderer" for
/// now — text/module drawing replaces the fill loop later.
fn drawAndCommit(bar: *Bar) !void {
    const stride = bar.width * 4; // ARGB8888
    const size: usize = @as(usize, stride) * bar.height;

    const fd = try posix.memfd_create("simpbar-buffer", 0);
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
    const pixel_count = size / 4;
    // Only the fill's alpha varies with bg_opacity_percent — text/icons/
    // border keep their own configured (always-opaque) colors, so lowering
    // this fades the background through to whatever's behind the bar
    // (blurred, if the "simpbar" Hyprland layer rule is set up) rather than
    // fading the whole bar's contents uniformly.
    const bg_alpha: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const bg_fill: u32 = bg_alpha | (current_config.appearance.bg_color & 0x00FFFFFF);
    var i: usize = 0;
    while (i < pixel_count) : (i += 1) pixels[i] = bg_fill;

    // Four independent border edges (originally just window#waybar's
    // top-only border-width: 2px 0px 0px 0px). Which edge "faces the
    // desktop" flips with `position`, but these are plain per-side widths,
    // not auto-selected based on anchor — the user can combine them
    // however they like. Clamped so top+bottom can't exceed bar.height and
    // left+right can't exceed bar.width (top/left take priority on an
    // impossible combination, same "first configured wins" spirit as
    // everything else that clamps rather than errors).
    const bc = current_config.appearance.border_color;
    const top_px = @min(current_config.appearance.border_top_px, bar.height);
    const bottom_px = @min(current_config.appearance.border_bottom_px, bar.height - top_px);
    const left_px = @min(current_config.appearance.border_left_px, bar.width);
    const right_px = @min(current_config.appearance.border_right_px, bar.width - left_px);

    var row: u32 = 0;
    while (row < top_px) : (row += 1) {
        var col: u32 = 0;
        while (col < bar.width) : (col += 1) pixels[row * bar.width + col] = bc;
    }
    row = bar.height - bottom_px;
    while (row < bar.height) : (row += 1) {
        var col: u32 = 0;
        while (col < bar.width) : (col += 1) pixels[row * bar.width + col] = bc;
    }
    row = 0;
    while (row < bar.height) : (row += 1) {
        var col: u32 = 0;
        while (col < left_px) : (col += 1) pixels[row * bar.width + col] = bc;
        col = bar.width - right_px;
        while (col < bar.width) : (col += 1) pixels[row * bar.width + col] = bc;
    }

    bar.click_regions.clear();

    var time_buf: [16]u8 = undefined; // "DD - HH:MM"
    const time_text = currentTimeText(&time_buf) catch |err| blk: {
        std.debug.print("clock render failed: {}\n", .{err});
        break :blk "";
    };
    drawCenterGroup(pixels, bar.width, bar.height, bar.font, time_text, bar.pointer_x, &bar.click_regions);

    const workspaces_end_x = drawWorkspaces(pixels, bar.width, bar.height, bar.font, bar.workspaces.list.items, bar.pointer_x, &bar.click_regions);
    // Config-gated as a whole block (not just the draw calls at the end):
    // nothing after this depends on mpris's screen position the way the
    // right-to-left chain depends on drawRightAligned's return value, so
    // skipping the entire block when disabled is safe — no other module's
    // layout needs mpris's state either way.
    if (isModuleEnabled(current_config.modules.left, .mpris)) {
        // bar.mpris.text() is "PLAYER|STATUS|ARTIST - TITLE" (MPRIS_SCRIPT) —
        // split off the player so clicks on the controls below can target it
        // specifically via spawnPlayerctlCommand; the "STATUS|ARTIST - TITLE"
        // remainder is what formatMprisText already expects.
        const mpris_raw = bar.mpris.text();
        const status_and_track = blk: {
            const sep = std.mem.indexOfScalar(u8, mpris_raw, '|') orelse {
                bar.mpris_player_len = 0;
                break :blk "";
            };
            const player = mpris_raw[0..sep];
            bar.mpris_player_len = @min(player.len, bar.mpris_player_buf.len);
            @memcpy(bar.mpris_player_buf[0..bar.mpris_player_len], player[0..bar.mpris_player_len]);
            break :blk mpris_raw[sep + 1 ..];
        };
        const playing = std.mem.startsWith(u8, status_and_track, "Playing|");
        var mpris_buf: [64]u8 = undefined;
        const mpris_text = formatMprisText(status_and_track, &mpris_buf);
        // Restart the scroll from the beginning whenever the track (or
        // play/pause status, since that's part of the same string) actually
        // changes — but not on every redraw, which would happen constantly
        // during the animation itself and never let it progress.
        if (!std.mem.eql(u8, bar.mpris_prev_buf[0..bar.mpris_prev_len], mpris_text)) {
            bar.mpris_scroll_step = 0;
            @memcpy(bar.mpris_prev_buf[0..mpris_text.len], mpris_text);
            bar.mpris_prev_len = mpris_text.len;
        }
        const center_start_x = centerGroupStartX(bar.width, bar.font, time_text);
        const mpris_start_x = if (mpris_text.len > 0)
            drawMprisControls(pixels, bar.width, bar.height, bar.font, workspaces_end_x, playing, bar.pointer_x, &bar.click_regions)
        else
            workspaces_end_x;
        drawMpris(pixels, bar.width, bar.height, bar.font, mpris_start_x, center_start_x - LAUNCHER_GAP, mpris_text, bar.mpris_scroll_step);
    }
    var volume_buf: [16]u8 = undefined;
    const volume_text = parseVolumePercent(bar.volume.text(), &volume_buf);
    var weather_buf: [32]u8 = undefined;
    const weather_text = formatWeatherText(bar.weather.text(), &weather_buf);
    drawRightGroup(
        pixels,
        bar.width,
        bar.height,
        bar.font,
        weather_text,
        bar.pacman.text(),
        volume_text,
        bar.drawer_anim,
        bar.tray,
        bar.pointer_x,
        &bar.click_regions,
    );

    // Corner rounding — the very last drawing step, so it clips everything
    // (background, borders, every module) rather than just the background
    // fill. Standard corner-circle technique: for each corner's radius×radius
    // pixel box, zero out (fully transparent, not just recolored — the SHM
    // buffer is argb8888 with no opaque-region hint set, so alpha=0 really
    // does cut the pixel away rather than just changing its RGB) whichever
    // pixels fall outside that corner's rounding circle. Squared-distance
    // comparison avoids a sqrt per pixel.
    const radius = @min(current_config.appearance.corner_radius_px, @min(bar.width, bar.height) / 2);
    if (radius > 0) {
        const r_i: i32 = @intCast(radius);
        const r_sq: i32 = r_i * r_i;
        var cy: u32 = 0;
        while (cy < radius) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < radius) : (cx += 1) {
                // Circle center sits one pixel inside the radius box's inner
                // corner (radius-1), matching the usual pixel-center-at-
                // integer-coordinate convention for a discrete rounded rect.
                const dx: i32 = @as(i32, @intCast(cx)) - (r_i - 1);
                const dy: i32 = @as(i32, @intCast(cy)) - (r_i - 1);
                if (dx * dx + dy * dy > r_sq) {
                    pixels[cy * bar.width + cx] = 0; // top-left
                    pixels[cy * bar.width + (bar.width - 1 - cx)] = 0; // top-right
                    pixels[(bar.height - 1 - cy) * bar.width + cx] = 0; // bottom-left
                    pixels[(bar.height - 1 - cy) * bar.width + (bar.width - 1 - cx)] = 0; // bottom-right
                }
            }
        }
    }

    const pool = try bar.shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    const buffer = try pool.createBuffer(
        0,
        @intCast(bar.width),
        @intCast(bar.height),
        @intCast(stride),
        .argb8888,
    );
    defer buffer.destroy();

    bar.surface.attach(buffer, 0, 0);
    bar.surface.damageBuffer(0, 0, @intCast(bar.width), @intCast(bar.height));
    bar.surface.commit();
}

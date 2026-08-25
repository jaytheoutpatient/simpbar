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

// Every ModuleKind valid in the "right" group per main.zig's drawRightGroup
// switch (i.e. everything except workspaces/mpris/clock/launchers, which are
// left/center-only) — used by ModuleGroup.ensureKindsPresent so the Modules
// tab always shows every possible right-side module, not just whichever
// ones happen to already be in config.json. Keep this in sync with
// drawRightGroup's switch if a new right-side kind is ever added.
const RIGHT_MODULE_KINDS = [_]ModuleKind{
    .power,     .drawer_toggle, .volume,  .waypaper,      .pacman,
    .tray,      .weather,       .cpu,     .ram,           .network,
    .disk,      .battery,       .custom_script, .cpu_temp,
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
    .{ .kind = .power, .enabled = true },
    .{ .kind = .drawer_toggle, .enabled = true },
    .{ .kind = .volume, .enabled = true, .in_drawer = true },
    .{ .kind = .waypaper, .enabled = true, .in_drawer = true },
    .{ .kind = .pacman, .enabled = true, .in_drawer = true },
    .{ .kind = .tray, .enabled = true, .in_drawer = true },
    .{ .kind = .weather, .enabled = true },
};
const CENTER_LAUNCHERS = [_]LauncherButton{
    .{ .label = "\u{f0c9} Menu", .command = "nwg-drawer" },
    .{ .label = "\u{f0ac} Browser", .command = "simpbar-launch-browser" },
    .{ .label = "\u{f066f} Discord", .command = "simpbar-launch-discord" },
    .{ .label = "\u{f07c} Files", .command = "nautilus" },
    .{ .label = "\u{f120} Term", .command = "foot" },
    .{ .label = "\u{f1b6} Steam", .command = "steam" },
    .{ .label = "\u{f013} HyprMod", .command = "hyprmod" },
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
    // Matches font.zig's FONT_PATH literal in main.zig exactly — config_main.zig
    // doesn't import font_mod (this binary has no Wayland/FreeType deps), so
    // the default has to be duplicated rather than referenced.
    font_path: []const u8 = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    bg_opacity_percent: u8 = 100,
    position: []const u8 = "bottom",
    corner_radius_px: u32 = 0,
    clock_format: []const u8 = "date_24h",
    // "" = compositor default (today's original single-bar behavior),
    // "all" = one bar per connected output, anything else = a specific
    // output name (main.zig falls back to "" if that name isn't currently
    // connected). Matches main.zig's Appearance.monitor exactly.
    monitor: []const u8 = "",
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
var config_json_path: [:0]const u8 = "";
var pidfile_path: [:0]const u8 = "";

fn resolvePaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    var dir_buf: [480]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = mkdir(dir.ptr, 0o755);
    config_json_path = std.fmt.bufPrintZ(&config_json_path_buf, "{s}/config.json", .{dir}) catch "";
    pidfile_path = std.fmt.bufPrintZ(&pidfile_path_buf, "{s}/simpbar.pid", .{dir}) catch "";
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

const ColorField = enum { bg, text, border, hover, ws_active, ws_inactive, popup_bg, popup_hover, popup_separator, popup_disabled };

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
    .{ .field = .ws_active, .default_hex = "#DCDCDC", .title = "Active Workspace", .group = .bar },
    .{ .field = .ws_inactive, .default_hex = "#505050", .title = "Inactive Workspace", .group = .bar },
    .{ .field = .popup_bg, .default_hex = "#262626", .title = "Popup Background", .group = .popup },
    .{ .field = .popup_hover, .default_hex = "#3A3A3A", .title = "Popup Hover", .group = .popup },
    .{ .field = .popup_separator, .default_hex = "#444444", .title = "Popup Separator", .group = .popup },
    .{ .field = .popup_disabled, .default_hex = "#707070", .title = "Popup Disabled Text", .group = .popup },
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
            std.debug.print("config: more than {d} modules in one group, dropping the rest\n", .{self.rows.len});
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

    fn button(self: *const LauncherRow) LauncherButton {
        return .{
            .label = self.label_buf[0..self.label_len],
            .command = self.command_buf[0..self.command_len :0],
            .icon = if (self.has_icon) self.icon_buf[0..self.icon_len] else null,
        };
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
            std.debug.print("config: more than {d} launchers, dropping the rest\n", .{self.rows.len});
        }
        self.len = @min(src.len, self.rows.len);
        for (0..self.len) |i| {
            self.rows[i] = .{};
            self.setLabel(i, src[i].label);
            self.setCommand(i, src[i].command);
            if (src[i].icon) |ic| self.setIcon(i, ic);
        }
    }

    /// Appends a new pinned launcher (Shortcuts tab's "Pin to Bar"). Returns
    /// false (no-op) once MAX_LAUNCHERS is reached.
    fn append(self: *LauncherGroup, label: []const u8, command: []const u8, icon: ?[]const u8) bool {
        if (self.len >= self.rows.len) return false;
        const i = self.len;
        self.rows[i] = .{};
        self.setLabel(i, label);
        self.setCommand(i, command);
        if (icon) |ic| self.setIcon(i, ic);
        self.len += 1;
        return true;
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

    const allocator = config_arena.allocator();
    var parsed: JsonConfig = .{};
    if (readFileAlloc(allocator, config_json_path)) |bytes| {
        parsed = std.json.parseFromSliceLeaky(JsonConfig, allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| blk: {
            std.debug.print("config: could not parse {s}: {} (using defaults)\n", .{ config_json_path, err });
            break :blk JsonConfig{};
        };
    } else |err| {
        std.debug.print("config: could not read {s}: {} (using defaults)\n", .{ config_json_path, err });
    }

    const j = parsed.appearance;
    const hexes = [_][]const u8{
        j.bg_color,                    j.text_color,
        j.border_color,                j.hover_color,
        j.workspace_active_color,      j.workspace_inactive_color,
        j.popup_bg_color,              j.popup_hover_color,
        j.popup_separator_color,       j.popup_disabled_color,
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
    live_clock_format = validClockFormatChoice(j.clock_format);
    live_monitor = j.monitor;

    live_left.load(parsed.modules.left);
    live_center.load(parsed.modules.center);
    live_right.load(parsed.modules.right);
    live_right.ensureKindsPresent(&RIGHT_MODULE_KINDS);
    live_launchers.load(parsed.launchers);
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
            .ws_active => "workspace_active_color",
            .ws_inactive => "workspace_inactive_color",
            .popup_bg => "popup_bg_color",
            .popup_hover => "popup_hover_color",
            .popup_separator => "popup_separator_color",
            .popup_disabled => "popup_disabled_color",
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
    try list.appendSlice(gpa, ",\"clock_format\":");
    try appendJsonString(&list, live_clock_format);
    try list.appendSlice(gpa, ",\"monitor\":");
    try appendJsonString(&list, live_monitor);

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
        std.debug.print("config: no pidfile at {s} (bar not running?)\n", .{pidfile_path});
        return;
    };
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(c_int, trimmed, 10) catch {
        std.debug.print("config: unreadable pid in {s}\n", .{pidfile_path});
        return;
    };
    if (std.c.kill(pid, .USR1) != 0) {
        std.debug.print("config: kill(SIGUSR1) on pid {d} failed (bar not running?)\n", .{pid});
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
        std.debug.print("config: failed to build config.json: {}\n", .{err});
        return;
    };
    defer gpa.free(bytes);
    if (!writeFileAll(config_json_path, bytes)) {
        std.debug.print("config: failed to write {s}\n", .{config_json_path});
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

fn onPositionChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    live_position = if (gtk.adw_combo_row_get_selected(row) == 0) "top" else "bottom";
    saveAndSignal();
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
// Monitor selection — discovers connected outputs via `hyprctl monitors -j`
// (the only live-system-query mechanism in this file, same runCaptured
// fork/exec/pipe-capture already used for fc-list above; NOT std.json —
// this file hand-parses external command output everywhere, matching
// main.zig's own hand-rolled substring-scan style for Hyprland JSON).
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
    const output = runCaptured(&.{ "hyprctl", "monitors", "-j" }, 3000) orelse return;
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
    gtk.adw_preferences_group_set_description(transparency_group, "Lowering this fades the bar's background through to what's behind it. For an actual blur (not just a plain see-through cutout), simpbar's Hyprland layer rule needs blur enabled too — already set up if you added it from here.");
    addSpinRow(transparency_group, "Background Opacity (%)", 0, 100, @floatFromInt(live_bg_opacity_percent), @ptrCast(&onBgOpacityChanged));
    gtk.gtk_box_append(outer, @ptrCast(transparency_group));

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

fn onPinToBarClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const ss: *const SessionShortcut = @ptrCast(@alignCast(user_data.?));
    if (!live_launchers.append(ss.name(), ss.exec(), ss.icon())) {
        std.debug.print("shortcuts: launcher list is full ({d} max), not pinning\n", .{MAX_LAUNCHERS});
        return;
    }
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
        std.debug.print("shortcuts: Name and Exec are both required, not creating\n", .{});
        return;
    }
    const comment = if (g_comment_entry) |e| entryText(e) else "";
    const icon = if (g_icon_entry) |e| entryText(e) else "";

    resolveApplicationsDir();
    var slug_buf: [MAX_ROW_TEXT]u8 = undefined;
    const slug = slugify(name, &slug_buf);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.desktop", .{ applications_dir, slug }) catch {
        std.debug.print("shortcuts: slug too long, not creating\n", .{});
        return;
    };

    const contents = buildDesktopFile(name, comment, exec, icon) catch |err| {
        std.debug.print("shortcuts: failed to build .desktop contents: {}\n", .{err});
        return;
    };
    defer gpa.free(contents);
    if (!writeFileAll(path, contents)) {
        std.debug.print("shortcuts: failed to write {s}\n", .{path});
        return;
    }

    if (session_shortcuts_len >= session_shortcuts.len) {
        std.debug.print("shortcuts: {d} created this session already, not tracking any more (file was still written)\n", .{session_shortcuts.len});
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

    const list_heading = gtk.gtk_label_new("Shortcuts (this session)");
    gtk.gtk_widget_add_css_class(@ptrCast(list_heading), "heading");
    gtk.gtk_label_set_xalign(list_heading, 0);
    gtk.gtk_widget_set_margin_top(@ptrCast(list_heading), 12);
    gtk.gtk_box_append(outer, @ptrCast(list_heading));

    const listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(listbox), "boxed-list");
    g_shortcuts_listbox = listbox;
    gtk.gtk_box_append(outer, @ptrCast(listbox));

    return outer;
}

// ---------------------------------------------------------------------
// Modules tab widgets (Step 6: switches + custom-script fields; Step 7:
// real drag-and-drop reordering). Each group ("Left"/"Center"/"Right") is
// an application-owned GtkListBox (styled with libadwaita's "boxed-list"
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
        .waypaper => "Wallpaper Button",
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
};
var left_ctx: GroupCtx = undefined;
var center_ctx: GroupCtx = undefined;
var right_ctx: GroupCtx = undefined;

const MODULE_ROW_DATA_KEY = "simpbar-module-row";

/// GtkDragSource "prepare" — real signature verified against the installed
/// Gtk-4.0.gir (GdkContentProvider* (GtkDragSource*, gdouble, gdouble,
/// gpointer)). `user_data` is the dragged AdwActionRow's own ModuleRow
/// pointer (stable for the row's lifetime — see the GroupCtx doc comment
/// on why that's safe here). Boxes it in a G_TYPE_POINTER GValue; GTK
/// copies the GValue into the content provider it creates, so the local
/// `value` going out of scope when this returns is fine.
fn onModuleDragPrepare(_: *gtk.GtkDragSource, _: f64, _: f64, user_data: ?*anyopaque) callconv(.c) ?*gtk.GdkContentProvider {
    const row_ptr = user_data orelse return null;
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.G_TYPE_POINTER);
    gtk.g_value_set_pointer(&value, row_ptr);
    return gtk.gdk_content_provider_new_for_value(&value);
}

/// GtkDropTarget "drop" — real signature verified against the installed
/// Gtk-4.0.gir (gboolean (GtkDropTarget*, const GValue*, gdouble x,
/// gdouble y, gpointer)). `user_data` is this listbox's GroupCtx.
fn onModuleDrop(_: *gtk.GtkDropTarget, value: *const gtk.GValue, _: f64, y: f64, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *GroupCtx = @ptrCast(@alignCast(user_data.?));
    const raw = gtk.g_value_get_pointer(value) orelse return 0;
    const source_row: *ModuleRow = @ptrCast(@alignCast(raw));

    // Reject drags that didn't originate from THIS group's own array (a
    // cross-group drop, or a stale pointer from before a rebuild) — v1
    // only supports reordering within a group, matching the config
    // schema's separate left/center/right JSON arrays.
    const from = ctx.group.indexOf(source_row) orelse return 0;

    var to: usize = ctx.group.len - 1; // dropping below the last row = move to end
    if (gtk.gtk_list_box_get_row_at_y(ctx.listbox, @intFromFloat(y))) |target_widget| {
        if (gtk.g_object_get_data(@ptrCast(target_widget), MODULE_ROW_DATA_KEY)) |tp| {
            const target_row: *ModuleRow = @ptrCast(@alignCast(tp));
            if (ctx.group.indexOf(target_row)) |idx| to = idx;
        }
    }

    if (from != to) {
        ctx.group.moveRow(from, to);
        rebuildGroupListBox(ctx);
        saveAndSignal();
    }
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
    // triggers reordering.
    //
    // Not attached at all when `!reorderable` (the Left group — see the
    // doc comment on addModuleGroupSection's `reorderable` parameter for
    // why): a row that looks draggable but silently does nothing on drop
    // is worse than a row that plainly isn't draggable.
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
/// low-frequency user action, not a hot path).
fn rebuildGroupListBox(ctx: *GroupCtx) void {
    gtk.gtk_list_box_remove_all(ctx.listbox);
    for (0..ctx.group.len) |i| {
        addModuleRow(ctx.listbox, &ctx.group.rows[i], ctx.reorderable);
    }
}

/// `reorderable` is false for the Left group specifically: main.zig's left
/// chain draws workspaces and mpris via a fixed left-to-right handoff
/// (drawWorkspaces returns an end-x that mpris's controls/ticker consume as
/// their own start-x, and the mpris ticker's scroll window is itself bounded
/// by where the center group starts — it has no fixed "width" the way a
/// launcher button does, so it can't just trade places with workspaces the
/// way two Right-group modules can). Only enable/disable is actually
/// config-driven for Left today, not order, so offering drag-and-drop there
/// would let a user "successfully" reorder rows in the GUI while the bar
/// silently ignored it — confirmed exactly that during live testing. Center
/// and Right both iterate their module list in array order with no such
/// positional coupling, so they stay fully reorderable.
fn addModuleGroupSection(outer: *gtk.GtkBox, title: [:0]const u8, mgroup: *ModuleGroup, ctx: *GroupCtx, reorderable: bool) void {
    const heading = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(@ptrCast(heading), "heading");
    gtk.gtk_label_set_xalign(heading, 0);
    gtk.gtk_box_append(outer, @ptrCast(heading));

    const listbox = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(listbox), "boxed-list");
    if (reorderable) {
        // Give the listbox a generous minimum height regardless of how few
        // rows it holds — a short group is an easy-to-overshoot drop target
        // since GtkDropTarget only fires "drop" while the pointer is still
        // over the widget it's attached to. Padding the listbox's own
        // minimum size out to a fixed floor gives every reorderable group a
        // comparably forgiving drop zone without needing to move the drop
        // target onto a different (larger) widget and translate coordinates
        // between them.
        gtk.gtk_widget_set_size_request(@ptrCast(listbox), -1, 160);
    }
    ctx.* = .{ .group = mgroup, .listbox = listbox, .reorderable = reorderable };

    if (reorderable) {
        const drop_target = gtk.gtk_drop_target_new(gtk.G_TYPE_POINTER, gtk.GDK_ACTION_MOVE);
        _ = gtk.g_signal_connect_data(@ptrCast(drop_target), "drop", @ptrCast(&onModuleDrop), @ptrCast(ctx), null, 0);
        gtk.gtk_widget_add_controller(@ptrCast(listbox), @ptrCast(drop_target));
    }

    for (0..mgroup.len) |i| {
        addModuleRow(listbox, &mgroup.rows[i], reorderable);
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

    addModuleGroupSection(outer, "Left", &live_left, &left_ctx, false);
    addModuleGroupSection(outer, "Center", &live_center, &center_ctx, true);
    addModuleGroupSection(outer, "Right", &live_right, &right_ctx, true);

    return outer;
}

// ---------------------------------------------------------------------
// Window / application — structure mirrors welcome_main.zig's buildWindow.
// ---------------------------------------------------------------------

const PAGE_NAMES = [_][:0]const u8{ "Appearance", "Modules", "Shortcuts" };
const PAGE_ICONS = [_][:0]const u8{ "applications-graphics-symbolic", "view-list-symbolic", "user-bookmarks-symbolic" };

var g_sidebar_rows: [PAGE_NAMES.len]*gtk.GtkListBoxRow = undefined;
var g_content_stack: ?*gtk.GtkStack = null;
var g_window: ?*gtk.AdwApplicationWindow = null;

fn onSidebarRowSelected(_: *gtk.GtkListBox, row: ?*gtk.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const r = row orelse return;
    for (g_sidebar_rows, 0..) |sr, i| {
        if (sr == r) {
            gtk.gtk_stack_set_visible_child_name(g_content_stack.?, PAGE_NAMES[i]);
            return;
        }
    }
}

fn buildWindow(app: *anyopaque) *gtk.AdwApplicationWindow {
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

    const pages = [_]*gtk.GtkBox{
        buildAppearancePage(),
        buildModulesPage(),
        buildShortcutsPage(),
    };

    const content_stack = gtk.gtk_stack_new();
    gtk.gtk_stack_set_transition_type(content_stack, gtk.STACK_TRANSITION_CROSSFADE);
    gtk.gtk_widget_set_vexpand(@ptrCast(content_stack), 1);
    gtk.gtk_widget_set_hexpand(@ptrCast(content_stack), 1);
    g_content_stack = content_stack;

    for (PAGE_NAMES, 0..) |name, i| {
        const row = gtk.gtk_list_box_row_new();
        const row_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_set_margin_top(@ptrCast(row_box), 8);
        gtk.gtk_widget_set_margin_bottom(@ptrCast(row_box), 8);
        gtk.gtk_widget_set_margin_start(@ptrCast(row_box), 12);
        gtk.gtk_widget_set_margin_end(@ptrCast(row_box), 12);
        gtk.gtk_box_append(row_box, @ptrCast(gtk.gtk_image_new_from_icon_name(PAGE_ICONS[i])));
        const label = gtk.gtk_label_new(name);
        gtk.gtk_label_set_xalign(label, 0);
        gtk.gtk_box_append(row_box, @ptrCast(label));
        gtk.gtk_list_box_row_set_child(row, @ptrCast(row_box));
        gtk.gtk_list_box_append(sidebar_list, @ptrCast(row));
        g_sidebar_rows[i] = row;

        const scrolled = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
        gtk.gtk_widget_set_vexpand(@ptrCast(scrolled), 1);
        gtk.gtk_widget_set_hexpand(@ptrCast(scrolled), 1);
        gtk.gtk_scrolled_window_set_child(scrolled, @ptrCast(pages[i]));
        _ = gtk.gtk_stack_add_named(content_stack, @ptrCast(scrolled), name);
    }

    _ = gtk.g_signal_connect_data(@ptrCast(sidebar_list), "row-selected", @ptrCast(&onSidebarRowSelected), null, null, 0);

    const sidebar_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(sidebar_toolbar, @ptrCast(gtk.adw_header_bar_new()));
    gtk.adw_toolbar_view_set_content(sidebar_toolbar, @ptrCast(sidebar_list));
    const sidebar_page = gtk.adw_navigation_page_new(@ptrCast(sidebar_toolbar), "Simpbar Config");
    gtk.adw_navigation_split_view_set_sidebar(split_view, sidebar_page);

    const content_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(content_toolbar, @ptrCast(gtk.adw_header_bar_new()));
    gtk.adw_toolbar_view_set_content(content_toolbar, @ptrCast(content_stack));
    const content_page = gtk.adw_navigation_page_new(@ptrCast(content_toolbar), "");
    gtk.adw_navigation_split_view_set_content(split_view, content_page);

    gtk.adw_application_window_set_content(window, @ptrCast(split_view));

    gtk.gtk_list_box_select_row(sidebar_list, gtk.gtk_list_box_get_row_at_index(sidebar_list, 0));

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
}

pub fn main() !void {
    const app = gtk.adw_application_new(APP_ID, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&onAppActivate), null, null, 0);
    const code = gtk.g_application_run(@ptrCast(app), 0, null);
    exit(code);
}

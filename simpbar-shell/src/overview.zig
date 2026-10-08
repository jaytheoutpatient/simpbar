//! Overview mode (Alt+W) — a GNOME-Shell-style overview layered over the
//! desktop: dimmed blurred backdrop (Hyprland's layer-rule blur does the
//! actual blurring; we paint the dim), a centered grid of REAL screenshot
//! thumbnails (zwlr_screencopy), a workspace strip along the top, a search
//! box, and a favorites dash above the bar.
//!
//! The overview is a second layer surface on the `overlay` layer (namespace
//! `simpbar-shell-overview`), created when it opens and destroyed when it
//! closes — so it costs nothing while closed. It opens on the focused
//! monitor only: snapshot, window list, and input region are all that
//! output's.
//!
//! Sequence on open (the snapshot is taken BEFORE the surface maps so we
//! never capture our own dim):
//!   1. hyprctl IPC: monitors -> focused output/origin, clients -> windows,
//!      workspaces -> strip, layers -> the bar hole (that strip stays
//!      un-dimmed and clickable-through, like the rest of the bar).
//!   2. zwlr_screencopy capture_output on that wl_output: buffer/copy/ready
//!      (bound at v1 so `buffer` alone means "go" — no buffer_done dance).
//!   3. map the overlay surface (dim paint + exclusive keyboard), animate
//!      in via wl_surface.frame callbacks (~260ms fade+slide).
//! Capture failure/timeout falls back to icon+title cards — the overview
//! still opens, just without screenshots.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const font_mod = @import("font");
const logging = @import("logging");
const widgets_mod = @import("widgets");

const MAX_WINS: usize = 64;
const MAX_CLIENTS: usize = 128;
const MAX_WS: usize = 12;
pub const MAX_FAVS: usize = 8;

/// Dash defaults for shell.json's `overview_favorites` (launch commands,
/// shown as their first word). Used whenever the config lists none.
pub const DEFAULT_FAVS = [_][]const u8{ "foot", "firefox", "dolphin", "mpv", "steam" };

const OPEN_MS: i64 = 260;
const CLOSE_MS: i64 = 200;
const CAPTURE_TIMEOUT_MS: i64 = 600;
/// Poll tick for the open/close animation — the host wakes us at this
/// cadence while animating instead of leaning on wl_surface.frame (a
/// compositor owes no frame callback for a still-transparent surface, so
/// waiting on one deadlocks frame 0).
const FRAME_MS: i64 = 16;

// Layout constants (1920x1080 reference; everything else derives from them).
const SEARCH_W: i64 = 520;
const SEARCH_H: i64 = 44;
const STRIP_Y: i64 = 84; // search box occupies y=24..68
const STRIP_THUMB_W: i64 = 160;
const STRIP_THUMB_H: i64 = 90;
const STRIP_GAP: i64 = 14;
const GRID_X: i64 = 48;
const CELL_GAP: i64 = 18;
const DASH_H: i64 = 40;

const BTN_LEFT: u32 = 0x110;

// evdev keycodes (same numbering main.zig's note editor already uses).
const KEY_ESC: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_TAB: u32 = 15;
const KEY_ENTER: u32 = 28;
const KEY_KPENTER: u32 = 96;
const KEY_LEFT: u32 = 105;
const KEY_UP: u32 = 103;
const KEY_RIGHT: u32 = 106;
const KEY_DOWN: u32 = 108;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const libc_clock = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

/// Monotonic milliseconds — same dance as main.zig (0.16 dropped
/// std.time.milliTimestamp; the bar binds libc time itself too).
fn nowMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_clock.clock_gettime(1, &tp) != 0) return 0; // CLOCK_MONOTONIC
    return @as(i64, @intCast(tp.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tp.nsec)), 1_000_000);
}

/// Cubic ease-out for the open/close animation.
fn easeOut(t: f64) f64 {
    const u = 1.0 - std.math.clamp(t, 0.0, 1.0);
    return 1.0 - u * u * u;
}

/// 0xAARRGGBB with alpha scaled by a 0..1 factor (animation fade).
fn sc(color: u32, p: f64) u32 {
    const a: f64 = @floatFromInt((color >> 24) & 0xFF);
    const na: u32 = @intFromFloat(@max(a * p, 0.0));
    return (@as(u32, @min(na, 255)) << 24) | (color & 0x00FFFFFF);
}

/// Rounded-corner coverage test (same geometry as Canvas.card's mask).
fn insideRounded(x: i64, y: i64, l: i64, t: i64, w: i64, h: i64, r: i64) bool {
    if (x < l or y < t or x >= l + w or y >= t + h) return false;
    if (r <= 0) return true;
    if (x >= l + r and x < l + w - r) return true;
    if (y >= t + r and y < t + h - r) return true;
    const cx = std.math.clamp(x, l + r, l + w - r - 1);
    const cy = std.math.clamp(y, t + r, t + h - r - 1);
    const dx = x - cx;
    const dy = y - cy;
    return dx * dx + dy * dy <= r * r;
}

/// Next UTF-8 codepoint at *i (advances past it). Malformed bytes decode
/// as one replacement byte so iteration always terminates.
fn nextCp(s: []const u8, i: *usize) ?u21 {
    if (i.* >= s.len) return null;
    const b0 = s[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    const len: usize = if (b0 >= 0xF0) 4 else if (b0 >= 0xE0) 3 else if (b0 >= 0xC0) 2 else 1;
    if (len == 1 or i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp: u21 = switch (len) {
        2 => (@as(u21, b0 & 0x1F) << 6) | (s[i.* + 1] & 0x3F),
        3 => (@as(u21, b0 & 0x0F) << 12) | (@as(u21, s[i.* + 1] & 0x3F) << 6) | (s[i.* + 2] & 0x3F),
        else => (@as(u21, b0 & 0x07) << 18) | (@as(u21, s[i.* + 1] & 0x3F) << 12) |
            (@as(u21, s[i.* + 2] & 0x3F) << 6) | (s[i.* + 3] & 0x3F),
    };
    i.* += len;
    return cp;
}

/// Index of the first byte of the last codepoint (backspace target).
fn lastCpStart(s: []const u8) usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xC0) != 0x80) return i;
    }
    return 0;
}

/// Text advance width in pixels (Canvas.textWidth's math without a Canvas —
/// layout runs before any buffer exists).
fn measure(font: *font_mod.Font, text: []const u8) i64 {
    var total: i64 = 0;
    var i: usize = 0;
    while (nextCp(text, &i)) |cp| {
        total += (font.glyph(cp) catch continue).advance_x;
    }
    return total;
}

/// Case-insensitive ASCII substring (search matching).
fn containsCI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// First word of a launch command, shown on the dash pill.
fn favLabel(cmd: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
    return cmd[0..end];
}

fn hitEq(a: ?Hit, b: ?Hit) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.kind == b.?.kind and a.?.index == b.?.index;
}

// --- wl_output registry bookkeeping ----------------------------------------

/// The registry's outputs plus their `wl_output.name` (v4) names — the
/// connector names Hyprland also prints in its JSON, which is how the
/// focused monitor from hyprctl maps onto a real wl_output. Lives in
/// main's Globals; the Overview borrows a pointer (process lifetime).
pub const OutputSet = struct {
    pub const MAX: usize = 8;

    /// Listener context: wl callbacks hand us one pointer, so each output
    /// gets a slot that knows its own index.
    pub const Slot = struct { set: *OutputSet, idx: usize };

    list: [MAX]*wl.Output = undefined,
    names: [MAX][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** MAX,
    slots: [MAX]Slot = undefined,
    count: usize = 0,

    pub fn add(self: *OutputSet, output: *wl.Output) ?*Slot {
        if (self.count >= MAX) return null;
        const idx = self.count;
        self.list[idx] = output;
        self.slots[idx] = .{ .set = self, .idx = idx };
        self.count += 1;
        return &self.slots[idx];
    }

    pub fn listener(_: *wl.Output, event: wl.Output.Event, slot: *Slot) void {
        switch (event) {
            .name => |e| {
                const name = std.mem.sliceTo(e.name, 0);
                const dst = &slot.set.names[slot.idx];
                const n = @min(name.len, dst.len - 1);
                @memcpy(dst[0..n], name[0..n]);
                dst[n] = 0;
            },
            .geometry, .mode, .done, .scale, .description => {},
        }
    }

    pub fn find(self: *const OutputSet, name: []const u8) ?*wl.Output {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, std.mem.sliceTo(self.names[i][0..], 0), name)) return self.list[i];
        }
        return null;
    }
};

// --- Hyprland IPC (same socket dance as the bar) ----------------------------

fn unixAddr(path: []const u8) !std.os.linux.sockaddr.un {
    var addr: std.os.linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn connectUnixSocket(path: []const u8) !posix.fd_t {
    const raw = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (raw < 0) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw);
    errdefer _ = posix.system.close(fd);
    const addr = try unixAddr(path);
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un)) != 0) return error.ConnectFailed;
    return fd;
}

/// One request/response to Hyprland's `.socket.sock`: write `command`, read
/// until the compositor closes (fresh connection per request, like hyprctl).
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
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        if (list.items.len > 4 * 1024 * 1024) break; // sanity cap
    }
    return list.toOwnedSlice(gpa);
}

/// `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`.
fn hyprSockPath(buf: []u8) ?[]const u8 {
    const runtime_dir = std.mem.sliceTo(getenv("XDG_RUNTIME_DIR") orelse return null, 0);
    const sig = std.mem.sliceTo(getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return null, 0);
    return std.fmt.bufPrint(buf, "{s}/hypr/{s}/.socket.sock", .{ runtime_dir, sig }) catch null;
}

/// Fire a Lua-bridge dispatch and report success (reply starts with "ok").
fn dispatchOk(sock_path: []const u8, cmd: []const u8) bool {
    const resp = hyprctlRequest(std.heap.page_allocator, sock_path, cmd) catch return false;
    defer std.heap.page_allocator.free(resp);
    return std.mem.startsWith(u8, resp, "ok");
}

// --- hyprctl JSON shapes (only the fields we read; unknown keys ignored) ----

const HpMonitor = struct {
    id: i32 = 0,
    name: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    scale: f64 = 1.0,
    focused: bool = false,
    activeWorkspace: struct { id: i32 = 0 } = .{},
};

const HpClient = struct {
    address: []const u8 = "",
    mapped: bool = false,
    hidden: bool = false,
    at: [2]i32 = .{ 0, 0 },
    size: [2]i32 = .{ 0, 0 },
    workspace: struct { id: i32 = 0 } = .{},
    class: []const u8 = "",
    title: []const u8 = "",
    monitor: i32 = 0,
    pinned: bool = false,
};

const HpWorkspace = struct {
    id: i32 = 0,
    name: []const u8 = "",
    monitor: []const u8 = "",
};

const LayerRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    namespace: []const u8 = "",
};
const LayerLevels = std.json.ArrayHashMap([]LayerRect);
const LayerMonitor = struct { levels: LayerLevels = .{} };
const LayersRoot = std.json.ArrayHashMap(LayerMonitor);

// --- overview data model ----------------------------------------------------

/// One window on the focused workspace (the grid).
const Win = struct {
    addr: [24]u8 = undefined,
    addr_len: usize = 0,
    class: [64]u8 = undefined,
    class_len: usize = 0,
    title: [192]u8 = undefined,
    title_len: usize = 0,
    x: i32 = 0, // global logical coords (hyprctl `at`/`size`)
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    fn addrSlice(self: *const Win) []const u8 {
        return self.addr[0..self.addr_len];
    }
    fn classSlice(self: *const Win) []const u8 {
        return self.class[0..self.class_len];
    }
    fn titleSlice(self: *const Win) []const u8 {
        return self.title[0..self.title_len];
    }
    /// Label under the thumbnail: class, falling back to the title.
    fn labelSlice(self: *const Win) []const u8 {
        if (self.class_len > 0) return self.classSlice();
        if (self.title_len > 0) return self.titleSlice();
        return "window";
    }
};

/// Rect-only client record for workspace-strip schematics (any workspace).
const Client = struct { ws: i32, x: i32, y: i32, w: i32, h: i32 };

const Ws = struct {
    id: i32,
    name: [16]u8 = undefined,
    name_len: usize = 0,
    active: bool = false,

    fn nameSlice(self: *const Ws) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// One grid cell: layout rects + the cached scaled thumbnail.
const Tile = struct {
    win: usize = 0,
    cell: widgets_mod.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    thumb: widgets_mod.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    buf: ?[]u32 = null,
};

const HitKind = enum { backdrop, search, tile, ws, fav };
const Hit = struct { kind: HitKind, index: usize = 0 };

pub const Anim = enum { closed, capturing, mapping, opening, open, closing };

pub const Overview = struct {
    // Wiring (borrowed from main for the process lifetime).
    gpa: std.mem.Allocator,
    font: *font_mod.Font,
    theme: *const widgets_mod.Theme,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    layer_shell: *zwlr.LayerShellV1,
    screencopy: ?*zwlr.ScreencopyManagerV1,
    outputs: *const OutputSet,
    favs: []const []const u8 = &.{},

    // Surface (null while closed).
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,

    // Animation.
    anim: Anim = .closed,
    progress: f64 = 0,
    anim_from: f64 = 0,
    anim_target: f64 = 1,
    anim_start_ms: i64 = 0,
    /// Close requested while still waiting for the first configure: teardown
    /// happens inside the configure handler (destroying a layer surface with
    /// its configure still queued would be a client-side protocol error).
    close_pending: bool = false,

    // Screencopy capture.
    frame: ?*zwlr.ScreencopyFrameV1 = null,
    cap_pool: ?*wl.ShmPool = null,
    cap_buffer: ?*wl.Buffer = null,
    cap_fd: posix.fd_t = -1,
    cap_map: ?[]align(std.heap.page_size_min) u8 = null, // the snapshot on ready
    cap_w: u32 = 0,
    cap_h: u32 = 0,
    cap_stride: u32 = 0,
    cap_yinvert: bool = false,
    cap_xrgb: bool = false,
    capture_deadline: i64 = 0,

    // Target output + geometry (global logical origin from hyprctl).
    out_name: [64]u8 = [_]u8{0} ** 64,
    out_output: ?*wl.Output = null,
    out_x: i32 = 0,
    out_y: i32 = 0,
    logical_w: i32 = 1920,
    logical_h: i32 = 1080,
    active_ws: i32 = 0,
    /// Bar strip in output-local coords (subtracted from the input region
    /// and skipped by the dim paint so the bar stays the bar).
    bar: ?widgets_mod.Rect = null,

    // Workspace data.
    wins: [MAX_WINS]Win = undefined,
    win_count: usize = 0,
    all: [MAX_CLIENTS]Client = undefined,
    all_count: usize = 0,
    wss: [MAX_WS]Ws = undefined,
    ws_count: usize = 0,

    // Search + selection.
    query: [128]u8 = undefined,
    query_len: usize = 0,
    sel: usize = 0,
    hover: ?Hit = null,
    press: ?Hit = null,
    px: i32 = 0,
    py: i32 = 0,

    // Layout (built on configure).
    search_rect: widgets_mod.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    ws_rects: [MAX_WS]widgets_mod.Rect = undefined,
    grid_zone: widgets_mod.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    fav_rects: [MAX_FAVS]widgets_mod.Rect = undefined,
    fav_count: usize = 0,
    cols: usize = 1,
    tiles: [MAX_WINS]Tile = undefined,
    tile_count: usize = 0,
    /// Cached scaled snapshot for the active workspace's strip thumb.
    strip_buf: ?[]u32 = null,
    strip_w: i64 = 0,
    strip_h: i64 = 0,

    // --- lifecycle ----------------------------------------------------------

    pub fn deinit(self: *Overview) void {
        self.abortCapture();
        self.teardown();
    }

    /// Toggle entry point (IPC "overview toggle", Alt+W).
    pub fn toggle(self: *Overview) bool {
        if (self.anim == .closing) return self.resumeOpening();
        if (self.anim == .closed) return self.open();
        self.close();
        return true;
    }

    /// Open (no-op if already opening/open). Returns false when the hyprctl
    /// side failed — the caller reports that to the CLI.
    pub fn open(self: *Overview) bool {
        if (self.anim == .closing) return self.resumeOpening();
        if (self.anim != .closed) return true;
        if (self.outputs.count == 0) {
            logging.warn("overview: no wl outputs — cannot open", .{});
            return false;
        }
        if (!self.fetchState()) {
            logging.err("overview: hyprctl query failed — not opening", .{});
            return false;
        }
        // Snapshot BEFORE mapping: capturing after would screenshot our own
        // dim overlay instead of the windows underneath.
        if (self.screencopy) |mgr| {
            const output = self.out_output orelse self.outputs.list[0];
            const frame = mgr.captureOutput(0, output) catch |err| {
                logging.warn("overview: capture_output failed: {}", .{err});
                self.mapNow();
                return true;
            };
            self.frame = frame;
            frame.setListener(*Overview, captureListener, self);
            self.anim = .capturing;
            self.capture_deadline = nowMs() + CAPTURE_TIMEOUT_MS;
        } else {
            logging.warn("overview: compositor lacks zwlr_screencopy — cards only", .{});
            self.mapNow();
        }
        return true;
    }

    /// Begin the close animation (idempotent).
    pub fn close(self: *Overview) void {
        switch (self.anim) {
            .closed => {},
            .capturing => {
                self.abortCapture();
                self.anim = .closed;
            },
            // First configure not yet dispatched: teardown from inside its
            // handler instead of destroying a surface with events queued.
            .mapping => self.close_pending = true,
            .opening, .open => {
                self.anim = .closing;
                self.anim_from = self.progress;
                self.anim_target = 0;
                self.anim_start_ms = nowMs();
            },
            .closing => {},
        }
    }

    /// Reverse a close that's still in flight (fast double-tap toggle).
    fn resumeOpening(self: *Overview) bool {
        self.anim = .opening;
        self.anim_from = self.progress;
        self.anim_target = 1;
        self.anim_start_ms = nowMs();
        return true;
    }

    /// True while the overview surface owns the keyboard.
    pub fn takesKeys(self: *const Overview) bool {
        return self.surface != null and (self.anim == .opening or self.anim == .open);
    }

    // --- state fetch --------------------------------------------------------

    /// Pull the focused monitor, its windows, the strip's workspaces, and the
    /// bar hole from Hyprland IPC. Monitors are all-or-nothing; the rest
    /// degrades (no bar hole, no schematics) instead of failing the open.
    fn fetchState(self: *Overview) bool {
        var sock_buf: [256]u8 = undefined;
        const sock = hyprSockPath(&sock_buf) orelse {
            logging.warn("overview: no Hyprland socket (XDG_RUNTIME_DIR/HYPRLAND_INSTANCE_SIGNATURE?)", .{});
            return false;
        };

        // 1) monitors — which output is focused, and its global origin.
        const mon_bytes = hyprctlRequest(self.gpa, sock, "j/monitors") catch |err| {
            logging.err("overview: j/monitors failed: {}", .{err});
            return false;
        };
        defer self.gpa.free(mon_bytes);
        const mons = std.json.parseFromSliceLeaky([]HpMonitor, self.gpa, mon_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            logging.err("overview: monitors JSON: {}", .{err});
            return false;
        };
        defer {
            for (mons) |m| self.gpa.free(m.name);
            self.gpa.free(mons);
        }
        var focused: ?*const HpMonitor = null;
        for (mons) |*m| {
            if (m.focused) {
                focused = m;
                break;
            }
        }
        if (focused == null and mons.len > 0) focused = &mons[0];
        const mon = focused orelse {
            logging.warn("overview: no monitors reported", .{});
            return false;
        };
        const n = @min(mon.name.len, self.out_name.len - 1);
        @memcpy(self.out_name[0..n], mon.name[0..n]);
        self.out_name[n] = 0;
        self.out_x = mon.x;
        self.out_y = mon.y;
        const scale = if (mon.scale > 0.0) mon.scale else 1.0;
        const lw = @round(@as(f64, @floatFromInt(mon.width)) / scale);
        const lh = @round(@as(f64, @floatFromInt(mon.height)) / scale);
        self.logical_w = @intFromFloat(@max(lw, 1.0));
        self.logical_h = @intFromFloat(@max(lh, 1.0));
        self.active_ws = mon.activeWorkspace.id;
        const out_name = std.mem.sliceTo(self.out_name[0..], 0);
        self.out_output = self.outputs.find(out_name) orelse blk: {
            if (self.outputs.count > 0) {
                logging.warn("overview: wl_output \"{s}\" not in registry — using first", .{out_name});
                break :blk self.outputs.list[0];
            }
            break :blk null;
        };
        if (self.out_output == null) return false;

        // 2) clients — the grid (active workspace) + strip schematics.
        self.win_count = 0;
        self.all_count = 0;
        const cli_bytes = hyprctlRequest(self.gpa, sock, "j/clients") catch |err| {
            logging.err("overview: j/clients failed: {}", .{err});
            return true; // monitors worked; an empty grid is a valid fallback
        };
        defer self.gpa.free(cli_bytes);
        const clients = std.json.parseFromSliceLeaky([]HpClient, self.gpa, cli_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            logging.err("overview: clients JSON: {}", .{err});
            return true;
        };
        defer {
            for (clients) |c| {
                self.gpa.free(c.address);
                self.gpa.free(c.class);
                self.gpa.free(c.title);
            }
            self.gpa.free(clients);
        }
        for (clients) |c| {
            if (self.all_count < MAX_CLIENTS) {
                self.all[self.all_count] = .{
                    .ws = c.workspace.id,
                    .x = c.at[0],
                    .y = c.at[1],
                    .w = c.size[0],
                    .h = c.size[1],
                };
                self.all_count += 1;
            }
            if (!c.mapped or c.hidden) continue;
            if (c.workspace.id != self.active_ws) continue;
            if (c.size[0] <= 0 or c.size[1] <= 0) continue;
            if (self.win_count >= MAX_WINS) continue;
            var win = Win{};
            win.x = c.at[0];
            win.y = c.at[1];
            win.w = c.size[0];
            win.h = c.size[1];
            const al = @min(c.address.len, win.addr.len);
            @memcpy(win.addr[0..al], c.address[0..al]);
            win.addr_len = al;
            const cl = @min(c.class.len, win.class.len);
            @memcpy(win.class[0..cl], c.class[0..cl]);
            win.class_len = cl;
            const tl = @min(c.title.len, win.title.len);
            @memcpy(win.title[0..tl], c.title[0..tl]);
            win.title_len = tl;
            self.wins[self.win_count] = win;
            self.win_count += 1;
        }
        // Left-to-right reading order for a stable grid.
        std.sort.insertion(Win, self.wins[0..self.win_count], {}, struct {
            fn less(_: void, a: Win, b: Win) bool {
                if (a.x != b.x) return a.x < b.x;
                return a.y < b.y;
            }
        }.less);

        // 3) workspaces — this monitor's strip (special ws ids are negative).
        self.ws_count = 0;
        const ws_bytes = hyprctlRequest(self.gpa, sock, "j/workspaces") catch |err| {
            logging.warn("overview: j/workspaces failed: {}", .{err});
            return true;
        };
        defer self.gpa.free(ws_bytes);
        const wss = std.json.parseFromSliceLeaky([]HpWorkspace, self.gpa, ws_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            logging.warn("overview: workspaces JSON: {}", .{err});
            return true;
        };
        defer {
            for (wss) |w| {
                self.gpa.free(w.name);
                self.gpa.free(w.monitor);
            }
            self.gpa.free(wss);
        }
        for (wss) |w| {
            if (w.id < 0) continue; // special workspaces
            if (self.ws_count >= MAX_WS) break;
            if (!std.mem.eql(u8, w.monitor, out_name) and w.id != self.active_ws) continue;
            var ws = Ws{ .id = w.id, .active = w.id == self.active_ws };
            const nl = @min(w.name.len, ws.name.len);
            @memcpy(ws.name[0..nl], w.name[0..nl]);
            ws.name_len = nl;
            self.wss[self.ws_count] = ws;
            self.ws_count += 1;
        }
        std.sort.insertion(Ws, self.wss[0..self.ws_count], {}, struct {
            fn less(_: void, a: Ws, b: Ws) bool {
                return a.id < b.id;
            }
        }.less);
        if (self.ws_count == 0) { // paranoid: never an empty strip
            self.wss[0] = .{ .id = self.active_ws, .active = true };
            self.ws_count = 1;
        }

        // 4) layers — the bar's rect (the input/dim hole).
        self.bar = null;
        const lay_bytes = hyprctlRequest(self.gpa, sock, "j/layers") catch |err| {
            logging.warn("overview: j/layers failed: {}", .{err});
            return true;
        };
        defer self.gpa.free(lay_bytes);
        var root = std.json.parseFromSliceLeaky(LayersRoot, self.gpa, lay_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            logging.warn("overview: layers JSON: {}", .{err});
            return true;
        };
        defer {
            var rit = root.map.iterator();
            while (rit.next()) |kv| {
                var lit = kv.value_ptr.levels.map.iterator();
                while (lit.next()) |lkv| {
                    for (lkv.value_ptr.*) |lr| self.gpa.free(lr.namespace);
                    self.gpa.free(lkv.value_ptr.*);
                }
                kv.value_ptr.levels.deinit(self.gpa);
            }
            root.deinit(self.gpa);
        }
        if (root.map.get(out_name)) |entry| {
            var lit = entry.levels.map.iterator();
            outer: while (lit.next()) |lkv| {
                for (lkv.value_ptr.*) |lr| {
                    if (std.mem.eql(u8, lr.namespace, "simpbar")) {
                        self.bar = .{
                            .x = lr.x - self.out_x,
                            .y = lr.y - self.out_y,
                            .w = @intCast(@max(lr.w, 0)),
                            .h = @intCast(@max(lr.h, 0)),
                        };
                        break :outer;
                    }
                }
            }
        }
        return true;
    }

    // --- capture ------------------------------------------------------------

    fn abortCapture(self: *Overview) void {
        if (self.frame) |f| {
            f.destroy();
            self.frame = null;
        }
        if (self.cap_buffer) |b| {
            b.destroy();
            self.cap_buffer = null;
        }
        if (self.cap_pool) |p| {
            p.destroy();
            self.cap_pool = null;
        }
        if (self.cap_fd >= 0) {
            _ = posix.system.close(self.cap_fd);
            self.cap_fd = -1;
        }
        if (self.cap_map) |m| {
            posix.munmap(m);
            self.cap_map = null;
        }
    }

    /// Capture failed or timed out: no snapshot, cards fallback.
    fn captureFailed(self: *Overview, why: []const u8) void {
        logging.warn("overview: screencopy failed ({s}) — falling back to cards", .{why});
        self.abortCapture();
        self.mapNow();
    }

    fn captureListener(_: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, self: *Overview) void {
        switch (event) {
            .buffer => |b| self.onCaptureBuffer(b.format, b.width, b.height, b.stride),
            .flags => |f| self.cap_yinvert = f.flags.y_invert,
            .ready => self.onCaptureReady(),
            .failed => self.captureFailed("compositor reported failure"),
            .damage, .linux_dmabuf, .buffer_done => {}, // v1 clients never see these
        }
    }

    fn onCaptureBuffer(self: *Overview, format: wl.Shm.Format, w: u32, h: u32, stride: u32) void {
        if (self.frame == null or self.cap_pool != null) return; // already set up
        if (format != .argb8888 and format != .xrgb8888) {
            self.captureFailed("unsupported wl_shm format");
            return;
        }
        if (w == 0 or h == 0 or stride < w * 4 or h > 16384) {
            self.captureFailed("bogus buffer geometry");
            return;
        }
        const size: usize = @as(usize, stride) * h;
        const fd = posix.memfd_create("simpbar-ov-capture", 0) catch |err| {
            self.captureFailed(@errorName(err));
            return;
        };
        self.cap_fd = fd;
        switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => {
                self.captureFailed("ftruncate");
                return;
            },
        }
        const map = posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch |err| {
            self.captureFailed(@errorName(err));
            return;
        };
        self.cap_map = map;
        self.cap_w = w;
        self.cap_h = h;
        self.cap_stride = stride;
        self.cap_xrgb = format == .xrgb8888;

        const pool = self.shm.createPool(fd, @intCast(size)) catch |err| {
            self.captureFailed(@errorName(err));
            return;
        };
        self.cap_pool = pool;
        const buf = pool.createBuffer(0, @intCast(w), @intCast(h), @intCast(stride), format) catch |err| {
            self.captureFailed(@errorName(err));
            return;
        };
        self.cap_buffer = buf;
        if (self.frame) |f| f.copy(buf); // -> flags + ready (or failed)
    }

    fn onCaptureReady(self: *Overview) void {
        if (self.frame) |f| {
            f.destroy();
            self.frame = null;
        }
        // The pixels live in our mmap — the pool/buffer objects did their
        // job; the mapping outlives them.
        if (self.cap_buffer) |b| {
            b.destroy();
            self.cap_buffer = null;
        }
        if (self.cap_pool) |p| {
            p.destroy();
            self.cap_pool = null;
        }
        if (self.cap_fd >= 0) {
            _ = posix.system.close(self.cap_fd);
            self.cap_fd = -1;
        }
        logging.step("overview: snapshot {d}x{d} (yinv={})", .{ self.cap_w, self.cap_h, self.cap_yinvert });
        self.mapNow();
    }

    /// Called from the host poll loop: a capture that never answers falls
    /// back to cards, and the open/close animation advances on the tick.
    pub fn pollTimeout(self: *Overview, now: i64) void {
        switch (self.anim) {
            .capturing => if (now >= self.capture_deadline) self.captureFailed("timeout"),
            .opening, .closing => self.animateTo(now),
            else => {},
        }
    }

    /// Next instant the host poll loop must wake us: the capture deadline,
    /// or the next animation tick while opening/closing.
    pub fn deadline(self: *const Overview) ?i64 {
        switch (self.anim) {
            .capturing => return self.capture_deadline,
            .opening, .closing => return nowMs() + FRAME_MS,
            else => return null,
        }
    }

    // --- surface map/teardown ----------------------------------------------

    /// Create the overlay layer surface and commit it empty; the compositor
    /// answers with configure, which paints frame 0 and starts the animation.
    fn mapNow(self: *Overview) void {
        if (self.surface != null) return;
        const output = self.out_output orelse self.outputs.list[0];
        const surface = self.compositor.createSurface() catch |err| {
            logging.err("overview: createSurface failed: {}", .{err});
            self.anim = .closed;
            return;
        };
        const layer_surface = self.layer_shell.getLayerSurface(
            surface,
            output,
            .overlay,
            "simpbar-shell-overview",
        ) catch |err| {
            logging.err("overview: getLayerSurface failed: {}", .{err});
            surface.destroy();
            self.anim = .closed;
            return;
        };
        self.surface = surface;
        self.layer_surface = layer_surface;
        layer_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer_surface.setExclusiveZone(0);
        // Exclusive: the overview owns the keyboard while open (search input);
        // keys route here until the surface is destroyed.
        layer_surface.setKeyboardInteractivity(.exclusive);
        layer_surface.setListener(*Overview, layerListener, self);
        self.applyInputRegion();
        self.anim = .mapping;
        self.configured = false;
        surface.commit();
    }

    /// Input = everything except the bar strip (clicks there fall through
    /// to the bar on the top layer; the dim paint skips it too).
    fn applyInputRegion(self: *Overview) void {
        const surface = self.surface orelse return;
        const region = self.compositor.createRegion() catch return;
        defer region.destroy();
        region.add(0, 0, @intCast(self.logical_w), @intCast(self.logical_h));
        if (self.bar) |b| region.subtract(b.x, b.y, @intCast(b.w), @intCast(b.h));
        surface.setInputRegion(region);
    }

    /// Destroy the surface and free everything overview-owned.
    fn teardown(self: *Overview) void {
        if (self.layer_surface) |ls| {
            ls.destroy();
            self.layer_surface = null;
        }
        if (self.surface) |s| {
            s.destroy();
            self.surface = null;
        }
        self.configured = false;
        self.width = 0;
        self.height = 0;
        self.abortCapture();
        self.freeTiles();
        self.anim = .closed;
        self.progress = 0;
        self.close_pending = false;
        self.hover = null;
        self.press = null;
        self.query_len = 0; // GNOME forgets the query when the overview closes
        self.sel = 0;
    }

    fn layerListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Overview) void {
        switch (event) {
            .configure => |cfg| {
                if (self.layer_surface) |ls| ls.ackConfigure(cfg.serial);
                if (cfg.width > 0) self.width = cfg.width;
                if (cfg.height > 0) self.height = cfg.height;
                if (self.close_pending) {
                    self.close_pending = false;
                    self.teardown();
                    return;
                }
                const first = !self.configured;
                self.configured = true;
                self.applyInputRegion();
                self.layout();
                self.buildTiles();
                if (first and self.anim == .mapping) {
                    self.anim = .opening;
                    self.anim_from = 0;
                    self.anim_target = 1;
                    self.anim_start_ms = nowMs();
                    logging.step("overview: mapped {d}x{d} — animating in", .{ self.width, self.height });
                }
                self.paint();
            },
            .closed => {
                // Compositor asked us to go (output gone): drop everything.
                logging.step("overview: compositor closed the layer surface", .{});
                self.teardown();
            },
        }
    }

    // --- animation ----------------------------------------------------------

    /// Advance the open/close fade — absolute-time based, so it's safe to
    /// call from any poll tick (idempotent within a frame). The host wakes
    /// us every FRAME_MS while animating; no wl_callback dance, which
    /// matters because frame 0 is fully transparent and a compositor owes
    /// no callback for a surface it has nothing to show for yet.
    fn animateTo(self: *Overview, now: i64) void {
        // Torn down between ticks: nothing left to animate.
        if (self.surface == null) return;
        if (self.anim != .opening and self.anim != .closing) return;
        const dur: f64 = @floatFromInt(if (self.anim == .opening) OPEN_MS else CLOSE_MS);
        const t = @as(f64, @floatFromInt(now - self.anim_start_ms)) / dur;
        self.progress = self.anim_from + (self.anim_target - self.anim_from) * easeOut(t);
        if (t >= 1.0) {
            if (self.anim == .opening) {
                self.anim = .open;
                self.progress = 1;
            } else {
                // Close finished; the final frame would be fully transparent
                // anyway, so skip straight to teardown.
                self.teardown();
                return;
            }
        }
        self.paint();
    }

    // --- layout -------------------------------------------------------------

    fn favPillW(self: *const Overview, i: usize) i64 {
        return measure(self.font, favLabel(self.favs[i])) + 28;
    }

    fn layout(self: *Overview) void {
        const w: i64 = self.width;
        const h: i64 = self.height;
        if (w == 0 or h == 0) return;
        const lh = widgets_mod.lineH(self.font);

        // Search box: top center.
        self.search_rect = .{
            .x = @intCast(@max(@divTrunc(w - SEARCH_W, 2), 0)),
            .y = 24,
            .w = @intCast(@min(SEARCH_W, w)),
            .h = @intCast(SEARCH_H),
        };

        // Workspace strip: centered row under the search box.
        const ws_n: i64 = @intCast(self.ws_count);
        const strip_total: i64 = ws_n * STRIP_THUMB_W + @max(ws_n - 1, 0) * STRIP_GAP;
        var x0: i64 = @max(@divTrunc(w - strip_total, 2), 0);
        var i: usize = 0;
        while (i < self.ws_count) : (i += 1) {
            self.ws_rects[i] = .{
                .x = @intCast(x0),
                .y = @intCast(STRIP_Y),
                .w = @intCast(STRIP_THUMB_W),
                .h = @intCast(STRIP_THUMB_H),
            };
            x0 += STRIP_THUMB_W + STRIP_GAP;
        }

        // Dash sits just above the bar hole (or the screen edge without one).
        const bar_top: i64 = if (self.bar) |b| b.y else h;
        const dash_y: i64 = bar_top - 20 - DASH_H;

        // Window grid: the middle, between the strip labels and the dash.
        const grid_y: i64 = STRIP_Y + STRIP_THUMB_H + 6 + lh + 26;
        self.grid_zone = .{
            .x = @intCast(GRID_X),
            .y = @intCast(@max(grid_y, 0)),
            .w = @intCast(@max(w - 2 * GRID_X, 64)),
            .h = @intCast(@max(@min(dash_y - 18, h) - @max(grid_y, 0), 64)),
        };

        // Favorites dash: centered pills.
        var total: i64 = 0;
        var fi: usize = 0;
        while (fi < self.favs.len and fi < MAX_FAVS) : (fi += 1) {
            total += self.favPillW(fi);
        }
        if (fi > 0) total += @as(i64, @intCast(fi - 1)) * 10;
        var fx: i64 = @max(@divTrunc(w - total, 2), 0);
        const pill_n = fi;
        fi = 0;
        while (fi < pill_n) : (fi += 1) {
            self.fav_rects[fi] = .{
                .x = @intCast(fx),
                .y = @intCast(@max(dash_y, 0)),
                .w = @intCast(self.favPillW(fi)),
                .h = @intCast(DASH_H),
            };
            fx += self.favPillW(fi) + 10;
        }
        self.fav_count = pill_n;
    }

    // --- tiles (grid + strip thumbnails) -------------------------------------

    fn freeTiles(self: *Overview) void {
        for (0..self.tile_count) |i| {
            if (self.tiles[i].buf) |b| {
                self.gpa.free(b);
                self.tiles[i].buf = null;
            }
        }
        self.tile_count = 0;
        if (self.strip_buf) |b| {
            self.gpa.free(b);
            self.strip_buf = null;
            self.strip_w = 0;
            self.strip_h = 0;
        }
    }

    fn matchesQuery(self: *const Overview, win: *const Win) bool {
        if (self.query_len == 0) return true;
        const q = self.query[0..self.query_len];
        return containsCI(win.titleSlice(), q) or containsCI(win.classSlice(), q);
    }

    /// Rebuild the grid (on configure and on every query change).
    fn buildTiles(self: *Overview) void {
        self.freeTiles();
        if (!self.configured) return;

        // Count matches first so the column heuristic knows n.
        var idxs: [MAX_WINS]usize = undefined;
        var n: usize = 0;
        for (0..self.win_count) |wi| {
            if (n >= MAX_WINS) break;
            if (self.matchesQuery(&self.wins[wi])) {
                idxs[n] = wi;
                n += 1;
            }
        }

        const gz = self.grid_zone;
        const gw: i64 = gz.w;
        const gh: i64 = gz.h;
        if (n > 0 and gw > 0 and gh > 0) {
            // Columns tuned so cells come out roughly window-shaped (1.6:1)
            // on this wide zone: n=1->1, n=4->2, n=9->4 at 1920x760.
            const aspect_zone = @as(f64, @floatFromInt(gw)) / @as(f64, @floatFromInt(gh));
            var cols: i64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(n)) * aspect_zone / 1.6) + 0.5);
            cols = std.math.clamp(cols, 1, @as(i64, @intCast(n)));
            const rows: i64 = @divTrunc(@as(i64, @intCast(n)) + cols - 1, cols);
            self.cols = @intCast(cols);
            const cell_w = @divTrunc(gw - (cols - 1) * CELL_GAP, @max(cols, 1));
            const cell_h = @divTrunc(gh - (rows - 1) * CELL_GAP, @max(rows, 1));
            const lh = widgets_mod.lineH(self.font);
            const label_h = @max(@min(lh + 4, @divTrunc(cell_h, 4)), 0);

            var t: usize = 0;
            while (t < n) : (t += 1) {
                const wi = idxs[t];
                const win = &self.wins[wi];
                const col: i64 = @intCast(t % self.cols);
                const row: i64 = @intCast(t / self.cols);
                const cx = gz.x + @as(i32, @intCast(col * (cell_w + CELL_GAP)));
                const cy = gz.y + @as(i32, @intCast(row * (cell_h + CELL_GAP)));
                const cell = widgets_mod.Rect{
                    .x = cx,
                    .y = cy,
                    .w = @intCast(@max(cell_w, 1)),
                    .h = @intCast(@max(cell_h, 1)),
                };
                // Fit the window's aspect inside the cell minus its label.
                const aw = @max(cell_w - 8, 8);
                const ah = @max(cell_h - label_h - 8, 8);
                const ar: f64 = if (win.w > 0 and win.h > 0)
                    @as(f64, @floatFromInt(win.w)) / @as(f64, @floatFromInt(win.h))
                else
                    16.0 / 9.0;
                var tw: i64 = aw;
                var th: i64 = @as(i64, @intFromFloat(@as(f64, @floatFromInt(tw)) / ar));
                if (th > ah) {
                    th = ah;
                    tw = @as(i64, @intFromFloat(@as(f64, @floatFromInt(th)) * ar));
                }
                tw = @max(tw, 8);
                th = @max(th, 8);
                const thumb = widgets_mod.Rect{
                    .x = cx + @as(i32, @intCast(@divTrunc(cell_w - tw, 2))),
                    .y = cy + @as(i32, @intCast(@divTrunc(@max(cell_h - label_h - th, 0), 2))),
                    .w = @intCast(tw),
                    .h = @intCast(th),
                };
                self.tiles[t] = .{ .win = wi, .cell = cell, .thumb = thumb };
                self.tiles[t].buf = self.renderTileBuf(tw, th, win);
            }
            self.tile_count = n;
        } else {
            self.cols = 1;
            self.tile_count = 0;
        }
        if (self.sel >= self.tile_count) self.sel = 0;
        self.renderStripBuf();
    }

    /// Scaled, rounded thumbnail straight from the snapshot (box-filtered so
    /// text in screenshots doesn't alias into mush). Null = no snapshot or
    /// the window sits entirely off-screen — the paint draws a card instead.
    fn renderTileBuf(self: *Overview, dw: i64, dh: i64, win: *const Win) ?[]u32 {
        const map = self.cap_map orelse return null;
        if (self.cap_w == 0 or self.cap_h == 0) return null;
        const sx = @as(f64, @floatFromInt(self.cap_w)) / @as(f64, @floatFromInt(self.logical_w));
        const sy = @as(f64, @floatFromInt(self.cap_h)) / @as(f64, @floatFromInt(self.logical_h));
        var cx = @as(i64, @intFromFloat(@as(f64, @floatFromInt(win.x - self.out_x)) * sx));
        var cy = @as(i64, @intFromFloat(@as(f64, @floatFromInt(win.y - self.out_y)) * sy));
        var cw = @as(i64, @intFromFloat(@as(f64, @floatFromInt(win.w)) * sx));
        var ch = @as(i64, @intFromFloat(@as(f64, @floatFromInt(win.h)) * sy));
        if (cx < 0) {
            cw += cx;
            cx = 0;
        }
        if (cy < 0) {
            ch += cy;
            cy = 0;
        }
        if (cx + cw > self.cap_w) cw = self.cap_w - cx;
        if (cy + ch > self.cap_h) ch = self.cap_h - cy;
        if (cw <= 0 or ch <= 0) return null;
        const buf = self.gpa.alloc(u32, @as(usize, @intCast(dw * dh))) catch return null;
        renderCrop(
            buf,
            dw,
            dh,
            map,
            self.cap_w,
            self.cap_h,
            self.cap_stride,
            self.cap_yinvert,
            self.cap_xrgb,
            cx,
            cy,
            cw,
            ch,
            @intCast(self.theme.radius_px),
        );
        return buf;
    }

    /// Whole-snapshot thumb for the active workspace's strip slot.
    fn renderStripBuf(self: *Overview) void {
        const map = self.cap_map orelse return;
        if (self.cap_w == 0 or self.cap_h == 0) return;
        const dw = STRIP_THUMB_W;
        const dh = STRIP_THUMB_H;
        const buf = self.gpa.alloc(u32, @as(usize, @intCast(dw * dh))) catch return;
        renderCrop(
            buf,
            dw,
            dh,
            map,
            self.cap_w,
            self.cap_h,
            self.cap_stride,
            self.cap_yinvert,
            self.cap_xrgb,
            0,
            0,
            self.cap_w,
            self.cap_h,
            @intCast(self.theme.radius_px),
        );
        self.strip_buf = buf;
        self.strip_w = dw;
        self.strip_h = dh;
    }

    // --- input --------------------------------------------------------------

    pub fn motion(self: *Overview, x: i32, y: i32) void {
        self.px = x;
        self.py = y;
        if (self.anim != .open) return;
        const h = self.hitTest(x, y);
        const new_hover: ?Hit = switch (h.kind) {
            .backdrop, .search => null,
            else => h,
        };
        if (!hitEq(self.hover, new_hover)) {
            self.hover = new_hover;
            self.paint();
        }
    }

    pub fn leave(self: *Overview) void {
        if (self.anim != .open) return;
        if (self.hover != null) {
            self.hover = null;
            self.paint();
        }
    }

    fn hitTest(self: *const Overview, x: i32, y: i32) Hit {
        for (0..self.tile_count) |t| {
            if (self.tiles[t].cell.contains(x, y)) return .{ .kind = .tile, .index = t };
        }
        for (0..self.ws_count) |i| {
            if (self.ws_rects[i].contains(x, y)) return .{ .kind = .ws, .index = i };
        }
        for (0..self.fav_count) |i| {
            if (self.fav_rects[i].contains(x, y)) return .{ .kind = .fav, .index = i };
        }
        if (self.search_rect.contains(x, y)) return .{ .kind = .search };
        return .{ .kind = .backdrop };
    }

    /// Press+release over the same thing activates it; clicking the bare
    /// backdrop closes (the classic "click outside").
    pub fn button(self: *Overview, btn: u32, pressed: bool) void {
        if (btn != BTN_LEFT or self.anim != .open) return;
        if (pressed) {
            self.press = self.hitTest(self.px, self.py);
        } else {
            const rel = self.hitTest(self.px, self.py);
            const pr = self.press orelse return;
            self.press = null;
            if (pr.kind != rel.kind or pr.index != rel.index) return;
            switch (pr.kind) {
                .backdrop => self.close(),
                .search => {},
                .tile => self.activateTile(pr.index),
                .ws => self.activateWs(pr.index),
                .fav => self.activateFav(pr.index),
            }
        }
    }

    pub fn keyPress(self: *Overview, keycode: u32, utf32: u32, ctrl: bool) bool {
        if (!self.takesKeys()) return false;
        if (keycode == KEY_ESC) {
            if (self.query_len > 0) {
                self.query_len = 0;
                self.rebuild();
            } else {
                self.close();
            }
            return true;
        }
        if (ctrl) return true; // swallow Ctrl chords while the overview has focus
        switch (keycode) {
            KEY_BACKSPACE => {
                if (self.query_len > 0) {
                    self.query_len = lastCpStart(self.query[0..self.query_len]);
                    self.rebuild();
                }
                return true;
            },
            KEY_ENTER, KEY_KPENTER => {
                if (self.tile_count > 0) self.activateTile(@min(self.sel, self.tile_count - 1));
                return true;
            },
            KEY_TAB => {
                if (self.tile_count > 0) {
                    self.sel = (self.sel + 1) % self.tile_count;
                    self.paint();
                }
                return true;
            },
            KEY_LEFT => {
                self.moveSel(-1, 0);
                return true;
            },
            KEY_RIGHT => {
                self.moveSel(1, 0);
                return true;
            },
            KEY_UP => {
                self.moveSel(0, -1);
                return true;
            },
            KEY_DOWN => {
                self.moveSel(0, 1);
                return true;
            },
            else => {},
        }
        // Anything printable extends the query.
        if (utf32 >= 0x20 and utf32 != 0x7F and utf32 <= 0x10FFFF) {
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(utf32), &enc) catch return true;
            if (self.query_len + len <= self.query.len) {
                @memcpy(self.query[self.query_len..][0..len], enc[0..len]);
                self.query_len += len;
                logging.step("kb: ov query now '{s}' (len={d})", .{ self.query[0..self.query_len], self.query_len });
                self.rebuild();
            }
            return true;
        }
        return false;
    }

    fn moveSel(self: *Overview, dcol: i64, drow: i64) void {
        if (self.tile_count == 0) return;
        const n: i64 = @intCast(self.tile_count);
        var s: i64 = @intCast(self.sel);
        if (dcol != 0) s = std.math.clamp(s + dcol, 0, n - 1);
        if (drow != 0) s = std.math.clamp(s + drow * @as(i64, @intCast(self.cols)), 0, n - 1);
        if (s != @as(i64, @intCast(self.sel))) {
            self.sel = @intCast(s);
            self.paint();
        }
    }

    fn rebuild(self: *Overview) void {
        self.buildTiles();
        logging.step("ov: rebuild q='{s}' tiles={d} sel={d}", .{ self.query[0..self.query_len], self.tile_count, self.sel });
        self.paint();
    }

    fn activateTile(self: *Overview, t: usize) void {
        if (t >= self.tile_count) return;
        const win = &self.wins[self.tiles[t].win];
        var sock_buf: [256]u8 = undefined;
        const sock = hyprSockPath(&sock_buf) orelse {
            self.close();
            return;
        };
        var cmd_buf: [320]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "dispatch hl.dsp.focus({{ window = \"address:{s}\" }})", .{win.addrSlice()}) catch {
            self.close();
            return;
        };
        if (dispatchOk(sock, cmd)) {
            self.close();
        } else {
            // Stay open so the miss is visible, not a silent vanish.
            logging.err("overview: focus {s} failed", .{win.addrSlice()});
        }
    }

    fn activateWs(self: *Overview, i: usize) void {
        if (i >= self.ws_count) return;
        const id = self.wss[i].id;
        if (id == self.active_ws) {
            self.close();
            return;
        }
        var sock_buf: [256]u8 = undefined;
        const sock = hyprSockPath(&sock_buf) orelse {
            self.close();
            return;
        };
        var cmd_buf: [160]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "dispatch hl.dsp.focus({{ workspace = {d} }})", .{id}) catch {
            self.close();
            return;
        };
        if (dispatchOk(sock, cmd)) {
            self.close(); // the snapshot is stale after a switch — close, don't show it
        } else {
            logging.err("overview: switch to workspace {d} failed", .{id});
        }
    }

    fn activateFav(self: *Overview, i: usize) void {
        if (i >= self.fav_count) return;
        const cmd = self.favs[i];
        var zbuf: [300]u8 = undefined;
        if (cmd.len + 1 <= zbuf.len) {
            @memcpy(zbuf[0..cmd.len], cmd);
            zbuf[cmd.len] = 0;
            widgets_mod.spawnDetached(zbuf[0..cmd.len :0]);
        }
        self.close();
    }

    // --- painting -----------------------------------------------------------

    fn paint(self: *Overview) void {
        const surface = self.surface orelse return;
        if (!self.configured or self.width == 0 or self.height == 0) return;
        const w = self.width;
        const h = self.height;
        const stride = w * 4; // ARGB8888
        const size: usize = @as(usize, stride) * h;

        const fd = posix.memfd_create("simpbar-ov-frame", 0) catch |err| {
            logging.err("overview: frame memfd: {}", .{err});
            return;
        };
        defer _ = posix.system.close(fd);
        switch (posix.errno(posix.system.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => return,
        }
        const data = posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch |err| {
            logging.err("overview: frame mmap: {}", .{err});
            return;
        };
        defer posix.munmap(data);
        const pixels: [*]u32 = @ptrCast(@alignCast(data.ptr));
        // No explicit clear: a fresh ftruncate'd memfd reads as zeros.

        var c = widgets_mod.Canvas{
            .pixels = pixels,
            .width = w,
            .height = h,
            .font = self.font,
            .theme = self.theme,
        };
        const p = self.progress;
        const dy: i64 = @intFromFloat((1.0 - p) * 48.0); // content slides up into place

        // Dim backdrop — the blur itself is Hyprland's layer rule on this
        // namespace; we only darken. The bar strip is left out entirely.
        const dim_a: u32 = @intFromFloat(p * 150.0);
        if (dim_a > 0) {
            const dimcol = widgets_mod.dim(0x000000, dim_a);
            if (self.bar) |b| {
                const bw: i64 = b.w;
                const bh: i64 = b.h;
                const bx: i64 = b.x;
                const by: i64 = b.y;
                if (by > 0) c.fillRect(0, 0, w, @intCast(by), dimcol);
                const below = by + bh;
                if (below < @as(i64, @intCast(h))) c.fillRect(0, below, w, @intCast(@as(i64, @intCast(h)) - below), dimcol);
                if (bx > 0) c.fillRect(0, by, @intCast(bx), @intCast(bh), dimcol);
                const right = bx + bw;
                if (right < @as(i64, @intCast(w))) c.fillRect(right, by, @intCast(@as(i64, @intCast(w)) - right), @intCast(bh), dimcol);
            } else {
                c.fillRect(0, 0, w, h, dimcol);
            }
        }

        if (p > 0) {
            self.paintSearch(&c, dy, p);
            self.paintStrip(&c, dy, p);
            self.paintGrid(&c, dy, p);
            self.paintDash(&c, dy, p);
        }

        const pool = self.shm.createPool(fd, @intCast(size)) catch |err| {
            logging.err("overview: createPool: {}", .{err});
            return;
        };
        defer pool.destroy();
        const buffer = pool.createBuffer(0, @intCast(w), @intCast(h), @intCast(stride), .argb8888) catch |err| {
            logging.err("overview: createBuffer: {}", .{err});
            return;
        };
        defer buffer.destroy();
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, @intCast(w), @intCast(h));
        surface.commit();
    }

    /// Straight copy of a cached thumb onto the surface at 1:1 (the buffer
    /// was rendered at exactly this size), alpha-scaled by the animation.
    fn blitBuf(c: *widgets_mod.Canvas, r: widgets_mod.Rect, buf: []const u32, bw: i64, bh: i64, p: f64) void {
        var y: i64 = 0;
        while (y < bh) : (y += 1) {
            const cy = @as(i64, @intCast(r.y)) + y;
            if (cy < 0 or cy >= @as(i64, @intCast(c.height))) continue;
            var x: i64 = 0;
            while (x < bw) : (x += 1) {
                const cx = @as(i64, @intCast(r.x)) + x;
                if (cx < 0 or cx >= @as(i64, @intCast(c.width))) continue;
                const src = buf[@as(usize, @intCast(y * bw + x))];
                const a0 = (src >> 24) & 0xFF;
                if (a0 == 0) continue;
                const a: u32 = if (p >= 1.0) a0 else @intFromFloat(@as(f64, @floatFromInt(a0)) * p);
                if (a == 0) continue;
                const idx = @as(usize, @intCast(cy * @as(i64, @intCast(c.width)) + cx));
                c.pixels[idx] = widgets_mod.Canvas.blendOver(c.pixels[idx], (a << 24) | (src & 0x00FFFFFF));
            }
        }
    }

    fn paintSearch(self: *Overview, c: *widgets_mod.Canvas, dy: i64, p: f64) void {
        var r = self.search_rect;
        r.y += @intCast(dy);
        const fill = sc(widgets_mod.withAlpha(self.theme.bg_color, @min(self.theme.card_alpha + 20, 92)), p);
        const border = sc(if (self.query_len > 0) self.theme.hover_color else self.theme.border_color, p);
        c.card(r, fill, border);
        const lh = widgets_mod.lineH(self.font);
        const baseline = @as(i64, @intCast(r.y)) + @divTrunc(@as(i64, @intCast(r.h)) - lh, 2) + self.font.ascentPx();
        const tx = @as(i64, @intCast(r.x)) + widgets_mod.CARD_PAD;
        const max_w = @as(i64, @intCast(r.w)) - 2 * widgets_mod.CARD_PAD;
        if (self.query_len > 0) {
            var dst: [256]u8 = undefined;
            const text = widgets_mod.fitText(c.*, self.query[0..self.query_len], max_w, &dst);
            _ = c.drawText(tx, baseline, text, sc(self.theme.text_color, p));
        } else {
            _ = c.drawText(tx, baseline, "Search\u{2026}", sc(widgets_mod.dim(self.theme.text_color, 150), p));
        }
    }

    fn paintStrip(self: *Overview, c: *widgets_mod.Canvas, dy: i64, p: f64) void {
        for (0..self.ws_count) |i| {
            var r = self.ws_rects[i];
            r.y += @intCast(dy);
            const ws = &self.wss[i];
            const hovered = if (self.hover) |hv| hv.kind == .ws and hv.index == i else false;
            const border = if (hovered) self.theme.hover_color else if (ws.active) self.theme.text_color else self.theme.border_color;
            if (ws.active) {
                if (self.strip_buf) |buf| {
                    blitBuf(c, r, buf, self.strip_w, self.strip_h, p);
                    c.card(r, 0x00000000, sc(border, p)); // outline only
                } else {
                    c.card(r, sc(widgets_mod.withAlpha(self.theme.bg_color, self.theme.card_alpha), p), sc(border, p));
                }
            } else {
                c.card(r, sc(widgets_mod.withAlpha(self.theme.bg_color, self.theme.card_alpha), p), sc(border, p));
                self.paintSchematic(c, r, ws.id, p);
            }
            // Name label under the thumb.
            const label = ws.nameSlice();
            const tw = c.textWidth(label);
            const lx = @as(i64, @intCast(r.x)) + @divTrunc(@as(i64, @intCast(r.w)) - tw, 2);
            const lbase = @as(i64, @intCast(r.y)) + @as(i64, @intCast(r.h)) + 4 + self.font.ascentPx();
            const lcol = if (ws.active) self.theme.text_color else widgets_mod.dim(self.theme.text_color, 170);
            _ = c.drawText(lx, lbase, label, sc(lcol, p));
        }
    }

    /// Schematic miniature of another workspace: its windows as outlines
    /// mapped from the output's logical size into the strip thumb.
    fn paintSchematic(self: *const Overview, c: *widgets_mod.Canvas, r: widgets_mod.Rect, ws_id: i32, p: f64) void {
        const rx: i64 = r.x;
        const ry: i64 = r.y;
        const rw: i64 = r.w;
        const rh: i64 = r.h;
        const col = sc(widgets_mod.dim(self.theme.text_color, 130), p);
        for (0..self.all_count) |i| {
            const cl = self.all[i];
            if (cl.ws != ws_id) continue;
            const x0 = rx + @divTrunc(@as(i64, cl.x - self.out_x) * rw, @max(self.logical_w, 1));
            const y0 = ry + @divTrunc(@as(i64, cl.y - self.out_y) * rh, @max(self.logical_h, 1));
            const x1 = rx + @divTrunc(@as(i64, cl.x - self.out_x + cl.w) * rw, @max(self.logical_w, 1));
            const y1 = ry + @divTrunc(@as(i64, cl.y - self.out_y + cl.h) * rh, @max(self.logical_h, 1));
            const ex0 = std.math.clamp(x0, rx, rx + rw - 2);
            const ey0 = std.math.clamp(y0, ry, ry + rh - 2);
            const ex1 = std.math.clamp(x1, ex0 + 2, rx + rw);
            const ey1 = std.math.clamp(y1, ey0 + 2, ry + rh);
            c.fillRect(ex0, ey0, @intCast(ex1 - ex0), @intCast(ey1 - ey0), col);
        }
    }

    fn paintGrid(self: *Overview, c: *widgets_mod.Canvas, dy: i64, p: f64) void {
        const gz = self.grid_zone;
        const gzy: i64 = @as(i64, @intCast(gz.y)) + dy;
        if (self.tile_count == 0) {
            const msg: []const u8 = if (self.win_count == 0) "No windows on this workspace" else "No matches";
            const tw = c.textWidth(msg);
            const lx = @as(i64, @intCast(gz.x)) + @divTrunc(@as(i64, @intCast(gz.w)) - tw, 2);
            const lbase = gzy + @divTrunc(@as(i64, @intCast(gz.h)), 2);
            _ = c.drawText(lx, lbase, msg, sc(widgets_mod.dim(self.theme.text_color, 180), p));
            return;
        }
        const lh = widgets_mod.lineH(self.font);
        for (0..self.tile_count) |t| {
            const tile = &self.tiles[t];
            var tr = tile.thumb;
            tr.y += @intCast(dy);
            var cr = tile.cell;
            cr.y += @intCast(dy);
            const hovered = if (self.hover) |hv| hv.kind == .tile and hv.index == t else false;
            const border = if (hovered)
                self.theme.hover_color
            else if (self.sel == t)
                self.theme.holiday_color
            else
                self.theme.border_color;
            if (tile.buf) |buf| {
                blitBuf(c, tr, buf, tr.w, tr.h, p);
                c.card(tr, 0x00000000, sc(border, p)); // outline over the rounded edge
            } else {
                const fill = sc(widgets_mod.withAlpha(self.theme.bg_color, self.theme.card_alpha), p);
                c.card(tr, fill, sc(border, p));
                // Card fallback: class name where the screenshot would be.
                var fdst: [256]u8 = undefined;
                const win = &self.wins[tile.win];
                const ftext = widgets_mod.fitText(c.*, win.labelSlice(), @as(i64, @intCast(tr.w)) - 16, &fdst);
                const fw = c.textWidth(ftext);
                const fx = @as(i64, @intCast(tr.x)) + @divTrunc(@as(i64, @intCast(tr.w)) - fw, 2);
                const fbase = @as(i64, @intCast(tr.y)) + @divTrunc(@as(i64, @intCast(tr.h)) - lh, 2) + self.font.ascentPx();
                _ = c.drawText(fx, fbase, ftext, sc(widgets_mod.dim(self.theme.text_color, 200), p));
            }
            // Label under the thumbnail (inside the cell's reserved strip).
            var dst: [256]u8 = undefined;
            const win = &self.wins[tile.win];
            const text = widgets_mod.fitText(c.*, win.labelSlice(), @as(i64, @intCast(cr.w)) - 8, &dst);
            const tw = c.textWidth(text);
            const tx = @as(i64, @intCast(cr.x)) + @divTrunc(@as(i64, @intCast(cr.w)) - tw, 2);
            const tbase = @as(i64, @intCast(tr.y)) + @as(i64, @intCast(tr.h)) + 4 + self.font.ascentPx();
            _ = c.drawText(tx, tbase, text, sc(if (hovered or self.sel == t) self.theme.text_color else widgets_mod.dim(self.theme.text_color, 210), p));
        }
    }

    fn paintDash(self: *Overview, c: *widgets_mod.Canvas, dy: i64, p: f64) void {
        const lh = widgets_mod.lineH(self.font);
        for (0..self.fav_count) |i| {
            var r = self.fav_rects[i];
            r.y += @intCast(dy);
            const hovered = if (self.hover) |hv| hv.kind == .fav and hv.index == i else false;
            const alpha = @min(self.theme.card_alpha + (if (hovered) @as(u32, 25) else 0), 95);
            const fill = sc(widgets_mod.withAlpha(self.theme.bg_color, alpha), p);
            const border = sc(if (hovered) self.theme.hover_color else self.theme.border_color, p);
            c.card(r, fill, border);
            const label = favLabel(self.favs[i]);
            const tw = c.textWidth(label);
            const tx = @as(i64, @intCast(r.x)) + @divTrunc(@as(i64, @intCast(r.w)) - tw, 2);
            const baseline = @as(i64, @intCast(r.y)) + @divTrunc(@as(i64, @intCast(r.h)) - lh, 2) + self.font.ascentPx();
            _ = c.drawText(tx, baseline, label, sc(if (hovered) self.theme.text_color else widgets_mod.dim(self.theme.text_color, 220), p));
        }
    }
};

/// Crop `cx,cy,cw,ch` out of the snapshot and box-downsample it into
/// `dw*dh`, with rounded-corner alpha. Reads rows bottom-up when the
/// compositor flagged y_invert, and forces opaque alpha for xrgb.
fn renderCrop(
    dst: []u32,
    dw: i64,
    dh: i64,
    map: []const u8,
    snap_w: i64,
    snap_h: i64,
    stride_bytes: i64,
    yinvert: bool,
    xrgb: bool,
    cx: i64,
    cy: i64,
    cw: i64,
    ch: i64,
    radius_in: i64,
) void {
    const src: [*]const u32 = @ptrCast(@alignCast(map.ptr));
    const row_px = @divTrunc(stride_bytes, 4);
    const radius = @min(radius_in, @divTrunc(@min(dw, dh), 2));
    var dy: i64 = 0;
    while (dy < dh) : (dy += 1) {
        var sy0 = cy + @divTrunc(dy * ch, dh);
        var sy1 = cy + @divTrunc((dy + 1) * ch, dh);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        if (sy1 > snap_h) sy1 = snap_h;
        if (sy0 < 0) sy0 = 0;
        const stepy = @max(1, @divTrunc(sy1 - sy0, 4));
        var dx: i64 = 0;
        while (dx < dw) : (dx += 1) {
            var sx0 = cx + @divTrunc(dx * cw, dw);
            var sx1 = cx + @divTrunc((dx + 1) * cw, dw);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            if (sx1 > snap_w) sx1 = snap_w;
            if (sx0 < 0) sx0 = 0;
            const a: u32 = if (insideRounded(dx, dy, 0, 0, dw, dh, radius)) 255 else 0;
            if (sy0 >= sy1 or sx0 >= sx1) {
                dst[@intCast(dy * dw + dx)] = 0;
                continue;
            }
            const stepx = @max(1, @divTrunc(sx1 - sx0, 4));
            var sumr: u32 = 0;
            var sumg: u32 = 0;
            var sumb: u32 = 0;
            var cnt: u32 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += stepy) {
                const row = if (yinvert) snap_h - 1 - sy else sy;
                const base = row * row_px;
                var sx = sx0;
                while (sx < sx1) : (sx += stepx) {
                    var px = src[@intCast(base + sx)];
                    if (xrgb) px |= 0xFF000000;
                    sumr += (px >> 16) & 0xFF;
                    sumg += (px >> 8) & 0xFF;
                    sumb += px & 0xFF;
                    cnt += 1;
                }
            }
            if (cnt == 0) {
                dst[@intCast(dy * dw + dx)] = 0;
                continue;
            }
            const r = @divTrunc(sumr, cnt);
            const g = @divTrunc(sumg, cnt);
            const b = @divTrunc(sumb, cnt);
            dst[@intCast(dy * dw + dx)] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

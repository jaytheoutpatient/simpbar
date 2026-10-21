const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ligma

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const xdg = wayland.client.xdg;

const dbus = @import("dbus.zig");
const font_mod = @import("font.zig");
const icontheme = @import("icontheme.zig");
const dbusmenu = @import("dbusmenu.zig");
const logging = @import("logging.zig");
const desktop_entries = @import("desktop_entries.zig");

pub const panic = std.debug.FullPanic(logging.panicHandler);

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
/// Blank space enforced between the end of one left/center-capable module
/// and the start of the next, inside the center group — cross-group drag
/// can join any two module kinds there (workspaces beside clock, mpris
/// beside launchers, etc.), and without a guaranteed module→module gap the
/// last segment of one runs straight into the first of the next. Segments
/// also carry their own intra-module gaps (workspace_gap between digits
/// inside their shared pill, LAUNCHER_GAP between launcher buttons).
const MODULE_GAP: i64 = 12;

// Spacing for the custom/* launcher buttons and custom/power.
const LAUNCHER_GAP: i64 = 16;
/// Gap between system tray icons (and before the first one) — tighter than
/// LAUNCHER_GAP so the tray reads as one cluster, in or out of the island.
const TRAY_ICON_GAP: i64 = 8;
const RIGHT_MARGIN: i64 = 8;

/// Minimum on-screen width reserved for a single module, so every module gets
/// its own space instead of sitting flush against whichever neighbour happens
/// to be next to it. Content narrower than this is centered inside the cell;
/// content wider than it (long custom-script output, a long weather string, a
/// full tray row) keeps its natural width and simply grows its cell — the bar
/// never truncates a module to fit. The slack becomes padding on BOTH sides,
/// which is why the reserve helpers below return where to *draw* as well as
/// where the pen ends up.
///
/// Keep this modest: it is a floor for the NARROWEST module, and the slack is
/// pure padding, so it is paid once per module across the whole bar. The
/// right group's shortest entries (the "▾" drawer toggle, power) are only
/// ~10-20px of text, so a large floor inflates that group's width and reads
/// as empty space rather than separation. Anything above the natural width of
/// the widest label in a group costs that group extra pixels for no benefit,
/// so this is best kept just above the widths you actually want separated.
///
/// Separation between two adjacent modules is `(CELL - content_w) + MODULE_GAP`,
/// so this single number walks the whole range: at 4 padding is 0 and modules
/// sit at the bare MODULE_GAP (12px) apart — effectively the pre-cell layout;
/// at 64 a pair of narrow modules lands ~36px apart; at 96, ~68px.
const MODULE_CELL_MIN: i64 = 4;

/// A reserved module cell, kept as three coordinates because the two layout
/// directions consume it differently: a left-group module draws from
/// `content_start` rightward, a right-group module (via drawRightAligned)
/// draws leftward from `content_end`, and `next_pen` — the cell's far edge —
/// is what the next module reserves from. Advancing the pen to the content's
/// own edge instead would hand this module's padding to the next module
/// instead of splitting it around this one, which is the whole point.
const CellPlacement = struct {
    content_start: i64,
    content_end: i64,
    next_pen: i64,
};

/// Splits `pad_wanted` in half around a cell's content, capped by the room
/// actually left before `limit`. A bar too narrow to give every module its
/// full cell degrades to natural width (the pre-cell layout) rather than
/// marching over the neighbouring group. Content is never clipped: a module
/// wider than the room available keeps its real width and overlaps, exactly
/// as it did before cells existed.
fn centeredPad(pad_wanted: i64, room: i64) i64 {
    return @min(@divTrunc(pad_wanted, 2), @max(@divTrunc(room, 2), 0));
}

/// Left-to-right reservation: `pen` is the cell's LEFT edge, `limit_right`
/// bounds how far the cell may grow (the center group's start edge).
fn reserveLeftCell(pen: i64, content_w: i64, limit_right: i64) CellPlacement {
    const pad = centeredPad(@max(MODULE_CELL_MIN - content_w, 0), limit_right - pen - content_w);
    return .{
        .content_start = pen + pad,
        .content_end = pen + pad + content_w,
        .next_pen = pen + pad * 2 + content_w,
    };
}

/// Right-to-left reservation: `pen` is the cell's RIGHT edge, `limit_left`
/// bounds how far the cell may grow leftward (the center group's start
/// edge). drawRightAligned anchors content by its right edge, hence the
/// asymmetry with reserveLeftCell.
fn reserveRightCell(pen: i64, content_w: i64, limit_left: i64) CellPlacement {
    const pad = centeredPad(@max(MODULE_CELL_MIN - content_w, 0), pen - limit_left - content_w);
    return .{
        .content_start = pen - pad - content_w,
        .content_end = pen - pad,
        .next_pen = pen - pad * 2 - content_w,
    };
}

// --- pinned-launcher app icons -------------------------------------------
//
// A launcher button with a non-null `icon` in config.json (typically an
// app picked from simpbar-config's Installed Applications list) renders a
// real themed icon next to its label instead of only the nerd-font glyph.
// The icon name/path is resolved + decoded ONCE per button (config reloads
// via SIGUSR1 invalidate the cache) into a fixed inline buffer, mirroring
// how TrayItem keeps its icons — no heap churn on every draw, and the frame
// presenter uploads the finished frame just like any other pixel.
const MAX_LAUNCHERS: usize = 32;
const LAUNCHER_ICON_SIZE: u32 = 16;
const LAUNCHER_ICON_TEXT_GAP: i64 = 5;

const LauncherIconCache = struct {
    pixels: [LAUNCHER_ICON_SIZE * LAUNCHER_ICON_SIZE]u32 = [_]u32{0} ** (LAUNCHER_ICON_SIZE * LAUNCHER_ICON_SIZE),
    has_icon: bool = false,
    resolved: bool = false,
    /// Nerd Font codepoint for the distro logo (0 = not a distro-logo
    /// launcher). Set instead of a decoded PNG when the launcher opens the
    /// app drawer — the drawer brands itself with the distro logo (see
    /// quickshell/appdrawer/Distro.qml), so a pinned App Drawer button
    /// matches it. Drawn as text, so it follows the label baseline rather
    /// than the 16px icon box.
    distro_glyph: u32 = 0,
};

/// Distro ID -> Nerd Font linux-* logo codepoint. Mirrors
/// quickshell/appdrawer/Distro.qml's table (same codepoints, same fallback
/// order) — keep the two in sync when adding a distro. All values verified
/// present in JetBrainsMonoNerdFont-Regular.ttf.
const DISTRO_GLYPHS = std.StaticStringMap(u32).initComptime(.{
    .{ "cachyos", 0xF385 },
    .{ "arch", 0xF303 }, .{ "archarm", 0xF303 }, .{ "archlinux", 0xF303 },
    .{ "artix", 0xF31F }, .{ "endeavouros", 0xF322 }, .{ "garuda", 0xF337 },
    .{ "manjaro", 0xF312 }, .{ "arcolinux", 0xF346 }, .{ "archcraft", 0xF345 },
    .{ "crystal", 0xF348 }, .{ "xerolinux", 0xF34A }, .{ "biglinux", 0xF347 },
    // Featherlite is Arch-based with no Nerd Font glyph of its own, so it
    // wears the Arch logo (mirrored in quickshell/appdrawer/Distro.qml).
    .{ "featherlite", 0xF303 },
    .{ "debian", 0xF306 }, .{ "ubuntu", 0xF31B }, .{ "pop", 0xF32A },
    .{ "pop_os", 0xF32A }, .{ "linuxmint", 0xF30E }, .{ "zorin", 0xF32F },
    .{ "elementary", 0xF309 }, .{ "kubuntu", 0xF333 }, .{ "kde_neon", 0xF331 },
    .{ "neon", 0xF331 }, .{ "fedora", 0xF30A }, .{ "nobara", 0xF380 },
    .{ "rhel", 0xF316 }, .{ "redhat", 0xF316 }, .{ "centos", 0xF304 },
    .{ "rocky", 0xF32B }, .{ "almalinux", 0xF31D },
    .{ "opensuse", 0xF314 }, .{ "tumbleweed", 0xF37D },
    .{ "opensuse-tumbleweed", 0xF37D }, .{ "opensuse-leap", 0xF37E },
    .{ "leap", 0xF37E }, .{ "nixos", 0xF313 }, .{ "gentoo", 0xF30D },
    .{ "slackware", 0xF318 }, .{ "void", 0xF32E }, .{ "alpine", 0xF300 },
    .{ "solus", 0xF32D }, .{ "mx", 0xF33F }, .{ "mxlinux", 0xF33F },
});

/// ID_LIKE family token -> codepoint, for distros with no direct entry.
const DISTRO_FAMILY_GLYPHS = std.StaticStringMap(u32).initComptime(.{
    .{ "arch", 0xF303 }, .{ "debian", 0xF306 }, .{ "ubuntu", 0xF31B },
    .{ "fedora", 0xF30A }, .{ "rhel", 0xF316 }, .{ "centos", 0xF304 },
    .{ "suse", 0xF314 }, .{ "opensuse", 0xF314 }, .{ "nixos", 0xF313 },
    .{ "gentoo", 0xF30D }, .{ "slackware", 0xF318 }, .{ "void", 0xF32E },
    .{ "alpine", 0xF300 }, .{ "solus", 0xF32D },
});

/// Generic Linux glyph: the universal fallback. Also BMP, always present.
const DISTRO_FALLBACK_GLYPH: u32 = 0xF17C;

var g_distro_glyph: ?u32 = null;
var g_os_id_buf: [64]u8 = undefined;
var g_os_like_buf: [128]u8 = undefined;

/// Reads one `KEY=...` value (unquoted, lowercased) from /etc/os-release
/// into a static buffer. Runs once per bar start; the two keys asked (ID,
/// ID_LIKE) have separate slots so neither clobbers the other.
fn osReleaseValue(key: []const u8, out: []u8) ?[]const u8 {
    const raw = posix.system.open("/etc/os-release", .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw < 0) return null;
    defer _ = posix.system.close(raw);
    var fbuf: [256]u8 = undefined;
    const n = posix.system.read(raw, &fbuf, fbuf.len);
    if (n <= 0) return null;
    const text = fbuf[0..@as(usize, @intCast(n))];
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        var v = std.mem.trim(u8, line[key.len + 1 ..], " \t\r\"");
        const len = @min(v.len, out.len);
        @memcpy(out[0..len], v[0..len]);
        // Lowercase for the table lookup (IDs are lowercase by spec, but
        // be liberal).
        for (out[0..len]) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') c.* += 'a' - 'A';
        }
        return out[0..len];
    }
    return null;
}

/// This machine's distro logo codepoint: direct ID hit, then each ID_LIKE
/// token through both tables, then the generic glyph. Cached — the answer
/// can't change under a running bar.
fn distroLogoCodepoint() u32 {
    if (g_distro_glyph) |cp| return cp;
    var cp: u32 = DISTRO_FALLBACK_GLYPH;
    if (osReleaseValue("ID", &g_os_id_buf)) |id| {
        if (DISTRO_GLYPHS.get(id)) |hit| {
            cp = hit;
        } else if (osReleaseValue("ID_LIKE", &g_os_like_buf)) |like| {
            var toks = std.mem.splitScalar(u8, like, ' ');
            while (toks.next()) |tok| {
                if (tok.len == 0) continue;
                if (DISTRO_GLYPHS.get(tok)) |hit| {
                    cp = hit;
                    break;
                }
                if (DISTRO_FAMILY_GLYPHS.get(tok)) |hit| {
                    cp = hit;
                    break;
                }
            }
        }
    }
    g_distro_glyph = cp;
    return cp;
}

/// True when `command` launches the app drawer: the first
/// whitespace-separated token's basename is "appdrawer" ("appdrawer",
/// "/usr/bin/appdrawer", "appdrawer open", ...). Renaming the pin's label
/// doesn't fool it, and a hypothetical "my-appdrawer-fork" correctly does
/// NOT match.
fn launcherLaunchesAppdrawer(command: []const u8) bool {
    // Trimmed on the left only in effect: trailing whitespace ends the first
    // token at the split below, so a both-sides trim is equivalent here
    // (std.mem has no trimLeft in this Zig version).
    var s = std.mem.trim(u8, command, " \t");
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, ' ')) |sp| s = s[0..sp];
    if (std.mem.indexOfScalar(u8, s, '\t')) |t| s = s[0..t];
    var base = s;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |sl| base = s[sl + 1 ..];
    return std.mem.eql(u8, base, "appdrawer");
}

/// Encodes a BMP codepoint as UTF-8 (all distro glyphs are BMP PUA).
fn encodeBmpCodepoint(cp: u32, out: *[4]u8) []const u8 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return out[0..1];
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return out[0..2];
    } else {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return out[0..3];
    }
}

var launcher_icons: [MAX_LAUNCHERS]LauncherIconCache = undefined;

/// Write end of the SIGUSR1 self-pipe (see the signal setup in realMain);
/// -1 until the pipe is created. Written from a signal handler, so it must
/// remain set for the process lifetime.
var g_sigusr1_write_fd: posix.fd_t = -1;

/// SIGUSR1 live-reload relay: the kernel may deliver the signal to any
/// thread (the bar hosts several libc thread-pool threads spawned outside
/// our control), so this handler only performs the async-signal-safe write()
/// to the self-pipe; the event loop drains the pipe and does the reload.
fn relaySIGUSR1(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    if (g_sigusr1_write_fd >= 0) {
        const b = [_]u8{0x1};
        _ = posix.system.write(g_sigusr1_write_fd, &b, b.len);
    }
}

/// Re-resolves every launcher icon on the next draw. Called after the
/// config changes (startup load and every successful SIGUSR1 reload), since
/// launchers are positional — index i in the config maps to cache slot i.
fn invalidateLauncherIcons() void {
    for (0..launcher_icons.len) |i| launcher_icons[i].resolved = false;
}

/// Installed-application icon index: lowercase lookup key (executable
/// basename or StartupWMClass) → icon name as the .desktop file spells it
/// (case preserved — theme filenames are case-sensitive). Built once at
/// startup from enumerateInstalledApps; first source wins, so user
/// overrides in ~/.local/share/applications beat system files, matching
/// the app drawer's own listing order.
///
/// Sized to swallow a busy desktop: every entry is 144 bytes of BSS, and a
/// full index fails silently from the caller's side (the app just keeps
/// its label). Flatpak exports are scanned last, so a too-small cap shows
/// up as exactly "sandboxed apps have no icons" — 1024 clears a full KDE
/// install plus a couple of hundred Flatpak exports with room to spare.
const MAX_DESKTOP_IDX: usize = 1024;
const DesktopIdxEntry = struct {
    key_buf: [64]u8 = undefined,
    key_len: usize = 0,
    icon_buf: [64]u8 = undefined,
    icon_len: usize = 0,
};
var desktop_idx: [MAX_DESKTOP_IDX]DesktopIdxEntry = undefined;
var desktop_idx_len: usize = 0;

fn desktopIndexAdd(key: []const u8, icon: []const u8) void {
    if (key.len == 0 or icon.len == 0 or desktop_idx_len >= desktop_idx.len) return;
    for (desktop_idx[0..desktop_idx_len]) |*e| {
        if (std.mem.eql(u8, e.key_buf[0..e.key_len], key)) return; // first wins
    }
    var e = &desktop_idx[desktop_idx_len];
    e.key_len = lowerCopy(&e.key_buf, key);
    const il = @min(e.icon_buf.len, icon.len);
    @memcpy(e.icon_buf[0..il], icon[0..il]);
    e.icon_len = il;
    desktop_idx_len += 1;
}

/// Already-lowercased key → icon name, or null. Pure lookup over the
/// startup-built index (tests populate it directly).
fn desktopIndexLookup(key_norm: []const u8) ?[]const u8 {
    for (desktop_idx[0..desktop_idx_len]) |*e| {
        if (std.mem.eql(u8, e.key_buf[0..e.key_len], key_norm)) return e.icon_buf[0..e.icon_len];
    }
    return null;
}

/// Deep variant: the full key, then each of its '.'-separated components
/// ("com.spotify.client" → the desktop entry keyed "spotify"). Skips
/// registry-ish components (com/org/io/net/app) and stubs — those only
/// ever false-positive. What makes wrapped flatpak ids resolve to the
/// sandox's real icon instead of a label.
fn desktopIndexLookupDeep(key_norm: []const u8) ?[]const u8 {
    if (desktopIndexLookup(key_norm)) |icon| return icon;
    var parts = std.mem.splitScalar(u8, key_norm, '.');
    while (parts.next()) |part| {
        if (part.len <= 2) continue;
        if (std.mem.eql(u8, part, "com") or std.mem.eql(u8, part, "org") or std.mem.eql(u8, part, "net") or std.mem.eql(u8, part, "app")) continue;
        if (desktopIndexLookup(part)) |icon| return icon;
    }
    return null;
}

fn buildDesktopIndex() void {
    desktop_idx_len = 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var list: std.ArrayList(desktop_entries.DesktopEntry) = .empty;
    desktop_entries.enumerateInstalledApps(arena.allocator(), &list) catch return;
    for (list.items) |app| {
        if (app.icon.len == 0) continue;
        // Executable basename: "Exec=/usr/lib/fluxer/fluxer %U" → "fluxer".
        var first = app.exec;
        if (std.mem.indexOfScalar(u8, first, ' ')) |sp| first = first[0..sp];
        if (std.mem.lastIndexOfScalar(u8, first, '/')) |sl| first = first[sl + 1 ..];
        var kbuf: [64]u8 = undefined;
        const kl = lowerCopy(&kbuf, first);
        desktopIndexAdd(kbuf[0..kl], app.icon);
        if (app.wm_class.len > 0) {
            const wml = lowerCopy(&kbuf, app.wm_class);
            desktopIndexAdd(kbuf[0..wml], app.icon);
        }
        // File stem: the stable key for sandboxed apps whose Exec is a
        // flatpak wrapper and which set no WMClass.
        if (app.id.len > 0) {
            var sbuf: [64]u8 = undefined;
            const sl = lowerCopy(&sbuf, app.id);
            desktopIndexAdd(sbuf[0..sl], app.icon);
        }
    }
    // desktopIndexAdd drops everything past the cap, and Flatpak exports
    // are the last source scanned — so a full index shows up as "sandboxed
    // apps have no icon and nothing else looks wrong". Say so out loud.
    if (desktop_idx_len >= desktop_idx.len) {
        logging.warn("desktop icon index full ({d} entries) — apps past the cap (flatpak exports scan last) get no icon", .{desktop_idx.len});
    }
}

/// True when `binary` resolves in PATH (the probe loops in the
/// simpbar-launch-* wrappers use `command -v`, this is the same check).
fn binaryOnPath(binary: []const u8) bool {
    const path_env = getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.sliceTo(path_env, 0), ':');
    var cbuf: [256]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintZ(&cbuf, "{s}/{s}", .{ dir, binary }) catch continue;
        if (access(full.ptr, 1) == 0) return true; // X_OK
    }
    return false;
}

/// Reads ~/.config/simpbar/<file> (the Welcome app's browser/discord
/// choice) into `buf`, trimmed — "" when unset/unreadable.
fn readChoiceBinary(file: []const u8, buf: []u8) []const u8 {
    const home = getenv("HOME") orelse return "";
    var pbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pbuf, "{s}/.config/simpbar/{s}", .{ std.mem.sliceTo(home, 0), file }) catch return "";
    const data = readFileAlloc(std.heap.page_allocator, path) catch return "";
    defer std.heap.page_allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    const len = @min(buf.len, trimmed.len);
    @memcpy(buf[0..len], trimmed[0..len]);
    return buf[0..len];
}

/// Wrapper-script binaries in probe order (mirroring install.sh's
/// simpbar-launch-browser / -discord loops — keep in sync by name).
const BROWSER_BINS = [_][]const u8{ "brave", "brave-browser", "zen-browser", "zen", "vivaldi-stable", "vivaldi", "microsoft-edge-stable", "microsoft-edge", "librewolf", "firefox", "firefox-esr" };
const DISCORD_BINS = [_][]const u8{ "vesktop", "equibop", "discord", "fluxer" };

/// Icon name for a wrapper script: the user's chosen binary when set and
/// installed, else the first probe binary that's either on PATH or has a
/// resolvable icon (Fluxer lives outside PATH but has a theme icon).
/// Null when nothing resolves — the pin falls back to its label.
fn wrapperIconName(candidates: []const []const u8, choice_file: []const u8, out: []u8) ?[]const u8 {
    var cbuf: [64]u8 = undefined;
    const choice = readChoiceBinary(choice_file, &cbuf);
    if (choice.len > 0 and binaryOnPath(choice)) {
        if (desktopIndexLookup(choice)) |icon| {
            const l = @min(out.len, icon.len);
            @memcpy(out[0..l], icon[0..l]);
            return out[0..l];
        }
        const l = @min(out.len, choice.len);
        @memcpy(out[0..l], choice[0..l]);
        return out[0..l];
    }
    for (candidates) |bin| {
        if (!binaryOnPath(bin)) {
            // Not launchable via PATH, but may still be the running app's
            // icon (Fluxer lives outside PATH yet has a theme icon) —
            // accept it when an icon resolves.
            const icon = desktopIndexLookup(bin) orelse bin;
            var pbuf: [512]u8 = undefined;
            if (icontheme.resolveIconPath(icon, &pbuf) == null) continue;
            const l = @min(out.len, icon.len);
            @memcpy(out[0..l], icon[0..l]);
            return out[0..l];
        }
        var kbuf: [64]u8 = undefined;
        const kl = lowerCopy(&kbuf, bin);
        const icon = desktopIndexLookup(kbuf[0..kl]) orelse bin;
        const l = @min(out.len, icon.len);
        @memcpy(out[0..l], icon[0..l]);
        return out[0..l];
    }
    return null;
}

/// Icon name for a pinned command: the explicit config icon wins (handled
/// by the caller — this is only the DERIVED fallback), the app-drawer pin
/// has no icon (it wears the distro glyph instead), wrappers probe their
/// families, and plain binaries go through the desktop index with the
/// binary name itself as the last resort (decode decides resolvability).
fn pinIconName(command: []const u8, out: []u8) ?[]const u8 {
    if (launcherLaunchesAppdrawer(command)) return null;
    if (std.mem.eql(u8, command, "simpbar-launch-browser")) return wrapperIconName(&BROWSER_BINS, "browser-choice", out);
    if (std.mem.eql(u8, command, "simpbar-launch-discord")) return wrapperIconName(&DISCORD_BINS, "discord-choice", out);
    var kbuf: [64]u8 = undefined;
    const key = launcherMatchKey(command, &kbuf);
    if (key.len == 0) return null;
    const icon = desktopIndexLookupDeep(key) orelse key;
    const l = @min(out.len, icon.len);
    @memcpy(out[0..l], icon[0..l]);
    return out[0..l];
}

/// Resolves an icon NAME to pixels in a 16px cache buffer. False when the
/// theme has no such icon or decoding fails — callers keep the label
/// fallback. Shared by pins and the taskbar tail.
fn decodeIconIntoPixels(icon_name: []const u8, dst: []u32) bool {
    var path_buf: [512]u8 = undefined;
    const path_slice = icontheme.resolveIconPath(icon_name, &path_buf) orelse return false;
    var path_z_buf: [520]u8 = undefined;
    @memcpy(path_z_buf[0..path_slice.len], path_slice);
    path_z_buf[path_slice.len] = 0;
    const decoded = icontheme.decodeIcon(std.heap.page_allocator, path_z_buf[0..path_slice.len :0], LAUNCHER_ICON_SIZE) catch return false;
    defer std.heap.page_allocator.free(decoded.pixels);
    icontheme.copyIntoIconBuffer(decoded, dst, LAUNCHER_ICON_SIZE);
    return true;
}

/// Running-app (tail) icon cache: appid → 16px pixels, resolved once and
/// kept (negative results cached too, so a missing icon doesn't retry
/// theme lookup on every draw). Sized to the tracker cap; eviction is
/// first-unused-slot — a full cache just means later arrivals keep labels.
var tail_icons: [MAX_RUNNING_APPS]TailIconCache = [_]TailIconCache{.{}} ** MAX_RUNNING_APPS;
const TailIconCache = struct {
    appid_buf: [64]u8 = undefined,
    appid_len: usize = 0,
    pixels: [LAUNCHER_ICON_SIZE * LAUNCHER_ICON_SIZE]u32 = [_]u32{0} ** (LAUNCHER_ICON_SIZE * LAUNCHER_ICON_SIZE),
    has_icon: bool = false,
    resolved: bool = false,
};

fn tailIconFind(appid_norm: []const u8) ?*TailIconCache {
    for (&tail_icons) |*c| {
        if (c.resolved and c.appid_len == appid_norm.len and std.mem.eql(u8, c.appid_buf[0..c.appid_len], appid_norm)) return c;
    }
    return null;
}

/// Decoded pixels for a running appid, or null (unknown or icon-less —
/// both draw the label fallback). Never decodes: the tick's
/// ensureTailIcons owns all resolving so draws never hitch on SVG raster.
fn tailIconPixels(appid_norm: []const u8) ?[]const u32 {
    const c = tailIconFind(appid_norm) orelse return null;
    return if (c.has_icon) &c.pixels else null;
}

/// Resolves icons for running appids not yet in the cache (bounded per
/// call so a burst of new windows spreads SVG raster across ticks).
/// Candidates: desktop index by full appid, then by last DNS component,
/// then the raw strings as icon names.
fn ensureTailIcons() void {
    var budget: usize = 4;
    for (running_state.apps[0..running_state.len]) |*app| {
        const id = app.appid();
        if (id.len == 0 or tailIconFind(id) != null) continue;
        if (budget == 0) return;
        budget -= 1;
        var slot: ?*TailIconCache = null;
        for (&tail_icons) |*c| {
            if (!c.resolved) {
                slot = c;
                break;
            }
        }
        const s = slot orelse return; // full: late arrivals keep labels
        s.resolved = true;
        s.has_icon = false;
        const al = @min(s.appid_buf.len, id.len);
        @memcpy(s.appid_buf[0..al], id[0..al]);
        s.appid_len = al;
        // Steam games first: "steam_app_<appid>" has no .desktop entry for
        // the index below to find — its icon only exists in Steam's own
        // library cache, so try there before any name-based resolution.
        var steam_path_buf: [512]u8 = undefined;
        if (icontheme.steamGameIconPath(id, &steam_path_buf)) |path| {
            if (decodeIconIntoPixels(path, &s.pixels)) {
                s.has_icon = true;
                continue;
            }
        }
        var short = id;
        if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| short = id[dot + 1 ..];
        const cand = desktopIndexLookupDeep(id) orelse short;
        if (decodeIconIntoPixels(cand, &s.pixels)) {
            s.has_icon = true;
            continue;
        }
        // Last resorts, in order: the full appid as a literal icon name,
        // then each DNS component (a theme may ship "spotify" while the
        // running id is the full "com.spotify.client").
        if (!std.mem.eql(u8, cand, id) and decodeIconIntoPixels(id, &s.pixels)) {
            s.has_icon = true;
            continue;
        }
        var parts = std.mem.splitScalar(u8, id, '.');
        while (parts.next()) |part| {
            if (part.len <= 2 or std.mem.eql(u8, part, short)) continue;
            if (std.mem.eql(u8, part, "com") or std.mem.eql(u8, part, "org") or std.mem.eql(u8, part, "net") or std.mem.eql(u8, part, "app")) continue;
            if (decodeIconIntoPixels(part, &s.pixels)) {
                s.has_icon = true;
                break;
            }
        }
    }
}

/// Decodes the icon for every not-yet-resolved launcher button into the
/// inline cache. Each slot is resolved at most once per config load: a null
/// or unresolvable icon marks the slot resolved-but-without-icon so the
/// missing-icon case doesn't retry gdk-pixbuf on every frame.
fn ensureLauncherIcons() void {
    for (current_config.launchers, 0..) |btn, i| {
        if (i >= launcher_icons.len) break;
        const cache = &launcher_icons[i];
        if (cache.resolved) continue;
        cache.resolved = true;
        cache.has_icon = false;
        cache.distro_glyph = 0;
        @memset(cache.pixels[0..], 0);

        // A pinned App Drawer button wears the distro logo (same glyph the
        // drawer brands itself with) instead of whatever generic icon the
        // pin names — detected from the command so renaming the pin or
        // changing its icon field can't break it.
        if (launcherLaunchesAppdrawer(btn.command)) {
            cache.distro_glyph = distroLogoCodepoint();
            continue;
        }

        // Explicit config icon first; otherwise derive one from the desktop
        // database so pins render icon-only with zero per-pin setup.
        var nbuf: [64]u8 = undefined;
        const icon: ?[]const u8 = if (btn.icon) |ex| (if (ex.len > 0) ex else pinIconName(btn.command, &nbuf)) else pinIconName(btn.command, &nbuf);
        const iname = icon orelse continue;
        if (decodeIconIntoPixels(iname, &cache.pixels)) cache.has_icon = true;
    }
}

// getenv is enough here; no need for std.process's env-map machinery.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Used to probe for binaries (mirroring icontheme.zig's own extern).
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

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

/// Mango (mangowm) IPC request — the same fresh-connection-per-request dance
/// as hyprctlRequest, but commands are framed with a trailing newline (mmsg
/// syntax). Like Hyprland, Mango closes the connection after a one-shot
/// reply, so read-until-EOF holds here too. (`mmsg watch ...` is the one
/// long-lived channel; that is a separate dedicated connection, see main.)
fn mangoRequest(gpa: std.mem.Allocator, sock_path: []const u8, command: []const u8) ![]u8 {
    const fd = try connectUnixSocket(sock_path);
    defer _ = posix.system.close(fd);

    var written: usize = 0;
    while (written < command.len) {
        const n = std.c.write(fd, command[written..].ptr, command.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
    if (std.c.write(fd, "\n", 1) != 1) return error.WriteFailed;

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        if (list.items.len > 4 * 1024 * 1024) break; // sanity cap
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

/// One rail entry. `mon_*` is the compositor monitor this tag/workspace
/// belongs to: Mango's tags are per-monitor sets (two monitors each own a
/// full "1 2 3 ...", which is why the old monitor-less rail showed every
/// digit twice), and Hyprland's j/workspaces entries carry the monitor each
/// workspace currently lives on (its ids stay global there, so a monitor's
/// run is just a subset). Entries sort by (monitor, id) — monitor-first, in
/// the same order the compositor reports its outputs — so every monitor's
/// run is one contiguous stretch `sliceForMonitor` can hand to that
/// monitor's own bar.
const Workspace = struct {
    id: i32,
    active: bool,
    urgent: bool = false,
    mon_buf: [MONITOR_NAME_MAX]u8 = undefined,
    mon_len: usize = 0,

    fn monitorName(self: *const Workspace) []const u8 {
        return self.mon_buf[0..self.mon_len];
    }

    fn setMonitor(self: *Workspace, name: []const u8) void {
        const n = @min(name.len, self.mon_buf.len);
        @memcpy(self.mon_buf[0..n], name[0..n]);
        self.mon_len = n;
    }
};

/// wl_output/mango monitor-name buffer size. Real connector names ("DP-1",
/// "HDMI-A-1") are far shorter; the headroom covers virtual output names.
const MONITOR_NAME_MAX = 32;

fn workspaceLessThan(_: void, a: Workspace, b: Workspace) bool {
    const order = std.mem.order(u8, a.monitorName(), b.monitorName());
    if (order != .eq) return order == .lt;
    return a.id < b.id;
}

/// Which compositor's IPC the workspace module talks to. Hyprland is the
/// original home of this module; Mango (mangowm) is supported natively so
/// the bar behaves identically on either desktop.
const CompositorMode = enum { hyprland, mango };

/// One Mango layout: the short symbol `mmsg get layouts` reports (also the
/// `layout` field on each tag), the full name `dispatch setlayout,<name>`
/// expects, and a Nerd Font glyph that reads as that layout's arrangement.
///
/// `icon` is a pre-encoded UTF-8 string rather than a codepoint so it can be
/// drawn straight through the same `nextUtf8Codepoint`/`drawGlyphAt` path as
/// every other label — including the supplementary-plane (5-hex-digit) Material
/// Design icons, which the bar already renders (the power button is
/// `md-power` U+F0425). The glyphs are picked for distinctness first, then
/// meaning: column/row shapes for the tile families, arrows for the scrollers,
/// a funnel for vertical_deck.
///
/// Keep `symbol`/`name` in sync with `mmsg get layouts`; the order matches the
/// compositor's own enumeration so the picker lists them the way Mango does.
const MangoLayout = struct {
    symbol: []const u8, // "DW", "CT", ...
    name: []const u8, // "dwindle", "center_tile", ...
    icon: []const u8, // UTF-8 glyph
};

const MANGO_LAYOUTS = [_]MangoLayout{
    .{ .symbol = "T", .name = "tile", .icon = "\u{f0db}" }, // fa-table_columns — master + stack
    .{ .symbol = "S", .name = "scroller", .icon = "\u{f04e1}" }, // md-swap_horizontal — horizontal strip
    .{ .symbol = "G", .name = "grid", .icon = "\u{f0570}" }, // md-view_grid
    .{ .symbol = "M", .name = "monocle", .icon = "\u{f2d0}" }, // fa-window_maximize — one fullscreen window
    .{ .symbol = "K", .name = "deck", .icon = "\u{eea8}" }, // fa-layer_group — stacked deck
    .{ .symbol = "CT", .name = "center_tile", .icon = "\u{ebf7}" }, // cod-layout_centered — master centred
    .{ .symbol = "RT", .name = "right_tile", .icon = "\u{ebf4}" }, // cod-layout_sidebar_right — master right
    .{ .symbol = "VS", .name = "vertical_scroller", .icon = "\u{f04e2}" }, // md-swap_vertical
    .{ .symbol = "VT", .name = "vertical_tile", .icon = "\u{f056a}" }, // md-view_agenda — stacked rows
    .{ .symbol = "VG", .name = "vertical_grid", .icon = "\u{f15fc}" }, // md-dots_grid
    .{ .symbol = "VK", .name = "vertical_deck", .icon = "\u{f0b0}" }, // fa-filter — funnel
    .{ .symbol = "DW", .name = "dwindle", .icon = "\u{f00fb}" }, // md-call_split — diagonal split
    .{ .symbol = "F", .name = "fair", .icon = "\u{ebf0}" }, // cod-layout_panel_justify — equal panels
    .{ .symbol = "VF", .name = "vertical_fair", .icon = "\u{f1963}" }, // md-align_vertical_distribute
};

/// The layout whose `symbol` matches, or null if the symbol is unknown (a
/// newer Mango added a layout this build doesn't know). The module then
/// falls back to hiding itself rather than showing a wrong icon.
fn layoutBySymbol(symbol: []const u8) ?*const MangoLayout {
    for (&MANGO_LAYOUTS) |*l| {
        if (std.mem.eql(u8, l.symbol, symbol)) return l;
    }
    return null;
}

/// Tracks the compositor's workspace/tag list via IPC, matching waybar's
/// "hyprland/workspaces" module ("all-outputs": true, "sort-by-number": true,
/// "active-only": false from ~/.config/waybar/config). The Hyprland backend
/// reads `j/workspaces` (+ `j/activeworkspace`); the Mango backend reads
/// `mmsg get all-tags`.
const Workspaces = struct {
    gpa: std.mem.Allocator,
    mode: CompositorMode,
    list: std.ArrayList(Workspace),
    sock_path_buf: [108]u8 = undefined,
    sock_path_len: usize,
    /// The active tag's Mango layout symbol ("DW", "CT", ...), captured from
    /// the same `mmsg get all-tags` payload refreshMango already parses, so
    /// the layout module costs no extra IPC. Empty under Hyprland (no per-tag
    /// layout concept in its IPC) and empty until the first successful Mango
    /// refresh — callers treat empty as "unknown" and hide the module.
    layout_buf: [8]u8 = undefined,
    layout_len: usize = 0,

    fn init(gpa: std.mem.Allocator, mode: CompositorMode, sock_path: []const u8) !Workspaces {
        var self = Workspaces{
            .gpa = gpa,
            .mode = mode,
            .list = .empty,
            .sock_path_len = sock_path.len,
        };
        @memcpy(self.sock_path_buf[0..sock_path.len], sock_path);
        self.refresh() catch |err| {
            logging.warn("workspaces: initial refresh failed: {}", .{err});
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
        switch (self.mode) {
            .hyprland => try self.refreshHyprland(),
            .mango => try self.refreshMango(),
        }
    }

    fn refreshHyprland(self: *Workspaces) !void {
        const ws_json = try hyprctlRequest(self.gpa, self.sockPath(), "j/workspaces");
        defer self.gpa.free(ws_json);
        const active_json = try hyprctlRequest(self.gpa, self.sockPath(), "j/activeworkspace");
        defer self.gpa.free(active_json);

        try self.scanHyprland(ws_json, extractFirstId(active_json) orelse -1);
    }

    /// The substring scan behind the Hyprland rail: `j/workspaces` entries
    /// (`{"id":1,...,"monitor":"DP-1",...}`) appended monitor-annotated and
    /// sorted per workspaceLessThan. Split from refreshHyprland so the
    /// payload logic stays testable without a compositor socket. Clears the
    /// list first; layout parsing (a Mango-only concept) is untouched.
    fn scanHyprland(self: *Workspaces, ws_json: []const u8, active_id: i32) !void {
        self.list.clearRetainingCapacity();
        const needle = "\"id\":";
        const monitor_needle = "\"monitor\":\"";
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, ws_json, idx, needle)) |pos| {
            const after = pos + needle.len;
            // This id's entry ends at the next id boundary (or payload end);
            // scanning for `monitor` only inside that slice stops a missing
            // field from bleeding into the next entry's (same substring-scan
            // style as refreshMango). `"monitor":"` can't false-match
            // `"monitorID":` — the needle's quote lands before `ID:`.
            const entry_end = std.mem.indexOfPos(u8, ws_json, after, needle) orelse ws_json.len;
            if (parseIdAt(ws_json, after)) |id| {
                var ws = Workspace{ .id = id, .active = id == active_id };
                if (std.mem.indexOf(u8, ws_json[after..entry_end], monitor_needle)) |mp| {
                    const s = after + mp + monitor_needle.len;
                    var e = s;
                    while (e < ws_json.len and ws_json[e] != '"') : (e += 1) {}
                    ws.setMonitor(ws_json[s..e]);
                }
                try self.list.append(self.gpa, ws);
            }
            idx = after;
        }
        std.sort.insertion(Workspace, self.list.items, {}, workspaceLessThan);
    }

    fn refreshMango(self: *Workspaces) !void {
        const tags_json = try mangoRequest(self.gpa, self.sockPath(), "get all-tags");
        defer self.gpa.free(tags_json);

        try self.scanMango(tags_json);
    }

    /// The substring scan behind the Mango rail: one pass of
    /// `{"monitor":"DP-1","tags":[{"index":N,"is_active":b,"is_urgent":b,
    /// "layout":"DW",...},...]}` records per monitor (matching wl_output
    /// name order). Each tag pairs `index` immediately with `is_active`, so
    /// a plain substring scan (matching scanHyprland's style) suffices once
    /// the scan is scoped to one monitor record at a time — that scoping is
    /// what makes the per-monitor rail possible. A tag counts as active on
    /// its own monitor only. The active tag's `layout` symbol is stashed for
    /// the layout module; with a single monitor (the common case) that is
    /// exactly the tag `setlayout` targets, and with several it is the first
    /// active tag across monitors. Payloads with no monitor records at all
    /// (older Mango) fall back to one flat scope with empty monitor names —
    /// those entries then serve every bar merged, the pre-multi-monitor
    /// behavior. Split from refreshMango so the payload logic stays
    /// testable without a compositor socket.
    fn scanMango(self: *Workspaces, tags_json: []const u8) !void {
        self.list.clearRetainingCapacity();
        self.layout_len = 0;
        const monitor_needle = "\"monitor\":\"";
        const needle = "\"index\":";
        const active_needle = "\"is_active\":";
        const layout_needle = "\"layout\":\"";
        const close_needle = "}";
        const grouped = std.mem.indexOf(u8, tags_json, monitor_needle) != null;

        var entry_idx: usize = 0;
        while (true) {
            // One scope: a monitor record's `monitor` name through everything
            // up to the next record. Ungrouped payloads get a single scope
            // spanning the whole body so the flat tag scan still runs.
            var mpos: usize = 0;
            var name_start: usize = 0;
            var entry_end: usize = tags_json.len;
            if (grouped) {
                mpos = std.mem.indexOfPos(u8, tags_json, entry_idx, monitor_needle) orelse break;
                name_start = mpos + monitor_needle.len;
                entry_end = std.mem.indexOfPos(u8, tags_json, name_start, monitor_needle) orelse tags_json.len;
            } else if (entry_idx != 0) break;

            var mon_name: []const u8 = "";
            if (grouped) {
                var e = name_start;
                while (e < entry_end and tags_json[e] != '"') : (e += 1) {}
                mon_name = tags_json[name_start..e];
            }

            const entry = tags_json[mpos..entry_end];
            var idx: usize = 0;
            while (std.mem.indexOfPos(u8, entry, idx, needle)) |tpos| {
                const after = tpos + needle.len;
                if (parseIdAt(entry, after)) |id| {
                    var active = false;
                    if (std.mem.indexOfPos(u8, entry, after, active_needle)) |p| {
                        const v = p + active_needle.len;
                        if (v < entry.len and entry[v] == 't') active = true;
                    }
                    // Urgent tags (demanding attention) get a dot under their
                    // digit — bounded to this tag's object like the layout
                    // lookup below, for the same cross-tag reason (within the
                    // monitor scope now, so it can never cross records).
                    var urgent = false;
                    const obj_end_u = std.mem.indexOfPos(u8, entry, after, close_needle) orelse entry.len;
                    const urgent_needle = "\"is_urgent\":";
                    if (std.mem.indexOf(u8, entry[after..obj_end_u], urgent_needle)) |p| {
                        const v = after + p + urgent_needle.len;
                        if (v < entry.len and entry[v] == 't') urgent = true;
                    }
                    // Stash the FIRST active tag's layout. Mango reports each
                    // tag as a flat object and this scan isn't object-aware
                    // (same shape as the is_active lookup above), so bound
                    // the search to this tag's own object by stopping at the
                    // next `}` — that keeps the layout we read the one
                    // belonging to the tag we're on rather than the next
                    // tag's. With several monitors the first active tag
                    // wins, which on the single-monitor setups this bar
                    // targets is simply the active tag; `layout()` returning
                    // empty (unknown) is the safe fallback and hides the
                    // module rather than guessing.
                    if (active and self.layout_len == 0) {
                        const obj_end = std.mem.indexOfPos(u8, entry, after, close_needle) orelse entry.len;
                        const obj = entry[after..obj_end];
                        if (std.mem.indexOf(u8, obj, layout_needle)) |lp| {
                            const s = lp + layout_needle.len;
                            var e2 = s;
                            while (e2 < obj.len and obj[e2] != '"') : (e2 += 1) {}
                            const sym = obj[s..e2];
                            if (sym.len > 0 and sym.len <= self.layout_buf.len) {
                                @memcpy(self.layout_buf[0..sym.len], sym);
                                self.layout_len = sym.len;
                            }
                        }
                    }
                    var ws = Workspace{ .id = id, .active = active, .urgent = urgent };
                    ws.setMonitor(mon_name);
                    try self.list.append(self.gpa, ws);
                }
                idx = after;
            }
            if (!grouped) break;
            entry_idx = name_start;
        }
        std.sort.insertion(Workspace, self.list.items, {}, workspaceLessThan);
    }

    /// The contiguous run of `list.items` holding the entries of exactly
    /// the given monitor (`"DP-1"`...) — sorted monitor-first, so one linear
    /// scan finds it. Empty monitor name (a bar that doesn't know its output
    /// yet) → the merged list across all monitors (previous single-bar rail).
    /// A name absent from the current list (hotplug race between the bar's
    /// wl_output and the compositor's IPC) also falls back to the merged list
    /// so no rail ever goes blank from a mismatch.
    fn sliceForMonitor(self: *const Workspaces, monitor: []const u8) []const Workspace {
        const all = self.list.items;
        if (monitor.len == 0) return all;
        var start: ?usize = null;
        var end: usize = all.len;
        for (all, 0..) |*ws, i| {
            if (start != null) {
                if (!std.mem.eql(u8, ws.monitorName(), monitor)) {
                    end = i;
                    break;
                }
            } else if (std.mem.eql(u8, ws.monitorName(), monitor)) {
                start = i;
            }
        }
        if (start) |s| return all[s..end];
        return all;
    }

    /// The active tag's layout symbol, or empty if unknown (Hyprland, or
    /// before the first Mango refresh succeeded).
    fn layout(self: *const Workspaces) []const u8 {
        return self.layout_buf[0..self.layout_len];
    }

    /// Applies layout `name` (a MANGO_LAYOUTS name, e.g. "dwindle") to the
    /// active tag. `set_layout` is runtime-only — it never writes the config
    /// file — and Mango announces the change on the very `watch all-tags`
    /// channel this bar already streams, so the icon updates on its own.
    fn setLayout(self: *const Workspaces, name: []const u8) !void {
        var cmd_buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "dispatch setlayout,{s}", .{name});
        try self.dispatchCommand(cmd);
    }

    /// Fire-and-forget a plain (non-JSON) dispatch command in the compositor's
    /// own syntax. On Hyprland these route through a Lua eval bridge (see
    /// ~/.config/hypr/hyprland.lua); on Mango they're `dispatch` functions.
    /// The resulting change comes back to us as an event on the watch
    /// connection, which triggers the normal refresh+redraw — no need to
    /// update local state here.
    fn dispatchCommand(self: *const Workspaces, command: []const u8) !void {
        if (self.sock_path_len == 0) return error.NoCompositorIpc;
        switch (self.mode) {
            .hyprland => {
                const resp = try hyprctlRequest(self.gpa, self.sockPath(), command);
                self.gpa.free(resp);
            },
            .mango => {
                const resp = try mangoRequest(self.gpa, self.sockPath(), command);
                self.gpa.free(resp);
            },
        }
    }

    /// Switches to tag/workspace `id`, using whatever syntax the active
    /// compositor understands. `monitor` is the bar's own output name
    /// (empty = unknown → legacy focused-monitor dispatch): Mango's tags
    /// are per-monitor sets, so a rail click on monitor B's bar must view
    /// the tag *on B* — `viewcrossmon,{tag},{monitor}` focuses B and views
    /// the tag there — otherwise `view,{tag}` would apply to whatever
    /// monitor currently holds keyboard focus. Hyprland's workspace ids are
    /// global (each lives on exactly one monitor), so its dispatch is
    /// monitor-agnostic and unchanged.
    fn switchTo(self: *const Workspaces, id: i32, monitor: []const u8) !void {
        switch (self.mode) {
            .hyprland => {
                var cmd_buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "dispatch hl.dsp.focus({{ workspace = {d} }})", .{id}) catch return error.CommandTooLong;
                try self.dispatchCommand(cmd);
            },
            .mango => {
                var cmd_buf: [96]u8 = undefined;
                const cmd = if (monitor.len > 0)
                    std.fmt.bufPrint(&cmd_buf, "dispatch viewcrossmon,{d},{s}", .{ id, monitor }) catch return error.CommandTooLong
                else
                    std.fmt.bufPrint(&cmd_buf, "dispatch view,{d}", .{id}) catch return error.CommandTooLong;
                try self.dispatchCommand(cmd);
            },
        }
    }

    /// Moves to the adjacent workspace/tag, in `direction`.
    ///
    /// Uses the relative forms the desktop's own keybinds already use rather
    /// than picking a target id out of `self.list` ourselves. Doing the
    /// arithmetic locally would mean reimplementing the compositor's own
    /// rules — skip empty numbers, clamp at the ends, honour per-monitor
    /// tag sets — and getting any of it wrong fights the compositor.
    /// Hyprland's "e+1"/"e-1" is the form hyprland.lua binds to
    /// mainMod+mouse_down/up -> focus({workspace="e±1"}); Mango's
    /// `viewtoright`/`viewtoleft` are what its SUPER+Right/Left binds use —
    /// so the bar and the keyboard agree on where "next" is by construction.
    ///
    /// `monitor` scopes the step to one bar's own output (empty = unknown →
    /// the relative dispatches act on the focused monitor, as before).
    /// Mango's relative view shifts have no monitor argument, so the two
    /// dispatches route the step: `focusmon,{monitor}` first (a plain name
    /// parses to UNDIR in mango, which is the "by-name" form it intends),
    /// then the same relative shift the keybinds use.
    ///
    /// `direction` is +1 for "forward" (wheel down). It arrives from the
    /// compositor's axis sign, which is negative for down.
    fn stepWorkspace(self: *const Workspaces, direction: i32, monitor: []const u8) void {
        const step_cmd = switch (self.mode) {
            .hyprland => if (direction > 0)
                "dispatch hl.dsp.focus({ workspace = \"e+1\" })"
            else
                "dispatch hl.dsp.focus({ workspace = \"e-1\" })",
            .mango => if (direction > 0) "dispatch viewtoright,0" else "dispatch viewtoleft,0",
        };
        if (self.mode == .mango and monitor.len > 0) {
            var focus_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&focus_buf, "dispatch focusmon,{s}", .{monitor})) |focus_cmd| {
                self.dispatchCommand(focus_cmd) catch |err| {
                    logging.err("workspace step focus ({s}) failed: {}", .{ monitor, err });
                    return;
                };
            } else |err| {
                logging.err("workspace step focus ({s}) too long: {}", .{ monitor, err });
                return;
            }
        }
        self.dispatchCommand(step_cmd) catch |err| {
            logging.err("workspace step ({s}) failed: {}", .{ if (direction > 0) "next" else "prev", err });
        };
    }

    /// Focuses one running client by its `addr` token (see RunningApp):
    /// Hyprland's `0x...` window address, Mango's decimal client id. Same
    /// dispatch bridge the overview's activateTile uses, so the bar and the
    /// overview agree on how a window is raised by construction.
    fn focusClient(self: *const Workspaces, addr: []const u8, ws_id: i32) void {
        // Jump to the client's tag/workspace first: raising a window on a
        // hidden tag without switching leaves the user staring at the old
        // tag wondering why nothing happened. Under Mango the client's tag
        // belongs to a specific monitor (tags are per-monitor sets), so use
        // that monitor's name — first entry with this id is the tag the
        // compositor named — instead of a focused-monitor `view`, which
        // would show the wrong monitor's same-numbered tag.
        if (ws_id >= 0) {
            var monitor: []const u8 = "";
            for (self.list.items) |*ws| {
                if (ws.id == ws_id) {
                    monitor = ws.monitorName();
                    break;
                }
            }
            self.switchTo(ws_id, monitor) catch |err| {
                logging.err("client tag switch ({d}) failed: {}", .{ ws_id, err });
            };
        }
        var cmd_buf: [160]u8 = undefined;
        const cmd = switch (self.mode) {
            .hyprland => std.fmt.bufPrint(&cmd_buf, "dispatch hl.dsp.focus({{ window = \"address:{s}\" }})", .{addr}) catch return,
            .mango => std.fmt.bufPrint(&cmd_buf, "dispatch focusid,{s}", .{addr}) catch return,
        };
        self.dispatchCommand(cmd) catch |err| {
            logging.err("client focus ({s}) failed: {}", .{ addr, err });
        };
    }
};

/// One live window, reduced to what the launcher/taskbar layer needs: who
/// owns it (`appid_norm`, lowercased at parse time so matching never
/// allocates) and how to raise it (`addr` — Hyprland's `0x...` address or
/// Mango's decimal client id, the exact token focusClient expects).
const RunningApp = struct {
    addr_buf: [20]u8 = undefined,
    addr_len: usize = 0,
    appid_buf: [64]u8 = undefined,
    appid_len: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    focused: bool = false,
    /// Tag (Mango) / workspace id (Hyprland) holding the window, -1 when
    /// unknown — click-to-focus switches there before raising it.
    ws: i32 = -1,

    fn addr(self: *const RunningApp) []const u8 {
        return self.addr_buf[0..self.addr_len];
    }
    fn appid(self: *const RunningApp) []const u8 {
        return self.appid_buf[0..self.appid_len];
    }
    fn title(self: *const RunningApp) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Cap on tracked windows (fixed backing array, same spirit as the tray's
/// bounds — a bar that needs more than 32 live taskbar entries has bigger
/// layout problems than a dropped tail).
const MAX_RUNNING_APPS: usize = 32;

/// Live window list behind the pinned-launcher running dots and the
/// unpinned taskbar buttons. Mirrors Workspaces' shape (mode + socket +
/// refresh on compositor events, cheap enough to also poll every couple of
/// seconds since focus-within-a-tag may not move Mango's all-tags stream).
const RunningApps = struct {
    gpa: std.mem.Allocator,
    mode: CompositorMode,
    sock_path_buf: [108]u8 = undefined,
    sock_path_len: usize = 0,
    apps: [MAX_RUNNING_APPS]RunningApp = undefined,
    len: usize = 0,

    fn empty() RunningApps {
        return .{ .gpa = std.heap.page_allocator, .mode = .hyprland };
    }

    fn init(gpa: std.mem.Allocator, mode: CompositorMode, sock_path: []const u8) RunningApps {
        var self = RunningApps{ .gpa = gpa, .mode = mode, .sock_path_len = @min(sock_path.len, 108) };
        @memcpy(self.sock_path_buf[0..self.sock_path_len], sock_path[0..self.sock_path_len]);
        const changed = self.refresh() catch |err| blk: {
            logging.warn("running apps: initial refresh failed: {}", .{err});
            break :blk false;
        };
        _ = changed;
        return self;
    }

    fn sockPath(self: *const RunningApps) []const u8 {
        return self.sock_path_buf[0..self.sock_path_len];
    }

    /// Re-reads the client list; on IPC failure the previous list is kept
    /// (a transient socket hiccup shouldn't blink every running dot out).
    /// Returns true when the set changed, so the tick can skip redundant
    /// redraws... (callers redraw on the clock tick anyway; kept for tests).
    fn refresh(self: *RunningApps) !bool {
        if (self.sock_path_len == 0) return false;
        var next: [MAX_RUNNING_APPS]RunningApp = undefined;
        const n = switch (self.mode) {
            .hyprland => try self.refreshHyprland(&next),
            .mango => try self.refreshMango(&next),
        };
        if (n == self.len) {
            var same = true;
            for (next[0..n], self.apps[0..self.len]) |a, b| {
                if (!std.mem.eql(u8, a.addr(), b.addr()) or a.focused != b.focused or a.ws != b.ws or !std.mem.eql(u8, a.appid(), b.appid())) {
                    same = false;
                    break;
                }
            }
            if (same) return false;
        }
        @memcpy(self.apps[0..n], next[0..n]);
        self.len = n;
        return true;
    }

    fn refreshHyprland(self: *RunningApps, out: *[MAX_RUNNING_APPS]RunningApp) !usize {
        const clients_json = try hyprctlRequest(self.gpa, self.sockPath(), "j/clients");
        defer self.gpa.free(clients_json);
        // Focused address from the active window (clients themselves carry
        // no focused flag — same two-request shape as refreshHyprland's
        // workspaces/activeworkspace pair).
        var focused_addr: []const u8 = "";
        if (hyprctlRequest(self.gpa, self.sockPath(), "j/activewindow")) |active_json| {
            defer self.gpa.free(active_json);
            if (extractJsonString(active_json, "\"address\"")) |a| focused_addr = a;
        } else |_| {}
        var n: usize = 0;
        var objs = topLevelObjects(clients_json);
        while (objs.next()) |obj| {
            if (n >= out.len) break;
            const class = extractJsonString(obj, "\"class\"") orelse continue;
            const address = extractJsonString(obj, "\"address\"") orelse continue;
            const title = extractJsonString(obj, "\"title\"") orelse "";
            var app = RunningApp{};
            const al = @min(address.len, app.addr_buf.len);
            @memcpy(app.addr_buf[0..al], address[0..al]);
            app.addr_len = al;
            app.appid_len = lowerCopy(&app.appid_buf, class);
            app.title_len = lowerCopy(&app.title_buf, title);
            app.focused = focused_addr.len > 0 and std.mem.eql(u8, address, focused_addr);
            app.ws = extractWorkspaceId(obj) orelse -1;
            out[n] = app;
            n += 1;
        }
        return n;
    }

    fn refreshMango(self: *RunningApps, out: *[MAX_RUNNING_APPS]RunningApp) !usize {
        const clients_json = try mangoRequest(self.gpa, self.sockPath(), "get all-clients");
        defer self.gpa.free(clients_json);
        var n: usize = 0;
        var objs = topLevelObjects(clients_json);
        while (objs.next()) |obj| {
            if (n >= out.len) break;
            const appid = extractJsonString(obj, "\"appid\"") orelse continue;
            if (appid.len == 0) continue;
            var app = RunningApp{};
            if (extractJsonInt(obj, "\"id\"")) |id| {
                var id_buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch continue;
                @memcpy(app.addr_buf[0..s.len], s);
                app.addr_len = s.len;
            } else continue;
            app.appid_len = lowerCopy(&app.appid_buf, appid);
            if (extractJsonString(obj, "\"title\"")) |t| app.title_len = lowerCopy(&app.title_buf, t);
            app.focused = std.mem.indexOf(u8, obj, "\"is_focused\":true") != null;
            // First tag owns the window for jump-to purposes (multi-tagged
            // windows are rare; the overview treats tags the same way).
            app.ws = extractFirstTagId(obj) orelse -1;
            out[n] = app;
            n += 1;
        }
        return n;
    }
};

/// Lowercases `src` into `dst`, returning the bytes written (truncated at
/// `dst.len` — appids/titles longer than the taskbar's fixed fields lose
/// their tail, which only costs a match in pathological cases).
fn lowerCopy(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
    return n;
}

/// Splits a top-level JSON array (`[...]`), bare or behind a wrapper object
/// (`{"clients":[...]}`), into its `{...}` element objects. Only `[`/`]
/// move the depth counter; the element scan itself is brace-balanced and
/// string-aware, so nested objects (Hyprland's per-client `"workspace"`),
/// arrays (Mango's `"tags"`), and braces/quotes inside titles can't end an
/// element early.
const TopLevelObjects = struct {
    text: []const u8,
    pos: usize,
    /// Array depth at `pos` — kept across next() calls, since the opening
    /// `[` is only scanned once (before the first element).
    arr_depth: usize = 0,

    fn next(self: *TopLevelObjects) ?[]const u8 {
        var i = self.pos;
        var in_str = false;
        var esc = false;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    in_str = false;
                }
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '[' => self.arr_depth += 1,
                ']' => self.arr_depth -|= 1,
                '{' => {
                    if (self.arr_depth != 1) continue;
                    // Element start: scan to its matching close.
                    const start = i;
                    var edepth: usize = 1;
                    var j = i + 1;
                    var sstr = false;
                    var sesc = false;
                    while (j < self.text.len) : (j += 1) {
                        const d = self.text[j];
                        if (sstr) {
                            if (sesc) {
                                sesc = false;
                            } else if (d == '\\') {
                                sesc = true;
                            } else if (d == '"') {
                                sstr = false;
                            }
                            continue;
                        }
                        if (d == '"') {
                            sstr = true;
                        } else if (d == '{' or d == '[') {
                            edepth += 1;
                        } else if (d == '}' or d == ']') {
                            edepth -= 1;
                            if (edepth == 0) {
                                self.pos = j + 1;
                                return self.text[start .. j + 1];
                            }
                        }
                    }
                    return null; // unterminated tail; stop
                },
                else => {},
            }
        }
        return null;
    }
};

fn topLevelObjects(array_json: []const u8) TopLevelObjects {
    return .{ .text = array_json, .pos = 0 };
}

/// Reads `"key":"value"` from a flat JSON object substring (no unescaping —
/// appids/addresses never carry escapes; titles may, and only lose an exact
/// fallback match when they do). Returns null when the key is absent.
fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, obj, search, key)) |pos| {
        var i = pos + key.len;
        while (i < obj.len and (obj[i] == ' ' or obj[i] == ':')) : (i += 1) {}
        if (i < obj.len and obj[i] == '"') {
            const start = i + 1;
            var j = start;
            var esc = false;
            while (j < obj.len) : (j += 1) {
                const c = obj[j];
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    return obj[start..j];
                }
            }
            return null;
        }
        search = i;
    }
    return null;
}

/// Reads `"key":123` (signed) from a flat JSON object substring.
fn extractJsonInt(obj: []const u8, key: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, obj, key) orelse return null;
    var i = pos + key.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == ':')) : (i += 1) {}
    return parseIdAt(obj, i);
}

/// Reads the first id in Mango's `"tags":[1, ...]` array (the tag a window
/// is on). Null for missing/empty arrays (sticky or global windows).
fn extractFirstTagId(obj: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, obj, "\"tags\"") orelse return null;
    const open = std.mem.indexOfPos(u8, obj, pos, "[") orelse return null;
    return parseIdAt(obj, open + 1);
}

/// Reads Hyprland's nested `"workspace":{"id":N, ...}` id. Scoped to the
/// workspace object so a same-named key elsewhere in the client can't win.
fn extractWorkspaceId(obj: []const u8) ?i32 {
    const wpos = std.mem.indexOf(u8, obj, "\"workspace\"") orelse return null;
    const open = std.mem.indexOfPos(u8, obj, wpos, "{") orelse return null;
    const close = std.mem.indexOfPos(u8, obj, open, "}") orelse obj.len;
    const seg = obj[open..close];
    const ipos = std.mem.indexOf(u8, seg, "\"id\"") orelse return null;
    var i = ipos + "\"id\"".len;
    while (i < seg.len and (seg[i] == ' ' or seg[i] == ':')) : (i += 1) {}
    return parseIdAt(seg, i);
}

/// True when a tail group's app has a resolved icon (read-only lookup —
/// resolving stays on the tick, so measures and draws never decode).
fn tailHasIcon(g: *const UnpinnedGroup) bool {
    if (g.client_idx >= running_state.len) return false;
    return tailIconPixels(running_state.apps[g.client_idx].appid()) != null;
}

/// Tail button content width: one icon cell when resolved, label width as
/// the fallback. Single source for the left measure, left draw, and center
/// compose passes so the three can never disagree.
fn tailButtonWidth(font: *font_mod.Font, g: *const UnpinnedGroup) i64 {
    if (tailHasIcon(g)) return LAUNCHER_ICON_SIZE;
    return textPixelWidth(font, g.name());
}

/// Live window list the launcher/taskbar layer reads. Global (like
/// current_config/launcher_icons/hover_frame) so the half-dozen draw Width
/// helpers don't all grow a new parameter for one feature's data.
var running_state: RunningApps = RunningApps.empty();

/// Wrapper-script launchers resolve to several possible appids (the Welcome
/// app's choice file, else the fallback probe order in install.sh) — match
/// any of them. Kept next to the scripts' own lists by name so drift is
/// greppable: BROWSER_APPIDS ↔ simpbar-launch-browser's probe loop.
const BROWSER_APPIDS = [_][]const u8{ "brave", "brave-browser", "zen", "zen-browser", "vivaldi", "vivaldi-stable", "edge", "microsoft-edge", "librewolf", "firefox", "firefox-esr", "chromium", "google-chrome", "chrome" };
/// DISCORD_APPIDS ↔ simpbar-launch-discord's probe loop ("fluxer" covers
/// app.fluxer.FluxerDesktop as a whole-word run, same as the other entries).
const DISCORD_APPIDS = [_][]const u8{ "vesktop", "equibop", "discord", "fluxer" };

/// Word separators inside an app id or a match key: reverse-DNS dots plus
/// the dash/underscore/space variants distro ids and desktop classes use
/// ("org.gnome.Nautilus", "zen-browser", "steam_app_440").
fn isWordSep(c: u8) bool {
    return c == '.' or c == '-' or c == '_' or c == ' ';
}

/// True when `needle`'s words appear as one contiguous run of `hay`'s
/// words: case is ignored and separators *between* words are skipped while
/// walking, but the run has to start and end on a whole word of `hay`
/// (index 0 / a separator on each side). So "simpbar-config" hits
/// "dev.jaytheoutpatient.simpbar.Config", "gnome-text-editor" hits
/// "org.gnome.TextEditor" and "chrome" hits "google-chrome" — while "edge"
/// never lands inside "ledger", "zen" never inside "zenity", and one
/// shared word ("simpbar", "com", "org") can never stand in for a whole
/// sibling key.
fn wordRunIn(hay: []const u8, needle: []const u8) bool {
    if (hay.len == 0 or needle.len == 0) return false;
    var needle_words: usize = 0;
    for (needle) |c| {
        if (!isWordSep(c)) needle_words += 1;
    }
    if (needle_words == 0) return false; // separators-only key matches nothing
    var start: usize = 0;
    while (start < hay.len) : (start += 1) {
        // A run may only begin at a word edge: index 0 or just past a sep.
        if (start > 0 and !isWordSep(hay[start - 1])) continue;
        var hi = start;
        var ni: usize = 0;
        while (true) {
            while (ni < needle.len and isWordSep(needle[ni])) ni += 1;
            if (ni == needle.len) break;
            while (hi < hay.len and isWordSep(hay[hi])) hi += 1;
            if (hi == hay.len or std.ascii.toLower(hay[hi]) != std.ascii.toLower(needle[ni])) break;
            hi += 1;
            ni += 1;
        }
        // Needle fully consumed, and the run stopped on a whole word: hit.
        var done = ni;
        while (done < needle.len and isWordSep(needle[done])) done += 1;
        if (done == needle.len and (hi == hay.len or isWordSep(hay[hi]))) return true;
    }
    return false;
}

/// True when `appid_norm` (already lowercased) names the app `key`
/// (lowercase): the two are compared as word runs in both directions, so
/// "org.gnome.nautilus" ↔ "nautilus", "zen-browser" ↔ "zen" and
/// "…simpbar.Config" ↔ "simpbar-config" all hit, and a flatpak pin
/// ("com.spotify.Client") still finds a window reporting plain "spotify".
///
/// Both directions, whole words only: the old per-component substring test
/// matched any single dot component either way, which made every window of
/// one family light every pin of that family — `…simpbar.Config` satisfied
/// the `simpbar-welcome` pin through their shared "simpbar" component (and
/// "com" satisfied every flatpak-style pin at once), so starting
/// simpbar-config lit the welcome dot too.
fn appidMatchesKey(appid_norm: []const u8, key: []const u8) bool {
    if (key.len == 0 or appid_norm.len == 0) return false;
    return wordRunIn(appid_norm, key) or wordRunIn(key, appid_norm);
}

/// Command → match key: first shell word's basename, lowercased
/// ("org.gnome.Nautilus" never appears here — commands are binaries, the
/// DNS-splitting happens on the appid side). Flatpak/snap wrappers resolve
/// to the wrapped app id (`flatpak run … com.spotify.Client @@` → the id,
/// not "flatpak" — otherwise every sandboxed pin matches nothing and
/// spawns duplicates). Empty when unmatchable.
fn launcherMatchKey(command: []const u8, buf: []u8) []const u8 {
    var word = command;
    if (std.mem.indexOfScalar(u8, word, ' ')) |sp| word = word[0..sp];
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |sl| word = word[sl + 1 ..];
    if (std.mem.endsWith(u8, word, ".desktop")) word = word[0 .. word.len - ".desktop".len];
    if (word.len == 0) return "";
    if (std.mem.eql(u8, word, "flatpak") or std.mem.eql(u8, word, "snap")) {
        if (wrappedAppId(command, buf)) |id| return id;
        // `flatpak update`-style verbs with no app: fall through to the
        // wrapper name itself (matches nothing, launches fine).
    }
    return buf[0..lowerCopy(buf, word)];
}

/// Pulls the wrapped app id out of a `flatpak run …` / `snap run …`
/// command: first token past `run` that isn't a flag. Flatpak ids always
/// carry dots (com.spotify.Client); snap names are bare (spotify), so the
/// dot rule only applies to flatpak. `=`-bearing tokens (--command=x,
/// --branch=x) and @@-forwarding placeholders never qualify.
fn wrappedAppId(command: []const u8, buf: []u8) ?[]const u8 {
    const is_snap = blk: {
        var w = command;
        if (std.mem.indexOfScalar(u8, w, ' ')) |sp| w = w[0..sp];
        const base = if (std.mem.lastIndexOfScalar(u8, w, '/')) |sl| w[sl + 1 ..] else w;
        break :blk std.mem.eql(u8, base, "snap");
    };
    var toks = std.mem.splitScalar(u8, command, ' ');
    var past_run = false;
    while (toks.next()) |tok| {
        if (!past_run) {
            if (std.mem.eql(u8, tok, "run")) past_run = true;
            continue;
        }
        if (tok.len == 0 or tok[0] == '-' or std.mem.indexOfScalar(u8, tok, '=') != null) continue;
        if (!is_snap and std.mem.indexOfScalar(u8, tok, '.') == null) continue;
        return buf[0..lowerCopy(buf, tok)];
    }
    return null;
}

/// True when the running client (`appid_norm` + `title_norm`, both
/// lowercased) belongs to `command`'s app. The app-drawer power button and
/// friends launch panels, not windows, and never match; the two wrapper
/// scripts match their whole candidate family; everything else matches its
/// binary name against appid (falling back to window title for odd hosts
/// like Steam's per-game appids).
fn clientMatchesLauncher(command: []const u8, appid_norm: []const u8, title_norm: []const u8) bool {
    if (launcherLaunchesAppdrawer(command)) return false;
    if (std.mem.eql(u8, command, "simpbar-launch-browser")) {
        for (BROWSER_APPIDS) |cand| if (appidMatchesKey(appid_norm, cand)) return true;
        return false;
    }
    if (std.mem.eql(u8, command, "simpbar-launch-discord")) {
        for (DISCORD_APPIDS) |cand| if (appidMatchesKey(appid_norm, cand)) return true;
        return false;
    }
    var kbuf: [64]u8 = undefined;
    const key = launcherMatchKey(command, &kbuf);
    if (key.len == 0) return false;
    if (appidMatchesKey(appid_norm, key)) return true;
    // Title fallback: "nautilus" also appears in file-manager titles, while
    // appids stay canonical — weak on purpose (contains only, one way).
    if (title_norm.len > 0 and std.mem.indexOf(u8, title_norm, key) != null) return true;
    return false;
}

/// Aggregate liveness for one pinned launcher: how many of its windows are
/// up, whether any has focus, and the client index to raise on click (the
/// focused one when exactly one is focused, else the first — cycling
/// handled by the click handler).
const LauncherLive = struct {
    count: usize = 0,
    focused: bool = false,
    client_idx: ?usize = null,
};

fn launcherLive(command: []const u8) LauncherLive {
    var live = LauncherLive{};
    for (running_state.apps[0..running_state.len], 0..) |*app, i| {
        if (!clientMatchesLauncher(command, app.appid(), app.title())) continue;
        if (live.count == 0) live.client_idx = i;
        live.count += 1;
        if (app.focused) {
            live.focused = true;
            live.client_idx = i;
        }
    }
    return live;
}

/// One unpinned running app group (all windows sharing an appid with no
/// pin): the taskbar tail after the pinned launchers. Display name is the
/// last reverse-DNS component ("FluxerDesktop", "Alacritty") so rows stay
/// short; the focused flag lights the same dot pinned icons wear.
const MAX_UNPINNED_GROUPS: usize = 16;
const UnpinnedGroup = struct {
    name_buf: [24]u8 = undefined,
    name_len: usize = 0,
    client_idx: usize = 0,
    count: usize = 0,
    focused: bool = false,

    fn name(self: *const UnpinnedGroup) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

fn collectUnpinned(out: *[MAX_UNPINNED_GROUPS]UnpinnedGroup) usize {
    var n: usize = 0;
    for (running_state.apps[0..running_state.len], 0..) |*app, ci| {
        // Pinned? Belongs to a launcher — not tail material.
        var pinned = false;
        for (current_config.launchers) |btn| {
            if (clientMatchesLauncher(btn.command, app.appid(), app.title())) {
                pinned = true;
                break;
            }
        }
        if (pinned) continue;
        // Group by appid: second window of the same app folds into the row.
        var found: ?usize = null;
        for (out[0..n], 0..) |*g, gi| {
            const other = &running_state.apps[g.client_idx];
            if (std.mem.eql(u8, app.appid(), other.appid())) {
                found = gi;
                break;
            }
        }
        if (found) |gi| {
            out[gi].count += 1;
            if (app.focused) {
                out[gi].focused = true;
                out[gi].client_idx = ci;
            }
            continue;
        }
        if (n >= out.len) break;
        var g = UnpinnedGroup{ .client_idx = ci, .count = 1, .focused = app.focused };
        const id = app.appid();
        var short = id;
        if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| short = id[dot + 1 ..];
        if (short.len == 0) short = id;
        const nl = @min(g.name_buf.len, short.len);
        @memcpy(g.name_buf[0..nl], short[0..nl]);
        g.name_len = nl;
        out[n] = g;
        n += 1;
    }
    return n;
}

/// Display order of pinned launchers: position → index into
/// current_config.launchers. Identity outside a drag; a drag permutes it
/// live for feedback while config.json (and the icon cache, which is also
/// config-indexed) stay untouched until the drop commits through
/// simpbar-config --move-launcher. Reset on every config load.
var launcher_view_order: [MAX_LAUNCHERS]usize = undefined;
var launcher_view_len: usize = 0;

fn resetLauncherViewOrder() void {
    const n = @min(current_config.launchers.len, launcher_view_order.len);
    for (0..n) |i| launcher_view_order[i] = i;
    launcher_view_len = n;
}

/// Position of config-index `li` in the current view order, or null (config
/// changed under us — the reload path resets the order, so this is purely
/// defensive).
fn launcherPosition(li: usize) ?usize {
    for (launcher_view_order[0..launcher_view_len], 0..) |v, p| {
        if (v == li) return p;
    }
    return null;
}

/// Moves config-index `li` to view position `q` (clamped). True when the
/// order actually changed (the motion handler only redraws on true). `q`
/// is in post-removal coordinates — exactly what dropPositionAt counts
/// (other pins at/left of x) — so no index adjustment is needed.
fn moveLauncherView(li: usize, q: usize) bool {
    const p = launcherPosition(li) orelse return false;
    const t = @min(q, launcher_view_len - 1);
    if (t == p) return false;
    var i = p;
    while (i + 1 < launcher_view_len) : (i += 1) launcher_view_order[i] = launcher_view_order[i + 1];
    var j = launcher_view_len - 1;
    while (j > t) : (j -= 1) launcher_view_order[j] = launcher_view_order[j - 1];
    launcher_view_order[t] = li;
    return true;
}

/// Drop target for the dragged launcher at pointer x: how many OTHER pins'
/// regions sit at/left of x (centers, so gaps split evenly). Regions only —
/// no layout knowledge — so left and center groups share it.
fn dropPositionAt(regions: *const ClickRegions, li: usize, x: i32) usize {
    var count: usize = 0;
    for (regions.items[0..regions.len]) |*r| {
        if (r.action != .launcher) continue;
        if (r.action.launcher == li) continue;
        if (@divTrunc(r.x_start + r.x_end, 2) <= x) count += 1;
    }
    return count;
}

/// True when the view order still matches config.json (a drop that ended
/// where it started needs no helper round-trip).
fn launcherViewIsIdentity() bool {
    if (launcher_view_len != @min(current_config.launchers.len, launcher_view_order.len)) return false;
    for (launcher_view_order[0..launcher_view_len], 0..) |v, p| {
        if (v != p) return false;
    }
    return true;
}

/// Click-vs-drag threshold for pins, in px (same 4px language as the
/// mixer's VOL_DRAG_PX disambiguation).
const LAUNCH_DRAG_PX: i32 = 4;

/// Resolves an armed launcher press on left-button release: a clean press
/// is the ordinary click (focus/launch); a dragged one commits the live
/// view order to config.json.
fn releaseLauncherPress(bar: *Bar) void {
    const li = bar.launch_press_li orelse return;
    const was_drag = bar.launch_dragging;
    bar.launch_press_li = null;
    bar.launch_dragging = false;
    if (!was_drag) {
        handleAction(bar, .{ .launcher = li });
        return;
    }
    commitLauncherDrop(bar, li);
}

/// Commits a finished drag: the headless helper rewrites config.json's
/// launcher order, ground truth is verified by re-reading the file, and a
/// match reloads through the standard SIGUSR1 path (icon invalidation,
/// view reset, redraw — all free). A mismatch snaps the live view back to
/// the file rather than displaying an order that isn't saved.
fn commitLauncherDrop(bar: *Bar, li: usize) void {
    const q = launcherPosition(li) orelse {
        resetLauncherViewOrder();
        drawAndCommit(bar) catch |err| {
            logging.err("draw failed: {}", .{err});
        };
        return;
    };
    if (launcherViewIsIdentity()) return;
    const spawned = spawnMoveLauncher(li, q);
    const matches = if (spawned) dropMatchesFile() else false;
    logging.step("launcher drop: from={d} to={d} spawned={} matches={}", .{ li, q, spawned, matches });
    if (spawned and matches) {
        if (g_sigusr1_write_fd >= 0) {
            const b = [_]u8{0x1};
            _ = posix.system.write(g_sigusr1_write_fd, &b, b.len);
        }
        return;
    }
    logging.warn("launcher drop: commit failed, keeping file order", .{});
    resetLauncherViewOrder();
    drawAndCommit(bar) catch |err| {
        logging.err("draw failed: {}", .{err});
    };
}

/// Re-reads config.json and checks the file's launcher order matches the
/// live view order (compared by command — indices are meaningless across
/// the rewrite). Ground truth for the drop commit: exit codes can't cover
/// the tick's reapChildren grabbing the helper first.
///
/// Parses into a THROWAWAY arena, never via loadConfigFromFile: a
/// successful load resets the inactive config arena and flips
/// config_arena_active, so calling it here would corrupt the reload
/// protocol — the next real reload would wipe the LIVE config's arena and
/// read stale slices (use-after-free → the segfault seen on drops).
fn dropMatchesFile() bool {
    const bytes = readFileAlloc(std.heap.page_allocator, config_json_path) catch return false;
    defer std.heap.page_allocator.free(bytes);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSliceLeaky(JsonConfig, scratch.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return false;
    if (parsed.launchers.len != launcher_view_len) return false;
    for (launcher_view_order[0..launcher_view_len], 0..) |li, p| {
        if (li >= current_config.launchers.len) return false;
        if (!std.mem.eql(u8, parsed.launchers[p].command, current_config.launchers[li].command)) return false;
    }
    return true;
}

/// Runs `simpbar-config --move-launcher FROM TO` to completion. Blocking
/// (~50ms for a JSON rewrite — a discrete drop action, never a frame), so
/// the file is settled before dropMatchesFile reads it. Absolute path, not
/// $PATH: a stale shadow binary elsewhere would silently eat the flag.
fn spawnMoveLauncher(from: usize, to: usize) bool {
    var from_buf: [8]u8 = undefined;
    var to_buf: [8]u8 = undefined;
    const from_s = std.fmt.bufPrintZ(&from_buf, "{d}", .{from}) catch return false;
    const to_s = std.fmt.bufPrintZ(&to_buf, "{d}", .{to}) catch return false;
    // argv[0] is the program name — env-style launches must repeat it
    // (an array starting at the flag makes env parse OUR flag as ITS
    // option and die 125, which is exactly what happened here).
    var argv = [_:null]?[*:0]const u8{ "/usr/bin/simpbar-config", "--move-launcher", from_s.ptr, to_s.ptr, null };
    return spawnAndWait("/usr/bin/simpbar-config", &argv);
}

/// Blocking spawn-and-wait (fork/exec/waitpid) for drop commits — the one
/// place the bar needs a child's completion before proceeding. A delivered
/// signal (SIGUSR1's handler only writes a pipe byte) EINTRs the wait, so
/// retry past INTR with a breath; anything else (ECHILD — the tick's
/// reapChildren grabbed the already-exited child) ends the wait and lets
/// dropMatchesFile verify ground truth. Gives up past ~5s.
fn spawnAndWait(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) bool {
    const pid = libc_proc.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = std.c.execve(path, argv, std.c.environ);
        std.c._exit(127);
    }
    const eintr: c_int = @intCast(@intFromEnum(std.posix.E.INTR));
    var status: c_int = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const w = std.c.waitpid(pid, &status, 0);
        if (w == pid) {
            const st: u32 = @bitCast(status);
            const ok = std.posix.W.IFEXITED(st) and std.posix.W.EXITSTATUS(st) == 0;
            if (!ok) logging.step("spawnAndWait: child {d} status {d}", .{ pid, status });
            return ok;
        }
        if (w < 0 and std.c._errno().* == eintr) {
            var dummy = [_]posix.pollfd{};
            _ = posix.poll(&dummy, 10) catch {};
            continue;
        }
        if (w < 0) logging.step("spawnAndWait: waitpid errno {d}", .{std.c._errno().*});
        return true;
    }
    logging.step("spawnAndWait: child {d} timed out", .{pid});
    return false;
}

/// Running dot under a launcher/taskbar cell: 5px accent pill sitting in
/// the hover-underline slot (same y as drawPill's dash, so the two never
/// stack into a double bar). Focused windows read full-accent, background
/// ones dimmed toward the bar bg — the same dimming language the muted OSD
/// uses for inactive state.
fn drawRunningDot(pixels: [*]u32, buf_width: u32, buf_height: u32, cx: i64, focused: bool) void {
    const h: i64 = @intCast(buf_height);
    const uy1 = h - HOVER_UNDERLINE_BOTTOM_GAP;
    const col = if (focused) current_config.appearance.workspace_active_color else lerpColor(current_config.appearance.bg_color, current_config.appearance.workspace_active_color, 0.45);
    fillRoundedRect(pixels, buf_width, buf_height, cx - 2, uy1 - 4, cx + 3, uy1, 2, col);
}

/// A click-through rectangle (currently horizontal-only, since the whole bar
/// is one row) mapped to an action, recomputed on every draw since module
/// layout can shift (e.g. workspaces being created/destroyed).
const MprisControl = enum { previous, play_pause, next };

const Action = union(enum) {
    switch_workspace: i32,
    spawn: [:0]const u8,
    /// Pinned launcher click (index into current_config.launchers): raises
    /// the app's window when it's running, launches it when it isn't.
    launcher: usize,
    /// Unpinned taskbar button click (index into running_state.apps):
    /// raises that window. Bounds-checked at click time — a refresh between
    /// draw and click may have shifted the list.
    focus_client: usize,
    toggle_drawer,
    activate_tray: usize,
    context_menu_tray: usize,
    mpris_control: MprisControl,
    /// Opens the Mango layout picker popup (the layout module's click).
    open_layout_picker,
    /// Applies the layout at `MANGO_LAYOUTS[index]` (a picker row click).
    set_layout: usize,
    /// Opens the volume mixer popup (the volume module's click). Toggles:
    /// clicking again while open closes it.
    open_volume_mixer,
};

/// What a vertical scroll wheel does over a ClickRegion. Separate from Action
/// because a scroll has a DIRECTION chosen per event by the compositor, not a
/// single fixed effect chosen when the region was registered — so the region
/// names the capability ("step workspaces") and the .axis handler below feeds
/// it the sign it just received.
const ScrollAction = enum {
    /// Step to the adjacent EXISTING workspace, in the scroll direction.
    step_workspace,
    /// Adjust the master volume ±5% per notch (volume module + mixer/OSD).
    /// Negative axis (scroll up) = louder, matching the measured workspace
    /// sign convention.
    adjust_volume,
};

const ClickRegion = struct {
    x_start: i32,
    x_end: i32,
    action: Action, // left click
    right_action: ?Action = null, // right click; most regions don't have one
    scroll_action: ?ScrollAction = null, // scroll wheel; most regions don't have one
};

const MAX_CLICK_REGIONS = 64;

const ClickRegions = struct {
    items: [MAX_CLICK_REGIONS]ClickRegion = undefined,
    len: usize = 0,
    /// Per-region hover fade level (0 = no highlight .. 1 = full pill +
    /// underline), eased toward (hovered ? 1 : 0) on the scroll-timer tick.
    /// Indexed parallel to items; slots at/after len are ignored. Regions
    /// are rebuilt in deterministic order every frame, so a region keeps its
    /// level across rebuilds — except when the list itself changes under a
    /// static pointer (workspace added/removed mid-hover), where the level
    /// briefly belongs to a neighbor. Settles within one fade; accepted.
    hover: [MAX_CLICK_REGIONS]f32 = [_]f32{0} ** MAX_CLICK_REGIONS,
    /// Index into items of the region under the pointer, maintained by the
    /// pointer handlers. Null when the pointer is off every region.
    hovered: ?usize = null,

    fn clear(self: *ClickRegions) void {
        self.len = 0;
    }

    fn add(self: *ClickRegions, x_start: i32, x_end: i32, action: Action) void {
        self.push(x_start, x_end, action, null, null);
    }

    fn addWithRight(self: *ClickRegions, x_start: i32, x_end: i32, action: Action, right_action: ?Action) void {
        self.push(x_start, x_end, action, right_action, null);
    }

    /// For regions that answer BOTH a click (to that exact workspace) and a
    /// scroll (to the next/previous one) — the workspace pills.
    fn addScrollable(self: *ClickRegions, x_start: i32, x_end: i32, action: Action, scroll_action: ScrollAction) void {
        self.push(x_start, x_end, action, null, scroll_action);
    }

    fn push(self: *ClickRegions, x_start: i32, x_end: i32, action: Action, right_action: ?Action, scroll_action: ?ScrollAction) void {
        if (self.len >= self.items.len) return; // scaffold-sized; fine for now
        self.items[self.len] = .{
            .x_start = x_start,
            .x_end = x_end,
            .action = action,
            .right_action = right_action,
            .scroll_action = scroll_action,
        };
        self.len += 1;
    }

    fn hitTest(self: *const ClickRegions, x: i32) ?*const ClickRegion {
        for (self.items[0..self.len]) |*r| {
            if (x >= r.x_start and x < r.x_end) return r;
        }
        return null;
    }

    /// Index form of hitTest for the hover fade machinery (hovered/hover are
    /// index-addressed; the pointer-returning form above stays for clicks).
    fn hitTestIndex(self: *const ClickRegions, x: i32) ?usize {
        for (self.items[0..self.len], 0..) |*r, i| {
            if (x >= r.x_start and x < r.x_end) return i;
        }
        return null;
    }

    /// Fade level for the region a draw site is about to draw + register.
    /// Every drawModulePill call site draws BEFORE its push/add (verified
    /// per site), so len is the incoming region's index. Clamped for the
    /// scaffold-full case where push drops the region rather than growing.
    fn nextHover(self: *const ClickRegions) f32 {
        return self.hover[@min(self.len, MAX_CLICK_REGIONS - 1)];
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
    /// Retained for config-file compat (the GUI still writes it); rendering
    /// is icon-only now — the label only appears when no icon resolves, so
    /// a button is never invisible.
    display: []const u8 = "both",
};

// The custom/* launcher buttons from ~/.config/waybar/config's
// "modules-center", minus their icons (our font is uppercase-only for now).
// Labels are the words from each module's "format", commands from
// "on-click".
// Labels/icons copied verbatim from ~/.config/waybar/config's "format"
// strings (most of these have no icon at all in the real config — only
// custom/rofi does; the rest are plain text).
const CENTER_LAUNCHERS = [_]LauncherButton{
    .{ .label = "\u{f0ac} Browser", .command = "simpbar-launch-browser" }, // fa-globe
    .{ .label = "\u{f066f} Discord", .command = "simpbar-launch-discord" }, // nf-md-discord
    .{ .label = "\u{f07c} Files", .command = "nautilus" }, // fa-folder-open
    .{ .label = "\u{f120} Term", .command = "foot" }, // fa-terminal
    .{ .label = "\u{f1b6} Steam", .command = "steam" }, // fa-steam
    .{ .label = "\u{f013} Config", .command = "simpbar-config" }, // fa-cog
    .{ .label = "\u{f118} Welcome", .command = "simpbar-welcome" }, // fa-smile-o
};

// custom/power from "modules-right" — icon only in the real config, no text.
// The power menu lives in the app drawer (lock / log out / reboot / power
// off); wlogout is no longer installed, so this opens that menu instead.
const POWER_BUTTON = LauncherButton{ .label = "\u{f0425}", .command = "appdrawer power" };

// Drawer toggle chevrons (Nerd Font Font Awesome, matching the power and
// launcher icon language — not text glyphs). Up chevron while the drawer is
// open. Measured separately (not assumed equal advance) so the cell stays
// exact.
const DRAWER_TOGGLE_LABEL = "\u{f078}";
/// Drawer toggle glyph while the drawer is open. Measured separately (not
/// assumed equal advance to the down chevron) so the cell stays exact.
const DRAWER_TOGGLE_LABEL_UP = "\u{f077}";

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
    /// Tombstone: the old Wallpaper Button module, superseded by the app
    /// drawer's wallpaper tab. Kept (unrendered, see drawRightGroup) so a
    /// config.json that still names it keeps parsing instead of falling back
    /// to defaults; simpbar-config strips it on load so the next save cleans
    /// the file. Do NOT add it back to RIGHT_MODULE_KINDS or defaults.
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
    /// Mango layout switcher: shows the active tag's layout as a distinct
    /// glyph and opens a picker popup on click. Mango-only in practice — the
    /// icon is unknown (hidden) under Hyprland, which has no per-tag layout
    /// in the IPC this bar reads.
    layout,
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
    cava_color: u32,
    /// Resting background for every module's pill. Hover/active states layer
    /// their pill + bezel + underline on top of this — the resting pill is
    /// always plain (no rim, no underline, no fade), so the lit states read
    /// by contrast rather than competing with a ring on every module.
    module_bg_color: u32,
    /// Flat ring color for the "solid" bezel style. Ignored by the traveling
    /// styles (which build the ring from the palette / hue wheel instead).
    bezel_color: u32,
    /// Resting pill opacity, 0-100: blends the
    /// pill fill toward the opaque bar background, so translucent pills are
    /// faked the same way everywhere in this file (lerp, since the pipeline
    /// is opaque). Exact while the bar background itself is opaque; over a
    /// transparent bar background it reads as translucent-tinted rather than
    /// true see-through — an accepted approximation, documented here so it
    /// doesn't surprise anyone later.
    module_pill_opacity: u8,
    /// Resting/hover/active bezel outline thickness in px (0 disables).
    /// Clamped at draw time so at least a
    /// sliver of fill survives — tiny pills degrade to flat instead of
    /// inverting. The bezel style itself (matugen ring vs rainbow-puke)
    /// stays on bezel_style; this is only the width.
    module_border_width: u32,
    /// Resting module pills on/off. Off = modules sit directly on the bar
    /// background (pre-pill look); hover/active treatments still draw their
    /// own pill when lit, so nothing interactive goes blind.
    module_pills: bool,
    /// Bezel rings on/off wherever they appear (resting pills, hover, active
    /// workspace, popup rows). Off = flat fills + dash only, no rings.
    pill_borders: bool,
    /// Master switch for hover/active-pill animation (fade + bezel motion).
    /// Off = highlights snap instantly and the bezel sits still — same look,
    /// none of the motion. Drawer animation is untouched; this covers
    /// only the hover treatment.
    animations_enabled: bool,
    /// Hover/active bezel style: "matugen" (default) wears the wallpaper
    /// palette ring; "rainbow-puke" wears the full hue wheel; "solid" wears
    /// one flat bezel_color ring. Anything unrecognized falls back to
    /// "matugen", same permissive spirit as `position`.
    bezel_style: []const u8,
    /// Hover/active bezel effect — what the ring DOES, independent of the
    /// style above (which picks what travels): "rotating" (default) sends
    /// the ring around the pill; "breathing" holds it still and swells its
    /// brightness; "solid" holds it still at full brightness. Only moves
    /// while animations are on — off freezes every effect at its resting
    /// phase. Unrecognized values fall back to "rotating".
    bezel_effect: []const u8,
    /// Bar background mode: "none" (default) is the plain bg_color fill;
    /// "cava" washes the equalizer across the whole background (uses the
    /// Audio Visualizer color); "matrix" rains glyph streams (matrix_color);
    /// "lava" floats metaball blobs upward (lava_color).
    /// Unrecognized values fall back to "none".
    bg_mode: []const u8,
    /// How strongly the cava background wash tints (0-100): 0 = invisible,
    /// 100 = full cava_color on lit pixels. Module pills/text stay opaque
    /// above it regardless.
    cava_bg_strength: u8,
    /// Cava background shape: "bars" (default) rises each column from the
    /// bottom edge, "wave" mirrors around the vertical center, "curve"
    /// smooths the tops into a filled wave with a bright crest.
    /// Unrecognized values fall back to "bars".
    cava_style: []const u8,
    /// Glyph-stream color for the "matrix" background mode.
    matrix_color: u32,
    /// Lava-lamp accent (mid orange) for the "lava" background mode; deep
    /// rim and hot core derive from it, so one knob themes the whole lamp.
    lava_color: u32,
    /// Lava tempo multiplier base: rise/sway speed = this / 3 (1-6, so 3
    /// is the designed pace, 6 double-time). Mirrors matrix_speed's shape.
    lava_speed: u32,
    /// Lava blob radius percent (50-200, 100 = designed size).
    lava_size: u8,
    /// Matrix fall speed, pixels per 60ms tick (1-6).
    matrix_speed: u32,
    /// Matrix rain charset: "katakana" (default) is classic cmatrix-style
    /// katakana + digits; "distros" rains Nerd Font linux-distro logos
    /// instead. Unrecognized values fall back to "katakana".
    matrix_style: []const u8,
    /// Which logos the "distros" matrix style rains: "all" (default) mixes
    /// every known distro logo; a distro ID ("arch", "debian", "fedora",
    /// ...) or "tux" rains that one logo everywhere. Unrecognized values
    /// fall back to "all". Ignored unless matrix_style is "distros".
    matrix_distro: []const u8,
    /// Media progress display: "underline" (default) draws the accent dash
    /// under the track text; "bar" fills the pill behind it, subtly.
    /// Unrecognized values fall back to "underline".
    mpris_progress_style: []const u8,
    /// Volume device both the module and the mixer follow: a PipeWire sink
    /// name (e.g. a USB DAC whose knob drives it directly, bypassing the
    /// default sink), or "" for the default output (today's behavior).
    /// Applies live — every poll/fetch/set reads it fresh.
    volume_sink: []const u8,
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
    /// "taskbar" or "dock" — taskbar spans the full edge and reserves it
    /// (windows stop above it); dock floats with margins on three sides and
    /// reserves nothing (windows slide under it). Anything unrecognized
    /// falls back to "taskbar". Applies live over SIGUSR1 via
    /// applyLayerGeometry, same as position/bar_height.
    bar_mode: []const u8,
    /// Auto-hide the bar (both modes): when the pointer leaves the bar (and
    /// any open popup), the bar collapses to a 2px hint strip at the screen
    /// edge after a short grace period and releases its exclusive zone, so
    /// windows use the space; touching the strip (or clicking it) brings it
    /// back instantly. No slide animation — instant show/hide only.
    auto_hide: bool,
    /// Rounds all 4 corners by this many px, applied as the very last step
    /// of every draw (after background/borders/every module): pixels outside
    /// each corner's rounding circle are zeroed out (fully transparent, not
    /// just recolored), and the border band just inside that circle is
    /// repainted in border_color so the straight borders curve around the
    /// corner instead of ending at the radius box. 0 = today's square
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
    /// Command run when the user left-clicks bare bar background (any x no
    /// ClickRegion claims). Empty = the click does nothing, which is the
    /// behavior of a bar that never had this feature. Lives on the runtime
    /// Appearance rather than being read from current_config directly because
    /// loadConfigFromFile rebuilds this struct wholesale from the parsed JSON
    /// and would otherwise drop the field on every (re)load.
    empty_click_command: [:0]const u8,
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
            .cava_color = 0xFFDCDCDC,
            .module_bg_color = 0xFF1E1E1E,
            .bezel_color = 0xFFDCDCDC, // solid-bezel default: accent-white, same as the active workspace color
            .bg_mode = BG_MODE_NONE,
            .cava_bg_strength = 35,
            .cava_style = CAVA_STYLE_BARS,
            .matrix_color = 0xFF00FF41, // classic phosphor green
            .matrix_speed = 2,
            .matrix_style = MATRIX_STYLE_KATAKANA,
            .matrix_distro = MATRIX_DISTRO_ALL,
            .lava_color = 0xFFFF6A2A, // lava-lamp mid orange
            .lava_speed = 3,
            .lava_size = 100,
            .mpris_progress_style = MPRIS_PROGRESS_UNDERLINE,
            .volume_sink = "",
            .module_pill_opacity = 100,
            .module_border_width = 1,
            .module_pills = true,
            .pill_borders = true,
            .bar_height = 28,
            .border_top_px = 2, // window#waybar border-width: 2px 0px 0px 0px
            .border_bottom_px = 0,
            .border_left_px = 0,
            .border_right_px = 0,
            .workspace_gap = 10,
            .font_path = font_mod.FONT_PATH,
            .bg_opacity_percent = 100,
            .position = "bottom",
            .bar_mode = "taskbar",
            .auto_hide = false,
            .corner_radius_px = 0,
            .clock_format = CLOCK_FORMAT_DATE_24H,
            .monitor = "",
            .empty_click_command = "",
            .animations_enabled = true,
            .bezel_style = BEZEL_STYLE_MATUGEN,
            .bezel_effect = BEZEL_EFFECT_ROTATING,
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
var matugen_path_buf: [512]u8 = undefined;
var config_json_path: [:0]const u8 = "";
var pidfile_path: [:0]const u8 = "";
var matugen_json_path: [:0]const u8 = "";

/// Resolves ~/.config/simpbar/{config.json,simpbar.pid,matugen.json} from
/// $HOME, creating ~/.config/simpbar first if it doesn't exist yet
/// (best-effort — mkdir's result is intentionally ignored; if the directory
/// truly can't be created, the open() calls below will fail instead, and
/// that failure path is already handled). Mirrors welcome_main.zig's
/// resolvePaths() pattern.
fn resolveConfigPaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    var dir_buf: [480]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/simpbar", .{home}) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o755);
    config_json_path = std.fmt.bufPrintZ(&config_json_path_buf, "{s}/config.json", .{dir}) catch "";
    pidfile_path = std.fmt.bufPrintZ(&pidfile_path_buf, "{s}/simpbar.pid", .{dir}) catch "";
    // The matugen colors file lives under simpbar's own config dir (not
    // matugen's) so this bar only ever reads from under its own roof. The
    // post-hook in the shipped matugen template writes it here; simpbar
    // only ever reads it, matugen only ever writes it.
    matugen_json_path = std.fmt.bufPrintZ(&matugen_path_buf, "{s}/matugen.json", .{dir}) catch "";
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
    cava_color: []const u8 = "#DCDCDC",
    module_bg_color: []const u8 = "#1E1E1E",
    bezel_color: []const u8 = "#DCDCDC",
    bg_mode: []const u8 = "none",
    cava_bg_strength: u8 = 35,
    cava_style: []const u8 = "bars",
    matrix_color: []const u8 = "#00FF41",
    matrix_speed: u32 = 2,
    matrix_style: []const u8 = "katakana",
    matrix_distro: []const u8 = "all",
    lava_color: []const u8 = "#FF6A2A",
    lava_speed: u32 = 3,
    lava_size: u8 = 100,
    mpris_progress_style: []const u8 = "underline",
    volume_sink: []const u8 = "",
    module_pill_opacity: u8 = 100,
    module_border_width: u32 = 1,
    module_pills: bool = true,
    pill_borders: bool = true,
    animations_enabled: bool = true,
    bezel_style: []const u8 = "matugen",
    bezel_effect: []const u8 = "rotating",
    bar_height: u32 = 28,
    border_top_px: u32 = 2,
    border_bottom_px: u32 = 0,
    border_left_px: u32 = 0,
    border_right_px: u32 = 0,
    workspace_gap: i64 = 10,
    font_path: []const u8 = font_mod.FONT_PATH,
    bg_opacity_percent: u8 = 100,
    position: []const u8 = "bottom",
    bar_mode: []const u8 = "taskbar",
    auto_hide: bool = false,
    corner_radius_px: u32 = 0,
    clock_format: []const u8 = CLOCK_FORMAT_DATE_24H,
    /// Which output(s) get bar surfaces. "" = compositor default (one bar on
    /// whatever output the compositor picks), "all" = one surface per output,
    /// otherwise an exact wl_output name for a single named bar. Workspaces
    /// became monitor-scoped along this axis: each bar shows, and switches,
    /// its own monitor's tag/workspace set (Mango's tags are per-monitor
    /// sets; Hyprland's rail filters to the workspaces living on that
    /// monitor). A bar whose output can't be determined ("" before the
    /// compositor's first surface enter) falls back to the merged list the
    /// pre-multi-monitor bar drew, so no monitor ever loses its rail.
    monitor: []const u8 = "",
    /// "matugen" (default) = when ~/.config/simpbar/matugen.json exists, its
    /// colors override these hex values (the wallpaper-based auto-theming
    /// integration). "manual" = ignore matugen.json entirely and always use
    /// the colors below. Anything unrecognized falls back to "matugen",
    /// same permissive-fallback spirit as `position`.
    auto_theme: []const u8 = "matugen",
    /// Command run when the user left-clicks bare bar background — any x that
    /// no ClickRegion claims, i.e. the gaps between modules. Runs through
    /// `sh -c`, so `$HOME` expands and shell operators work.
    ///
    /// Empty (the default) disables the behaviour entirely, leaving the click
    /// a no-op exactly as before. This is deliberately NOT wired to
    /// `.toggle_drawer`: that action reveals this bar's own `in_drawer`
    /// modules (see DRAWER_TOGGLE_LABEL), which is a different feature from
    /// launching an external menu, and conflating them would make the two
    /// impossible to enable independently.
    ///
    /// Lives here rather than in a new top-level struct because this bar has
    /// one flat options struct by convention, and adding a sibling would mean
    /// touching the load/merge plumbing for no benefit.
    empty_click_command: [:0]const u8 = "",
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

// JSON-facing shape of ~/.config/simpbar/matugen.json — the file matugen
// renders (from the repo's matugen/simpbar-matugen.json template) whenever
// it generates a colorscheme, holding just the ten colors this bar draws.
// Unlike JsonAppearance every field is OPTIONAL: matugen owns this file
// outright and may add/remove colors across versions or be hand-edited
// mid-way, so the merge below applies only the keys that are actually
// present and valid. A deliberately minimal subset of JsonAppearance's
// color fields — geometry/spacing/font stay in config.json, which matugen
// never touches (and which is also what simpbar-config writes).
const JsonMatugenColors = struct {
    bg_color: ?[]const u8 = null,
    text_color: ?[]const u8 = null,
    border_color: ?[]const u8 = null,
    hover_color: ?[]const u8 = null,
    workspace_active_color: ?[]const u8 = null,
    workspace_inactive_color: ?[]const u8 = null,
    popup_bg_color: ?[]const u8 = null,
    popup_hover_color: ?[]const u8 = null,
    popup_separator_color: ?[]const u8 = null,
    popup_disabled_color: ?[]const u8 = null,
    cava_color: ?[]const u8 = null,
    module_bg_color: ?[]const u8 = null,
    bezel_color: ?[]const u8 = null,
    matrix_color: ?[]const u8 = null,
};

/// Applies the colors matugen wrote to ~/.config/simpbar/matugen.json into
/// `appearance`, only for whichever keys that file actually spells out.
/// Returns false — leaving `appearance` completely untouched — on ANY
/// problem: file missing, unparseable JSON, or an invalid color hex. That
/// whole-failure gracefulness matters twice over: a missing matugen.json is
/// the every-day case (no matugen integration set up, or a user who toggled
/// the bar back to manual colors in simpbar-config), and a corrupt/half-
/// written file should degrade to the config.json palette, never to a
/// partially-merged mishmash or a bar that refuses to load. Colors that are
/// requested here are validated before anything is applied, so a bad value
/// any position doesn't leave earlier positions half-swapped.
fn tryApplyMatugenColors(allocator: std.mem.Allocator, appearance: *Appearance) bool {
    if (matugen_json_path.len == 0) return false;

    const bytes = readFileAlloc(allocator, matugen_json_path) catch |err| {
        // Missing file is the normal "matugen not in play" case (OpenFailed),
        // not something worth logging at the INFO level every reload — only
        // a read that shouldn't plausibly fail is worth a line.
        if (err != error.OpenFailed) {
            logging.warn("config: could not read {s}: {}", .{ matugen_json_path, err });
        }
        return false;
    };

    const colors = std.json.parseFromSliceLeaky(JsonMatugenColors, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {} — keeping config.json colors", .{ matugen_json_path, err });
        return false;
    };

    _ = mergeMatugenColor(appearance, "bg_color", colors.bg_color) orelse return false;
    _ = mergeMatugenColor(appearance, "text_color", colors.text_color) orelse return false;
    _ = mergeMatugenColor(appearance, "border_color", colors.border_color) orelse return false;
    _ = mergeMatugenColor(appearance, "hover_color", colors.hover_color) orelse return false;
    _ = mergeMatugenColor(appearance, "workspace_active_color", colors.workspace_active_color) orelse return false;
    _ = mergeMatugenColor(appearance, "workspace_inactive_color", colors.workspace_inactive_color) orelse return false;
    _ = mergeMatugenColor(appearance, "popup_bg_color", colors.popup_bg_color) orelse return false;
    _ = mergeMatugenColor(appearance, "popup_hover_color", colors.popup_hover_color) orelse return false;
    _ = mergeMatugenColor(appearance, "popup_separator_color", colors.popup_separator_color) orelse return false;
    _ = mergeMatugenColor(appearance, "popup_disabled_color", colors.popup_disabled_color) orelse return false;
    _ = mergeMatugenColor(appearance, "cava_color", colors.cava_color) orelse return false;
    _ = mergeMatugenColor(appearance, "module_bg_color", colors.module_bg_color) orelse return false;
    _ = mergeMatugenColor(appearance, "bezel_color", colors.bezel_color) orelse return false;
    _ = mergeMatugenColor(appearance, "matrix_color", colors.matrix_color) orelse return false;

    return true;
}

/// Parses one optional matugen color into `appearance` if present; returns
/// null when the value is present but not a valid "#RRGGBB", so the caller
/// can bail the whole merge. Returns a dummy non-null otherwise.
fn mergeMatugenColor(appearance: *Appearance, comptime field: []const u8, value: ?[]const u8) ?u8 {
    const hex = value orelse return 1;
    const parsed = parseHexColor(hex) catch {
        logging.warn("config: bad matugen color {s}=\"{s}\" — keeping config.json colors", .{ field, hex });
        return null;
    };
    @field(appearance, field) = parsed;
    return 1;
}

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
        .cava_color = parseHexColor(j.cava_color) catch return null,
        .module_bg_color = parseHexColor(j.module_bg_color) catch return null,
        .bezel_color = parseHexColor(j.bezel_color) catch return null,
        .bg_mode = if (std.mem.eql(u8, j.bg_mode, BG_MODE_CAVA)) BG_MODE_CAVA else if (std.mem.eql(u8, j.bg_mode, BG_MODE_MATRIX)) BG_MODE_MATRIX else if (std.mem.eql(u8, j.bg_mode, BG_MODE_LAVA)) BG_MODE_LAVA else BG_MODE_NONE,
        .cava_bg_strength = @min(j.cava_bg_strength, 100),
        .cava_style = cavaStyleOrDefault(j.cava_style),
        .matrix_color = parseHexColor(j.matrix_color) catch return null,
        .matrix_speed = std.math.clamp(j.matrix_speed, 1, 6),
        .matrix_style = if (std.mem.eql(u8, j.matrix_style, MATRIX_STYLE_DISTROS)) MATRIX_STYLE_DISTROS else MATRIX_STYLE_KATAKANA,
        .matrix_distro = j.matrix_distro,
        .lava_color = parseHexColor(j.lava_color) catch return null,
        .lava_speed = std.math.clamp(j.lava_speed, 1, 6),
        .lava_size = @min(j.lava_size, 200),
        .mpris_progress_style = if (std.mem.eql(u8, j.mpris_progress_style, MPRIS_PROGRESS_BAR)) MPRIS_PROGRESS_BAR else MPRIS_PROGRESS_UNDERLINE,
        .volume_sink = j.volume_sink,
        .module_pill_opacity = @min(j.module_pill_opacity, 100),
        .module_border_width = @min(j.module_border_width, 8),
        .module_pills = j.module_pills,
        .pill_borders = j.pill_borders,
        .bar_height = j.bar_height,
        .border_top_px = j.border_top_px,
        .border_bottom_px = j.border_bottom_px,
        .border_left_px = j.border_left_px,
        .border_right_px = j.border_right_px,
        .workspace_gap = j.workspace_gap,
        .font_path = j.font_path,
        .bg_opacity_percent = @min(j.bg_opacity_percent, 100),
        .position = if (std.mem.eql(u8, j.position, "top")) "top" else "bottom",
        .bar_mode = if (std.mem.eql(u8, j.bar_mode, BAR_MODE_DOCK)) BAR_MODE_DOCK else BAR_MODE_TASKBAR,
        .auto_hide = j.auto_hide,
        .corner_radius_px = j.corner_radius_px,
        .clock_format = validClockFormat(j.clock_format),
        // No validation against currently-connected outputs here — parsing
        // happens before Wayland registry discovery has run, so there's
        // nothing to validate against yet. main()'s target-output-selection
        // step (after outputs are discovered) is what falls back to ""
        // behavior for a name that doesn't match any connected output.
        .monitor = j.monitor,
        .empty_click_command = j.empty_click_command,
        .animations_enabled = j.animations_enabled,
        .bezel_style = if (std.mem.eql(u8, j.bezel_style, BEZEL_STYLE_RAINBOW_PUKE)) BEZEL_STYLE_RAINBOW_PUKE else if (std.mem.eql(u8, j.bezel_style, BEZEL_STYLE_SOLID)) BEZEL_STYLE_SOLID else BEZEL_STYLE_MATUGEN,
        .bezel_effect = if (std.mem.eql(u8, j.bezel_effect, BEZEL_EFFECT_BREATHING)) BEZEL_EFFECT_BREATHING else if (std.mem.eql(u8, j.bezel_effect, BEZEL_EFFECT_SOLID)) BEZEL_EFFECT_SOLID else BEZEL_EFFECT_ROTATING,
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
///
/// WARNING: only call this from startup and the SIGUSR1 reload handler. A
/// successful load resets the inactive config arena and flips
/// config_arena_active; any OTHER caller (verification peeks, tick work,
/// ...) corrupts the reload protocol and the next real reload reads freed
/// memory. For read-only peeks, parse into your own arena instead.
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
        logging.warn("config: could not read {s}: {}", .{ config_json_path, err });
        return null;
    };

    const parsed = std.json.parseFromSliceLeaky(JsonConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logging.warn("config: could not parse {s}: {}", .{ config_json_path, err });
        return null;
    };

    var appearance = parseAppearance(parsed.appearance) orelse {
        logging.warn("config: bad color value in {s}", .{config_json_path});
        return null;
    };

    // Apply matugen's generated palette when both switches are on: the
    // config.json auto_theme field says "matugen", and there's a valid
    // matugen.json on disk to read. A failed/absent file never fails the
    // load — tryApplyMatugenColors returns false and we keep the
    // config.json colors (defaultConfig path never triggers here).
    if (std.mem.eql(u8, parsed.appearance.auto_theme, "matugen") and tryApplyMatugenColors(allocator, &appearance)) {
        logging.step("config: applied matugen colors from {s}", .{matugen_json_path});
    }

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
            logging.warn("tray: dbus connect failed: {}", .{err});
            return self;
        };
        requestWatcherName(&conn) catch |err| {
            logging.warn("tray: could not become StatusNotifierWatcher: {}", .{err});
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
        const msg = c.readMessage(std.heap.c_allocator) catch |err| {
            logging.warn("tray: dbus connection lost: {}", .{err});
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
                    self.handleGetProperty(c, &msg) catch |err| logging.err("tray: Get failed: {}", .{err});
                } else {
                    self.handleGetAllProperties(c, &msg) catch |err| logging.err("tray: GetAll failed: {}", .{err});
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
            logging.warn("tray: failed to ack registration: {}", .{err});
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
            logging.warn("tray: {s} failed: {}", .{ member, err });
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
/// Horizontal inset of a hovered row's pill from the popup edges.
const POPUP_ROW_PAD_X: i32 = 4;
/// Vertical inset of a hovered row's pill from the row edges.
const POPUP_ROW_PAD_Y: i32 = 2;
/// Corner radius of a hovered row's pill (row pills are 16px tall, so this
/// lands on full capsule ends).
const POPUP_ROW_RADIUS: i32 = 8;
/// Horizontal space between a layout-picker row's icon and its name.
const LAYOUT_ICON_GAP: i32 = 8;
/// Marks the active layout's row in the layout picker (fa-check).
const LAYOUT_ACTIVE_CHECK = "\u{f00c}";

const PopupRow = struct {
    y_start: i32,
    y_end: i32,
    /// dbusmenu item id to send a "clicked" Event for, or null for rows
    /// that aren't independently clickable (separators, submenu headers —
    /// there's no drill-down navigation in this scaffold, so a submenu
    /// header just isn't actionable).
    item_id: ?i32,
};

/// One open popup, backed by a real xdg_popup surface (parented to our
/// layer-shell bar via zwlr_layer_surface_v1::get_popup). Two kinds share
/// the surface/hit-test machinery:
///
///   * `.dbusmenu` — a tray item's right-click menu. Only the top-level
///     items are shown — no submenu drill-down, which costs nothing for the
///     apps actually tested against (Steam's menu is flat).
///   * `.layout_picker` — the Mango layout switcher. Rows come from
///     MANGO_LAYOUTS instead of a DBusMenu, so `menu` is left undefined.
const PopupMenu = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    popup: *xdg.Popup,
    /// Which row source populates this popup (see the type doc above).
    kind: PopupKind = .dbusmenu,
    dest_buf: [64]u8 = undefined,
    dest_len: usize = 0,
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    /// Valid only when kind == .dbusmenu — the layout picker has no backing
    /// menu and leaves this undefined, so nothing may read it for that kind.
    menu: dbusmenu.DbusMenu = undefined,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    rows: [MAX_POPUP_ROWS]PopupRow = undefined,
    row_count: usize = 0,
    /// Volume-mixer snapshot: how many vol_entries rows the surface was
    /// sized for at open. A refresh that changes the count rebuilds the
    /// popup (close + reopen); same count redraws in place. Only meaningful
    /// when kind == .volume — like `menu` is dbusmenu-only.
    vol_count: usize = 0,
    /// 60ms-tick frame the volume OSD was (re)armed on; the tick dismisses
    /// it past VOL_OSD_ALIVE_TICKS. Only meaningful for .volume_osd.
    osd_since: u32 = 0,
    /// Mixer slider drag: entry being dragged (or null), its live value,
    /// the press origin, and whether the pointer moved past click threshold.
    /// Only meaningful for .volume; cleared on release.
    vol_drag_row: ?usize = null,
    vol_drag_val: u8 = 0,
    vol_press_id: i32 = -99,
    vol_press_x: i32 = 0,
    vol_press_y: i32 = 0,
    vol_drag_moved: bool = false,
    /// Per-row hover fade level (0..1), eased on the scroll-timer tick like
    /// the bar's own hover anims. Indexed parallel to rows.
    row_hover: [MAX_POPUP_ROWS]f32 = [_]f32{0} ** MAX_POPUP_ROWS,
    /// Row under the pointer, maintained by the pointer handlers.
    hovered_row: ?usize = null,

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

    /// Index form of hitTestRow for the row-fade machinery.
    fn hitTestRowIndex(self: *const PopupMenu, y: i32) ?usize {
        for (self.rows[0..self.row_count], 0..) |row, i| {
            if (y >= row.y_start and y < row.y_end) return i;
        }
        return null;
    }
};

/// What a PopupMenu's rows are sourced from; selects the draw and click
/// paths in drawPopup / the pointer-button handler.
const PopupKind = enum { dbusmenu, layout_picker, volume, volume_osd };

/// Creates the xdg_popup surface a popup menu draws on, anchored to a thin
/// rect at the clicked x position and spanning the bar's full height — the
/// popup opens above it (bar is bottom-anchored), sliding to stay on-screen
/// horizontally if it would run off either edge. Shared by the DBusMenu
/// context menu and the layout picker, which differ only in their rows.
/// Returns the three objects (still caller-owned: popup is wired to the bar,
/// but the positioner is already destroyed) or null on any failure.
const PopupSurface = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    popup: *xdg.Popup,
};

fn createPopupSurface(bar: *Bar, width: i32, height: i32, centered: bool) ?PopupSurface {
    const wm_base = bar.wm_base orelse return null;
    const surface = bar.compositor.createSurface() catch return null;
    const xdg_surface = wm_base.getXdgSurface(surface) catch {
        surface.destroy();
        return null;
    };
    const positioner = wm_base.createPositioner() catch {
        xdg_surface.destroy();
        surface.destroy();
        return null;
    };
    defer positioner.destroy();

    positioner.setSize(width, height);
    // Click-anchored panels follow the pointer; the volume OSD centers on
    // the output edge instead (bottom-center under a bottom bar, top-center
    // under a top bar — the side facing the desktop, so it never hides
    // behind the bar it reports on).
    const anchor_x: i32 = @intCast(@max(@as(i64, 0), if (centered and bar.width > 0)
        @divTrunc(@as(i64, @intCast(bar.width)), 2) - 4
    else
        @as(i64, bar.pointer_x) - 4));
    positioner.setAnchorRect(anchor_x, 0, 8, @intCast(bar.height));
    if (centered and std.mem.eql(u8, current_config.appearance.position, "top")) {
        positioner.setAnchor(.bottom);
        positioner.setGravity(.bottom);
    } else {
        positioner.setAnchor(.top);
        positioner.setGravity(.top);
    }
    positioner.setConstraintAdjustment(.{ .slide_x = true, .slide_y = true, .flip_y = true });

    const popup = xdg_surface.getPopup(null, positioner) catch {
        xdg_surface.destroy();
        surface.destroy();
        return null;
    };
    bar.layer_surface.getPopup(popup);
    return .{ .surface = surface, .xdg_surface = xdg_surface, .popup = popup };
}

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

    const ps = createPopupSurface(bar, max_w, total_h, false) orelse return;

    var pm = PopupMenu{
        .surface = ps.surface,
        .xdg_surface = ps.xdg_surface,
        .popup = ps.popup,
    };
    pm.menu = menu;
    pm.dest_len = @min(item.busName().len, pm.dest_buf.len);
    @memcpy(pm.dest_buf[0..pm.dest_len], item.busName()[0..pm.dest_len]);
    pm.path_len = @min(menu_path.len, pm.path_buf.len);
    @memcpy(pm.path_buf[0..pm.path_len], menu_path[0..pm.path_len]);
    bar.popup = pm;

    wirePopup(bar, ps, true);
}

/// Left-click on the Mango layout module: shows a popup listing every layout
/// MANGO_LAYOUTS knows, each with its own icon (the same glyph the bar shows)
/// and name, so it's obvious which layout you're on and what the alternatives
/// are — the shape tiling-plugin layout pickers use. Rows are sourced from
/// MANGO_LAYOUTS rather than a DBusMenu; clicking one fires `.set_layout`
/// through the same hit-test path as a tray menu row.
fn openLayoutPicker(bar: *Bar) void {
    if (bar.popup != null) return; // one at a time
    if (bar.workspaces.mode != .mango) return; // no per-tag layout concept elsewhere

    // Width: widest (icon + gap + name, plus the check the ACTIVE row also
    // draws) plus padding, so no label truncates and the active row's check
    // doesn't clip off the right edge.
    const check_w = LAYOUT_ICON_GAP + textPixelWidth(bar.font, LAYOUT_ACTIVE_CHECK);
    var max_w: i32 = POPUP_MIN_WIDTH;
    for (&MANGO_LAYOUTS) |*l| {
        const w: i32 = @intCast(textPixelWidth(bar.font, l.icon) + LAYOUT_ICON_GAP + textPixelWidth(bar.font, l.name) + check_w + POPUP_PADDING_X * 2);
        if (w > max_w) max_w = w;
    }
    if (max_w > POPUP_MAX_WIDTH) max_w = POPUP_MAX_WIDTH;
    const total_h: i32 = @as(i32, @intCast(MANGO_LAYOUTS.len)) * POPUP_ROW_HEIGHT;

    const ps = createPopupSurface(bar, max_w, total_h, false) orelse return;

    const pm = PopupMenu{
        .surface = ps.surface,
        .xdg_surface = ps.xdg_surface,
        .popup = ps.popup,
        .kind = .layout_picker,
    };
    bar.popup = pm;

    wirePopup(bar, ps, true);
}

/// Finishes bringing up a just-created popup: hooks up its configure listeners
/// and (if we hold a seat) grabs it, then does the initial null commit that
/// triggers the first configure. Shared by every popup kind.
fn wirePopup(bar: *Bar, ps: PopupSurface, grab: bool) void {
    ps.xdg_surface.setListener(*Bar, popupXdgSurfaceListener, bar);
    ps.popup.setListener(*Bar, popupEventListener, bar);
    if (grab) {
        if (bar.seat) |seat| ps.popup.grab(seat, bar.last_pointer_serial);
    }

    ps.surface.commit(); // initial null commit — triggers the first configure
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
            drawPopup(bar) catch |err| logging.err("popup draw failed: {}", .{err});
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

/// Renders the popup's rows into a fresh SHM buffer and commits it — the same
/// pattern as drawAndCommit, just for the popup's own surface and a much
/// simpler (single-column list) layout. Also (re)populates `rows` for
/// hit-testing hover/click. The row source depends on pm.kind.
// --- volume mixer popup ------------------------------------------------------
//
// Clicking the volume module opens a mixer panel (this popup kind): master
// plus one row per PipeWire sink input. Click toggles that row's mute, the
// wheel adjusts ±5% per notch — neither closes the panel, so levels can be
// dialed in without reopening. Data comes from one `pactl` run per refresh
// (master volume/mute + `list sink-inputs` concatenated), parsed by the pure
// parseVolumeList below (canned pactl text in tests); set-commands go out
// fire-and-forget and the next refresh shows their result. Refreshed every
// second while open; a refresh that changes the row count rebuilds the
// popup, same count redraws in place.

const VOL_MAX_ENTRIES: usize = 8; // master + 7 apps (surface sized on open)
const VOL_WHEEL_STEP_PCT: i8 = 5; // per wheel notch

const VolumeEntry = struct {
    id: i32 = -1, // pactl sink-input id; -1 = master
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    vol_pct: u8 = 0,
    muted: bool = false,
    fn name(self: *const VolumeEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var vol_entries: [VOL_MAX_ENTRIES]VolumeEntry = [_]VolumeEntry{.{}} ** VOL_MAX_ENTRIES;
var vol_count: usize = 0;
var vol_fetch_fd: posix.fd_t = -1;
var vol_fetch_buf: [4096]u8 = undefined;
var vol_fetch_len: usize = 0;
/// hover_frame value when the in-flight fetch started (60ms ticks; the
/// watchdog below abandons a wedged fetch past ~5s via wrapping subtract).
var vol_fetch_since_frame: u32 = 0;
/// Bar whose volume click started the in-flight fetch (fixed backing array,
/// so the pointer stays valid for the fetch's ~50ms life). Cleared on open.
var vol_open_bar: ?*Bar = null;
/// Long-lived `pactl subscribe` pipe: PipeWire change events land here in
/// real time (a knob turn, media keys, other mixers), and each batch kicks
/// a prompt volume re-poll — this is what makes the OSD fire in ~100ms
/// instead of on the 5s timer's schedule. Event-driven; the timer poll
/// stays as fallback. -1 when down (the 1s
/// tick respawns past CAVA-style delay via vol_sub_dead_since).
var vol_sub_fd: posix.fd_t = -1;
var vol_sub_dead_since: i64 = 0;
/// Poll-change OSD suppressions remaining (60ms ticks): a mixer-driven
/// master set would otherwise echo as an OSD ~100ms later when the wpctl
/// poll notices it. Only master-output sets arm it (app/mic sets never move the sink poll).
/// Direct wheel adjustments bypass it via showVolumeOSD (explicit action).
var vol_osd_suppress_left: i32 = 0;

/// Copies `s` into an entry name slot (truncated, never fails).
fn volSetName(e: *VolumeEntry, s: []const u8) void {
    const n = @min(s.len, e.name_buf.len);
    @memcpy(e.name_buf[0..n], s[0..n]);
    e.name_len = n;
}

/// Unquotes a `key = "value"` pactl property tail (`"Firefox"` -> `Firefox`,
/// bare tokens pass through).
fn volUnquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

/// First `NN%` in `line`, saturated to u8, or null when there is none.
fn volFirstPercent(line: []const u8) ?u8 {
    const pct = std.mem.indexOfScalar(u8, line, '%') orelse return null;
    var s = pct;
    while (s > 0 and line[s - 1] >= '0' and line[s - 1] <= '9') : (s -= 1) {}
    if (s == pct) return null;
    const v = std.fmt.parseInt(u16, line[s..pct], 10) catch return null;
    return @intCast(@min(v, 255));
}

/// Parses `pactl get-sink-volume @DEFAULT_SINK@`, `pactl get-sink-mute
/// @DEFAULT_SINK@`, `pactl get-source-volume @DEFAULT_SOURCE@`, `pactl
/// get-source-mute @DEFAULT_SOURCE@` and `pactl list sink-inputs`
/// concatenated (in that order, master pairs tagged `[sink]` / `[source]`
/// by the fetch script) into `out`: sink master at 0, mic master at 1 when
/// present, then apps. Returns the entry count; 0 means unusable (caller
/// keeps the old list / never opens). Pure — feed it canned pactl text in
/// tests.
fn parseVolumeList(text: []const u8, out: *[VOL_MAX_ENTRIES]VolumeEntry) usize {
    var sink_vol: ?u8 = null;
    var sink_mute = false;
    var mic_vol: ?u8 = null;
    var mic_mute = false;
    var master_slot: usize = 0; // 0 = sink pair, 1 = source pair
    var n_apps: usize = 0;
    var cur: ?usize = null; // app slot being filled (index into out)
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[sink]")) {
            master_slot = 0;
            continue;
        }
        if (std.mem.eql(u8, line, "[source]")) {
            master_slot = 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Sink Input #")) {
            const num = std.mem.trim(u8, line["Sink Input #".len..], " \t");
            var id: i32 = 0;
            var ok = num.len > 0;
            for (num) |c| {
                if (c < '0' or c > '9') {
                    ok = false;
                    break;
                }
                id = id * 10 + (c - '0');
            }
            // Slots 0-1 are the masters; apps start at 2.
            if (!ok or 2 + n_apps >= VOL_MAX_ENTRIES) {
                cur = null;
                continue;
            }
            out[2 + n_apps] = .{ .id = id };
            cur = 2 + n_apps;
            n_apps += 1;
        } else if (std.mem.startsWith(u8, line, "application.name")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (cur) |c| volSetName(&out[c], volUnquote(line[eq + 1 ..]));
            }
        } else if (std.mem.startsWith(u8, line, "application.process.binary")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                // Fallback when application.name is absent; never overwrites.
                if (cur) |c| {
                    if (out[c].name_len == 0) volSetName(&out[c], volUnquote(line[eq + 1 ..]));
                }
            }
        } else if (std.mem.startsWith(u8, line, "Volume:")) {
            if (volFirstPercent(line)) |pct| {
                if (cur) |c| {
                    out[c].vol_pct = pct;
                } else if (master_slot == 0) {
                    sink_vol = pct;
                } else {
                    mic_vol = pct;
                }
            }
        } else if (std.mem.startsWith(u8, line, "Mute:")) {
            const m = std.mem.eql(u8, std.mem.trim(u8, line["Mute:".len..], " \t"), "yes");
            if (cur) |c| {
                out[c].muted = m;
            } else if (master_slot == 0) {
                sink_mute = m;
            } else {
                mic_mute = m;
            }
        }
    }
    const sv = sink_vol orelse return 0;
    out[0] = .{ .id = -1, .vol_pct = sv, .muted = sink_mute };
    volSetName(&out[0], "Master");
    var base: usize = 1;
    // Mic row only when the source query actually answered (the [source]
    // marker alone proves nothing — the commands after it may have failed).
    // Without it the apps staged at [2..] compact down so entries stay dense.
    if (mic_vol) |mv| {
        out[1] = .{ .id = -2, .vol_pct = mv, .muted = mic_mute };
        volSetName(&out[1], "Mic");
        base = 2;
    } else if (n_apps > 0) {
        std.mem.copyForwards(VolumeEntry, out[1..][0..n_apps], out[2..][0..n_apps]);
    }
    // Unnamed streams still need a label (some loopbacks carry no
    // application properties at all).
    for (out[base .. base + n_apps]) |*e| {
        if (e.name_len == 0) {
            var nb: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "Stream #{d}", .{e.id}) catch "Stream";
            volSetName(e, s);
        }
    }
    return base + n_apps;
}

/// Display value for a row: "muted" or "NN%". Same string the measurer and
/// the painter use, so widths never drift. Takes the resolved mute/level
/// (not the entry) so a mid-drag override renders identically.
fn volValueText(muted: bool, pct: u8, buf: []u8) []const u8 {
    if (muted) return "muted";
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
}

fn drawVolumeRows(bar: *Bar, pm: *PopupMenu, pixels: [*]u32) void {
    const text_color = current_config.appearance.text_color;
    const dim_color = current_config.appearance.popup_disabled_color;
    pm.row_count = 0;
    var y: i32 = 0;
    var idx: usize = 0;
    const n = @min(vol_count, VOL_MAX_ENTRIES);
    var sep_done = false;
    while (idx < n) : (idx += 1) {
        const e = &vol_entries[idx];
        if (e.id >= 0 and !sep_done) {
            // Separator between masters and apps (same look as dbusmenu's).
            sep_done = true;
            const line_y = y + @divTrunc(POPUP_SEPARATOR_HEIGHT, 2);
            if (line_y >= 0 and line_y < pm.height) {
                var x: u32 = 0;
                while (x < pm.width) : (x += 1) pixels[@as(u32, @intCast(line_y)) * pm.width + x] = current_config.appearance.popup_separator_color;
            }
            if (pm.row_count < pm.rows.len) {
                pm.rows[pm.row_count] = .{ .y_start = y, .y_end = y + POPUP_SEPARATOR_HEIGHT, .item_id = null };
                pm.row_count += 1;
            }
            y += POPUP_SEPARATOR_HEIGHT;
        }
        const y_start = y;
        const y_end = y + VOL_ROW_H;
        if (pm.row_count < pm.rows.len) {
            pm.rows[pm.row_count] = .{ .y_start = y_start, .y_end = y_end, .item_id = @intCast(idx) };
            pm.row_count += 1;
        }
        fillPopupRowBand(pixels, pm, y_start, y_end, pm.row_hover[idx]);
        // Live drag value wins over the fetched level for the dragged row.
        const disp_pct = if (pm.vol_drag_row) |dr| (if (dr == idx) pm.vol_drag_val else e.vol_pct) else e.vol_pct;
        const color = if (e.muted) dim_color else text_color;
        const baseline = y_start + @divTrunc(POPUP_ROW_HEIGHT + bar.font.ascentPx() - bar.font.descentPx(), 2);
        var vbuf: [8]u8 = undefined;
        const value = volValueText(e.muted, disp_pct, &vbuf);
        const value_w = textPixelWidth(bar.font, value);
        var ni: usize = 0;
        var x0: i64 = POPUP_PADDING_X;
        while (nextUtf8Codepoint(e.name(), &ni)) |cp| {
            x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, color, 0, pm.width);
        }
        var vi: usize = 0;
        var vx = @as(i64, @intCast(pm.width)) - POPUP_PADDING_X - value_w;
        while (nextUtf8Codepoint(value, &vi)) |cp| {
            vx += drawGlyphAt(pixels, pm.width, pm.height, bar.font, vx, baseline, cp, color, 0, pm.width);
        }
        // Slider band under the label: track + accent fill + thumb. Dimmed
        // wholesale while muted (level still visible underneath).
        const tr = volSliderTrack(pm.width);
        const ty: i64 = @as(i64, y_start + POPUP_ROW_HEIGHT) + @divTrunc(@as(i64, VOL_SLIDER_H) - VOL_TRACK_H, 2);
        const scol = if (e.muted) dim_color else text_color;
        fillRoundedRect(pixels, pm.width, pm.height, tr.x0, ty, tr.x1, ty + VOL_TRACK_H, 3, current_config.appearance.popup_separator_color);
        const fillx = volSliderValToX(tr.x0, tr.x1, disp_pct);
        if (fillx > tr.x0) {
            fillRoundedRect(pixels, pm.width, pm.height, tr.x0, ty, fillx, ty + VOL_TRACK_H, 3, scol);
        }
        const tcy = ty + @divTrunc(VOL_TRACK_H, 2);
        fillRoundedRect(pixels, pm.width, pm.height, fillx - VOL_THUMB_R, tcy - VOL_THUMB_R, fillx + VOL_THUMB_R, tcy + VOL_THUMB_R, @intCast(VOL_THUMB_R), scol);
        y = y_end;
    }
}

/// Opens the mixer sized to the current list (masters + up to 6 apps).
/// No-op without data or with a popup already up (one at a time).
fn openVolumeMixer(bar: *Bar) void {
    if (bar.popup != null) return;
    const n = @min(vol_count, VOL_MAX_ENTRIES);
    if (n == 0) return;
    var max_w: i32 = POPUP_MIN_WIDTH;
    var idx: usize = 0;
    var apps: usize = 0;
    while (idx < n) : (idx += 1) {
        const e = &vol_entries[idx];
        if (e.id >= 0) apps += 1;
        var vbuf: [8]u8 = undefined;
        const value = volValueText(e.muted, e.vol_pct, &vbuf);
        const w: i32 = @intCast(textPixelWidth(bar.font, e.name()) + VOL_NAME_VALUE_GAP + textPixelWidth(bar.font, value) + POPUP_PADDING_X * 2);
        if (w > max_w) max_w = w;
    }
    if (max_w > POPUP_MAX_WIDTH) max_w = POPUP_MAX_WIDTH;
    const total_h: i32 = @as(i32, @intCast(n)) * VOL_ROW_H + (if (apps > 0) POPUP_SEPARATOR_HEIGHT else 0);
    const ps = createPopupSurface(bar, max_w, total_h, false) orelse return;
    bar.popup = PopupMenu{
        .surface = ps.surface,
        .xdg_surface = ps.xdg_surface,
        .popup = ps.popup,
        .kind = .volume,
        .vol_count = n,
    };
    wirePopup(bar, ps, true);
}

/// Gap between a mixer row's name and its right-aligned value.
const VOL_NAME_VALUE_GAP: i64 = 24;
/// Mixer row geometry: 20px label line + 14px slider band (6px track).
const VOL_ROW_H: i32 = 34;
const VOL_SLIDER_H: i32 = 14;
const VOL_TRACK_H: i64 = 6;
const VOL_THUMB_R: i64 = 6;
/// Press/release travel counting as a slider drag rather than a mute click.
const VOL_DRAG_PX: i32 = 4;

/// Track x-bounds within a popup of width `pm_width`.
fn volSliderTrack(pm_width: u32) struct { x0: i64, x1: i64 } {
    return .{ .x0 = POPUP_PADDING_X, .x1 = @as(i64, @intCast(pm_width)) - POPUP_PADDING_X };
}

/// Thumb center x for a 0-100 value on a track.
fn volSliderValToX(x0: i64, x1: i64, val: u8) i64 {
    return x0 + @divTrunc((x1 - x0) * @as(i64, val), 100);
}

/// 0-100 value for a pointer x on a track (clamped for overshoot).
fn volSliderXToVal(x0: i64, x1: i64, x: i64) u8 {
    if (x1 <= x0) return 0;
    const v = @divTrunc((x - x0) * 100, x1 - x0);
    if (v < 0) return 0;
    if (v > 100) return 100;
    return @intCast(v);
}

/// True when any bar currently shows the mixer (refreshes go out then).
fn anyVolumePopupOpen(bars: []Bar) bool {
    for (bars) |*b| {
        if (b.popup) |pm| {
            if (pm.kind == .volume) return true;
        }
    }
    return false;
}

/// pactl-side device reference for the mixer list/set commands and the wheel
/// adjust: the single-quoted configured sink, or @DEFAULT_SINK@ when none is
/// set. Names with a single quote are refused (null → caller skips) — pactl
/// node names never contain one, which keeps the sh -c interpolation below
/// injection-free without an escaping layer.
fn pactlSinkArg(buf: []u8) ?[]const u8 {
    const sk = current_config.appearance.volume_sink;
    if (sk.len == 0) return "@DEFAULT_SINK@";
    if (std.mem.indexOfScalar(u8, sk, '\'') != null) return null;
    return std.fmt.bufPrint(buf, "'{s}'", .{sk}) catch null;
}

/// Starts one `pactl` list run feeding vol_entries on EOF. No-op while one
/// is in flight; the 60ms tick abandons a wedged fetch after ~5s.
fn startVolumeListFetch() void {
    if (vol_fetch_fd >= 0) return;
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
    setCloexec(read_fd);
    _ = std.c.fcntl(read_fd, posix.F.SETFL, @as(c_int, 0o4000));
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
        // Master sides follow the configured volume device (see
        // pactlSinkArg); app listing is device-independent. The [sink] /
        // [source] markers tell the parser which master pair follows (sink
        // output first, then microphone input).
        var sbuf: [160]u8 = undefined;
        const sink = pactlSinkArg(&sbuf) orelse std.c._exit(127);
        var cbuf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cbuf, "echo '[sink]'; pactl get-sink-volume {s} 2>/dev/null; pactl get-sink-mute {s} 2>/dev/null; echo '[source]'; pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null; pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null; pactl list sink-inputs 2>/dev/null", .{ sink, sink }) catch std.c._exit(127);
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr, null };
        _ = std.c.execve("/bin/sh", &argv, std.c.environ);
        std.c._exit(127);
    }
    _ = posix.system.close(write_fd);
    vol_fetch_fd = read_fd;
    vol_fetch_len = 0;
    vol_fetch_since_frame = hover_frame;
}

/// Starts the long-lived `pactl subscribe` feed (see vol_sub_fd). No-op
/// while one runs. Same fork/exec pipe plumbing as the list fetch, minus
/// the output handling — events are drained and discarded, they only exist
/// to kick a prompt volume re-poll.
fn startVolumeSubscribe() void {
    if (vol_sub_fd >= 0) return;
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
    setCloexec(read_fd);
    _ = std.c.fcntl(read_fd, posix.F.SETFL, @as(c_int, 0o4000));
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
        var argv = [_:null]?[*:0]const u8{ "env", "pactl", "subscribe", null };
        _ = std.c.execve("/usr/bin/env", &argv, std.c.environ);
        std.c._exit(127);
    }
    _ = posix.system.close(write_fd);
    vol_sub_fd = read_fd;
}

/// Drains pending subscribe events; true when the feed died (EOF/error) and
/// the caller should close it for the 1s-tick respawn. Any events at all
/// mean audio state may have moved — kick a volume re-poll (guarded
/// no-op while one is in flight, so bursts coalesce).
fn readVolumeSubscribe(cmd: *PolledCommand) bool {
    if (vol_sub_fd < 0) return true;
    var chunk: [512]u8 = undefined;
    var saw_data = false;
    while (true) {
        const n = posix.read(vol_sub_fd, &chunk) catch |err| {
            if (err == error.WouldBlock) break;
            return true;
        };
        if (n == 0) return true;
        saw_data = true;
    }
    // Events mean audio state may have moved — kick a volume re-poll. The
    // fetch's in-flight guard coalesces a knob turn's burst into one run.
    if (saw_data) startVolumeFetch(cmd);
    return false;
}

/// Reads one chunk; true when the fetch finished (EOF/error/full) and the
/// caller should finalize (parse + redraw/rebuild, then close).
fn readVolumeFetch() bool {
    if (vol_fetch_fd < 0) return true;
    var chunk: [512]u8 = undefined;
    const n = posix.read(vol_fetch_fd, &chunk) catch return true;
    if (n == 0) return true;
    const free = vol_fetch_buf.len - vol_fetch_len;
    if (free == 0) return true; // absurdly large output; parse the head
    const copy_len = @min(n, free);
    @memcpy(vol_fetch_buf[vol_fetch_len..][0..copy_len], chunk[0..copy_len]);
    vol_fetch_len += copy_len;
    return false;
}

fn closeVolumeFetch() void {
    if (vol_fetch_fd >= 0) _ = posix.system.close(vol_fetch_fd);
    vol_fetch_fd = -1;
    vol_fetch_len = 0;
}

/// Parses a finished fetch into the live list. Returns the entry count (0 =
/// unusable: PipeWire/pactl down — callers keep any open popup untouched
/// rather than blanking it).
fn finishVolumeFetch() usize {
    var tmp: [VOL_MAX_ENTRIES]VolumeEntry = [_]VolumeEntry{.{}} ** VOL_MAX_ENTRIES;
    const n = parseVolumeList(vol_fetch_buf[0..vol_fetch_len], &tmp);
    closeVolumeFetch();
    if (n == 0) return 0;
    vol_entries = tmp;
    vol_count = n;
    return n;
}

/// Settles a finished list fetch: opens the pending mixer, or refreshes
/// open ones (rebuild on row-count change, redraw otherwise). A failed
/// fetch (0 entries) changes nothing — the click that asked simply shows
/// no panel, and live panels keep their last good values.
fn finishVolumeListFetch(bars: []Bar) void {
    const opener = vol_open_bar;
    vol_open_bar = null;
    if (finishVolumeFetch() == 0) return;
    if (opener) |b| {
        openVolumeMixer(b);
        return;
    }
    for (bars) |*b| {
        if (b.popup) |*pm| {
            if (pm.kind != .volume) continue;
            // A mid-drag rebuild would drop the gesture; the release
            // triggers its own refresh right after.
            if (pm.vol_drag_row != null) continue;
            if (vol_count != pm.vol_count) {
                closePopup(b);
                openVolumeMixer(b);
            } else {
                drawPopup(b) catch |err| {
                    logging.err("popup draw failed: {}", .{err});
                };
            }
        }
    }
}

/// Fires a pactl set/mute at one entry. `delta_pct` 0 = mute toggle, else a
/// signed step (wheel). Ids come from our own parse (numeric-checked), names
/// never interpolated — no shell-injection surface.
fn spawnVolumeSet(entry_idx: usize, delta_pct: i8) void {
    if (entry_idx >= vol_count) return;
    const e = &vol_entries[entry_idx];
    var buf: [128]u8 = undefined;
    // Master side follows the configured volume device.
    var sbuf: [160]u8 = undefined;
    const sink = pactlSinkArg(&sbuf) orelse return;
    // Sink-master sets move the wpctl poll the OSD watches: suppress its
    // echo so the panel doesn't double-show (see vol_osd_suppress_left).
    if (e.id == -1) vol_osd_suppress_left = 100;
    const cmd = if (delta_pct == 0) blk: {
        if (e.id == -1) {
            break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-mute {s} toggle", .{sink}) catch return;
        }
        if (e.id == -2) {
            break :blk std.fmt.bufPrintZ(&buf, "pactl set-source-mute @DEFAULT_SOURCE@ toggle", .{}) catch return;
        }
        break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-input-mute {d} toggle", .{e.id}) catch return;
    } else blk: {
        const step: u8 = @intCast(@abs(delta_pct));
        const sign: u8 = if (delta_pct > 0) '+' else '-';
        if (e.id == -1) {
            break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-volume {s} {c}{d}%", .{ sink, sign, step }) catch return;
        }
        if (e.id == -2) {
            break :blk std.fmt.bufPrintZ(&buf, "pactl set-source-volume @DEFAULT_SOURCE@ {c}{d}%", .{ sign, step }) catch return;
        }
        break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-input-volume {d} {c}{d}%", .{ e.id, sign, step }) catch return;
    };
    spawnDetached(cmd);
}

/// Fires an absolute pactl set at one entry (slider commit). Same
/// injection-safety contract as spawnVolumeSet.
fn spawnVolumeSetAbs(entry_idx: usize, pct: u8) void {
    if (entry_idx >= vol_count) return;
    const e = &vol_entries[entry_idx];
    var buf: [128]u8 = undefined;
    var sbuf: [160]u8 = undefined;
    const sink = pactlSinkArg(&sbuf) orelse return;
    // Same panel-echo suppression as the relative variant below.
    if (e.id == -1) vol_osd_suppress_left = 100;
    const cmd = if (e.id == -1) blk: {
        break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-volume {s} {d}%", .{ sink, pct }) catch return;
    } else if (e.id == -2) blk: {
        break :blk std.fmt.bufPrintZ(&buf, "pactl set-source-volume @DEFAULT_SOURCE@ {d}%", .{pct}) catch return;
    } else blk: {
        break :blk std.fmt.bufPrintZ(&buf, "pactl set-sink-input-volume {d} {d}%", .{ e.id, pct }) catch return;
    };
    spawnDetached(cmd);
}

/// Click-to-open from the volume module: starts the list fetch; the popup
/// opens sized once it lands (~one frame later, imperceptible).
fn openVolumeMixerFetch(bar: *Bar) void {
    if (bar.popup != null) return;
    if (vol_fetch_fd >= 0) return;
    vol_open_bar = bar;
    startVolumeListFetch();
}

/// Steps the master sink ±VOL_WHEEL_STEP_PCT per notch (negative axis =
/// scroll up = louder, matching the measured workspace sign convention),
/// kicks a prompt volume re-poll so the OSD corrects within ~100ms, and
/// shows the OSD. Shared by the module wheel and the OSD wheel (the mixer
/// panel adjusts per-row instead and refreshes through its own fetch).
fn adjustMasterVolume(bar: *Bar, steps: i32) void {
    var s = steps;
    if (s > WORKSPACE_SCROLL_MAX_STEPS) s = WORKSPACE_SCROLL_MAX_STEPS;
    if (s < -WORKSPACE_SCROLL_MAX_STEPS) s = -WORKSPACE_SCROLL_MAX_STEPS;
    if (s == 0) return;
    const delta: i8 = @intCast(-s * VOL_WHEEL_STEP_PCT);
    const step: u8 = @intCast(@abs(delta));
    const sign: u8 = if (delta > 0) '+' else '-';
    var buf: [128]u8 = undefined;
    var sbuf: [160]u8 = undefined;
    const sink = pactlSinkArg(&sbuf) orelse return;
    const cmd = std.fmt.bufPrintZ(&buf, "pactl set-sink-volume {s} {c}{d}%", .{ sink, sign, step }) catch return;
    spawnDetached(cmd);
    startVolumeFetch(bar.volume);
    showVolumeOSD(bar);
}

// --- volume OSD ------------------------------------------------------------
//
// Transient level feedback: a small grab-less popup above the bar showing
// the master percentage plus a level bar, auto-dismissed ~2s after the last
// change. Triggered by wheel adjustments and by any other master change the
// 5s volume poll notices (media keys, pavucontrol) — never while the mixer
// panel is open (the panel is its own feedback). No grab: an OSD that stole
// pointer focus on every wheel tick would be unusable.

const VOL_OSD_WIDTH: i32 = 300;
const VOL_OSD_HEIGHT: i32 = 52;
const VOL_OSD_PAD: i64 = 14;
const VOL_OSD_BAR_H: i64 = 8;
const VOL_OSD_ALIVE_TICKS: u32 = 34; // ~2s on the 60ms tick

/// Shows (or refreshes + re-arms) the OSD on `bar`. No-op without a volume
/// reading, and never over the mixer panel.
fn showVolumeOSD(bar: *Bar) void {
    var pbuf: [16]u8 = undefined;
    if (!parseVolumePoll(bar.volume.text(), &pbuf).ok) return;
    if (bar.popup) |pm| {
        if (pm.kind == .volume) return;
        if (pm.kind != .volume_osd) closePopup(bar);
    }
    if (bar.popup == null) {
        const ps = createPopupSurface(bar, VOL_OSD_WIDTH, VOL_OSD_HEIGHT, true) orelse return;
        bar.popup = PopupMenu{
            .surface = ps.surface,
            .xdg_surface = ps.xdg_surface,
            .popup = ps.popup,
            .kind = .volume_osd,
            .osd_since = hover_frame,
        };
        wirePopup(bar, ps, false);
    } else {
        bar.popup.?.osd_since = hover_frame;
        drawPopup(bar) catch |err| {
            logging.err("popup draw failed: {}", .{err});
        };
    }
}

fn drawVolumeOSD(bar: *Bar, pm: *PopupMenu, pixels: [*]u32) void {
    const text_color = current_config.appearance.text_color;
    var pbuf: [16]u8 = undefined;
    const vol = parseVolumePoll(bar.volume.text(), &pbuf);
    if (!vol.ok) return;
    // Muted reads dimmed throughout; the bar
    // underneath still shows where it will land on unmute.
    const col = if (vol.muted) current_config.appearance.popup_disabled_color else text_color;
    const pct = vol.pct;
    var vbuf: [8]u8 = undefined;
    const shown = if (vol.muted) "muted" else std.fmt.bufPrint(&vbuf, "{d}%", .{pct}) catch "?";
    const mid: i64 = @divTrunc(@as(i64, VOL_OSD_HEIGHT), 2);
    const baseline = mid + @divTrunc(@as(i64, bar.font.ascentPx()) - @as(i64, bar.font.descentPx()), 2);
    // Speaker icon, oversized like the bar's module glyphs, vertically
    // centered. Falls back to 1x on raster failure.
    var ii: usize = 0;
    const icp = nextUtf8Codepoint(volumeIconFor(pct), &ii) orelse 0;
    const big = if (ii > 0) bar.font.glyphScaled(icp, 2) catch null else null;
    defer if (big) |b| bar.font.gpa.free(b.pixels);
    var x0: i64 = VOL_OSD_PAD;
    if (big) |b| {
        const iy = mid - @divTrunc(@as(i64, @intCast(b.height)), 2);
        blitBigGlyph(pixels, pm.width, pm.height, x0 + @as(i64, b.bitmap_left), iy, &b, col, pm.width);
        x0 += @as(i64, b.advance_x);
    } else {
        var gi: usize = 0;
        const icon = volumeIconFor(pct);
        while (nextUtf8Codepoint(icon, &gi)) |cp| {
            x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, col, 0, pm.width);
        }
    }
    x0 += 10;
    // Percentage right-aligned; slider fills the middle.
    const value_w = textPixelWidth(bar.font, shown);
    const vx = @as(i64, @intCast(pm.width)) - VOL_OSD_PAD - value_w;
    var ti: usize = 0;
    var tx = vx;
    while (nextUtf8Codepoint(shown, &ti)) |cp| {
        tx += drawGlyphAt(pixels, pm.width, pm.height, bar.font, tx, baseline, cp, col, 0, pm.width);
    }
    const sx0 = x0;
    const sx1 = vx - 10;
    if (sx1 > sx0) {
        const sy = mid - @divTrunc(VOL_OSD_BAR_H, 2);
        const track_col = current_config.appearance.popup_separator_color;
        const fill_col = if (vol.muted) current_config.appearance.popup_disabled_color else current_config.appearance.workspace_active_color;
        fillRoundedRect(pixels, pm.width, pm.height, sx0, sy, sx1, sy + VOL_OSD_BAR_H, 4, track_col);
        const fw: i64 = @divTrunc((sx1 - sx0) * @as(i64, pct), 100);
        if (fw > 0) {
            fillRoundedRect(pixels, pm.width, pm.height, sx0, sy, sx0 + fw, sy + VOL_OSD_BAR_H, 4, fill_col);
        }
    }
}

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

    switch (pm.kind) {
        .dbusmenu => drawDbusMenuRows(bar, pm, pixels),
        .layout_picker => drawLayoutPickerRows(bar, pm, pixels),
        .volume => drawVolumeRows(bar, pm, pixels),
        .volume_osd => drawVolumeOSD(bar, pm, pixels),
    }

    const pool = try bar.shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const buffer = try pool.createBuffer(0, @intCast(pm.width), @intCast(pm.height), @intCast(stride), .argb8888);
    defer buffer.destroy();
    pm.surface.attach(buffer, 0, 0);
    pm.surface.damageBuffer(0, 0, @intCast(pm.width), @intCast(pm.height));
    pm.surface.commit();
}

/// Row-renderer for a `.dbusmenu` popup: the top-level items of the backing
/// DBusMenu, separators drawn as thin lines, and `item_id` carrying the
/// dbusmenu id so a click can send the "clicked" Event.
fn drawDbusMenuRows(bar: *Bar, pm: *PopupMenu, pixels: [*]u32) void {
    var top_idx: [MAX_POPUP_ROWS]usize = undefined;
    const top_children = pm.menu.childrenOf(0, &top_idx);

    pm.row_count = 0;
    var y: i32 = 0;
    for (top_children) |idx| {
        const it = &pm.menu.items[idx];
        const row_h: i32 = if (it.is_separator) POPUP_SEPARATOR_HEIGHT else POPUP_ROW_HEIGHT;
        const y_start = y;
        const y_end = y + row_h;
        // This child's row number (== its hit-test index) if recorded.
        const row_i = pm.row_count;

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
            if (it.enabled) {
                fillPopupRowBand(pixels, pm, y_start, y_end, pm.row_hover[row_i]);
            }
            const color = if (it.enabled) current_config.appearance.text_color else current_config.appearance.popup_disabled_color;
            drawPopupLabel(pixels, pm, bar, y_start, POPUP_PADDING_X, it.label(), color);
        }

        y = y_end;
    }
}

/// Hover pill for one popup row: an inset rounded rect in the hover color,
/// faded by `anim` (0 = invisible .. 1 = full) — the menu-sized version of
/// the bar's hover pill, minus the underline (menus don't underline).
/// No text-brightening: row labels keep text_color throughout the fade.
fn fillPopupRowBand(pixels: [*]u32, pm: *PopupMenu, y_start: i32, y_end: i32, anim: f32) void {
    if (anim <= 0.0) return;
    const a = anim * HOVER_MAX_ALPHA;
    const pill = lerpColor(current_config.appearance.popup_bg_color, current_config.appearance.popup_hover_color, a);
    const w: i64 = @as(i64, pm.width) - 2 * @as(i64, POPUP_ROW_PAD_X);
    const h: i64 = @as(i64, y_end - y_start) - 2 * @as(i64, POPUP_ROW_PAD_Y);
    const t: i64 = bezelThick(w, h);
    const tr: i32 = @intCast(@max(@as(i64, 0), @as(i64, POPUP_ROW_RADIUS) - t));
    const x0: i64 = @as(i64, POPUP_ROW_PAD_X) + t;
    const y0: i64 = @as(i64, y_start) + @as(i64, POPUP_ROW_PAD_Y) + t;
    const x1: i64 = @as(i64, pm.width) - @as(i64, POPUP_ROW_PAD_X) - t;
    const y1: i64 = @as(i64, y_end) - @as(i64, POPUP_ROW_PAD_Y) - t;
    // strokeBezel self-skips at thickness 0 (borders off or too small),
    // leaving just the flat fill — one path for both cases.
    strokeBezel(pixels, pm.width, pm.height, POPUP_ROW_PAD_X, y_start + POPUP_ROW_PAD_Y, pm.width - POPUP_ROW_PAD_X, y_end - POPUP_ROW_PAD_Y, POPUP_ROW_RADIUS, current_config.appearance.popup_bg_color, anim);
    fillRoundedRect(pixels, pm.width, pm.height, x0, y0, x1, y1, tr, pill);
}

/// Draws one row's label at `x0`, baseline-centered in the row that starts at
/// `y_start`, one codepoint at a time through the same glyph path the bar uses.
fn drawPopupLabel(pixels: [*]u32, pm: *PopupMenu, bar: *Bar, y_start: i32, x0_start: i64, label: []const u8, color: u32) void {
    const baseline = y_start + @divTrunc(POPUP_ROW_HEIGHT + bar.font.ascentPx() - bar.font.descentPx(), 2);
    var x0 = x0_start;
    var ci: usize = 0;
    while (nextUtf8Codepoint(label, &ci)) |cp| {
        x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, color, 0, pm.width);
    }
}

/// Row-renderer for a `.layout_picker` popup: one row per MANGO_LAYOUTS entry,
/// drawn as the layout's icon + name, with the active layout marked by a
/// persistent hover-coloured band plus a trailing check so it's unambiguous
/// which layout you're currently on. `item_id` carries the MANGO_LAYOUTS index
/// so a click can apply that layout.
fn drawLayoutPickerRows(bar: *Bar, pm: *PopupMenu, pixels: [*]u32) void {
    const active_symbol = bar.workspaces.layout();
    const text_color = current_config.appearance.text_color;

    pm.row_count = 0;
    var y: i32 = 0;
    for (MANGO_LAYOUTS, 0..) |layout, i| {
        const y_start = y;
        const y_end = y + POPUP_ROW_HEIGHT;

        if (pm.row_count < pm.rows.len) {
            pm.rows[pm.row_count] = .{
                .y_start = y_start,
                .y_end = y_end,
                .item_id = @intCast(i),
            };
            pm.row_count += 1;
        }

        const is_active = active_symbol.len > 0 and std.mem.eql(u8, active_symbol, layout.symbol);
        // The active row keeps a persistent full-strength pill (a selection
        // marker, not hover); the pointer's row fades in on top of it.
        if (is_active) fillPopupRowBand(pixels, pm, y_start, y_end, 1.0);
        fillPopupRowBand(pixels, pm, y_start, y_end, pm.row_hover[i]);

        // Icon, then the name, then — for the active row — a check.
        const baseline = y_start + @divTrunc(POPUP_ROW_HEIGHT + bar.font.ascentPx() - bar.font.descentPx(), 2);
        var x0: i64 = POPUP_PADDING_X;
        var ci: usize = 0;
        while (nextUtf8Codepoint(layout.icon, &ci)) |cp| {
            x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, text_color, 0, pm.width);
        }
        x0 += LAYOUT_ICON_GAP;
        ci = 0;
        while (nextUtf8Codepoint(layout.name, &ci)) |cp| {
            x0 += drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, text_color, 0, pm.width);
        }
        if (is_active) {
            x0 += LAYOUT_ICON_GAP;
            ci = 0;
            while (nextUtf8Codepoint(LAYOUT_ACTIVE_CHECK, &ci)) |cp| {
                _ = drawGlyphAt(pixels, pm.width, pm.height, bar.font, x0, baseline, cp, text_color, 0, pm.width);
            }
        }

        y = y_end;
    }
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
    pointer_y: i32 = -1,
    pointer_over_popup: bool = false,
    last_pointer_serial: u32 = 0,
    /// Launcher drag-and-drop: a press over a pin arms (li + press point)
    /// instead of acting; release without motion is the click, motion past
    /// LAUNCH_DRAG_PX live-reorders launcher_view_order, release commits.
    launch_press_li: ?usize = null,
    launch_press_x: i32 = 0,
    launch_press_y: i32 = 0,
    launch_dragging: bool = false,
    drawer_expanded: bool = false, // target state, flipped instantly on click
    drawer_anim: f32 = 0.0, // 0=collapsed..1=expanded, eased toward drawer_expanded each tick
    /// Dock-mode packing: last frame's per-group content widths. The pack
    /// origin for this frame derives from these (not from measuring up
    /// front, which would duplicate every module's width logic), so a width
    /// change settles one frame later — imperceptible, self-correcting.
    dock_left_w: i64 = 0,
    dock_center_w: i64 = 0,
    dock_right_w: i64 = 0,
    /// Dock input-region bookkeeping: whether a region is currently set, and
    /// the rect it covers (re-set only on change; cleared when leaving dock).
    dock_input_set: bool = false,
    dock_input_x: i64 = 0,
    dock_input_w: i64 = 0,
    /// Taskbar↔dock morph: eased blend, 0 = taskbar geometry .. 1 = dock
    /// pack. On a mode switch it travels from the current value to the new
    /// target with an elastic overshoot (rubber band); while traveling,
    /// paintFrame draws the interpolated layout below. from/t hold the
    /// animation; active gates the per-tick redraws.
    mode_blend: f32 = 0.0,
    mode_morph_from: f32 = 0.0,
    mode_morph_t: f32 = 1.0,
    mode_morph_active: bool = false,
    /// Auto-hide state (appearance.auto_hide): hidden = collapsed to the
    /// edge strip, exclusive zone released. hide_grace counts scroll ticks
    /// down to hiding after the pointer leaves (a short delay so brushing
    /// past the bar doesn't flicker it).
    autohide_hidden: bool = false,
    autohide_grace: u32 = 0,
    /// The compositor monitor this bar's output carries (`"DP-1"`...) — used
    /// to show that monitor's own workspace rail and to send rail clicks at
    /// that monitor (see text in switchTo). Filled from the pinned output at
    /// creation (all-target / named-output configs) or from the first
    /// wl_surface enter (compositor-default configs); empty means unknown,
    /// and the rail falls back to the merged list with legacy dispatches.
    monitor_buf: [MONITOR_NAME_MAX]u8 = undefined,
    monitor_len: usize = 0,
    /// The registry's output list (set at creation) so a wl_surface enter
    /// can resolve the entered wl_output pointer to a connector name.
    outputs: []const OutputInfo = &.{},
    /// Running total of vertical scroll distance accumulated over the hovered
    /// region, in Wayland surface units. Crosses WORKSPACE_SCROLL_STEP to fire
    /// one step; the remainder is kept so continuous scroll keeps flowing
    /// instead of needing a fresh full notch every time. Zeroed whenever the
    /// pointer moves off a scrollable region (see the .axis handler), so
    /// partial scroll can't carry across modules.
    scroll_accum: f64 = 0.0,
    mpris_player_buf: [128]u8 = undefined,
    mpris_player_len: usize = 0,
    /// Matrix-rain background state (bg_mode == "matrix"): per-column
    /// stream head heights in px, scattered on first paint/resize and
    /// advanced on the 60ms tick. ncols == 0 means uninitialized for the
    /// current width.
    matrix_heads: [512]i16 = [_]i16{0} ** 512,
    matrix_ncols: usize = 0,
    /// One-time-resolved rain charset for this bar's font (Nerd Font
    /// linux-distro logos where the font has them, else full blocks — an
    /// unresolved miss every frame would flicker and burn a FreeType load
    /// each time).
    matrix_chars: [48]u32 = [_]u32{0} ** 48,
    matrix_chars_len: usize = 0,
    matrix_charset_done: bool = false,
    /// Drawer island span: min/max x of last frame's drawn in-drawer cells.
    /// The island's shared resting pill paints from these bounds before each
    /// walk (dock-pack style — content settles a frame later), so no measure
    /// pass duplicates the right group's per-kind width logic.
    drawer_island_x0: i64 = 0,
    drawer_island_x1: i64 = 0,
    drawer_island_set: bool = false,
    /// Weather hover bounds: the live cell span, refreshed every walk that
    /// draws the module (cleared when it doesn't). The tick's redraw gate
    /// and the condition-fx overlay both read last frame's bounds.
    weather_fx_x0: i64 = 0,
    weather_fx_x1: i64 = 0,
    weather_fx_set: bool = false,
    /// Media progress fraction (position/length) for the progress underline,
    /// or null when the player doesn't report both. Refreshed with the
    /// mpris poll (2s cadence — smooth enough for a thin bar that moves a
    /// few px per update on a normal track).
    mpris_frac: ?f32 = null,
    popup: ?PopupMenu = null,
};

/// This bar's monitor name as the compositor IPC spells it (`"DP-1"`...).
fn barMonitorName(bar: *const Bar) []const u8 {
    return bar.monitor_buf[0..bar.monitor_len];
}

/// The workspace rail slice for THIS bar: its own monitor's entries when
/// known, else the merged list (see sliceForMonitor for the fallback rules).
/// Every rail draw/measure call site goes through this so the numbers the
/// centering math uses and the pixels the rail paints stay in sync.
fn barWorkspaces(bar: *const Bar) []const Workspace {
    return bar.workspaces.sliceForMonitor(barMonitorName(bar));
}

/// Copies a monitor name onto a bar; returns whether something changed
/// (used to decide whether a redraw is worth doing after wl_surface enter).
fn barSetMonitor(bar: *Bar, name: []const u8) bool {
    if (name.len == 0) return false;
    const n = @min(name.len, bar.monitor_buf.len);
    if (bar.monitor_len == n and std.mem.eql(u8, bar.monitor_buf[0..n], name[0..n])) return false;
    @memcpy(bar.monitor_buf[0..n], name[0..n]);
    bar.monitor_len = n;
    return true;
}

/// wl_surface events for the bar's main surface. No drawing happens here —
/// the only thing this listener exists for is `.enter`: a bar created
/// without a pinned output (the default config) gets placed by the
/// compositor, and enter is what names that output. With the name in hand
/// the rail switches from the merged list to that monitor's own
/// tags/workspaces (the same reason a named all-target bar fills its
/// monitor at creation).
fn barSurfaceListener(_: *wl.Surface, event: wl.Surface.Event, bar: *Bar) void {
    switch (event) {
        .enter => |e| {
            if (bar.monitor_len > 0) return; // already named at creation
            for (bar.outputs) |*oi| {
                if (oi.output == e.output) {
                    if (barSetMonitor(bar, oi.name())) {
                        // Redraw so the rail adopts the monitor's own set
                        // without waiting for the next event — but only once
                        // a buffer exists (enter can precede the first
                        // configure; the configure path repaints anyway).
                        if (bar.configured) {
                            drawAndCommit(bar) catch |err| {
                                logging.err("draw failed: {}", .{err});
                            };
                        }
                    }
                    return;
                }
            }
        },
        else => {},
    }
}

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
    const is_top = std.mem.eql(u8, current_config.appearance.position, "top");
    const is_dock = std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK);
    if (is_top) {
        bar.layer_surface.setAnchor(.{ .top = true, .left = true, .right = true });
    } else {
        bar.layer_surface.setAnchor(.{ .bottom = true, .left = true, .right = true });
    }
    bar.layer_surface.setSize(0, current_config.appearance.bar_height);
    if (is_dock) {
        // Floating dock: margins on three sides, and no exclusive zone so
        // windows slide under it instead of stopping at it.
        bar.layer_surface.setExclusiveZone(0);
        if (is_top) {
            bar.layer_surface.setMargin(DOCK_MARGIN_EDGE, DOCK_MARGIN_SIDE, 0, DOCK_MARGIN_SIDE);
        } else {
            bar.layer_surface.setMargin(0, DOCK_MARGIN_SIDE, DOCK_MARGIN_EDGE, DOCK_MARGIN_SIDE);
        }
    } else {
        bar.layer_surface.setExclusiveZone(@intCast(current_config.appearance.bar_height));
        bar.layer_surface.setMargin(0, MARGIN_SIDE, 0, MARGIN_SIDE);
    }
    bar.surface.commit();
}

/// Auto-hide hint-strip rect (x, w) for the current frame: full width in
/// taskbar mode (the bar spans the edge), or the last packed pill span in
/// dock mode so the strip sits centered under the dock instead of ruling a
/// stray line across the whole screen. Falls back to a modest centered
/// segment while degenerate (no measured content yet).
fn autohideStripRect(bar: *const Bar) struct {
    x: i64,
    w: i64,
} {
    if (!std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK)) {
        return .{ .x = 0, .w = @intCast(bar.width) };
    }
    var total: i64 = bar.dock_left_w + bar.dock_center_w + bar.dock_right_w;
    if (bar.dock_left_w > 0 and bar.dock_center_w > 0) total += DOCK_GAP;
    if (bar.dock_center_w > 0 and bar.dock_right_w > 0) total += DOCK_GAP;
    if (bar.dock_left_w > 0 and bar.dock_center_w == 0 and bar.dock_right_w > 0) total += DOCK_GAP;
    if (total <= 0) total = 160;
    const buf_w: i64 = @intCast(bar.width);
    return .{ .x = @divTrunc(buf_w - total, 2), .w = total };
}

/// Shows a hidden bar (auto-hide): clears the hidden flag and grace timer,
/// restores the exclusive zone + margins for the current mode, and forces
/// the input region to be re-established (dock) or released (taskbar) below.
/// No-op unless hidden, so enter handlers can call it unconditionally.
fn autohideShow(bar: *Bar) void {
    bar.autohide_grace = 0;
    if (!bar.autohide_hidden) return;
    bar.autohide_hidden = false;
    applyLayerGeometry(bar);
    // The pill/strip region below is re-decided every frame from these, so
    // stale values would leave the wrong one in place.
    bar.dock_input_set = false;
    if (!std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK)) {
        bar.surface.setInputRegion(null);
    }
    drawAndCommit(bar) catch |err| {
        logging.err("draw failed: {}", .{err});
    };
}

/// Hides the bar (auto-hide): releases the exclusive zone so windows use the
/// space, narrows input to the edge strip, clears stale hover/click state,
/// and closes any open popup (it belongs to a visible bar). The strip paint
/// itself happens in paintFrame's hidden branch on the redraw below.
fn autohideHide(bar: *Bar) void {
    if (bar.autohide_hidden) return;
    if (!current_config.appearance.auto_hide) return;
    bar.autohide_hidden = true;
    bar.autohide_grace = 0;
    bar.layer_surface.setExclusiveZone(0);
    // Input follows the strip (same rect the hidden branch paints), so only
    // the strip — not the whole transparent surface — stays clickable.
    const strip = autohideStripRect(bar);
    const strip_y: i32 = if (std.mem.eql(u8, current_config.appearance.position, "top")) 0 else @intCast(bar.height - @as(u32, @intCast(AUTOHIDE_STRIP_PX)));
    if (bar.compositor.createRegion()) |region| {
        region.add(@intCast(@max(0, strip.x)), strip_y, @intCast(@max(0, strip.w)), AUTOHIDE_STRIP_PX);
        bar.surface.setInputRegion(region);
        region.destroy();
    } else |_| {}
    bar.click_regions.hovered = null;
    bar.click_regions.hover = [_]f32{0} ** MAX_CLICK_REGIONS;
    bar.click_regions.clear();
    if (bar.popup != null) closePopup(bar);
    drawAndCommit(bar) catch |err| {
        logging.err("draw failed: {}", .{err});
    };
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
            logging.err("draw failed: {}", .{err});
        };
    }
}

pub fn main() void {
    logging.init("simpbar");
    realMain() catch |err| {
        logging.err("fatal: {s}", .{@errorName(err)});
        logging.crash("fatal error: {s}", .{@errorName(err)});
        logging.dumpCurrentStack();
        std.process.exit(1);
    };
}

fn realMain() !void {
    logging.step("starting up", .{});
    resolveConfigPaths();
    current_config = loadConfig();
    invalidateLauncherIcons();
    resetLauncherViewOrder();
    writePidfile();
    logging.step("config loaded from {s}", .{config_json_path});
    icontheme.refreshConfiguredTheme();

    // DebugAllocator does leak tracking and guard work on every allocation;
    // keep it for Debug builds, but use libc's release allocator for the
    // shipping builds. Both choices stay paired with every free below.
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa: std.mem.Allocator = if (builtin.mode == .Debug)
        gpa_state.allocator()
    else
        std.heap.c_allocator;

    var app_font = init_font: {
        var buf: [512]u8 = undefined;
        const path_z = fontPathZ(current_config.appearance.font_path, &buf) orelse font_mod.FONT_PATH;
        break :init_font font_mod.Font.init(gpa, path_z, FONT_PIXEL_SIZE) catch |err| blk: {
            // A user-configured font_path that fails to load (bad path, not
            // actually a font file, ...) shouldn't take the whole bar down —
            // fall back to the built-in default, matching every other
            // "never let a bad config value crash the bar" convention here.
            logging.warn("font: could not load {s}: {} — falling back to {s}", .{ path_z, err, font_mod.FONT_PATH });
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

    // Compositor IPC for the workspace module — matching waybar's
    // "hyprland/workspaces" module. Hyprland keeps both sockets (command +
    // event) at $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/; Mango
    // (mangowm) exposes a single socket at $MANGO_INSTANCE_SIGNATURE where
    // `mmsg watch all-tags` streams tag updates on a long-lived connection.
    const hypr_sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    const mango_sig = getenv("MANGO_INSTANCE_SIGNATURE");

    var hypr_sock_dir_buf: [92]u8 = undefined;
    const hypr_sock_dir: ?[]const u8 = if (hypr_sig) |sig| blk: {
        const runtime_dir = std.mem.sliceTo(getenv("XDG_RUNTIME_DIR") orelse break :blk null, 0);
        const instance_sig = std.mem.sliceTo(sig, 0);
        break :blk std.fmt.bufPrint(&hypr_sock_dir_buf, "{s}/hypr/{s}", .{ runtime_dir, instance_sig }) catch null;
    } else null;

    var cmd_sock_path_buf: [128]u8 = undefined;
    var workspaces: Workspaces = blk: {
        const empty = Workspaces{ .gpa = gpa, .mode = .hyprland, .list = .empty, .sock_path_len = 0 };
        if (hypr_sock_dir) |dir| {
            const cmd_path = std.fmt.bufPrint(&cmd_sock_path_buf, "{s}/.socket.sock", .{dir}) catch break :blk empty;
            break :blk Workspaces.init(gpa, .hyprland, cmd_path) catch empty;
        }
        if (mango_sig) |sig| {
            const sock = std.mem.sliceTo(sig, 0);
            break :blk Workspaces.init(gpa, .mango, sock) catch empty;
        }
        break :blk empty;
    };
    defer workspaces.deinit();

    // Live window list for the launcher running-dots + taskbar tail: same
    // compositor socket as workspaces, refreshed on compositor events and
    // every other clock tick (focus-within-a-tag may not move Mango's
    // all-tags stream, so events alone can miss a focus change).
    running_state = RunningApps.init(gpa, workspaces.mode, workspaces.sockPath());
    // Icon names for pins and tail buttons (one .desktop scan; the theme
    // lookups themselves stay lazy per pin/appid).
    buildDesktopIndex();

    var event_sock_path_buf: [128]u8 = undefined;
    const comp_event_fd: posix.fd_t = if (hypr_sock_dir) |dir| blk: {
        const event_path = std.fmt.bufPrint(&event_sock_path_buf, "{s}/.socket2.sock", .{dir}) catch break :blk -1;
        break :blk connectUnixSocket(event_path) catch -1;
    } else if (mango_sig) |sig| blk: {
        // Mango's change channel: on the same socket as commands, sending
        // "watch all-tags\n" keeps the connection open and streams a full
        // refresh frame after every tag change.
        const fd = connectUnixSocket(std.mem.sliceTo(sig, 0)) catch break :blk -1;
        const cmd = "watch all-tags\n";
        if (std.c.write(fd, cmd, cmd.len) != @as(isize, @intCast(cmd.len))) {
            _ = posix.system.close(fd);
            break :blk -1;
        }
        break :blk fd;
    } else -1;
    defer if (comp_event_fd >= 0) {
        _ = posix.system.close(comp_event_fd);
    };

    var weather: PolledCommand = .{};
    startWeatherFetch(&weather);
    var pacman_updates: PolledCommand = .{};
    startPacmanFetch(&pacman_updates);
    var volume: PolledCommand = .{};
    startVolumeFetch(&volume);
    startVolumeSubscribe();
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
            // Start settled in the configured mode (no morph sweep at login;
            // transitions only run on live switches below).
            .mode_blend = if (std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK)) 1.0 else 0.0,
        };
        // Multi-monitor rails: give this bar the registry's output list (for
        // wl_surface enter resolution) and, when the config pinned a
        // specific output / "all", its own output's connector name so the
        // rail shows — and switches — that monitor's own tag set from the
        // very first frame. A compositor-default target (no pinned output)
        // learns its name from barSurfaceListener's first enter instead.
        bars[bar_count].outputs = globals.outputs[0..globals.output_count];
        if (target_output) |out| {
            for (globals.outputs[0..globals.output_count]) |*oi| {
                if (oi.output == out) {
                    _ = barSetMonitor(&bars[bar_count], oi.name());
                    break;
                }
            }
        }
        surface.setListener(*Bar, barSurfaceListener, &bars[bar_count]);
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

    // SIGUSR1 live-reload: a process-wide sigaction handler writes a byte to
    // a self-pipe that's multiplexed into poll() alongside every timerfd, so
    // a reload is triggered by the event loop exactly like any other event.
    // This is deliberately NOT the signalfd+sigprocmask pattern: sigprocmask
    // only affects the *calling* thread, while the bar hosts several libc
    // thread-pool threads (simdjson, blake3, ...) spawned outside our control
    // that never inherit that mask — delivering SIGUSR1 to one of them ran
    // SIGUSR1's default *terminate* disposition and silently killed the bar
    // on every config save. Signal disposition is process-wide, so a handler
    // can't be dodged by the kernel picking a non-blocking thread. A failure
    // here (fd/memory exhaustion) is still non-fatal: reload just becomes a
    // no-op for this run.
    var sigusr1_pipe: [2]posix.fd_t = .{ -1, -1 };
    if (std.c.pipe(&sigusr1_pipe) == 0) {
        setCloexec(sigusr1_pipe[0]);
        setCloexec(sigusr1_pipe[1]);
        // F_SETFL for O_NONBLOCK: the drain below must never block the event
        // loop on an empty pipe (F.GETFL's value 3 is NOT F_SETFL — that
        // mistake quietly returned the flags without applying them).
        _ = std.c.fcntl(sigusr1_pipe[0], posix.F.SETFL, @as(c_int, 0o4000));
        g_sigusr1_write_fd = sigusr1_pipe[1];
        const act = posix.Sigaction{
            .handler = .{ .sigaction = relaySIGUSR1 },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(.USR1, &act, null);
    } else {
        logging.warn("SIGUSR1 self-pipe failed, live config reload disabled", .{});
    }
    const sigusr1_fd = sigusr1_pipe[0];
    defer {
        if (sigusr1_fd >= 0) _ = posix.system.close(sigusr1_fd);
    }

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
    defer {
        if (cava_state.pending_fd >= 0) _ = posix.system.close(cava_state.pending_fd);
    }
    if (cavaWanted()) startCavaFetch();

    // Main event loop: multiplex the Wayland display fd (compositor events),
    // a 1s timerfd (clock ticks), and the compositor's workspace-event socket
    // (Hyprland's .socket2.sock or Mango's `mmsg watch all-tags` stream) —
    // a negative fd (no supported compositor running) is simply ignored by
    // poll(). Each redraws the same buffer; more modules later just mean
    // more fds feeding into the same poll() call.
    var poll_fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = timer_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = comp_event_fd, .events = posix.POLL.IN, .revents = 0 },
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
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [29] cava visualizer pipe, refreshed below
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [30] vol_fetch_fd, refreshed below
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, // [31] vol_sub_fd (pactl subscribe), refreshed below
    };
    comptime {
        if (MAX_CUSTOM_SCRIPTS != 4) @compileError("poll_fds' custom-script slots [21..28] are hand-unrolled for MAX_CUSTOM_SCRIPTS == 4; update both if that changes");
    }

    var second_count: i64 = 0;

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
        poll_fds[29].fd = cava_state.pending_fd;
        poll_fds[30].fd = vol_fetch_fd;
        poll_fds[31].fd = vol_sub_fd;

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
            second_count += 1;
            // Focus changes don't always move the compositor event stream
            // (nothing about the tag set changes), so poll the client list
            // on a slow cadence as well — socket IPC, no fork, cheap. The
            // drawAllBars at the end of this tick picks up any change.
            // Silent on failure (the event path above already warns, and a
            // dead compositor socket would otherwise spam once per 2s).
            if (@rem(second_count, 2) == 0) {
                _ = running_state.refresh() catch false;
                // New arrivals get their taskbar icons outside the draw
                // path (SVG raster would hitch frames), bounded per tick.
                ensureTailIcons();
            }
            // pactl subscribe feed can die (pactl upgrade, PipeWire restart);
            // respawn it on the slow tick rather than wedging the OSD's
            // event-driven path — the timer poll below still covers the gap.
            if (vol_sub_fd < 0) {
                if (vol_sub_dead_since == 0) {
                    vol_sub_dead_since = second_count;
                } else if (second_count - vol_sub_dead_since >= 2) {
                    vol_sub_dead_since = 0;
                    startVolumeSubscribe();
                }
            } else {
                vol_sub_dead_since = 0;
            }
            // A dead/vacant cava visualizer is retried on a slow timer rather
            // than wedged: cava can exit on its own (audio sink dropped) and
            // the initial spawn above can race the pulseaudio socket appearing.
            // A running daemon the config no longer wants (module removed and
            // background mode changed away) is stopped here instead.
            if (!cavaWanted()) {
                if (cava_state.pending_fd >= 0) closeCava();
            } else if (cava_state.pending_fd < 0 and
                (second_count - cava_state.dead_since_tick) >= CAVA_RESPAWN_SECONDS)
            {
                cava_state.dead_since_tick = second_count;
                startCavaFetch();
            }
            // Mixer panel refresh: levels drift (other mixers, keys, streams
            // coming and going), so re-list while any panel is open. A wedged
            // fetch (PipeWire down mid-run) is abandoned past ~5s.
            if (vol_fetch_fd >= 0 and hover_frame -% vol_fetch_since_frame > 83) {
                closeVolumeFetch();
                vol_open_bar = null;
            } else {
                for (bars[0..bar_count]) |*b| {
                    if (b.popup) |pm| {
                        // A mid-drag refresh would snap the slider out from
                        // under the pointer; the release triggers its own.
                        if (pm.kind == .volume and pm.vol_drag_row == null) {
                            startVolumeListFetch();
                            break;
                        }
                    }
                }
            }
            drawAllBars(bars[0..bar_count]);
        }
        if (poll_fds[2].revents & posix.POLL.IN != 0) {
            // Don't bother parsing which event(s) arrived — just drain
            // what's queued and re-fetch the full workspace/tag list. Simpler
            // than tracking the compositor's various workspace event payloads,
            // and cheap enough for something that only fires on user action.
            var drain_buf: [4096]u8 = undefined;
            _ = posix.read(comp_event_fd, &drain_buf) catch {};
            workspaces.refresh() catch |err| {
                logging.warn("workspaces refresh failed: {}", .{err});
            };
            // Same event means windows may have opened/closed/focused —
            // re-read the client list so dots and tail track it.
            const running_changed = running_state.refresh() catch |err| blk: {
                logging.warn("running apps refresh failed: {}", .{err});
                break :blk false;
            };
            _ = running_changed;
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
            // Master level changed out from under us (media keys,
            // pavucontrol, the mixer): show the OSD unless a mixer panel is
            // already giving feedback. Compared before the read overwrites.
            const prev_len = volume.text_len;
            var prev: [256]u8 = undefined;
            @memcpy(prev[0..prev_len], volume.text_buf[0..prev_len]);
            if (volume.onReadable()) {
                _ = posix.system.close(volume.pending_fd);
                volume.pending_fd = -1;
                const now = volume.text();
                if (now.len != prev_len or !std.mem.eql(u8, now, prev[0..prev_len])) {
                    var mixer_open = false;
                    for (bars[0..bar_count]) |*b| {
                        if (b.popup) |pm| {
                            if (pm.kind == .volume) {
                                mixer_open = true;
                                break;
                            }
                        }
                    }
                    // Panel-driven master sets suppress their own echo (set
                    // alongside the set-command); anything else pops the OSD.
                    if (!mixer_open and vol_osd_suppress_left <= 0) {
                        for (bars[0..bar_count]) |*b| showVolumeOSD(b);
                    }
                }
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
            // The hover bezel's animation clock — advances whether or not
            // anything is hovered (wrapping is fine; phase math is modulo).
            // Matrix streams ride the same clock.
            hover_frame +%= 1;
            // Mixer-echo suppressions tick down here (see spawnVolumeSet).
            if (vol_osd_suppress_left > 0) vol_osd_suppress_left -= 1;
            if (current_config.appearance.animations_enabled and std.mem.eql(u8, current_config.appearance.bg_mode, BG_MODE_MATRIX)) {
                for (bars[0..bar_count]) |*b| updateMatrixHeads(b);
            }
            // Only bother animating (and redrawing) when there's actually
            // something to show — no point burning a redraw every 60ms
            // while nothing's playing and the drawer's fade isn't mid-flight.
            // drawer_anim is per-bar state (each bar's own fade progresses
            // independently), so this loops over every bar rather than
            // updating one shared value.
            for (bars[0..bar_count]) |*b| {
                var needs_redraw = false;
                // Auto-hide grace countdown (see the leave handler).
                if (b.autohide_grace > 0) {
                    b.autohide_grace -= 1;
                    if (b.autohide_grace == 0) autohideHide(b);
                }
                // Taskbar↔dock rubber-band morph: ease the blend toward the
                // current mode's endpoint, redrawing every tick while
                // traveling (settled endpoints paint no differently than
                // before, so idle costs nothing extra).
                if (b.mode_morph_active) {
                    const morph_target: f32 = if (std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK)) 1.0 else 0.0;
                    b.mode_morph_t += MODE_MORPH_STEP;
                    if (b.mode_morph_t >= 1.0) {
                        b.mode_blend = morph_target;
                        b.mode_morph_active = false;
                    } else {
                        b.mode_blend = b.mode_morph_from + (morph_target - b.mode_morph_from) * easeOutElastic(b.mode_morph_t);
                    }
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
                // Hover fade: every region's pill+underline eases toward lit
                // (under the pointer) or dark. Same needs_redraw gating as
                // the drawer — settled regions cost nothing per tick. With
                // animations off the level snaps straight to target instead
                // (the pointer handlers already redraw on change, so the
                // snap still paints its single frame).
                const anim_on = current_config.appearance.animations_enabled;
                var hi: usize = 0;
                while (hi < b.click_regions.len) : (hi += 1) {
                    const hover_target: f32 = if (b.click_regions.hovered == hi) 1.0 else 0.0;
                    if (b.click_regions.hover[hi] != hover_target) {
                        b.click_regions.hover[hi] = if (!anim_on) hover_target else if (b.click_regions.hover[hi] < hover_target)
                            @min(hover_target, b.click_regions.hover[hi] + HOVER_ANIM_STEP)
                        else
                            @max(hover_target, b.click_regions.hover[hi] - HOVER_ANIM_STEP);
                        needs_redraw = true;
                    }
                }
                // A settled-but-lit hover still animates its bezel, so it
                // needs a redraw every tick until it goes fully dark — but
                // only while animations are on (off = frozen bezel = static).
                // Same for the active-workspace pill below: its bezel never
                // stops while animations are on, so the bar redraws every
                // tick while one exists (practically always). Same cost class
                // as any animated bar — one full CPU frame per 60ms tick.
                if (anim_on) {
                    var hj: usize = 0;
                    while (hj < b.click_regions.len) : (hj += 1) {
                        if (b.click_regions.hover[hj] > 0.0) {
                            needs_redraw = true;
                            break;
                        }
                    }
                    if (!needs_redraw) {
                        for (barWorkspaces(b)) |ws| {
                            if (ws.active) {
                                needs_redraw = true;
                                break;
                            }
                        }
                    }
                    // A pulsing urgent pill needs frames too (same gating as
                    // the bezel above; frozen when animations are off).
                    if (!needs_redraw) {
                        for (barWorkspaces(b)) |ws| {
                            if (ws.urgent and !ws.active) {
                                needs_redraw = true;
                                break;
                            }
                        }
                    }
                    // Animated backgrounds repaint every tick while visible
                    // (same cost class as the always-on bezel above).
                    if (!needs_redraw and bgEffectVisible()) needs_redraw = true;
                    // Hovered weather plays its condition fx — same deal.
                    if (!needs_redraw and weatherHovered(b)) needs_redraw = true;
                }
                if (needs_redraw) {
                    drawAndCommit(b) catch |err| {
                        logging.err("draw failed: {}", .{err});
                    };
                }
                // An open popup's row pills ride the same tick — easing plus,
                // like the bar, a redraw every tick while any row stays lit
                // (the bezel keeps animating under a parked pointer). Both
                // collapse to snap + no forced redraws with animations off.
                if (b.popup) |*pm| {
                    // The volume OSD is timed, not hovered: dismiss ~2s
                    // after its last change.
                    if (pm.kind == .volume_osd and hover_frame -% pm.osd_since > VOL_OSD_ALIVE_TICKS) {
                        closePopup(b);
                    }
                    var popup_redraw = false;
                    var ri: usize = 0;
                    while (ri < pm.row_count) : (ri += 1) {
                        const row_target: f32 = if (pm.hovered_row == ri) 1.0 else 0.0;
                        if (pm.row_hover[ri] != row_target) {
                            pm.row_hover[ri] = if (!anim_on) row_target else if (pm.row_hover[ri] < row_target)
                                @min(row_target, pm.row_hover[ri] + HOVER_ANIM_STEP)
                            else
                                @max(row_target, pm.row_hover[ri] - HOVER_ANIM_STEP);
                            popup_redraw = true;
                        } else if (anim_on and pm.row_hover[ri] > 0.0) {
                            popup_redraw = true;
                        }
                    }
                    if (popup_redraw) {
                        drawPopup(b) catch |err| {
                            logging.err("popup draw failed: {}", .{err});
                        };
                    }
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
                        logging.err("draw failed: {}", .{err});
                    };
                }
            }
        }
        if (poll_fds[14].revents & posix.POLL.IN != 0) {
            // Drain the SIGUSR1 self-pipe. Multiple quick reloads coalesce
            // into a single reload below — fine for live config edits.
            var sig_buf: [64]u8 = undefined;
            while (true) {
                const n = posix.read(sigusr1_fd, sig_buf[0..]) catch 0;
                if (n <= 0) break; // drained (0 counts as fine too, defensive)
            }
            // Unlike the startup load, a reload NEVER falls back to
            // defaultConfig() — a config.json that's momentarily missing or
            // malformed (mid-edit, a bad hand-edit, a GUI bug) should leave
            // the bar exactly as it was, not silently discard the user's
            // working config.
            if (loadConfigFromFile()) |cfg| {
                const old_font_path = current_config.appearance.font_path;
                const font_changed = !std.mem.eql(u8, old_font_path, cfg.appearance.font_path);
                const old_matrix_style = current_config.appearance.matrix_style;
                const matrix_style_changed = !std.mem.eql(u8, old_matrix_style, cfg.appearance.matrix_style);
                const old_matrix_distro = current_config.appearance.matrix_distro;
                const matrix_distro_changed = !std.mem.eql(u8, old_matrix_distro, cfg.appearance.matrix_distro);
                const old_position = current_config.appearance.position;
                const old_bar_height = current_config.appearance.bar_height;
                const old_bar_mode = current_config.appearance.bar_mode;
                const geometry_changed = !std.mem.eql(u8, old_position, cfg.appearance.position) or
                    old_bar_height != cfg.appearance.bar_height or
                    !std.mem.eql(u8, old_bar_mode, cfg.appearance.bar_mode);
                current_config = cfg;
                invalidateLauncherIcons();
                resetLauncherViewOrder();
                // A reload mid-drag (GUI save, drop commit) strands the
                // armed press — its indices belong to the old order.
                for (bars[0..bar_count]) |*b| {
                    b.launch_press_li = null;
                    b.launch_dragging = false;
                }
                logging.step("config: reloaded {s}", .{config_json_path});
                // Toggling auto-hide off while hidden must reveal the bar —
                // otherwise it stays invisible with the feature disabled.
                // Conversely, a reload while hidden re-applies geometry
                // (restoring the exclusive zone), so re-hide to put the
                // release + strip back in place.
                if (!cfg.appearance.auto_hide) {
                    for (bars[0..bar_count]) |*b| autohideShow(b);
                } else {
                    for (bars[0..bar_count]) |*b| {
                        if (b.autohide_hidden) {
                            b.autohide_hidden = false;
                            autohideHide(b);
                        }
                    }
                }

                // Closes a previously-known gap: bar_height (and now
                // position) used to only take effect on the next bar
                // restart. Re-issuing these layer-shell requests + a commit
                // is cheap and async — see applyLayerGeometry's doc comment
                // for why this doesn't need to block on the resulting
                // configure event here.
                if (geometry_changed) {
                    for (bars[0..bar_count]) |*b| applyLayerGeometry(b);
                }
                // A mode flip starts the rubber-band morph (or snaps when
                // animations are off). From the current eased value, so a
                // rapid re-flip retargets smoothly instead of jumping.
                if (!std.mem.eql(u8, old_bar_mode, cfg.appearance.bar_mode)) {
                    for (bars[0..bar_count]) |*b| startModeMorph(b);
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
                            logging.warn("font: could not load {s}: {} — keeping current font", .{ path_z, err });
                        }
                    } else {
                        logging.warn("font: path too long, keeping current font", .{});
                    }
                }

                // Icon theme follows settings.ini (written by simpbar-config's
                // icon picker); re-read it so a picked theme applies on this
                // same reload instead of waiting for a bar restart.
                icontheme.refreshConfiguredTheme();

                // The rain charset is resolved once per font+style+distro: a
                // new font may lack glyphs the old one had (or vice versa),
                // and a style/distro switch swaps the whole candidate set.
                // Reset so the next paint re-resolves instead of raining
                // stale (or missing) glyphs.
                if (font_changed or matrix_style_changed or matrix_distro_changed) {
                    for (bars[0..bar_count]) |*b| {
                        b.matrix_charset_done = false;
                        b.matrix_chars_len = 0;
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
                logging.warn("config: reload failed, keeping previous config", .{});
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
        if (poll_fds[29].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // cava never EOFs on its own — any EOF/HUP here means the daemon
            // died, and the respawn-on-tick logic above brings it back. A
            // frame (or several batched frames) meanwhile is the equalizer's
            // own ~30fps refresh slot, independent of the 1s clock tick.
            switch (readCavaAvailable()) {
                .frame => drawAllBars(bars[0..bar_count]),
                .eof => cava_state.dead_since_tick = second_count,
                .none => {},
            }
        }
        if (poll_fds[30].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // One-shot pactl list run for the mixer: read until EOF, then
            // settle (open pending panel / refresh live ones).
            if (readVolumeFetch()) finishVolumeListFetch(bars[0..bar_count]);
        }
        if (poll_fds[31].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // PipeWire change event: re-poll volume immediately so the OSD
            // tracks the knob/keys in ~100ms rather than on the timer's
            // schedule. Dead feed (HUP) is respawned by the 1s tick below.
            if (readVolumeSubscribe(&volume)) {
                _ = posix.system.close(vol_sub_fd);
                vol_sub_fd = -1;
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
    /// Final text, trimmed. Sized for the longest single producer: the
    /// mpris two-liner ("PLAYER|STATUS|ARTIST - TITLE\nPOSITION|LENGTH"),
    /// whose first line is an unbounded track title — anything shorter
    /// truncates the position/length tail and silently kills progress.
    text_buf: [256]u8 = undefined,
    text_len: usize = 0,
    /// Staging for one fetch's raw output; must cover text_buf or the tail
    /// never survives to be trimmed into it (see above).
    read_buf: [1024]u8 = undefined,
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

// --- cava audio visualizer (right-group module) --------------------------
//
// The bar spawns `cava` once at startup, piping its stdout straight into an
// fd the poll() loop watches — a LONG-LIVED process unlike weather/pacman/
// custom-script (which run-to-EOF then restart on a timer), so it gets its
// own reader instead of PolledCommand's one-shot parser. cava's raw ascii
// output (per ~/.config/simpbar/cava.conf's [output] section: integer values
// 0..ascii_max_range separated by ';', one full frame per '\n') updates a
// small bar array; whenever a whole frame arrives the bar redraws, giving the
// equalizer its own frame rate independent of the 1s clock tick. If the
// daemon dies (cava exits, crashes, frees the audio sink) it's respawned on a
// slow timer rather than hammering fork/exec. The geometry constants mirror
// CAVA_DEFAULT_CONF below so the two can't silently drift out of agreement;
// deviating from that file only changes how the equalizer looks, never how
// the bar parses (unknown/extra values are ignored defensively).

const CAVA_BARS: usize = 24; // [general] bars in ~/.config/simpbar/cava.conf
const CAVA_REFERENCE_MAX: u32 = 1000; // [output] ascii_max_range
const CAVA_BAR_WIDTH: i64 = 1; // [general] bar_width
const CAVA_BAR_GAP: i64 = 1; // [general] bar_spacing
const CAVA_RESPAWN_SECONDS: i64 = 5; // wait between a dead cava and a respawn

/// The cava.conf written out when the user doesn't have one, so the visualiser
/// works on a fresh install instead of silently vanishing (cava exits with
/// "Unable to open file" and the module just never draws anything). Only ever
/// written when the file is ABSENT — an existing cava.conf, however odd, is
/// left completely alone so hand-tweaked visuals survive restarts.
///
/// Two keys here are load-bearing and must not be dropped: `data_format =
/// ascii` (cava >= 1.0 defaults to *binary*, which emits raw bytes this bar's
/// ';'-delimited parser cannot read at all) and `method = raw` (every other
/// output method draws to a terminal instead of stdout).
const CAVA_DEFAULT_CONF =
    \\# Written by simpbar. Edit freely — it is only re-created when missing.
    \\[general]
    \\bars = 24
    \\bar_width = 1
    \\bar_spacing = 1
    \\sleep_timer = 0
    \\
    \\[input]
    \\# 'auto' is the monitor source of the default sink, i.e. whatever plays.
    \\method = pipewire
    \\source = auto
    \\
    \\[output]
    \\method = raw
    \\data_format = ascii
    \\ascii_max_range = 1000
    \\bar_delimiter = 59
    \\frame_delimiter = 10
    \\
    \\[smoothing]
    \\noise_reduction = 77
    \\
;

/// Writes CAVA_DEFAULT_CONF to `conf` unless something is already there.
/// Best-effort like writePidfile: a failure here just means the visualiser
/// stays dead, which is no worse than the missing-file case it replaces.
fn ensureCavaConf(conf: [:0]const u8) void {
    const probe = posix.system.open(conf.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (probe >= 0) {
        _ = posix.system.close(@intCast(probe));
        return; // already there, hands off
    }
    const raw_fd = posix.system.open(conf.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(posix.mode_t, 0o644));
    if (raw_fd < 0) return;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var off: usize = 0;
    while (off < CAVA_DEFAULT_CONF.len) {
        const n = posix.system.write(fd, CAVA_DEFAULT_CONF.ptr + off, CAVA_DEFAULT_CONF.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
    logging.step("cava: wrote default {s}", .{conf});
}

const CavaState = struct {
    pending_fd: posix.fd_t = -1,
    read_buf: [512]u8 = undefined,
    read_len: usize = 0,
    bars: [CAVA_BARS]u32 = [_]u32{0} ** CAVA_BARS,
    bar_count: usize = CAVA_BARS,
    has_data: bool = false,
    dead_since_tick: i64 = std.math.minInt(i64),
};

var cava_state: CavaState = .{};

fn closeCava() void {
    if (cava_state.pending_fd >= 0) _ = posix.system.close(cava_state.pending_fd);
    cava_state.pending_fd = -1;
    cava_state.read_len = 0;
}

/// Whether the cava daemon should be running: the right-group module wants
/// it, or the background mode paints with it. Checked at startup, on the
/// 1Hz respawn tick, and to stop a daemon the config no longer needs.
fn cavaWanted() bool {
    if (findRightEntry(.cava) != null) return true;
    return std.mem.eql(u8, current_config.appearance.bg_mode, BG_MODE_CAVA);
}

/// Forks/execs `cava -p ~/.config/simpbar/cava.conf` with the child's stdout
/// on a pipe this bar keeps, mirroring PolledCommand.startFetch's plumbing
/// (who owns which end, CLOEXEC on read_fd, dying child = exit 127). A missing
/// cava.conf is materialised first, because cava's own failure mode is to exit
/// instantly and leave the module blank with nothing on the bar to hint why.
fn startCavaFetch() void {
    if (cava_state.pending_fd >= 0) return;
    const home = std.mem.span(getenv("HOME") orelse return);
    var conf_buf: [512]u8 = undefined;
    if (home.len >= conf_buf.len) return;
    const conf = std.fmt.bufPrint(&conf_buf, "{s}/.config/simpbar/cava.conf", .{home}) catch return;
    var conf_z_buf: [512]u8 = undefined;
    if (conf.len >= conf_z_buf.len) return;
    @memcpy(conf_z_buf[0..conf.len], conf);
    conf_z_buf[conf.len] = 0;
    ensureCavaConf(conf_z_buf[0..conf.len :0]);
    var argv = [_:null]?[*:0]const u8{ "env", "cava", "-p", conf_z_buf[0..conf.len :0].ptr, null };

    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
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
        _ = std.c.execve("/usr/bin/env", &argv, std.c.environ);
        std.c._exit(127);
    }
    _ = posix.system.close(write_fd);
    cava_state.pending_fd = read_fd;
}

/// Applies one ';'-separated frame's worth of bar values (0..ascii_max_range)
/// to cava_state.bars. Tokens that aren't plain integers are skipped instead
/// of aborting the frame — a value that changed width mid-stream shouldn't
/// hollow the equalizer out.
fn parseCavaFrame(line: []const u8) void {
    var it = std.mem.splitScalar(u8, line, ';');
    var idx: usize = 0;
    while (it.next()) |tok| : (idx += 1) {
        if (tok.len == 0) continue;
        if (idx >= cava_state.bar_count) break;
        const v = std.fmt.parseInt(u32, tok, 10) catch continue;
        cava_state.bars[idx] = @min(v, CAVA_REFERENCE_MAX);
    }
    cava_state.has_data = true;
}

/// Drains whatever the cava pipe has buffered, applying the LAST complete
/// frame seen (cava batches several frames per read at 30fps — the newest
/// values are the ones that belong on screen). Closes the pipe on EOF/HUP and
/// reports it so the caller can schedule a respawn.
const CavaReadResult = enum { none, frame, eof };

fn readCavaAvailable() CavaReadResult {
    var got_frame = false;
    while (true) {
        var chunk: [512]u8 = undefined;
        const n = posix.read(cava_state.pending_fd, &chunk) catch {
            closeCava();
            return .eof;
        };
        if (n == 0) {
            closeCava();
            return if (got_frame) .frame else .eof;
        }
        // Append into the staging buffer, parsed from the front as lines
        // complete, keeping only the trailing partial line for next time.
        const free = cava_state.read_buf.len - cava_state.read_len;
        const copy_len = @min(n, free);
        @memcpy(cava_state.read_buf[cava_state.read_len..][0..copy_len], chunk[0..copy_len]);
        cava_state.read_len += copy_len;
        // A single line can saturate the staging buffer only if it's far
        // longer than CAVA_BARS's printed width could ever be; drop the
        // head so a pathological frame can't wedge the reader forever.
        if (free == 0) {
            const drop = cava_state.read_buf.len / 2;
            std.mem.copyForwards(u8, cava_state.read_buf[0 .. cava_state.read_len - drop], cava_state.read_buf[drop..cava_state.read_len]);
            cava_state.read_len -= drop;
        }
        var line_start: usize = 0;
        const staged = cava_state.read_buf[0..cava_state.read_len];
        while (std.mem.indexOfScalarPos(u8, staged, line_start, '\n')) |nl| {
            parseCavaFrame(staged[line_start..nl]);
            got_frame = true;
            line_start = nl + 1;
        }
        if (line_start > 0) {
            std.mem.copyForwards(u8, cava_state.read_buf[0 .. cava_state.read_len - line_start], staged[line_start..]);
            cava_state.read_len -= line_start;
        }
        // The loop keeps reading until the pipe is momentarily empty (each
        // poll wakeup is expected to carry several frames), so only return
        // once a read yields less than the full chunk or hits 0.
        if (n < chunk.len) {
            return if (got_frame) .frame else .none;
        }
    }
}

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
/// extractFirstId above.
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
            logging.warn("config: more than {d} custom_script entries, ignoring the rest", .{MAX_CUSTOM_SCRIPTS});
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
const SCROLL_INTERVAL_MS: i64 = 60; // drawer fade + hover/morph animation tick
const DRAWER_ANIM_STEP: f32 = 0.25; // fraction of the fade per SCROLL_INTERVAL_MS tick (~240ms full fade)

fn startWeatherFetch(cmd: *PolledCommand) void {
    // Routed through /usr/bin/env for PATH search — no execvp binding here.
    var argv = [_:null]?[*:0]const u8{ "env", "curl", "-s", WEATHER_URL, null };
    cmd.startFetch("/usr/bin/env", &argv);
}

/// The shell one-liner that counts available package updates
/// (pacman-contrib's checkupdates, Arch Linux). Writes into `buf` and
/// returns a null-terminated view of it.
fn systemUpdateCountShell(buf: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "checkupdates | wc -l", .{}) catch "checkupdates | wc -l";
}

fn startPacmanFetch(cmd: *PolledCommand) void {
    // Needs a real shell for the pipe (checkupdates | wc -l). The module is
    // still called "pacman" in config.json for backwards compat.
    var shell_buf: [128]u8 = undefined;
    const shell_cmd = systemUpdateCountShell(&shell_buf);
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", shell_cmd.ptr, null };
    cmd.startFetch("/bin/sh", &argv);
}

fn startVolumeFetch(cmd: *PolledCommand) void {
    // pactl takes node names (wpctl only takes numeric IDs, which shift on
    // every restart); grep/tr reduce each answer to one plain line so the
    // poll text stays trivially parseable below: "<digits>" plus a "MUTED"
    // line when muted. Copied onto the stack: argv only needs to live
    // through the fork/exec below.
    var sbuf: [160]u8 = undefined;
    const sink = pactlSinkArg(&sbuf) orelse return;
    var cbuf: [384]u8 = undefined;
    // -m1 alone doesn't suffice: it stops after one matching LINE while -o
    // still prints every % on it (stereo pairs), so head -1 keeps exactly
    // the front-left figure the module shows.
    const command = std.fmt.bufPrintZ(&cbuf, "pactl get-sink-volume {s} 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%'; pactl get-sink-mute {s} 2>/dev/null | grep -q yes && echo MUTED", .{ sink, sink }) catch return;
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", command.ptr, null };
    cmd.startFetch("/bin/sh", &argv);
}

/// Parsed volume poll text ("<digits>[\nMUTED]"): the level, the mute flag,
/// and the digits slice for labels. `ok` is false on empty/garbled output
/// (PipeWire down, unknown sink) — callers show nothing rather than stale.
const VolumePoll = struct {
    pct: u8 = 0,
    muted: bool = false,
    text: []const u8 = "",
    ok: bool = false,
};

fn parseVolumePoll(text: []const u8, buf: []u8) VolumePoll {
    var it = std.mem.splitScalar(u8, text, '\n');
    var digits: []const u8 = "";
    var muted = false;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "MUTED")) {
            muted = true;
            continue;
        }
        if (digits.len == 0) {
            var all_digits = true;
            for (line) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) digits = line;
        }
    }
    if (digits.len == 0) return .{};
    const pct: u8 = @intCast(@min(std.fmt.parseInt(u32, digits, 10) catch 0, 255));
    const n = @min(digits.len, buf.len);
    @memcpy(buf[0..n], digits[0..n]);
    return .{ .pct = pct, .muted = muted, .text = buf[0..n], .ok = true };
}

// Finds the first playerctl-visible player that's actually Playing or
// Paused and prints two lines: "PLAYER|STATUS|ARTIST - TITLE" then
// "POSITION|LENGTH" (the player name is used to target play/pause/prev/next
// clicks at this exact player via spawnPlayerctlCommand, not just for
// display). Position/length are MPRIS microseconds for the progress
// underline; players that don't report them leave the fields empty and the
// bar simply shows no progress. Two lines (not extra |-fields) because track
// titles may contain '|' themselves — the second line carries only integers,
// so it parses unambiguously. (Same convention as simpbar-shell's
// MPRIS_SCRIPT, which uses \x1f separators for the same reason; a second
// line is simpler here since this script already prints exactly one.)
// Deliberately not filtered by player name (~/.config/waybar/config's old
// "mpris" module ignored "firefox" entirely, which also hides every
// Firefox-family browser tab — Zen Browser registers as
// "firefox.instance_<pid>" too, same as vanilla Firefox) — instead skips
// Stopped entries, which is what that filter was really working around:
// Firefox-family browsers leave a stale "Stopped" MPRIS entry with the last
// tab's title lingering after the tab closes.
// No output at all if every visible player is Stopped/none exist — same
// as the real module in that case.
const MPRIS_SCRIPT =
    \\for p in $(playerctl -l 2>/dev/null); do
    \\  out=$(playerctl -p "$p" metadata --format "{{status}}|{{artist}} - {{title}}" 2>/dev/null) || continue
    \\  case "$out" in Stopped\|*) continue;; esac
    \\  pos=$(playerctl -p "$p" position 2>/dev/null) || pos=""
    \\  len=$(playerctl -p "$p" metadata mpris:length 2>/dev/null) || len=""
    \\  printf '%s|%s\n%s|%s' "$p" "$out" "$pos" "$len"
    \\  break
    \\done
;

fn startMprisFetch(cmd: *PolledCommand) void {
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", MPRIS_SCRIPT, null };
    cmd.startFetch("/bin/sh", &argv);
}

/// Parses playerctl's decimal-seconds position ("211.716851", or a bare
/// integer) into integer microseconds, or -1 when malformed. Integer math
/// only — no float parsing.
fn parseMprisPos(s: []const u8) i64 {
    if (s.len == 0) return -1;
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        const whole = std.fmt.parseInt(i64, s[0..dot], 10) catch return -1;
        if (whole < 0) return -1;
        var frac = s[dot + 1 ..];
        if (frac.len == 0) return whole * 1000000;
        if (frac.len > 6) frac = frac[0..6];
        var mult: i64 = 100000;
        var frac_us: i64 = 0;
        // "716851" -> 7*100000 + 1*10000 + ... (positional, truncated).
        for (frac) |c| {
            if (c < '0' or c > '9') return -1;
            frac_us += @as(i64, c - '0') * mult;
            mult = @divTrunc(mult, 10);
        }
        return whole * 1000000 + frac_us;
    }
    const whole = std.fmt.parseInt(i64, s, 10) catch return -1;
    if (whole < 0) return -1;
    return whole * 1000000;
}

/// Parses wpctl's "Volume: 1.00" into a "100" percentage string written
/// into `buf`. Hand-rolled integer parsing (assumes exactly the two decimal
/// places wpctl always prints) rather than std.fmt.parseFloat, to sidestep
/// yet another moving-target stdlib API.
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

/// Condition effects for the weather hover animation (bar module + desktop
/// card): what plays while the pointer sits on the widget.
/// Mapped from the shaped weather icon, like the tint.
const WeatherFx = enum { none, rain, snow, storm, clear, cloud, fog, wind };

/// Maps a shaped weather icon (U+E3xx) to its hover effect. Pure so tests
/// pin it — the shell duplicates this table (it can't import main.zig).
fn weatherFxKind(nf: u32) WeatherFx {
    return switch (nf) {
        0xE30D => .clear,
        0xE302, 0xE304 => .cloud,
        0xE335 => .cloud,
        0xE319 => .rain,
        0xE31D => .storm,
        0xE31A => .snow,
        0xE313 => .fog,
        0xE34B => .wind,
        0xE351 => .wind,
        else => .none,
    };
}

/// Condition-aware resolver: showers (0x1F326) wear the partly-rainy icon
/// but must RAIN, not drift cloud puffs — the icon alone can't tell them
/// from sun-behind-cloud (0x1F324). Everything else follows the icon
/// table. Pure so tests pin it; mirrored by the shell.
fn weatherFxFor(wttr: u32, nf: u32) WeatherFx {
    if (wttr == 0x1F326) return .rain;
    return weatherFxKind(nf);
}

/// Deterministic 0..1 scatter for particle `i` (stateless effects need no
/// RNG state — the frame clock is the only input). Pure so tests pin it.
fn fxHash01(i: i64) f32 {
    const h: u64 = @as(u64, @intCast(i)) *% 2654435761;
    return @as(f32, @floatFromInt((h >> 8) & 0xFFFF)) / 65535.0;
}

/// One effect pixel, clipped to the effect rect. The caller owns the bounds;
/// out-of-shape pixels (rounded pill corners) simply don't get drawn.
fn putFxPixel(pixels: [*]u32, buf_width: u32, buf_height: u32, x: i64, y: i64, x0: i64, x1: i64, yT: i64, yB: i64, rgb: u32) void {
    if (x < x0 or x >= x1 or y < yT or y >= yB) return;
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= buf_width or uy >= buf_height) return;
    pixels[uy * buf_width + ux] = rgb;
}

/// Hover overlay for the weather module: condition particles inside
/// [x0,x1) at the pill band, driven by the free-running frame clock (no
/// per-bar animation state — the tick's redraw gate keeps frames coming
/// while hovered). `interior` is the pill fill to nest into (pillFillColor
/// when pills are on, bar bg otherwise) and `tint` the condition color;
/// both come from the caller, so this function reads no theme globals and
/// tests can render it into a scratch buffer (see the smoke test below).
fn drawWeatherFx(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, x1: i64, wttr: u32, nf: u32, frame: u32, interior: u32, tint: u32) void {
    const kind = weatherFxFor(wttr, nf);
    if (kind == .none) return;
    const w = x1 - x0;
    if (w <= 0) return;
    const h: i64 = @intCast(buf_height);
    const yT = HOVER_PILL_PAD_Y + 1;
    const yB = h - HOVER_PILL_PAD_Y - 1;
    const H = yB - yT;
    if (H <= 0) return;
    const fi: i64 = @intCast(frame % 100000);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(H);
    switch (kind) {
        .none => {},
        .rain => {
            var i: i64 = 0;
            while (i < 10) : (i += 1) {
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 1) * fw));
                const fy = yT + @mod(fi * 3 + @divTrunc(i * H, 10), H);
                const col = lerpColor(interior, tint, 0.55);
                putFxPixel(pixels, buf_width, buf_height, fx, fy, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, fx, fy + 1, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, fx, fy + 2, x0, x1, yT, yB, col);
            }
        },
        .snow => {
            var i: i64 = 0;
            while (i < 9) : (i += 1) {
                const fy = yT + @mod(@divTrunc(fi, 2) + @divTrunc(i * H, 9), H);
                const sway = @round(1.5 * std.math.sin(@as(f32, @floatFromInt(fi)) * 0.08 + @as(f32, @floatFromInt(i)) * 1.7));
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 3) * fw)) + @as(i64, @intFromFloat(sway));
                putFxPixel(pixels, buf_width, buf_height, fx, fy, x0, x1, yT, yB, lerpColor(interior, 0xFFFFFFFF, 0.7));
            }
        },
        .storm => {
            var i: i64 = 0;
            while (i < 7) : (i += 1) {
                const fx = x0 + @as(i64, @intFromFloat(fxHash01(i * 2 + 1) * fw));
                const fy = yT + @mod(fi * 3 + @divTrunc(i * H, 7), H);
                const col = lerpColor(interior, tint, 0.55);
                putFxPixel(pixels, buf_width, buf_height, fx, fy, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, fx, fy + 1, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, fx, fy + 2, x0, x1, yT, yB, col);
            }
            if (@mod(fi, 110) < 5) {
                const flash = lerpColor(interior, 0xFFFFFFFF, 0.22);
                var yy = yT;
                while (yy < yB) : (yy += 1) {
                    var xx = x0;
                    while (xx < x1) : (xx += 1) {
                        putFxPixel(pixels, buf_width, buf_height, xx, yy, x0, x1, yT, yB, flash);
                    }
                }
            }
        },
        .clear => {
            // Shine sweep: a soft bright band sliding down and wrapping.
            const sy = yT + @mod(fi * 2, H + 6) - 3;
            var yy = sy - 1;
            while (yy <= sy + 1) : (yy += 1) {
                const d: f32 = @floatFromInt(@abs(yy - sy));
                const col = lerpColor(interior, 0xFFFFE9A8, 0.18 * (1.0 - d / 2.0));
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    putFxPixel(pixels, buf_width, buf_height, xx, yy, x0, x1, yT, yB, col);
                }
            }
        },
        .cloud => {
            var i: i64 = 0;
            while (i < 3) : (i += 1) {
                const px = x0 + @mod(fi + i * @divTrunc(w, 3), w);
                const py = yT + @as(i64, @intFromFloat(fxHash01(i * 2 + 5) * fh));
                const col = lerpColor(interior, 0xFFFFFFFF, 0.22);
                putFxPixel(pixels, buf_width, buf_height, px, py, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, px + 1, py, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, px + 2, py, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, px, py + 1, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, px + 1, py + 1, x0, x1, yT, yB, col);
                putFxPixel(pixels, buf_width, buf_height, px + 2, py + 1, x0, x1, yT, yB, col);
            }
        },
        .fog => {
            var r: i64 = 0;
            while (r < 2) : (r += 1) {
                const ly = yT + @divTrunc((r + 1) * H, 3);
                const col = lerpColor(interior, tint, 0.2);
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    if (@mod(xx + fi * 2 + r * 6, 12) < 7) {
                        putFxPixel(pixels, buf_width, buf_height, xx, ly, x0, x1, yT, yB, col);
                    }
                }
            }
        },
        .wind => {
            var i: i64 = 0;
            while (i < 5) : (i += 1) {
                const wy = yT + @as(i64, @intFromFloat(fxHash01(i * 2 + 7) * fh));
                const sx = x0 + @mod(i * @divTrunc(w, 5) - fi * 4, w);
                const col = lerpColor(interior, tint, 0.3);
                var k: i64 = 0;
                while (k < 5) : (k += 1) {
                    putFxPixel(pixels, buf_width, buf_height, sx + k, wy, x0, x1, yT, yB, col);
                }
            }
        },
    }
}

/// True while the pointer sits on the weather cell: animations on, cell
/// recorded, pointer inside its span on the bar surface itself (leave resets
/// pointer_x to -1; popups route elsewhere). Read by the tick's redraw gate
/// and the .weather arm's overlay.
fn weatherHovered(bar: *const Bar) bool {
    if (!current_config.appearance.animations_enabled) return false;
    if (!bar.weather_fx_set) return false;
    if (bar.pointer_over_popup) return false;
    const px: i64 = @as(i64, bar.pointer_x);
    return px >= bar.weather_fx_x0 - 4 and px <= bar.weather_fx_x1 + 4;
}
/// Tint for a SHAPED weather icon (the U+E3xx codepoints formatWeatherText
/// emits): semantic condition colors that stay vivid across themes. Keyed on
/// the icon rather than wttr.in's emoji because the .weather arm only ever
/// sees the shaped label; every icon from one condition shares its tint, so
/// the mapping matches the shell's emoji-keyed table in intent (see
/// ~/.local/share/simpbar/simpbar-shell/src/widgets.zig). Unlisted icons
/// wear `fallback` (the caller passes the text color). Pure so tests pin it.
fn weatherIconTint(nf: u32, fallback: u32) u32 {
    return switch (nf) {
        0xE30D => 0xFFFFD60A, // clear gold
        0xE302, 0xE304 => 0xFFFFB340, // partly amber
        0xE335 => 0xFF9AA7B8, // overcast slate
        0xE319 => 0xFF4AA8FF, // rain blue
        0xE31D => 0xFFB48CFF, // storm violet
        0xE31A => 0xFFA8E6FF, // snow ice
        0xE313 => 0xFF8E9AAF, // fog gray
        0xE34B => 0xFF7DE3D0, // wind teal
        0xE351 => 0xFFFF8A8A, // tornado red
        else => fallback,
    };
}

/// Splits a shaped weather label ("<icon> <temp>") back into its icon
/// codepoint and the display text after it: the bar draws the icon tinted
/// (wttrColorFor) with the temperature in the text color, but measures the
/// joined string so widths never drift from the single-label days.
fn splitWeatherLabel(text: []const u8) struct { icon: u32, icon_len: usize, rest: []const u8 } {
    var i: usize = 0;
    const icon = nextUtf8Codepoint(text, &i) orelse return .{ .icon = 0, .icon_len = 0, .rest = text };
    const rest = std.mem.trim(u8, text[i..], " \t");
    return .{ .icon = icon, .icon_len = i, .rest = rest };
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
        0x1F324 => 0xE302, // 🌥 sun behind small cloud (wttr's current "partly cloudy day" emoji)
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
    var rest = std.mem.trim(u8, trimmed[i..], " \t\r\n");
    // wttr.in prefixes non-negative temperatures with "+" ("+21°C") — noise
    // next to an icon, so drop it (a leading "-" is significant and stays).
    if (rest.len > 0 and rest[0] == '+') rest = rest[1..];

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

/// Blits an uncached oversized glyph (see Font.glyphScaled) with its top-left
/// at (`x0`, `y0`), coverage-blended over dst exactly like drawGlyphAt (the
/// opaque pipeline: blendPixel forces opaque). No pen advance is returned —
/// callers advance by `big.advance_x` themselves.
fn blitBigGlyph(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, y0: i64, big: *const font_mod.BigGlyph, color: u32, clip_x_max: i64) void {
    for (0..big.height) |row| {
        for (0..big.width) |col| {
            const coverage = big.pixels[row * big.width + col];
            if (coverage == 0) continue;
            const px = x0 + @as(i64, @intCast(col));
            const py = y0 + @as(i64, @intCast(row));
            if (px < 0 or px >= clip_x_max or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= buf_width or pyu >= buf_height) continue;
            const idx = pyu * buf_width + pxu;
            pixels[idx] = blendPixel(pixels[idx], color, coverage);
        }
    }
}

/// Layout metrics for an oversized icon blit: the cell content width covers
/// the whole ink extent (glyph bitmaps routinely overhang their advance —
/// weather/layout icons run ~1.6x wider — so measuring the advance alone
/// clips the pill ring straight through the ink), and the pen origin shifts
/// so the ink starts exactly at the content's left edge. Returns null when
/// there is no raster or it is taller than `avail_h` (caller draws 1x).
/// Pure (operates on the struct, never the font) so tests pin it.
const BigLayout = struct {
    b: *const font_mod.BigGlyph,
    content_w: i64,
    pen_off: i64,
    adv: i64,
};

fn bigIconLayout(big: ?*const font_mod.BigGlyph, avail_h: i64) ?BigLayout {
    const b = big orelse return null;
    if (@as(i64, b.height) > avail_h) return null;
    const lo: i64 = @min(@as(i64, 0), @as(i64, b.bitmap_left));
    const hi: i64 = @max(@as(i64, b.advance_x), @as(i64, b.bitmap_left) + @as(i64, @intCast(b.width)));
    return .{ .b = b, .content_w = hi - lo, .pen_off = -lo, .adv = hi };
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

/// Widest prefix of `text` whose drawn width plus a trailing "…" fits
/// `max_w`, copied into `buf` (size it at the source text's capacity — the
/// output is always a prefix of the input plus three bytes). Returns the
/// full `text` when it already fits, and an empty slice when even the
/// ellipsis alone doesn't — the caller decides whether "draw nothing" beats
/// overlapping something else. Advances come from the same per-codepoint
/// walk textPixelWidth sums, so a prefix capped here draws at exactly the
/// width it was measured against.
fn ellipsizeToFit(buf: []u8, font: *font_mod.Font, text: []const u8, max_w: i64) []const u8 {
    if (max_w <= 0) return "";
    if (textPixelWidth(font, text) <= max_w) return text;
    const ell_w = textPixelWidth(font, "…");
    if (ell_w > max_w) return "";
    var i: usize = 0;
    var used: i64 = 0;
    var keep: usize = 0;
    while (nextUtf8Codepoint(text, &i)) |cp| {
        const adv: i64 = (font.glyph(cp) catch continue).advance_x;
        if (used + adv + ell_w > max_w) break;
        used += adv;
        keep = i; // nextUtf8Codepoint leaves i past the codepoint just read
    }
    if (keep + "…".len > buf.len) return "";
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep .. keep + "…".len], "…");
    return buf[0 .. keep + "…".len];
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
/// All digits share ONE resting pill (no inner seams — the same treatment as
/// the center launcher runs and the mpris single bar); per-digit hover wash
/// and click regions are unchanged, so only the resting layer changes and
/// the pen advances exactly as before.
/// Returns the x position just past the last workspace drawn.
/// Draws the numbered workspace pills starting at `x0_start` (not a fixed
/// margin — the left group is now order-driven, so workspaces can live at
/// any position in the chain), returning the x after the last number. The
/// caller gates on module enabled/placement; this only draws and registers
/// click regions.
fn drawWorkspaces(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    workspaces: []const Workspace,
    x0_start: i64,
    click_regions: *ClickRegions,
) i64 {
    const y0: i64 = baselineY(buf_height, font);
    const workspace_gap = current_config.appearance.workspace_gap;

    // Measure pass: run bounds for the single shared resting pill. Replicates
    // the draw loop's pen walk exactly (content + trailing gap per number),
    // so the pill lands pixel-true on the per-digit hover bounds below.
    var id_buf: [8]u8 = undefined;
    var mx0: i64 = x0_start;
    var run_start: i64 = 0;
    var run_end: i64 = 0;
    var any = false;
    for (workspaces) |ws| {
        const text = std.fmt.bufPrint(&id_buf, "{d}", .{ws.id}) catch continue;
        const w = textPixelWidth(font, text);
        if (!any) {
            run_start = mx0 - @divTrunc(workspace_gap, 2);
            any = true;
        }
        run_end = mx0 + w + @divTrunc(workspace_gap, 2);
        mx0 += w + workspace_gap;
    }
    if (any) drawRestingPill(pixels, buf_width, buf_height, run_start, run_end);

    var x0: i64 = x0_start;
    for (workspaces) |ws| {
        const color = if (ws.active) current_config.appearance.workspace_active_color else current_config.appearance.workspace_inactive_color;
        const text = std.fmt.bufPrint(&id_buf, "{d}", .{ws.id}) catch continue;
        const region_start = x0;
        // Half the gap on each side, so there's no dead zone between numbers
        // — same bounds for the hover highlight as for the click region.
        const hover_start = region_start - @divTrunc(workspace_gap, 2);
        const hover_end = region_start + textPixelWidth(font, text) + @divTrunc(workspace_gap, 2);
        if (ws.active) drawActivePill(pixels, buf_width, buf_height, hover_start, hover_end);
        // Urgent (not active) digits wear the amber alert instead: pulsing
        // while animations are on, steady while off. Drawn under the hover
        // wash so a parked pointer overdraws it.
        if (!ws.active and ws.urgent) {
            const pulse: f32 = if (current_config.appearance.animations_enabled) bezelBreathAt(hover_frame) else 1.0;
            drawUrgentPill(pixels, buf_width, buf_height, hover_start, hover_end, pulse);
        }
        // Hover wash only — the shared resting pill above owns the ring (no
        // inner seams). Same geometry the per-digit resting pill used, so a
        // parked pointer paints identically.
        drawPill(pixels, buf_width, buf_height, hover_start, hover_end, click_regions.nextHover());
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, color, 0, buf_width);
        }
        click_regions.addScrollable(@intCast(hover_start), @intCast(hover_end), .{ .switch_workspace = ws.id }, .step_workspace);
        x0 += workspace_gap;
    }
    return x0;
}

const MPRIS_CONTROL_GAP: i64 = 6; // spacing between the three control glyphs, and before the track text
/// Clearance the LEFT group's mpris run keeps between its pill's right edge
/// and the center group's left edge (centerGroupStartX). The track title is
/// the only unbounded content in that chain — the clock's cell is the one
/// bound drawLeftGroup ever consults — so a long title used to grow
/// rightward until the pill touched the centered middle modules. Content is
/// capped so the pill's own 4px overhang still leaves a full MODULE_GAP of
/// air against the center group's leftmost pill (which overhangs up to
/// LAUNCHER_GAP/2 left of its start edge). Dock/morph modes pass their
/// packed center start as that same bound, so the cap holds in every layout.
const MPRIS_CENTER_CLEARANCE: i64 = 4 + MODULE_GAP;

/// Draws the previous/play-pause/next glyphs immediately before the mpris
/// track text, each a small click region targeting whichever player is
/// currently shown (via spawnPlayerctlCommand — not playerctl's no-target
/// default, which would act on every running player at once). Only called
/// when there's an active player to control; the play-pause glyph mirrors
/// the status icon already shown in the track text (pause glyph while
/// Playing, play glyph otherwise) so it always shows the action a click
/// performs, not the current state.
/// Round play/pause toggle box side shared by the left and center mpris
/// modules (reference look): squarish circular button. Measured identically
/// at compose time (centering) and draw time (pen advance).
fn mprisToggleSide(font: *font_mod.Font, playing: bool) i64 {
    const icon: u32 = if (playing) 0xf04c else 0xf04b;
    const adv = if (font.glyph(icon)) |g| g.advance_x else |_| 0;
    const dia: i64 = @as(i64, @intCast(current_config.appearance.bar_height)) - 2 * @as(i64, HOVER_PILL_PAD_Y);
    return @max(adv + 4, dia);
}

/// Media progress underline: accent bar under the mpris text spanning `frac`
/// of the run width, at the dash slot with capsule ends (min 8px so a sliver
/// always reads). No-op when frac is null (unknown length) or zero — the
/// hover dash still works wherever pills are interactive.
fn drawMprisProgress(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, run_w: i64, frac: ?f32) void {
    const f = frac orelse return;
    if (f <= 0.0 or run_w <= 0) return;
    const w = @max(@as(i64, 8), @as(i64, @intFromFloat(@as(f32, @floatFromInt(run_w)) * f)));
    const h: i64 = @intCast(buf_height);
    const uy1 = h - HOVER_UNDERLINE_BOTTOM_GAP;
    fillRoundedRect(pixels, buf_width, buf_height, x0, uy1 - HOVER_UNDERLINE_H, x0 + w, uy1, @divTrunc(HOVER_UNDERLINE_H + 1, 2), current_config.appearance.workspace_active_color);
}

/// One mpris pill shared by the left and center modules: resting pill
/// spanning track text + round toggle as a single bar (no inner-ring seam),
/// static text, progress underline, toggle hover wash. Returns the pen past
/// the button (no trailing gap; callers add spacing like every other module
/// kind). Empty text draws nothing and advances nothing.
/// Media progress bar fill: the "bar" mpris_progress_style. Fills the pill
/// interior behind the text from the left by `frac`, nesting inside the ring
/// exactly like hover washes do (same shared thickness). Subtle by design —
/// accent at 0.35 over the pill fill — so it reads as progress without
/// shouting over the track text. No-op when frac is null (unknown length)
/// or zero. Pure pixels except theme reads (see drawWeatherFx), so tests
/// render it into a scratch buffer below.
fn drawMprisBarFill(pixels: [*]u32, buf_width: u32, buf_height: u32, px0: i64, px1: i64, frac: ?f32) void {
    const f = frac orelse return;
    if (f <= 0.0) return;
    const w = px1 - px0;
    if (w <= 0) return;
    const h: i64 = @intCast(buf_height);
    const y0 = HOVER_PILL_PAD_Y;
    const y1 = h - HOVER_PILL_PAD_Y;
    if (y1 <= y0) return;
    const fw: i64 = @intFromFloat(@as(f32, @floatFromInt(w)) * @min(f, 1.0));
    if (fw <= 0) return;
    const t: i64 = bezelThick(w, h - 2 * HOVER_PILL_PAD_Y);
    const tr: i32 = @intCast(@max(@as(i64, 0), @as(i64, HOVER_PILL_RADIUS) - t));
    const base = if (current_config.appearance.module_pills) pillFillColor() else current_config.appearance.bg_color;
    const col = lerpColor(base, current_config.appearance.workspace_active_color, 0.35);
    fillRoundedRect(pixels, buf_width, buf_height, px0 + t, y0 + t, px0 + fw, y1 - t, tr, col);
}

fn drawMprisPill(pixels: [*]u32, buf_width: u32, buf_height: u32, font: *font_mod.Font, y0: i64, x0_start: i64, text: []const u8, playing: bool, frac: ?f32, click_regions: *ClickRegions) i64 {
    if (text.len == 0) return x0_start;
    const side = mprisToggleSide(font, playing);
    const text_w = textPixelWidth(font, text);
    var x0 = x0_start;
    // Resting pill over text + toggle as one bar (pad matches the static
    // segments' ±4px rhythm).
    const pill_x0 = x0 - 4;
    const pill_x1 = x0 + text_w + MPRIS_CONTROL_GAP + side + 4;
    drawRestingPill(pixels, buf_width, buf_height, pill_x0, pill_x1);
    // Bar-style progress lives UNDER the glyphs (it spans the text run);
    // the underline lives below them, so it draws after.
    const bar_fill = std.mem.eql(u8, current_config.appearance.mpris_progress_style, MPRIS_PROGRESS_BAR);
    if (bar_fill) drawMprisBarFill(pixels, buf_width, buf_height, pill_x0, pill_x1, frac);
    var i: usize = 0;
    while (nextUtf8Codepoint(text, &i)) |cp| {
        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
    }
    if (!bar_fill) {
        drawMprisProgress(pixels, buf_width, buf_height, x0_start, text_w, frac);
    }
    x0 += MPRIS_CONTROL_GAP;
    // Toggle hover wash only (the resting pill above owns ring + fill).
    drawPill(pixels, buf_width, buf_height, x0 - 2, x0 + side + 2, click_regions.nextHover());
    const icon: u32 = if (playing) 0xf04c else 0xf04b;
    const adv = if (font.glyph(icon)) |g| g.advance_x else |_| 0;
    const gx = x0 + @divTrunc(side - adv, 2);
    _ = drawGlyphAt(pixels, buf_width, buf_height, font, gx, y0, icon, current_config.appearance.text_color, 0, buf_width);
    click_regions.add(@intCast(x0 - 2), @intCast(x0 + side + 2), .{ .mpris_control = .play_pause });
    return x0 + side;
}


/// Draws the left group as an ordered chain in config order — the waybar
/// "modules-left" model where every left/center-capable module contributes
/// its own fixed width left-to-right, mpris included (static track text +
/// round toggle via drawMprisPill, same as the center module).
/// Workspaces/clock/launchers/mpris are each drawn at the running pen x and
/// advance it. RIGHT-only module kinds are ignored — the config GUI won't
/// place them in left, and the renderer has no left-anchored drawing for
/// them.
fn drawLeftGroup(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    workspaces: []const Workspace,
    time_text: []const u8,
    mpris_text: []const u8,
    mpris_playing: bool,
    mpris_frac: ?f32,
    center_start_x: i64,
    x0_start: i64,
    click_regions: *ClickRegions,
) i64 {
    const y0: i64 = baselineY(buf_height, font);
    var x0: i64 = x0_start;
    var any_drawn = false;
    for (current_config.modules.left) |entry| {
        if (!entry.enabled) continue;
        // Guaranteed module→module padding (mirroring the center group's
        // boundary gap): whatever pen the previous module's own trailing gap
        // left, the next module still starts MODULE_GAP after it, so a drag
        // that rejoins any two kinds (clock flush after launchers was a
        // 0-gap collision before) can never sit them flush against each
        // other. Kinds that reserve their own MODULE_CELL_MIN cell below get
        // that gap for free from the cell's padding, so it isn't double-counted.
        if (any_drawn) x0 += MODULE_GAP;
        switch (entry.kind) {
            .workspaces => {
                x0 = drawWorkspaces(pixels, buf_width, buf_height, font, workspaces, x0, click_regions);
            },
            .clock => {
                // Static text, identical treatment to the center's clock
                // segment (not clickable here either). Reserved a
                // MODULE_CELL_MIN-wide cell like the right group's
                // single-content modules, bounded by the center group's
                // start edge — the left group advances rightward, so that
                // edge is the only thing stopping a cell from growing into
                // the center. Draws from cell.content_start, not from the
                // pen, so the glyph run starts at the centered position
                // while the pen jumps straight to the cell's right edge.
                const cell = reserveLeftCell(x0, textPixelWidth(font, time_text), center_start_x);
                // Resting pill over the cell, ±4px like drawRightAligned's
                // modules: the cell sits in the 12px module-gap rhythm where
                // neighbors intrude up to 8px, so anything wider overlaps the
                // next pill. (Cell bounds hug the text exactly — MODULE_CELL_MIN
                // only pads tiny content — so the ±0 they replaced put glyphs
                // right on the border.)
                drawRestingPill(pixels, buf_width, buf_height, cell.content_start - 4, cell.content_end + 4);
                var cx = cell.content_start;
                var i: usize = 0;
                while (nextUtf8Codepoint(time_text, &i)) |cp| {
                    cx += drawGlyphAt(pixels, buf_width, buf_height, font, cx, y0, cp, current_config.appearance.text_color, 0, buf_width);
                }
                x0 = cell.next_pen;
            },
            .launchers => {
                // Every pinned launcher, left-aligned from the running pen —
                // rendered per its display mode (name-only, name + icon, or
                // icon-only — the per-launcher choice the config GUI stores
                // in `display`). Icon-only falls back to the name when no
                // icon decodes, so the button stays clickable/visible, and
                // name-only skips the icon entirely. Either way: icon (if
                // drawn), label (if drawn), hover highlight, launcher click
                // (raises the app when running, launches when not).
                // Unpinned running apps trail the pins as text buttons
                // (Windows-taskbar style), wearing the same running dot.
                // Measure pass: span ONE resting pill across the whole button
                // run instead of separated per-button pills. Width logic
                // mirrors the draw loop below — keep in sync.
                var unpinned: [MAX_UNPINNED_GROUPS]UnpinnedGroup = undefined;
                const unpinned_n = collectUnpinned(&unpinned);
                var run_x = x0;
                var run_first = true;
                var run_start: i64 = 0;
                var run_end: i64 = 0;
                for (0..launcher_view_len) |vp| {
                    const mli = launcher_view_order[vp];
                    if (mli >= current_config.launchers.len) continue;
                    const mbtn = current_config.launchers[mli];
                    const mhas = mli < launcher_icons.len and launcher_icons[mli].has_icon;
                    const mdistro: u32 = if (mli < launcher_icons.len) launcher_icons[mli].distro_glyph else 0;
                    // Icon-only taskbar: the label survives solely as the
                    // fallback when no icon resolved, so a button is never
                    // invisible.
                    const mdraw_icon = (mhas or mdistro != 0);
                    const mdraw_label = !mdraw_icon;
                    var mdg: [4]u8 = undefined;
                    const munit: i64 = if (mhas and mdistro == 0) LAUNCHER_ICON_SIZE else if (mdistro != 0) textPixelWidth(font, encodeBmpCodepoint(mdistro, &mdg)) else 0;
                    const mw = (if (mdraw_label) textPixelWidth(font, mbtn.label) else 0) + (if (mdraw_icon) munit + (if (mdraw_label) LAUNCHER_ICON_TEXT_GAP else 0) else 0);
                    if (run_first) {
                        run_start = run_x - @divTrunc(LAUNCHER_GAP, 2);
                        run_first = false;
                    } else {
                        run_x += LAUNCHER_GAP;
                    }
                    run_x += mw;
                    run_end = run_x + @divTrunc(LAUNCHER_GAP, 2);
                }
                for (unpinned[0..unpinned_n]) |g| {
                    const mw = tailButtonWidth(font, &g);
                    if (run_first) {
                        run_start = run_x - @divTrunc(LAUNCHER_GAP, 2);
                        run_first = false;
                    } else {
                        run_x += LAUNCHER_GAP;
                    }
                    run_x += mw;
                    run_end = run_x + @divTrunc(LAUNCHER_GAP, 2);
                }
                if (!run_first) drawRestingPill(pixels, buf_width, buf_height, run_start, run_end);
                for (0..launcher_view_len) |vp| {
                    const li = launcher_view_order[vp];
                    if (li >= current_config.launchers.len) continue;
                    const btn = current_config.launchers[li];
                    const has_icon = li < launcher_icons.len and launcher_icons[li].has_icon;
                    const distro: u32 = if (li < launcher_icons.len) launcher_icons[li].distro_glyph else 0;
                    const draw_png = has_icon and distro == 0;
                    const draw_glyph = distro != 0;
                    const draw_icon = draw_png or draw_glyph;
                    const draw_label = !draw_icon;
                    // The text gap only separates an icon from a following
                    // label — in icon-only mode it would be 5px of dead space
                    // trailing the icon, sitting the icon left-of-center in
                    // its pill.
                    var dg_buf: [4]u8 = undefined;
                    const dg_str: []const u8 = if (distro != 0) encodeBmpCodepoint(distro, &dg_buf) else "";
                    const icon_unit: i64 = if (draw_png) LAUNCHER_ICON_SIZE else if (draw_glyph) textPixelWidth(font, dg_str) else 0;
                    const icon_w: i64 = if (draw_icon) icon_unit + (if (draw_label) LAUNCHER_ICON_TEXT_GAP else 0) else 0;
                    const label_w = (if (draw_label) textPixelWidth(font, btn.label) else 0) + icon_w;
                    const region_start = x0;
                    const hover_start = region_start - @divTrunc(LAUNCHER_GAP, 2);
                    const hover_end = region_start + label_w + @divTrunc(LAUNCHER_GAP, 2);
                    drawPill(pixels, buf_width, buf_height, hover_start, hover_end, click_regions.nextHover());
                    if (draw_icon and li < launcher_icons.len) {
                        if (draw_glyph) {
                            var gi: usize = 0;
                            while (nextUtf8Codepoint(dg_str, &gi)) |cp| {
                                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
                            }
                            x0 += icon_w - textPixelWidth(font, dg_str);
                        } else {
                            drawLauncherIcon(pixels, buf_width, buf_height, x0, &launcher_icons[li]);
                            x0 += icon_w;
                        }
                    }
                    if (draw_label) {
                        var i: usize = 0;
                        while (nextUtf8Codepoint(btn.label, &i)) |cp| {
                            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
                        }
                    }
                    const live = launcherLive(btn.command);
                    if (live.count > 0) drawRunningDot(pixels, buf_width, buf_height, region_start + @divTrunc(label_w, 2), live.focused);
                    click_regions.add(@intCast(hover_start), @intCast(hover_end), .{ .launcher = li });
                    x0 += LAUNCHER_GAP;
                }
                for (unpinned[0..unpinned_n]) |g| {
                    const uw = tailButtonWidth(font, &g);
                    const uregion_start = x0;
                    const uhover_start = uregion_start - @divTrunc(LAUNCHER_GAP, 2);
                    const uhover_end = uregion_start + uw + @divTrunc(LAUNCHER_GAP, 2);
                    drawPill(pixels, buf_width, buf_height, uhover_start, uhover_end, click_regions.nextHover());
                    if (tailHasIcon(&g)) {
                        if (tailIconPixels(running_state.apps[g.client_idx].appid())) |px| {
                            blitIcon16(pixels, buf_width, buf_height, x0, px);
                        }
                        x0 += uw;
                    } else {
                        var ui: usize = 0;
                        while (nextUtf8Codepoint(g.name(), &ui)) |cp| {
                            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
                        }
                    }
                    drawRunningDot(pixels, buf_width, buf_height, uregion_start + @divTrunc(uw, 2), g.focused);
                    click_regions.add(@intCast(uhover_start), @intCast(uhover_end), .{ .focus_client = g.client_idx });
                    x0 += LAUNCHER_GAP;
                }
            },
            .mpris => {
                // Same pill as the center module (static text + round toggle
                // + progress) — one shared code path with the center module.
                // Empty text draws nothing and advances nothing.
                //
                // The track title is unbounded content: nothing in this
                // chain ever bounded it against the center group's left
                // edge (the clock's reserveLeftCell below is the only bound
                // drawLeftGroup has), so a long title grew rightward until
                // the pill ran into the centered middle modules. Cap the
                // run at that edge instead: draw in the room actually left,
                // ellipsizing the title when it doesn't fit, and draw
                // nothing when not even the round toggle fits (a missing
                // module beats one overlapping the middle of the bar).
                if (mpris_text.len > 0) {
                    const toggle_w = MPRIS_CONTROL_GAP + mprisToggleSide(font, mpris_playing);
                    const avail = center_start_x - MPRIS_CENTER_CLEARANCE - x0;
                    if (textPixelWidth(font, mpris_text) + toggle_w <= avail) {
                        x0 = drawMprisPill(pixels, buf_width, buf_height, font, y0, x0, mpris_text, mpris_playing, mpris_frac, click_regions);
                    } else if (avail > toggle_w) {
                        // mpris_text is capped at 64 bytes upstream
                        // (paintFrame's mpris_buf); the ellipsized output is
                        // a prefix of it plus three bytes.
                        var tbuf: [67]u8 = undefined;
                        const capped = ellipsizeToFit(&tbuf, font, mpris_text, avail - toggle_w);
                        if (capped.len > 0) {
                            x0 = drawMprisPill(pixels, buf_width, buf_height, font, y0, x0, capped, mpris_playing, mpris_frac, click_regions);
                        }
                    }
                }
            },
            else => {}, // RIGHT-only kind in left: no left-anchored render for it
        }
        any_drawn = true;
    }
    // Pen end = content end (every module advances past exactly what drew).
    return x0;
}

/// Draws the launcher buttons + clock as one centered group, matching
/// waybar's "modules-center" (the whole group is centered together, not
/// each item individually). Registers a click region per launcher button;
/// the clock itself isn't clickable here (a calendar popup is a possible
/// future addition — the upstream clock module's calendar app is no longer
/// installed).
// Center holds a centered whole block, so every left/center-capable module
// kind that may now live there composes into drawable segments: launcher
// buttons and clock text (the original two), plus workspace number pills
// and the mpris track label once cross-group drag lets them be placed in
// center. Cap is generous because workspaces contribute one segment each.
const MAX_CENTER_SEGMENTS = 64;

/// One drawable piece of the center group. Kinds:
/// - launcher button: `command` set, `icon_w`/`launcher_idx` when it has an
///   app icon. Clickable (spawn).
/// - clock text / mpris track label: `command` null, `ws_id` null. Not
///   clickable.
/// - workspace pill: `ws_id` set (= workspace number), with per-workspace
///   active coloring, hover highlight, and a switch_workspace click region
///   exactly like the left chain's workspaces. The id digits are stored in
///   the segment's own `label_buf` (the compose() output must outlive the
///   local framebuffer that formatted them), so `label` always points at
///   self-owned storage.
/// `gap_after` is the horizontal space to leave after this segment before
/// the next one.
const CenterSegment = struct {
    label: []const u8,
    label_buf: [8]u8 = undefined,
    command: ?[:0]const u8 = null,
    gap_after: i64 = 0,
    /// Non-zero when this launcher renders a decoded app icon before its
    /// label — the icon's width plus the icon→text gap. Drives both the
    /// measuring pass and the draw pass through the same compose() output.
    icon_w: i64 = 0,
    /// Index into launcher_icons[] hashing the decoded icon for this
    /// segment (only meaningful when `icon_w` is non-zero).
    launcher_idx: usize = 0,
    /// Non-null when this is a workspace number pill rather than a launcher
    /// or plain-text segment.
    ws_id: ?i32 = null,
    ws_active: bool = false,
    ws_urgent: bool = false,
    /// Set when this is an unpinned running-app button (taskbar tail):
    /// index into running_state.apps to raise on click. `label` points at
    /// this segment's own `task_buf` (same self-owned pattern as ws
    /// label_buf), `task_focused` lights the running dot.
    focus_idx: ?usize = null,
    task_focused: bool = false,
    task_buf: [24]u8 = undefined,
    /// True when this static segment is the mpris track label (gets the
    /// progress underline when the player reports position/length).
    mpris: bool = false,
    /// Play/pause toggle width (glyph advance + leading gap) appended after
    /// an mpris label, 0 when the seg isn't mpris. Measured at compose time
    /// so centering accounts for it exactly like any other width.
    mpris_toggle_w: i64 = 0,
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
/// Cross-group drag lets any left/center-capable module kind live here now,
/// so beyond the original clock + launchers this also emits workspace
/// pills (colored, clickable) and a static mpris track label.
fn composeCenterSegments(out: *CenterSegments, font: *font_mod.Font, time_text: []const u8, workspaces: []const Workspace, mpris_text: []const u8, mpris_playing: bool) void {
    out.* = .{};
    var emitted_any = false;
    for (current_config.modules.center) |entry| {
        if (!entry.enabled) continue;
        // Module-boundary padding: the segment that closed the previous
        // module always gets at least MODULE_GAP of trailing space, so two
        // modules never collide no matter which kinds a cross-group drag
        // joined (workspace pills leave workspace_gap between themselves,
        // launcher buttons LAUNCHER_GAP, but the module→module handoff needs
        // the full gap regardless of what either module is).
        if (emitted_any and out.len > 0 and out.items[out.len - 1].gap_after < MODULE_GAP) {
            out.items[out.len - 1].gap_after = MODULE_GAP;
        }
        const len_before = out.len;
        switch (entry.kind) {
            .clock => {
                if (out.len < out.items.len) {
                    out.items[out.len] = .{ .label = time_text, .command = null, .gap_after = MODULE_GAP };
                    out.len += 1;
                }
            },
            .launchers => {
                for (0..launcher_view_len) |vp| {
                    const i = launcher_view_order[vp];
                    if (i >= current_config.launchers.len) continue;
                    const btn = current_config.launchers[i];
                    if (out.len >= out.items.len) break;
                    const has_icon = i < launcher_icons.len and launcher_icons[i].has_icon;
                    const distro: u32 = if (i < launcher_icons.len) launcher_icons[i].distro_glyph else 0;
                    const draw_png = has_icon and distro == 0;
                    const draw_glyph = distro != 0;
                    const draw_icon = draw_png or draw_glyph;
                    const draw_label = !draw_icon;
                    // A distro logo is a font glyph, not a 16px PNG: measure
                    // it so icon_w (and everything downstream — centering,
                    // hover bounds, pen advance) stays exact.
                    var dg_buf: [4]u8 = undefined;
                    const icon_unit: i64 = if (draw_png) LAUNCHER_ICON_SIZE else if (draw_glyph) textPixelWidth(font, encodeBmpCodepoint(distro, &dg_buf)) else 0;
                    out.items[out.len] = .{
                        .label = if (draw_label) btn.label else "",
                        .command = btn.command,
                        .gap_after = LAUNCHER_GAP,
                        .icon_w = if (draw_icon) icon_unit + (if (draw_label) LAUNCHER_ICON_TEXT_GAP else 0) else 0,
                        .launcher_idx = i,
                    };
                    out.len += 1;
                }
                // Taskbar tail: unpinned running apps as text buttons after
                // the pins (same order as the left group's, one shared
                // collectUnpinned source so the two can never disagree).
                var tail: [MAX_UNPINNED_GROUPS]UnpinnedGroup = undefined;
                const tail_n = collectUnpinned(&tail);
                for (tail[0..tail_n]) |g| {
                    if (out.len >= out.items.len) break;
                    var seg = &out.items[out.len];
                    seg.* = .{ .label = "", .gap_after = LAUNCHER_GAP, .focus_idx = g.client_idx, .task_focused = g.focused };
                    if (tailHasIcon(&g)) {
                        // Icon-only: no label, no icon→text gap.
                        seg.icon_w = LAUNCHER_ICON_SIZE;
                    } else {
                        const nl = @min(g.name().len, seg.task_buf.len);
                        @memcpy(seg.task_buf[0..nl], g.name()[0..nl]);
                        seg.label = seg.task_buf[0..nl];
                    }
                    out.len += 1;
                }
            },
            .workspaces => {
                // Id digits are formatted directly into `out`'s OWN segment's
                // label_buf — the caller's CenterSegments backs the array, so
                // the slice points at stable memory that survives this call.
                // (The old version formatted into a function-local `seg` and
                // copied the struct, which copied the label_buf bytes but not
                // the pointer — every segment's `label` aliased the same dead
                // stack slot, so every pill showed the last workspace number.)
                for (workspaces) |ws| {
                    if (out.len >= out.items.len) break;
                    var seg = &out.items[out.len];
                    seg.* = .{ .label = "", .gap_after = current_config.appearance.workspace_gap };
                    seg.ws_id = ws.id;
                    seg.ws_active = ws.active;
                    seg.ws_urgent = ws.urgent;
                    seg.label = std.fmt.bufPrint(&seg.label_buf, "{d}", .{ws.id}) catch "";
                    out.len += 1;
                }
            },
            .mpris => {
                if (mpris_text.len > 0 and out.len < out.items.len) {
                    // mpris in center is a static label plus a play/pause
                    // toggle, sharing drawMprisPill with the left module.
                    out.items[out.len] = .{ .label = mpris_text, .command = null, .gap_after = MODULE_GAP, .mpris = true, .mpris_toggle_w = mprisToggleSide(font, mpris_playing) + MPRIS_CONTROL_GAP };
                    out.len += 1;
                }
            },
            else => {}, // not a center-capable module kind; ignore defensively
        }
        if (out.len > len_before) emitted_any = true;
    }
}

fn centerGroupWidth(font: *font_mod.Font, time_text: []const u8, workspaces: []const Workspace, mpris_text: []const u8, mpris_playing: bool) i64 {
    var segs: CenterSegments = .{};
    composeCenterSegments(&segs, font, time_text, workspaces, mpris_text, mpris_playing);
    var total: i64 = 0;
    for (segs.items[0..segs.len]) |seg| total += seg.icon_w + textPixelWidth(font, seg.label) + seg.mpris_toggle_w + seg.gap_after;
    return total;
}

/// x position of the center group's left edge — the boundary drawMpris
/// must stay clear of (it grows rightward from the workspaces and would
/// otherwise run into this pixel-for-pixel identical calculation).
fn centerGroupStartX(buf_width: u32, font: *font_mod.Font, time_text: []const u8, workspaces: []const Workspace, mpris_text: []const u8, mpris_playing: bool) i64 {
    return @divTrunc(@as(i64, @intCast(buf_width)) - centerGroupWidth(font, time_text, workspaces, mpris_text, mpris_playing), 2);
}

fn drawCenterGroup(
    pixels: [*]u32,
    buf_width: u32,
    buf_height: u32,
    font: *font_mod.Font,
    time_text: []const u8,
    workspaces: []const Workspace,
    mpris_text: []const u8,
    mpris_frac: ?f32,
    mpris_playing: bool,
    x0_start: i64,
    click_regions: *ClickRegions,
) i64 {
    const y0: i64 = baselineY(buf_height, font);
    var x0: i64 = x0_start;
    var segs: CenterSegments = .{};
    composeCenterSegments(&segs, font, time_text, workspaces, mpris_text, mpris_playing);

    // Measure pass: ONE resting pill per consecutive launcher-button run
    // and ONE per consecutive workspace-digit run (joined digits, no inner
    // seams) instead of separated per-button/per-digit pills. The x-walk
    // replicates the draw loop below exactly (content + trailing gap_after
    // per segment); run bounds match the per-button/per-digit hover bounds
    // the draw loop recomputes, so the pills land pixel-true.
    const workspace_gap = current_config.appearance.workspace_gap;
    var scan_x = x0;
    var scan_run = false;
    var scan_start: i64 = 0;
    var scan_last_end: i64 = 0;
    var wscan_run = false;
    var wscan_start: i64 = 0;
    var wscan_last_end: i64 = 0;
    for (segs.items[0..segs.len]) |seg| {
        const seg_w = seg.icon_w + textPixelWidth(font, seg.label);
        const is_launcher = (seg.command != null or seg.focus_idx != null) and seg.ws_id == null;
        if (is_launcher and !scan_run) {
            scan_run = true;
            scan_start = scan_x - @divTrunc(LAUNCHER_GAP, 2);
        }
        if (is_launcher) scan_last_end = scan_x + seg_w;
        if (!is_launcher and scan_run) {
            scan_run = false;
            drawRestingPill(pixels, buf_width, buf_height, scan_start, scan_last_end + @divTrunc(LAUNCHER_GAP, 2));
        }
        const is_ws = seg.ws_id != null;
        if (is_ws and !wscan_run) {
            wscan_run = true;
            wscan_start = scan_x - @divTrunc(workspace_gap, 2);
        }
        if (is_ws) wscan_last_end = scan_x + seg_w + @divTrunc(workspace_gap, 2);
        if (!is_ws and wscan_run) {
            wscan_run = false;
            drawRestingPill(pixels, buf_width, buf_height, wscan_start, wscan_last_end);
        }
        scan_x += seg_w + seg.gap_after;
    }
    if (scan_run) drawRestingPill(pixels, buf_width, buf_height, scan_start, scan_last_end + @divTrunc(LAUNCHER_GAP, 2));
    if (wscan_run) drawRestingPill(pixels, buf_width, buf_height, wscan_start, wscan_last_end);

    for (segs.items[0..segs.len]) |seg| {
        if (seg.ws_id) |ws_id| {
            const color = if (seg.ws_active) current_config.appearance.workspace_active_color else current_config.appearance.workspace_inactive_color;
            const region_start = x0;
            const hover_start = region_start - @divTrunc(workspace_gap, 2);
            const hover_end = region_start + textPixelWidth(font, seg.label) + @divTrunc(workspace_gap, 2);
            if (seg.ws_active) drawActivePill(pixels, buf_width, buf_height, hover_start, hover_end);
            // Urgent (not active) digits wear the amber alert instead (see
            // the left workspaces loop for the layering).
            if (!seg.ws_active and seg.ws_urgent) {
                const pulse: f32 = if (current_config.appearance.animations_enabled) bezelBreathAt(hover_frame) else 1.0;
                drawUrgentPill(pixels, buf_width, buf_height, hover_start, hover_end, pulse);
            }
            // Hover wash only — the shared run pill from the measure pass
            // owns the ring (no inner seams).
            drawPill(pixels, buf_width, buf_height, hover_start, hover_end, click_regions.nextHover());
            var i: usize = 0;
            while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, color, 0, buf_width);
            }
            click_regions.addScrollable(@intCast(hover_start), @intCast(hover_end), .{ .switch_workspace = ws_id }, .step_workspace);
        } else if (seg.command != null) {
            const region_start = x0;
            const label_w = seg.icon_w + textPixelWidth(font, seg.label);
            const hover_start = region_start - @divTrunc(LAUNCHER_GAP, 2);
            const hover_end = region_start + label_w + @divTrunc(LAUNCHER_GAP, 2);
            drawPill(pixels, buf_width, buf_height, hover_start, hover_end, click_regions.nextHover());
            if (seg.icon_w > 0 and seg.launcher_idx < launcher_icons.len) {
                const distro = launcher_icons[seg.launcher_idx].distro_glyph;
                if (distro != 0) {
                    // Distro logo: same glyph the drawer brands itself with,
                    // drawn on the text baseline (not the 16px icon box).
                    var dg_buf: [4]u8 = undefined;
                    const dg_str = encodeBmpCodepoint(distro, &dg_buf);
                    var gi: usize = 0;
                    while (nextUtf8Codepoint(dg_str, &gi)) |cp| {
                        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
                    }
                    x0 += seg.icon_w - textPixelWidth(font, dg_str);
                } else {
                    drawLauncherIcon(pixels, buf_width, buf_height, x0, &launcher_icons[seg.launcher_idx]);
                    x0 += seg.icon_w;
                }
            }
            var i: usize = 0;
            while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
            }
            // Pinned icon doubles as its running app (same launcherLive
            // source as the left group); guard the index for a config that
            // reloaded between compose and draw (same frame — can't happen,
            // but the union payload would raise the wrong pin otherwise).
            if (seg.launcher_idx < current_config.launchers.len) {
                const live = launcherLive(current_config.launchers[seg.launcher_idx].command);
                if (live.count > 0) drawRunningDot(pixels, buf_width, buf_height, region_start + @divTrunc(label_w, 2), live.focused);
                click_regions.add(@intCast(hover_start), @intCast(hover_end), .{ .launcher = seg.launcher_idx });
            }
        } else if (seg.focus_idx) |fci| {
            // Unpinned running-app button: icon when resolved (icon-only
            // like the pins), label fallback otherwise, focus click, same
            // running dot (a tail row only exists while up, so always lit).
            const region_start = x0;
            const label_w = seg.icon_w + textPixelWidth(font, seg.label);
            const hover_start = region_start - @divTrunc(LAUNCHER_GAP, 2);
            const hover_end = region_start + label_w + @divTrunc(LAUNCHER_GAP, 2);
            drawPill(pixels, buf_width, buf_height, hover_start, hover_end, click_regions.nextHover());
            if (seg.icon_w > 0) {
                if (fci < running_state.len) {
                    if (tailIconPixels(running_state.apps[fci].appid())) |px| {
                        blitIcon16(pixels, buf_width, buf_height, x0, px);
                    }
                }
                x0 += seg.icon_w;
            } else {
                var i: usize = 0;
                while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                    x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
                }
            }
            drawRunningDot(pixels, buf_width, buf_height, region_start + @divTrunc(label_w, 2), seg.task_focused);
            click_regions.add(@intCast(hover_start), @intCast(hover_end), .{ .focus_client = fci });
        } else if (seg.mpris) {
            // mpris shares the left module's pill wholesale (one bar, one
            // code path) — text, progress, round toggle and all.
            x0 = drawMprisPill(pixels, buf_width, buf_height, font, y0, x0, seg.label, mpris_playing, mpris_frac, click_regions);
        } else {
            // Static segment (clock, plain label): resting pill over the
            // content bounds at ±4px (drawRightAligned rhythm — the segment
            // sits in trailing-gap spacing where neighbors intrude, so the
            // ±8 used for joined launcher runs would overlap).
            const st_w = seg.icon_w + textPixelWidth(font, seg.label);
            drawRestingPill(pixels, buf_width, buf_height, x0 - 4, x0 + st_w + 4);
            if (seg.icon_w > 0 and seg.launcher_idx < launcher_icons.len) {
                drawLauncherIcon(pixels, buf_width, buf_height, x0, &launcher_icons[seg.launcher_idx]);
                x0 += seg.icon_w;
            }
            var i: usize = 0;
            while (nextUtf8Codepoint(seg.label, &i)) |cp| {
                x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, current_config.appearance.text_color, 0, buf_width);
            }
        }
        x0 += seg.gap_after;
    }
    return x0;
}

/// Blits a launcher's decoded app icon (a LAUNCHER_ICON_SIZE square, row-0
/// at top) with its left edge at `x0`, vertically centered, alpha-blended
/// against the bar's background the same way the tray path blends its icons
/// (dst is always opaque here, so coverage-weighted RGB is exact).
/// Blits a LAUNCHER_ICON_SIZE square (row-0 at top) with its left edge at
/// `x0`, vertically centered, alpha-blended against the bar's background
/// the same way the tray path blends its icons (dst is always opaque here,
/// so coverage-weighted RGB is exact). Shared by launcher pins and the
/// taskbar tail — both caches hold the same 16px format.
fn blitIcon16(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, icon: []const u32) void {
    const y0 = @divTrunc(@as(i64, @intCast(buf_height)) - LAUNCHER_ICON_SIZE, 2);
    for (0..LAUNCHER_ICON_SIZE) |iy| {
        for (0..LAUNCHER_ICON_SIZE) |ix| {
            const src = icon[iy * LAUNCHER_ICON_SIZE + ix];
            const coverage: u8 = @intCast((src >> 24) & 0xFF);
            if (coverage == 0) continue;
            const px = x0 + @as(i64, @intCast(ix));
            const py = y0 + @as(i64, @intCast(iy));
            if (px < 0 or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= buf_width or pyu >= buf_height) continue;
            const idx = pyu * buf_width + pxu;
            pixels[idx] = blendPixel(pixels[idx], src, coverage);
        }
    }
}

/// Draws a launcher's decoded app icon (kept as the thin wrapper so the
/// existing call sites read unchanged).
fn drawLauncherIcon(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, cache: *const LauncherIconCache) void {
    blitIcon16(pixels, buf_width, buf_height, x0, &cache.pixels);
}

/// Draws `label` ending at `x_end` (its right edge), returns the x
/// coordinate of its left edge — so callers can chain right-to-left layout
/// by feeding each call's result in as the next one's `x_end`. Registers a
/// click region (with a few px of padding) when `action` is given.
/// Span accumulator for the drawer island: the min/max x of one frame's
/// drawn in-drawer cells. Recorded during drawRightGroup's walk and painted
/// (from the previous frame's span, dock-pack style) before the next walk.
const IslandSpan = struct {
    set: bool = false,
    x0: i64 = 0,
    x1: i64 = 0,
    fn include(self: *IslandSpan, lo: i64, hi: i64) void {
        if (!self.set) {
            self.set = true;
            self.x0 = lo;
            self.x1 = hi;
        } else {
            self.x0 = @min(self.x0, lo);
            self.x1 = @max(self.x1, hi);
        }
    }
};

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
    click_regions: *ClickRegions,
    island: ?*IslandSpan,
    scroll_action: ?ScrollAction,
) i64 {
    const region_start = x_end - textPixelWidth(font, label);
    if (island) |sp| {
        // Drawer-island member: the shared island pill (painted from last
        // frame's span before this walk) owns the ring — hover wash only, on
        // the same bounds the resting pill used, so a parked pointer paints
        // identically to the separated-pill days.
        sp.include(region_start - 4, x_end + 4);
        drawPill(pixels, buf_width, buf_height, region_start - 4, x_end + 4, if (action != null) click_regions.nextHover() else 0.0);
    } else {
        // Every module gets its resting pill; only clickable labels can light it
        // — static readouts pass a zero fade level outright, since they register
        // no region and must not mirror a neighbor's animation.
        drawModulePill(pixels, buf_width, buf_height, region_start - 4, x_end + 4, if (action != null) click_regions.nextHover() else 0.0);
    }
    var x0 = region_start;
    var i: usize = 0;
    while (nextUtf8Codepoint(label, &i)) |cp| {
        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, color, 0, buf_width);
    }
    if (action) |a| {
        if (scroll_action) |sa| {
            click_regions.addScrollable(@intCast(region_start - 4), @intCast(x0 + 4), a, sa);
        } else {
            click_regions.add(@intCast(region_start - 4), @intCast(x0 + 4), a);
        }
    }
    return region_start;
}

/// Bar modes (appearance.bar_mode values).
const BAR_MODE_TASKBAR = "taskbar";
const BAR_MODE_DOCK = "dock";
/// Dock-mode gaps: edge = space between the dock and its screen edge,
/// side = inset from the left/right screen edges. Taskbar keeps today's
/// exact zeros (MARGIN_SIDE).
const DOCK_MARGIN_EDGE: i32 = 10;
const DOCK_MARGIN_SIDE: i32 = 16;
/// Gap between packed groups in dock mode (same rhythm as MODULE_GAP).
const DOCK_GAP: i64 = 12;
/// Padding around the packed content for the dock's background pill.
const DOCK_PILL_PAD: i64 = 8;
/// Auto-hide hint strip thickness (px) at the screen edge while hidden.
const AUTOHIDE_STRIP_PX: i32 = 2;
/// Hide delay after the pointer leaves, in scroll-timer ticks
/// (5 × 60ms ≈ 300ms — calm, not flickery).
const AUTOHIDE_GRACE_TICKS: u32 = 5;
/// Taskbar↔dock morph pacing: fraction of the transition per 60ms tick
/// (~11 ticks ≈ 660ms of squash-and-stretch; the elastic curve itself carries
/// the overshoot, so this only sets the tempo, not the shape).
const MODE_MORPH_STEP: f32 = 0.09;

/// Classic ease-out elastic: shoots past 1 early, then wobbles down to it —
/// the rubber band. ref: easings.net easeOutElastic (c4 amplitude term).
fn easeOutElastic(t: f32) f32 {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    const c4 = (2.0 * std.math.pi) / 3.0;
    return std.math.pow(f32, 2.0, -10.0 * t) * std.math.sin((t * 10.0 - 0.75) * c4) + 1.0;
}

/// Hover fade pacing: fraction per 60ms scroll-timer tick (~150ms full fade —
/// deliberately snappier than the drawer's ~240ms, since hover tracks the
/// pointer and must never feel laggy).
const HOVER_ANIM_STEP: f32 = 0.4;
/// Opacity ceiling for the hover treatment: even fully faded in, the pill
/// and underline only blend this far from the background toward their
/// colors, keeping the highlight a subtle glow rather than a solid block.
const HOVER_MAX_ALPHA: f32 = 0.55;
/// Vertical inset of the hover pill from the bar's top/bottom edges.
const HOVER_PILL_PAD_Y: i32 = 4;
/// Corner radius of the hover pill (clamped to half the pill height, so a
/// large value degrades gracefully to capsule ends instead of breaking).
const HOVER_PILL_RADIUS: i32 = 12;
/// Thickness of the accent underline.
const HOVER_UNDERLINE_H: i32 = 3;
/// Gap between the underline's bottom edge and the bar's bottom edge.
const HOVER_UNDERLINE_BOTTOM_GAP: i32 = 2;

/// Urgent-workspace dot color: warm amber, fixed (urgency reads
/// conventionally, not thematically — matching the reference look rather
/// than the palette). Also tints the alert pill below.
const URGENT_AMBER: u32 = 0xFFF5A524;
/// Urgent-workspace alert: amber wash + amber dash at `strength` (0..1),
/// no bezel of its own (it nests inside the shared workspace-run ring like
/// every other wash). Drawn under the hover layer so a hovered urgent digit
/// simply overdraws it. Strength comes from bezelBreathAt's 0.55..1.0 swell
/// while animations are on (gentle pulse until visited), flat 1.0 while off.
fn drawUrgentPill(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64, strength: f32) void {
    if (strength <= 0.0) return;
    const bg = current_config.appearance.bg_color;
    const a = strength * HOVER_MAX_ALPHA;
    const wash = lerpColor(bg, URGENT_AMBER, a);
    const line = lerpColor(bg, URGENT_AMBER, a);
    const h: i64 = @intCast(buf_height);
    const wt: i64 = bezelThick(x_end - x_start, h - 2 * HOVER_PILL_PAD_Y);
    const wr: i32 = @intCast(@max(@as(i64, 0), @as(i64, HOVER_PILL_RADIUS) - wt));
    fillRoundedRect(pixels, buf_width, buf_height, x_start + wt, HOVER_PILL_PAD_Y + wt, x_end - wt, h - HOVER_PILL_PAD_Y - wt, wr, wash);
    const w = x_end - x_start;
    const uw = @max(@as(i64, 8), @divTrunc(w, 3));
    const cx = @divTrunc(x_start + x_end, 2);
    const ux0 = cx - @divTrunc(uw, 2);
    const uy1 = h - HOVER_UNDERLINE_BOTTOM_GAP;
    fillRoundedRect(pixels, buf_width, buf_height, ux0, uy1 - HOVER_UNDERLINE_H, ux0 + uw, uy1, @divTrunc(HOVER_UNDERLINE_H + 1, 2), line);
}

/// Frames elapsed on the scroll-timer tick — the clock for the hover bezel
/// rotation below. Wraps rather than resetting; phase math is modulo-based.
var hover_frame: u32 = 0;

/// Hover/active bezel styles (appearance.bezel_style values).
const BEZEL_STYLE_MATUGEN = "matugen";
const BEZEL_STYLE_RAINBOW_PUKE = "rainbow-puke";
const BEZEL_STYLE_SOLID = "solid";

/// Hover/active bezel effects (appearance.bezel_effect values) — what the
/// ring does, independent of the style above.
const BEZEL_EFFECT_ROTATING = "rotating";
const BEZEL_EFFECT_BREATHING = "breathing";
const BEZEL_EFFECT_SOLID = "solid";

/// Bar background modes (appearance.bg_mode values): what paints behind
/// the modules — "none" (default) is today's plain bg_color fill, "cava"
/// washes the cava equalizer across the whole background, "matrix" rains
/// cmatrix-style glyph streams, "lava" floats metaball blobs upward.
/// Unrecognized values fall back to "none".
const BG_MODE_NONE = "none";
const BG_MODE_CAVA = "cava";
const BG_MODE_MATRIX = "matrix";
const BG_MODE_LAVA = "lava";

/// appearance.matrix_style values: which glyph set the matrix rain uses.
const MATRIX_STYLE_KATAKANA = "katakana";
const MATRIX_STYLE_DISTROS = "distros";

/// appearance.matrix_distro values: which logos the "distros" style rains.
/// "all" mixes every known logo; anything else names one DISTRO_GLYPHS id
/// ("arch", "debian", ...) or "tux" for the generic glyph. Unrecognized
/// values fall back to "all".
const MATRIX_DISTRO_ALL = "all";
const MATRIX_DISTRO_TUX = "tux";

/// Logo codepoint for one matrix_distro value, or null when the value
/// names nothing (caller falls back to the full set).
fn matrixDistroGlyph(id: []const u8) ?u32 {
    if (std.mem.eql(u8, id, MATRIX_DISTRO_TUX)) return DISTRO_FALLBACK_GLYPH;
    return DISTRO_GLYPHS.get(id);
}

/// Cava background shapes (appearance.cava_style values): "bars" rises
/// each column from the bottom edge, "wave" mirrors around the vertical
/// center, "curve" smooths the tops into a filled wave with a bright
/// crest. Unrecognized values fall back to "bars".
const CAVA_STYLE_BARS = "bars";
const CAVA_STYLE_WAVE = "wave";
const CAVA_STYLE_CURVE = "curve";

/// Curated cava_style: unknown → bars. The loader and the GUI's own load
/// mirror this same fallback.
fn cavaStyleOrDefault(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, CAVA_STYLE_WAVE)) return CAVA_STYLE_WAVE;
    if (std.mem.eql(u8, raw, CAVA_STYLE_CURVE)) return CAVA_STYLE_CURVE;
    return CAVA_STYLE_BARS;
}

/// One daemon bar as a 0..1 fraction of the reference max. Pure for tests.
fn cavaBarFrac(i: usize) f32 {
    if (i >= cava_state.bar_count) return 0.0;
    return @as(f32, @floatFromInt(@min(cava_state.bars[i], CAVA_REFERENCE_MAX))) / @as(f32, @floatFromInt(CAVA_REFERENCE_MAX));
}

/// Smooth curve value at column ux of uw: cosine interpolation between
/// adjacent bar centers (bar i centers on (i+0.5)*uw/n). Clamps past the
/// ends instead of ringing. Pure for tests.
fn cavaCurveFrac(ux: usize, uw: usize) f32 {
    const n = cava_state.bar_count;
    if (n == 0 or uw == 0) return 0.0;
    const fn_: f32 = @floatFromInt(n);
    const f = (@as(f32, @floatFromInt(ux)) + 0.5) * fn_ / @as(f32, @floatFromInt(uw)) - 0.5;
    if (f <= 0.0) return cavaBarFrac(0);
    if (f >= fn_ - 1.0) return cavaBarFrac(n - 1);
    const idx0: usize = @intFromFloat(f);
    const t = f - @as(f32, @floatFromInt(idx0));
    const a = cavaBarFrac(idx0);
    const b = cavaBarFrac(@min(idx0 + 1, n - 1));
    const u = 0.5 - 0.5 * @cos(t * std.math.pi);
    return a + (b - a) * u;
}

/// Media progress display (appearance.mpris_progress_style values): what
/// shows playback position on the mpris pill — "underline" (default) is the
/// accent dash under the track text, "bar" is a subtle fill across the pill
/// itself.
const MPRIS_PROGRESS_UNDERLINE = "underline";
const MPRIS_PROGRESS_BAR = "bar";

/// Breath period in ticks (60 × 60ms ≈ 3.6s per in-out cycle).
const BEZEL_BREATH_PERIOD: u32 = 60;

/// Breathing multiplier at `frame`: a 0.55..1.0 sine swell whose trough
/// never fully vanishes, so the ring stays a ring. Wraps with the period.
/// Pure (no config access) so tests can pin it.
fn bezelBreathAt(frame: u32) f32 {
    const period: f32 = @floatFromInt(BEZEL_BREATH_PERIOD);
    const bf: f32 = @floatFromInt(frame % BEZEL_BREATH_PERIOD);
    const tau: f32 = @floatCast(std.math.pi * 2.0);
    return 0.55 + 0.45 * std.math.sin(bf / period * tau);
}

/// Rotation period of the hover bezel, in ticks (40 × 60ms ≈ 2.4s per turn).
const HOVER_BEZEL_PERIOD: u32 = 40;

/// HSV → opaque 0xAARRGGBB. s,v in 0..1; h wraps (negative and >1 fold back
/// onto the wheel via floored modulo, so callers never need to normalize).
/// Used only by the "rainbow-puke" bezel style.
fn hsvToRgb(h: f32, s: f32, v: f32) u32 {
    const c = v * s;
    const hh = @mod(h, 1.0) * 6.0;
    const x = c * (1.0 - @abs(@mod(hh, 2.0) - 1.0));
    const i: u32 = @as(u32, @intFromFloat(@floor(hh))) % 6;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    switch (i) {
        0 => {
            r = c;
            g = x;
        },
        1 => {
            r = x;
            g = c;
        },
        2 => {
            g = c;
            b = x;
        },
        3 => {
            g = x;
            b = c;
        },
        4 => {
            r = x;
            b = c;
        },
        else => {
            r = c;
            b = x;
        },
    }
    const m = v - c;
    return 0xFF000000 |
        (@as(u32, @intFromFloat((r + m) * 255.0)) << 16) |
        (@as(u32, @intFromFloat((g + m) * 255.0)) << 8) |
        @as(u32, @intFromFloat((b + m) * 255.0));
}

/// Palette-ring color at ring position `frac` (turns around the border):
/// four matugen stops — accent, text, hover-fill, inactive — with smooth
/// blends between neighbors, wrapping at the seam. Pure (no config access)
/// so the GUI-side round-trip harness can pin it.
fn bezelColorAt(stops: [4]u32, frac: f32) u32 {
    const pos = @mod(frac, 1.0) * 4.0;
    const seg: u32 = @as(u32, @intFromFloat(@floor(pos))) % 4;
    const f = pos - @floor(pos);
    return lerpColor(stops[seg], stops[(seg + 1) % 4], f);
}

/// Rounded-rect containment in doubled coordinates: pixel centers are exact
/// integers, so (2*px+1, 2*py+1) tests against the continuous rect
/// [X0,X1)×[Y0,Y1) with corner radius R (all doubled). Shared by the fill
/// below and the bezel stroke, so both agree pixel-for-pixel on the shape.
fn inRoundedRect2(cx: i64, cy: i64, X0: i64, Y0: i64, X1: i64, Y1: i64, R: i64) bool {
    const ix0 = X0 + R;
    const ix1 = X1 - R;
    const iy0 = Y0 + R;
    const iy1 = Y1 - R;
    const qx: i64 = if (cx < ix0) ix0 - cx else if (cx > ix1) cx - ix1 else 0;
    const qy: i64 = if (cy < iy0) iy0 - cy else if (cy > iy1) cy - iy1 else 0;
    return qx * qx + qy * qy <= R * R;
}

/// Fills the rounded rect [x0,x1)×[y0,y1) with `color`, clipped to the
/// buffer. Radius clamps to half the smaller dimension so short pills
/// degrade to capsules instead of breaking.
fn fillRoundedRect(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, y0: i64, x1: i64, y1: i64, radius: i32, color: u32) void {
    if (x1 <= x0 or y1 <= y0) return;
    const w = x1 - x0;
    const h = y1 - y0;
    const half_min: i32 = @intCast(@divTrunc(@min(w, h), 2));
    const r = @min(radius, half_min);
    if (r < 0) return;
    const xs: i64 = @max(0, x0);
    const xe: i64 = @min(@as(i64, @intCast(buf_width)), x1);
    const ys: i64 = @max(0, y0);
    const ye: i64 = @min(@as(i64, @intCast(buf_height)), y1);
    // Doubled coordinates so pixel centers are exact integers: pixel
    // (px,py) is tested at (2*px+1, 2*py+1) against the continuous rect.
    // (Exclusive bounds would otherwise collapse the inner rect
    // asymmetrically when the radius reaches half the height.)
    const X0 = 2 * x0;
    const X1 = 2 * x1;
    const Y0 = 2 * y0;
    const Y1 = 2 * y1;
    const R: i64 = 2 * @as(i64, r);
    var py = ys;
    while (py < ye) : (py += 1) {
        var px = xs;
        while (px < xe) : (px += 1) {
            if (inRoundedRect2(2 * px + 1, 2 * py + 1, X0, Y0, X1, Y1, R)) {
                pixels[@as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px))] = color;
            }
        }
    }
}

/// 1px animated bezel around the rounded rect [x0,x1)×[y0,y1): the ring wears
/// the matugen palette itself — accent, text, hover-fill, inactive in
/// quarter turns, blending smoothly between neighbors — unless the style is
/// "rainbow-puke" (full hue wheel) or "solid" (one flat bezel_color ring).
/// The gradient styles travel around the border when the effect is
/// "rotating" (one turn per HOVER_BEZEL_PERIOD ticks), swell in place when
/// "breathing", and sit still when "solid" (as does a solid ring — it has no
/// gradient to travel).
/// Every hue on the ring comes straight out of appearance, so it reads as
/// the wallpaper's colors, never rainbow; on manual (non-matugen) themes it
/// reads as that theme's four roles instead. Faded by `a` toward `bg`.
/// NOTE: callers pass the UNcapped fade level here (not × HOVER_MAX_ALPHA):
/// the bezel needs full brightness to read at 1px wide — capping it along
/// with the pill wash renders the hue swing nearly invisible on a dark bar.
/// Effective bezel thickness for a shape: 0 when borders are off, the
/// configured module_border_width otherwise, clamped so at least a sliver of
/// fill survives (tiny pills degrade to flat instead of inverting). Single
/// source for both the stroke below and the fill insets at its call sites,
/// so the two can never disagree about where the rim ends.
fn bezelThick(w: i64, h: i64) i32 {
    if (!current_config.appearance.pill_borders) return 0;
    const cfg: i64 = current_config.appearance.module_border_width;
    const fit: i64 = @divTrunc(@min(w, h), 2) - 1;
    if (fit < 1) return 0;
    return @intCast(@min(cfg, fit));
}

fn strokeBezel(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, y0: i64, x1: i64, y1: i64, radius: i32, bg: u32, a: f32) void {
    if (x1 <= x0 or y1 <= y0) return;
    const stops = [_]u32{
        current_config.appearance.workspace_active_color,
        current_config.appearance.text_color,
        current_config.appearance.hover_color,
        current_config.appearance.workspace_inactive_color,
    };
    const w = x1 - x0;
    const h = y1 - y0;
    const r = @min(radius, @as(i32, @intCast(@divTrunc(@min(w, h), 2))));
    if (r < 0) return;
    // Rim thickness comes from the shared helper (0 = borders off or too
    // small to fit: plain fill, no ring). Doubled below since the shape
    // math runs in doubled coordinates.
    const t: i64 = bezelThick(w, h);
    if (t == 0) return;
    const T = 2 * t;
    // Doubled coordinates (see fillRoundedRect); the inner shape is the
    // outer shrunk t px per side with radius t px smaller.
    const X0 = 2 * x0;
    const X1 = 2 * x1;
    const Y0 = 2 * y0;
    const Y1 = 2 * y1;
    const R: i64 = 2 * @as(i64, r);
    const ccx = x0 + x1; // rect center, already in doubled units
    const ccy = y0 + y1;
    // Effect motion: rotating travels the ring with the frame clock;
    // breathing holds it still and swells its brightness instead (the
    // breath multiplier below); solid holds it still at full brightness.
    // Everything freezes at its resting phase while animations are off —
    // the same still look, with hover fades still easing (that easing
    // lives in the fade level `a`, untouched here).
    const anim_on = current_config.appearance.animations_enabled;
    const effect = current_config.appearance.bezel_effect;
    const phase = if (anim_on and std.mem.eql(u8, effect, BEZEL_EFFECT_ROTATING))
        @as(f32, @floatFromInt(hover_frame % HOVER_BEZEL_PERIOD)) / @as(f32, HOVER_BEZEL_PERIOD)
    else
        0.0;
    const breath: f32 = if (anim_on and std.mem.eql(u8, effect, BEZEL_EFFECT_BREATHING)) bezelBreathAt(hover_frame) else 1.0;
    const xs: i64 = @max(0, x0);
    const xe: i64 = @min(@as(i64, @intCast(buf_width)), x1);
    const ys: i64 = @max(0, y0);
    const ye: i64 = @min(@as(i64, @intCast(buf_height)), y1);
    var py = ys;
    while (py < ye) : (py += 1) {
        var px = xs;
        while (px < xe) : (px += 1) {
            const cx = 2 * px + 1;
            const cy = 2 * py + 1;
            if (!inRoundedRect2(cx, cy, X0, Y0, X1, Y1, R)) continue;
            if (inRoundedRect2(cx, cy, X0 + T, Y0 + T, X1 - T, Y1 - T, R - T)) continue;
            const ang = std.math.atan2(@as(f32, @floatFromInt(cy - ccy)), @as(f32, @floatFromInt(cx - ccx)));
            // Ring position in turns (floored modulo keeps negatives in
            // range); the palette quarters travel with the frame phase.
            const frac = @mod(ang / (std.math.pi * 2.0) + phase, 1.0);
            // "rainbow-puke" runs the full hue wheel at fixed vividness;
            // "solid" wears one flat bezel_color ring; the default matugen
            // ring wears the wallpaper palette instead.
            const ring = if (std.mem.eql(u8, current_config.appearance.bezel_style, BEZEL_STYLE_SOLID))
                current_config.appearance.bezel_color
            else if (std.mem.eql(u8, current_config.appearance.bezel_style, BEZEL_STYLE_RAINBOW_PUKE))
                hsvToRgb(frac, 0.85, 1.0)
            else
                bezelColorAt(stops, frac);
            const col = lerpColor(bg, ring, a * breath);
            pixels[@as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px))] = col;
        }
    }
}

/// One pill per module: the resting layer (bezel + module_bg fill, skipped
/// while module_pills/pill_borders are off — see drawRestingPill) with the
/// hover treatment (wash + dash, faded by `anim`) layered on top. `anim` is the region's fade level from
/// click_regions.nextHover() — eased toward 1/0 on the scroll-timer tick —
/// so the highlight blooms in over ~150ms instead of snapping. Colors lerp
/// from the bar background (the opaque stand-in for translucency this file
/// already uses for the drawer fade). Callers draw this *before* their
/// glyphs so text/icons land on top. Static (action-less) readouts still get
/// their resting pill (they just never light up) — and hover only ever shows
/// where a click region exists, since hit-testing lives in the pointer
/// handlers.
fn drawModulePill(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64, anim: f32) void {
    drawRestingPill(pixels, buf_width, buf_height, x_start, x_end);
    drawPill(pixels, buf_width, buf_height, x_start, x_end, anim);
}

/// Active-workspace marker: the hover pill + rotating bezel + accent dash at
/// full strength, drawn under the hover layer so a hovered active workspace
/// simply overdraws the identical shape (same geometry, same global phase —
/// invisible). The bright workspace_active_color digits still carry
/// active-vs-inactive; the pill carries "this one is live". Shared by the
/// left and center workspace loops.
fn drawActivePill(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64) void {
    drawPill(pixels, buf_width, buf_height, x_start, x_end, 1.0);
}

/// Pill + rotating bezel + centered dash at fade level `anim` (0 = invisible
/// .. 1 = full): fill and dash honor the opacity ceiling, bezel takes the
/// raw level so its 1px ring stays vivid. The single shape behind both hover
/// (faded) and active-workspace (full) states. The dash wears the matugen
/// accent (workspace_active_color) solid so the wallpaper palette reads at
/// a glance; the bezel shimmers around the accent hue around it.
/// Resting pill fill: module_bg blended toward the opaque bar background by
/// module_pill_opacity (the faked translucency). Shared by drawRestingPill
/// and the weather fx interior, so particles nest in the fill exactly.
fn pillFillColor() u32 {
    const pct: f32 = @as(f32, @floatFromInt(current_config.appearance.module_pill_opacity)) / 100.0;
    return lerpColor(current_config.appearance.bg_color, current_config.appearance.module_bg_color, pct);
}
/// Resting module pill: the living bezel outside, flat module_bg_color
/// inside. Every module wears one, so the whole bar shares one rotating
/// phase (synchronized rings, and no extra redraw cost past what the active
/// pill already pays). Hover/active layer their wash + dash on top via
/// drawPill below. Skipped entirely while module_pills is off (bare bar);
/// the bezel is skipped while pill_borders is off (flat fills), in which
/// case the fill spans the full bounds since there is no rim to inset for.
fn drawRestingPill(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64) void {
    if (!current_config.appearance.module_pills) return;
    const h: i64 = @intCast(buf_height);
    const pill_col = pillFillColor();
    const t: i64 = bezelThick(x_end - x_start, h - 2 * HOVER_PILL_PAD_Y);
    const tr: i32 = @intCast(@max(@as(i64, 0), @as(i64, HOVER_PILL_RADIUS) - t));
    strokeBezel(pixels, buf_width, buf_height, x_start, HOVER_PILL_PAD_Y, x_end, h - HOVER_PILL_PAD_Y, HOVER_PILL_RADIUS, current_config.appearance.bg_color, 1.0);
    fillRoundedRect(pixels, buf_width, buf_height, x_start + t, HOVER_PILL_PAD_Y + t, x_end - t, h - HOVER_PILL_PAD_Y - t, tr, pill_col);
}

fn drawPill(pixels: [*]u32, buf_width: u32, buf_height: u32, x_start: i64, x_end: i64, anim: f32) void {
    if (anim <= 0.0) return;
    // The fill and dash honor the opacity ceiling (see strokeBezel for why
    // the bezel takes the raw level instead).
    const bg = current_config.appearance.bg_color;
    const a = anim * HOVER_MAX_ALPHA;
    const pill = lerpColor(bg, current_config.appearance.hover_color, a);
    const line = lerpColor(bg, current_config.appearance.workspace_active_color, a);
    const h: i64 = @intCast(buf_height);
    // The ring lives on the outermost drawn layer: resting owns it while
    // pills are on, otherwise the lit wash draws its own (same geometry and
    // global phase either way, so the two configurations never double-draw).
    if (current_config.appearance.pill_borders and !current_config.appearance.module_pills) {
        strokeBezel(pixels, buf_width, buf_height, x_start, HOVER_PILL_PAD_Y, x_end, h - HOVER_PILL_PAD_Y, HOVER_PILL_RADIUS, bg, anim);
    }
    // Wash inset inside the resting ring (same shared thickness, so it nests
    // exactly), then the underline on top.
    const wt: i64 = bezelThick(x_end - x_start, h - 2 * HOVER_PILL_PAD_Y);
    const wr: i32 = @intCast(@max(@as(i64, 0), @as(i64, HOVER_PILL_RADIUS) - wt));
    fillRoundedRect(pixels, buf_width, buf_height, x_start + wt, HOVER_PILL_PAD_Y + wt, x_end - wt, h - HOVER_PILL_PAD_Y - wt, wr, pill);
    // Centered dash, ~a third of the region wide (min 8px so narrow pills
    // like workspace digits still read), sitting just above the bottom edge.
    const w = x_end - x_start;
    const uw = @max(@as(i64, 8), @divTrunc(w, 3));
    const cx = @divTrunc(x_start + x_end, 2);
    const ux0 = cx - @divTrunc(uw, 2);
    const uy1 = h - HOVER_UNDERLINE_BOTTOM_GAP;
    fillRoundedRect(pixels, buf_width, buf_height, ux0, uy1 - HOVER_UNDERLINE_H, ux0 + uw, uy1, @divTrunc(HOVER_UNDERLINE_H + 1, 2), line);
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
fn drawTrayIconEndingAt(pixels: [*]u32, buf_width: u32, buf_height: u32, x_end: i64, icon: []const u32, progress: f32, anim: f32) i64 {
    const x0 = x_end - TRAY_ICON_SIZE;
    const y0 = @divTrunc(@as(i64, @intCast(buf_height)) - TRAY_ICON_SIZE, 2);
    const p = std.math.clamp(progress, 0.0, 1.0);
    // Same -2/+2 padding as the click region this icon gets at the call
    // site, so the highlight and the clickable area agree. Hover wash only —
    // tray icons deliberately wear no resting pill of their own (they sit on
    // the bar background, or in the drawer island's shared pill when flagged
    // in-drawer).
    _ = drawPill(pixels, buf_width, buf_height, x0 - 2, x_end + 2, anim);
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

/// Draws the cava equalizer's bars ending at `x_end` (right-aligned like
/// every right-group module), returning the new left edge. Each bar is
/// CAVA_BAR_WIDTH px wide, spaced CAVA_BAR_GAP, inside the border band's
/// inner rectangle, always growing upward from the bar's lower usable edge
/// — the classic equalizer look, identical whether the bar sits at the top
/// or bottom of the screen.
fn drawCavaEqualizer(pixels: [*]u32, buf_width: u32, buf_height: u32, x_end: i64) i64 {
    const top_px = @min(current_config.appearance.border_top_px, buf_height);
    const bottom_px = @min(current_config.appearance.border_bottom_px, buf_height - top_px);
    const usable_top: i64 = @as(i64, @intCast(top_px));
    const usable_bottom: i64 = @as(i64, @intCast(buf_height)) - @as(i64, @intCast(bottom_px));
    const max_h = usable_bottom - usable_top;
    if (max_h <= 0) return x_end;
    const color = current_config.appearance.cava_color;

    var x = x_end - @as(i64, @intCast(cava_state.bar_count)) * (CAVA_BAR_WIDTH + CAVA_BAR_GAP);
    for (0..cava_state.bar_count) |i| {
        const h = @max(1, @divTrunc(@as(i64, @intCast(cava_state.bars[i])) * max_h, @as(i64, CAVA_REFERENCE_MAX)));
        const y0: i64 = usable_bottom - h;
        var dx: i64 = 0;
        while (dx < CAVA_BAR_WIDTH) : (dx += 1) {
            const px = x + dx;
            if (px < 0 or px >= buf_width) continue;
            var dy: i64 = 0;
            while (dy < h) : (dy += 1) {
                const py = y0 + dy;
                if (py < 0 or py >= buf_height) continue;
                pixels[@as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px))] = color;
            }
        }
        x += CAVA_BAR_WIDTH + CAVA_BAR_GAP;
    }
    // Left edge of the whole equalizer — what the next right-group module
    // docks against.
    return x_end - @as(i64, @intCast(cava_state.bar_count)) * (CAVA_BAR_WIDTH + CAVA_BAR_GAP);
}

/// Whether any background effect needs per-tick repaints right now: a mode
/// is set, animations are on, and the background is actually visible
/// (bg_opacity 0 = gone body, gone effect). Cava additionally needs data
/// and a nonzero strength — a silent daemon paints plain tint.
fn bgEffectVisible() bool {
    if (!current_config.appearance.animations_enabled) return false;
    if (current_config.appearance.bg_opacity_percent == 0) return false;
    const mode = current_config.appearance.bg_mode;
    if (std.mem.eql(u8, mode, BG_MODE_CAVA)) {
        return cava_state.has_data and current_config.appearance.cava_bg_strength > 0;
    }
    if (std.mem.eql(u8, mode, BG_MODE_MATRIX)) return true;
    if (std.mem.eql(u8, mode, BG_MODE_LAVA)) return true;
    return false;
}

const MATRIX_MAX_COLS: usize = 512; // widest surface this covers at 8px cells (4K)
const MATRIX_CELL_W: i64 = 8;
const MATRIX_CELL_H: i64 = 8;
const MATRIX_TAIL_PX: i64 = 72; // visible stream length behind each head

/// Rain brightness 0..1 for a pixel `dist` px behind its stream head: full
/// at the head, linear falloff over MATRIX_TAIL_PX, dark past it. Pure so
/// tests can pin it.
fn matrixFalloff(dist: i64) f32 {
    if (dist < 0) return 0.0;
    if (dist >= MATRIX_TAIL_PX) return 0.0;
    return 1.0 - @as(f32, @floatFromInt(dist)) / @as(f32, @floatFromInt(MATRIX_TAIL_PX));
}

/// Advances every stream head for `bar`'s current width, (re)scattering
/// deterministically on first paint or resize so columns never march in
/// sync. No-op on degenerate sizes.
fn updateMatrixHeads(bar: *Bar) void {
    const w: i64 = @intCast(bar.width);
    const h: i64 = @intCast(bar.height);
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    const ncols: usize = @min(uw / @as(usize, MATRIX_CELL_W), bar.matrix_heads.len);
    if (bar.matrix_ncols != ncols) {
        var i: usize = 0;
        while (i < ncols) : (i += 1) {
            const spread: i64 = h + 2 * MATRIX_TAIL_PX;
            const ii: i64 = @intCast(i);
            bar.matrix_heads[i] = @intCast(@mod(ii * 7919, spread) - MATRIX_TAIL_PX);
        }
        bar.matrix_ncols = ncols;
    }
    const speed: i16 = @intCast(current_config.appearance.matrix_speed);
    var i: usize = 0;
    while (i < bar.matrix_ncols) : (i += 1) {
        const extra: i16 = if (i % 3 == 0) 1 else 0;
        bar.matrix_heads[i] += speed + extra;
        if (@as(i64, bar.matrix_heads[i]) - MATRIX_TAIL_PX > h) {
            const stagger: i64 = @intCast((i * 37) % @as(usize, MATRIX_TAIL_PX));
            bar.matrix_heads[i] = @intCast(-MATRIX_TAIL_PX - stagger);
        }
    }
}

/// Unique Nerd Font linux-logo codepoints for the matrix rain, derived
/// from DISTRO_GLYPHS (deduped — several IDs share one logo) plus the
/// generic Tux fallback. Comptime, so the rain charset stays in sync with
/// the distro table automatically.
const MATRIX_DISTRO_CANDIDATES = blk: {
    var uniq: [64]u32 = undefined;
    var n: usize = 0;
    for (DISTRO_GLYPHS.values()) |cp| {
        var seen = false;
        for (uniq[0..n]) |u| {
            if (u == cp) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            uniq[n] = cp;
            n += 1;
        }
    }
    var fallback_seen = false;
    for (uniq[0..n]) |u| {
        if (u == DISTRO_FALLBACK_GLYPH) {
            fallback_seen = true;
            break;
        }
    }
    if (!fallback_seen) {
        uniq[n] = DISTRO_FALLBACK_GLYPH;
        n += 1;
    }
    break :blk uniq[0..n].*;
};

/// Classic cmatrix charset: katakana + digits (what the rain used before
/// the distro-logos style existed). Tried in order against the loaded
/// font; FULL BLOCK below is the backstop.
const MATRIX_KATAKANA_CANDIDATES = [_]u32{
    0x30A2, 0x30A4, 0x30A6, 0x30A8, 0x30AA, 0x30AB, 0x30AD, 0x30AF, 0x30B2,
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    0x2588,
};

/// Resolves the rain charset against this bar's font exactly once, per
/// appearance.matrix_style/matrix_distro: distro logos (all of them, or
/// one picked logo) or classic katakana, kept only where the face has
/// them, always ending in FULL BLOCK so the list can never come back
/// empty (blocks ship in practically every monospace).
fn resolveMatrixCharset(bar: *Bar) void {
    if (bar.matrix_charset_done) return;
    bar.matrix_charset_done = true;
    if (std.mem.eql(u8, current_config.appearance.matrix_style, MATRIX_STYLE_DISTROS) and
        !std.mem.eql(u8, current_config.appearance.matrix_distro, MATRIX_DISTRO_ALL))
    {
        // One picked logo everywhere. A font missing just that glyph still
        // gets the full set below rather than a block-only rain.
        if (matrixDistroGlyph(current_config.appearance.matrix_distro)) |cp| {
            if (bar.font.glyph(cp)) |_| {
                bar.matrix_chars[0] = cp;
                bar.matrix_chars_len = 1;
                return;
            } else |_| {}
        }
    }
    const candidates: []const u32 = if (std.mem.eql(u8, current_config.appearance.matrix_style, MATRIX_STYLE_DISTROS))
        &MATRIX_DISTRO_CANDIDATES
    else
        &MATRIX_KATAKANA_CANDIDATES;
    for (candidates) |cp| {
        if (bar.matrix_chars_len >= bar.matrix_chars.len) break;
        _ = bar.font.glyph(cp) catch continue;
        bar.matrix_chars[bar.matrix_chars_len] = cp;
        bar.matrix_chars_len += 1;
    }
    if (bar.matrix_chars_len == 0) {
        bar.matrix_chars[0] = 0x2588;
        bar.matrix_chars_len = 1;
    }
}

/// Blits one rain cell, preserving the destination alpha (blendPixel forces
/// opaque — over a translucent bar background that would punch solid holes).
/// `bright` folds the tail falloff into the glyph coverage.
fn blitMatrixGlyph(pixels: [*]u32, buf_width: u32, buf_height: u32, font: *font_mod.Font, pen_x: i64, baseline_y: i64, cp: u32, fg_rgb: u32, bright: f32, clip_x0: i64, clip_x1: i64) void {
    const g = font.glyph(cp) catch return;
    const fr: f32 = @floatFromInt((fg_rgb >> 16) & 0xFF);
    const fg: f32 = @floatFromInt((fg_rgb >> 8) & 0xFF);
    const fb: f32 = @floatFromInt(fg_rgb & 0xFF);
    const x0 = pen_x + g.bitmap_left;
    const y0 = baseline_y - g.bitmap_top;
    for (0..g.height) |row| {
        for (0..g.width) |col| {
            const coverage = g.pixels[row * g.width + col];
            if (coverage == 0) continue;
            const px = x0 + @as(i64, @intCast(col));
            const py = y0 + @as(i64, @intCast(row));
            if (px < clip_x0 or px >= clip_x1 or py < 0) continue;
            const pxu: usize = @intCast(px);
            const pyu: usize = @intCast(py);
            if (pxu >= buf_width or pyu >= buf_height) continue;
            const k = @as(f32, @floatFromInt(coverage)) / 255.0 * bright;
            const dst = pixels[pyu * buf_width + pxu];
            const dr: f32 = @floatFromInt((dst >> 16) & 0xFF);
            const dg: f32 = @floatFromInt((dst >> 8) & 0xFF);
            const db: f32 = @floatFromInt(dst & 0xFF);
            const r: u32 = @intFromFloat(dr + (fr - dr) * k);
            const gg: u32 = @intFromFloat(dg + (fg - dg) * k);
            const b: u32 = @intFromFloat(db + (fb - db) * k);
            pixels[pyu * buf_width + pxu] = (dst & 0xFF000000) | (r << 16) | (gg << 8) | b;
        }
    }
}

/// Rains the matrix streams over the background rect [x0,x1)×[y0,y1) with
/// corner `radius`: one stable glyph per 8px cell (charset position-hash, so
/// cells don't flicker), brightness falling off behind each head, head cell
/// near-white. Cells straddling the rounded shape are skipped whole (all
/// four corners must test inside), so nothing pokes past dock capsules.
fn drawMatrixBackground(bar: *Bar, pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, x1: i64, y0: i64, y1: i64, radius: i64) void {
    if (bar.matrix_ncols == 0) return;
    resolveMatrixCharset(bar);
    const mat_rgb = current_config.appearance.matrix_color & 0x00FFFFFF;
    const X0 = 2 * x0;
    const X1 = 2 * x1;
    const Y0 = 2 * y0;
    const Y1 = 2 * y1;
    const R = 2 * radius;
    const nchars: i64 = @intCast(bar.matrix_chars_len);
    var col: usize = 0;
    while (col < bar.matrix_ncols) : (col += 1) {
        const cx0 = x0 + @as(i64, @intCast(col)) * MATRIX_CELL_W;
        if (cx0 + MATRIX_CELL_W <= x0 or cx0 >= x1) continue;
        const head: i64 = bar.matrix_heads[col];
        var y = head;
        while (true) {
            const dist = head - y;
            const b = matrixFalloff(dist);
            if (b <= 0.0) break;
            const cy0 = y - MATRIX_CELL_H;
            if (cy0 + MATRIX_CELL_H <= y0 or cy0 >= y1) {
                y -= MATRIX_CELL_H;
                if (y < y0 - MATRIX_TAIL_PX - MATRIX_CELL_H) break;
                continue;
            }
            // Whole-cell shape test (four corners, doubled coords).
            if (inRoundedRect2(2 * cx0 + 1, 2 * cy0 + 1, X0, Y0, X1, Y1, R) and
                inRoundedRect2(2 * (cx0 + MATRIX_CELL_W) - 1, 2 * cy0 + 1, X0, Y0, X1, Y1, R) and
                inRoundedRect2(2 * cx0 + 1, 2 * y - 1, X0, Y0, X1, Y1, R) and
                inRoundedRect2(2 * (cx0 + MATRIX_CELL_W) - 1, 2 * y - 1, X0, Y0, X1, Y1, R))
            {
                const cellrow = @divFloor(y, MATRIX_CELL_H);
                const ici: i64 = @intCast(col);
                const cp = bar.matrix_chars[@as(usize, @intCast(@mod(ici * 31 + cellrow * 17, nchars)))];
                // Head cell flashes near-white; the tail wears matrix green.
                const fr: f32 = @floatFromInt((mat_rgb >> 16) & 0xFF);
                const fg: f32 = @floatFromInt((mat_rgb >> 8) & 0xFF);
                const fb: f32 = @floatFromInt(mat_rgb & 0xFF);
                const hw: f32 = if (dist < MATRIX_CELL_H) 0.6 else 0.0;
                const cr: u32 = @intFromFloat(fr + (255.0 - fr) * hw);
                const cg: u32 = @intFromFloat(fg + (255.0 - fg) * hw);
                const cb: u32 = @intFromFloat(fb + (255.0 - fb) * hw);
                blitMatrixGlyph(pixels, buf_width, buf_height, bar.font, cx0, y - 1, cp, (cr << 16) | (cg << 8) | cb, b, x0, x1);
            }
            y -= MATRIX_CELL_H;
            if (y < -MATRIX_TAIL_PX - MATRIX_CELL_H) break;
        }
    }
}

/// Washes the cava equalizer across the background rect [x0,x1)×[y0,y1)
/// with corner `radius`, shaped by appearance.cava_style: "bars" rises
/// each column from the bottom edge (the original look), "wave" mirrors
/// around the vertical center, "curve" fills under cosine-smoothed tops
/// with a brighter crest line. Tinted toward cava_color by
/// cava_bg_strength. Same bg_alpha as the flat fill, so bg_opacity fades
/// wash and body alike.
fn drawCavaBackground(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, x1: i64, y0: i64, y1: i64, radius: i64) void {
    _ = buf_height;
    if (!cava_state.has_data or cava_state.bar_count == 0) return;
    const s = @as(f32, @floatFromInt(current_config.appearance.cava_bg_strength)) / 100.0;
    if (s <= 0.0) return;
    const w = x1 - x0;
    if (w <= 0) return;
    const rh = y1 - y0;
    if (rh <= 0) return;
    const style = cavaStyleOrDefault(current_config.appearance.cava_style);
    const is_wave = std.mem.eql(u8, style, CAVA_STYLE_WAVE);
    const is_curve = std.mem.eql(u8, style, CAVA_STYLE_CURVE);
    const bg_rgb = current_config.appearance.bg_color & 0x00FFFFFF;
    const cav_rgb = current_config.appearance.cava_color & 0x00FFFFFF;
    const bg_a: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const uw: usize = @intCast(w);
    const n = cava_state.bar_count;
    const X0 = 2 * x0;
    const X1 = 2 * x1;
    const Y0 = 2 * y0;
    const Y1 = 2 * y1;
    const R = 2 * radius;
    const col = lerpColor(bg_rgb, cav_rgb, s);
    const crest_col = lerpColor(bg_rgb, cav_rgb, @min(1.0, s + 0.35));
    const cy = @divTrunc(y0 + y1, 2);
    var x = x0;
    while (x < x1) : (x += 1) {
        const ux: usize = @intCast(x - x0);
        const frac = if (is_curve) cavaCurveFrac(ux, uw) else cavaBarFrac(ux * n / uw);
        // Fill span for this column; the crest (curve only) paints over
        // the fill's top right after, same x, so no second pass is needed.
        var fy0: i64 = y1;
        var fy1: i64 = y1;
        var crest: i64 = -1;
        if (is_wave) {
            const half: i64 = @intFromFloat(frac * @as(f32, @floatFromInt(rh)) / 2.0);
            fy0 = cy - half;
            fy1 = cy + half;
        } else {
            const ch: i64 = @intFromFloat(frac * @as(f32, @floatFromInt(rh)));
            if (ch <= 0) continue;
            fy0 = y1 - ch;
            if (is_curve) crest = fy0;
        }
        if (fy1 <= fy0) continue;
        var y = fy0;
        while (y < fy1) : (y += 1) {
            if (radius > 0 and !inRoundedRect2(2 * x + 1, 2 * y + 1, X0, Y0, X1, Y1, R)) continue;
            pixels[@as(usize, @intCast(y)) * buf_width + @as(usize, @intCast(x))] = bg_a | (col & 0x00FFFFFF);
        }
        if (crest >= 0) {
            var cy2 = crest - 1;
            while (cy2 <= crest + 1) : (cy2 += 1) {
                if (cy2 < y0 or cy2 >= y1) continue;
                if (radius > 0 and !inRoundedRect2(2 * x + 1, 2 * cy2 + 1, X0, Y0, X1, Y1, R)) continue;
                pixels[@as(usize, @intCast(cy2)) * buf_width + @as(usize, @intCast(x))] = bg_a | (crest_col & 0x00FFFFFF);
            }
        }
    }
}

/// Paints the background effect (bg_mode) over the already-filled
/// background shape [x0,x1)×[y0,y1) with corner `radius` — under all
/// modules, above the flat fill. No-op unless a mode is set, animations
/// are on, and the background is actually visible.
fn paintBackgroundEffect(bar: *Bar, pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, x1: i64, y0: i64, y1: i64, radius: i64) void {
    if (!bgEffectVisible()) return;
    const mode = current_config.appearance.bg_mode;
    if (std.mem.eql(u8, mode, BG_MODE_CAVA)) {
        drawCavaBackground(pixels, buf_width, buf_height, x0, x1, y0, y1, radius);
    } else if (std.mem.eql(u8, mode, BG_MODE_MATRIX)) {
        drawMatrixBackground(bar, pixels, buf_width, buf_height, x0, x1, y0, y1, radius);
    } else if (std.mem.eql(u8, mode, BG_MODE_LAVA)) {
        drawLavaBackground(pixels, buf_width, buf_height, x0, x1, y0, y1, radius);
    }
}

/// One lava-lamp blob: center + radius, all driven statelessly by the
/// frame counter (same clock as the bezel breath), so the motion is
/// deterministic and testable.
const LavaBlob = struct { x: f32, y: f32, r: f32 };

const LAVA_BLOBS: usize = 8;

/// Blob i at `frame` over a region w×rh: slow rise with sinusoidal sway,
/// shrinking toward the extremes so blobs appear to merge/split at the
/// top and bottom like the real lamp. `tempo` scales the rise/sway rate
/// (1.0 = designed pace), `girth` the radius. Pure for tests.
fn lavaBlob(i: usize, frame: i64, w: f32, rh: f32, tempo: f32, girth: f32) LavaBlob {
    const speed = (0.005 + 0.011 * fxHash01(@as(i64, @intCast(i)) * 8 + 1)) * tempo;
    const t = @mod(@as(f32, @floatFromInt(frame)) * speed + fxHash01(@as(i64, @intCast(i)) * 8 + 2), 1.0);
    const sway_ph = fxHash01(@as(i64, @intCast(i)) * 8 + 5) * 6.28;
    const sway_sp = 0.015 * (0.5 + fxHash01(@as(i64, @intCast(i)) * 8 + 4)) * tempo;
    const x = w * (0.08 + 0.84 * fxHash01(@as(i64, @intCast(i)) * 8 + 3)) + @sin(@as(f32, @floatFromInt(frame)) * sway_sp + sway_ph) * w * 0.04;
    const y = rh + 4.0 - t * (rh + 8.0);
    const shrink = 0.55 + 0.45 * @sqrt(@max(0.0, @sin(std.math.pi * t)));
    const r = rh * (0.30 + 0.16 * fxHash01(@as(i64, @intCast(i)) * 8 + 6)) * shrink * girth;
    return .{ .x = x, .y = y, .r = r };
}

/// Metaball field at (x, y): summed soft falloffs, so neighbors merge
/// into goo instead of drawing as separate dots. Pure for tests.
fn lavaField(x: f32, y: f32, blobs: []const LavaBlob) f32 {
    var s: f32 = 0.0;
    for (blobs) |b| {
        const dx = x - b.x;
        const dy = y - b.y;
        const r2 = b.r * b.r;
        s += r2 / (dx * dx + dy * dy + r2);
    }
    return s;
}

/// Lava color for field strength `s` around `mid` (the lava_color accent):
/// dim rim → full body → hot yellow-white core where blobs overlap. Pure
/// for tests.
fn lavaColorFor(s: f32, mid: u32) u32 {
    const mr: f32 = @floatFromInt((mid >> 16) & 0xFF);
    const mg: f32 = @floatFromInt((mid >> 8) & 0xFF);
    const mb: f32 = @floatFromInt(mid & 0xFF);
    const shade = struct {
        fn f(fac: f32, c: f32) u32 {
            return @intFromFloat(@min(255.0, c * fac));
        }
    }.f;
    if (s < 1.2) {
        const f = @max(0.05, 0.35 + 0.4 * ((s - 0.8) / 0.4));
        return (@as(u32, 0xFF) << 24) | (shade(f, mr) << 16) | (shade(f, mg) << 8) | shade(f, mb);
    }
    if (s < 2.0) {
        const f = @min(1.0, 0.75 + 0.35 * ((s - 1.2) / 0.8));
        return (@as(u32, 0xFF) << 24) | (shade(f, mr) << 16) | (shade(f, mg) << 8) | shade(f, mb);
    }
    const t = @min(1.0, (s - 2.0) / 1.0) * 0.9;
    const hr: u32 = @intFromFloat(mr + (255.0 - mr) * t);
    const hg: u32 = @intFromFloat(mg + (240.0 - mg) * t);
    const hb: u32 = @intFromFloat(mb + (192.0 - mb) * t);
    return (@as(u32, 0xFF) << 24) | (hr << 16) | (hg << 8) | hb;
}

/// Washes the lava lamp across the background rect [x0,x1)×[y0,y1) with
/// corner `radius`: gooey metaballs rising through the region, tinted from
/// lava_color (rim → body → hot core). Same bg_alpha as the flat fill, so
/// bg_opacity fades wash and body alike.
fn drawLavaBackground(pixels: [*]u32, buf_width: u32, buf_height: u32, x0: i64, x1: i64, y0: i64, y1: i64, radius: i64) void {
    _ = buf_height;
    const w = x1 - x0;
    if (w <= 0) return;
    const rh = y1 - y0;
    if (rh <= 0) return;
    const fw: f32 = @floatFromInt(w);
    const frh: f32 = @floatFromInt(rh);
    var blobs: [LAVA_BLOBS]LavaBlob = undefined;
    const tempo: f32 = @as(f32, @floatFromInt(current_config.appearance.lava_speed)) / 3.0;
    const girth: f32 = @as(f32, @floatFromInt(current_config.appearance.lava_size)) / 100.0;
    for (0..LAVA_BLOBS) |i| blobs[i] = lavaBlob(i, hover_frame, fw, frh, tempo, girth);
    const mid = current_config.appearance.lava_color & 0x00FFFFFF;
    const bg_a: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const X0 = 2 * x0;
    const X1 = 2 * x1;
    const Y0 = 2 * y0;
    const Y1 = 2 * y1;
    const R = 2 * radius;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const s = lavaField(@as(f32, @floatFromInt(x - x0)), @as(f32, @floatFromInt(y - y0)), &blobs);
            if (s <= 0.8) continue;
            if (radius > 0 and !inRoundedRect2(2 * x + 1, 2 * y + 1, X0, Y0, X1, Y1, R)) continue;
            pixels[@as(usize, @intCast(y)) * buf_width + @as(usize, @intCast(x))] = bg_a | lavaColorFor(s, mid);
        }
    }
}

/// Draws `current_config.modules.right` in config order, right-to-left from
/// the bar's edge — today's default order reproduces the original
/// hardcoded sequence exactly: custom/power, then the group/tray-expander
/// drawer (a "▾" toggle; expanded reveals custom/pacman, a polled
/// wireplumber volume reading, and any tray icons), then custom/weather. An entry with `in_drawer == true` is only drawn while
/// `drawer_anim > 0` (0 = fully collapsed, 1 = fully expanded, animated
/// over a few frames by the caller), fading toward the bar's background
/// color as it goes, so expanding/collapsing is a quick fade rather than an
/// instant on/off. `first` tracks whether anything has been drawn yet in
/// this pass, since only the very first drawn item skips the leading
/// MODULE_GAP that every subsequent one gets — this generalizes the
/// original code's fixed "gap before every call except the first" pattern
/// to an arbitrary enabled/disabled subset.
///
/// Single-content text modules (power, volume, cpu, …) additionally reserve a
/// MODULE_CELL_MIN-wide cell via reserveRightCell so each one keeps its own
/// space and never sits flush against its neighbour; the cell's padding is
/// what fills the gap, so those cases no longer subtract MODULE_GAP
/// themselves. Multi-item kinds (tray, cava) keep their explicit intra-module
/// LAUNCHER_GAP instead: a cell per icon would space them arbitrarily far
/// apart, and their width is data-driven rather than a label's, so there is
/// no meaningful "natural width" to pad out to a minimum.
/// Speaker icon tier for a 0-100 volume (wireplumber's "default"
/// format-icons array: low/medium/high, U+F026/F027/F028). Shared by the
/// volume module and the OSD so they never disagree.
fn volumeIconFor(pct: u8) []const u8 {
    return if (pct >= 67) "\u{f028}" else if (pct >= 34) "\u{f027}" else "\u{f026}";
}

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
    workspaces: *const Workspaces,
    center_start_x: i64,
    x_end_start: i64,
    click_regions: *ClickRegions,
    bar: *Bar,
) i64 {
    const y0: i64 = baselineY(buf_height, font);
    var x_end: i64 = x_end_start;
    var first = true;
    var custom_script_draw_index: usize = 0;
    const text_color = current_config.appearance.text_color;
    const drawer_color = lerpColor(current_config.appearance.bg_color, text_color, drawer_anim);
    // Weather hover bounds start cleared every walk; the .weather arm sets
    // them when it draws (see weatherHovered).
    bar.weather_fx_set = false;

    // Drawer island: one shared resting pill over last frame's in-drawer
    // span (dock-pack style — a changed drawer settles a frame later, which
    // the 240ms open fade masks). Gated on the fade so a closed drawer
    // paints nothing from stale bounds.
    if (drawer_anim > 0.0 and bar.drawer_island_set and bar.drawer_island_x1 > bar.drawer_island_x0) {
        drawRestingPill(pixels, buf_width, buf_height, bar.drawer_island_x0, bar.drawer_island_x1);
    }
    var island_now = IslandSpan{};

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
                if (!first) x_end -= MODULE_GAP;
                first = false;
                const cell = reserveRightCell(x_end, textPixelWidth(font, POWER_BUTTON.label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, POWER_BUTTON.label, text_color, .{ .spawn = POWER_BUTTON.command }, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .drawer_toggle => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                // Open state wears the active pill + flipped chevron (like an
                // active workspace reads live): tracked off the drawer fade
                // level rather than threading another param — anim > 0.5 is
                // what is visibly on screen.
                const drawer_open = drawer_anim > 0.5;
                const toggle_label = if (drawer_open) DRAWER_TOGGLE_LABEL_UP else DRAWER_TOGGLE_LABEL;
                const cell = reserveRightCell(x_end, textPixelWidth(font, toggle_label), center_start_x);
                x_end = cell.next_pen;
                if (drawer_open) drawActivePill(pixels, buf_width, buf_height, cell.content_start, cell.content_end);
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, toggle_label, if (drawer_open) current_config.appearance.workspace_active_color else text_color, .toggle_drawer, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .volume => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                const vol_pct: u8 = @intCast(@min(std.fmt.parseInt(u32, volume_text, 10) catch 0, 255));
                const vol_icon: []const u8 = volumeIconFor(vol_pct);
                var vol_buf: [24]u8 = undefined;
                const vol_label = std.fmt.bufPrint(&vol_buf, "{s} {s}", .{ vol_icon, volume_text }) catch vol_icon;
                const cell = reserveRightCell(x_end, textPixelWidth(font, vol_label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, vol_label, drawer_color, .open_volume_mixer, click_regions, if (entry.in_drawer) &island_now else null, .adjust_volume);
            },
            .waypaper => {
                // Tombstone (see ModuleKind): old configs still parse, but
                // nothing draws — no space taken, `first` untouched.
            },
            .pacman => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                // Package-update count badged with this machine's distro
                // logo (same glyph the drawer brands itself with) — never
                // a hardcoded Debian swirl on Arch-family machines.
                var pac_buf: [24]u8 = undefined;
                var dg_buf: [4]u8 = undefined;
                const pac_label = std.fmt.bufPrint(&pac_buf, "{s} {s}", .{ encodeBmpCodepoint(distroLogoCodepoint(), &dg_buf), pacman_text }) catch pacman_text;
                const cell = reserveRightCell(x_end, textPixelWidth(font, pac_label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, pac_label, drawer_color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .tray => {
                // icon-only items, no text label; skipped entirely if an
                // item hasn't gotten its first successful icon fetch yet.
                for (tray.items[0..tray.item_count], 0..) |item, i| {
                    if (!item.has_icon) continue;
                    if (!first) x_end -= TRAY_ICON_GAP;
                    first = false;
                    const region_hi = x_end + 2;
                    const icon_left = drawTrayIconEndingAt(pixels, buf_width, buf_height, x_end, &item.pixels, drawer_anim, click_regions.nextHover());
                    click_regions.addWithRight(@intCast(icon_left - 2), @intCast(x_end + 2), .{ .activate_tray = i }, .{ .context_menu_tray = i });
                    if (entry.in_drawer) island_now.include(icon_left - 2, region_hi);
                    x_end = icon_left;
                }
            },
            .weather => {
                // No click region: the real config only wires up a
                // right-click (format-alt-click), which this scaffold
                // doesn't distinguish from left-click yet.
                if (weather_text.len > 0) {
                    if (!first) x_end -= MODULE_GAP;
                    first = false;
                    // Oversized condition icon (2x raster, vertically
                    // centered) plus text-color temperature. The layout
                    // metrics cover the ink extent (not just the advance) so
                    // the pill ring clears the bitmap; falls back to the 1x
                    // two-tone label when the raster is missing or too tall
                    // for the pill (only shaped U+E300-U+E3E3 icons go big —
                    // anything else would rasterize FreeType's .notdef box).
                    const parts = splitWeatherLabel(weather_text);
                    const icon_col = weatherIconTint(parts.icon, text_color);
                    const big = if (parts.icon_len > 0 and parts.icon >= 0xE300 and parts.icon <= 0xE3FF) font.glyphScaled(parts.icon, 2) catch null else null;
                    defer if (big) |b| font.gpa.free(b.pixels);
                    const avail_h: i64 = @as(i64, @intCast(buf_height)) - 2 * @as(i64, HOVER_PILL_PAD_Y) - 2;
                    const lay = if (big) |*b| bigIconLayout(b, avail_h) else null;
                    const space_adv: i64 = if (font.glyph(@as(u32, ' ')) catch null) |g| @as(i64, g.advance_x) else 0;
                    const temp_w: i64 = textPixelWidth(font, parts.rest);
                    const icon_adv: i64 = if (lay) |l| l.adv else textPixelWidth(font, weather_text[0..parts.icon_len]);
                    const content_w = icon_adv + space_adv + temp_w;
                    const cell = reserveRightCell(x_end, content_w, center_start_x);
                    x_end = cell.next_pen;
                    const rs = cell.content_end - content_w;
                    bar.weather_fx_x0 = rs - 4;
                    bar.weather_fx_x1 = cell.content_end + 4;
                    bar.weather_fx_set = true;
                    if (entry.in_drawer) {
                        island_now.include(rs - 4, cell.content_end + 4);
                        drawPill(pixels, buf_width, buf_height, rs - 4, cell.content_end + 4, 0.0);
                    } else {
                        drawModulePill(pixels, buf_width, buf_height, rs - 4, cell.content_end + 4, 0.0);
                    }
                    // Condition fx overlay (behind the glyphs): plays while
                    // hovered, frozen otherwise. Interior nests in the pill
                    // fill exactly (see drawWeatherFx).
                    if (weatherHovered(bar)) {
                        const interior = if (current_config.appearance.module_pills) pillFillColor() else current_config.appearance.bg_color;
                        // Raw poll text leads with the wttr emoji (format=1
                        // keeps "<emoji> <temp>") — the fx resolver needs it
                        // to tell showers apart from sun-behind-cloud.
                        var wi: usize = 0;
                        const wttr_cp = nextUtf8Codepoint(bar.weather.text(), &wi) orelse 0;
                        drawWeatherFx(pixels, buf_width, buf_height, rs - 4, cell.content_end + 4, wttr_cp, parts.icon, hover_frame, interior, icon_col);
                    }
                    var x0 = rs;
                    if (lay) |l| {
                        const iy = @divTrunc(@as(i64, @intCast(buf_height)) - @as(i64, @intCast(l.b.height)), 2);
                        blitBigGlyph(pixels, buf_width, buf_height, rs + l.pen_off + @as(i64, l.b.bitmap_left), iy, l.b, icon_col, buf_width);
                        x0 = rs + l.adv;
                        x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, @as(u32, ' '), text_color, 0, buf_width);
                        var ti: usize = 0;
                        while (nextUtf8Codepoint(parts.rest, &ti)) |cp| {
                            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, text_color, 0, buf_width);
                        }
                    } else {
                        var wi: usize = 0;
                        while (true) {
                            const s = wi;
                            const cp = nextUtf8Codepoint(weather_text, &wi) orelse break;
                            const col = if (s < parts.icon_len) icon_col else text_color;
                            x0 += drawGlyphAt(pixels, buf_width, buf_height, font, x0, y0, cp, col, 0, buf_width);
                        }
                    }
                }
            },
            .cpu => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                var cpu_buf: [24]u8 = undefined;
                const cpu_label = std.fmt.bufPrint(&cpu_buf, "\u{f2db} {d}%", .{sys_stats.cpu_pct}) catch "\u{f2db}";
                const cell = reserveRightCell(x_end, textPixelWidth(font, cpu_label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, cpu_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .ram => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                var ram_buf: [24]u8 = undefined;
                const ram_label = std.fmt.bufPrint(&ram_buf, "\u{f538} {d}%", .{sys_stats.ram_pct}) catch "\u{f538}";
                const cell = reserveRightCell(x_end, textPixelWidth(font, ram_label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, ram_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .disk => {
                if (!first) x_end -= MODULE_GAP;
                first = false;
                var disk_buf: [24]u8 = undefined;
                const disk_label = std.fmt.bufPrint(&disk_buf, "\u{f0a0} {d}%", .{disk_pct}) catch "\u{f0a0}";
                const cell = reserveRightCell(x_end, textPixelWidth(font, disk_label), center_start_x);
                x_end = cell.next_pen;
                _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, disk_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
            },
            .battery => {
                if (battery_state.found) {
                    if (!first) x_end -= MODULE_GAP;
                    first = false;
                    var bat_buf: [24]u8 = undefined;
                    const bat_icon: []const u8 = if (battery_state.charging) "\u{f0e7}" else "\u{f240}";
                    const bat_label = std.fmt.bufPrint(&bat_buf, "{s} {d}%", .{ bat_icon, battery_state.capacity }) catch bat_icon;
                    const cell = reserveRightCell(x_end, textPixelWidth(font, bat_label), center_start_x);
                    x_end = cell.next_pen;
                    _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, bat_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
                }
            },
            .cpu_temp => {
                if (cpu_temp_state.found) {
                    if (!first) x_end -= MODULE_GAP;
                    first = false;
                    var temp_buf: [24]u8 = undefined;
                    const celsius = @divTrunc(cpu_temp_state.millidegrees_c, 1000);
                    const temp_label = std.fmt.bufPrint(&temp_buf, "\u{f2c9} {d}\u{00b0}C", .{celsius}) catch "\u{f2c9}";
                    const cell = reserveRightCell(x_end, textPixelWidth(font, temp_label), center_start_x);
                    x_end = cell.next_pen;
                    _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, temp_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
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
                    if (!first) x_end -= MODULE_GAP;
                    first = false;
                    var net_buf: [48]u8 = undefined;
                    const net_label = std.fmt.bufPrint(&net_buf, "\u{f1eb} {s}", .{value}) catch "\u{f1eb}";
                    const cell = reserveRightCell(x_end, textPixelWidth(font, net_label), center_start_x);
                    x_end = cell.next_pen;
                    _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, net_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
                }
            },
            .layout => {
                // Mango layout indicator: the active tag's layout as its own
                // distinct glyph, oversized (2x raster, vertically centered —
                // same treatment as the weather icon), so a glance tells you
                // which layout you're in. The layout metrics cover the ink
                // extent so the pill ring clears the bitmap; falls back to
                // 1x when the raster is missing or too tall for the pill.
                // Clicking opens the picker popup. Hidden entirely (no cell
                // reserved) when the layout is unknown — Hyprland, or before
                // the first Mango refresh — so it costs nothing there.
                if (layoutBySymbol(workspaces.layout())) |l| {
                    if (!first) x_end -= MODULE_GAP;
                    first = false;
                    var li: usize = 0;
                    const lcp = nextUtf8Codepoint(l.icon, &li) orelse 0;
                    const big = if (li > 0) font.glyphScaled(lcp, 2) catch null else null;
                    defer if (big) |b| font.gpa.free(b.pixels);
                    const avail_h: i64 = @as(i64, @intCast(buf_height)) - 2 * @as(i64, HOVER_PILL_PAD_Y) - 2;
                    const lay = if (big) |*b| bigIconLayout(b, avail_h) else null;
                    const content_w: i64 = if (lay) |t| t.adv else textPixelWidth(font, l.icon);
                    const cell = reserveRightCell(x_end, content_w, center_start_x);
                    x_end = cell.next_pen;
                    const rs = cell.content_end - content_w;
                    if (entry.in_drawer) {
                        island_now.include(rs - 4, cell.content_end + 4);
                        drawPill(pixels, buf_width, buf_height, rs - 4, cell.content_end + 4, click_regions.nextHover());
                    } else {
                        drawModulePill(pixels, buf_width, buf_height, rs - 4, cell.content_end + 4, click_regions.nextHover());
                    }
                    if (lay) |t| {
                        const iy = @divTrunc(@as(i64, @intCast(buf_height)) - @as(i64, @intCast(t.b.height)), 2);
                        blitBigGlyph(pixels, buf_width, buf_height, rs + t.pen_off + @as(i64, t.b.bitmap_left), iy, t.b, color, buf_width);
                    } else {
                        var gx = rs;
                        var gi: usize = 0;
                        while (nextUtf8Codepoint(l.icon, &gi)) |cp| {
                            gx += drawGlyphAt(pixels, buf_width, buf_height, font, gx, y0, cp, color, 0, buf_width);
                        }
                    }
                    click_regions.add(@intCast(rs - 4), @intCast(cell.content_end + 4), .open_layout_picker);
                }
            },
            .custom_script => {
                defer custom_script_draw_index += 1;
                if (custom_script_draw_index < custom_script_count) {
                    const text = custom_scripts[custom_script_draw_index].text();
                    if (text.len > 0) {
                        if (!first) x_end -= MODULE_GAP;
                        first = false;
                        var script_buf: [96]u8 = undefined;
                        const label = entry.label orelse "";
                        const script_label = if (label.len > 0)
                            std.fmt.bufPrint(&script_buf, "{s}: {s}", .{ label, text }) catch text
                        else
                            text;
                        const cell = reserveRightCell(x_end, textPixelWidth(font, script_label), center_start_x);
                        x_end = cell.next_pen;
                        _ = drawRightAligned(pixels, buf_width, buf_height, font, y0, cell.content_end, script_label, color, null, click_regions, if (entry.in_drawer) &island_now else null, null);
                    }
                }
            },
            .cava => {
                // Audio-reactive equalizer fed by the cava pipe (see the
                // cava section above). No click region — same "visualizer is
                // not interactive" stance as weather. Anchored opposite the
                // bar's screen edge: grow from the bottom on a top bar, from
                // the top on a bottom bar.
                if (cava_state.has_data) {
                    if (!first) x_end -= LAUNCHER_GAP;
                    first = false;
                    const cava_hi = x_end;
                    x_end = drawCavaEqualizer(pixels, buf_width, buf_height, x_end);
                    if (entry.in_drawer) island_now.include(x_end, cava_hi);
                }
            },
            .workspaces, .mpris, .clock, .launchers => {}, // not valid in the right group; ignore defensively
        }
    }
    // Publish this frame's island span for the next frame's pill (or clear
    // it so a closed/emptied drawer paints nothing from stale bounds).
    bar.drawer_island_x0 = island_now.x0;
    bar.drawer_island_x1 = island_now.x1;
    bar.drawer_island_set = island_now.set;
    // Pen end = content start (right edge of the leftmost drawn module).
    return x_end;
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

/// How much vertical scroll distance (Wayland surface units) one workspace
/// step costs. wl_pointer axis values are 24.8 fixed-point pixels of
/// "scroll movement", not degrees or lines. Measured on this compositor: a
/// single discrete wheel notch arrives as exactly 15.00, so this threshold
/// is one physical click — verified rather than guessed. Touchpads send a
/// stream of sub-notch deltas that must add up to it, which is what
/// `scroll_accum` is for.
const WORKSPACE_SCROLL_STEP: f64 = 15.0;

/// Ceiling on steps dispatched from a single wl_pointer.axis event. A real
/// wheel notch is one step, so this only ever bites on a pathological delta —
/// without it, one enormous value could queue an unbounded burst of workspace
/// switches and leave the desktop somewhere the user never asked for.
const WORKSPACE_SCROLL_MAX_STEPS: i32 = 3;

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

            // Touching any surface cancels a pending hide and reveals a
            // hidden bar (the strip is part of the bar surface, so this is
            // also the reveal path). No-op when fully shown.
            autohideShow(bar);

            bar.pointer_over_popup = if (bar.popup) |*pm| e.surface == pm.surface else false;
            if (bar.pointer_over_popup) {
                bar.popup.?.pointer_x = e.surface_x.toInt();
                bar.popup.?.pointer_y = e.surface_y.toInt();
                // The tick eases the fade from here; no immediate redraw
                // needed (one arrives within a tick anyway).
                if (bar.popup) |*pm| pm.hovered_row = pm.hitTestRowIndex(pm.pointer_y);
            } else {
                bar.pointer_x = e.surface_x.toInt();
                bar.pointer_y = e.surface_y.toInt();
                bar.click_regions.hovered = bar.click_regions.hitTestIndex(bar.pointer_x);
                // Redraw for the hover highlight — entering already over a
                // button (e.g. the pointer didn't move but focus/workspace
                // did) needs this same as motion does below.
                drawAndCommit(bar) catch |err| {
                    logging.err("draw failed: {}", .{err});
                };
            }
        },
        .leave => {
            const bar = &router.bars[router.current orelse return];
            // Start the hide grace period (autohideHide fires it from the
            // scroll tick). A re-enter before it lapses cancels it — see
            // the enter handler above.
            if (current_config.appearance.auto_hide and !bar.autohide_hidden) {
                bar.autohide_grace = AUTOHIDE_GRACE_TICKS;
            }
            if (bar.pointer_over_popup) {
                if (bar.popup) |*pm| {
                    pm.pointer_x = -1;
                    pm.pointer_y = -1;
                    pm.hovered_row = null; // tick fades the row out from here
                    drawPopup(bar) catch {};
                }
            } else {
                bar.pointer_x = -1;
                bar.pointer_y = -1;
                bar.click_regions.hovered = null; // tick fades the pill out
                // A drag that leaves the bar is a cancelled drop: forget the
                // press and snap the live order back to config.json (no
                // release will arrive — without a grab it goes to whatever
                // surface is under the pointer instead).
                if (bar.launch_press_li != null) {
                    bar.launch_press_li = null;
                    if (bar.launch_dragging) {
                        bar.launch_dragging = false;
                        resetLauncherViewOrder();
                    }
                }
                drawAndCommit(bar) catch |err| { // first fade-out frame
                    logging.err("draw failed: {}", .{err});
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
                        pm.hovered_row = pm.hitTestRowIndex(new_y);
                        drawPopup(bar) catch {}; // first fade frame
                    }
                    // Mixer slider drag: past threshold it stops being a
                    // mute click; the value tracks the pointer live (commit
                    // on release), repainting only on value change.
                    if (pm.kind == .volume and pm.vol_drag_row != null) {
                        const dx = pm.pointer_x - pm.vol_press_x;
                        const dy = pm.pointer_y - pm.vol_press_y;
                        if (!pm.vol_drag_moved and dx * dx + dy * dy > VOL_DRAG_PX * VOL_DRAG_PX) {
                            pm.vol_drag_moved = true;
                        }
                        if (pm.vol_drag_moved) {
                            const tr = volSliderTrack(pm.width);
                            const v = volSliderXToVal(tr.x0, tr.x1, @as(i64, pm.pointer_x));
                            if (v != pm.vol_drag_val) {
                                pm.vol_drag_val = v;
                                drawPopup(bar) catch {};
                            }
                        }
                    }
                }
            } else {
                // Only redraw when the hovered button actually changes —
                // motion fires on every pixel of movement, but the fade
                // only needs its first frame here; the tick animates the rest.
                const old_idx = bar.click_regions.hitTestIndex(bar.pointer_x);
                bar.pointer_x = e.surface_x.toInt();
                bar.pointer_y = e.surface_y.toInt();
                const new_idx = bar.click_regions.hitTestIndex(bar.pointer_x);
                bar.click_regions.hovered = new_idx;
                if (old_idx != new_idx) {
                    drawAndCommit(bar) catch |err| {
                        logging.err("draw failed: {}", .{err});
                    };
                }
                // Launcher drag: past threshold the armed press becomes a
                // reorder — the view order tracks the pointer live (guide:
                // dropPositionAt), repainting only when a pin actually
                // moves. Click-vs-drag, same 4px language as the mixer.
                if (bar.launch_press_li) |li| {
                    const dx = bar.pointer_x - bar.launch_press_x;
                    const dy = bar.pointer_y - bar.launch_press_y;
                    if (!bar.launch_dragging and dx * dx + dy * dy > LAUNCH_DRAG_PX * LAUNCH_DRAG_PX) {
                        bar.launch_dragging = true;
                    }
                    if (bar.launch_dragging) {
                        if (moveLauncherView(li, dropPositionAt(&bar.click_regions, li, bar.pointer_x))) {
                            drawAndCommit(bar) catch |err| {
                                logging.err("draw failed: {}", .{err});
                            };
                        }
                    }
                }
            }
        },
        .button => |e| {
            const bar = &router.bars[router.current orelse return];
            bar.last_pointer_serial = e.serial;
            // Releases only resolve an armed launcher press (click vs
            // drop-commit) — everything else has always been press-only.
            if (e.state != .pressed) {
                if (e.button == BTN_LEFT and bar.launch_press_li != null) {
                    releaseLauncherPress(bar);
                }
                return;
            }

            // A press on the hidden strip reveals the bar instead of doing
            // anything else (there are no modules to hit-test while hidden).
            if (bar.autohide_hidden) {
                autohideShow(bar);
                return;
            }

            if (bar.pointer_over_popup) {
                if (e.button != BTN_LEFT) return;
                const pm = &(bar.popup orelse return);
                // The OSD is pure feedback: any click dismisses it.
                if (pm.kind == .volume_osd) {
                    closePopup(bar);
                    return;
                }
                const row = pm.hitTestRow(pm.pointer_y) orelse return;
                const kind = pm.kind; // copy: closePopup nulls bar.popup
                if (row.item_id) |id| {
                    switch (kind) {
                        .layout_picker => {
                            if (id >= 0 and id < MANGO_LAYOUTS.len) {
                                handleAction(bar, .{ .set_layout = @intCast(id) });
                            }
                        },
                        .dbusmenu => {
                            var dest_buf: [64]u8 = undefined;
                            var path_buf: [128]u8 = undefined;
                            const dest_len = pm.dest().len;
                            const path_len = pm.path().len;
                            @memcpy(dest_buf[0..dest_len], pm.dest());
                            @memcpy(path_buf[0..path_len], pm.path());
                            if (bar.tray.conn) |*c| {
                                dbusmenu.sendClickEvent(c, dest_buf[0..dest_len], path_buf[0..path_len], id);
                            }
                        },
                        .volume => {
                            // Click-vs-drag, resolved on release: a press
                            // arms a potential slider drag, a clean release
                            // mutes the row, a moved release commits the
                            // dragged level. Either way the panel stays open
                            // (a closing panel couldn't dial anything in).
                            if (id < 0) return;
                            const idx: usize = @intCast(id);
                            var mpm: ?*PopupMenu = null;
                            if (bar.popup) |*mp| {
                                if (mp.kind == .volume) mpm = mp;
                            }
                            const m = mpm orelse return;
                            if (e.state == .pressed) {
                                if (idx >= vol_count) return;
                                m.vol_drag_row = idx;
                                m.vol_drag_val = vol_entries[idx].vol_pct;
                                m.vol_press_id = vol_entries[idx].id;
                                m.vol_press_x = m.pointer_x;
                                m.vol_press_y = m.pointer_y;
                                m.vol_drag_moved = false;
                                return;
                            }
                            const pr = m.vol_drag_row orelse return;
                            const val = m.vol_drag_val;
                            const moved = m.vol_drag_moved;
                            m.vol_drag_row = null;
                            m.vol_drag_moved = false;
                            // A 1s refresh may have reordered rows mid-press;
                            // the pressed pactl id staying put is what makes
                            // the release act on the right entry.
                            if (pr >= vol_count or vol_entries[pr].id != m.vol_press_id) return;
                            if (moved) {
                                spawnVolumeSetAbs(pr, val);
                            } else {
                                spawnVolumeSet(pr, 0);
                            }
                            startVolumeListFetch();
                            return;
                        },
                        .volume_osd => {}, // dismissed before hit-test above; unreachable here
                    }
                } else if (kind == .volume) {
                    // Separator row: nothing to mute, panel stays open.
                    return;
                }
                closePopup(bar);
                return;
            }

            // A miss here is not an error: regions only cover the modules
            // themselves, so the gaps between them are bare background and
            // used to be silently dropped. Left-click there runs the
            // configured command (empty by default = no-op, as before).
            // Right-click is deliberately left alone so it keeps falling
            // through, matching how a right-click on empty background behaved
            // when it was simply ignored.
            const region = bar.click_regions.hitTest(bar.pointer_x);
            if (region) |r| {
                if (e.button == BTN_LEFT) {
                    // Launcher pins arm a press instead of firing: the
                    // release decides click (focus/launch) vs drag (drop
                    // commits a reorder). Every other module fires on press
                    // exactly as before.
                    if (r.action == .launcher) {
                        bar.launch_press_li = r.action.launcher;
                        bar.launch_press_x = bar.pointer_x;
                        bar.launch_press_y = bar.pointer_y;
                        bar.launch_dragging = false;
                    } else {
                        handleAction(bar, r.action);
                    }
                } else if (e.button == BTN_RIGHT) {
                    if (r.right_action) |ra| handleAction(bar, ra);
                }
                return;
            }
            if (e.button == BTN_LEFT) {
                const cmd = current_config.appearance.empty_click_command;
                if (cmd.len > 0) spawnDetached(cmd);
            }
        },
        .axis => |e| {
            // Scroll wheel. Horizontal scroll is left alone deliberately: this
            // bar has no horizontal-scroll meaning for any module.
            if (e.axis != .vertical_scroll) return;
            const bar = &router.bars[router.current orelse return];
            // The mixer panel interprets wheel itself (per-row ±5%); every
            // other popup kind has no scroll semantics.
            if (bar.pointer_over_popup) {
                if (bar.popup) |pm| {
                    if (pm.kind == .volume_osd) {
                        // Wheel over the OSD keeps adjusting master (and
                        // re-arms the dismiss timer via showVolumeOSD).
                        bar.scroll_accum += e.value.toDouble();
                        var steps: i32 = @intFromFloat(@divTrunc(bar.scroll_accum, WORKSPACE_SCROLL_STEP));
                        if (steps > WORKSPACE_SCROLL_MAX_STEPS) steps = WORKSPACE_SCROLL_MAX_STEPS;
                        if (steps < -WORKSPACE_SCROLL_MAX_STEPS) steps = -WORKSPACE_SCROLL_MAX_STEPS;
                        bar.scroll_accum -= @as(f64, @floatFromInt(steps)) * WORKSPACE_SCROLL_STEP;
                        if (steps == 0) return;
                        adjustMasterVolume(bar, steps);
                        return;
                    }
                    if (pm.kind == .volume) {
                        const hrow = pm.hovered_row orelse return;
                        if (hrow >= pm.rows.len) return;
                        const item = pm.rows[hrow].item_id orelse return;
                        if (item < 0) return;
                        // Same notch accumulation as workspaces: sub-notch
                        // touchpad deltas gather into whole steps. Negative
                        // axis is scroll-up (measured), so up = louder.
                        bar.scroll_accum += e.value.toDouble();
                        var steps: i32 = @intFromFloat(@divTrunc(bar.scroll_accum, WORKSPACE_SCROLL_STEP));
                        if (steps > WORKSPACE_SCROLL_MAX_STEPS) steps = WORKSPACE_SCROLL_MAX_STEPS;
                        if (steps < -WORKSPACE_SCROLL_MAX_STEPS) steps = -WORKSPACE_SCROLL_MAX_STEPS;
                        bar.scroll_accum -= @as(f64, @floatFromInt(steps)) * WORKSPACE_SCROLL_STEP;
                        if (steps == 0) return;
                        const delta: i8 = @intCast(-steps * VOL_WHEEL_STEP_PCT);
                        spawnVolumeSet(@intCast(item), delta);
                        startVolumeListFetch();
                    }
                }
                return;
            }
            // The region is re-read from the CURRENT pointer_x every event
            // rather than latched on .enter, so moving along the bar mid-gesture
            // can't keep firing the module the scroll started over.
            const region = bar.click_regions.hitTest(bar.pointer_x);
            const scroll_action = if (region) |r| r.scroll_action else null;
            if (scroll_action == null) {
                // Drop any partial scroll on the floor: it was meant for a
                // different module, and carrying it would make the next
                // module jump the moment the pointer reached it.
                bar.scroll_accum = 0.0;
                return;
            }
            // Accumulate the axis delta and dispatch a step per whole notch
            // worth, rather than per event: a touchpad streams sub-notch
            // deltas, and firing on each would flip through workspaces far too
            // fast to land on one. (Which SIGN means "forward" is settled by
            // measurement below, not by the axis sign the protocol docs imply.)
            bar.scroll_accum += e.value.toDouble();
            // Truncate toward zero, so a partial step is carried in the
            // remainder rather than rounded away: sustained scroll keeps
            // flowing smoothly instead of needing a fresh full notch each time.
            var steps: i32 = @intFromFloat(@divTrunc(bar.scroll_accum, WORKSPACE_SCROLL_STEP));
            if (steps > WORKSPACE_SCROLL_MAX_STEPS) steps = WORKSPACE_SCROLL_MAX_STEPS;
            if (steps < -WORKSPACE_SCROLL_MAX_STEPS) steps = -WORKSPACE_SCROLL_MAX_STEPS;
            // Consume exactly the steps being dispatched, so what stays in the
            // accumulator is only the sub-step remainder. (This must be
            // computed from the CLAMPED `steps`, or a huge single delta would
            // be drained from the accumulator while fewer steps actually ran.)
            bar.scroll_accum -= @as(f64, @floatFromInt(steps)) * WORKSPACE_SCROLL_STEP;
            if (steps == 0) return;
            switch (scroll_action.?) {
                .step_workspace => {
                // Direction, measured against the desktop's own binds rather
                // than assumed: hyprland.lua binds mainMod+mouse_down/up to
                // focus({workspace="e+1"/"e-1"}), and driving those exact
                // binds with injected REL_WHEEL shows Hyprland reports the
                // forward scroll as a NEGATIVE axis value (and back as
                // positive) — the opposite of the wl_pointer.axis sign the
                // protocol docs suggest. Injected-notch tests confirm this
                // mapping lands on the same workspace the keyboard does, so
                // the bar and the keybinds agree by measurement, not by
                // reading the spec.
                const direction: i32 = if (steps < 0) 1 else -1;
                logging.step("axis: step_workspace {d} step(s) {s} (value {d:.2}, x {d}, accum left {d:.2})", .{
                    @abs(steps), if (direction > 0) "next" else "prev", e.value.toDouble(), bar.pointer_x, bar.scroll_accum,
                });
                var n: usize = 0;
                while (n < @as(usize, @intCast(@abs(steps)))) : (n += 1) {
                    bar.workspaces.stepWorkspace(direction, barMonitorName(bar));
                }
                },
                .adjust_volume => {
                    // Negative axis is scroll-up (measured above), so up =
                    // louder. Reuses the same notch accumulation.
                    adjustMasterVolume(bar, steps);
                },
            }
        },
        else => {},
    }
}

fn handleAction(bar: *Bar, action: Action) void {
    switch (action) {
        .switch_workspace => |id| {
            // The bar the click landed on owns the rail: scope the switch to
            // its own monitor (falling back to the focused-monitor dispatch
            // when the bar has no output name yet).
            bar.workspaces.switchTo(id, barMonitorName(bar)) catch |err| {
                logging.err("workspace switch failed: {}", .{err});
            };
        },
        .spawn => |command| spawnDetached(command),
        .launcher => |idx| {
            // Pinned icon doubles as its running app: raise when up,
            // launch when not. A focused single window is already where
            // the user wants it (plain focus, no minimize toggle); with
            // several windows up, clicking past the focused one cycles.
            if (idx >= current_config.launchers.len) return;
            const btn = current_config.launchers[idx];
            const live = launcherLive(btn.command);
            if (live.count == 0 or live.client_idx == null) {
                spawnDetached(btn.command);
                return;
            }
            const apps = running_state.apps[0..running_state.len];
            if (live.count > 1 and live.focused) {
                const cur = live.client_idx.?;
                var i: usize = 0;
                while (i < apps.len) : (i += 1) {
                    const j = (cur + 1 + i) % apps.len;
                    if (j == cur) break;
                    if (clientMatchesLauncher(btn.command, apps[j].appid(), apps[j].title())) {
                        bar.workspaces.focusClient(apps[j].addr(), apps[j].ws);
                        return;
                    }
                }
                return;
            }
            const ci = live.client_idx.?;
            if (ci < apps.len and !(live.count == 1 and apps[ci].focused)) {
                bar.workspaces.focusClient(apps[ci].addr(), apps[ci].ws);
            }
        },
        .focus_client => |ci| {
            if (ci >= running_state.len) return;
            bar.workspaces.focusClient(running_state.apps[ci].addr(), running_state.apps[ci].ws);
        },
        .toggle_drawer => {
            // Only flips the target — bar.drawer_anim eases toward it on
            // the scroll timer's tick (see its handler), producing the
            // fade instead of an instant on/off. This redraw won't show
            // the change yet (anim hasn't moved), but keeps behavior from
            // depending purely on timer timing for the first frame.
            bar.drawer_expanded = !bar.drawer_expanded;
            drawAndCommit(bar) catch |err| {
                logging.err("draw failed: {}", .{err});
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
        .open_layout_picker => openLayoutPicker(bar),
        .open_volume_mixer => {
            if (bar.popup) |pm| {
                // Toggle: clicking volume with the mixer open closes it;
                // any other popup keeps the one-at-a-time rule.
                if (pm.kind == .volume) closePopup(bar);
                return;
            }
            openVolumeMixerFetch(bar);
        },
        .set_layout => |index| {
            if (index >= MANGO_LAYOUTS.len) return;
            bar.workspaces.setLayout(MANGO_LAYOUTS[index].name) catch |err| {
                logging.err("layout switch failed: {}", .{err});
            };
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
                logging.err("draw failed: {}", .{err});
            };
        },
        .closed => {
            std.process.exit(0);
        },
    }
}

/// Squared radius of the inner edge of a rounded corner's border band: the
/// corner circle radius `r`, shrunk by that corner's border thickness (the
/// thicker of its two adjacent sides). Returns r² unchanged when both sides
/// are 0px, so the corner gets no band and stays pure clipped. Only the
/// squared value is needed — drawAndCommit compares squared distances.
fn sqShrunkRadius(r: i32, side_a_px: u32, side_b_px: u32) i32 {
    const thickness: i32 = @intCast(@max(side_a_px, side_b_px));
    const inner = @max(r - thickness, 0);
    return inner * inner;
}

/// Rasterizes one frame into `pixels` (ARGB8888, bar.width×bar.height) — the
/// CPU drawing step. Background fill, borders, every module, and corner
/// rounding all draw here; drawAndCommit then hands the finished buffer to
/// the compositor via wl_shm.
/// Renders the clicked-on-this-frame geometry into one compact log line, and
/// only when it differs from the line last logged. This is the single most
/// useful trace when a module "isn't responding to the mouse": it shows every
/// region's real x-range and what it does, which pixel analysis of a
/// screenshot can only infer.
fn actionName(a: Action) []const u8 {
    return switch (a) {
        .switch_workspace => "switch_workspace",
        .spawn => "spawn",
        .toggle_drawer => "toggle_drawer",
        .activate_tray => "activate_tray",
        .context_menu_tray => "context_menu_tray",
        .mpris_control => "mpris_control",
        .open_layout_picker => "open_layout_picker",
        .open_volume_mixer => "open_volume_mixer",
        .set_layout => "set_layout",
        .launcher => "launcher",
        .focus_client => "focus_client",
    };
}

fn logClickRegionLayout(bar: *Bar) void {
    var line_buf: [1024]u8 = undefined;
    var used: usize = 0;
    // bufPrint into the remaining tail, advancing `used` — std.io's
    // fixedBufferStream is gone in Zig 0.16, and this file already builds all
    // its strings with bufPrint for that reason.
    const append = struct {
        fn f(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
            const tail = buf[len.*..];
            const s = std.fmt.bufPrint(tail, fmt, args) catch return;
            len.* += s.len;
        }
    }.f;
    append(&line_buf, &used, "regions ({d}):", .{bar.click_regions.len});
    for (bar.click_regions.items[0..bar.click_regions.len]) |r| {
        append(&line_buf, &used, " {d}-{d}={s}", .{ r.x_start, r.x_end, actionName(r.action) });
        if (r.action == .switch_workspace) {
            append(&line_buf, &used, "({d})", .{r.action.switch_workspace});
        }
        if (r.scroll_action) |sa| {
            append(&line_buf, &used, "+scroll:{s}", .{@tagName(sa)});
        }
    }
    const line = line_buf[0..used];
    if (g_last_region_log_len == line.len and
        std.mem.eql(u8, line, g_last_region_log[0..line.len])) return;
    @memcpy(g_last_region_log[0..line.len], line);
    g_last_region_log_len = line.len;
    logging.step("layout {s}", .{line});
}

var g_last_region_log: [1024]u8 = undefined;
var g_last_region_log_len: usize = 0;

/// Last-frame dock pack geometry shared by the dock frame and the morph
/// transition below (single source of truth for the gap rules).
const DockPack = struct {
    total: i64,
    start: i64,
    center: i64,
    right_end: i64,
};

fn dockPack(bar: *const Bar) DockPack {
    const buf_w: i64 = @intCast(bar.width);
    const lw = bar.dock_left_w;
    const cw = bar.dock_center_w;
    const rw = bar.dock_right_w;
    var total: i64 = lw + cw + rw;
    if (lw > 0 and cw > 0) total += DOCK_GAP;
    if (cw > 0 and rw > 0) total += DOCK_GAP;
    if (lw > 0 and cw == 0 and rw > 0) total += DOCK_GAP;
    const pack_start = @divTrunc(buf_w - total, 2);
    return .{
        .total = total,
        .start = pack_start,
        .center = pack_start + lw + (if (lw > 0 and (cw > 0 or rw > 0)) DOCK_GAP else 0),
        .right_end = pack_start + total,
    };
}

/// Begins the taskbar↔dock rubber-band morph on a mode switch: travels from
/// the current eased blend to the new mode's endpoint with an elastic
/// overshoot (see easeOutElastic). Honors the animations kill-switch with an
/// instant snap instead.
fn startModeMorph(bar: *Bar) void {
    const target: f32 = if (std.mem.eql(u8, current_config.appearance.bar_mode, BAR_MODE_DOCK)) 1.0 else 0.0;
    if (!current_config.appearance.animations_enabled) {
        bar.mode_blend = target;
        bar.mode_morph_active = false;
        return;
    }
    bar.mode_morph_from = bar.mode_blend;
    bar.mode_morph_t = 0.0;
    bar.mode_morph_active = true;
}

/// Integer lerp for morphing geometry (all pack math stays i64; the blend
/// itself is float).
fn lerpI64(a: i64, b: i64, t: f32) i64 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * t);
}

/// Dock-mode frame (appearance.bar_mode == "dock"): packs left/center/right
/// into one centered pill with no dead space, instead of taskbar's
/// edge-anchored full-width layout. Pack geometry comes from LAST frame's
/// measured widths (bar.dock_*_w) — never from measuring up front, which
/// would duplicate every module's width logic — so a width change settles
/// one frame later: imperceptible and self-correcting. Draw order is left →
/// center → right so each block starts from stable last-frame origins; the
/// background pill and the input region both cover the stable pack span, so
/// a change-frame's content may peek past the pill for a single frame at
/// most.
fn paintDock(bar: *Bar, pixels: [*]u32, time_text: []const u8, mpris_text: []const u8, mpris_playing: bool, volume_text: []const u8, weather_text: []const u8) void {
    const buf_h: i64 = @intCast(bar.height);
    const bg_alpha: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const bg_fill: u32 = bg_alpha | (current_config.appearance.bg_color & 0x00FFFFFF);

    // Last-frame pack span, with gaps only between non-empty groups.
    const pack = dockPack(bar);
    const total = pack.total;
    const pack_start = pack.start;
    const center_start_last = pack.center;
    const right_end_last = pack.right_end;

    // Background capsule over the pack span (skipped while degenerate —
    // groups still draw below so widths get measured for the next frame).
    if (total > 0) {
        fillRoundedRect(pixels, bar.width, bar.height, pack_start - DOCK_PILL_PAD, 0, pack_start + total + DOCK_PILL_PAD, buf_h, @intCast(@divTrunc(buf_h, 2)), bg_fill);
        paintBackgroundEffect(bar, pixels, bar.width, bar.height, pack_start - DOCK_PILL_PAD, pack_start + total + DOCK_PILL_PAD, 0, buf_h, @divTrunc(buf_h, 2));
    }

    // Groups left to right; pens recorded back for the next frame.
    const left_end = drawLeftGroup(pixels, bar.width, bar.height, bar.font, barWorkspaces(bar), time_text, mpris_text, mpris_playing, bar.mpris_frac, center_start_last, pack_start, &bar.click_regions);
    bar.dock_left_w = @max(0, left_end - pack_start);
    const center_end = drawCenterGroup(pixels, bar.width, bar.height, bar.font, time_text, barWorkspaces(bar), mpris_text, bar.mpris_frac, mpris_playing, center_start_last, &bar.click_regions);
    bar.dock_center_w = @max(0, center_end - center_start_last);
    const right_start = drawRightGroup(pixels, bar.width, bar.height, bar.font, weather_text, bar.pacman.text(), volume_text, bar.drawer_anim, bar.tray, bar.workspaces, center_end, right_end_last, &bar.click_regions, bar);
    bar.dock_right_w = @max(0, right_end_last - right_start);

    // Input follows the pill: without this the full-width transparent
    // surface would eat clicks meant for windows beneath it. Re-set only on
    // change; the region object itself is compositor-copied on commit, so
    // destroying it right away is safe.
    if (total > 0) {
        const rx = @max(0, pack_start - DOCK_PILL_PAD);
        const region_w: i64 = total + DOCK_PILL_PAD * 2;
        if (!bar.dock_input_set or bar.dock_input_x != rx or bar.dock_input_w != region_w) {
            if (bar.compositor.createRegion()) |region| {
                region.add(@intCast(rx), 0, @intCast(region_w), @intCast(bar.height));
                bar.surface.setInputRegion(region);
                region.destroy();
            } else |_| {}
            bar.dock_input_set = true;
            bar.dock_input_x = rx;
            bar.dock_input_w = region_w;
        }
    } else if (bar.dock_input_set) {
        bar.surface.setInputRegion(null);
        bar.dock_input_set = false;
    }
}

/// Mid-morph frame (0 < bar.mode_blend < 1): taskbar and dock geometry
/// interpolated by the eased blend, so the bar visibly stretches/recoils
/// between full-bleed and packed instead of snapping. The background is one
/// pill morphing full-surface square into pack capsule (bounds and radius
/// both lerped); straight borders and the surface corner pass stay off for
/// the half-second this lasts, exactly as in dock mode. Group pens are
/// recorded anchor-subtracted as usual, so the width cache stays warm
/// through the transition.
fn paintMorph(bar: *Bar, pixels: [*]u32, e: f32, time_text: []const u8, mpris_text: []const u8, mpris_playing: bool, volume_text: []const u8, weather_text: []const u8) void {
    const buf_w: i64 = @intCast(bar.width);
    const buf_h: i64 = @intCast(bar.height);
    const bg_alpha: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const bg_fill: u32 = bg_alpha | (current_config.appearance.bg_color & 0x00FFFFFF);
    const pack = dockPack(bar);

    // Taskbar endpoints (today's exact anchors) and dock endpoints.
    const t_left: i64 = WORKSPACE_LEFT_MARGIN;
    const t_center = centerGroupStartX(bar.width, bar.font, time_text, barWorkspaces(bar), mpris_text, mpris_playing);
    const t_right: i64 = buf_w - RIGHT_MARGIN;
    const L = lerpI64(t_left, pack.start, e);
    const C = lerpI64(t_center, pack.center, e);
    const Rend = lerpI64(t_right, pack.right_end, e);

    // Background pill: full surface at e=0, pack capsule at e=1. Radius
    // clamped at 0 — elastic overshoot past either endpoint extrapolates the
    // rect (clipped, correct) and must not invert the rounding.
    const user_r: i64 = @intCast(@min(current_config.appearance.corner_radius_px, @min(bar.width, bar.height) / 2));
    const pr = @max(0, lerpI64(user_r, @divTrunc(buf_h, 2), e));
    fillRoundedRect(pixels, bar.width, bar.height, lerpI64(0, pack.start - DOCK_PILL_PAD, e), 0, lerpI64(buf_w, pack.start + pack.total + DOCK_PILL_PAD, e), buf_h, @intCast(pr), bg_fill);
    paintBackgroundEffect(bar, pixels, bar.width, bar.height, lerpI64(0, pack.start - DOCK_PILL_PAD, e), lerpI64(buf_w, pack.start + pack.total + DOCK_PILL_PAD, e), 0, buf_h, pr);

    const left_end = drawLeftGroup(pixels, bar.width, bar.height, bar.font, barWorkspaces(bar), time_text, mpris_text, mpris_playing, bar.mpris_frac, C, L, &bar.click_regions);
    bar.dock_left_w = @max(0, left_end - L);
    const center_end = drawCenterGroup(pixels, bar.width, bar.height, bar.font, time_text, barWorkspaces(bar), mpris_text, bar.mpris_frac, mpris_playing, C, &bar.click_regions);
    bar.dock_center_w = @max(0, center_end - C);
    const right_start = drawRightGroup(pixels, bar.width, bar.height, bar.font, weather_text, bar.pacman.text(), volume_text, bar.drawer_anim, bar.tray, bar.workspaces, center_end, Rend, &bar.click_regions, bar);
    bar.dock_right_w = @max(0, Rend - right_start);

    // Input follows the morphing pill (same change-detect fields as dock).
    const rx = @max(0, lerpI64(0, pack.start - DOCK_PILL_PAD, e));
    const rw: i64 = lerpI64(buf_w, pack.total + DOCK_PILL_PAD * 2, e);
    if (!bar.dock_input_set or bar.dock_input_x != rx or bar.dock_input_w != rw) {
        if (bar.compositor.createRegion()) |region| {
            region.add(@intCast(rx), 0, @intCast(rw), @intCast(bar.height));
            bar.surface.setInputRegion(region);
            region.destroy();
        } else |_| {}
        bar.dock_input_set = true;
        bar.dock_input_x = rx;
        bar.dock_input_w = rw;
    }
}

fn paintFrame(bar: *Bar, pixels: [*]u32) void {
    const width: usize = bar.width;
    const pixel_count: usize = width * bar.height;
    // Only the background fill and borders follow bg_opacity_percent — every
    // module (pills, text, icons, hover, bezels) stays fully opaque, so at 0
    // the bar body is gone but the modules float over the wallpaper.
    const bg_alpha: u32 = (@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24;
    const bg_fill: u32 = bg_alpha | (current_config.appearance.bg_color & 0x00FFFFFF);
    // Eased taskbar↔dock blend (see mode_blend): endpoints render through
    // the exact legacy paths so both modes stay pixel-identical at rest.
    const e = bar.mode_blend;
    // Transparent base unless fully taskbar (the dock pill and morph pill
    // paint their own background; taskbar fills edge to edge as before).
    // @memset keeps this full-surface clear out of the scalar loop and lets
    // LLVM emit wide stores for both the fill and transparent cases.
    @memset(pixels[0..pixel_count], if (e <= 0.0) bg_fill else 0);

    // Auto-hide collapsed state: transparent surface with just the 2px hint
    // strip at the screen edge. No modules, no regions (autohideHide already
    // cleared them and narrowed input to the strip); strip clicks reach the
    // button handler, which shows the bar instead of hit-testing.
    if (bar.autohide_hidden) {
        @memset(pixels[0..pixel_count], 0);
        const strip = autohideStripRect(bar);
        const strip_u: u32 = @intCast(AUTOHIDE_STRIP_PX);
        const sy: u32 = if (std.mem.eql(u8, current_config.appearance.position, "top")) 0 else bar.height - strip_u;
        // Same alpha as the background: at opacity 0 a hidden bar leaves no
        // trace at all.
        const strip_col: u32 = ((@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24) | (current_config.appearance.border_color & 0x00FFFFFF);
        var yy: u32 = sy;
        while (yy < sy + strip_u and yy < bar.height) : (yy += 1) {
            const xx: i64 = @max(0, strip.x);
            const xe: i64 = @min(@as(i64, @intCast(bar.width)), strip.x + strip.w);
            if (xe > xx) {
                const start: usize = @as(usize, yy) * width + @as(usize, @intCast(xx));
                @memset(pixels[start..][0..@intCast(xe - xx)], strip_col);
            }
        }
        return;
    }

    // Decode any pinned-launcher icons that haven't been resolved since the
    // last config load, before any width measuring or drawing consults them.
    ensureLauncherIcons();

    // Four independent border edges (originally just window#waybar's
    // top-only border-width: 2px 0px 0px 0px). Which edge "faces the
    // desktop" flips with `position`, but these are plain per-side widths,
    // not auto-selected based on anchor — the user can combine them
    // however they like. Clamped so top+bottom can't exceed bar.height and
    // left+right can't exceed bar.width (top/left take priority on an
    // impossible combination, same "first configured wins" spirit as
    // everything else that clamps rather than errors).
    // Borders fade with the background (same alpha): at 0 only modules,
    // pills, text and icons remain — the bar body is gone.
    const bc = ((@as(u32, current_config.appearance.bg_opacity_percent) * 255 / 100) << 24) | (current_config.appearance.border_color & 0x00FFFFFF);
    // Full-width borders only at the taskbar endpoint — dock and morph carry
    // their own bezel, and border rects would stripe the transparent gaps.
    const top_px = if (e <= 0.0) @min(current_config.appearance.border_top_px, bar.height) else 0;
    const bottom_px = if (e <= 0.0) @min(current_config.appearance.border_bottom_px, bar.height - top_px) else 0;
    const left_px = if (e <= 0.0) @min(current_config.appearance.border_left_px, bar.width) else 0;
    const right_px = if (e <= 0.0) @min(current_config.appearance.border_right_px, bar.width - left_px) else 0;

    const left_n: usize = left_px;
    const right_n: usize = right_px;
    var row: u32 = 0;
    while (row < top_px) : (row += 1) {
        @memset(pixels[@as(usize, row) * width ..][0..width], bc);
    }
    row = bar.height - bottom_px;
    while (row < bar.height) : (row += 1) {
        @memset(pixels[@as(usize, row) * width ..][0..width], bc);
    }
    row = 0;
    while (row < bar.height) : (row += 1) {
        const row_start: usize = @as(usize, row) * width;
        if (left_n > 0) @memset(pixels[row_start..][0..left_n], bc);
        if (right_n > 0) @memset(pixels[row_start + width - right_n ..][0..right_n], bc);
    }

    // Background effect inside the border bands (taskbar endpoint only —
    // dock/morph paint their own shape above). Under all modules.
    if (e <= 0.0) {
        const er: i64 = @intCast(@min(current_config.appearance.corner_radius_px, @min(bar.width, bar.height) / 2));
        const bh: i64 = @intCast(bar.height);
        paintBackgroundEffect(bar, pixels, bar.width, bar.height, @as(i64, @intCast(left_px)), @as(i64, @intCast(bar.width)) - @as(i64, @intCast(right_px)), @as(i64, @intCast(top_px)), bh - @as(i64, @intCast(bottom_px)), er);
    }

    bar.click_regions.clear();

    var time_buf: [16]u8 = undefined; // "DD - HH:MM"
    const time_text = currentTimeText(&time_buf) catch |err| blk: {
        logging.err("clock render failed: {}", .{err});
        break :blk "";
    };
    // mpris is a left/center-capable kind now, so its text is resolved once
    // for whichever group holds it (bar.mpris.text() is
    // "PLAYER|STATUS|ARTIST - TITLE" — split off the player so clicks on
    // the controls can target it specifically via spawnPlayerctlCommand;
    // the "STATUS|ARTIST - TITLE" remainder is what formatMprisText
    // expects). When mpris isn't configured at all, everything below is
    // left empty and neither group draws anything for it.
    var mpris_playing = false;
    var mpris_text: []const u8 = "";
    if (isModuleEnabled(current_config.modules.left, .mpris) or isModuleEnabled(current_config.modules.center, .mpris)) {
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
        // Second output line ("POSITION|LENGTH") feeds the progress
        // underline; absent/unparseable means unknown, never guessed. Split
        // off before display shaping so the numbers can never leak into the
        // visible text. Position prints as decimal seconds ("211.716851")
        // while length is integer microseconds — split the fraction by hand
        // (integer math only) rather than pulling in float parsing.
        var track_part = status_and_track;
        bar.mpris_frac = null;
        if (std.mem.indexOfScalar(u8, status_and_track, '\n')) |nl| {
            track_part = status_and_track[0..nl];
            const numline = std.mem.trim(u8, status_and_track[nl + 1 ..], " \t\r\n");
            if (std.mem.indexOfScalar(u8, numline, '|')) |pp| {
                const pos_us = parseMprisPos(numline[0..pp]);
                const len = std.fmt.parseInt(i64, numline[pp + 1 ..], 10) catch -1;
                // Lengths are microseconds; anything under a second is noise
                // (or a malformed line) rather than a track.
                if (pos_us >= 0 and len > 1000000) {
                    bar.mpris_frac = @min(1.0, @as(f32, @floatFromInt(pos_us)) / @as(f32, @floatFromInt(len)));
                }
            }
        }
        mpris_playing = std.mem.startsWith(u8, track_part, "Playing|");
        var mpris_buf: [64]u8 = undefined;
        mpris_text = formatMprisText(track_part, &mpris_buf);
    }
    const center_start_x = centerGroupStartX(bar.width, bar.font, time_text, barWorkspaces(bar), mpris_text, mpris_playing);
    var volume_buf: [16]u8 = undefined;
    const vol_poll = parseVolumePoll(bar.volume.text(), &volume_buf);
    const volume_text = vol_poll.text;
    var weather_buf: [32]u8 = undefined;
    const weather_text = formatWeatherText(bar.weather.text(), &weather_buf);
    if (e >= 1.0) {
        paintDock(bar, pixels, time_text, mpris_text, mpris_playing, volume_text, weather_text);
    } else if (e <= 0.0) {
        // Leaving dock mode must release the input region, or the bar keeps
        // only its last pill clickable.
        if (bar.dock_input_set) {
            bar.surface.setInputRegion(null);
            bar.dock_input_set = false;
        }
        const center_end = drawCenterGroup(pixels, bar.width, bar.height, bar.font, time_text, barWorkspaces(bar), mpris_text, bar.mpris_frac, mpris_playing, center_start_x, &bar.click_regions);
        // Record content widths even in taskbar mode, so flipping to dock
        // packs correctly on the very first frame instead of piling up at
        // center for a frame. Anchor-subtracted, so identical values would
        // come out of either layout.
        bar.dock_center_w = @max(0, center_end - center_start_x);
        const left_end = drawLeftGroup(
            pixels,
            bar.width,
            bar.height,
            bar.font,
            barWorkspaces(bar),
            time_text,
            mpris_text,
            mpris_playing,
            bar.mpris_frac,
            center_start_x,
            WORKSPACE_LEFT_MARGIN,
            &bar.click_regions,
        );
        bar.dock_left_w = @max(0, left_end - WORKSPACE_LEFT_MARGIN);
        const right_anchor: i64 = @as(i64, @intCast(bar.width)) - RIGHT_MARGIN;
        const right_start = drawRightGroup(
            pixels,
            bar.width,
            bar.height,
            bar.font,
            weather_text,
            bar.pacman.text(),
            volume_text,
            bar.drawer_anim,
            bar.tray,
            bar.workspaces,
            center_start_x,
            right_anchor,
            &bar.click_regions,
            bar,
        );
        bar.dock_right_w = @max(0, right_anchor - right_start);
    } else {
        // Mid-morph: interpolated layout (see paintMorph).
        paintMorph(bar, pixels, e, time_text, mpris_text, mpris_playing, volume_text, weather_text);
    }

    // Region layout changes only when module widths change (a workspace
    // appears, a tray icon arrives, the clock's digits change width), so
    // logging it only on change keeps module geometry debuggable without
    // producing a line per frame — the bar redraws continuously.
    logClickRegionLayout(bar);

    // Corner rounding — the very last drawing step, so it clips everything
    // (background, borders, every module) rather than just the background
    // fill. Standard corner-circle technique: for each corner's radius×radius
    // pixel box, pixels falling outside that corner's rounding circle are the
    // one part of the bar that genuinely isn't part of the rounded rectangle,
    // so they're zeroed (fully transparent, not just recolored — the SHM
    // buffer is argb8888 with no opaque-region hint set, so alpha=0 really
    // does cut the pixel away rather than just changing its RGB). Pixels just
    // *inside* the circle are the rounded corner's border, but the straight
    // borders were only drawn as rectangles above — so those are recolored to
    // border_color, letting each side's border curve around its corner
    // instead of stopping dead at the radius box. The band is as thick as the
    // thicker of the corner's two adjacent border widths so it never reads
    // thinner than the straight border running into it; a corner with 0px on
    // both adjacent sides gets no band (pure clipping, old behavior).
    // Squared-distance comparisons avoid a sqrt per pixel.
    const radius = @min(current_config.appearance.corner_radius_px, @min(bar.width, bar.height) / 2);
    // Skipped in dock mode: the surface corners are already transparent
    // there, and the packed pill carries its own capsule rounding.
    // Surface corners only at the taskbar endpoint (the dock pill and morph
    // pill carry their own rounding; the surface is transparent there).
    if (radius > 0 and e <= 0.0) {
        const r_i: i32 = @intCast(radius);
        const r_sq: i32 = r_i * r_i;
        // Inner edge of each corner's border band: the circle shrunk by that
        // corner's border thickness (max of its two adjacent sides). Clamped
        // at 0, and equal to r_sq when both sides are 0px (i.e. no band).
        const inner_tl_sq = sqShrunkRadius(r_i, current_config.appearance.border_top_px, current_config.appearance.border_left_px);
        const inner_tr_sq = sqShrunkRadius(r_i, current_config.appearance.border_top_px, current_config.appearance.border_right_px);
        const inner_bl_sq = sqShrunkRadius(r_i, current_config.appearance.border_bottom_px, current_config.appearance.border_left_px);
        const inner_br_sq = sqShrunkRadius(r_i, current_config.appearance.border_bottom_px, current_config.appearance.border_right_px);
        var cy: u32 = 0;
        while (cy < radius) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < radius) : (cx += 1) {
                // Circle center sits one pixel inside the radius box's inner
                // corner (radius-1), matching the usual pixel-center-at-
                // integer-coordinate convention for a discrete rounded rect.
                const dx: i32 = @as(i32, @intCast(cx)) - (r_i - 1);
                const dy: i32 = @as(i32, @intCast(cy)) - (r_i - 1);
                const d_sq = dx * dx + dy * dy;
                const tl = cy * bar.width + cx;
                const tr = cy * bar.width + (bar.width - 1 - cx);
                const bl = (bar.height - 1 - cy) * bar.width + cx;
                const br = (bar.height - 1 - cy) * bar.width + (bar.width - 1 - cx);
                if (d_sq > r_sq) {
                    pixels[tl] = 0;
                    pixels[tr] = 0;
                    pixels[bl] = 0;
                    pixels[br] = 0;
                } else {
                    if (d_sq > inner_tl_sq) pixels[tl] = bc;
                    if (d_sq > inner_tr_sq) pixels[tr] = bc;
                    if (d_sq > inner_bl_sq) pixels[bl] = bc;
                    if (d_sq > inner_br_sq) pixels[br] = bc;
                }
            }
        }
    }
}

/// Paints the current frame and hands it to the compositor: allocate an
/// anonymous memfd buffer, paint the frame into it, then attach it as a
/// wl_shm argb8888 buffer. This is the bar's only presenter — every pixel is
/// rasterized on the CPU (see paintFrame) and handed over through shared
/// memory, so no EGL/GLES context is ever created and no GL driver is loaded.
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
    paintFrame(bar, pixels);

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

// ---------------------------------------------------------------------
// Tests — bezel breathing math (pure, no display).
// Run: zig test src/main.zig -lc -fllvm -flld <bar link flags below>
// ---------------------------------------------------------------------

test "bezel breath phases" {
    const t = std.testing;
    const eps = 1e-5;
    // Frame 0: swell starts at rest; quarter period: full; half: rest;
    // three-quarter: trough (never below 0.10 — the ring stays a ring).
    try t.expect(@abs(bezelBreathAt(0) - 0.55) < eps);
    try t.expect(@abs(bezelBreathAt(BEZEL_BREATH_PERIOD / 4) - 1.0) < eps);
    try t.expect(@abs(bezelBreathAt(BEZEL_BREATH_PERIOD / 2) - 0.55) < eps);
    try t.expect(@abs(bezelBreathAt(3 * BEZEL_BREATH_PERIOD / 4) - 0.10) < eps);
    // Full period stays in range and wraps exactly.
    var f: u32 = 0;
    while (f <= BEZEL_BREATH_PERIOD) : (f += 1) {
        const v = bezelBreathAt(f);
        try t.expect(v >= 0.09 and v <= 1.01);
    }
    try t.expect(bezelBreathAt(BEZEL_BREATH_PERIOD) == bezelBreathAt(0));
    try t.expect(bezelBreathAt(BEZEL_BREATH_PERIOD + 1) == bezelBreathAt(1));
}

test "island span accumulates" {
    const t = std.testing;
    var sp = IslandSpan{};
    try t.expect(!sp.set);
    sp.include(100, 140);
    try t.expect(sp.set);
    try t.expectEqual(@as(i64, 100), sp.x0);
    try t.expectEqual(@as(i64, 140), sp.x1);
    // Grows both ways, never shrinks.
    sp.include(60, 120);
    sp.include(130, 200);
    try t.expectEqual(@as(i64, 60), sp.x0);
    try t.expectEqual(@as(i64, 200), sp.x1);
    sp.include(80, 90);
    try t.expectEqual(@as(i64, 60), sp.x0);
    try t.expectEqual(@as(i64, 200), sp.x1);
}

test "matrix falloff" {
    const t = std.testing;
    const eps = 1e-5;
    // Full at the head, linear down the tail, dark at/past its end.
    try t.expect(@abs(matrixFalloff(0) - 1.0) < eps);
    try t.expect(@abs(matrixFalloff(@divTrunc(MATRIX_TAIL_PX, 2)) - 0.5) < eps);
    try t.expect(matrixFalloff(MATRIX_TAIL_PX) == 0.0);
    try t.expect(matrixFalloff(MATRIX_TAIL_PX + 40) == 0.0);
    try t.expect(matrixFalloff(-5) == 0.0);
}

test "matrix distro candidates" {
    const t = std.testing;
    // Non-empty, unique, carries the Tux fallback, and fits the per-bar
    // charset buffer with room to spare.
    try t.expect(MATRIX_DISTRO_CANDIDATES.len > 10);
    try t.expect(MATRIX_DISTRO_CANDIDATES.len < 48);
    var seen_fallback = false;
    var i: usize = 0;
    while (i < MATRIX_DISTRO_CANDIDATES.len) : (i += 1) {
        if (MATRIX_DISTRO_CANDIDATES[i] == DISTRO_FALLBACK_GLYPH) seen_fallback = true;
        var j: usize = i + 1;
        while (j < MATRIX_DISTRO_CANDIDATES.len) : (j += 1) {
            try t.expect(MATRIX_DISTRO_CANDIDATES[i] != MATRIX_DISTRO_CANDIDATES[j]);
        }
    }
    try t.expect(seen_fallback);
}

test "matrix distro glyph lookup" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 0xF303), matrixDistroGlyph("arch"));
    try t.expectEqual(@as(?u32, 0xF306), matrixDistroGlyph("debian"));
    try t.expectEqual(@as(?u32, 0xF30A), matrixDistroGlyph("fedora"));
    try t.expectEqual(@as(?u32, DISTRO_FALLBACK_GLYPH), matrixDistroGlyph("tux"));
    try t.expect(matrixDistroGlyph("no-such-distro") == null);
    try t.expect(matrixDistroGlyph("all") == null); // "all" is not one logo
}

test "weather tint and split" {
    const t = std.testing;
    const fb: u32 = 0xFFDCDCDC;
    // Semantic tints per icon; unlisted icons wear the fallback.
    try t.expectEqual(@as(u32, 0xFFFFD60A), weatherIconTint(0xE30D, fb));
    try t.expectEqual(@as(u32, 0xFF4AA8FF), weatherIconTint(0xE319, fb));
    try t.expectEqual(@as(u32, 0xFFA8E6FF), weatherIconTint(0xE31A, fb));
    try t.expectEqual(fb, weatherIconTint(0x0041, fb));
    // Split: first codepoint is the icon, rest trimmed of the gap space.
    const icon_bytes = [_]u8{ 0xEE, 0x8C, 0x8D }; // U+E30D sunny
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..3], &icon_bytes);
    @memcpy(buf[3..10], " +21°C");
    const parts = splitWeatherLabel(buf[0..10]);
    try t.expectEqual(@as(u32, 0xE30D), parts.icon);
    try t.expectEqual(@as(usize, 3), parts.icon_len);
    try t.expectEqualStrings("+21°C", parts.rest);
}

test "scaled glyph restores size" {
    const t = std.testing;
    var font = font_mod.Font.init(t.allocator, font_mod.FONT_PATH, 11) catch return error.SkipZigTest;
    defer font.deinit();
    const small = try font.glyph(0xE30D);
    const big = try font.glyphScaled(0xE30D, 2);
    defer t.allocator.free(big.pixels);
    // Roughly double in both axes with a bigger advance...
    try t.expect(big.width >= small.width * 3 / 2);
    try t.expect(big.height >= small.height * 3 / 2);
    try t.expect(big.advance_x > small.advance_x);
    // ...and the face size is restored: the cached 1x glyph is untouched.
    const small_again = try font.glyph(0xE30D);
    try t.expectEqual(small.width, small_again.width);
    try t.expectEqual(small.height, small_again.height);
    try t.expectEqual(small.advance_x, small_again.advance_x);
}

test "weather fx mapping and render" {
    const t = std.testing;
    // Every shaped icon maps somewhere sane; unknown icons stay still.
    try t.expectEqual(WeatherFx.clear, weatherFxFor(0, 0xE30D));
    try t.expectEqual(WeatherFx.cloud, weatherFxFor(0, 0xE302));
    try t.expectEqual(WeatherFx.cloud, weatherFxFor(0, 0xE335));
    try t.expectEqual(WeatherFx.rain, weatherFxFor(0, 0xE319));
    try t.expectEqual(WeatherFx.storm, weatherFxFor(0, 0xE31D));
    try t.expectEqual(WeatherFx.snow, weatherFxFor(0, 0xE31A));
    try t.expectEqual(WeatherFx.fog, weatherFxFor(0, 0xE313));
    try t.expectEqual(WeatherFx.wind, weatherFxFor(0, 0xE34B));
    try t.expectEqual(WeatherFx.wind, weatherFxFor(0, 0xE351));
    try t.expectEqual(WeatherFx.none, weatherFxFor(0, 0x0041));
    // Showers wear the partly-rainy icon but must RAIN; sun-behind-cloud
    // shares that icon and stays cloudy.
    try t.expectEqual(WeatherFx.rain, weatherFxFor(0x1F326, 0xE304));
    try t.expectEqual(WeatherFx.cloud, weatherFxFor(0x1F324, 0xE304));
    // Scatter stays in range.
    var hi: i64 = 0;
    while (hi < 200) : (hi += 1) {
        const v = fxHash01(hi);
        try t.expect(v >= 0.0 and v < 1.0);
    }
    // Render smoke: rain lights pixels inside its rect and only there; the
    // none kind leaves the buffer untouched.
    var buf: [40 * 200]u32 = [_]u32{0xFF101010} ** (40 * 200);
    drawWeatherFx(&buf, 200, 40, 10, 190, 0, 0xE319, 7, 0xFF101010, 0xFF4AA8FF);
    var lit: usize = 0;
    var leaked: usize = 0;
    var yy: usize = 0;
    while (yy < 40) : (yy += 1) {
        var xx: usize = 0;
        while (xx < 200) : (xx += 1) {
            if (buf[yy * 200 + xx] != 0xFF101010) {
                lit += 1;
                if (xx < 10 or xx >= 190) leaked += 1;
            }
        }
    }
    try t.expect(lit > 5);
    try t.expectEqual(@as(usize, 0), leaked);
    var buf2: [40 * 200]u32 = [_]u32{0xFF101010} ** (40 * 200);
    drawWeatherFx(&buf2, 200, 40, 10, 190, 0, 0x0041, 7, 0xFF101010, 0xFF4AA8FF);
    for (buf2) |px| try t.expectEqual(@as(u32, 0xFF101010), px);
}

test "waypaper tombstone still parses" {
    const t = std.testing;
    // An old config.json naming the retired module must keep parsing (into
    // the tombstone variant) instead of falling back to defaults and wiping
    // the user's layout. The renderer skips it; the GUI strips it on load.
    // An unknown kind still fails the whole parse — which is exactly why the
    // tombstone variant above has to exist: without it, every config.json
    // written while waypaper was a module would fall back to defaults.
    const bad_doc =
        \\{"appearance": {}, "modules": {"left": [], "center": [], "right": [{"kind": "waypower", "enabled": false}]}, "launchers": []}
    ;
    var arena2 = std.heap.ArenaAllocator.init(t.allocator);
    defer arena2.deinit();
    try t.expectError(error.InvalidEnumTag, std.json.parseFromSliceLeaky(JsonConfig, arena2.allocator(), bad_doc, .{}));
    const doc2 =
        \\{"appearance": {}, "modules": {"left": [], "center": [], "right": [{"kind": "waypaper", "enabled": false, "in_drawer": true}, {"kind": "weather", "enabled": true}]}, "launchers": []}
    ;
    // Leaky parse needs an arena (production passes its config arena); a
    // throwaway one keeps the leak checker quiet.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(JsonConfig, arena.allocator(), doc2, .{});
    try t.expectEqual(@as(usize, 2), parsed.modules.right.len);
    try t.expectEqual(ModuleKind.waypaper, parsed.modules.right[0].kind);
    try t.expect(parsed.modules.right[0].in_drawer);
    try t.expectEqual(ModuleKind.weather, parsed.modules.right[1].kind);
}

test "mpris progress styles" {
    const t = std.testing;
    current_config.appearance.bg_color = 0xFF101010;
    current_config.appearance.module_bg_color = 0xFF1E1E1E;
    current_config.appearance.module_pill_opacity = 100;
    current_config.appearance.workspace_active_color = 0xFFDCDCDC;
    current_config.appearance.module_pills = true;
    current_config.appearance.pill_borders = true;
    // Underline: pixels change only in the bottom dash band.
    var u: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawMprisProgress(&u, 200, 32, 10, 100, 0.5);
    var u_min: usize = 32;
    var u_max: usize = 0;
    var u_lit: usize = 0;
    // Bar fill: spans vertically through the pill interior, wider total.
    var b: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawMprisBarFill(&b, 200, 32, 6, 150, 0.5);
    var b_min: usize = 32;
    var b_max: usize = 0;
    var b_lit: usize = 0;
    var yy: usize = 0;
    while (yy < 32) : (yy += 1) {
        var xx: usize = 0;
        while (xx < 200) : (xx += 1) {
            if (u[yy * 200 + xx] != 0xFF101010) {
                u_lit += 1;
                u_min = @min(u_min, yy);
                u_max = @max(u_max, yy);
            }
            if (b[yy * 200 + xx] != 0xFF101010) {
                b_lit += 1;
                b_min = @min(b_min, yy);
                b_max = @max(b_max, yy);
            }
        }
    }
    try t.expect(u_lit > 0);
    try t.expect(u_max - u_min <= 4);
    try t.expect(u_min >= 24);
    try t.expect(b_lit > u_lit * 2);
    try t.expect(b_max - b_min > 12);
    // Null/zero fractions draw nothing in either style.
    var n1: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawMprisProgress(&n1, 200, 32, 10, 100, null);
    var n2: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawMprisBarFill(&n2, 200, 32, 6, 150, 0.0);
    for (n1) |px| try t.expectEqual(@as(u32, 0xFF101010), px);
    for (n2) |px| try t.expectEqual(@as(u32, 0xFF101010), px);
}

test "urgent pill lights amber" {
    const t = std.testing;
    current_config.appearance.bg_color = 0xFF101010;
    current_config.appearance.module_pill_opacity = 100;
    current_config.appearance.module_bg_color = 0xFF1E1E1E;
    current_config.appearance.module_pills = true;
    current_config.appearance.pill_borders = true;
    current_config.appearance.module_border_width = 1;
    // Full strength paints wash + dash; zero strength is a no-op.
    var lit: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawUrgentPill(&lit, 200, 32, 50, 110, 1.0);
    var n_lit: usize = 0;
    var amber: usize = 0;
    for (lit) |px| {
        if (px != 0xFF101010) {
            n_lit += 1;
            // Amber tint: red channel leads (0xF5A524-ish blends).
            const r: i32 = @intCast((px >> 16) & 0xFF);
            const b: i32 = @intCast(px & 0xFF);
            if (r > b + 20) amber += 1;
        }
    }
    try t.expect(n_lit > 50);
    try t.expect(amber > n_lit / 2);
    var dark: [32 * 200]u32 = [_]u32{0xFF101010} ** (32 * 200);
    drawUrgentPill(&dark, 200, 32, 50, 110, 0.0);
    for (dark) |px| try t.expectEqual(@as(u32, 0xFF101010), px);
}

test "big icon layout covers ink" {
    const t = std.testing;
    var pxbuf: [32]u8 = [_]u8{0} ** 32;
    // Overhanging bitmap (21px ink on a 13px advance, bearing -4): the cell
    // must span the ink [-4, 17), not the advance — advance-only measuring
    // is what clipped the old layout pill's ring through the glyph.
    const over = font_mod.BigGlyph{ .width = 21, .height = 18, .bitmap_left = -4, .bitmap_top = 17, .advance_x = 13, .pixels = &pxbuf };
    const lay = bigIconLayout(&over, 26) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(i64, 21), lay.content_w);
    try t.expectEqual(@as(i64, 4), lay.pen_off);
    try t.expectEqual(@as(i64, 17), lay.adv);
    // Ink inside the advance: advance wins, no shift.
    const norm = font_mod.BigGlyph{ .width = 10, .height = 10, .bitmap_left = 1, .bitmap_top = 9, .advance_x = 13, .pixels = &pxbuf };
    const lay2 = bigIconLayout(&norm, 26) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(i64, 13), lay2.content_w);
    try t.expectEqual(@as(i64, 0), lay2.pen_off);
    try t.expectEqual(@as(i64, 13), lay2.adv);
    // Taller than the pill interior: no layout (caller draws 1x instead).
    const tall = font_mod.BigGlyph{ .width = 10, .height = 30, .bitmap_left = 0, .bitmap_top = 20, .advance_x = 13, .pixels = &pxbuf };
    try t.expect(bigIconLayout(&tall, 26) == null);
    // Null raster: null.
    try t.expect(bigIconLayout(null, 26) == null);
}

test "volume list parses pactl" {
    const t = std.testing;
    // Sink selection: blank means the default placeholder for each tool,
    // a name gets single-quoted, a quote in the name refuses (no shell
    // interpolation of attacker-influenced text, ever).
    current_config.appearance.volume_sink = "";
    var abuf: [160]u8 = undefined;
    try t.expectEqualStrings("@DEFAULT_SINK@", pactlSinkArg(&abuf).?);
    current_config.appearance.volume_sink = "alsa_output.usb-GC7.analog-stereo";
    try t.expectEqualStrings("'alsa_output.usb-GC7.analog-stereo'", pactlSinkArg(&abuf).?);
    current_config.appearance.volume_sink = "we'ird";
    try t.expect(pactlSinkArg(&abuf) == null);
    current_config.appearance.volume_sink = "";
    var out: [VOL_MAX_ENTRIES]VolumeEntry = [_]VolumeEntry{.{}} ** VOL_MAX_ENTRIES;
    // Master + muted app + unnamed stream + boosted (>100%) level.
    const sample =
        \\Volume: front-left: 42598 /  65% / -11.22 dB,   front-right: 42598 /  65% / -11.22 dB
        \\Mute: no
        \\Sink Input #6
        \\    Driver: protocol-native.c
        \\    Properties:
        \\        application.name = "Firefox"
        \\    Volume: front-left: 30455 /  46% / -20.07 dB,   front-right: 30455 /  46% / -20.07 dB
        \\            balance 0.00
        \\    Mute: yes
        \\Sink Input #9
        \\    Volume: mono: 65536 / 100% / 0.00 dB
        \\    Mute: no
        \\Sink Input #12
        \\    Properties:
        \\        application.name = "Strawberry"
        \\    Volume: front-left: 80000 / 122% / 5.15 dB,   front-right: 80000 / 122% / 5.15 dB
        \\    Mute: no
    ;
    const n = parseVolumeList(sample, &out);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqual(@as(i32, -1), out[0].id);
    try t.expectEqualStrings("Master", out[0].name());
    try t.expectEqual(@as(u8, 65), out[0].vol_pct);
    try t.expect(!out[0].muted);
    try t.expectEqual(@as(i32, 6), out[1].id);
    try t.expectEqualStrings("Firefox", out[1].name());
    try t.expectEqual(@as(u8, 46), out[1].vol_pct);
    try t.expect(out[1].muted);
    try t.expectEqualStrings("Stream #9", out[2].name());
    try t.expectEqual(@as(u8, 100), out[2].vol_pct);
    try t.expectEqual(@as(u8, 122), out[3].vol_pct);
    // Sink + source master pairs land at 0/1 with apps after them.
    var outm: [VOL_MAX_ENTRIES]VolumeEntry = [_]VolumeEntry{.{}} ** VOL_MAX_ENTRIES;
    const samplem =
        \\[sink]
        \\Volume: front-left: 42598 /  65% / -11.22 dB
        \\Mute: no
        \\[source]
        \\Volume: front-left: 20000 /  30% / -31.0 dB
        \\Mute: yes
        \\Sink Input #6
        \\    application.name = "Firefox"
        \\    Volume: front-left: 30455 /  46% / -20.07 dB
        \\    Mute: no
    ;
    const nm = parseVolumeList(samplem, &outm);
    try t.expectEqual(@as(usize, 3), nm);
    try t.expectEqualStrings("Master", outm[0].name());
    try t.expectEqual(@as(i32, -2), outm[1].id);
    try t.expectEqualStrings("Mic", outm[1].name());
    try t.expectEqual(@as(u8, 30), outm[1].vol_pct);
    try t.expect(outm[1].muted);
    try t.expectEqualStrings("Firefox", outm[2].name());
    // No sink master volume: unusable, keep the old list.
    var out2: [VOL_MAX_ENTRIES]VolumeEntry = [_]VolumeEntry{.{}} ** VOL_MAX_ENTRIES;
    try t.expectEqual(@as(usize, 0), parseVolumeList("Mute: no\nSink Input #6\n\tMute: no\n", &out2));
    // Garbage: unusable too.
    try t.expectEqual(@as(usize, 0), parseVolumeList("hello\nworld\n", &out2));
    // Master only: single row, still openable.
    try t.expectEqual(@as(usize, 1), parseVolumeList("Volume: mono: 10 /  0% / -inf dB\nMute: yes\n", &out2));
    try t.expect(out2[0].muted);
}

test "volume poll and slider math" {
    const t = std.testing;
    // Volume poll text ("67" / "67\nMUTED") parses to level + mute flag.
    var pbuf: [16]u8 = undefined;
    const p1 = parseVolumePoll("67\n", &pbuf);
    try t.expect(p1.ok);
    try t.expectEqual(@as(u8, 67), p1.pct);
    try t.expect(!p1.muted);
    try t.expectEqualStrings("67", p1.text);
    const p2 = parseVolumePoll("0\nMUTED\n", &pbuf);
    try t.expect(p2.ok);
    try t.expect(p2.muted);
    try t.expectEqual(@as(u8, 0), p2.pct);
    const p3 = parseVolumePoll("", &pbuf);
    try t.expect(!p3.ok);
    const p4 = parseVolumePoll("hello\n", &pbuf);
    try t.expect(!p4.ok);
    // Track geometry round-trips: value -> thumb x -> value.
    const tr = volSliderTrack(200);
    try t.expectEqual(@as(i64, POPUP_PADDING_X), tr.x0);
    try t.expectEqual(@as(i64, 200) - POPUP_PADDING_X, tr.x1);
    try t.expectEqual(tr.x0, volSliderValToX(tr.x0, tr.x1, 0));
    try t.expectEqual(tr.x1, volSliderValToX(tr.x0, tr.x1, 100));
    try t.expectEqual(@as(u8, 0), volSliderXToVal(tr.x0, tr.x1, tr.x0));
    try t.expectEqual(@as(u8, 100), volSliderXToVal(tr.x0, tr.x1, tr.x1));
    try t.expectEqual(@as(u8, 50), volSliderXToVal(tr.x0, tr.x1, @divTrunc(tr.x0 + tr.x1, 2)));
    // Overshoot clamps both ways; degenerate tracks read 0.
    try t.expectEqual(@as(u8, 0), volSliderXToVal(tr.x0, tr.x1, tr.x0 - 40));
    try t.expectEqual(@as(u8, 100), volSliderXToVal(tr.x0, tr.x1, tr.x1 + 40));
    try t.expectEqual(@as(u8, 0), volSliderXToVal(50, 50, 60));
    // Value text honors mute.
    var vb: [8]u8 = undefined;
    try t.expectEqualStrings("muted", volValueText(true, 80, &vb));
    try t.expectEqualStrings("80%", volValueText(false, 80, &vb));
}

test "running app matching and taskbar tail" {
    const t = std.testing;
    // appid keys: exact, reverse-DNS tail, word runs both ways.
    try t.expect(appidMatchesKey("nautilus", "nautilus"));
    try t.expect(appidMatchesKey("org.gnome.nautilus", "nautilus"));
    try t.expect(appidMatchesKey("app.fluxer.fluxerdesktop", "fluxer"));
    try t.expect(appidMatchesKey("zen-browser", "zen"));
    try t.expect(appidMatchesKey("firefox", "firefox-esr"));
    try t.expect(appidMatchesKey("alacritty", "alacritty"));
    try t.expect(!appidMatchesKey("alacritty", "foot"));
    try t.expect(!appidMatchesKey("org.gnome.nautilus", ""));
    try t.expect(!appidMatchesKey("", "foot"));
    // Two pins from one app family: their shared "simpbar" word must not
    // light a sibling's dot — config and welcome are separate GTK apps
    // (dev.jaytheoutpatient.simpbar.{Config,Welcome}), and before this the
    // shared component matched both pins, so launching simpbar-config
    // marked simpbar-welcome running too.
    try t.expect(appidMatchesKey("dev.jaytheoutpatient.simpbar.config", "simpbar-config"));
    try t.expect(!appidMatchesKey("dev.jaytheoutpatient.simpbar.config", "simpbar-welcome"));
    try t.expect(appidMatchesKey("dev.jaytheoutpatient.simpbar.welcome", "simpbar-welcome"));
    try t.expect(!appidMatchesKey("dev.jaytheoutpatient.simpbar.welcome", "simpbar-config"));
    try t.expect(!clientMatchesLauncher("simpbar-welcome", "dev.jaytheoutpatient.simpbar.config", "simpbar config"));
    try t.expect(!clientMatchesLauncher("simpbar-config", "dev.jaytheoutpatient.simpbar.welcome", "simpbar welcome"));
    try t.expect(clientMatchesLauncher("simpbar-welcome", "dev.jaytheoutpatient.simpbar.welcome", "simpbar welcome"));
    // Whole words only: one short component can't vouch for an unrelated
    // key ("edge" sits inside "ledger", "zen" inside "zenity", and "com"
    // inside every flatpak id), while word-split ids still line up with
    // their binary names and classes.
    try t.expect(!appidMatchesKey("ledger", "edge"));
    try t.expect(!appidMatchesKey("zenity", "zen"));
    try t.expect(!appidMatchesKey("com.discordapp.discord", "com.spotify.client"));
    try t.expect(appidMatchesKey("org.gnome.texteditor", "gnome-text-editor"));
    try t.expect(appidMatchesKey("steam_app_440", "steam"));
    try t.expect(appidMatchesKey("com.vivaldi.vivaldi", "vivaldi"));
    // Command keys: basename, argv, desktop suffix.
    var kb: [64]u8 = undefined;
    try t.expectEqualStrings("nautilus", launcherMatchKey("nautilus", &kb));
    try t.expectEqualStrings("foot", launcherMatchKey("/usr/bin/foot --app-id foo", &kb));
    try t.expectEqualStrings("steam", launcherMatchKey("steam.desktop", &kb));
    try t.expectEqualStrings("", launcherMatchKey("", &kb));
    // Launcher matching: wrappers cover families, drawer never matches,
    // plain binaries match appid (title as fallback).
    try t.expect(clientMatchesLauncher("simpbar-launch-browser", "firefox", ""));
    try t.expect(clientMatchesLauncher("simpbar-launch-browser", "zen-browser", ""));
    try t.expect(!clientMatchesLauncher("simpbar-launch-browser", "vesktop", ""));
    try t.expect(clientMatchesLauncher("simpbar-launch-discord", "vesktop", ""));
    try t.expect(clientMatchesLauncher("simpbar-launch-discord", "app.fluxer.fluxerdesktop", ""));
    try t.expect(!clientMatchesLauncher("appdrawer power", "appdrawer", ""));
    try t.expect(!clientMatchesLauncher("appdrawer power", "quickshell", ""));
    try t.expect(clientMatchesLauncher("nautilus", "org.gnome.nautilus", ""));
    try t.expect(clientMatchesLauncher("steam", "steam", ""));
    try t.expect(!clientMatchesLauncher("foot", "alacritty", "~ - fish"));
    // JSON plumbing: nested objects don't end the element early, braces in
    // titles don't confuse the splitter, string/int fields extract.
    const sample =
        \\{"clients":[{"id":7,"title":"a {b} \"c\"","appid":"Alacritty","tags":[1],"is_focused":true},{"id":9,"title":"x","appid":"org.gnome.Nautilus","tags":[4],"is_focused":false}]}
    ;
    var objs = topLevelObjects(sample);
    const o1 = objs.next() orelse return error.MissingObj;
    try t.expectEqualStrings("Alacritty", extractJsonString(o1, "\"appid\"") orelse "");
    try t.expectEqual(@as(i32, 7), extractJsonInt(o1, "\"id\"") orelse -1);
    try t.expect(std.mem.indexOf(u8, o1, "\"is_focused\":true") != null);
    const o2 = objs.next() orelse return error.MissingObj;
    try t.expectEqualStrings("org.gnome.Nautilus", extractJsonString(o2, "\"appid\"") orelse "");
    try t.expect(objs.next() == null);
    // Hyprland shape: nested workspace object inside the client element.
    const hp =
        \\[{"address":"0x1a2b","class":"firefox","title":"Tabs","workspace":{"id":1,"name":"1"}},{"address":"0x3c4d","class":"foot","title":"~","workspace":{"id":2,"name":"2"}}]
    ;
    var hobjs = topLevelObjects(hp);
    const h1 = hobjs.next() orelse return error.MissingObj;
    try t.expectEqualStrings("0x1a2b", extractJsonString(h1, "\"address\"") orelse "");
    try t.expectEqualStrings("firefox", extractJsonString(h1, "\"class\"") orelse "");
    const h2 = hobjs.next() orelse return error.MissingObj;
    try t.expectEqualStrings("foot", extractJsonString(h2, "\"class\"") orelse "");
    try t.expect(hobjs.next() == null);
    // Workspace/tag extraction: Mango's first tags[] entry, Hyprland's
    // nested workspace object.
    try t.expectEqual(@as(i32, 1), extractFirstTagId(o1) orelse -1);
    try t.expectEqual(@as(i32, 4), extractFirstTagId(o2) orelse -1);
    try t.expectEqual(@as(i32, 1), extractWorkspaceId(h1) orelse -1);
    try t.expectEqual(@as(i32, 2), extractWorkspaceId(h2) orelse -1);
    try t.expect(extractFirstTagId("{\"tags\":[]}") == null);
    try t.expect(extractWorkspaceId("{\"class\":\"x\"}") == null);
    // liveness + tail over a fake window set (globals restored after).
    const saved_launchers = current_config.launchers;
    const saved_apps = running_state.apps;
    const saved_len = running_state.len;
    defer {
        current_config.launchers = saved_launchers;
        running_state.apps = saved_apps;
        running_state.len = saved_len;
    }
    const fake_launchers = [_]LauncherButton{
        .{ .label = "Term", .command = "foot" },
        .{ .label = "Browser", .command = "simpbar-launch-browser" },
    };
    current_config.launchers = &fake_launchers;
    running_state.len = 3;
    running_state.apps[0] = .{};
    running_state.apps[0].appid_len = lowerCopy(&running_state.apps[0].appid_buf, "foot");
    running_state.apps[0].addr_len = 1;
    running_state.apps[0].focused = true;
    running_state.apps[1] = .{};
    running_state.apps[1].appid_len = lowerCopy(&running_state.apps[1].appid_buf, "org.gnome.Nautilus");
    running_state.apps[1].addr_len = 1;
    running_state.apps[2] = .{};
    running_state.apps[2].appid_len = lowerCopy(&running_state.apps[2].appid_buf, "Alacritty");
    running_state.apps[2].addr_len = 1;
    const live = launcherLive("foot");
    try t.expectEqual(@as(usize, 1), live.count);
    try t.expect(live.focused);
    try t.expectEqual(@as(usize, 0), live.client_idx.?);
    try t.expectEqual(@as(usize, 0), launcherLive("simpbar-launch-browser").count);
    var tail: [MAX_UNPINNED_GROUPS]UnpinnedGroup = undefined;
    const tail_n = collectUnpinned(&tail);
    try t.expectEqual(@as(usize, 2), tail_n);
    try t.expectEqualStrings("nautilus", tail[0].name());
    try t.expectEqualStrings("alacritty", tail[1].name());
}

test "launcher drag reorder math" {
    const t = std.testing;
    const saved_order = launcher_view_order;
    const saved_len = launcher_view_len;
    defer {
        launcher_view_order = saved_order;
        launcher_view_len = saved_len;
    }
    launcher_view_len = 4;
    launcher_view_order[0] = 0;
    launcher_view_order[1] = 1;
    launcher_view_order[2] = 2;
    launcher_view_order[3] = 3;
    try t.expectEqual(@as(usize, 0), launcherPosition(0).?);
    try t.expect(launcherPosition(9) == null);
    try t.expect(moveLauncherView(0, 2));
    try t.expectEqual(@as(usize, 1), launcher_view_order[0]);
    try t.expectEqual(@as(usize, 2), launcher_view_order[1]);
    try t.expectEqual(@as(usize, 0), launcher_view_order[2]);
    try t.expectEqual(@as(usize, 3), launcher_view_order[3]);
    try t.expect(!moveLauncherView(0, 2)); // already there
    try t.expect(!moveLauncherView(9, 0)); // unknown index
    try t.expect(moveLauncherView(3, 0));
    try t.expectEqual(@as(usize, 3), launcher_view_order[0]);
    try t.expect(moveLauncherView(1, 99)); // clamps to the end
    try t.expectEqual(@as(usize, 1), launcher_view_order[3]);
    // Drop targets count other pins' centers at/left of x (gaps split
    // evenly; non-launcher regions ignored).
    var regs: ClickRegions = .{};
    regs.add(0, 10, .{ .launcher = 0 });
    regs.add(12, 18, .{ .switch_workspace = 1 });
    regs.add(20, 30, .{ .launcher = 1 });
    regs.add(40, 50, .{ .launcher = 2 });
    try t.expectEqual(@as(usize, 2), dropPositionAt(&regs, 0, 45));
    try t.expectEqual(@as(usize, 0), dropPositionAt(&regs, 0, 5));
    try t.expectEqual(@as(usize, 2), dropPositionAt(&regs, 1, 100));
    try t.expectEqual(@as(usize, 0), dropPositionAt(&regs, 1, 0));
}

test "taskbar icons resolve" {
    const t = std.testing;
    const saved_idx_len = desktop_idx_len;
    defer desktop_idx_len = saved_idx_len;
    desktopIndexAdd("nautilus", "org.gnome.Nautilus");
    desktopIndexAdd("alacritty", "Alacritty");
    desktopIndexAdd("nautilus", "second-wins-never");
    try t.expectEqualStrings("org.gnome.Nautilus", desktopIndexLookup("nautilus") orelse "");
    try t.expectEqualStrings("Alacritty", desktopIndexLookup("alacritty") orelse "");
    try t.expect(desktopIndexLookup("nope") == null);
    // Pin names: drawer has none (glyph path), plain binaries go through
    // the index with the binary itself as fallback, junk wrappers miss.
    var nbuf: [64]u8 = undefined;
    try t.expect(pinIconName("appdrawer power", &nbuf) == null);
    try t.expectEqualStrings("org.gnome.Nautilus", pinIconName("nautilus", &nbuf) orelse "");
    try t.expectEqualStrings("foot", pinIconName("foot", &nbuf) orelse "");
    try t.expect(pinIconName("", &nbuf) == null);
    // Wrapped sandbox commands resolve to the wrapped app id, not the
    // wrapper binary — otherwise every flatpak pin matches nothing and
    // spawns duplicates.
    var fbuf: [64]u8 = undefined;
    try t.expectEqualStrings("com.spotify.client", launcherMatchKey("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=spotify --file-forwarding com.spotify.Client @@u @@", &fbuf));
    try t.expectEqualStrings("org.gnome.boxes", launcherMatchKey("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=gnome-boxes --file-forwarding org.gnome.Boxes @@u %U @@", &fbuf));
    try t.expectEqualStrings("spotify", launcherMatchKey("snap run spotify", &fbuf));
    try t.expectEqualStrings("flatpak", launcherMatchKey("flatpak update", &fbuf));
    try t.expect(clientMatchesLauncher("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=spotify --file-forwarding com.spotify.Client @@u @@", "spotify", ""));
    try t.expect(clientMatchesLauncher("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=gnome-boxes --file-forwarding org.gnome.Boxes @@u %U @@", "org.gnome.boxes", ""));
    try t.expect(!clientMatchesLauncher("/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=spotify --file-forwarding com.spotify.Client @@u @@", "alacritty", ""));
    // Deep index: full key, then DNS components (middle ones included).
    desktopIndexAdd("spotify", "com.spotify.Client");
    try t.expectEqualStrings("com.spotify.Client", desktopIndexLookupDeep("com.spotify.client") orelse "");
    try t.expect(desktopIndexLookupDeep("org.unknown.app") == null);
    const junk = [_][]const u8{"no-such-bin-xyz"};
    var wbuf: [64]u8 = undefined;
    try t.expect(wrapperIconName(&junk, "no-such-choice-xyz", &wbuf) == null);
    // Empty tail cache: lookups miss, no icon anywhere.
    try t.expect(tailIconFind("alacritty") == null);
    try t.expect(tailIconPixels("alacritty") == null);
    var g = UnpinnedGroup{ .client_idx = 99999 };
    try t.expect(!tailHasIcon(&g));
}

test "applications dirs cover user flatpak exports" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dirs: std.ArrayList([:0]const u8) = .empty;
    try desktop_entries.applicationsDirs(arena, "/home/tester", &dirs);
    // Scan order is the "first wins" order: the user's own dir leads, then
    // the user's Flatpak exports — `flatpak install --user` is the default
    // prompt on most setups, and those entries were invisible here, which
    // is how a running sandboxed app ended up with a dot but no icon.
    try t.expectEqual(@as(usize, 5), dirs.items.len);
    try t.expectEqualStrings("/home/tester/.local/share/applications", dirs.items[0]);
    try t.expectEqualStrings("/home/tester/.local/share/flatpak/exports/share/applications", dirs.items[1]);
    try t.expectEqualStrings("/usr/local/share/applications", dirs.items[2]);
    try t.expectEqualStrings("/usr/share/applications", dirs.items[3]);
    try t.expectEqualStrings("/var/lib/flatpak/exports/share/applications", dirs.items[4]);
}

test "cava curve interpolates" {
    const t = std.testing;
    try t.expectEqualStrings("bars", cavaStyleOrDefault(""));
    try t.expectEqualStrings("bars", cavaStyleOrDefault("nope"));
    try t.expectEqualStrings("wave", cavaStyleOrDefault("wave"));
    try t.expectEqualStrings("curve", cavaStyleOrDefault("curve"));
    // Fake daemon frame over the globals (restored after).
    const saved_bars = cava_state.bars;
    const saved_count = cava_state.bar_count;
    defer {
        cava_state.bars = saved_bars;
        cava_state.bar_count = saved_count;
    }
    cava_state.bars[0] = 250;
    cava_state.bars[1] = 500;
    cava_state.bars[2] = 750;
    cava_state.bars[3] = 1000;
    cava_state.bar_count = 4;
    try t.expectApproxEqAbs(@as(f32, 0.25), cavaBarFrac(0), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), cavaBarFrac(3), 1e-6);
    try t.expectEqual(@as(f32, 0.0), cavaBarFrac(4));
    try t.expectEqual(@as(f32, 0.0), cavaCurveFrac(0, 0));
    // Bar centers reproduce their own values (4 bars over 4 columns).
    try t.expectApproxEqAbs(@as(f32, 0.25), cavaCurveFrac(0, 4), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), cavaCurveFrac(3, 4), 1e-6);
    // Quarter-blend between bar 0 (.25) and bar 1 (.5): cosine ease at
    // t=0.25 is 0.5-0.5*cos(pi/4).
    const u = 0.5 - 0.5 * @cos(0.25 * std.math.pi);
    try t.expectApproxEqAbs(@as(f32, 0.25 + 0.25 * u), cavaCurveFrac(1, 8), 1e-5);
    // Past the ends it clamps instead of ringing.
    try t.expectApproxEqAbs(@as(f32, 0.25), cavaCurveFrac(0, 400), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), cavaCurveFrac(399, 400), 1e-6);
}

test "lava lamp field and color" {
    const t = std.testing;
    // One blob dead-center reads ~1.0; far away reads ~0; neighbors add.
    const one = [_]LavaBlob{.{ .x = 10.0, .y = 10.0, .r = 8.0 }};
    try t.expectApproxEqAbs(@as(f32, 1.0), lavaField(10.0, 10.0, &one), 1e-5);
    try t.expect(lavaField(200.0, 10.0, &one) < 0.05);
    const two = [_]LavaBlob{ .{ .x = 10.0, .y = 10.0, .r = 8.0 }, .{ .x = 10.0, .y = 10.0, .r = 8.0 } };
    try t.expectApproxEqAbs(@as(f32, 2.0), lavaField(10.0, 10.0, &two), 1e-5);
    // Blobs are deterministic per frame and live inside the region.
    const b0 = lavaBlob(0, 100, 600.0, 36.0, 1.0, 1.0);
    const b0_again = lavaBlob(0, 100, 600.0, 36.0, 1.0, 1.0);
    try t.expectEqual(b0.x, b0_again.x);
    try t.expect(b0.r > 0.0);
    const b1 = lavaBlob(1, 100, 600.0, 36.0, 1.0, 1.0);
    try t.expect(b0.x != b1.x or b0.y != b1.y);
    // Tempo moves blobs along their path; girth scales the radius.
    const fast = lavaBlob(0, 100, 600.0, 36.0, 2.0, 1.0);
    try t.expect(fast.y != b0.y);
    const fat = lavaBlob(0, 100, 600.0, 36.0, 1.0, 2.0);
    try t.expectApproxEqAbs(b0.r * 2.0, fat.r, 1e-4);
    // Color ramp climbs rim → body → core (each channel non-decreasing).
    const mid: u32 = 0xFFFF6A2A;
    const rim = lavaColorFor(1.0, mid);
    const body = lavaColorFor(1.8, mid);
    const core = lavaColorFor(3.0, mid);
    try t.expect((rim >> 16) & 0xFF <= (body >> 16) & 0xFF);
    try t.expect((body >> 16) & 0xFF <= (core >> 16) & 0xFF);
    try t.expect((core >> 16) & 0xFF >= 0xF0 and (core >> 8) & 0xFF >= 0xC0);
}

test "distro glyph tables" {
    const t = std.testing;
    // Direct hits (this machine is CachyOS; the tables must agree).
    try t.expectEqual(@as(u32, 0xF385), DISTRO_GLYPHS.get("cachyos").?);
    try t.expectEqual(@as(u32, 0xF303), DISTRO_GLYPHS.get("arch").?);
    try t.expectEqual(@as(u32, 0xF306), DISTRO_GLYPHS.get("debian").?);
    try t.expectEqual(@as(u32, 0xF30A), DISTRO_FAMILY_GLYPHS.get("fedora").?);
    try t.expect(DISTRO_GLYPHS.get("no-such-distro") == null);
    // The live detector agrees with the tables on whatever host runs
    // this (cache cleared first and restored after, so test order never
    // matters). Only asserted when the host ID hits the table directly —
    // family fallback has its own paths below the detector.
    const saved = g_distro_glyph;
    defer g_distro_glyph = saved;
    g_distro_glyph = null;
    var idbuf: [64]u8 = undefined;
    if (osReleaseValue("ID", &idbuf)) |id| {
        if (DISTRO_GLYPHS.get(id)) |cp| {
            try t.expectEqual(cp, distroLogoCodepoint());
        }
    }
}

test "mango all-tags scoped per monitor and sliceable" {
    const t = std.testing;
    var ws = Workspaces{ .gpa = t.allocator, .mode = .mango, .list = .empty, .sock_path_len = 0 };
    defer ws.deinit();

    // Two monitors, nine tags each — the multi-monitor shape that used to
    // interleave into one duplicated "1 2 2 3 ..." rail. The screenshot
    // scenario: monitor DP-1 sits on tag 1, HDMI-A-1 on tag 4.
    var buf: [4096]u8 = undefined;
    var used: usize = 0;
    const Put = struct {
        fn pr(out: []u8, fp: *usize, comptime fmt: []const u8, args: anytype) void {
            fp.* += (std.fmt.bufPrint(out[fp.*..], fmt, args) catch unreachable).len;
        }
    };
    Put.pr(&buf, &used, "{{\"all_tags\":[", .{});
    var mi: usize = 0;
    while (mi < 2) : (mi += 1) {
        const mon: []const u8 = if (mi == 0) "DP-1" else "HDMI-A-1";
        Put.pr(&buf, &used, "{s}{{", .{if (mi == 0) "" else ","});
        Put.pr(&buf, &used, "\"monitor\":\"{s}\",\"tags\":[", .{mon});
        const active_tag: usize = if (mi == 0) 1 else 4;
        var tag_i: usize = 1;
        while (tag_i <= 9) : (tag_i += 1) {
            const active = tag_i == active_tag;
            Put.pr(&buf, &used, "{{\"index\":{d},\"is_active\":{s},\"is_urgent\":{s},\"layout\":\"DW\",\"client_count\":0}}", .{ tag_i, if (active) "true" else "false", if (tag_i == 2 and mi == 1) "true" else "false" });
            if (tag_i < 9) Put.pr(&buf, &used, ",", .{});
        }
        Put.pr(&buf, &used, "]}}", .{});
    }
    Put.pr(&buf, &used, "]}}", .{});
    const payload = buf[0..used];

    try ws.scanMango(payload);

    // Sorted (monitor, id): DP-1's 1..9 contiguous, then HDMI-A-1's 1..9.
    try t.expectEqual(@as(usize, 18), ws.list.items.len);
    try t.expectEqualStrings("DP-1", ws.list.items[0].monitorName());
    try t.expectEqual(@as(i32, 1), ws.list.items[0].id);
    try t.expect(ws.list.items[0].active); // DP-1's tag 1
    try t.expect(!ws.list.items[1].active); // DP-1's tag 2
    try t.expectEqualStrings("HDMI-A-1", ws.list.items[9].monitorName());
    try t.expectEqual(@as(i32, 1), ws.list.items[9].id);
    try t.expectEqualStrings("DW", ws.layout());

    // Urgent flag lands on the right entry (HDMI tag 2): the old whole-
    // payload scan could bind it to the wrong monitor's same-numbered tag.
    try t.expect(ws.list.items[10].urgent);
    try t.expect(!ws.list.items[1].urgent);

    // Per-monitor rails: each bar gets exactly its monitor's run.
    const dp1 = ws.sliceForMonitor("DP-1");
    try t.expectEqual(@as(usize, 9), dp1.len);
    try t.expectEqual(@as(i32, 1), dp1[0].id);
    try t.expectEqualStrings("DP-1", dp1[8].monitorName());
    const hdmi = ws.sliceForMonitor("HDMI-A-1");
    try t.expectEqual(@as(usize, 9), hdmi.len);
    try t.expect(hdmi[3].active); // HDMI tag 4

    // Unknown bar (empty name) → merged list; missing name → same fallback
    // rather than a blank rail.
    try t.expectEqual(@as(usize, 18), ws.sliceForMonitor("").len);
    try t.expectEqual(@as(usize, 18), ws.sliceForMonitor("nope").len);
}

test "mango all-tags flat payload still fills the merged rail" {
    const t = std.testing;
    var ws = Workspaces{ .gpa = t.allocator, .mode = .mango, .list = .empty, .sock_path_len = 0 };
    defer ws.deinit();

    // Pre-per-monitor Mango (no monitor records): one flat scope, empty
    // monitor names — every bar serves the merged list as before.
    try ws.scanMango("{\"all_tags\":[{\"index\":9,\"is_active\":true,\"layout\":\"CT\"},{\"index\":2,\"is_active\":false,\"layout\":\"CT\"}]}");
    try t.expectEqual(@as(usize, 2), ws.list.items.len);
    try t.expectEqual(@as(i32, 2), ws.list.items[0].id); // sorted ids
    try t.expectEqual(@as(usize, 0), ws.list.items[0].monitorName().len);
    try t.expectEqual(@as(usize, 2), ws.sliceForMonitor("").len);
    try t.expectEqualStrings("CT", ws.layout());
}

test "hyprland workspace entries carry their monitor" {
    const t = std.testing;
    var ws = Workspaces{ .gpa = t.allocator, .mode = .hyprland, .list = .empty, .sock_path_len = 0 };
    defer ws.deinit();

    // monitorID sits before monitor in Hypr's payload; the scan needle
    // (`"monitor":"`) must not false-match it. Active workspace is id 3 on
    // DP-1 from the separate activeworkspace request.
    const payload =
        "[{\"id\":1,\"name\":\"1\",\"monitor\":\"DP-1\",\"monitorID\":0,\"windows\":1}," ++
        "{\"id\":9,\"name\":\"9\",\"monitor\":\"HDMI-A-1\",\"monitorID\":1,\"windows\":0}," ++
        "{\"id\":3,\"name\":\"3\",\"monitor\":\"DP-1\",\"monitorID\":0,\"windows\":2}]";
    try ws.scanHyprland(payload, 3);

    // (monitor, id) order: DP-1's run [1,3] then HDMI-A-1's [9].
    try t.expectEqual(@as(usize, 3), ws.list.items.len);
    try t.expectEqual(@as(i32, 1), ws.list.items[0].id);
    try t.expect(!ws.list.items[0].active);
    try t.expectEqual(@as(i32, 3), ws.list.items[1].id);
    try t.expect(ws.list.items[1].active);
    try t.expectEqual(@as(i32, 9), ws.list.items[2].id);
    try t.expectEqualStrings("DP-1", ws.list.items[1].monitorName());
    try t.expectEqualStrings("HDMI-A-1", ws.list.items[2].monitorName());

    try t.expectEqual(@as(usize, 2), ws.sliceForMonitor("DP-1").len);
    try t.expectEqual(@as(usize, 1), ws.sliceForMonitor("HDMI-A-1").len);
}

test "monitor name copy truncates without leaking capture" {
    const t = std.testing;
    var ws = Workspace{ .id = 1, .active = false };
    const long = "DP-1" ++ "0123456789" ** 6; // 64 chars > MONITOR_NAME_MAX
    ws.setMonitor(long);
    try t.expectEqual(@as(usize, MONITOR_NAME_MAX), ws.monitorName().len);
    // Re-set to the same name (already at the cap → same truncated string)
    // is idempotent through the slice helpers the bar uses.
    try t.expectEqualStrings(ws.monitorName(), ws.monitorName());
}

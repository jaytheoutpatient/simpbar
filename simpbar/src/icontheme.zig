//! Resolves a freedesktop icon *name* (what StatusNotifierItem's IconName
//! property gives you — e.g. "steam_tray_mono" — when an app doesn't embed
//! raw pixel data via IconPixmap) to an actual image file, and decodes it.
//!
//! This is a deliberately simplified version of the icon theme spec: it
//! doesn't parse index.theme, doesn't follow theme Inherits chains, and
//! doesn't detect which theme is actually configured — it searches
//! Flatpak's exported icon dirs (many sandboxed apps' icons only live
//! there) and the hicolor theme (the spec-mandated universal fallback),
//! then the always-installed Adwaita sets (for legacy names only they
//! ship), then the flat /usr/share/pixmaps location older apps use. A
//! "-symbolic" name with no direct hit retries as its non-symbolic twin.
//! That's enough to find real icons in practice without a full spec
//! implementation.

const std = @import("std");
// Not gdk-pixbuf.h directly — see the comment in build.zig on why.
const c = @cImport({
    @cInclude("gdkpixbuf_shim.h");
});

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
// mkdir is only test-side: fixtures for the user-icon-dir walks.
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

fn fileExists(path: [:0]const u8) bool {
    return access(path.ptr, 0) == 0; // F_OK is always 0 on POSIX
}

/// $HOME, or /root when unset — every home-relative path this module builds
/// goes through here.
fn homeDir() []const u8 {
    return if (getenv("HOME")) |h| std.mem.span(h) else "/root";
}

/// Icon theme simpbar-config's icon picker applied (via gsettings +
/// ~/.config/gtk-3.0/settings.ini, which GTK itself also reads). Empty
/// until refreshConfiguredTheme() runs — the hardcoded hicolor/Adwaita
/// search below then behaves exactly as before.
var theme_name_buf: [128]u8 = undefined;
var theme_name_len: usize = 0;

pub fn configuredTheme() []const u8 {
    return theme_name_buf[0..theme_name_len];
}

/// Re-reads gtk-icon-theme-name from ~/.config/gtk-3.0/settings.ini.
/// Call at startup and on every config reload; never fails.
pub fn refreshConfiguredTheme() void {
    theme_name_len = 0;
    const home = homeDir();
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/.config/gtk-3.0/settings.ini", .{home}) catch return;
    var zpath: [528]u8 = undefined;
    if (path.len + 1 > zpath.len) return;
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    const fd = open(zpath[0..path.len :0], 0, 0);
    if (fd < 0) return;
    defer _ = close(fd);
    var data: [32768]u8 = undefined;
    var n_total: usize = 0;
    while (n_total < data.len) {
        const n = read(fd, data[n_total..].ptr, data.len - n_total);
        if (n <= 0) break;
        n_total += @intCast(n);
    }
    var lines = std.mem.splitScalar(u8, data[0..n_total], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "gtk-icon-theme-name")) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len == 0 or v.len >= theme_name_buf.len) return;
        for (v) |ch| {
            if (ch == '/' or ch == 0 or ch == '\n' or ch == '\r') return;
        }
        @memcpy(theme_name_buf[0..v.len], v);
        theme_name_len = v.len;
        return;
    }
}

fn tryPath(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Finds an icon file for `name`, writing the path into `buf` and returning
/// a slice of it, or null if nothing matched.
pub fn resolveIconPath(name: []const u8, buf: []u8) ?[]const u8 {
    if (searchIconPath(name, buf)) |p| return p;
    // Standard fallback: a "-symbolic" icon with no direct hit retries as
    // its non-symbolic twin (our config/welcome pins name the symbolic
    // form while only the regular one is installed).
    const suffix = "-symbolic";
    if (name.len > suffix.len and std.mem.endsWith(u8, name, suffix)) {
        if (searchIconPath(name[0 .. name.len - suffix.len], buf)) |p| return p;
    }
    return null;
}

fn searchIconPath(name: []const u8, buf: []u8) ?[]const u8 {
    return searchIconPathIn(homeDir(), name, buf);
}

/// One (root, theme dir, contexts) place the lookup walks.
const IconRoot = struct { root: []const u8, theme: []const u8, ctxs: []const []const u8 };

/// The user-level roots: always searched, and always ahead of the system
/// ones — the Flatpak export tree (`flatpak install --user` is the default
/// prompt, so many apps' icons live only there), then the two plain per-user
/// icon dirs. The latter matter for game launchers in particular: Lutris
/// installs each game's own icon (`Icon=lutris_diablo`, via
/// `xdg-icon-resource --novendor`) into `~/.local/share/icons/hicolor/…`,
/// and before these roots existed that name resolved nowhere except behind
/// the configured-theme branch — so the pin and the taskbar tail drew a text
/// label where the game's art should be. The icon spec puts user dirs ahead
/// of system ones for the same reason, so a user-installed name wins.
///
/// `buf` (three path slots) holds the formatted paths, so the returned
/// slices outlive this call — callers keep it in scope while they walk the
/// list.
fn userIconRoots(home: []const u8, buf: *[3 * 512]u8) [3]IconRoot {
    const ctxs = &[_][]const u8{ "apps", "status", "actions" };
    const flatpak = std.fmt.bufPrint(buf[0..512], "{s}/.local/share/flatpak/exports/share/icons", .{home}) catch "";
    const user = std.fmt.bufPrint(buf[512..1024], "{s}/.local/share/icons", .{home}) catch "";
    const dot = std.fmt.bufPrint(buf[1024..1536], "{s}/.icons", .{home}) catch "";
    return .{
        .{ .root = flatpak, .theme = "hicolor", .ctxs = ctxs },
        .{ .root = user, .theme = "hicolor", .ctxs = ctxs },
        .{ .root = dot, .theme = "hicolor", .ctxs = ctxs },
    };
}

/// `home` is a parameter rather than a `homeDir()` call here so tests can
/// aim the walk at a fixture without mutating the process environment.
fn searchIconPathIn(home: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;

    if (name.len > 0 and name[0] == '/') {
        if (tryPath(&path_buf, "{s}", .{name})) |p| {
            if (fileExists(p)) {
                const len = @min(p.len, buf.len);
                @memcpy(buf[0..len], p[0..len]);
                return buf[0..len];
            }
        }
        return null;
    }

    // The user-picked theme first (simpbar-config's icon picker): user
    // dirs, then system icons. Skipped when no theme is configured — then
    // this resolves exactly as before.
    const picked = configuredTheme();
    if (picked.len != 0) {
        const picked_sizes = [_][]const u8{ "scalable", "symbolic", "256x256", "128x128", "64x64", "48x48", "32x32", "24x24", "22x22", "16x16" };
        const picked_ctxs = [_][]const u8{ "apps", "status", "actions", "devices" };
        const picked_exts = [_][]const u8{ ".svg", ".png" };
        var hbuf: [512]u8 = undefined;
        const user_rels = [_][]const u8{ ".icons", ".local/share/icons" };
        for (user_rels) |rel| {
            const root = std.fmt.bufPrint(&hbuf, "{s}/{s}", .{ home, rel }) catch continue;
            for (picked_sizes) |size| {
                for (picked_ctxs) |ctx| {
                    for (picked_exts) |ext| {
                        const p = tryPath(&path_buf, "{s}/{s}/{s}/{s}/{s}{s}", .{ root, picked, size, ctx, name, ext }) orelse continue;
                        if (fileExists(p)) {
                            const len = @min(p.len, buf.len);
                            @memcpy(buf[0..len], p[0..len]);
                            return buf[0..len];
                        }
                    }
                }
            }
        }
        for (picked_sizes) |size| {
            for (picked_ctxs) |ctx| {
                for (picked_exts) |ext| {
                    const p = tryPath(&path_buf, "/usr/share/icons/{s}/{s}/{s}/{s}{s}", .{ picked, size, ctx, name, ext }) orelse continue;
                    if (fileExists(p)) {
                        const len = @min(p.len, buf.len);
                        @memcpy(buf[0..len], p[0..len]);
                        return buf[0..len];
                    }
                }
            }
        }
    }

    // (root, theme dir, contexts): the user-level trees lead in their
    // historical order (Flatpak exports shadow system icons, as before),
    // then the always-present Adwaita sets for names only they ship
    // (legacy context included). Anything resolving before this change
    // resolves to the same file after it; later roots only fill past
    // misses. The user-level Flatpak export tree leads the list for the
    // same reason XDG_DATA_DIRS puts it first: `flatpak install --user`
    // is the default prompt on most setups, and its icons live only there.
    var roots_buf: [3 * 512]u8 = undefined;
    const roots = userIconRoots(home, &roots_buf) ++ [_]IconRoot{
        .{ .root = "/var/lib/flatpak/exports/share/icons", .theme = "hicolor", .ctxs = &[_][]const u8{ "apps", "status", "actions" } },
        .{ .root = "/usr/share/icons", .theme = "hicolor", .ctxs = &[_][]const u8{ "apps", "status", "actions" } },
        .{ .root = "/usr/share/icons", .theme = "Adwaita", .ctxs = &[_][]const u8{ "apps", "status", "actions", "devices", "legacy" } },
        .{ .root = "/usr/share/icons", .theme = "AdwaitaLegacy", .ctxs = &[_][]const u8{ "apps", "status", "actions", "devices", "legacy" } },
    };
    // "symbolic" and "scalable" aren't WxH names but are real, common
    // directory names in the spec (monochrome / vector icons); tried
    // first since they scale cleanly to our small render size.
    const sizes = [_][]const u8{ "scalable", "symbolic", "256x256", "128x128", "64x64", "48x48", "32x32", "24x24", "22x22", "16x16" };
    const exts = [_][]const u8{ ".svg", ".png" };

    for (roots) |r| {
        for (sizes) |size| {
            for (r.ctxs) |ctx| {
                for (exts) |ext| {
                    const p = tryPath(&path_buf, "{s}/{s}/{s}/{s}/{s}{s}", .{ r.root, r.theme, size, ctx, name, ext }) orelse continue;
                    if (fileExists(p)) {
                        const len = @min(p.len, buf.len);
                        @memcpy(buf[0..len], p[0..len]);
                        return buf[0..len];
                    }
                }
            }
        }
    }

    for (exts) |ext| {
        const p = tryPath(&path_buf, "/usr/share/pixmaps/{s}{s}", .{ name, ext }) orelse continue;
        if (fileExists(p)) {
            const len = @min(p.len, buf.len);
            @memcpy(buf[0..len], p[0..len]);
            return buf[0..len];
        }
    }

    return null;
}

/// Steam game icons: the one common class of running app with no .desktop
/// entry anywhere to key off. Steam reports a running game's app_id as
/// "steam_app_<appid>" (SDL and Proton both set it from SteamAppId), and
/// keeps every game's square icon in its own library cache at
/// <steam>/appcache/librarycache/<appid>/<40-hex>.jpg — sitting next to the
/// store art (library_600x900.jpg, library_hero.jpg, …) it is shipped with.
/// Returns the icon path when `appid_norm` names a Steam game, else null
/// (callers keep their label fallback).
pub fn steamGameIconPath(appid_norm: []const u8, buf: []u8) ?[]const u8 {
    const id = steamAppIdDigits(appid_norm) orelse return null;
    const home = homeDir();
    // Install roots Steam actually uses, best first: ~/.steam/steam is the
    // usual symlink into ~/.local/share/Steam, kept alongside it for the
    // setups where one exists without the other (debian-installation is the
    // Debian/Ubuntu package's own name).
    const rels = [_][]const u8{ "/.steam/steam", "/.local/share/Steam", "/.steam/root", "/.steam/debian-installation" };
    for (rels) |rel| {
        var dir_buf: [512]u8 = undefined;
        const dir = tryPath(&dir_buf, "{s}{s}/appcache/librarycache/{s}", .{ home, rel, id }) orelse continue;
        if (steamIconInDir(dir, buf)) |p| return p;
        // Some entries cache only store art (no square icon downloaded yet)
        // — the portrait capsule is the closest thing Steam ships, and it
        // letterboxes into the icon cell rather than dropping to a label.
        var cap_buf: [560]u8 = undefined;
        const cap = tryPath(&cap_buf, "{s}/library_600x900.jpg", .{dir}) orelse continue;
        if (fileExists(cap)) {
            const len = @min(buf.len, cap.len);
            @memcpy(buf[0..len], cap[0..len]);
            return buf[0..len];
        }
    }
    return null;
}

/// "steam_app_440" → "440"; null for anything that isn't a Steam game id
/// (the Steam client itself reports "steam", non-Steam apps their own ids).
fn steamAppIdDigits(appid_norm: []const u8) ?[]const u8 {
    const prefix = "steam_app_";
    if (!std.mem.startsWith(u8, appid_norm, prefix)) return null;
    const digits = appid_norm[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return digits;
}

/// glibc's struct dirent64 (x86_64/Linux layout), same declaration as
/// desktop_entries.zig's — only d_name is read here.
const Dirent = extern struct {
    d_ino: u64 = 0,
    d_off: i64 = 0,
    d_reclen: u16 = 0,
    d_type: u8 = 0,
    d_name: [256]u8 = undefined,
};

const libc_dir = struct {
    extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
    extern "c" fn readdir(dirp: *anyopaque) ?*const Dirent;
    extern "c" fn closedir(dirp: *anyopaque) c_int;
};

/// Smallest square image in `dir` — Steam's icon, versus the far larger
/// store art sharing the folder (a 32x32 hash jpg next to a 7000x7000
/// splash). Writes the chosen path into `out`, or null when the directory
/// holds no decodable image at all.
fn steamIconInDir(dir: [:0]const u8, out: []u8) ?[]const u8 {
    const dirp = libc_dir.opendir(dir.ptr) orelse return null;
    defer _ = libc_dir.closedir(dirp);
    var best: ?ImageDims = null;
    var best_len: usize = 0;
    var pbuf: [640]u8 = undefined;
    while (libc_dir.readdir(dirp)) |ent| {
        const name = std.mem.sliceTo(&ent.d_name, 0);
        if (!isSteamIconFileName(name)) continue;
        const path = tryPath(&pbuf, "{s}/{s}", .{ dir, name }) orelse continue;
        const d = imageDims(path) orelse continue;
        if (best) |b| {
            if (!smallerIcon(d, b)) continue;
        }
        const len = @min(out.len, path.len);
        @memcpy(out[0..len], path[0..len]);
        best = d;
        best_len = len;
    }
    return if (best != null) out[0..best_len] else null;
}

/// Steam names each cached asset after a content hash: exactly 40 hex chars
/// plus an image extension. The store art carries readable names instead
/// (header, library_hero, logo), which is what makes them tellable apart.
fn isSteamIconFileName(name: []const u8) bool {
    const stem_len = 40; // one SHA-1 content hash, hex-encoded
    if (name.len != stem_len + 4) return false;
    for (name[0..stem_len]) |ch| {
        const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!hex) return false;
    }
    return std.mem.endsWith(u8, name, ".jpg") or std.mem.endsWith(u8, name, ".jpeg") or std.mem.endsWith(u8, name, ".png");
}

/// True when `a` is the better (smaller) icon candidate: min side by the
/// longest edge, then by area — the 32x32 icon always beats store art.
fn smallerIcon(a: ImageDims, b: ImageDims) bool {
    const am = @max(a.w, a.h);
    const bm = @max(b.w, b.h);
    if (am != bm) return am < bm;
    return a.w * a.h < b.w * b.h;
}

const ImageDims = struct { w: u32, h: u32 };

fn readU16BE(b: []const u8) u32 {
    return (@as(u32, b[0]) << 8) | b[1];
}

fn readU32BE(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// Dimensions from the first bytes of a PNG or JPEG, read straight from the
/// file — enough to tell Steam's icon from its store art without decoding
/// (the art is megabytes; the icon is a kilobyte) and without a stat()
/// binding. Null when the file isn't a decodable image.
fn imageDims(path: [:0]const u8) ?ImageDims {
    const fd = open(path.ptr, 0, 0); // O_RDONLY
    if (fd < 0) return null;
    defer _ = close(fd);
    var head: [4096]u8 = undefined;
    const n = read(fd, &head, head.len);
    if (n <= 0) return null;
    return imageDimsFromHeader(head[0..@intCast(n)]);
}

/// Split out of imageDims so the parsers are testable without a filesystem.
fn imageDimsFromHeader(head: []const u8) ?ImageDims {
    // PNG: 8-byte signature, then the IHDR chunk's big-endian w/h.
    if (head.len >= 24 and std.mem.eql(u8, head[0..8], "\x89PNG\r\n\x1a\n")) {
        const w = readU32BE(head[16..20]);
        const h = readU32BE(head[20..24]);
        if (w == 0 or h == 0) return null;
        return .{ .w = w, .h = h };
    }
    // JPEG: walk the segment chain to a Start-Of-Frame marker, which carries
    // height then width as big-endian u16. Fill bytes, RSTn and the SOI
    // marker take no length word; everything else is skipped by its own.
    if (head.len >= 4 and head[0] == 0xFF and head[1] == 0xD8) {
        var i: usize = 2;
        while (i + 9 < head.len) {
            if (head[i] != 0xFF) {
                i += 1;
                continue;
            }
            const marker = head[i + 1];
            if (marker == 0xFF) {
                i += 1;
                continue;
            }
            // SOF0..SOF15 minus DHT (C4), JPG (C8) and DAC (CC).
            if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
                const h = readU16BE(head[i + 5 .. i + 7]);
                const w = readU16BE(head[i + 7 .. i + 9]);
                if (w == 0 or h == 0) return null;
                return .{ .w = w, .h = h };
            }
            if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9)) {
                i += 2; // TEM / RSTn / SOI / EOI: no length word
                continue;
            }
            const seg_len = readU16BE(head[i + 2 .. i + 4]);
            if (seg_len < 2) return null; // malformed: don't wander
            i += 2 + seg_len;
        }
    }
    return null;
}

pub const DecodedIcon = struct {
    width: u32,
    height: u32,
    /// ARGB8888 (0xAARRGGBB), owned — caller frees with the same allocator.
    pixels: []u32,
};

/// Decodes `path` (PNG or SVG — gdk-pixbuf handles both, rasterizing SVG at
/// the requested size via its librsvg-backed loader) scaled to fit within
/// `target_size`x`target_size`, preserving aspect ratio (so the result may
/// be smaller than target_size in one dimension).
pub fn decodeIcon(gpa: std.mem.Allocator, path: [:0]const u8, target_size: u32) !DecodedIcon {
    const pb = c.simpbar_pixbuf_load(path.ptr, @intCast(target_size)) orelse return error.DecodeFailed;
    defer c.simpbar_pixbuf_free(pb);

    const w: u32 = @intCast(c.simpbar_pixbuf_width(pb));
    const h: u32 = @intCast(c.simpbar_pixbuf_height(pb));
    if (w == 0 or h == 0) return error.EmptyImage;
    const rowstride: u32 = @intCast(c.simpbar_pixbuf_rowstride(pb));
    const n_channels: u32 = @intCast(c.simpbar_pixbuf_channels(pb));
    const has_alpha = c.simpbar_pixbuf_has_alpha(pb) != 0;
    const src = c.simpbar_pixbuf_pixels(pb);

    const pixels = try gpa.alloc(u32, w * h);
    errdefer gpa.free(pixels);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const off = y * rowstride + x * n_channels;
            const r = src[off];
            const g = src[off + 1];
            const b = src[off + 2];
            const a: u8 = if (has_alpha) src[off + 3] else 255;
            pixels[y * w + x] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        }
    }
    return DecodedIcon{ .width = w, .height = h, .pixels = pixels };
}

/// Copies `decoded` centered into `dst` (a `dst_size`x`dst_size` buffer),
/// leaving the rest transparent — used when the decoded image is smaller
/// than the target in one dimension (aspect-ratio padding).
pub fn copyIntoIconBuffer(decoded: DecodedIcon, dst: []u32, dst_size: u32) void {
    @memset(dst, 0);
    const x_off = (dst_size -| decoded.width) / 2;
    const y_off = (dst_size -| decoded.height) / 2;
    var y: u32 = 0;
    while (y < decoded.height and y + y_off < dst_size) : (y += 1) {
        var x: u32 = 0;
        while (x < decoded.width and x + x_off < dst_size) : (x += 1) {
            dst[(y + y_off) * dst_size + (x + x_off)] = decoded.pixels[y * decoded.width + x];
        }
    }
}

// --- tests -----------------------------------------------------------------

test "steam game appids are the steam_app_<digits> form" {
    const t = std.testing;
    try t.expectEqualStrings("440", steamAppIdDigits("steam_app_440").?);
    try t.expectEqualStrings("1012790", steamAppIdDigits("steam_app_1012790").?);
    // The client, a typo, and anything else that merely mentions steam.
    try t.expect(steamAppIdDigits("steam") == null);
    try t.expect(steamAppIdDigits("steam_app_") == null);
    try t.expect(steamAppIdDigits("steam_app_44a") == null);
    try t.expect(steamAppIdDigits("steam_app_440_extra") == null);
    try t.expect(steamAppIdDigits("org.steam.App") == null);
    try t.expect(steamAppIdDigits("") == null);
}

test "steam cache names only its hash-stemmed assets" {
    const t = std.testing;
    try t.expect(isSteamIconFileName("6b0312cda02f5f777efa2f3318c307ff9acafbb5.jpg"));
    try t.expect(isSteamIconFileName("077b050ef3e89cd84e2c5a575d78d53b54058236.PNG") == false); // ext is checked lowercase-verbatim
    try t.expect(isSteamIconFileName("077b050ef3e89cd84e2c5a575d78d53b54058236.png"));
    // The store art shares the folder but is never hash-named.
    try t.expect(!isSteamIconFileName("library_600x900.jpg"));
    try t.expect(!isSteamIconFileName("library_hero.jpg"));
    try t.expect(!isSteamIconFileName("header.jpg"));
    try t.expect(!isSteamIconFileName("logo.png"));
    try t.expect(!isSteamIconFileName("6b0312cda02f5f777efa2f3318c307ff9acafbb5.jpg.tmp"));
    // 39 chars, 41 chars, non-hex — all out.
    try t.expect(!isSteamIconFileName("6b0312cda02f5f777efa2f3318c307ff9acafbb.jpg"));
    try t.expect(!isSteamIconFileName("6b0312cda02f5f777efa2f3318c307ff9acafbb55.jpg"));
    try t.expect(!isSteamIconFileName("zzb0312cda02f5f777efa2f3318c307ff9acafbb5.jpg"));
    try t.expect(!isSteamIconFileName(""));
}

test "the smaller image wins the icon slot" {
    const t = std.testing;
    const icon = ImageDims{ .w = 32, .h = 32 };
    const splash = ImageDims{ .w = 7000, .h = 7000 }; // real: the 7 MB one
    const capsule = ImageDims{ .w = 300, .h = 450 };
    try t.expect(smallerIcon(icon, splash));
    try t.expect(!smallerIcon(splash, icon));
    try t.expect(smallerIcon(icon, capsule));
    // Equal longest edge falls back to area, so 64x64 beats 64x128.
    try t.expect(smallerIcon(.{ .w = 64, .h = 64 }, .{ .w = 64, .h = 128 }));
    try t.expect(!smallerIcon(.{ .w = 64, .h = 128 }, .{ .w = 64, .h = 64 }));
}

test "image dimensions read from PNG and JPEG headers" {
    const t = std.testing;
    // PNG: signature, IHDR chunk tag, then big-endian width/height.
    var png: [24]u8 = undefined;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    png[8..12].* = .{ 0, 0, 0, 13 };
    @memcpy(png[12..16], "IHDR");
    png[16..20].* = .{ 0, 0, 0, 64 };
    png[20..24].* = .{ 0, 0, 0, 48 };
    try t.expectEqual(ImageDims{ .w = 64, .h = 48 }, imageDimsFromHeader(&png).?);

    // JPEG: SOI, a 16-byte APP0 segment, then SOF0 with height then width.
    var jpg: [32]u8 = undefined;
    @memset(&jpg, 0);
    jpg[0] = 0xFF;
    jpg[1] = 0xD8; // SOI
    jpg[2] = 0xFF;
    jpg[3] = 0xE0; // APP0
    jpg[4] = 0x00;
    jpg[5] = 0x10; // length 16 → next marker at 2 + 2 + 16
    jpg[20] = 0xFF;
    jpg[21] = 0xC0; // SOF0
    jpg[22] = 0x00;
    jpg[23] = 0x11; // length
    jpg[24] = 0x08; // precision
    jpg[25] = 0x01;
    jpg[26] = 0x2C; // height 300
    jpg[27] = 0x01;
    jpg[28] = 0x2C; // width 300
    try t.expectEqual(ImageDims{ .w = 300, .h = 300 }, imageDimsFromHeader(&jpg).?);

    // Neither format (an SVG, say — no fixed-size header) reads as dims,
    // which is exactly why the cache picker only trusts hash-named files.
    try t.expect(imageDimsFromHeader("<svg xmlns=\"http://www.w3.org/2000/svg\"/>") == null);
    try t.expect(imageDimsFromHeader("") == null);
    // A truncated JPEG chain must not wander off the end.
    try t.expect(imageDimsFromHeader(jpg[0..8]) == null);
}

test "flatpak exports and plain user icon dirs lead the walk" {
    const t = std.testing;
    const home = "/home/tester";
    var buf: [3 * 512]u8 = undefined;
    const user_roots = userIconRoots(home, &buf);

    // Order is the "user wins" order: user Flatpak exports first (they
    // shadow system names the same way XDG_DATA_DIRS ranks them), then the
    // plain user dirs Lutris/xdg-icon-resource install into.
    try t.expectEqualStrings("/home/tester/.local/share/flatpak/exports/share/icons", user_roots[0].root);
    try t.expectEqualStrings("/home/tester/.local/share/icons", user_roots[1].root);
    try t.expectEqualStrings("/home/tester/.icons", user_roots[2].root);
    for (user_roots) |r| {
        try t.expectEqualStrings("hicolor", r.theme);
        try t.expectEqual(@as(usize, 3), r.ctxs.len);
        try t.expectEqualStrings("apps", r.ctxs[0]);
    }
}

/// Raw libc fixture helper (the module's own I/O idiom): create every
/// missing level of `prefix ++ rel`, ignoring EEXIST.
fn testMakeDirs(prefix: []const u8, rel: []const u8) void {
    var z: [512:0]u8 = undefined;
    @memcpy(z[0..prefix.len], prefix);
    var at = prefix.len;
    // Join with one '/', or "home" + ".local" glues into "home.local".
    if (at != 0 and z[at - 1] != '/') {
        z[at] = '/';
        at += 1;
    }
    for (rel) |ch| {
        z[at] = ch;
        at += 1;
        if (ch == '/') {
            z[at] = 0;
            _ = mkdir(&z, 0o755);
        }
    }
    z[at] = 0;
    _ = mkdir(&z, 0o755);
}

/// Creates an empty file at `path` (its existence is all `access()` needs).
fn testTouch(path: []const u8) void {
    var z: [512:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    // O_WRONLY | O_CREAT | O_TRUNC
    const fd = open(&z, 1 | 64 | 512, 0o644);
    if (fd >= 0) _ = close(fd);
}

test "a Lutris-style game icon resolves from the plain user dirs" {
    const t = std.testing;
    // Fixture home is the test run's scratch dir (std.testing.tmpDir parks
    // it under <cwd>/.zig-cache/tmp/<random>): the walk takes `home`, so no
    // HOME environment mutation, and cleanup() deletes the whole tree.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [512]u8 = undefined;
    const home = std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    // Lutris drops each game's own art in ~/.local/share/icons (a
    // `xdg-icon-resource --novendor` install), the older ~/.icons tree the
    // XDG lookup sketches as a twin; both must be reachable.
    testMakeDirs(home, ".local/share/icons/hicolor/128x128/apps");
    testMakeDirs(home, ".icons/hicolor/64x64/apps");
    var path_buf: [512]u8 = undefined;
    testTouch(std.fmt.bufPrint(&path_buf, "{s}/.local/share/icons/hicolor/128x128/apps/test_game_art.png", .{home}) catch unreachable);
    testTouch(std.fmt.bufPrint(&path_buf, "{s}/.icons/hicolor/64x64/apps/test_dot_art.png", .{home}) catch unreachable);

    var out: [512]u8 = undefined;
    const game = searchIconPathIn(home, "test_game_art", &out).?;
    try t.expect(std.mem.indexOf(u8, game, "/.local/share/icons/hicolor/128x128/apps/test_game_art.png") != null);
    const dot = searchIconPathIn(home, "test_dot_art", &out).?;
    try t.expect(std.mem.indexOf(u8, dot, "/.icons/hicolor/64x64/apps/test_dot_art.png") != null);

    // And the walk still ends: a name present in neither tree misses, as
    // it always did, instead of something half-failing.
    try t.expect(searchIconPathIn(home, "test_never_installed", &out) == null);
}


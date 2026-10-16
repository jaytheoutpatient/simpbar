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

fn fileExists(path: [:0]const u8) bool {
    return access(path.ptr, 0) == 0; // F_OK is always 0 on POSIX
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
    const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/root";
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
        const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/root";
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

    // (root, theme dir, contexts): the two hicolor trees first in their
    // historical order (Flatpak exports shadow system icons, as before),
    // then the always-present Adwaita sets for names only they ship
    // (legacy context included). Anything resolving before this change
    // resolves to the same file after it; later roots only fill past
    // misses.
    const roots = [_]struct { root: []const u8, theme: []const u8, ctxs: []const []const u8 }{
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

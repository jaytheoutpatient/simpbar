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

fn fileExists(path: [:0]const u8) bool {
    return access(path.ptr, 0) == 0; // F_OK is always 0 on POSIX
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

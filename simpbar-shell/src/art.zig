//! Album-art decoding for the media card, via the same gdk-pixbuf shim the
//! bar uses for tray icons (../simpbar/src/gdkpixbuf_shim.{c,h}).
//!
//! gdk-pixbuf sniffs the image format from content, so JPEG/PNG/WebP from
//! MPRIS art URLs all decode through one call. The caller hands over a file
//! path (downloaded with curl for http(s) URLs, used directly for file://)
//! and gets back centered RGBA bytes sized for the cover tile.

const std = @import("std");

const c = @cImport(@cInclude("gdkpixbuf_shim.h"));

/// Cover tile interior in px (64px tile minus the 1px card border ring).
pub const COVER_PX: u8 = 62;
pub const COVER_BYTES: usize = @as(usize, COVER_PX) * COVER_PX * 4;

/// Decodes `path` (NUL-terminated) into `out` as COVER_PX² straight-alpha
/// RGBA. Images larger than the tile scale down preserving aspect ratio;
/// smaller ones are centered by the caller using the returned dims. Returns
/// null on any failure (missing file, unsupported format, decode error) —
/// the caller keeps the placeholder tile.
pub fn decodeCover(path: [:0]const u8, out: *[COVER_BYTES]u8) ?struct { w: u8, h: u8 } {
    const pb = c.simpbar_pixbuf_load(path.ptr, COVER_PX) orelse return null;
    defer c.simpbar_pixbuf_free(pb);
    const w = c.simpbar_pixbuf_width(pb);
    const h = c.simpbar_pixbuf_height(pb);
    if (w <= 0 or h <= 0 or w > COVER_PX or h > COVER_PX) return null;
    const channels = c.simpbar_pixbuf_channels(pb);
    if (channels != 3 and channels != 4) return null;
    const rowstride: usize = @intCast(c.simpbar_pixbuf_rowstride(pb));
    const has_alpha = c.simpbar_pixbuf_has_alpha(pb) != 0;
    const src = c.simpbar_pixbuf_pixels(pb);
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const uch: usize = @intCast(channels);
    var row: usize = 0;
    while (row < uh) : (row += 1) {
        var col: usize = 0;
        while (col < uw) : (col += 1) {
            const s = row * rowstride + col * uch;
            const d = (row * uw + col) * 4;
            out[d] = src[s];
            out[d + 1] = src[s + 1];
            out[d + 2] = src[s + 2];
            out[d + 3] = if (has_alpha) src[s + 3] else 0xFF;
        }
    }
    return .{ .w = @intCast(w), .h = @intCast(h) };
}

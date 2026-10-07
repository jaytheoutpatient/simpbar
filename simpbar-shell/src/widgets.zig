//! simpbar-shell's "paint-only desktop widget" model.
//!
//! This is a direct port of the idea behind Event-Horizon-Shell's
//! `DesktopWidget` base class (C++, MIT — github.com/Event-Horizon-desktop-
//! environment/Event-Horizon-Shell): a widget owns no window; it is a small
//! struct that paints its current state into a shared ARGB surface buffer
//! on demand, reports the cadence at which it needs repainting, and reacts
//! to clicks over its rect. The host (main.zig) draws every widget into one
//! full-output "desktop layer" surface per monitor, lazy-scheduled from each
//! widget's cadence — no fixed animation loop.
//!
//! All drawing is software (freetype glyph coverage alpha-blended into a
//! wl_shm ARGB8888 buffer), matching how the bar renders and how the original
//! shell renders with Cairo.

const std = @import("std");
const posix = std.posix;
const font_mod = @import("font");
const art_mod = @import("art");
const logging = @import("logging");

pub const WidgetId = enum { clock, weather, media, system, calendar, watch };

/// Axis-aligned rect in surface coordinates. The host keeps one per widget
/// (measured from the font at startup, placed from config).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            px < self.x + @as(i32, @intCast(self.w)) and
            py < self.y + @as(i32, @intCast(self.h));
    }
};

/// Themed palette for cards. Colors are 0xAARRGGBB. `card_alpha` is 0-100
/// and only scales card fills (frosted-glass look, like the bar's
/// bg_opacity_percent); text/borders stay fully opaque.
pub const Theme = struct {
    bg_color: u32 = 0xFF0F0F0F,
    text_color: u32 = 0xFFDCDCDC,
    border_color: u32 = 0xFF454545,
    hover_color: u32 = 0xFF3A3A3A,
    /// Warm accent for public-holiday days on the calendar. Sourced from the
    /// matugen template's `holiday_color` when present, so it follows the
    /// wallpaper theme like the rest.
    holiday_color: u32 = 0xFFF0805C,
    card_alpha: u32 = 55,
    radius_px: u32 = 12,
};

const CARD_PAD: i64 = 14;
const ROW_GAP: i64 = 5;
const BAR_H: i64 = 6;

// Media-card geometry. cardSizeFor and MediaWidget.paint share these so the
// measured rect always fits the painted layout (13px font metrics).
const MEDIA_W: i64 = 340;
const MEDIA_COVER: i64 = 64;
const MEDIA_HEAD_GAP: i64 = 10;
const MEDIA_PROG_H: i64 = 4;
const MEDIA_TIME_GAP: i64 = 8;
const MEDIA_TITLE_GAP: i64 = 4;
const MEDIA_CTRL_GAP: i64 = 10;

// Calendar-card geometry: header row (< month year >), weekday row, a 6x7
// day grid, and a footer line naming today's/next holiday. cardSizeFor and
// CalendarWidget share these.
const CAL_W: i64 = 196;
const CAL_CELL_W: i64 = 24; // 7 cells: 168 = CAL_W - 2*CARD_PAD
const CAL_CELL_H: i64 = 20;
const CAL_ROWS: i64 = 6;
const CAL_HEAD_GAP: i64 = 6;
const CAL_WD_GAP: i64 = 4;
const CAL_FOOT_GAP: i64 = 6;
const CAL_ARROW_ZONE: i64 = 20; // clickable width of the < / > header zones

// Analog watch (Seiko diver style) geometry: a compact tile whose content
// IS the widget — the host skips its frosted card for this one, the steel
// case and bezel are the chrome. No bracelet: just the head, with short
// lug stubs top and bottom. cardSizeFor and WatchWidget.paint share these
// so the measured rect always fits the painted watch.
const WATCH_W: i64 = 190;
const WATCH_H: i64 = 200;
const WATCH_CASE_R: f64 = 86;

/// 0xAARRGGBB with alpha rescaled to `alpha_pct` (0-100), RGB untouched.
/// Used for card fills so only the background's opacity varies.
pub fn withAlpha(color: u32, alpha_pct: u32) u32 {
    const a: u32 = alpha_pct * 255 / 100;
    return (a << 24) | (color & 0x00FFFFFF);
}

/// 0xAARRGGBB with a fixed 8-bit alpha — for dimmed secondary text.
pub fn dim(color: u32, alpha_08: u32) u32 {
    return (alpha_08 << 24) | (color & 0x00FFFFFF);
}

pub fn lineH(font: *const font_mod.Font) i64 {
    return @as(i64, font.ascentPx()) + font.descentPx();
}

/// Card size per widget, measured from the font at startup so cards scale
/// with font size. Returns {width, height}.
pub fn cardSizeFor(id: WidgetId, font: *const font_mod.Font) [2]u32 {
    const lh: i64 = lineH(font);
    return switch (id) {
        .clock => .{ 190, @intCast(2 * CARD_PAD + 2 * lh + ROW_GAP) },
        .weather => .{ 170, @intCast(2 * CARD_PAD + lh) },
        .media => .{ @intCast(MEDIA_W), @intCast(2 * CARD_PAD + MEDIA_COVER + MEDIA_HEAD_GAP + MEDIA_PROG_H + MEDIA_TIME_GAP + lh + MEDIA_CTRL_GAP + lh) },
        .system => .{ 190, @intCast(2 * CARD_PAD + 3 * lh + 2 * ROW_GAP + 2 * BAR_H) },
        .calendar => .{ @intCast(CAL_W), @intCast(2 * CARD_PAD + 3 * lh + CAL_HEAD_GAP + CAL_WD_GAP + CAL_ROWS * CAL_CELL_H + CAL_FOOT_GAP) },
        // Fixed-size: the watch is drawn from its own geometry, not the font.
        .watch => .{ @intCast(WATCH_W), @intCast(WATCH_H) },
    };
}

/// Drawing context handed to a widget's paint: the FULL surface buffer plus
/// font/theme. All coordinates are surface-absolute (the host paints every
/// widget into the same buffer), and the host has already drawn the card
/// background behind each widget's rect before calling paint.
pub const Canvas = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    font: *font_mod.Font,
    theme: *const Theme,

    /// Straight-alpha OVER blend of a 0xAARRGGBB src onto dst, preserving
    /// dst alpha — cards are translucent, so glyph coverage must composite
    /// instead of assuming an opaque backdrop like the bar can.
    fn blendOver(dst: u32, src: u32) u32 {
        const sa: u32 = (src >> 24) & 0xFF;
        if (sa == 255) return src;
        if (sa == 0) return dst;
        const da: u32 = (dst >> 24) & 0xFF;
        const oa = sa + (da * (255 - sa)) / 255;
        if (oa == 0) return 0;
        const sr = (src >> 16) & 0xFF;
        const sg = (src >> 8) & 0xFF;
        const sb = src & 0xFF;
        const dr = (dst >> 16) & 0xFF;
        const dg = (dst >> 8) & 0xFF;
        const db = dst & 0xFF;
        const r = (sr * sa + (dr * da * (255 - sa)) / 255) / oa;
        const g = (sg * sa + (dg * da * (255 - sa)) / 255) / oa;
        const b = (sb * sa + (db * da * (255 - sa)) / 255) / oa;
        return (oa << 24) | (r << 16) | (g << 8) | b;
    }

    pub fn fillRect(self: Canvas, x0: i64, y0: i64, w: u64, h: u64, color: u32) void {
        const x_start = @max(x0, 0);
        const y_start = @max(y0, 0);
        const x_end = @min(x0 + @as(i64, @intCast(w)), @as(i64, @intCast(self.width)));
        const y_end = @min(y0 + @as(i64, @intCast(h)), @as(i64, @intCast(self.height)));
        if (x_end <= x_start or y_end <= y_start) return;
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width ..][0..self.width];
            var x = x_start;
            while (x < x_end) : (x += 1) {
                row[@intCast(x)] = blendOver(row[@intCast(x)], color);
            }
        }
    }

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

    /// Fills a rounded card with `fill` (already alpha-scaled) plus a 1px
    /// rounded border in `border`.
    pub fn card(self: Canvas, r: Rect, fill: u32, border: u32) void {
        const radius: i64 = @intCast(@min(self.theme.radius_px, @min(r.w, r.h) / 2));
        const l: i64 = r.x;
        const t: i64 = r.y;
        const w: i64 = @intCast(r.w);
        const h: i64 = @intCast(r.h);
        const inner_r = if (radius > 0) radius - 1 else 0;
        const x_start = @max(l, 0);
        const x_end = @min(l + w, @as(i64, @intCast(self.width)));
        const y_start = @max(t, 0);
        const y_end = @min(t + h, @as(i64, @intCast(self.height)));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width ..][0..self.width];
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const idx: usize = @intCast(x);
                if (!insideRounded(x, y, l, t, w, h, radius)) continue;
                const in_inner = insideRounded(x, y, l + 1, t + 1, w - 2, h - 2, inner_r);
                row[idx] = blendOver(row[idx], if (in_inner) fill else border);
            }
        }
    }

    /// Sum of each codepoint's advance width in `text`.
    pub fn textWidth(self: Canvas, text: []const u8) i64 {
        var total: i64 = 0;
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            total += (self.font.glyph(cp) catch continue).advance_x;
        }
        return total;
    }

    /// Draws `text` with its pen origin at (`x`, baseline `baseline_y`),
    /// alpha-blending glyph coverage over whatever the card underneath left.
    /// Returns the total advance width.
    pub fn drawText(self: Canvas, x: i64, baseline_y: i64, text: []const u8, color: u32) i64 {
        var pen: i64 = x;
        var i: usize = 0;
        while (nextUtf8Codepoint(text, &i)) |cp| {
            const g = self.font.glyph(cp) catch continue;
            const x0 = pen + g.bitmap_left;
            const y0 = baseline_y - g.bitmap_top;
            for (0..g.height) |row_off| {
                for (0..g.width) |col_off| {
                    const coverage = g.pixels[row_off * g.width + col_off];
                    if (coverage == 0) continue;
                    const px = x0 + @as(i64, @intCast(col_off));
                    const py = y0 + @as(i64, @intCast(row_off));
                    if (px < 0 or py < 0) continue;
                    const pxu: usize = @intCast(px);
                    const pyu: usize = @intCast(py);
                    if (pxu >= self.width or pyu >= self.height) continue;
                    // Glyph coverage is the glyph's alpha: 0xAARRGGBB src with
                    // A=coverage and RGB=text color (straight alpha).
                    const src = (@as(u32, coverage) << 24) | (color & 0x00FFFFFF);
                    self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
                }
            }
            pen += g.advance_x;
        }
        return pen - x;
    }

    /// Blits straight-alpha RGBA bytes (`w*h*4` row-major) with a rounded-
    /// corner mask — the media cover art over its tile. Per-pixel OVER blend
    /// like drawText, so translucent PNG edges composite instead of punching
    /// holes to the wallpaper.
    pub fn blitRgba(self: Canvas, x: i64, y: i64, w: u64, h: u64, rgba: []const u8, radius: i64) void {
        const iw: i64 = @intCast(w);
        const ih: i64 = @intCast(h);
        var row: u64 = 0;
        while (row < h) : (row += 1) {
            var col: u64 = 0;
            while (col < w) : (col += 1) {
                const o = (row * w + col) * 4;
                const a: u32 = rgba[o + 3];
                if (a == 0) continue;
                const px = x + @as(i64, @intCast(col));
                const py = y + @as(i64, @intCast(row));
                if (px < 0 or py < 0) continue;
                const pxu: usize = @intCast(px);
                const pyu: usize = @intCast(py);
                if (pxu >= self.width or pyu >= self.height) continue;
                if (!insideRounded(px, py, x, y, iw, ih, radius)) continue;
                const src = (a << 24) | (@as(u32, rgba[o]) << 16) | (@as(u32, rgba[o + 1]) << 8) | rgba[o + 2];
                self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
            }
        }
    }

    /// A float-space point — the anti-aliased primitives below take arrays
    /// of these.
    pub const FPt = struct { x: f64, y: f64 };

    /// Alpha-blend `color` at (x, y) with fractional coverage `cov`
    /// (0..1) — shared exit for the AA primitives: `cov` becomes the
    /// source's alpha, then the usual straight-alpha OVER blend.
    fn blendCov(self: Canvas, x: i64, y: i64, color: u32, cov: f64) void {
        if (cov <= 0.0) return;
        if (x < 0 or y < 0) return;
        const pxu: usize = @intCast(x);
        const pyu: usize = @intCast(y);
        if (pxu >= self.width or pyu >= self.height) return;
        const a: f64 = @floatFromInt((color >> 24) & 0xFF);
        const eff: u32 = @intFromFloat(@min(1.0, cov) * a);
        if (eff == 0) return;
        const src = (eff << 24) | (color & 0x00FFFFFF);
        self.pixels[pyu * self.width + pxu] = blendOver(self.pixels[pyu * self.width + pxu], src);
    }

    /// Anti-aliased filled circle: solid inside, one-pixel feather at the
    /// rim from the signed distance to it. The case and dial edges lean on
    /// this — at 172px across, hard-edged stair-stepping would be obvious.
    pub fn fillCircleAA(self: Canvas, cx: f64, cy: f64, rad: f64, color: u32) void {
        const x0: i64 = @intFromFloat(@floor(cx - rad - 1.0));
        const x1: i64 = @intFromFloat(@ceil(cx + rad + 1.0));
        const y0: i64 = @intFromFloat(@floor(cy - rad - 1.0));
        const y1: i64 = @intFromFloat(@ceil(cy + rad + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                self.blendCov(x, y, color, rad + 0.5 - dist);
            }
        }
    }

    /// AA-filled ring (annulus) — bezels and the stepped edge where the
    /// case drops into the dial. Coverage is the product of both rims'.
    pub fn fillRingAA(self: Canvas, cx: f64, cy: f64, rad_in: f64, rad_out: f64, color: u32) void {
        const x0: i64 = @intFromFloat(@floor(cx - rad_out - 1.0));
        const x1: i64 = @intFromFloat(@ceil(cx + rad_out + 1.0));
        const y0: i64 = @intFromFloat(@floor(cy - rad_out - 1.0));
        const y1: i64 = @intFromFloat(@ceil(cy + rad_out + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                self.blendCov(x, y, color, @min(rad_out + 0.5 - dist, dist - (rad_in - 0.5)));
            }
        }
    }

    /// AA-filled convex polygon (either winding): per-pixel coverage from
    /// the distance to the nearest edge. This is how rotated index batons
    /// and the sweeping hands stay smooth at any angle.
    pub fn fillConvex(self: Canvas, pts: []const FPt, color: u32) void {
        if (pts.len < 3) return;
        var minx = pts[0].x;
        var maxx = pts[0].x;
        var miny = pts[0].y;
        var maxy = pts[0].y;
        for (pts[1..]) |p| {
            minx = @min(minx, p.x);
            maxx = @max(maxx, p.x);
            miny = @min(miny, p.y);
            maxy = @max(maxy, p.y);
        }
        // Signed area picks up the winding; flip distances so "inside" is
        // positive either way.
        var area: f64 = 0;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p.x * q.y - q.x * p.y;
        }
        const orient: f64 = if (area >= 0) 1.0 else -1.0;
        const x0: i64 = @intFromFloat(@floor(minx - 1.0));
        const x1: i64 = @intFromFloat(@ceil(maxx + 1.0));
        const y0: i64 = @intFromFloat(@floor(miny - 1.0));
        const y1: i64 = @intFromFloat(@ceil(maxy + 1.0));
        var y = @max(y0, 0);
        while (y <= y1) : (y += 1) {
            var x = @max(x0, 0);
            while (x <= x1) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                var min_d: f64 = std.math.floatMax(f64);
                for (pts, 0..) |p, i| {
                    const q = pts[(i + 1) % pts.len];
                    const ex = q.x - p.x;
                    const ey = q.y - p.y;
                    const len = @sqrt(ex * ex + ey * ey);
                    if (len == 0.0) continue;
                    const cross = (ex * (py - p.y) - ey * (px - p.x)) * orient;
                    min_d = @min(min_d, cross / len);
                }
                self.blendCov(x, y, color, min_d + 0.5);
            }
        }
    }
};

// --- UTF-8 plumbing (ported from the bar) ---------------------------------

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
    i.* += 1; // malformed lead byte — skip as a single byte
    return 0x20;
}

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

/// Maps wttr.in's emoji (Miscellaneous Symbols / Emoji blocks — mostly *not*
/// covered by the Nerd Font) to an equivalent icon from the Nerd Font's
/// weather-icons pack (U+E300-U+E3E3, verified present).
fn wttrIconFor(cp: u32) ?u32 {
    return switch (cp) {
        0x2600 => 0xE30D, // ☀ sunny/clear
        0x26C5 => 0xE302, // ⛅ partly cloudy
        0x2601 => 0xE335, // ☁ cloudy
        0x1F326 => 0xE304, // 🌦 partly cloudy w/ rain
        0x1F324 => 0xE304, // 🌤 sun behind small cloud
        0x1F325 => 0xE302, // 🌥 sun behind cloud (wttr.in uses this too)
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

// --- spawn helper (ported from the bar's spawnDetached) -------------------

const libc_proc = struct {
    // fork() is kept as a private helper inside std.c — bind it ourselves.
    extern "c" fn fork() c_int;
};

/// Runs `command` through `sh -c`, detached via the standard double-fork so
/// it survives us and doesn't leave a zombie.
fn spawnDetached(command: [:0]const u8) void {
    const pid = libc_proc.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr, null };
            _ = std.c.execve("/bin/sh", &argv, std.c.environ);
            std.c._exit(127);
        }
        std.c._exit(0);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

// --- shared data-fetch plumbing ------------------------------------------
//
// Spawns a short-lived child (curl, playerctl) and captures its stdout over
// a pipe without blocking the main loop — the same PolledCommand pattern the
// bar uses for weather/pacman/mpris. `pending_fd` (when >= 0) is an fd in
// the host's poll() set; the widget calls onReadable when poll says it's
// readable.

fn setCloexec(fd: posix.fd_t) void {
    _ = std.c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}

pub const Fetcher = struct {
    // Sized for the largest payload any widget pulls down: the calendar's
    // holiday JSON (a year of entries runs ~7 KB).
    read_buf: [10240]u8 = undefined,
    read_len: usize = 0,
    pending_fd: posix.fd_t = -1,

    pub fn busy(self: *const Fetcher) bool {
        return self.pending_fd >= 0;
    }

    pub fn fd(self: *const Fetcher) posix.fd_t {
        return self.pending_fd;
    }

    /// Runs `argv` (execve-style) with its stdout piped to read_fd, which we
    /// keep. No-op while a previous fetch is still in flight.
    pub fn start(self: *Fetcher, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
        if (self.pending_fd >= 0) return;
        self.read_len = 0;

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
            _ = std.c.execve(path, argv, std.c.environ);
            std.c._exit(127);
        }
        _ = posix.system.close(write_fd);
        self.pending_fd = read_fd;
    }

    /// Call when poll() reports pending_fd readable. Returns how many bytes
    /// were copied into `out` once the fetch is complete (EOF), or 0 while
    /// still in flight.
    pub fn onReadable(self: *Fetcher, out: []u8) usize {
        var chunk: [256]u8 = undefined;
        const n = posix.read(self.pending_fd, &chunk) catch return 0;
        if (n == 0) {
            const trimmed = std.mem.trim(u8, self.read_buf[0..self.read_len], " \t\r\n");
            const copy_len = @min(trimmed.len, out.len);
            @memcpy(out[0..copy_len], trimmed[0..copy_len]);
            return copy_len;
        }
        const copy_len = @min(n, self.read_buf.len - self.read_len);
        @memcpy(self.read_buf[self.read_len..][0..copy_len], chunk[0..copy_len]);
        self.read_len += copy_len;
        return 0;
    }

    pub fn closeFd(self: *Fetcher) void {
        _ = posix.system.close(self.pending_fd);
        self.pending_fd = -1;
    }
};

// --- clock ----------------------------------------------------------------

const libc_time = struct {
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
    extern "c" fn mktime(tm: *Tm) i64;

    // Layout matches glibc's `struct tm` (tm_gmtoff/tm_zone tail is a glibc
    // extension, present on Linux x86_64).
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

const DAYS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTHS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const MONTHS_FULL = [_][]const u8{
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};
const WD_ROW = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

// --- proleptic-Gregorian date math ----------------------------------------
//
// Pure integer conversions (Howard Hinnant's days_from_civil / civil_from_
// days): no timezone surprises, no mktime round-trips for calendar layout.
// mktime is still used where wall-clock matters (notification due times).

fn daysFromCivil(y: i32, m: u32, d: u32) i64 {
    const yy: i64 = y - @as(i32, if (m <= 2) 1 else 0);
    const era: i64 = @divFloor(yy, 400);
    const yoe: i64 = yy - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) @as(i64, @intCast(m)) - 3 else @as(i64, @intCast(m)) + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, @intCast(d)) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { y: i32, m: u8, d: u8 } {
    const z = z0 + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = @intCast(if (m <= 2) y + 1 else y), .m = @intCast(m), .d = @intCast(d) };
}

/// Weekday of an epoch day: 0 = Sunday (day 0 = 1970-01-01 = Thursday).
fn wdayOf(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

/// Monday-first column (0..6) for a Sunday-based weekday.
fn monCol(wd: u8) u8 {
    return @mod(wd + 6, 7);
}

fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        else => 30,
    };
}

pub const ClockWidget = struct {
    main_buf: [24]u8 = undefined,
    main_len: usize = 0,
    sub_buf: [24]u8 = undefined,
    sub_len: usize = 0,

    pub const interval_ms: i64 = 1000;

    pub fn update(self: *ClockWidget) void {
        const now = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now, &tm);
        const mday: u32 = @intCast(tm.mday);
        const hour24: u32 = @intCast(tm.hour);
        const min: u32 = @intCast(tm.min);
        const sec: u32 = @intCast(tm.sec);
        const wday: usize = @intCast(tm.wday);
        const mon: usize = @intCast(tm.mon);
        const main = std.fmt.bufPrint(&self.main_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour24, min, sec }) catch self.main_buf[0..0];
        const sub = std.fmt.bufPrint(&self.sub_buf, "{s} {d} {s}", .{ DAYS[wday % 7], mday, MONTHS[mon % 12] }) catch self.sub_buf[0..0];
        self.main_len = main.len;
        self.sub_len = sub.len;
    }

    pub fn paint(self: *const ClockWidget, c: Canvas, r: Rect) void {
        const lh = lineH(c.font);
        const padx: i64 = r.x + CARD_PAD;
        const b1 = r.y + CARD_PAD + c.font.ascentPx();
        const b2 = b1 + lh + ROW_GAP;
        _ = c.drawText(padx, b1, self.main_buf[0..self.main_len], c.theme.text_color);
        _ = c.drawText(padx, b2, self.sub_buf[0..self.sub_len], dim(c.theme.text_color, 0xCC));
    }

    pub fn click(self: *const ClockWidget) void {
        _ = self;
    }
};

// --- weather --------------------------------------------------------------

const WEATHER_URL = "https://wttr.in/?format=1";

pub const WeatherWidget = struct {
    icon_buf: [8]u8 = undefined,
    icon_len: usize = 0,
    temp_buf: [24]u8 = undefined,
    temp_len: usize = 0,
    fetch: Fetcher = .{},
    fetched: bool = false,

    pub const interval_ms: i64 = 1200_000; // 20 min, matching the bar

    pub fn refresh(self: *WeatherWidget) void {
        if (self.fetch.busy()) return;
        var argv = [_:null]?[*:0]const u8{ "env", "curl", "-s", WEATHER_URL, null };
        self.fetch.start("/usr/bin/env", &argv);
    }

    /// Call when the fetch pipe is readable. Returns true when the fetch
    /// finished (state may have changed).
    pub fn onPipe(self: *WeatherWidget) bool {
        var out: [160]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        const trimmed = std.mem.trim(u8, out[0..n], " \t\r\n");
        self.fetched = trimmed.len > 0;
        if (!self.fetched) return true;

        var i: usize = 0;
        const cp = nextUtf8Codepoint(trimmed, &i) orelse {
            self.icon_len = 0;
            const t = trimmed[0..@min(trimmed.len, self.temp_buf.len)];
            @memcpy(self.temp_buf[0..t.len], t);
            self.temp_len = t.len;
            return true;
        };
        // Skip variation-selector/ZWJ codepoints attached to the same emoji
        // cluster before the plain text begins — even when the lead emoji is
        // unmapped, so a stray U+FE0F can't leak into the temp text (it has
        // no glyph and would render as tofu).
        while (i < trimmed.len) {
            const save = i;
            const nc = nextUtf8Codepoint(trimmed, &i) orelse break;
            if (nc == 0xFE0F or nc == 0x200D) continue;
            i = save;
            break;
        }
        if (wttrIconFor(cp)) |ic| {
            self.icon_len = utf8Encode(ic, &self.icon_buf);
        } else {
            self.icon_len = 0;
        }
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        const rest = trimmed[i..];
        const t = rest[0..@min(rest.len, self.temp_buf.len)];
        @memcpy(self.temp_buf[0..t.len], t);
        self.temp_len = t.len;
        return true;
    }

    pub fn paint(self: *const WeatherWidget, c: Canvas, r: Rect) void {
        const b = r.y + CARD_PAD + c.font.ascentPx();
        const padx: i64 = r.x + CARD_PAD;
        if (!self.fetched) {
            _ = c.drawText(padx, b, "…", c.theme.text_color);
            return;
        }
        const icon_w = c.textWidth(self.icon_buf[0..self.icon_len]);
        _ = c.drawText(padx, b, self.icon_buf[0..self.icon_len], c.theme.border_color);
        _ = c.drawText(padx + icon_w + 8, b, self.temp_buf[0..self.temp_len], c.theme.text_color);
    }

    pub fn click(self: *const WeatherWidget) void {
        _ = self;
        var url_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&url_buf, "xdg-open https://wttr.in/", .{}) catch return;
        spawnDetached(cmd);
    }
};

// --- monotonic clock (same hand-bound libc approach as main.zig) -----------

const libc_mono = struct {
    extern "c" fn clock_gettime(clockid: c_int, tp: *posix.timespec) c_int;
};

/// Monotonic milliseconds — only deltas are meaningful. Used to interpolate
/// the media progress bar between 2 s metadata refetches.
fn monoMs() i64 {
    var tp: posix.timespec = undefined;
    if (libc_mono.clock_gettime(1, &tp) != 0) return 0; // 1 = CLOCK_MONOTONIC
    const sec: i64 = @intCast(tp.sec);
    const nsec: i64 = @intCast(tp.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

/// Truncates `text` with an ellipsis so it fits `max_w`, writing into `dst`
/// (which must hold text.len + 3). Returns the slice to draw.
fn fitText(c: Canvas, text: []const u8, max_w: i64, dst: []u8) []const u8 {
    if (c.textWidth(text) <= max_w) return text;
    const ell: []const u8 = "\u{2026}";
    const ell_w = c.textWidth(ell);
    var end: usize = 0;
    var w: i64 = 0;
    var j: usize = 0;
    while (nextUtf8Codepoint(text, &j)) |cp| {
        const adv = (c.font.glyph(cp) catch continue).advance_x;
        if (w + adv + ell_w > max_w) break;
        w += adv;
        end = j;
    }
    const total = end + ell.len;
    if (total > dst.len) return text[0..0];
    @memcpy(dst[0..end], text[0..end]);
    @memcpy(dst[end..total], ell);
    return dst[0..total];
}

/// Formats microseconds as m:ss into `buf`.
fn fmtDur(us: u64, buf: []u8) []const u8 {
    const s = us / 1_000_000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch buf[0..0];
}

// --- media -----------------------------------------------------------------

const MPRIS_SCRIPT = "playerctl metadata --format 'M\x1f{{status}}\x1f{{artist}}\x1f{{title}}\x1f{{position}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}' 2>/dev/null; printf '\\nS:'; playerctl shuffle 2>/dev/null; printf '\\nL:'; playerctl loop 2>/dev/null; printf '\\n'";

/// Where downloaded http(s) cover art lands before decode. Single fixed
/// path — fetches are strictly sequential, so nothing races it.
const ART_CACHE: [:0]const u8 = "/tmp/simpbar-shell-art.bin";

pub const MediaLoop = enum { none, track, playlist };
pub const MediaControl = enum { shuffle, prev, toggle, next, loop };
pub const MediaPhase = enum { meta, art };

pub const MediaWidget = struct {
    artist_buf: [128]u8 = undefined,
    artist_len: usize = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    has_track: bool = false,
    playing: bool = false,
    shuffle_on: bool = false,
    loop_mode: MediaLoop = .none,
    pos_us: u64 = 0,
    len_us: u64 = 0,
    stamp_ms: i64 = 0,
    next_fetch_ms: i64 = 0,
    painted_sec: i64 = -1,
    /// Cover-art state. `art_url_*` is the last MPRIS artUrl seen; a new URL
    /// resets to fetch again, an unchanged one is never re-downloaded.
    art_url_buf: [512]u8 = undefined,
    art_url_len: usize = 0,
    art: enum { none, ready, failed } = .none,
    art_rgba: [art_mod.COVER_BYTES]u8 = undefined,
    art_w: u8 = 0,
    art_h: u8 = 0,
    /// Which fetch the shared pipe is carrying: metadata text, or the curl
    /// completion marker for a cover-art download.
    phase: MediaPhase = .meta,
    fetch: Fetcher = .{},

    // Progress repaints while playing; the metadata refetch below runs every
    // 2 s (gated by next_fetch_ms) so one playerctl child per second isn't
    // spawned just to move the bar.
    pub const interval_ms: i64 = 1000;

    pub fn refresh(self: *MediaWidget) void {
        if (self.fetch.busy()) return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", MPRIS_SCRIPT, null };
        self.fetch.start("/bin/sh", &argv);
    }

    /// Position at `now_ms`, interpolating from the last fetch while playing
    /// and clamping at the track length.
    fn displayPosUs(self: *const MediaWidget, now_ms: i64) u64 {
        if (!self.playing or self.stamp_ms == 0 or self.len_us == 0) return self.pos_us;
        const delta_ms: u64 = if (now_ms > self.stamp_ms) @intCast(now_ms - self.stamp_ms) else 0;
        const remaining = if (self.pos_us >= self.len_us) 0 else self.len_us - self.pos_us;
        return self.pos_us + @min(delta_ms * 1000, remaining);
    }

    /// Cadence tick — refetch metadata every 2 s, repaint every second while
    /// the position display advances. Returns true when pixels changed.
    pub fn tick(self: *MediaWidget) bool {
        const now = monoMs();
        if (now >= self.next_fetch_ms) {
            self.refresh();
            self.next_fetch_ms = now + 2000;
        }
        if (!self.has_track or !self.playing or self.len_us == 0) return false;
        const sec: i64 = @intCast(self.displayPosUs(now) / 1_000_000);
        if (sec == self.painted_sec) return false;
        self.painted_sec = sec;
        return true;
    }

    /// file:// MPRIS art URL -> filesystem path, %XX-decoded, NUL-terminated
    /// for the decoder. Returns null when the URL isn't usable.
    fn fileUrlPath(url: []const u8, dst: []u8) ?[:0]u8 {
        const prefix = "file://";
        if (!std.mem.startsWith(u8, url, prefix)) return null;
        var rest = url[prefix.len..];
        if (std.mem.startsWith(u8, rest, "localhost")) rest = rest["localhost".len..];
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            if (n + 1 >= dst.len) return null;
            if (rest[i] == '%' and i + 2 < rest.len) {
                const hi = std.fmt.charToDigit(rest[i + 1], 16) catch null;
                const lo = std.fmt.charToDigit(rest[i + 2], 16) catch null;
                if (hi != null and lo != null) {
                    dst[n] = hi.? * 16 + lo.?;
                    n += 1;
                    i += 3;
                    continue;
                }
            }
            dst[n] = rest[i];
            n += 1;
            i += 1;
        }
        dst[n] = 0;
        return dst[0..n :0];
    }

    /// Decodes `path` into the cover buffer. Returns true with dims stored on
    /// success, false (placeholder kept) on any failure.
    fn loadArtFile(self: *MediaWidget, path: [:0]const u8) bool {
        if (art_mod.decodeCover(path, &self.art_rgba)) |dims| {
            self.art_w = dims.w;
            self.art_h = dims.h;
            self.art = .ready;
            return true;
        }
        self.art = .failed;
        return false;
    }

    /// Reconciles cover art after a metadata fetch: new URL -> decode now for
    /// file://, queue a curl download for http(s), placeholder otherwise.
    /// Unchanged URLs are never re-fetched.
    fn updateArt(self: *MediaWidget, art_url: []const u8) void {
        if (std.mem.eql(u8, art_url, self.art_url_buf[0..self.art_url_len])) return;
        const u = art_url[0..@min(art_url.len, self.art_url_buf.len)];
        @memcpy(self.art_url_buf[0..u.len], u);
        self.art_url_len = u.len;
        self.art = .none;
        self.art_w = 0;
        self.art_h = 0;
        if (u.len == 0) return;
        var path_buf: [512]u8 = undefined;
        if (fileUrlPath(u, &path_buf)) |path| {
            _ = self.loadArtFile(path);
            return;
        }
        const http = std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://");
        if (!http or std.mem.indexOfScalar(u8, u, '\'') != null) {
            self.art = .failed; // data: URIs and unquotable URLs stay placeholders
            return;
        }
        var script: [1024]u8 = undefined;
        const s = std.fmt.bufPrintZ(&script, "curl -s -o {s} -- '{s}' && printf art-ok || printf art-fail", .{ ART_CACHE, u }) catch {
            self.art = .failed;
            return;
        };
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .art;
    }

    /// Call when the fetch pipe is readable. Returns true when the fetch
    /// finished (state may have changed).
    pub fn onPipe(self: *MediaWidget) bool {
        var out: [1024]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        // Cover-art download finished: the marker (printed after curl
        // exits, so the cache file is complete) says whether curl itself
        // succeeded; the decode can still fail on format.
        if (self.phase == .art) {
            self.phase = .meta;
            const marker = std.mem.trim(u8, out[0..n], " \t\r\n");
            if (std.mem.eql(u8, marker, "art-ok")) {
                _ = self.loadArtFile(ART_CACHE);
            } else {
                self.art = .failed;
            }
            return true;
        }
        const now = monoMs();
        var meta: ?[]const u8 = null;
        var shuffle_s: ?[]const u8 = null;
        var loop_s: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, out[0..n], '\n');
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0) continue;
            if (t.len > 1 and t[0] == 'M' and t[1] == 0x1F) {
                meta = t[2..];
            } else if (std.mem.startsWith(u8, t, "S:")) {
                shuffle_s = std.mem.trim(u8, t[2..], " \t");
            } else if (std.mem.startsWith(u8, t, "L:")) {
                loop_s = std.mem.trim(u8, t[2..], " \t");
            }
        }
        if (meta == null) {
            self.has_track = false;
            self.playing = false;
            self.shuffle_on = false;
            self.loop_mode = .none;
            self.pos_us = 0;
            self.len_us = 0;
            self.stamp_ms = 0;
            self.painted_sec = -1;
            self.art = .none;
            self.art_url_len = 0;
            return true;
        }
        var parts = std.mem.splitScalar(u8, meta.?, 0x1F);
        const status = std.mem.trim(u8, parts.next() orelse "", " \t");
        const artist = std.mem.trim(u8, parts.next() orelse "", " \t");
        const title = std.mem.trim(u8, parts.next() orelse "", " \t");
        const pos_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const len_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const art_s = std.mem.trim(u8, parts.next() orelse "", " \t");
        const a = artist[0..@min(artist.len, self.artist_buf.len)];
        @memcpy(self.artist_buf[0..a.len], a);
        self.artist_len = a.len;
        const t = title[0..@min(title.len, self.title_buf.len)];
        @memcpy(self.title_buf[0..t.len], t);
        self.title_len = t.len;
        self.playing = std.ascii.eqlIgnoreCase(status, "Playing");
        const paused = std.ascii.eqlIgnoreCase(status, "Paused");
        self.pos_us = std.fmt.parseInt(u64, pos_s, 10) catch 0;
        self.len_us = std.fmt.parseInt(u64, len_s, 10) catch 0;
        if (shuffle_s) |s| {
            if (std.ascii.eqlIgnoreCase(s, "On")) self.shuffle_on = true //
            else self.shuffle_on = false;
        } else self.shuffle_on = false;
        if (loop_s) |s| {
            if (std.ascii.eqlIgnoreCase(s, "Track")) self.loop_mode = .track //
            else if (std.ascii.eqlIgnoreCase(s, "Playlist")) self.loop_mode = .playlist //
            else self.loop_mode = .none;
        } else self.loop_mode = .none;
        self.has_track = self.title_len > 0 or self.artist_len > 0 or self.len_us > 0 or self.playing or paused;
        if (!self.has_track) {
            self.pos_us = 0;
            self.len_us = 0;
            self.stamp_ms = 0;
            self.painted_sec = -1;
            self.art = .none;
            self.art_url_len = 0;
            return true;
        }
        self.updateArt(art_s);
        self.stamp_ms = now;
        self.painted_sec = @intCast(self.displayPosUs(now) / 1_000_000);
        return true;
    }

    /// Absolute layout of the media card's rows, shared by paint and click
    /// hit-testing so the control zones always match the drawn glyphs.
    const MediaLayout = struct {
        inner_x: i64,
        inner_w: i64,
        title_b: i64,
        artist_b: i64,
        prog_y: i64,
        times_b: i64,
        ctrl_top: i64,
        ctrl_base: i64,
        ctrl_bottom: i64,
    };

    fn mediaLayout(r: Rect, font: *font_mod.Font) MediaLayout {
        const ascent: i64 = font.ascentPx();
        const descent: i64 = font.descentPx();
        const inner_x = r.x + CARD_PAD;
        const inner_w = @as(i64, @intCast(r.w)) - 2 * CARD_PAD;
        const title_b = r.y + CARD_PAD + ascent;
        const artist_b = title_b + ascent + descent + MEDIA_TITLE_GAP;
        const prog_y = r.y + CARD_PAD + MEDIA_COVER + MEDIA_HEAD_GAP;
        const times_b = prog_y + MEDIA_PROG_H + MEDIA_TIME_GAP + ascent;
        const ctrl_top = times_b + descent + MEDIA_CTRL_GAP;
        return .{
            .inner_x = inner_x,
            .inner_w = inner_w,
            .title_b = title_b,
            .artist_b = artist_b,
            .prog_y = prog_y,
            .times_b = times_b,
            .ctrl_top = ctrl_top,
            .ctrl_base = ctrl_top + ascent,
            .ctrl_bottom = ctrl_top + ascent + descent,
        };
    }

    /// Which transport control (if any) sits under surface point (px, py).
    /// Slots run shuffle / prev / play-pause / next / repeat left to right.
    fn controlAt(r: Rect, font: *font_mod.Font, px: i32, py: i32) ?MediaControl {
        const l = mediaLayout(r, font);
        if (py < l.ctrl_top or py > l.ctrl_bottom) return null;
        if (px < l.inner_x or px >= l.inner_x + l.inner_w) return null;
        return switch (@divTrunc((@as(i64, px) - l.inner_x) * 5, l.inner_w)) {
            0 => .shuffle,
            1 => .prev,
            2 => .toggle,
            3 => .next,
            4 => .loop,
            else => null,
        };
    }

    pub fn paint(self: *const MediaWidget, c: Canvas, r: Rect) void {
        if (!self.has_track) {
            const b = r.y + CARD_PAD + c.font.ascentPx();
            _ = c.drawText(r.x + CARD_PAD, b, "no media playing", dim(c.theme.text_color, 0x99));
            return;
        }
        const l = mediaLayout(r, c.font);
        const ascent: i64 = c.font.ascentPx();
        const descent: i64 = c.font.descentPx();

        // Cover tile — no image decoder in the shell, so a rounded tile with
        // a music glyph stands in for album art (mpris:artUrl is fetched but
        // not rendered).
        const tile = Rect{
            .x = @intCast(l.inner_x),
            .y = @intCast(r.y + CARD_PAD),
            .w = @intCast(MEDIA_COVER),
            .h = @intCast(MEDIA_COVER),
        };
        c.card(tile, c.theme.hover_color, c.theme.border_color);
        if (self.art == .ready and self.art_w > 0 and self.art_h > 0) {
            // Real cover art, centered in the tile inside the 1px border
            // ring, masked to the tile's inner corner radius.
            const aw: i64 = self.art_w;
            const ah: i64 = self.art_h;
            const tile_r: i64 = @min(@as(i64, @intCast(c.theme.radius_px)), MEDIA_COVER / 2);
            c.blitRgba(
                l.inner_x + @divTrunc(MEDIA_COVER - aw, 2),
                r.y + CARD_PAD + @divTrunc(MEDIA_COVER - ah, 2),
                @intCast(aw),
                @intCast(ah),
                self.art_rgba[0..@as(usize, self.art_w) * self.art_h * 4],
                if (tile_r > 0) tile_r - 1 else 0,
            );
        } else {
            const note: []const u8 = "\u{f001}";
            const note_w = c.textWidth(note);
            _ = c.drawText(
                l.inner_x + @divTrunc(MEDIA_COVER - note_w, 2),
                r.y + CARD_PAD + @divTrunc(MEDIA_COVER + ascent - descent, 2),
                note,
                dim(c.theme.text_color, 0xAA),
            );
        }

        // Title over artist, truncated to the space right of the cover.
        const text_x = l.inner_x + MEDIA_COVER + 10;
        const text_w = r.x + @as(i64, @intCast(r.w)) - CARD_PAD - text_x;
        var tclip: [300]u8 = undefined;
        var aclip: [160]u8 = undefined;
        const title = if (self.title_len > 0) self.title_buf[0..self.title_len] else "Unknown title";
        _ = c.drawText(text_x, l.title_b, fitText(c, title, text_w, &tclip), c.theme.text_color);
        if (self.artist_len > 0) {
            _ = c.drawText(text_x, l.artist_b, fitText(c, self.artist_buf[0..self.artist_len], text_w, &aclip), dim(c.theme.text_color, 0xCC));
        }

        // Progress bar with knob, elapsed left and remaining right.
        const pos = self.displayPosUs(monoMs());
        const clamped = @min(pos, self.len_us);
        const fill_w: u64 = if (self.len_us == 0) 0 else clamped * @as(u64, @intCast(l.inner_w)) / self.len_us;
        c.fillRect(l.inner_x, l.prog_y, @intCast(l.inner_w), @intCast(MEDIA_PROG_H), dim(c.theme.text_color, 0x44));
        if (fill_w > 0) c.fillRect(l.inner_x, l.prog_y, @intCast(fill_w), @intCast(MEDIA_PROG_H), c.theme.text_color);
        if (self.len_us > 0) {
            const kw: i64 = 7;
            const kx = std.math.clamp(l.inner_x + @as(i64, @intCast(fill_w)) - @divTrunc(kw, 2), l.inner_x, l.inner_x + l.inner_w - kw);
            c.fillRect(kx, l.prog_y - 1, @intCast(kw), @intCast(kw), c.theme.text_color);
        }
        var ebuf: [16]u8 = undefined;
        _ = c.drawText(l.inner_x, l.times_b, fmtDur(pos, &ebuf), dim(c.theme.text_color, 0xAA));
        var rbuf: [24]u8 = undefined;
        const right: []const u8 = if (self.len_us > 0) blk: {
            var tmp: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&rbuf, "-{s}", .{fmtDur(self.len_us - clamped, &tmp)}) catch rbuf[0..0];
        } else "--:--";
        _ = c.drawText(l.inner_x + l.inner_w - c.textWidth(right), l.times_b, right, dim(c.theme.text_color, 0xAA));

        // Transport controls: shuffle / prev / play-pause / next / repeat.
        // Font Awesome codepoints, all verified in the bundled Nerd Font.
        const glyphs = [_][]const u8{
            "\u{f074}", // shuffle
            "\u{f048}", // previous
            if (self.playing) "\u{f04c}" else "\u{f04b}", // pause / play
            "\u{f051}", // next
            "\u{f01e}", // repeat
        };
        var i: usize = 0;
        while (i < glyphs.len) : (i += 1) {
            const cx = l.inner_x + @divTrunc(l.inner_w * (2 * @as(i64, @intCast(i)) + 1), 10);
            const gw = c.textWidth(glyphs[i]);
            const col = switch (i) {
                0 => if (self.shuffle_on) c.theme.text_color else dim(c.theme.text_color, 0x66),
                4 => if (self.loop_mode != .none) c.theme.text_color else dim(c.theme.text_color, 0x66),
                else => c.theme.text_color,
            };
            _ = c.drawText(cx - @divTrunc(gw, 2), l.ctrl_base, glyphs[i], col);
        }
    }

    /// Left-click inside the card: transport controls act, anything else is a
    /// play-pause toggle like before. State flips optimistically; the next
    /// metadata refetch (<= 2 s) confirms it.
    pub fn clickAt(self: *MediaWidget, r: Rect, font: *font_mod.Font, px: i32, py: i32) void {
        const now = monoMs();
        if (self.has_track) {
            if (controlAt(r, font, px, py)) |ctl| {
                switch (ctl) {
                    .shuffle => {
                        spawnDetached("playerctl shuffle Toggle");
                        self.shuffle_on = !self.shuffle_on;
                    },
                    .prev => spawnDetached("playerctl previous"),
                    .toggle => {
                        spawnDetached("playerctl play-pause");
                        self.pos_us = self.displayPosUs(now);
                        self.playing = !self.playing;
                        self.stamp_ms = now;
                        self.painted_sec = @intCast(self.pos_us / 1_000_000);
                    },
                    .next => spawnDetached("playerctl next"),
                    .loop => {
                        const target: MediaLoop = switch (self.loop_mode) {
                            .none => .track,
                            .track => .playlist,
                            .playlist => .none,
                        };
                        const arg: []const u8 = switch (target) {
                            .none => "None",
                            .track => "Track",
                            .playlist => "Playlist",
                        };
                        var cmd_buf: [32]u8 = undefined;
                        const cmd = std.fmt.bufPrintZ(&cmd_buf, "playerctl loop {s}", .{arg}) catch return;
                        spawnDetached(cmd);
                        self.loop_mode = target;
                    },
                }
                self.next_fetch_ms = 0;
                return;
            }
        }
        spawnDetached("playerctl play-pause");
        self.next_fetch_ms = 0;
    }
};

// --- system monitor ---------------------------------------------------------

fn readFileInto(path: [:0]const u8, buf: []u8) usize {
    const raw_fd = posix.system.open(path, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return 0;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub const SystemWidget = struct {
    cpu_pct: u8 = 0,
    mem_pct: u8 = 0,
    load_buf: [12]u8 = undefined,
    load_len: usize = 0,
    prev_total: u64 = 0,
    prev_idle: u64 = 0,
    have_prev: bool = false,

    pub const interval_ms: i64 = 2000;

    fn updateCpu(self: *SystemWidget) void {
        var buf: [1024]u8 = undefined;
        const n = readFileInto("/proc/stat", &buf);
        if (n == 0) return;
        const text = buf[0..n];
        const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = text[0..line_end];
        var it = std.mem.tokenizeAny(u8, line, " ");
        _ = it.next() orelse return; // "cpu"
        var fields: [8]u64 = undefined;
        var count: usize = 0;
        while (it.next()) |tok| {
            if (count >= fields.len) break;
            fields[count] = std.fmt.parseInt(u64, tok, 10) catch 0;
            count += 1;
        }
        if (count < 2) return;
        const idle = fields[3] + fields[4];
        var total: u64 = 0;
        for (fields[0..count]) |f| total += f;
        if (self.have_prev and total > self.prev_total) {
            const dt = total - self.prev_total;
            const di = idle - self.prev_idle;
            const busy = dt - di;
            const pct: u64 = if (busy >= dt) 100 else (100 * busy) / dt;
            self.cpu_pct = @intCast(pct);
        }
        self.prev_total = total;
        self.prev_idle = idle;
        self.have_prev = true;
    }

    fn updateMem(self: *SystemWidget) void {
        var buf: [1024]u8 = undefined;
        const n = readFileInto("/proc/meminfo", &buf);
        if (n == 0) return;
        const text = buf[0..n];
        var total: u64 = 0;
        var available: u64 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (total != 0 and available != 0) break;
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total = parseKbAfterColon(line);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                available = parseKbAfterColon(line);
            }
        }
        if (total > 0 and available <= total) {
            self.mem_pct = @intCast((100 * (total - available)) / total);
        }
    }

    fn updateLoad(self: *SystemWidget) void {
        var buf: [128]u8 = undefined;
        const n = readFileInto("/proc/loadavg", &buf);
        if (n == 0) return;
        var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\n");
        const first = it.next() orelse return;
        const v = std.fmt.parseFloat(f32, first) catch return;
        const scaled: i64 = @intFromFloat(@round(v * 100.0));
        const whole: i64 = @divTrunc(scaled, 100);
        const frac: i64 = @mod(scaled, 100);
        // frac must be unsigned: Zig 0.16 fmt prints '+' for signed ints
        // under a width spec ("2.+98" instead of "2.98"). @mod keeps it
        // in [0,100) for any input sign, so the cast cannot overflow.
        const s = std.fmt.bufPrint(&self.load_buf, "{d}.{d:0>2}", .{ whole, @as(u32, @intCast(frac)) }) catch return;
        self.load_len = s.len;
    }

    pub fn refresh(self: *SystemWidget) void {
        self.updateCpu();
        self.updateMem();
        self.updateLoad();
    }

    fn drawBar(c: Canvas, x: i64, y: i64, w: i64, pct: u8) void {
        c.fillRect(x, y, @intCast(w), BAR_H, dim(c.theme.border_color, 0x70));
        const fill_w: i64 = @divTrunc(w * pct, 100);
        if (fill_w > 0) c.fillRect(x, y, @intCast(fill_w), BAR_H, c.theme.text_color);
    }

    pub fn paint(self: *const SystemWidget, c: Canvas, r: Rect) void {
        const padx: i64 = r.x + CARD_PAD;
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * CARD_PAD;
        const ascent: i64 = c.font.ascentPx();
        const b1 = r.y + CARD_PAD + ascent;
        _ = c.drawText(padx, b1, "CPU", c.theme.text_color);
        var pct_buf: [16]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, " {d}%", .{self.cpu_pct}) catch "";
        const cpu_x = padx + c.textWidth("CPU") + 6;
        _ = c.drawText(cpu_x, b1, pct_str, dim(c.theme.text_color, 0xCC));
        drawBar(c, padx, b1 + 4, inner_w, self.cpu_pct);

        const b2 = b1 + BAR_H + ROW_GAP + 4 + lineH(c.font);
        _ = c.drawText(padx, b2, "MEM", c.theme.text_color);
        const mem_str = std.fmt.bufPrint(&pct_buf, " {d}%", .{self.mem_pct}) catch "";
        _ = c.drawText(cpu_x, b2, mem_str, dim(c.theme.text_color, 0xCC));
        drawBar(c, padx, b2 + 4, inner_w, self.mem_pct);

        const b3 = b2 + BAR_H + ROW_GAP + 4 + lineH(c.font);
        _ = c.drawText(padx, b3, "LOAD", c.theme.text_color);
        _ = c.drawText(padx + c.textWidth("LOAD") + 6, b3, self.load_buf[0..self.load_len], dim(c.theme.text_color, 0xCC));
    }

    pub fn click(self: *const SystemWidget) void {
        _ = self;
    }
};

fn parseKbAfterColon(line: []const u8) u64 {
    const idx = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var it = std.mem.tokenizeAny(u8, line[idx + 1 ..], " \t");
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}

// --- calendar ---------------------------------------------------------------
//
// Month grid + reminders + public holidays. Two external touchpoints, both
// following the bar/shell conventions of spawning tiny helpers rather than
// growing in-process UI machinery:
//
//   * reminders live in a plain text file (~/.config/simpbar/reminders.txt,
//     one per line: "YYYY-MM-DD HH:MM [lead] text" — lead = days before the
//     date to notify, 0 = on the day, and optional for hand-written lines
//     (the rest of the line is the text). Editing goes through rofi when a day
//     is clicked; notifications through notify-send when a due time passes.
//   * holidays come from date.nager.at's free no-key API for a configurable
//     country (shell.json: holiday_country, holiday_region), colour-coded:
//     global public holidays in the bright accent, regional ones dimmed.

const MAX_HOLIDAYS: usize = 48;
const REM_MAX: usize = 48;
const NOTIFY_GRACE_S: i64 = 900; // deliver a due notification up to 15 min late

const Holiday = struct {
    m: u8,
    d: u8,
    global: bool,
    name_len: u8,
    name: [56]u8,
};

const Reminder = struct {
    y: i32,
    m: u8,
    d: u8,
    hh: u8,
    mm: u8,
    lead: u8,
    text_off: u16,
    text_len: u16,
    raw_len: u16,
    fired: bool,
    /// The exact file line — reloads carry `fired` across by matching this.
    raw: [176]u8,

    fn text(self: *const Reminder) []const u8 {
        return self.raw[self.text_off .. self.text_off + self.text_len];
    }
};

const CalPhase = enum { holidays, menu };

/// Parses "YYYY-MM-DD HH:MM [lead] text" into `out` (raw copy included).
/// The lead field is optional so hand-written lines like
/// "2026-10-20 10:00 PayDay" work: a non-numeric first token means the
/// text starts right there and the reminder notifies on the day (lead 0).
fn parseReminderLine(line: []const u8, out: *Reminder) bool {
    if (line.len < 18) return false;
    if (line[4] != '-' or line[7] != '-' or line[10] != ' ' or line[13] != ':' or line[16] != ' ') return false;
    if (line.len > out.raw.len) return false;
    const y = std.fmt.parseInt(i32, line[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u8, line[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, line[8..10], 10) catch return false;
    const hh = std.fmt.parseInt(u8, line[11..13], 10) catch return false;
    const mm = std.fmt.parseInt(u8, line[14..16], 10) catch return false;
    var i: usize = 17;
    while (i < line.len and line[i] != ' ') i += 1;
    const lead_opt: ?u8 = std.fmt.parseInt(u8, line[17..i], 10) catch null;
    if (lead_opt != null and (i >= line.len or i + 1 >= line.len)) return false; // lead but no text
    const lead = lead_opt orelse 0;
    var text_start: usize = if (lead_opt != null) i + 1 else 17;
    while (text_start < line.len and line[text_start] == ' ') text_start += 1;
    if (text_start >= line.len) return false; // text required
    if (y < 1970 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31) return false;
    if (hh > 23 or mm > 59 or lead > 60) return false;
    @memcpy(out.raw[0..line.len], line);
    out.raw_len = @intCast(line.len);
    out.y = y;
    out.m = m;
    out.d = d;
    out.hh = hh;
    out.mm = mm;
    out.lead = lead;
    out.text_off = @intCast(text_start);
    out.text_len = @intCast(line.len - text_start);
    out.fired = false;
    return true;
}

/// Notification moment for a reminder: its date shifted back `lead` days, at
/// HH:MM local time (mktime — wall-clock, so DST resolves normally).
fn dueEpoch(r: Reminder) i64 {
    const c = civilFromDays(daysFromCivil(r.y, r.m, r.d) - @as(i64, r.lead));
    var tm: libc_time.Tm = std.mem.zeroes(libc_time.Tm);
    tm.year = c.y - 1900;
    tm.mon = c.m - 1;
    tm.mday = c.d;
    tm.hour = r.hh;
    tm.min = r.mm;
    tm.isdst = -1;
    return libc_time.mktime(&tm);
}

/// Wraps `text` in single quotes for `sh -c`, escaping embedded quotes.
/// Returns the slice written, or null if `out` is too small.
fn shQuote(text: []const u8, out: []u8) ?[]const u8 {
    if (out.len < 3) return null;
    out[0] = '\'';
    var n: usize = 1;
    for (text) |ch| {
        if (ch == '\'') {
            if (n + 4 >= out.len) return null;
            @memcpy(out[n .. n + 4], "'\\''");
            n += 4;
        } else {
            if (n + 1 >= out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    out[n] = '\'';
    return out[0 .. n + 1];
}

/// Reads `"key": "value"` out of a JSON object slice, unescaping \" and \\.
/// Returns null when the key is absent or malformed.
fn jsonField(obj: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, obj, key) orelse return null;
    var i = k + key.len;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != ':') return null;
    i += 1;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    var n: usize = 0;
    while (i < obj.len) {
        const ch = obj[i];
        if (ch == '"') return out[0..n];
        if (ch == '\\' and i + 1 < obj.len) {
            const c: u8 = switch (obj[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => { // \uXXXX: drop (nager emits raw UTF-8, not escapes)
                    i += 2;
                    continue;
                },
            };
            if (n >= out.len) return out[0..n];
            out[n] = c;
            n += 1;
            i += 2;
            continue;
        }
        if (n >= out.len) return out[0..n];
        out[n] = ch;
        n += 1;
        i += 1;
    }
    return null; // unterminated string
}

/// True when the holiday's `counties` array mentions the configured region
/// ("WA" matches county "AU-WA"). Absent/null counties never match.
fn countyMatches(obj: []const u8, region: []const u8) bool {
    const key = "\"counties\":[";
    const c = std.mem.indexOf(u8, obj, key) orelse return false;
    const start = c + key.len;
    const end = std.mem.indexOfScalarPos(u8, obj, start, ']') orelse obj.len;
    var i = start;
    while (i < end) {
        const q1 = std.mem.indexOfScalarPos(u8, obj, i, '"') orelse return false;
        const q2 = std.mem.indexOfScalarPos(u8, obj, q1 + 1, '"') orelse return false;
        const county = obj[q1 + 1 .. q2];
        if (std.mem.eql(u8, county, region)) return true;
        if (county.len > region.len + 1 and
            county[county.len - region.len - 1] == '-' and
            std.mem.eql(u8, county[county.len - region.len ..], region)) return true;
        i = q2 + 1;
    }
    return false;
}

pub const CalendarWidget = struct {
    // View state: which month is shown, and whether it tracks the real one.
    view_y: i32 = 0,
    view_m: u8 = 1,
    have_view: bool = false,
    follow: bool = true,
    /// Epoch day of the real today — today's highlight and the footer's
    /// "next holiday" always refer to actual dates, not the browsed month.
    today_days: i64 = 0,

    // Holiday list (for `holiday_year`, the real current year).
    holiday_year: i32 = 0,
    fetch_year: i32 = 0,
    holiday_count: usize = 0,
    holidays: [MAX_HOLIDAYS]Holiday = undefined,
    holiday_retry_ms: i64 = 0,
    phase: CalPhase = .holidays,
    fetch: Fetcher = .{},

    // Reminders, kept in sync with the file.
    reminders: [REM_MAX]Reminder = undefined,
    reminder_count: usize = 0,
    cache: [4096]u8 = undefined,
    cache_len: usize = 0,

    rem_buf: [512]u8 = undefined,
    rem_len: usize = 0,
    country_buf: [8]u8 = undefined,
    country_len: usize = 0,
    region_buf: [8]u8 = undefined,
    region_len: usize = 0,

    // Monthly-ish cadence: 30 s covers the day rollover, the notification
    // window, and reminder-file changes without a busy loop.
    pub const interval_ms: i64 = 30_000;

    /// One-time wiring from the host: reminders path + holiday country/region
    /// from shell.json (sanitized — the country lands in a URL path).
    pub fn configure(self: *CalendarWidget, rem_path: []const u8, country_code: []const u8, region_code: []const u8) void {
        const p = rem_path[0..@min(rem_path.len, self.rem_buf.len - 1)];
        @memcpy(self.rem_buf[0..p.len], p);
        self.rem_buf[p.len] = 0;
        self.rem_len = p.len;

        var n: usize = 0;
        for (country_code) |ch| {
            if (std.ascii.isAlphabetic(ch) and n < self.country_buf.len) {
                self.country_buf[n] = ch;
                n += 1;
            }
        }
        if (n == 0) {
            @memcpy(self.country_buf[0..2], "AU");
            n = 2;
        }
        self.country_len = n;

        var rn: usize = 0;
        for (region_code) |ch| {
            if ((std.ascii.isAlphanumeric(ch) or ch == '-') and rn < self.region_buf.len) {
                self.region_buf[rn] = ch;
                rn += 1;
            }
        }
        self.region_len = rn;
    }

    fn remPath(self: *const CalendarWidget) [:0]const u8 {
        return self.rem_buf[0..self.rem_len :0];
    }

    fn country(self: *const CalendarWidget) []const u8 {
        return self.country_buf[0..self.country_len];
    }

    fn region(self: *const CalendarWidget) []const u8 {
        return self.region_buf[0..self.region_len];
    }

    // --- holidays ---------------------------------------------------------

    fn startHolidayFetch(self: *CalendarWidget, year: i32) void {
        if (self.fetch.busy()) return;
        var url_buf: [160]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://date.nager.at/api/v3/PublicHolidays/{d}/{s}", .{ year, self.country() }) catch return;
        var script: [256]u8 = undefined;
        // The printf marker keeps output non-empty even when curl fails, so
        // the fetch pipe always reaches EOF-with-bytes (the Fetcher treats a
        // fully empty read as "still in flight"); --max-time stops a black-
        // holed network from wedging the fetcher (and the retry gate) open.
        const s = std.fmt.bufPrintZ(&script, "curl -sf --max-time 20 -- '{s}' || printf '\\nH'", .{url}) catch return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .holidays;
    }

    /// Parses a date.nager.at PublicHolidays response into self.holidays.
    /// `region` empty keeps every entry; otherwise non-global holidays are
    /// kept only when their county matches. Returns false when the payload
    /// isn't a JSON list at all (curl error page, truncated body).
    fn parseHolidays(self: *CalendarWidget, json: []const u8, region_filter: []const u8) bool {
        if (std.mem.indexOf(u8, json, "[") == null) return false;
        var count: usize = 0;
        var i: usize = 0;
        while (count < MAX_HOLIDAYS) {
            const o = std.mem.indexOfScalarPos(u8, json, i, '{') orelse break;
            const e = std.mem.indexOfScalarPos(u8, json, o, '}') orelse break;
            const obj = json[o .. e + 1];
            i = e;
            var dbuf: [16]u8 = undefined;
            const date = jsonField(obj, "\"date\"", &dbuf) orelse continue;
            if (date.len < 10) continue;
            const m = std.fmt.parseInt(u8, date[5..7], 10) catch continue;
            const d = std.fmt.parseInt(u8, date[8..10], 10) catch continue;
            if (m < 1 or m > 12 or d < 1 or d > 31) continue;
            const global = std.mem.indexOf(u8, obj, "\"global\":false") == null;
            if (!global and region_filter.len > 0 and !countyMatches(obj, region_filter)) continue;
            var nbuf: [56]u8 = undefined;
            const name = jsonField(obj, "\"localName\"", &nbuf) orelse
                jsonField(obj, "\"name\"", &nbuf) orelse "Holiday";
            var h = Holiday{ .m = m, .d = d, .global = global, .name_len = 0, .name = undefined };
            const nm = name[0..@min(name.len, h.name.len)];
            @memcpy(h.name[0..nm.len], nm);
            h.name_len = @intCast(nm.len);
            self.holidays[count] = h;
            count += 1;
        }
        self.holiday_count = count;
        // Insertion sort by (month, day) — cheap at this size, and the
        // footer's "next holiday" logic wants ordered entries.
        var k: usize = 1;
        while (k < count) : (k += 1) {
            var j: usize = k;
            while (j > 0 and (self.holidays[j].m < self.holidays[j - 1].m or
                (self.holidays[j].m == self.holidays[j - 1].m and self.holidays[j].d < self.holidays[j - 1].d)))
            {
                const tmp = self.holidays[j];
                self.holidays[j] = self.holidays[j - 1];
                self.holidays[j - 1] = tmp;
                j -= 1;
            }
        }
        return true;
    }

    fn holidayFor(self: *const CalendarWidget, y: i32, m: u8, d: u8) ?*const Holiday {
        if (y != self.holiday_year) return null;
        for (0..self.holiday_count) |i| {
            const h = &self.holidays[i];
            if (h.m == m and h.d == d) return h;
        }
        return null;
    }

    // --- reminders --------------------------------------------------------

    /// Re-reads the reminders file. Unchanged content is a cheap no-op;
    /// changed content is re-parsed with each line's `fired` flag carried
    /// over from the previous set (matched by exact line), so reloads —
    /// every tick, or right after the rofi menu closes — never re-notify.
    /// Returns true when the entry set changed (day dots may move).
    fn loadReminders(self: *CalendarWidget) bool {
        var buf: [4096]u8 = undefined;
        const n = readFileInto(self.remPath(), &buf);
        if (n == self.cache_len and (n == 0 or std.mem.eql(u8, buf[0..n], self.cache[0..self.cache_len]))) {
            return false;
        }
        const copy_len = @min(n, self.cache.len);
        @memcpy(self.cache[0..copy_len], buf[0..copy_len]);
        self.cache_len = copy_len;

        const now_t = libc_time.time(null);
        var fresh: [REM_MAX]Reminder = undefined;
        var fresh_count: usize = 0;
        var fired_count: usize = 0;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // Tolerate one stray leading '+' (seen on a hand- or tool-edited
            // line once) — valid lines always start with the year.
            if (line[0] == '+') {
                logging.step("calendar: stripping stray '+' from: {s}", .{line});
                line = line[1..];
            }
            if (fresh_count >= REM_MAX) break;
            var r: Reminder = undefined;
            if (!parseReminderLine(line, &r)) {
                logging.step("calendar: skipping malformed line: {s}", .{line});
                continue;
            }
            var carried = false;
            for (0..self.reminder_count) |i| {
                const old = &self.reminders[i];
                if (old.raw_len == r.raw_len and std.mem.eql(u8, old.raw[0..old.raw_len], r.raw[0..r.raw_len])) {
                    r.fired = old.fired;
                    carried = true;
                    break;
                }
            }
            // Only a never-seen entry whose due time already passed is born
            // fired (created too late to announce). A carried entry keeps its
            // armed state even when the file is edited around it — otherwise
            // a reparse between "due" and "next tick" would swallow the
            // notification.
            if (!carried and dueEpoch(r) < now_t) {
                r.fired = true;
                logging.step("calendar: new past-due entry marked silently: {s}", .{line});
            }
            fresh[fresh_count] = r;
            fresh_count += 1;
            if (r.fired) fired_count += 1;
        }
        self.reminders = fresh;
        self.reminder_count = fresh_count;
        logging.step("calendar: reminders loaded: {d} entries ({d} fired)", .{ fresh_count, fired_count });
        return true;
    }

    fn hasReminder(self: *const CalendarWidget, y: i32, m: u8, d: u8) bool {
        for (0..self.reminder_count) |i| {
            const r = self.reminders[i];
            if (r.y == y and r.m == m and r.d == d) return true;
        }
        return false;
    }

    /// Fires notifications for reminders whose due time passed since the
    /// last tick, marking them fired either way (a due time missed by more
    /// than the grace window — suspend, downtime — is marked silently).
    fn checkReminders(self: *CalendarWidget, now_t: i64) void {
        for (0..self.reminder_count) |i| {
            const r = &self.reminders[i];
            if (r.fired) continue;
            const due = dueEpoch(r.*);
            if (now_t < due) continue;
            r.fired = true;
            if (now_t - due > NOTIFY_GRACE_S) {
                logging.step("calendar: reminder {s} missed the {d}s window ({d}s late) — marked silently", .{ r.text(), NOTIFY_GRACE_S, now_t - due });
                continue;
            }
            var when_buf: [32]u8 = undefined;
            const when = std.fmt.bufPrint(&when_buf, "{s} {d} {s} {d:0>2}:{d:0>2}", .{
                DAYS[wdayOf(daysFromCivil(r.y, r.m, r.d)) % 7],
                r.d,
                MONTHS[r.m - 1],
                r.hh,
                r.mm,
            }) catch continue;
            var t_q: [400]u8 = undefined;
            var w_q: [80]u8 = undefined;
            const title = shQuote(r.text(), &t_q) orelse continue;
            const body = shQuote(when, &w_q) orelse continue;
            var cmd: [560]u8 = undefined;
            const s = std.fmt.bufPrintZ(&cmd, "notify-send -a simpbar -u normal {s} {s}", .{ title, body }) catch continue;
            logging.step("calendar: reminder due, notifying: {s}", .{r.text()});
            spawnDetached(s);
        }
    }

    /// Click on a day: rofi menu for that date — add a reminder (free-text,
    /// optionally "HH:MM lead text" prefixed) or delete an existing one.
    /// The script edits the file; the completion fires loadReminders().
    fn openDayMenu(self: *CalendarWidget, y: i32, m: u8, d: u8) void {
        if (self.fetch.busy()) return;
        var d_buf: [16]u8 = undefined;
        // NOTE: view_y is i32, but Zig 0.16's fmt renders an explicit '+'
        // for signed ints whenever a width/fill spec is applied — that '+'
        // leaked into the date (d='+2026-10-09'), which broke the menu's
        // grep match and wrote '+'-prefixed lines. Cast to unsigned.
        const ds = std.fmt.bufPrint(&d_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(y, 0))), m, d }) catch return;
        var script: [1536]u8 = undefined;
        const s = std.fmt.bufPrintZ(&script,
            \\printf 'menu-run\n'
            \\f='{s}'
            \\d='{s}'
            \\menu=$(printf '+ New reminder\n'; grep -F -- "$d " "$f" 2>/dev/null | sed 's/^[0-9-]* //')
            \\sel=$(printf '%s\n' "$menu" | rofi -dmenu -i -p "Reminders · $d") || exit 0
            \\[ -n "$sel" ] || exit 0
            \\case "$sel" in
            \\'+ New reminder')
            \\  inp=$(rofi -dmenu -p "$d — text, or HH:MM lead text" </dev/null) || exit 0
            \\  case "$inp" in
            \\    '') exit 0 ;;
            \\    [0-9][0-9]:[0-9][0-9]' '*) line="$d $inp" ;;
            \\    *) line="$d 09:00 0 $inp" ;;
            \\  esac
            \\  printf '%s\n' "$line" >> "$f"
            \\  notify-send -a simpbar "Reminder added" "$line" 2>/dev/null
            \\  ;;
            \\*)
            \\  grep -vxF -- "$d $sel" "$f" > "$f.tmp" 2>/dev/null
            \\  mv "$f.tmp" "$f" 2>/dev/null
            \\  notify-send -a simpbar "Reminder removed" "$d $sel" 2>/dev/null
            \\  ;;
            \\esac
            \\printf 'menu-done'
        , .{ self.remPath(), ds }) catch return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", s.ptr, null };
        self.fetch.start("/bin/sh", &argv);
        self.phase = .menu;
    }

    // --- cadence / io -----------------------------------------------------

    /// 30 s tick: follow the real month/day, kick a holiday fetch when the
    /// year isn't loaded yet, re-sync the reminders file, fire due
    /// notifications. Returns true when displayed pixels changed.
    pub fn tick(self: *CalendarWidget) bool {
        var changed = false;
        const now_t = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now_t, &tm);
        const cur_y: i32 = tm.year + 1900;
        const cur_m: u8 = @intCast(tm.mon + 1);
        const cur_d: u8 = @intCast(tm.mday);
        const today = daysFromCivil(cur_y, cur_m, cur_d);

        if (!self.have_view) {
            self.view_y = cur_y;
            self.view_m = cur_m;
            self.have_view = true;
            self.follow = true;
            changed = true;
        } else if (self.follow and (self.view_y != cur_y or self.view_m != cur_m)) {
            self.view_y = cur_y;
            self.view_m = cur_m;
            changed = true;
        }
        if (self.today_days != today) {
            self.today_days = today;
            changed = true;
        }

        if (self.holiday_year != cur_y and !self.fetch.busy() and monoMs() >= self.holiday_retry_ms) {
            self.fetch_year = cur_y;
            self.holiday_retry_ms = monoMs() + 3_600_000; // hourly retry until a year loads
            self.startHolidayFetch(cur_y);
        }
        if (self.loadReminders()) changed = true;
        self.checkReminders(now_t);
        return changed;
    }

    /// Fetch pipe finished: holiday JSON parsed, or the rofi menu closed
    /// (either way the reminders file may have changed).
    pub fn onPipe(self: *CalendarWidget) bool {
        var out: [10240]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        switch (self.phase) {
            .holidays => {
                if (self.parseHolidays(out[0..n], self.region())) {
                    self.holiday_year = self.fetch_year;
                    return true;
                }
                return false; // next hourly gate retries
            },
            .menu => return self.loadReminders(),
        }
    }

    // --- layout / painting ------------------------------------------------

    /// Absolute layout shared by paint and click hit-testing.
    const CalLayout = struct {
        padx: i64,
        grid_x: i64,
        grid_y: i64,
        b1: i64, // header baseline
        wd_b: i64, // weekday row baseline
        foot_b: i64, // footer baseline
        lh: i64,
    };

    fn calLayout(r: Rect, font: *font_mod.Font) CalLayout {
        const lh = lineH(font);
        const ascent: i64 = font.ascentPx();
        const padx = r.x + CARD_PAD;
        const b1 = r.y + CARD_PAD + ascent;
        const wd_b = r.y + CARD_PAD + lh + CAL_HEAD_GAP + ascent;
        const grid_y = r.y + CARD_PAD + 2 * lh + CAL_HEAD_GAP + CAL_WD_GAP;
        const foot_b = grid_y + CAL_ROWS * CAL_CELL_H + CAL_FOOT_GAP + ascent;
        return .{ .padx = padx, .grid_x = padx, .grid_y = grid_y, .b1 = b1, .wd_b = wd_b, .foot_b = foot_b, .lh = lh };
    }

    fn navMonth(self: *CalendarWidget, delta: i32) void {
        self.follow = false; // browsing detaches from the real month
        var m: i32 = @as(i32, self.view_m) + delta;
        var y = self.view_y;
        if (m < 1) {
            m = 12;
            y -= 1;
        } else if (m > 12) {
            m = 1;
            y += 1;
        }
        self.view_m = @intCast(m);
        self.view_y = y;
    }

    fn jumpToToday(self: *CalendarWidget) void {
        const now_t = libc_time.time(null);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&now_t, &tm);
        self.view_y = tm.year + 1900;
        self.view_m = @intCast(tm.mon + 1);
        self.follow = true;
    }

    pub fn paint(self: *const CalendarWidget, c: Canvas, r: Rect) void {
        const l = calLayout(r, c.font);
        const ascent: i64 = c.font.ascentPx();
        const grid_w: i64 = 7 * CAL_CELL_W;

        // Header: < Month YYYY > — chevrons from Font Awesome, title click
        // jumps back to the real month (see clickAt).
        if (self.have_view) {
            var title_buf: [32]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ MONTHS_FULL[self.view_m - 1], self.view_y }) catch "";
            const left: []const u8 = "\u{f053}";
            const right: []const u8 = "\u{f054}";
            _ = c.drawText(l.grid_x, l.b1, left, dim(c.theme.text_color, 0x99));
            _ = c.drawText(l.grid_x + grid_w - c.textWidth(right), l.b1, right, dim(c.theme.text_color, 0x99));
            const tw = c.textWidth(title);
            _ = c.drawText(l.grid_x + @divTrunc(grid_w - tw, 2), l.b1, title, c.theme.text_color);
        }

        // Weekday header (Monday first — matches the grid below).
        for (WD_ROW, 0..) |lbl, col| {
            const lw = c.textWidth(lbl);
            _ = c.drawText(
                l.grid_x + @as(i64, @intCast(col)) * CAL_CELL_W + @divTrunc(CAL_CELL_W - lw, 2),
                l.wd_b,
                lbl,
                dim(c.theme.text_color, 0x88),
            );
        }

        if (self.have_view) {
            const first_col: i64 = monCol(wdayOf(daysFromCivil(self.view_y, self.view_m, 1)));
            const dim_days = daysInMonth(self.view_y, self.view_m);
            var day: i32 = 1;
            var pos: i64 = first_col;
            while (day <= dim_days) : (day += 1) {
                const col = @mod(pos, 7);
                const row = @divFloor(pos, 7);
                pos += 1;
                const x0 = l.grid_x + col * CAL_CELL_W;
                const y0 = l.grid_y + row * CAL_CELL_H;
                const is_today = daysFromCivil(self.view_y, self.view_m, @intCast(day)) == self.today_days;
                const hol = self.holidayFor(self.view_y, self.view_m, @intCast(day));
                if (is_today) {
                    // Accent pill behind today's number.
                    c.card(
                        .{ .x = @intCast(x0 + 1), .y = @intCast(y0 + 1), .w = @intCast(CAL_CELL_W - 2), .h = @intCast(CAL_CELL_H - 3) },
                        dim(c.theme.border_color, 0x33),
                        dim(c.theme.border_color, 0x99),
                    );
                }
                var num_buf: [4]u8 = undefined;
                const num = std.fmt.bufPrint(&num_buf, "{d}", .{day}) catch continue;
                const num_col: u32 = if (hol) |h|
                    if (h.global) c.theme.holiday_color else dim(c.theme.holiday_color, 0x99)
                else if (is_today) c.theme.text_color //
                else dim(c.theme.text_color, 0xE0);
                _ = c.drawText(x0 + @divTrunc(CAL_CELL_W - c.textWidth(num), 2), y0 + 2 + ascent, num, num_col);
                if (self.hasReminder(self.view_y, self.view_m, @intCast(day))) {
                    c.fillRect(x0 + @divTrunc(CAL_CELL_W, 2) - 1, y0 + CAL_CELL_H - 4, 3, 3, c.theme.text_color);
                }
            }
        }

        // Footer: today's holiday in the accent color, else the next
        // upcoming one of the real year.
        if (self.holiday_count > 0) {
            var chosen: ?*const Holiday = null;
            var is_today_hol = false;
            for (0..self.holiday_count) |i| {
                const h = &self.holidays[i];
                const hd = daysFromCivil(self.holiday_year, h.m, h.d);
                if (hd == self.today_days) {
                    chosen = h;
                    is_today_hol = true;
                    break;
                }
                if (hd > self.today_days and chosen == null) chosen = h;
            }
            if (chosen) |h| {
                var label_buf: [96]u8 = undefined;
                const label = if (is_today_hol)
                    std.fmt.bufPrint(&label_buf, "{s}", .{h.name[0..h.name_len]}) catch ""
                else
                    std.fmt.bufPrint(&label_buf, "Next: {s} · {d} {s}", .{ h.name[0..h.name_len], h.d, MONTHS[h.m - 1] }) catch "";
                var clip: [120]u8 = undefined;
                const col = if (is_today_hol) c.theme.holiday_color else dim(c.theme.text_color, 0x99);
                _ = c.drawText(l.padx, l.foot_b, fitText(c, label, grid_w, &clip), col);
            }
        }
    }

    /// Left-click: header arrows step months, the month title jumps back to
    /// today, a day cell opens its rofi reminder menu.
    pub fn clickAt(self: *CalendarWidget, r: Rect, font: *font_mod.Font, px: i32, py: i32) void {
        if (!self.have_view) return;
        const l = calLayout(r, font);
        const grid_w: i64 = 7 * CAL_CELL_W;
        const px64: i64 = px;
        const py64: i64 = py;
        const head_top: i64 = r.y + CARD_PAD;
        if (py64 >= head_top and py64 < head_top + l.lh) {
            if (px64 < l.grid_x + CAL_ARROW_ZONE) navMonth(self, -1) //
            else if (px64 >= l.grid_x + grid_w - CAL_ARROW_ZONE) navMonth(self, 1) //
            else jumpToToday(self);
            return;
        }
        if (py64 >= l.grid_y and py64 < l.grid_y + CAL_ROWS * CAL_CELL_H and
            px64 >= l.grid_x and px64 < l.grid_x + grid_w)
        {
            const col = @divFloor(px64 - l.grid_x, CAL_CELL_W);
            const row = @divFloor(py64 - l.grid_y, CAL_CELL_H);
            const first_col = @as(i64, monCol(wdayOf(daysFromCivil(self.view_y, self.view_m, 1))));
            const day = row * 7 + col - first_col + 1;
            if (day >= 1 and day <= daysInMonth(self.view_y, self.view_m)) {
                self.openDayMenu(self.view_y, self.view_m, @intCast(day));
            }
        }
    }
};

// --- analog watch (Seiko 5 automatic) --------------------------------------

/// An analog clock drawn like a Seiko SKX diver: knurled steel case with a
/// black 60-minute bezel (numerals, triangle pip at 12), lume plots
/// (triangle at 12, bars at 6/9, dots elsewhere), a Mercedes hour hand, and
/// a day-date window at 3 — no bracelet, just the head on short lug stubs.
/// The seconds hand steps in 1/6-second beats — the 21,600 vph sweep of the
/// 7S26 movement rather than a dead-beat tick.
///
/// Clicking anywhere on the watch flips between the black (SKX007) and a
/// deep-blue dial. Every paint reads the wall clock fresh — no hand-angle
/// state, nothing to drift.
pub const WatchWidget = struct {
    /// 0 = black diver, 1 = blue diver.
    dial: u8 = 0,

    /// Six repaints a second = six beats (21,600 vibrations/hour).
    pub const interval_ms: i64 = 167; // six beats per second (21,600 vph)

    /// Colours for one dial variant (0xAARRGGBB). The steel of the case
    /// and the lume are shared between both variants.
    const Palette = struct {
        dial: u32,
        bezel: u32,
        bezel_text: u32,
        minute_tick: u32,
        five_tick: u32,
        lume: u32,
        hand: u32,
        seconds: u32,
        brand: u32,
        window_fg: u32,
    };

    const STEEL_BODY: u32 = 0xFFA9AEB6;
    const STEEL_POLISH: u32 = 0xFFD6DBE1;
    const STEEL_BEZEL: u32 = 0xFFBEC3CA;
    const STEEL_SHADOW: u32 = 0xFF7C818A;
    const STEEL_CAP: u32 = 0xFFC8CDD4;
    const BEZEL_DIM: u32 = 0xFF8B9098;
    const PLOT_EDGE: u32 = 0xFF2E3238; // surround that lifts lume plots off the dial
    const WINDOW_BG: u32 = 0xFFFFFFFF;
    const WINDOW_BORDER: u32 = 0xFF1C1C1F;

    const BLACK_DIVER: Palette = .{
        .dial = 0xFF121418,
        .bezel = 0xFF16181D,
        .bezel_text = 0xFFE9EBEF,
        .minute_tick = 0xFF6E737C,
        .five_tick = 0xFFC9CED6,
        .lume = 0xFFDCE6B8,
        .hand = 0xFFDCE0E6,
        .seconds = 0xFFB4BAC2,
        .brand = 0xFFE9EBEF,
        .window_fg = 0xFF17171A,
    };
    const BLUE_DIVER: Palette = .{
        .dial = 0xFF152A45,
        .bezel = 0xFF13263E,
        .bezel_text = 0xFFE9EBEF,
        .minute_tick = 0xFF6E7B8C,
        .five_tick = 0xFFC9D2DE,
        .lume = 0xFFDCE6B8,
        .hand = 0xFFDCE0E6,
        .seconds = 0xFFB4BAC2,
        .brand = 0xFFE9EBEF,
        .window_fg = 0xFF17171A,
    };

    /// Uppercased day abbreviations for the window — DAYS is title-case for
    /// the digital clock's sub-line.
    const DAYS_UPPER = [_][]const u8{ "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };

    const DEG = std.math.pi / 180.0;

    pub fn tick(self: *WatchWidget) bool {
        _ = self;
        return true; // the hands move on every beat — always repaint
    }

    /// Click the watch to swap the dial (the host repaints after any click).
    pub fn click(self: *WatchWidget) void {
        self.dial = (self.dial + 1) % 2;
    }

    /// Radial unit direction for angle `a` in radians: 0 = 12 o'clock,
    /// growing clockwise.
    fn radial(a: f64) [2]f64 {
        return .{ @sin(a), -@cos(a) };
    }

    /// Point at radius `along` with lateral offset `off` from the dial
    /// center, along direction (dx, dy).
    fn at(cx: f64, cy: f64, dx: f64, dy: f64, along: f64, off: f64) Canvas.FPt {
        return .{ .x = cx + dx * along - dy * off, .y = cy + dy * along + dx * off };
    }

    /// Tapered baton from radius r0 to r1 (either end may pass the center,
    /// so hands can carry a tail), width w0 → w1. AA via fillConvex.
    fn baton(c: Canvas, cx: f64, cy: f64, a: f64, r0: f64, r1: f64, w0: f64, w1: f64, color: u32) void {
        const d = radial(a);
        const pts = [4]Canvas.FPt{
            at(cx, cy, d[0], d[1], r0, -w0 / 2),
            at(cx, cy, d[0], d[1], r1, -w1 / 2),
            at(cx, cy, d[0], d[1], r1, w1 / 2),
            at(cx, cy, d[0], d[1], r0, w0 / 2),
        };
        c.fillConvex(&pts, color);
    }

    /// Centered, letterspaced text — dial brand lettering is spaced like
    /// this on the real watch. ASCII only (SEIKO / AUTOMATIC).
    fn drawSpaced(c: Canvas, cx: i64, baseline: i64, text: []const u8, gap: i64, color: u32) void {
        var total: i64 = 0;
        for (text, 0..) |_, i| {
            total += (c.font.glyph(text[i]) catch continue).advance_x;
            if (i + 1 < text.len) total += gap;
        }
        var pen = cx - @divTrunc(total, 2);
        for (text, 0..) |_, i| {
            _ = c.drawText(pen, baseline, text[i .. i + 1], color);
            pen += (c.font.glyph(text[i]) catch continue).advance_x + gap;
        }
    }

    pub fn paint(self: *const WatchWidget, c: Canvas, r: Rect) void {
        const P: Palette = if (self.dial == 0) BLACK_DIVER else BLUE_DIVER;
        const cx_i: i64 = @as(i64, r.x) + WATCH_W / 2;
        const cy_i: i64 = @as(i64, r.y) + WATCH_H / 2;
        const cx: f64 = @floatFromInt(cx_i);
        const cy: f64 = @floatFromInt(cy_i);

        // Wall clock drives every hand — no angle state to drift. The
        // sub-second read gives the beat phase (6 beats per second).
        var tp: posix.timespec = undefined;
        if (libc_mono.clock_gettime(0, &tp) != 0) { // 0 = CLOCK_REALTIME
            tp.sec = @intCast(libc_time.time(null));
            tp.nsec = 0;
        }
        const epoch: i64 = @intCast(tp.sec);
        var tm: libc_time.Tm = undefined;
        _ = libc_time.localtime_r(&epoch, &tm);
        const nsec: i64 = @intCast(tp.nsec);
        const beat: i64 = @divTrunc(@mod(nsec, 1_000_000_000) * 6, 1_000_000_000);

        // Seconds: 6°/s with the hand stepping 1° per beat. Minute and
        // hour ride continuously on top of that.
        const sec_a = (@as(f64, @floatFromInt(tm.sec)) * 6.0 + @as(f64, @floatFromInt(beat))) * DEG;
        const min_a = (@as(f64, @floatFromInt(tm.min)) + @as(f64, @floatFromInt(tm.sec)) / 60.0) * 6.0 * DEG;
        const hr_a = (@as(f64, @floatFromInt(@mod(tm.hour, 12))) + @as(f64, @floatFromInt(tm.min)) / 60.0) * 30.0 * DEG;

        // Short lug stubs top and bottom — the head without its bracelet,
        // drawn first so the case laps over their inner ends.
        for ([2]bool{ true, false }) |is_top| {
            const s: f64 = if (is_top) -1.0 else 1.0;
            const lugs = [4]Canvas.FPt{
                .{ .x = cx - 23, .y = cy + s * 76 },
                .{ .x = cx + 23, .y = cy + s * 76 },
                .{ .x = cx + 17, .y = cy + s * 97 },
                .{ .x = cx - 17, .y = cy + s * 97 },
            };
            c.fillConvex(&lugs, STEEL_BODY);
        }

        // Crown at 4 o'clock (SKX puts it between 3 and 4), poking out
        // from behind the case: a radial stem plus the knurled knob.
        const crown_a = 120.0 * DEG;
        baton(c, cx, cy, crown_a, 78, 90, 7.0, 7.0, STEEL_BODY);
        const cd = radial(crown_a);
        const kx = cx + cd[0] * 90;
        const ky = cy + cd[1] * 90;
        c.fillCircleAA(kx, ky, 5.2, STEEL_BODY);
        c.fillRingAA(kx, ky, 3.0, 5.2, STEEL_SHADOW);

        // Case: brushed body, polished outer band, then the bezel stack.
        c.fillCircleAA(cx, cy, WATCH_CASE_R, STEEL_BODY);
        c.fillRingAA(cx, cy, WATCH_CASE_R - 3, WATCH_CASE_R, STEEL_POLISH);
        // Coin-edge knurling on the bezel flank.
        var e: u32 = 0;
        while (e < 60) : (e += 1) {
            baton(c, cx, cy, @as(f64, @floatFromInt(e)) * 6.0 * DEG, 79.5, 83.0, 1.4, 1.4, STEEL_SHADOW);
        }
        // Black 60-minute insert.
        c.fillRingAA(cx, cy, 60, 79, P.bezel);

        // Bezel minute ticks — every minute for the first quarter like the
        // real insert, fives elsewhere — skipping the numeral/triangle spots.
        var i: u32 = 0;
        while (i < 60) : (i += 1) {
            const a_deg: i32 = @intCast(i * 6);
            const near_num = @abs(a_deg - 60) < 10 or @abs(a_deg - 120) < 10 or
                @abs(a_deg - 180) < 10 or @abs(a_deg - 240) < 10 or @abs(a_deg - 300) < 10;
            const near_pip = a_deg < 10 or a_deg > 350;
            if (near_num or near_pip) continue;
            const a = @as(f64, @floatFromInt(i)) * 6.0 * DEG;
            if (i % 5 == 0) {
                baton(c, cx, cy, a, 72.5, 77.5, 2.0, 2.2, P.bezel_text);
            } else if (i <= 15) {
                baton(c, cx, cy, a, 74.5, 77.5, 1.0, 1.0, BEZEL_DIM);
            }
        }

        // Triangle pip at 12 on the bezel, apex toward the dial.
        {
            const t_out = [3]Canvas.FPt{
                at(cx, cy, 0, -1, 77.5, -4.5),
                at(cx, cy, 0, -1, 77.5, 4.5),
                at(cx, cy, 0, -1, 63.0, 0),
            };
            c.fillConvex(&t_out, P.bezel_text);
            const t_in = [3]Canvas.FPt{
                at(cx, cy, 0, -1, 75.5, -2.6),
                at(cx, cy, 0, -1, 75.5, 2.6),
                at(cx, cy, 0, -1, 65.5, 0),
            };
            c.fillConvex(&t_in, P.lume);
        }

        // Bezel numerals 10..50.
        const numerals = [_]struct { deg: f64, label: *const [2]u8 }{
            .{ .deg = 60, .label = "10" },
            .{ .deg = 120, .label = "20" },
            .{ .deg = 180, .label = "30" },
            .{ .deg = 240, .label = "40" },
            .{ .deg = 300, .label = "50" },
        };
        for (numerals) |n| {
            const d = radial(n.deg * DEG);
            const px = cx + d[0] * 68.5;
            const py = cy + d[1] * 68.5;
            const tw = c.textWidth(n.label);
            _ = c.drawText(
                @as(i64, @intFromFloat(px)) - @divTrunc(tw, 2),
                @as(i64, @intFromFloat(py)) + @divTrunc(c.font.ascentPx(), 2),
                n.label,
                P.bezel_text,
            );
        }

        // Dial with a stepped edge out of the bezel.
        c.fillRingAA(cx, cy, 58.5, 60.5, 0x88000000);
        c.fillCircleAA(cx, cy, 59, P.dial);

        // Dial minute track just inside the edge.
        var m: u32 = 0;
        while (m < 60) : (m += 1) {
            const a = @as(f64, @floatFromInt(m)) * 6.0 * DEG;
            if (m % 5 == 0) {
                baton(c, cx, cy, a, 53.5, 58.0, 1.8, 2.0, P.five_tick);
            } else {
                baton(c, cx, cy, a, 55.0, 58.0, 0.9, 0.9, P.minute_tick);
            }
        }

        // Lume plots: triangle at 12, bars at 6 and 9, dots elsewhere —
        // none at 3, where the day-date window sits.
        var k: i32 = 0;
        while (k < 12) : (k += 1) {
            if (k == 3) continue;
            const a = @as(f64, @floatFromInt(k)) * 30.0 * DEG;
            const d = radial(a);
            if (k == 0) {
                const tri_out = [3]Canvas.FPt{
                    at(cx, cy, d[0], d[1], 50, -5.5),
                    at(cx, cy, d[0], d[1], 50, 5.5),
                    at(cx, cy, d[0], d[1], 37, 0),
                };
                c.fillConvex(&tri_out, PLOT_EDGE);
                const tri_in = [3]Canvas.FPt{
                    at(cx, cy, d[0], d[1], 48.5, -3.6),
                    at(cx, cy, d[0], d[1], 48.5, 3.6),
                    at(cx, cy, d[0], d[1], 38.5, 0),
                };
                c.fillConvex(&tri_in, P.lume);
            } else if (k == 6 or k == 9) {
                baton(c, cx, cy, a, 38, 50, 9.0, 9.0, PLOT_EDGE);
                baton(c, cx, cy, a, 39.5, 48.5, 6.2, 6.2, P.lume);
            } else {
                c.fillCircleAA(cx + d[0] * 44, cy + d[1] * 44, 5.4, PLOT_EDGE);
                c.fillCircleAA(cx + d[0] * 44, cy + d[1] * 44, 4.1, P.lume);
            }
        }

        // Day-date window at 3 o'clock — smaller here to sit inside the
        // diver dial.
        const win_x = cx_i + 10;
        const win_y = cy_i - 10;
        const win_w = 47;
        const win_h = 20;
        c.fillRect(win_x - 1, win_y - 1, win_w + 2, win_h + 2, WINDOW_BORDER);
        c.fillRect(win_x, win_y, win_w, win_h, WINDOW_BG);
        c.fillRect(win_x + 28, win_y + 1, 1, win_h - 2, 0xFF3A3A3E);
        var date_buf: [4]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d}", .{tm.mday}) catch " ";
        const day_str = DAYS_UPPER[@as(usize, @intCast(tm.wday))];
        const text_base = cy_i + @divTrunc(c.font.ascentPx(), 2);
        const day_w = c.textWidth(day_str);
        _ = c.drawText(win_x + 1 + @divTrunc(26 - day_w, 2), text_base, day_str, P.window_fg);
        const date_w = c.textWidth(date_str);
        _ = c.drawText(win_x + 29 + @divTrunc(17 - date_w, 2), text_base, date_str, P.window_fg);

        // Branding: SEIKO under the 12, Automatic above the 6 — no "5"
        // shield on a diver.
        drawSpaced(c, cx_i, cy_i - 24, "SEIKO", 2, P.brand);
        drawSpaced(c, cx_i, cy_i + 31, "Automatic", 1, P.brand);

        // Hands: silver bodies with lume fill (sword minute over the
        // Mercedes hour), then the thin seconds hand with its lollipop pip,
        // stepping exactly 1° per beat.
        baton(c, cx, cy, hr_a, -8, 30, 8.0, 6.0, P.hand);
        baton(c, cx, cy, hr_a, -2, 26, 4.5, 3.5, P.lume);
        const hd = radial(hr_a);
        c.fillCircleAA(cx + hd[0] * 21, cy + hd[1] * 21, 6.2, P.hand);
        c.fillCircleAA(cx + hd[0] * 21, cy + hd[1] * 21, 4.6, P.lume);
        baton(c, cx, cy, hr_a, 15, 27, 1.4, 1.4, P.hand); // Mercedes bar
        baton(c, cx, cy, min_a, -9, 50, 7.0, 4.5, P.hand);
        baton(c, cx, cy, min_a, 0, 44, 3.6, 2.6, P.lume);
        baton(c, cx, cy, sec_a, -14, 56, 1.8, 1.8, P.seconds);
        const sd = radial(sec_a);
        c.fillCircleAA(cx + sd[0] * 44, cy + sd[1] * 44, 4.6, P.seconds); // lollipop
        c.fillCircleAA(cx + sd[0] * 44, cy + sd[1] * 44, 3.0, P.lume);
        c.fillCircleAA(cx - sd[0] * 12, cy - sd[1] * 12, 2.8, P.seconds); // counterweight
        c.fillCircleAA(cx, cy, 4.4, STEEL_CAP);
        c.fillCircleAA(cx, cy, 1.8, P.hand);
    }
};

// --- the composite widget ---------------------------------------------------

pub const Widget = union(WidgetId) {
    clock: ClockWidget,
    weather: WeatherWidget,
    media: MediaWidget,
    system: SystemWidget,
    calendar: CalendarWidget,
    watch: WatchWidget,

    pub fn intervalMs(self: Widget) i64 {
        return switch (self) {
            .clock => ClockWidget.interval_ms,
            .weather => WeatherWidget.interval_ms,
            .media => MediaWidget.interval_ms,
            .system => SystemWidget.interval_ms,
            .calendar => CalendarWidget.interval_ms,
            .watch => WatchWidget.interval_ms,
        };
    }

    /// Cadence tick — update state / kick fetches. Returns true if the
    /// widget's pixels need repainting now.
    pub fn tick(self: *Widget) bool {
        return switch (self.*) {
            .clock => |*c| blk: {
                c.update();
                break :blk true;
            },
            .system => |*s| blk: {
                s.refresh();
                break :blk true;
            },
            .weather => |*w| blk: {
                w.refresh();
                break :blk false;
            },
            .media => |*m| blk: {
                break :blk m.tick();
            },
            .calendar => |*k| blk: {
                break :blk k.tick();
            },
            .watch => |*w| blk: {
                break :blk w.tick();
            },
        };
    }

    /// The fd poll() should watch for this widget, or -1.
    pub fn pollFd(self: *const Widget) posix.fd_t {
        return switch (self.*) {
            .weather => |w| w.fetch.fd(),
            .media => |m| m.fetch.fd(),
            .calendar => |k| k.fetch.fd(),
            else => -1,
        };
    }

    /// A fetch pipe became readable. Returns true when the widget consumed a
    /// completed fetch (pixels may have changed).
    pub fn onPipe(self: *Widget) bool {
        return switch (self.*) {
            .weather => |*w| w.onPipe(),
            .media => |*m| m.onPipe(),
            .calendar => |*k| k.onPipe(),
            else => false,
        };
    }

    /// Left-click action. Media and calendar get the click point plus their
    /// rect so their controls hit-test; every other widget ignores the extras.
    pub fn click(self: *Widget, font: *font_mod.Font, r: Rect, x: i32, y: i32) void {
        switch (self.*) {
            .clock => |c| c.click(),
            .weather => |w| w.click(),
            .media => |*m| m.clickAt(r, font, x, y),
            .system => |s| s.click(),
            .calendar => |*k| k.clickAt(r, font, x, y),
            .watch => |*w| w.click(),
        }
    }

    /// Draw content inside the already-painted card.
    pub fn paint(self: *const Widget, c: Canvas, r: Rect) void {
        switch (self.*) {
            .clock => |w| w.paint(c, r),
            .weather => |w| w.paint(c, r),
            .media => |w| w.paint(c, r),
            .system => |w| w.paint(c, r),
            .calendar => |w| w.paint(c, r),
            .watch => |w| w.paint(c, r),
        }
    }
};
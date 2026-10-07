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

pub const WidgetId = enum { clock, weather, media, system };

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
    card_alpha: u32 = 55,
    radius_px: u32 = 12,
};

const CARD_PAD: i64 = 14;
const ROW_GAP: i64 = 5;
const BAR_H: i64 = 6;

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
        .media => .{ 250, @intCast(2 * CARD_PAD + lh) },
        .system => .{ 190, @intCast(2 * CARD_PAD + 3 * lh + 2 * ROW_GAP + 2 * BAR_H) },
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
    read_buf: [1024]u8 = undefined,
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
        if (wttrIconFor(cp)) |ic| {
            // Skip variation-selector/ZWJ codepoints attached to the same
            // emoji cluster before the plain text begins.
            while (i < trimmed.len) {
                const save = i;
                const nc = nextUtf8Codepoint(trimmed, &i) orelse break;
                if (nc == 0xFE0F or nc == 0x200D) continue;
                i = save;
                break;
            }
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

// --- media -----------------------------------------------------------------

const MPRIS_SCRIPT = "playerctl metadata --format '{{status}}|{{artist}}|{{title}}'";

pub const MediaWidget = struct {
    line_buf: [256]u8 = undefined,
    line_len: usize = 0,
    playing: bool = false,
    fetch: Fetcher = .{},

    pub const interval_ms: i64 = 2000; // event-driven; polled here like the bar

    pub fn refresh(self: *MediaWidget) void {
        if (self.fetch.busy()) return;
        var argv = [_:null]?[*:0]const u8{ "sh", "-c", MPRIS_SCRIPT, null };
        self.fetch.start("/bin/sh", &argv);
    }

    /// Call when the fetch pipe is readable. Returns true when the fetch
    /// finished (state may have changed).
    pub fn onPipe(self: *MediaWidget) bool {
        var out: [256]u8 = undefined;
        const n = self.fetch.onReadable(&out);
        if (n == 0) return false;
        self.fetch.closeFd();
        const raw = out[0..n];
        if (raw.len == 0) {
            self.playing = false;
            self.line_len = 0;
            return true;
        }
        var it = std.mem.splitScalar(u8, raw, '|');
        const status = it.next() orelse "";
        const artist = std.mem.trim(u8, it.next() orelse "", " \t");
        const title = std.mem.trim(u8, it.next() orelse "", " \t");
        self.playing = std.ascii.eqlIgnoreCase(status, "Playing");
        const glyph: []const u8 = if (self.playing) "\u{f04b}" else "\u{f04c}";
        const full = if (artist.len > 0)
            std.fmt.bufPrint(&self.line_buf, "{s} {s} \u{2014} {s}", .{ glyph, artist, title }) catch self.line_buf[0..0]
        else
            std.fmt.bufPrint(&self.line_buf, "{s} {s}", .{ glyph, title }) catch self.line_buf[0..0];
        self.line_len = full.len;
        return true;
    }

    /// Truncates the content after the leading glyph so the whole line fits
    /// a `max_w`-wide space, writing the result into `dst`. Returns the
    /// slice to draw.
    fn clippedLine(self: *const MediaWidget, c: Canvas, dst: []u8, max_w: i64) []const u8 {
        const line = self.line_buf[0..self.line_len];
        var i: usize = 0;
        _ = nextUtf8Codepoint(line, &i) orelse return line;
        const glyph_end = i;
        // skip the single space before the text
        while (i < line.len and line[i] == ' ') i += 1;
        const text = line[i..];
        const glyph_slice = line[0..glyph_end];
        const glyph_w = c.textWidth(glyph_slice);
        const max_text_w = max_w - glyph_w - 6;
        if (c.textWidth(text) <= max_text_w) return line;
        var end: usize = 0;
        var w: i64 = 0;
        var j: usize = 0;
        while (nextUtf8Codepoint(text, &j)) |cp2| {
            const adv = (c.font.glyph(cp2) catch continue).advance_x;
            if (w + adv + c.textWidth("\u{2026}") > max_text_w) break;
            w += adv;
            end = j;
        }
        const sep: []const u8 = " ";
        const ell: []const u8 = "\u{2026}";
        const rest_prefix = text[0..end];
        var n: usize = 0;
        @memcpy(dst[0..glyph_end], line[0..glyph_end]);
        n = glyph_end;
        @memcpy(dst[n .. n + sep.len], sep);
        n += sep.len;
        @memcpy(dst[n .. n + rest_prefix.len], rest_prefix);
        n += rest_prefix.len;
        @memcpy(dst[n .. n + ell.len], ell);
        n += ell.len;
        return dst[0..n];
    }

    pub fn paint(self: *const MediaWidget, c: Canvas, r: Rect) void {
        const b = r.y + CARD_PAD + c.font.ascentPx();
        const padx: i64 = r.x + CARD_PAD;
        if (self.line_len == 0) {
            _ = c.drawText(padx, b, "no media playing", dim(c.theme.text_color, 0x99));
            return;
        }
        const inner_w: i64 = @as(i64, @intCast(r.w)) - 2 * CARD_PAD;
        var clip: [256]u8 = undefined;
        const drawn = self.clippedLine(c, &clip, inner_w);
        _ = c.drawText(padx, b, drawn, c.theme.text_color);
    }

    pub fn click(self: *const MediaWidget) void {
        _ = self;
        var cmd_buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "playerctl play-pause", .{}) catch return;
        spawnDetached(cmd);
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
        const s = std.fmt.bufPrint(&self.load_buf, "{d}.{d:0>2}", .{ whole, frac }) catch return;
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

// --- the composite widget ---------------------------------------------------

pub const Widget = union(WidgetId) {
    clock: ClockWidget,
    weather: WeatherWidget,
    media: MediaWidget,
    system: SystemWidget,

    pub fn intervalMs(self: Widget) i64 {
        return switch (self) {
            .clock => ClockWidget.interval_ms,
            .weather => WeatherWidget.interval_ms,
            .media => MediaWidget.interval_ms,
            .system => SystemWidget.interval_ms,
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
                m.refresh();
                break :blk false;
            },
        };
    }

    /// The fd poll() should watch for this widget, or -1.
    pub fn pollFd(self: *const Widget) posix.fd_t {
        return switch (self.*) {
            .weather => |w| w.fetch.fd(),
            .media => |m| m.fetch.fd(),
            else => -1,
        };
    }

    /// A fetch pipe became readable. Returns true when the widget consumed a
    /// completed fetch (pixels may have changed).
    pub fn onPipe(self: *Widget) bool {
        return switch (self.*) {
            .weather => |*w| w.onPipe(),
            .media => |*m| m.onPipe(),
            else => false,
        };
    }

    /// Left-click action.
    pub fn click(self: *const Widget) void {
        switch (self.*) {
            .clock => |c| c.click(),
            .weather => |w| w.click(),
            .media => |m| m.click(),
            .system => |s| s.click(),
        }
    }

    /// Draw content inside the already-painted card.
    pub fn paint(self: *const Widget, c: Canvas, r: Rect) void {
        switch (self.*) {
            .clock => |w| w.paint(c, r),
            .weather => |w| w.paint(c, r),
            .media => |w| w.paint(c, r),
            .system => |w| w.paint(c, r),
        }
    }
};
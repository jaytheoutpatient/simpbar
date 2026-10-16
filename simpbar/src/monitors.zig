// Shared monitor helpers for simpbar-config (Hyprland + MangoWM).
//
// Ported from Event-Horizon-shell-zig's monitors_state.zig /
// monitors_tab_helpers.zig data layer (mode strings, OutputCaps from
// availableModes / wlr-randr, position strings, canvas fit + drag finalize),
// adapted to simpbar-config's GTK pages:
//
//   - Hyprland: `hyprctl monitors -j` carries per-output `availableModes`
//     (e.g. "2560x1440@239.97Hz"). Those become the Resolution / Refresh
//     dropdown options; the free-text Mode field stays as fallback.
//   - MangoWM: `wlr-randr` lists every mode per output. Those become the
//     same dropdowns for monitor_rule width/height/refresh.
//   - Both pages share the arrange-canvas math (fit, drag delta, snap,
//     collision resolve, origin normalize) so the visual canvas behaves
//     the same on either compositor.
//
// Everything here is pure (no filesystem / process / GTK) and tested.
// Run: zig test src/monitors.zig

const std = @import("std");

pub const MAX_OUTPUTS = 8;
pub const MAX_RES = 24;
pub const MAX_HZ = 12;

// ---------------------------------------------------------------------
// Mode strings ("2560x1440@239.97Hz")
// ---------------------------------------------------------------------

pub const ModeSpec = struct { w: i32 = 0, h: i32 = 0, hz: f64 = 0 };

/// Parses "WxH", "WxH@Hz", "WxH@HzHz" (trailing Hz optional).
pub fn parseHyprModeString(s: []const u8) ModeSpec {
    var m: ModeSpec = .{};
    const at = std.mem.indexOfScalar(u8, s, '@');
    const res = if (at) |a| s[0..a] else s;
    if (std.mem.indexOfScalar(u8, res, 'x')) |x| {
        m.w = std.fmt.parseInt(i32, res[0..x], 10) catch 0;
        m.h = std.fmt.parseInt(i32, res[x + 1 ..], 10) catch 0;
    }
    if (at) |a| {
        var hzp = s[a + 1 ..];
        if (hzp.len >= 2 and std.mem.endsWith(u8, hzp, "Hz")) hzp = hzp[0 .. hzp.len - 2];
        m.hz = std.fmt.parseFloat(f64, std.mem.trim(u8, hzp, " \t")) catch 0;
    }
    return m;
}

/// Splits a stored Hyprland mode ("1920x1080@240" / "1920x1080") into
/// resolution + refresh parts (refresh without Hz suffix, may be empty).
pub fn splitHyprMode(mode: []const u8, res_out: *[]const u8, hz_out: *[]const u8) void {
    if (std.mem.indexOfScalar(u8, mode, '@')) |at| {
        res_out.* = std.mem.trim(u8, mode[0..at], " \t");
        var hz = std.mem.trim(u8, mode[at + 1 ..], " \t");
        if (hz.len >= 2 and std.mem.endsWith(u8, hz, "Hz")) hz = hz[0 .. hz.len - 2];
        hz_out.* = hz;
    } else {
        res_out.* = std.mem.trim(u8, mode, " \t");
        hz_out.* = "";
    }
}

/// Joins resolution + refresh back into a stored mode string.
pub fn joinHyprMode(res: []const u8, hz: []const u8, buf: []u8) []const u8 {
    if (hz.len == 0) {
        const n = @min(res.len, buf.len);
        @memcpy(buf[0..n], res[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s}@{s}", .{ res, hz }) catch res;
}

/// "%g"-ish float formatting: trims trailing zeros ("240.00" -> "240",
/// "59.950" -> "59.95"). Used for refresh-rate dropdown labels.
pub fn formatHz(v: f64, buf: []u8) []const u8 {
    if (!std.math.isFinite(v)) return "";
    const s = std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch return "";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    if (end == 0) return "0";
    return s[0..end];
}

// ---------------------------------------------------------------------
// OutputCaps: valid resolutions + refresh rates per output
// ---------------------------------------------------------------------

pub const OutputCaps = struct {
    n_res: usize = 0,
    res: [MAX_RES][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** MAX_RES,
    res_len: [MAX_RES]u8 = [_]u8{0} ** MAX_RES,
    hz: [MAX_RES][MAX_HZ]f64 = [_][MAX_HZ]f64{[_]f64{0} ** MAX_HZ} ** MAX_RES,
    hz_len: [MAX_RES]u8 = [_]u8{0} ** MAX_RES,

    pub fn resolution(self: *const OutputCaps, i: usize) []const u8 {
        if (i >= self.n_res) return "";
        return self.res[i][0..self.res_len[i]];
    }

    pub fn hzList(self: *const OutputCaps, i: usize) []const f64 {
        if (i >= self.n_res) return &.{};
        return self.hz[i][0..self.hz_len[i]];
    }

    pub fn findResolution(self: *const OutputCaps, s: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.n_res) : (i += 1) {
            if (std.mem.eql(u8, self.resolution(i), s)) return i;
        }
        return null;
    }

    pub fn addMode(self: *OutputCaps, w: i32, h: i32, hz: f64) void {
        if (w <= 0 or h <= 0) return;
        var rbuf: [16]u8 = undefined;
        const rk = std.fmt.bufPrint(&rbuf, "{d}x{d}", .{ w, h }) catch return;
        const ri = self.findResolution(rk) orelse blk: {
            if (self.n_res >= MAX_RES) return;
            const at = self.n_res;
            const n = @min(rk.len, 16);
            @memcpy(self.res[at][0..n], rk[0..n]);
            self.res_len[at] = @intCast(n);
            self.n_res += 1;
            break :blk at;
        };
        if (hz <= 0) return;
        const n = self.hz_len[ri];
        for (self.hz[ri][0..n]) |v| {
            if (v == hz) return;
        }
        if (n >= MAX_HZ) return;
        self.hz[ri][n] = hz;
        self.hz_len[ri] = n + 1;
    }

    pub fn sortModes(self: *OutputCaps) void {
        var i: usize = 1;
        while (i < self.n_res) : (i += 1) {
            var j = i;
            while (j > 0 and area(self, j) > area(self, j - 1)) : (j -= 1) self.swapRes(j, j - 1);
        }
        var r: usize = 0;
        while (r < self.n_res) : (r += 1) {
            const list = self.hz[r][0..self.hz_len[r]];
            var a: usize = 1;
            while (a < list.len) : (a += 1) {
                var b = a;
                while (b > 0 and list[b] > list[b - 1]) : (b -= 1) {
                    const tmp = list[b];
                    list[b] = list[b - 1];
                    list[b - 1] = tmp;
                }
            }
        }
    }

    fn area(self: *const OutputCaps, i: usize) i64 {
        const s = self.resolution(i);
        const x = std.mem.indexOfScalar(u8, s, 'x') orelse return 0;
        const w = std.fmt.parseInt(i64, s[0..x], 10) catch 0;
        const h = std.fmt.parseInt(i64, s[x + 1 ..], 10) catch 0;
        return w * h;
    }

    fn swapRes(self: *OutputCaps, a: usize, b: usize) void {
        const r = self.res[a];
        self.res[a] = self.res[b];
        self.res[b] = r;
        const rl = self.res_len[a];
        self.res_len[a] = self.res_len[b];
        self.res_len[b] = rl;
        const hl = self.hz_len[a];
        self.hz_len[a] = self.hz_len[b];
        self.hz_len[b] = hl;
        const hz = self.hz[a];
        self.hz[a] = self.hz[b];
        self.hz[b] = hz;
    }
};

/// Merges one hyprctl monitor object's `availableModes` array into caps.
/// `mobj` is the object's JSON substring (not the whole document).
pub fn mergeHyprAvailableModes(mobj: []const u8, caps: *OutputCaps) void {
    const key = "\"availableModes\"";
    const ki = std.mem.indexOf(u8, mobj, key) orelse return;
    var k = ki + key.len;
    while (k < mobj.len and (mobj[k] == ' ' or mobj[k] == '\t')) k += 1;
    if (k >= mobj.len or mobj[k] != ':') return;
    k += 1;
    while (k < mobj.len and (mobj[k] == ' ' or mobj[k] == '\t')) k += 1;
    if (k >= mobj.len or mobj[k] != '[') return;
    k += 1;
    // Quoted mode strings inside the array.
    while (k < mobj.len) {
        const q = std.mem.indexOfScalarPos(u8, mobj, k, '"') orelse break;
        const e = std.mem.indexOfScalarPos(u8, mobj, q + 1, '"') orelse break;
        const raw = mobj[q + 1 .. e];
        if (raw.len > 0) {
            const m = parseHyprModeString(raw);
            caps.addMode(m.w, m.h, m.hz);
        }
        k = e + 1;
        if (k < mobj.len and mobj[k] == ']') break;
    }
    caps.sortModes();
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// First `digits x digits` run on the line.
fn scanWxH(line: []const u8) ?struct { w: i32, h: i32, end: usize } {
    var p: usize = 0;
    while (p < line.len) {
        if (!isDigit(line[p])) {
            p += 1;
            continue;
        }
        var j = p;
        while (j < line.len and isDigit(line[j])) j += 1;
        if (j < line.len and line[j] == 'x') {
            var k = j + 1;
            while (k < line.len and isDigit(line[k])) k += 1;
            if (k > j + 1) {
                const w = std.fmt.parseInt(i32, line[p..j], 10) catch null;
                const h = std.fmt.parseInt(i32, line[j + 1 .. k], 10) catch null;
                if (w != null and h != null and w.? > 0 and h.? > 0) {
                    return .{ .w = w.?, .h = h.?, .end = k };
                }
            }
            p = k;
            continue;
        }
        p = j;
    }
    return null;
}

/// Refresh from a wlr-randr mode line: number right before "Hz".
fn scanHz(line: []const u8) f64 {
    const hz = std.mem.indexOf(u8, line, "Hz") orelse return 0;
    var e = hz;
    while (e > 0 and (line[e - 1] == ' ' or line[e - 1] == '\t')) e -= 1;
    var b = e;
    while (b > 0 and (isDigit(line[b - 1]) or line[b - 1] == '.')) b -= 1;
    if (b >= e) return 0;
    return std.fmt.parseFloat(f64, line[b..e]) catch 0;
}

pub const WlrCapsEntry = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    caps: OutputCaps = .{},

    pub fn name(self: *const WlrCapsEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Parses the FULL mode list from `wlr-randr` text (not just the current
/// mode): every indented line containing WxH + Hz becomes a caps entry.
/// Returns the number of entries filled (up to out.len).
pub fn parseWlrRandrCaps(text: []const u8, out: []WlrCapsEntry) usize {
    var n: usize = 0;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            cur = null;
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            if (sp == 0 or n >= out.len) continue;
            out[n].name_len = 0;
            out[n].caps = .{};
            const nm = line[0..sp];
            const k = @min(nm.len, out[n].name_buf.len);
            @memcpy(out[n].name_buf[0..k], nm[0..k]);
            out[n].name_len = k;
            cur = n;
            n += 1;
            continue;
        }
        const ci = cur orelse continue;
        const t = std.mem.trim(u8, line, " \t");
        // Mode lines look like "1920x1080 px, 60.000 Hz ..." or
        // "3840x2160 @ 60.000 Hz ...". Skip headers like "Modes:".
        if (std.mem.indexOf(u8, t, "Hz") == null) continue;
        const m = scanWxH(t) orelse continue;
        const hz = scanHz(t);
        out[ci].caps.addMode(m.w, m.h, hz);
    }
    for (out[0..n]) |*e| e.caps.sortModes();
    return n;
}

pub fn findCaps(entries: []const WlrCapsEntry, n: usize, name: []const u8) ?*const OutputCaps {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, entries[i].name(), name)) return &entries[i].caps;
    }
    return null;
}

// ---------------------------------------------------------------------
// Position strings ("1920x0") + scale
// ---------------------------------------------------------------------

fn strtolPrefix(s: []const u8) i32 {
    if (s.len == 0) return 0;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i = 1;
    const ds = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == ds) return 0;
    return std.fmt.parseInt(i32, s[0..i], 10) catch 0;
}

/// Splits "XxY" on the first 'x'. Returns false when there is no
/// separator (outputs untouched).
pub fn parsePositionXy(s: []const u8, ox: *i32, oy: *i32) bool {
    const sep = std.mem.indexOfScalar(u8, s, 'x') orelse return false;
    ox.* = strtolPrefix(s);
    oy.* = strtolPrefix(s[sep + 1 ..]);
    return true;
}

pub fn formatPositionXy(x: i32, y: i32, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ x, y });
}

pub fn parseScale(s: []const u8) f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch return 1.0;
    if (!std.math.isFinite(v) or v <= 0) return 1.0;
    return std.math.clamp(v, 0.25, 8.0);
}

// ---------------------------------------------------------------------
// Arrange canvas math (shared Hyprland + Mango)
// ---------------------------------------------------------------------

pub const ArrangeRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Fit = struct {
    min_x: f64 = 0,
    min_y: f64 = 0,
    span_w: f64 = 1,
    span_h: f64 = 1,
    fit_scale: f64 = 1,
};

/// Logical (post-scale) size from physical mode + scale string.
pub fn logicalExtents(phys_w: i32, phys_h: i32, scale_s: []const u8, transform: i32, lw: *i32, lh: *i32) void {
    var pw = if (phys_w > 0) phys_w else 1920;
    var ph = if (phys_h > 0) phys_h else 1080;
    if (pw <= 0) pw = 1920;
    if (ph <= 0) ph = 1080;
    const sc = parseScale(scale_s);
    var fw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(pw)) / sc));
    var fh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(ph)) / sc));
    const tr = std.math.clamp(transform, 0, 7);
    if (tr == 1 or tr == 3 or tr == 5 or tr == 7) {
        const t = fw;
        fw = fh;
        fh = t;
    }
    lw.* = @max(1, fw);
    lh.* = @max(1, fh);
}

pub fn computeCanvasFit(rects: []const ArrangeRect, cw: i32, ch: i32, pad_frac: f64) Fit {
    var f: Fit = .{};
    var mn_x: f64 = 0;
    var mn_y: f64 = 0;
    var mx_x: f64 = 0;
    var mx_y: f64 = 0;
    var any = false;
    for (rects) |r| {
        if (r.w <= 0 or r.h <= 0) continue;
        const x: f64 = @floatFromInt(r.x);
        const y: f64 = @floatFromInt(r.y);
        const x2: f64 = @floatFromInt(r.x + r.w);
        const y2: f64 = @floatFromInt(r.y + r.h);
        if (!any) {
            mn_x = x;
            mn_y = y;
            mx_x = x2;
            mx_y = y2;
            any = true;
        } else {
            mn_x = @min(mn_x, x);
            mn_y = @min(mn_y, y);
            mx_x = @max(mx_x, x2);
            mx_y = @max(mx_y, y2);
        }
    }
    if (!any) return f;
    const sw = @max(1.0, mx_x - mn_x);
    const sh = @max(1.0, mx_y - mn_y);
    const cw_f: f64 = @floatFromInt(@max(1, cw));
    const ch_f: f64 = @floatFromInt(@max(1, ch));
    const inner_w = @max(1.0, cw_f * (1.0 - 2.0 * pad_frac));
    const inner_h = @max(1.0, ch_f * (1.0 - 2.0 * pad_frac));
    f.min_x = mn_x;
    f.min_y = mn_y;
    f.span_w = sw;
    f.span_h = sh;
    f.fit_scale = @min(inner_w / sw, inner_h / sh);
    return f;
}

fn aabbOverlap(a: ArrangeRect, b: ArrangeRect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

fn separatePair(a: *ArrangeRect, b: *ArrangeRect) void {
    const axc = a.x + @divTrunc(a.w, 2);
    const bxc = b.x + @divTrunc(b.w, 2);
    const ayc = a.y + @divTrunc(a.h, 2);
    const byc = b.y + @divTrunc(b.h, 2);
    const overlap_x = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x);
    const overlap_y = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y);
    if (overlap_x <= 0 or overlap_y <= 0) return;
    if (overlap_x < overlap_y) {
        const step = @divTrunc(overlap_x + 1, 2);
        if (axc < bxc) {
            a.x -= step;
            b.x += step;
        } else {
            a.x += step;
            b.x -= step;
        }
    } else {
        const step = @divTrunc(overlap_y + 1, 2);
        if (ayc < byc) {
            a.y -= step;
            b.y += step;
        } else {
            a.y += step;
            b.y -= step;
        }
    }
}

const SNAP_PX: i32 = 40;

fn trySnap(val: i32, target: i32, threshold: i32) ?i32 {
    if (@abs(val - target) <= threshold) return target;
    return null;
}

/// Resolves overlaps, snaps the moved rect to neighbours, normalizes the
/// origin to 0,0. `disabled[i]` marks outputs to skip. Operates in place.
pub fn finalizeDrag(rects: []ArrangeRect, disabled: []const bool, moved_idx: usize) void {
    // Resolve collisions.
    var iter: i32 = 0;
    while (iter < 24) : (iter += 1) {
        var moved = false;
        for (rects, 0..) |*ri, i| {
            if (i < disabled.len and disabled[i]) continue;
            if (ri.w <= 0) continue;
            for (rects[i + 1 ..], i + 1 ..) |*rj, j| {
                if (j < disabled.len and disabled[j]) continue;
                if (rj.w <= 0) continue;
                if (!aabbOverlap(ri.*, rj.*)) continue;
                separatePair(ri, rj);
                moved = true;
            }
        }
        if (!moved) break;
    }
    // Snap moved rect to neighbours.
    if (moved_idx < rects.len and !(moved_idx < disabled.len and disabled[moved_idx]) and rects[moved_idx].w > 0) {
        const me = &rects[moved_idx];
        for (rects, 0..) |*op, j| {
            if (j == moved_idx) continue;
            if (j < disabled.len and disabled[j]) continue;
            if (op.w <= 0) continue;
            const o = op.*;
            if (trySnap(me.x, o.x - me.w, SNAP_PX)) |v| me.x = v;
            if (trySnap(me.x, o.x + o.w, SNAP_PX)) |v| me.x = v;
            if (trySnap(me.y, o.y - me.h, SNAP_PX)) |v| me.y = v;
            if (trySnap(me.y, o.y + o.h, SNAP_PX)) |v| me.y = v;
            if (trySnap(me.y, o.y, SNAP_PX)) |v| me.y = v;
            if (trySnap(me.y + me.h, o.y + o.h, SNAP_PX)) |v| me.y = v - me.h;
            if (trySnap(me.x, o.x, SNAP_PX)) |v| me.x = v;
            if (trySnap(me.x + me.w, o.x + o.w, SNAP_PX)) |v| me.x = v - me.w;
        }
    }
    // Normalize origin.
    var mn_x: i32 = std.math.maxInt(i32);
    var mn_y: i32 = std.math.maxInt(i32);
    for (rects, 0..) |*r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        mn_x = @min(mn_x, r.x);
        mn_y = @min(mn_y, r.y);
    }
    if (mn_x == std.math.maxInt(i32)) return;
    for (rects) |*r| {
        if (r.w <= 0) continue;
        r.x -= mn_x;
        r.y -= mn_y;
    }
}

/// Side-by-side arrangement: enabled outputs in order at y=0.
pub fn arrangeSideBySide(rects: []ArrangeRect, disabled: []const bool) void {
    var x: i32 = 0;
    for (rects, 0..) |*r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        r.x = x;
        r.y = 0;
        x += r.w;
    }
    // Normalize (keeps disabled rects untouched, enabled start at 0,0).
    var mn_x: i32 = std.math.maxInt(i32);
    for (rects, 0..) |*r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        mn_x = @min(mn_x, r.x);
    }
    if (mn_x == std.math.maxInt(i32)) return;
    for (rects, 0..) |*r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        r.x -= mn_x;
    }
}

/// Aligns every enabled output's top edge to the highest top.
pub fn alignTops(rects: []ArrangeRect, disabled: []const bool) void {
    var best: i32 = std.math.maxInt(i32);
    for (rects, 0..) |r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        best = @min(best, r.y);
    }
    if (best == std.math.maxInt(i32)) return;
    for (rects, 0..) |*r, i| {
        if (i < disabled.len and disabled[i]) continue;
        if (r.w <= 0) continue;
        r.y = best;
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "mode strings parse" {
    const t = std.testing;
    const m = parseHyprModeString("2560x1440@239.97Hz");
    try t.expectEqual(@as(i32, 2560), m.w);
    try t.expectEqual(@as(i32, 1440), m.h);
    try t.expect(std.math.approxEqAbs(f64, 239.97, m.hz, 0.001));
    const bare = parseHyprModeString("1920x1080");
    try t.expectEqual(@as(i32, 1920), bare.w);
    try t.expectEqual(@as(f64, 0), bare.hz);
    const nohz = parseHyprModeString("1920x1080@60");
    try t.expectEqual(@as(f64, 60), nohz.hz);
}

test "split/join hypr mode" {
    const t = std.testing;
    var res: []const u8 = "";
    var hz: []const u8 = "";
    splitHyprMode("1920x1080@240", &res, &hz);
    try t.expectEqualStrings("1920x1080", res);
    try t.expectEqualStrings("240", hz);
    splitHyprMode("1920x1080", &res, &hz);
    try t.expectEqualStrings("1920x1080", res);
    try t.expectEqualStrings("", hz);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("1920x1080@240", joinHyprMode("1920x1080", "240", &buf));
    try t.expectEqualStrings("1920x1080", joinHyprMode("1920x1080", "", &buf));
}

test "caps add/sort/dedup" {
    const t = std.testing;
    var oc: OutputCaps = .{};
    oc.addMode(1920, 1080, 60);
    oc.addMode(1920, 1080, 144);
    oc.addMode(2560, 1440, 60);
    oc.addMode(1920, 1080, 60);
    oc.sortModes();
    try t.expectEqual(@as(usize, 2), oc.n_res);
    try t.expectEqualStrings("2560x1440", oc.resolution(0));
    try t.expectEqual(@as(usize, 2), oc.hzList(1).len);
    try t.expect(std.math.approxEqAbs(f64, 144, oc.hzList(1)[0], 0.001));
}

test "merge hypr availableModes" {
    const t = std.testing;
    const obj =
        \\{"name":"DP-1","width":2560,"availableModes":["2560x1440@239.97Hz","2560x1440@144Hz","1920x1080@60Hz"]}
    ;
    var caps: OutputCaps = .{};
    mergeHyprAvailableModes(obj, &caps);
    try t.expectEqual(@as(usize, 2), caps.n_res);
    try t.expectEqualStrings("2560x1440", caps.resolution(0));
    try t.expectEqual(@as(usize, 2), caps.hzList(0).len);
}

test "parse wlr-randr caps full list" {
    const t = std.testing;
    const sample =
        \\DP-2 "AOC (DP-2)"
        \\  Modes:
        \\    1920x1080 px, 60.000000 Hz (preferred)
        \\    1920x1080 px, 240.001999 Hz (current)
        \\    1280x720 px, 60.000000 Hz
        \\  Position: 0,0
    ;
    var entries: [4]WlrCapsEntry = undefined;
    const n = parseWlrRandrCaps(sample, &entries);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqualStrings("DP-2", entries[0].name());
    try t.expectEqual(@as(usize, 2), entries[0].caps.n_res);
    // 1920x1080 has 2 distinct rates (60 + 240.002).
    const ri = entries[0].caps.findResolution("1920x1080").?;
    try t.expectEqual(@as(usize, 2), entries[0].caps.hzList(ri).len);
}

test "position parse/format" {
    const t = std.testing;
    var x: i32 = -1;
    var y: i32 = -1;
    try t.expect(parsePositionXy("1920x0", &x, &y));
    try t.expectEqual(@as(i32, 1920), x);
    try t.expectEqual(@as(i32, 0), y);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("-2560x0", try formatPositionXy(-2560, 0, &buf));
    x = 7;
    y = 9;
    try t.expect(!parsePositionXy("nope", &x, &y));
    try t.expectEqual(@as(i32, 7), x);
}

test "canvas fit + arrange" {
    const t = std.testing;
    const rects = [_]ArrangeRect{
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 },
    };
    const f = computeCanvasFit(&rects, 600, 300, 0.1);
    try t.expect(std.math.approxEqAbs(f64, 0.125, f.fit_scale, 1e-9));

    var mut = [_]ArrangeRect{
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    };
    const dis = [_]bool{ false, false };
    finalizeDrag(&mut, &dis, 1);
    // Stacked pair must separate.
    try t.expect(mut[0].x != mut[1].x or mut[0].y != mut[1].y);

    var row = [_]ArrangeRect{
        .{ .x = 500, .y = 300, .w = 1920, .h = 1080 },
        .{ .x = 99, .y = 77, .w = 1280, .h = 720 },
    };
    arrangeSideBySide(&row, &dis);
    try t.expectEqual(@as(i32, 0), row[0].x);
    try t.expectEqual(@as(i32, 0), row[0].y);
    try t.expectEqual(@as(i32, 1920), row[1].x);
}

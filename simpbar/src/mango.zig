// Simpbar Config — MangoWM config model.
//
// MangoWM (mangowm) is configured by a flat set of `key = value` files under
// ~/.config/mango/cfg/, all pulled in by ~/.config/mango/config.conf via
// `source = ./cfg/<name>.conf`. There is no in-memory daemon state to speak
// of — the files ARE the config, and `mmsg dispatch reload_config` re-reads
// them. So the model here is deliberately simple: each file is loaded as an
// ordered list of owned lines, edited line-by-line (which preserves the
// user's comments and grouping exactly), and written back atomically.
//
// This mirrors hyprland.zig's role for the Hyprland pages, but Mango's config
// is plain INI-ish text rather than a Lua snippet, so the model is much
// smaller: get/set/append/remove a `key = value` line, and iterate the lines
// that carry a given multi-value key (bind, window_rule, exec_once, ...).

const std = @import("std");

const gpa = std.heap.c_allocator;

// Raw libc file I/O (mirrors hyprland.zig — Zig 0.16's std.Io.Dir wants an
// explicit Io instance for every operation, which is overkill here).
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY_CREAT_TRUNC: c_int = 1 | 0o100 | 0o1000; // O_WRONLY|O_CREAT|O_TRUNC

fn writeAll(path: [*:0]const u8, data: []const u8) bool {
    const fd = open(path, O_WRONLY_CREAT_TRUNC, 0o644);
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

/// Longest config line we will round-trip. Mango values (a spawn command, a
/// colour list, a scroller proportion preset) are all far below this.
pub const MAX_LINE = 1024;

/// A parsed `key = value` pair, with both sides trimmed. The slices point
/// into the line buffer they were parsed from.
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Returns the key/value of `line` if it is a non-comment `key = value` line,
/// else null. Leading/trailing whitespace around the key and value is trimmed;
/// the key keeps its original case (Mango keys are lower_snake_case).
pub fn parseKV(line: []const u8) ?KV {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    const key = std.mem.trim(u8, t[0..eq], " \t");
    if (key.len == 0) return null;
    return .{ .key = key, .value = std.mem.trim(u8, t[eq + 1 ..], " \t\r") };
}

/// One Mango config file, held as an ordered list of owned lines.
pub const Doc = struct {
    path: []u8 = &.{}, // owned; empty until load()
    lines: std.ArrayList([]u8) = .empty,

    pub fn isLoaded(self: *const Doc) bool {
        return self.path.len != 0;
    }

    /// (Re)loads `path` from disk. A missing file yields an empty document
    /// with the path remembered, so editing creates it on the first save.
    pub fn load(self: *Doc, path: []const u8) void {
        self.reset();
        self.path = gpa.dupe(u8, path) catch {
            self.path = &.{};
            return;
        };

        var pbuf: [1024]u8 = undefined;
        if (path.len + 1 > pbuf.len) return;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const fd = open(pbuf[0..path.len :0].ptr, O_RDONLY, 0);
        if (fd < 0) return;
        defer _ = close(fd);

        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = read(fd, &chunk, chunk.len);
            if (n <= 0) break;
            data.appendSlice(gpa, chunk[0..@intCast(n)]) catch return;
            if (data.items.len > 4 * 1024 * 1024) break;
        }

        var it = std.mem.splitScalar(u8, data.items, '\n');
        while (it.next()) |raw| {
            // splitScalar yields a trailing "" for a file ending in '\n';
            // skip just that one so save() (which re-adds '\n' per line)
            // round-trips cleanly instead of growing the file each time.
            if (raw.len == 0 and it.index == null) continue;
            const copy = gpa.dupe(u8, raw) catch return;
            self.lines.append(gpa, copy) catch {
                gpa.free(copy);
                return;
            };
        }
    }

    /// Releases every line and the path. Safe to call on a fresh Doc.
    pub fn reset(self: *Doc) void {
        for (self.lines.items) |l| gpa.free(l);
        self.lines.clearRetainingCapacity();
        if (self.path.len != 0) gpa.free(self.path);
        self.path = &.{};
    }

    /// Writes the document back via a same-directory temp file + rename, so a
    /// concurrent reload never observes a half-written file.
    pub fn save(self: *Doc) bool {
        if (self.path.len == 0) return false;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        for (self.lines.items) |l| {
            buf.appendSlice(gpa, l) catch return false;
            buf.append(gpa, '\n') catch return false;
        }

        const dir_end = std.mem.lastIndexOfScalar(u8, self.path, '/') orelse return false;
        var tmp_buf: [MAX_LINE + 64]u8 = undefined;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.simpbar-mango-tmp", .{self.path[0..dir_end]}) catch return false;

        if (!writeAll(tmp.ptr, buf.items)) {
            _ = unlink(tmp.ptr);
            return false;
        }

        var path_buf: [MAX_LINE + 64]u8 = undefined;
        if (self.path.len + 1 > path_buf.len) {
            _ = unlink(tmp.ptr);
            return false;
        }
        @memcpy(path_buf[0..self.path.len], self.path);
        path_buf[self.path.len] = 0;
        if (rename(tmp.ptr, path_buf[0..self.path.len :0].ptr) != 0) {
            _ = unlink(tmp.ptr);
            return false;
        }
        return true;
    }

    // -- line access ----------------------------------------------------

    pub fn lineCount(self: *const Doc) usize {
        return self.lines.items.len;
    }

    pub fn line(self: *const Doc, i: usize) []const u8 {
        return self.lines.items[i];
    }

    /// Index of the first line carrying `key`, or null.
    pub fn lineIndexOf(self: *const Doc, key: []const u8) ?usize {
        for (self.lines.items, 0..) |l, i| {
            if (parseKV(l)) |kv| {
                if (std.mem.eql(u8, kv.key, key)) return i;
            }
        }
        return null;
    }

    /// Replaces line `i` (freeing the old copy). Out-of-range is a no-op.
    pub fn setLine(self: *Doc, i: usize, text: []const u8) void {
        if (i >= self.lines.items.len) return;
        const copy = gpa.dupe(u8, text) catch return;
        gpa.free(self.lines.items[i]);
        self.lines.items[i] = copy;
    }

    /// Removes line `i` (freeing it). Out-of-range is a no-op.
    pub fn removeLine(self: *Doc, i: usize) void {
        if (i >= self.lines.items.len) return;
        gpa.free(self.lines.orderedRemove(i));
    }

    pub fn appendLine(self: *Doc, text: []const u8) void {
        const copy = gpa.dupe(u8, text) catch return;
        self.lines.append(gpa, copy) catch {
            gpa.free(copy);
            return;
        };
    }

    // -- single-value helpers -------------------------------------------

    /// First value for `key`, or null.
    pub fn value(self: *const Doc, key: []const u8) ?[]const u8 {
        const i = self.lineIndexOf(key) orelse return null;
        return (parseKV(self.lines.items[i]) orelse return null).value;
    }

    /// Sets `key = value`, replacing the first existing line in place (so its
    /// position and neighbours are preserved) or appending when absent.
    pub fn setValue(self: *Doc, key: []const u8, val: []const u8) void {
        var b: [MAX_LINE]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{s} = {s}", .{ key, val }) catch return;
        if (self.lineIndexOf(key)) |i| {
            self.setLine(i, s);
        } else {
            self.appendLine(s);
        }
    }

    /// Same as setValue but formats the value first.
    pub fn setValueFmt(self: *Doc, key: []const u8, comptime fmt: []const u8, args: anytype) void {
        var b: [MAX_LINE]u8 = undefined;
        const v = std.fmt.bufPrint(&b, fmt, args) catch return;
        self.setValue(key, v);
    }

    pub fn getBool(self: *const Doc, key: []const u8, default: bool) bool {
        const v = self.value(key) orelse return default;
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes")) return true;
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no")) return false;
        return default;
    }

    pub fn getInt(self: *const Doc, key: []const u8, default: i64) i64 {
        const v = self.value(key) orelse return default;
        return std.fmt.parseInt(i64, v, 10) catch default;
    }

    pub fn getFloat(self: *const Doc, key: []const u8, default: f64) f64 {
        const v = self.value(key) orelse return default;
        return std.fmt.parseFloat(f64, v) catch default;
    }
};

//! Cursor / GTK / icon theme discovery and apply for simpbar-config.
//!
//! Discovery scans the user's drop-in dirs first — ~/.cursors for cursors,
//! ~/.themes for GTK themes, ~/.icons for icons — then the XDG user dirs
//! (~/.local/share/icons, ~/.local/share/themes) and finally the system
//! dirs (/usr/share/icons, /usr/share/themes). A directory only counts when
//! it carries the kind's marker: a `cursors/` subdir for cursor themes,
//! gtk-3.0/gtk.css (or gtk-4.0/gtk.css) for GTK themes, index.theme plus an
//! icon subdir for icon themes.
//!
//! Applying goes through gsettings (the same mechanism nwg-look reads and
//! writes, so both tools agree) plus ~/.config/gtk-3.0/gtk-4.0/settings.ini
//! so non-GNOME clients see the same theme. Everything here is best-effort:
//! no failure may break the settings page being built.

const std = @import("std");

const gpa = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(dirp: *anyopaque) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fork() c_int;

/// glibc dirent on Linux: d_name starts after ino(8) + off(8) +
/// reclen(2) + type(1). Only the name is read; the rest is padding here.
const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};
extern "c" fn readdir(dirp: *anyopaque) ?*Dirent;

const O_RDONLY: c_int = 0;
const O_WRONLY_CREAT_TRUNC: c_int = 1 | 0o100 | 0o1000; // O_WRONLY|O_CREAT|O_TRUNC

pub const MAX_NAMES = 96;
pub const MAX_NAME = 128;

fn homeDir() []const u8 {
    if (getenv("HOME")) |h| return std.mem.span(h);
    return "/root";
}

fn isDir(path: []const u8) bool {
    var zbuf: [576]u8 = undefined;
    if (path.len + 1 > zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const d = opendir(zbuf[0..path.len :0]) orelse return false;
    _ = closedir(d);
    return true;
}

fn fileExists(path: []const u8) bool {
    var zbuf: [576]u8 = undefined;
    if (path.len + 1 > zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = open(zbuf[0..path.len :0], O_RDONLY, 0);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

/// Fixed-capacity sorted name set with stable pointer views for combo rows.
/// Storage lives for the process's life (like the font entries in
/// config_main.zig); GtkStringList copies what it is given anyway.
const ThemeList = struct {
    count: usize = 0,
    lens: [MAX_NAMES]usize = undefined,
    names: [MAX_NAMES][MAX_NAME:0]u8 = undefined,
    labels: [MAX_NAMES][*:0]const u8 = undefined,
    values: [MAX_NAMES][]const u8 = undefined,

    fn clear(self: *ThemeList) void {
        self.count = 0;
    }

    fn add(self: *ThemeList, name: []const u8) void {
        if (name.len == 0 or name.len >= MAX_NAME) return;
        for (name) |c| {
            if (c == '\n' or c == '\r' or c == 0) return;
        }
        for (self.values[0..self.count]) |v| {
            if (std.mem.eql(u8, v, name)) return;
        }
        if (self.count >= MAX_NAMES) return;
        const slot = &self.names[self.count];
        @memcpy(slot[0..name.len], name);
        slot[name.len] = 0;
        self.lens[self.count] = name.len;
        self.count += 1;
        self.rebuild(self.count - 1);
    }

    fn rebuild(self: *ThemeList, i: usize) void {
        const n = self.lens[i];
        self.labels[i] = self.names[i][0..n :0];
        self.values[i] = self.names[i][0..n];
    }

    /// Appends `name` when it isn't listed yet (so the dropdown's selection
    /// stays truthful for a currently-configured theme the scan didn't
    /// find), keeping sort order.
    fn ensure(self: *ThemeList, name: []const u8) void {
        if (name.len == 0) return;
        for (self.values[0..self.count]) |v| {
            if (std.mem.eql(u8, v, name)) return;
        }
        self.add(name);
        self.sort();
    }

    fn sort(self: *ThemeList) void {
        var i: usize = 1;
        while (i < self.count) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.lessThan(u8, self.names[j][0..self.lens[j]], self.names[j - 1][0..self.lens[j - 1]])) {
                std.mem.swap([MAX_NAME:0]u8, &self.names[j], &self.names[j - 1]);
                std.mem.swap(usize, &self.lens[j], &self.lens[j - 1]);
                j -= 1;
            }
        }
        for (0..self.count) |k| self.rebuild(k);
    }
};

var cursors: ThemeList = .{};
var gtk_themes: ThemeList = .{};
var icon_themes: ThemeList = .{};

const Kind = enum { cursor, gtk, icon };

fn join3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ a, b, c }) catch null;
}

fn qualify(kind: Kind, root: []const u8, name: []const u8) bool {
    var pbuf: [576]u8 = undefined;
    switch (kind) {
        .cursor => {
            const p = join3(&pbuf, root, name, "cursors") orelse return false;
            return isDir(p);
        },
        .gtk => {
            const p3 = join3(&pbuf, root, name, "gtk-3.0/gtk.css") orelse return false;
            if (fileExists(p3)) return true;
            const p4 = join3(&pbuf, root, name, "gtk-4.0/gtk.css") orelse return false;
            return fileExists(p4);
        },
        .icon => {
            const idx = join3(&pbuf, root, name, "index.theme") orelse return false;
            if (!fileExists(idx)) return false;
            const subdirs = [_][]const u8{
                "scalable", "symbolic", "apps", "places", "devices", "mimetypes",
                "16x16",  "22x22",  "24x24",  "32x32",  "48x48",  "64x64",
                "128x128", "256x256",
            };
            for (subdirs) |s| {
                const p = join3(&pbuf, root, name, s) orelse continue;
                if (isDir(p)) return true;
            }
            const cache = join3(&pbuf, root, name, "icon-theme.cache") orelse return false;
            return fileExists(cache);
        },
    }
}

fn scanRoot(list: *ThemeList, kind: Kind, root: []const u8) void {
    var zroot: [512]u8 = undefined;
    if (root.len + 1 > zroot.len) return;
    @memcpy(zroot[0..root.len], root);
    zroot[root.len] = 0;
    const dir = opendir(zroot[0..root.len :0]) orelse return;
    defer _ = closedir(dir);
    while (readdir(dir)) |e| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!qualify(kind, root, name)) continue;
        list.add(name);
    }
}

fn scanInto(list: *ThemeList, kind: Kind) void {
    list.clear();
    const home = homeDir();
    const rels: []const []const u8 = switch (kind) {
        .cursor => &.{ ".cursors", ".icons", ".local/share/icons" },
        .gtk => &.{ ".themes", ".local/share/themes" },
        .icon => &.{ ".icons", ".local/share/icons" },
    };
    var hbuf: [512]u8 = undefined;
    for (rels) |r| {
        const p = std.fmt.bufPrint(&hbuf, "{s}/{s}", .{ home, r }) catch continue;
        scanRoot(list, kind, p);
    }
    const abs: []const []const u8 = switch (kind) {
        .cursor, .icon => &.{"/usr/share/icons"},
        .gtk => &.{"/usr/share/themes"},
    };
    for (abs) |p| scanRoot(list, kind, p);
    list.sort();
}

pub fn discoverCursors() void {
    scanInto(&cursors, .cursor);
}

pub fn discoverGtkThemes() void {
    scanInto(&gtk_themes, .gtk);
}

pub fn discoverIcons() void {
    scanInto(&icon_themes, .icon);
}

pub fn cursorLabels() []const [*:0]const u8 {
    return cursors.labels[0..cursors.count];
}

pub fn cursorValues() []const []const u8 {
    return cursors.values[0..cursors.count];
}

pub fn gtkLabels() []const [*:0]const u8 {
    return gtk_themes.labels[0..gtk_themes.count];
}

pub fn gtkValues() []const []const u8 {
    return gtk_themes.values[0..gtk_themes.count];
}

pub fn iconLabels() []const [*:0]const u8 {
    return icon_themes.labels[0..icon_themes.count];
}

pub fn iconValues() []const []const u8 {
    return icon_themes.values[0..icon_themes.count];
}

pub fn ensureCursorPresent(name: []const u8) void {
    cursors.ensure(name);
}

pub fn ensureGtkPresent(name: []const u8) void {
    gtk_themes.ensure(name);
}

pub fn ensureIconPresent(name: []const u8) void {
    icon_themes.ensure(name);
}

// ---------------------------------------------------------------------
// Process helpers (fork/execve like hyprland.zig's runQuiet/captureOutput)
// ---------------------------------------------------------------------

const MAX_ARGV = 12;
const MAX_ARG = 256;

fn buildArgv(argv: []const []const u8, zbufs: *[MAX_ARGV][MAX_ARG]u8, out: *[MAX_ARGV + 1]?[*:0]const u8) bool {
    if (argv.len == 0 or argv.len > MAX_ARGV) return false;
    out[0] = "/usr/bin/env";
    for (argv, 0..) |a, i| {
        if (a.len >= MAX_ARG) return false;
        @memcpy(zbufs[i][0..a.len], a);
        zbufs[i][a.len] = 0;
        out[i + 1] = zbufs[i][0..a.len :0];
    }
    out[argv.len + 1] = null;
    return true;
}

/// Fire-and-forget spawn; waits for the child. Best-effort: the caller
/// never branches on the result for UI construction.
pub fn spawnWait(argv: []const []const u8) bool {
    var zbufs: [MAX_ARGV][MAX_ARG]u8 = undefined;
    var exec_argv: [MAX_ARGV + 1]?[*:0]const u8 = undefined;
    if (!buildArgv(argv, &zbufs, &exec_argv)) return false;
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = std.c.execve("/usr/bin/env", @ptrCast(&exec_argv), std.c.environ);
        std.c._exit(127);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    return true;
}

/// Captures stdout (up to 4KB); null on any failure, timeout, or empty
/// output. Caller owns the slice (gpa).
pub fn captureOneLine(argv: []const []const u8) ?[]u8 {
    var zbufs: [MAX_ARGV][MAX_ARG]u8 = undefined;
    var exec_argv: [MAX_ARGV + 1]?[*:0]const u8 = undefined;
    if (!buildArgv(argv, &zbufs, &exec_argv)) return null;
    var fds: [2]c_int = undefined;
    // pipe/dup2/poll mirror hyprland.zig's helpers; declared locally so
    // this module stays dependency-free.
    const S = struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
        extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
    };
    if (S.pipe(&fds) != 0) return null;
    const pid = fork();
    if (pid < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = close(fds[0]);
        _ = S.dup2(fds[1], 1);
        _ = close(fds[1]);
        _ = std.c.execve("/usr/bin/env", @ptrCast(&exec_argv), std.c.environ);
        std.c._exit(127);
    }
    _ = close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [512]u8 = undefined;
    var done = false;
    while (!done) {
        var pfd = [1]PollFd{.{ .fd = fds[0], .events = POLLIN, .revents = 0 }};
        if (S.poll(&pfd, 1, 3000) <= 0) break;
        const n = read(fds[0], &chunk, chunk.len);
        if (n <= 0) {
            done = n == 0;
            break;
        }
        if (out.items.len + @as(usize, @intCast(n)) > 4096) break;
        out.appendSlice(gpa, chunk[0..@intCast(n)]) catch break;
    }
    _ = close(fds[0]);
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
const POLLIN: i16 = 0x0001;

/// Trims whitespace and one layer of surrounding single quotes (gsettings
/// prints strings like 'Bibata-Modern-Classic') into `buf`.
fn unquoteInto(s: []const u8, buf: []u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and t[0] == '\'' and t[t.len - 1] == '\'') t = t[1 .. t.len - 1];
    const n = @min(t.len, buf.len);
    @memcpy(buf[0..n], t[0..n]);
    return buf[0..n];
}

fn gsettingsGetBuf(key: []const u8, buf: []u8) []const u8 {
    const out = captureOneLine(&.{ "gsettings", "get", "org.gnome.desktop.interface", key }) orelse return "";
    defer gpa.free(out);
    return unquoteInto(out, buf);
}

pub fn currentCursorThemeBuf(buf: []u8) []const u8 {
    return gsettingsGetBuf("cursor-theme", buf);
}

pub fn currentCursorSize() u32 {
    var tmp: [32]u8 = undefined;
    const s = gsettingsGetBuf("cursor-size", &tmp);
    const v = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 10) catch return 24;
    return std.math.clamp(v, 8, 128);
}

// ---------------------------------------------------------------------
// settings.ini (~/.config/gtk-3.0 and gtk-4.0)
// ---------------------------------------------------------------------

fn iniPath(buf: []u8, subdir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.config/{s}/settings.ini", .{ homeDir(), subdir }) catch null;
}

fn readFileAll(path: []const u8) ?[]u8 {
    var zbuf: [512]u8 = undefined;
    if (path.len + 1 > zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = open(zbuf[0..path.len :0], O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [2048]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > 65536) break;
        out.appendSlice(gpa, chunk[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Reads `key` from ~/.config/<subdir>/settings.ini into `buf`.
fn readIniKey(subdir: []const u8, key: []const u8, buf: []u8) []const u8 {
    var pbuf: [512]u8 = undefined;
    const path = iniPath(&pbuf, subdir) orelse return "";
    const data = readFileAll(path) orelse return "";
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) {
            const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            const n = @min(v.len, buf.len);
            @memcpy(buf[0..n], v[0..n]);
            return buf[0..n];
        }
    }
    return "";
}

/// Merges one `key=value` into INI text: drops existing `key` lines,
/// ensures a [Settings] section, appends the new line. Pure (tested).
fn buildIni(existing: []const u8, key: []const u8, value: []const u8, out: *std.ArrayList(u8)) void {
    var saw_settings = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            if (std.ascii.eqlIgnoreCase(trimmed, "[Settings]")) saw_settings = true;
            out.appendSlice(gpa, trimmed) catch continue;
            out.append(gpa, '\n') catch continue;
            continue;
        }
        if (trimmed[0] == '#' or trimmed[0] == ';') {
            out.appendSlice(gpa, trimmed) catch continue;
            out.append(gpa, '\n') catch continue;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            out.appendSlice(gpa, trimmed) catch continue;
            out.append(gpa, '\n') catch continue;
            continue;
        };
        if (std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], " \t"), key)) continue;
        out.appendSlice(gpa, trimmed) catch continue;
        out.append(gpa, '\n') catch continue;
    }
    if (!saw_settings) {
        out.appendSlice(gpa, "[Settings]\n") catch {};
    }
    out.appendSlice(gpa, key) catch {};
    out.append(gpa, '=') catch {};
    out.appendSlice(gpa, value) catch {};
    out.append(gpa, '\n') catch {};
}

fn writeFileAtomic(path: []const u8, data: []const u8) bool {
    var tbuf: [560]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tbuf, "{s}.tmp", .{path}) catch return false;
    var ztmp: [576]u8 = undefined;
    if (tmp.len + 1 > ztmp.len) return false;
    @memcpy(ztmp[0..tmp.len], tmp);
    ztmp[tmp.len] = 0;
    const fd = open(ztmp[0..tmp.len :0], O_WRONLY_CREAT_TRUNC, 0o644);
    if (fd < 0) return false;
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) {
            _ = close(fd);
            return false;
        }
        off += @intCast(n);
    }
    _ = close(fd);
    var zpath: [560]u8 = undefined;
    if (path.len + 1 > zpath.len) return false;
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    if (rename(ztmp[0..tmp.len :0], zpath[0..path.len :0]) != 0) return false;
    return true;
}

/// Sets `key=value` in ~/.config/<subdir>/settings.ini, preserving every
/// other line. Creates the directory and file when missing.
pub fn writeIniKey(subdir: []const u8, key: []const u8, value: []const u8) void {
    var dbuf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/.config/{s}", .{ homeDir(), subdir }) catch return;
    var zdir: [528]u8 = undefined;
    if (dir.len + 1 > zdir.len) return;
    @memcpy(zdir[0..dir.len], dir);
    zdir[dir.len] = 0;
    _ = mkdir(zdir[0..dir.len :0], 0o755);
    var pbuf: [512]u8 = undefined;
    const path = iniPath(&pbuf, subdir) orelse return;
    const existing = readFileAll(path);
    defer if (existing) |e| gpa.free(e);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    buildIni(existing orelse "", key, value, &out);
    _ = writeFileAtomic(path, out.items);
}

// ---------------------------------------------------------------------
// Current values and apply
// ---------------------------------------------------------------------

pub fn currentGtkThemeBuf(buf: []u8) []const u8 {
    const from_ini = readIniKey("gtk-3.0", "gtk-theme-name", buf);
    if (from_ini.len != 0) return from_ini;
    const gs = gsettingsGetBuf("gtk-theme", buf);
    if (gs.len != 0) return gs;
    const fallback = "Adwaita";
    const n = @min(fallback.len, buf.len);
    @memcpy(buf[0..n], fallback);
    return buf[0..n];
}

pub fn currentIconThemeBuf(buf: []u8) []const u8 {
    const from_ini = readIniKey("gtk-3.0", "gtk-icon-theme-name", buf);
    if (from_ini.len != 0) return from_ini;
    const gs = gsettingsGetBuf("icon-theme", buf);
    if (gs.len != 0) return gs;
    const fallback = "Adwaita";
    const n = @min(fallback.len, buf.len);
    @memcpy(buf[0..n], fallback);
    return buf[0..n];
}

pub fn applyCursorTheme(name: []const u8) void {
    if (name.len == 0) return;
    _ = spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", name });
}

pub fn applyCursorSize(size: u32) void {
    var nbuf: [16]u8 = undefined;
    const n = std.fmt.bufPrint(&nbuf, "{d}", .{size}) catch return;
    _ = spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.interface", "cursor-size", n });
}

pub fn applyGtkTheme(name: []const u8) void {
    if (name.len == 0) return;
    writeIniKey("gtk-3.0", "gtk-theme-name", name);
    writeIniKey("gtk-4.0", "gtk-theme-name", name);
    _ = spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", name });
}

pub fn applyIconTheme(name: []const u8) void {
    if (name.len == 0) return;
    writeIniKey("gtk-3.0", "gtk-icon-theme-name", name);
    writeIniKey("gtk-4.0", "gtk-icon-theme-name", name);
    _ = spawnWait(&.{ "gsettings", "set", "org.gnome.desktop.interface", "icon-theme", name });
}

/// Live-applies the cursor under Hyprland without a session restart.
pub fn refreshHyprCursor(theme: []const u8, size: u32) void {
    if (theme.len == 0) return;
    var nbuf: [16]u8 = undefined;
    const n = std.fmt.bufPrint(&nbuf, "{d}", .{size}) catch return;
    _ = spawnWait(&.{ "hyprctl", "setcursor", theme, n });
}

// ---------------------------------------------------------------------
// Monitor auto-detection (for the Monitors pages).
//
// Sources, in order: `hyprctl monitors -j` on Hyprland (name, resolution,
// refresh, position, scale); `wlr-randr` on Mango (same set, parsed from
// its text output); `mmsg get all-monitors` as the Mango fallback (name,
// resolution, position, scale — no refresh rate there, so refresh stays 0
// meaning unknown and callers preserve whatever was configured).
// ---------------------------------------------------------------------

pub const DetectedMonitor = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    refresh: u32 = 0, // rounded Hz; 0 = unknown
    x: i32 = 0,
    y: i32 = 0,
    scale: f32 = 1.0,
    has_scale: bool = false,
    enabled: bool = true,

    pub fn name(self: *const DetectedMonitor) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *DetectedMonitor, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = n;
    }
};

pub const MAX_DETECTED = 8;

var detected: [MAX_DETECTED]DetectedMonitor = undefined;
var detected_n: usize = 0;

pub fn detectedMonitors() []DetectedMonitor {
    return detected[0..detected_n];
}

/// Formats a scale factor the way compositor configs spell it ("1",
/// "1.5" — never "1.00").
pub fn formatScale(scale: f32, buf: []u8) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.2}", .{scale}) catch return "1";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    if (end == 0) return "1";
    return s[0..end];
}

fn skipBlank(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) : (i.* += 1) {}
}

/// At s[i] == '"': the raw string body (escapes kept verbatim — monitor
/// names never contain quotes), advancing past the closing quote.
fn parseJsonString(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= s.len or s[i.*] != '"') return null;
    i.* += 1;
    const start = i.*;
    while (i.* < s.len and s[i.*] != '"') : (i.* += 1) {
        if (s[i.*] == '\\' and i.* + 1 < s.len) i.* += 1;
    }
    if (i.* >= s.len) return null;
    const out = s[start..i.*];
    i.* += 1;
    return out;
}

/// A JSON number (int or float) at i, advancing past it.
fn parseJsonNumber(s: []const u8, i: *usize) ?f64 {
    const start = i.*;
    if (i.* < s.len and (s[i.*] == '-' or s[i.*] == '+')) i.* += 1;
    var digits = false;
    while (i.* < s.len and ((s[i.*] >= '0' and s[i.*] <= '9') or s[i.*] == '.')) : (i.* += 1) {
        if (s[i.*] >= '0' and s[i.*] <= '9') digits = true;
    }
    if (!digits) return null;
    return std.fmt.parseFloat(f64, s[start..i.*]) catch null;
}

fn clampU32(v: f64) u32 {
    if (v < 0 or v > 16384) return 0;
    return @intFromFloat(@round(v));
}

/// Locates the monitors array region: mmsg's `"monitors": [...]` member,
/// else a top-level `[...]` (hyprctl). Returns the bracket contents.
/// Strings are skipped while bracket-matching so a `]` inside a quoted
/// description can't end the scan early.
fn monitorsRegion(text: []const u8) ?[]const u8 {
    var start: usize = 0;
    if (std.mem.indexOf(u8, text, "\"monitors\"")) |ki| {
        var k = ki + "\"monitors\"".len;
        while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
        if (k < text.len and text[k] == ':') {
            k += 1;
            while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
            if (k < text.len and text[k] == '[') start = k + 1;
        }
    } else {
        var k: usize = 0;
        while (k < text.len and (text[k] == ' ' or text[k] == '\t' or text[k] == '\r' or text[k] == '\n')) k += 1;
        if (k < text.len and text[k] == '[') start = k + 1;
    }
    if (start == 0) return null;
    var depth: usize = 1; // inside the array bracket
    var i = start;
    while (i < text.len) {
        if (text[i] == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            i += 1;
            continue;
        }
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) return text[start..i];
        }
        i += 1;
    }
    return null;
}

/// Monitor objects of the monitors region: its depth-1 members. Nested
/// objects (tags, workspaces, clients) sit deeper and are skipped; only
/// name/width/height/refreshRate/x/y/scale are captured. An object counts
/// when it has a name plus dimensions.
fn parseMonitorObjects(text: []const u8) usize {
    detected_n = 0;
    const region = monitorsRegion(text) orelse return 0;
    var depth: usize = 0;
    var cur: ?usize = null;
    var i: usize = 0;
    while (i < region.len) {
        const c = region[i];
        if (c == '{') {
            depth += 1;
            if (depth == 1) {
                if (detected_n < MAX_DETECTED) {
                    cur = detected_n;
                    detected[detected_n] = .{};
                } else {
                    cur = null;
                }
            }
            i += 1;
            continue;
        }
        if (c == '}') {
            if (depth == 1) {
                if (cur) |ci| {
                    if (detected[ci].name_len != 0 and detected[ci].width != 0 and detected[ci].height != 0) {
                        detected_n += 1;
                    }
                }
                cur = null;
            }
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (depth != 1 or cur == null or c != '"') {
            i += 1;
            continue;
        }
        const ci = cur.?;
        var j = i;
        const key = parseJsonString(region, &j) orelse {
            i += 1;
            continue;
        };
        var k = j;
        skipBlank(region, &k);
        if (k >= region.len or region[k] != ':') {
            i += 1;
            continue;
        }
        k += 1;
        skipBlank(region, &k);
        if (std.mem.eql(u8, key, "name")) {
            if (parseJsonString(region, &k)) |v| detected[ci].setName(v);
            i = k;
            continue;
        }
        if (parseJsonNumber(region, &k)) |v| {
            if (std.mem.eql(u8, key, "width")) detected[ci].width = clampU32(v);
            if (std.mem.eql(u8, key, "height")) detected[ci].height = clampU32(v);
            if (std.mem.eql(u8, key, "x")) detected[ci].x = @intFromFloat(@round(std.math.clamp(v, -16384, 16384)));
            if (std.mem.eql(u8, key, "y")) detected[ci].y = @intFromFloat(@round(std.math.clamp(v, -16384, 16384)));
            if (std.mem.eql(u8, key, "scale")) {
                detected[ci].scale = @floatCast(std.math.clamp(v, 0.5, 4.0));
                detected[ci].has_scale = true;
            }
            if (std.mem.eql(u8, key, "refreshRate")) detected[ci].refresh = clampU32(v);
        }
        i = k;
    }
    return detected_n;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// First `digits x digits` run on the line (the mode), e.g. 1920x1080.
fn scanWxH(line: []const u8) ?struct { w: u32, h: u32 } {
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
                const w = std.fmt.parseInt(u32, line[p..j], 10) catch null;
                const h = std.fmt.parseInt(u32, line[j + 1 .. k], 10) catch null;
                if (w != null and h != null and w.? != 0 and h.? != 0) return .{ .w = w.?, .h = h.? };
                p = k;
                continue;
            }
        }
        p = j;
    }
    return null;
}

/// Refresh from a current-mode line: the number right before "Hz"
/// (covers both "1920x1080 px, 60.000 Hz" and "1920x1080 @ 60 Hz").
fn scanHz(line: []const u8) u32 {
    const hz = std.mem.indexOf(u8, line, "Hz") orelse return 0;
    var e = hz;
    while (e > 0 and (line[e - 1] == ' ' or line[e - 1] == '\t')) e -= 1;
    var b = e;
    while (b > 0 and (isDigit(line[b - 1]) or line[b - 1] == '.')) b -= 1;
    if (b >= e) return 0;
    const v = std.fmt.parseFloat(f64, line[b..e]) catch return 0;
    return clampU32(v);
}

fn parseWlrModeLine(line: []const u8, d: *DetectedMonitor) void {
    if (scanWxH(line)) |m| {
        d.width = m.w;
        d.height = m.h;
    }
    d.refresh = scanHz(line);
}

/// wlr-randr text: `NAME "desc..."` headers, then indented details —
/// `Enabled:`, a `Modes:` line with one `(current)` entry, `Position:`,
/// `Scale:`. Disabled outputs are collected but flagged off.
fn parseWlrRandr(text: []const u8) usize {
    detected_n = 0;
    var filled: usize = 0;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            cur = null;
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            if (sp == 0 or filled >= MAX_DETECTED) continue;
            cur = filled;
            detected[filled] = .{};
            detected[filled].setName(line[0..sp]);
            filled += 1;
            continue;
        }
        const ci = cur orelse continue;
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "Enabled:")) {
            const rest = std.mem.trim(u8, t["Enabled:".len..], " \t");
            detected[ci].enabled = std.ascii.eqlIgnoreCase(rest, "yes");
        } else if (std.mem.indexOf(u8, t, "current") != null and std.mem.indexOf(u8, t, "Hz") != null) {
            parseWlrModeLine(t, &detected[ci]);
        } else if (std.mem.startsWith(u8, t, "Position:")) {
            const rest = std.mem.trim(u8, t["Position:".len..], " \t");
            const comma = std.mem.indexOfScalar(u8, rest, ',') orelse continue;
            const px = std.fmt.parseInt(i32, std.mem.trim(u8, rest[0..comma], " \t"), 10) catch continue;
            const py = std.fmt.parseInt(i32, std.mem.trim(u8, rest[comma + 1 ..], " \t"), 10) catch continue;
            detected[ci].x = std.math.clamp(px, -16384, 16384);
            detected[ci].y = std.math.clamp(py, -16384, 16384);
        } else if (std.mem.startsWith(u8, t, "Scale:")) {
            const rest = std.mem.trim(u8, t["Scale:".len..], " \t");
            var e: usize = 0;
            while (e < rest.len and (isDigit(rest[e]) or rest[e] == '.')) e += 1;
            if (e == 0) continue;
            const v = std.fmt.parseFloat(f64, rest[0..e]) catch continue;
            detected[ci].scale = @floatCast(std.math.clamp(v, 0.5, 4.0));
            detected[ci].has_scale = true;
        }
    }
    // Keep enabled outputs with a detected mode, in order.
    var kept: usize = 0;
    for (detected[0..filled]) |*d| {
        if (d.enabled and d.width != 0 and d.height != 0) {
            detected[kept] = d.*;
            kept += 1;
        }
    }
    detected_n = kept;
    return detected_n;
}

/// Mango monitor_rule composer (pure, tested): detected geometry plus
/// refresh when known (else the old rule's refresh, else omitted),
/// preserving every non-geometry pair (scale, rr, vrr, mirror, ...) from
/// the old rule value. Fresh rules get the repo's rr:0/vrr:0 convention.
pub fn composeMangoRule(name: []const u8, width: u32, height: u32, refresh: u32, x: i32, y: i32, old_value: ?[]const u8, is_new: bool, out: []u8) []const u8 {
    const W = struct {
        buf: []u8,
        n: usize = 0,
        fn s(self: *@This(), t: []const u8) void {
            if (self.n >= self.buf.len) return;
            const k = @min(t.len, self.buf.len - self.n);
            @memcpy(self.buf[self.n..][0..k], t[0..k]);
            self.n += k;
        }
        fn d(self: *@This(), v: anytype) void {
            var tmp: [16]u8 = undefined;
            const t = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
            self.s(t);
        }
    };
    var w = W{ .buf = out };
    var old_refresh: ?[]const u8 = null;
    var extras: [32][]const u8 = undefined;
    var en: usize = 0;
    if (old_value) |ov| {
        var it = std.mem.splitScalar(u8, ov, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            if (p.len == 0) continue;
            const c = std.mem.indexOfScalar(u8, p, ':') orelse {
                if (en < extras.len) {
                    extras[en] = p;
                    en += 1;
                }
                continue;
            };
            const pk = std.mem.trim(u8, p[0..c], " \t");
            const pv = std.mem.trim(u8, p[c + 1 ..], " \t");
            if (std.mem.eql(u8, pk, "refresh")) {
                if (refresh == 0 and pv.len != 0) old_refresh = pv;
                continue;
            }
            var core = false;
            for ([_][]const u8{ "name", "width", "height", "x", "y" }) |k| {
                if (std.mem.eql(u8, pk, k)) {
                    core = true;
                    break;
                }
            }
            if (core) continue;
            if (en < extras.len) {
                extras[en] = p;
                en += 1;
            }
        }
    }
    w.s("monitor_rule = name:");
    w.s(name);
    w.s(", width:");
    w.d(width);
    w.s(", height:");
    w.d(height);
    if (refresh != 0) {
        w.s(", refresh:");
        w.d(refresh);
    } else if (old_refresh) |r| {
        w.s(", refresh:");
        w.s(r);
    }
    w.s(", x:");
    w.d(x);
    w.s(", y:");
    w.d(y);
    for (extras[0..en]) |e| {
        w.s(", ");
        w.s(e);
    }
    if (is_new) w.s(", rr:0, vrr:0");
    return out[0..w.n];
}

/// Hyprland live data. Empty (0) when hyprctl is missing or fails.
pub fn detectHyprland() usize {
    const out = captureOneLine(&.{ "hyprctl", "monitors", "-j" }) orelse return 0;
    defer gpa.free(out);
    return parseMonitorObjects(out);
}

/// Mango live data: wlr-randr first (native, has refresh), xrandr second
/// (needs a running XWayland; XWAYLAND* mirror names are skipped), mmsg
/// fallback (always present with correct names, but no refresh — refresh
/// stays 0/unknown). Empty (0) when none of them answer.
pub fn detectMango() usize {
    if (captureOneLine(&.{"wlr-randr"})) |out| {
        defer gpa.free(out);
        const n = parseWlrRandr(out);
        if (n != 0) return n;
    }
    if (captureOneLine(&.{"xrandr"})) |out| {
        defer gpa.free(out);
        const n = parseXRandr(out);
        if (n != 0) return n;
    }
    const out = captureOneLine(&.{ "mmsg", "get", "all-monitors" }) orelse return 0;
    defer gpa.free(out);
    return parseMonitorObjects(out);
}

/// Parses one signed integer at s[i..], advancing past it.
fn parseSigned(s: []const u8, i: *usize) ?i32 {
    const start = i.*;
    if (i.* < s.len and (s[i.*] == '-' or s[i.*] == '+')) i.* += 1;
    const ds = i.*;
    while (i.* < s.len and isDigit(s[i.*])) i.* += 1;
    if (ds == i.*) {
        i.* = start;
        return null;
    }
    return std.fmt.parseInt(i32, s[start..i.*], 10) catch null;
}

/// xrandr text (XWayland mirror): `NAME connected [primary] WxH+X+Y ...`
/// headers plus indented mode lines, the current one marked `*`:
/// `   1920x1080    239.88*+`. Disconnected outputs are skipped, as are
/// XWAYLAND* mirror names (not compositor outputs — writing one into a
/// monitor_rule would address nothing).
fn parseXRandr(text: []const u8) usize {
    detected_n = 0;
    var filled: usize = 0;
    var cur: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            cur = null;
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            if (sp == 0) continue;
            const nm = line[0..sp];
            if (std.mem.startsWith(u8, nm, "XWAYLAND")) continue;
            if (std.mem.indexOf(u8, line, " disconnected") != null) continue;
            if (std.mem.indexOf(u8, line, " connected") == null) continue;
            if (filled >= MAX_DETECTED) continue;
            cur = filled;
            detected[filled] = .{};
            detected[filled].setName(nm);
            filled += 1;
            // Geometry rides on the header: 1920x1080+0+0.
            if (scanWxH(line)) |m| {
                detected[filled - 1].width = m.w;
                detected[filled - 1].height = m.h;
            }
            // Position: signed pair right after the WxH run (+-1920+0 —
            // the first '+' is the separator, the number carries its own).
            if (scanWxHEnd(line)) |e| {
                var p = e;
                if (p < line.len and line[p] == '+') p += 1;
                const px = parseSigned(line, &p) orelse continue;
                const py = parseSigned(line, &p) orelse continue;
                detected[filled - 1].x = std.math.clamp(px, -16384, 16384);
                detected[filled - 1].y = std.math.clamp(py, -16384, 16384);
            }
            continue;
        }
        const ci = cur orelse continue;
        if (std.mem.indexOfScalar(u8, line, '*') == null) continue;
        const t = std.mem.trim(u8, line, " \t");
        const mode_end = scanWxHEnd(t);
        if (mode_end) |e| {
            if (scanWxH(t[0..e])) |m| {
                detected[ci].width = m.w;
                detected[ci].height = m.h;
            }
        }
        // Refresh: first float AFTER the WxH run (the width itself would
        // otherwise win).
        const rfrom = mode_end orelse 0;
        var q: usize = rfrom;
        while (q < t.len) : (q += 1) {
            if (!isDigit(t[q])) continue;
            var e = q;
            while (e < t.len and (isDigit(t[e]) or t[e] == '.')) e += 1;
            if (std.fmt.parseFloat(f64, t[q..e]) catch null) |v| {
                detected[ci].refresh = clampU32(v);
                break;
            }
        }
    }
    // Keep outputs with a detected mode, in order.
    var kept: usize = 0;
    for (detected[0..filled]) |*d| {
        if (d.width != 0 and d.height != 0) {
            detected[kept] = d.*;
            kept += 1;
        }
    }
    detected_n = kept;
    return detected_n;
}

/// End offset (exclusive) of the first `digits x digits` run, or null.
fn scanWxHEnd(line: []const u8) ?usize {
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
            if (k > j + 1) return k;
        }
        p = j;
    }
    return null;
}

// ---------------------------------------------------------------------
// Unit tests (pure helpers only — no filesystem / process touch)
// ---------------------------------------------------------------------

test "unquote strips gsettings quoting" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Bibata-Modern-Classic", unquoteInto("'Bibata-Modern-Classic'\n", &buf));
    try t.expectEqualStrings("Adwaita", unquoteInto("  'Adwaita'  ", &buf));
    try t.expectEqualStrings("plain", unquoteInto("plain", &buf));
    try t.expectEqualStrings("", unquoteInto("\n", &buf));
}

test "buildIni replaces key and preserves the rest" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    buildIni("[Settings]\ngtk-theme-name=Old\nfont-name=Sans 10\n", "gtk-theme-name", "New", &out);
    try t.expectEqualStrings("[Settings]\nfont-name=Sans 10\ngtk-theme-name=New\n", out.items);
}

test "buildIni adds a missing section" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    buildIni("", "gtk-theme-name", "Dracula", &out);
    try t.expectEqualStrings("[Settings]\ngtk-theme-name=Dracula\n", out.items);
}

test "buildIni keeps comments and other sections" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    buildIni("# hello\n[Settings]\n# keep me\ngtk-theme-name=Old\n[Other]\nx=1\n", "gtk-theme-name", "New", &out);
    try t.expectEqualStrings("# hello\n[Settings]\n# keep me\n[Other]\nx=1\ngtk-theme-name=New\n", out.items);
}

test "theme list dedupes and sorts" {
    var l: ThemeList = .{};
    l.add("Bibata-Modern-Ice");
    l.add("Adwaita");
    l.add("Bibata-Modern-Ice");
    l.add("default");
    l.sort();
    try std.testing.expectEqual(@as(usize, 3), l.count);
    try std.testing.expectEqualStrings("Adwaita", l.values[0]);
    try std.testing.expectEqualStrings("Bibata-Modern-Ice", l.values[1]);
    try std.testing.expectEqualStrings("default", l.values[2]);
    l.ensure("Capitaine");
    try std.testing.expectEqual(@as(usize, 4), l.count);
    try std.testing.expectEqualStrings("Capitaine", l.values[2]);
}

test "formatScale trims" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1", formatScale(1.0, &buf));
    try std.testing.expectEqualStrings("1.5", formatScale(1.5, &buf));
    try std.testing.expectEqualStrings("2", formatScale(2.0, &buf));
}

test "parse hyprctl monitors json" {
    const sample =
        \\[{"id":0,"name":"DP-2","description":"Microstep cyclical (DP-2)","make":"Microstep","model":"cyclical","serial":"","width":1920,"height":1080,"refreshRate":239.963,"x":0,"y":0,"activeWorkspace":{"id":2,"name":"2"},"specialWorkspace":{"id":0,"name":""},"reserved":[0,0,0,0],"scale":1.0,"transform":0,"focused":true,"dpmsStatus":true,"vrr":false,"solitary":"1","activelyTearing":false,"directScanoutTo":""},{"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"refreshRate":59.951,"x":1920,"y":-200,"scale":1.5,"transform":0,"focused":false,"dpmsStatus":true,"vrr":false}]
    ;
    try std.testing.expectEqual(@as(usize, 2), parseMonitorObjects(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("DP-2", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1920), ds[0].width);
    try std.testing.expectEqual(@as(u32, 1080), ds[0].height);
    try std.testing.expectEqual(@as(u32, 240), ds[0].refresh);
    try std.testing.expectEqual(@as(u32, 2560), ds[1].width);
    try std.testing.expectEqual(@as(u32, 1440), ds[1].height);
    try std.testing.expectEqual(@as(u32, 60), ds[1].refresh);
    try std.testing.expectEqual(@as(i32, 1920), ds[1].x);
    try std.testing.expectEqual(@as(i32, -200), ds[1].y);
    try std.testing.expect(ds[1].has_scale);
}

test "parse mmsg all-monitors json" {
    const sample =
        \\{"monitors":[{"name":"DP-2","active":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1,"tags":[{"index":1,"is_active":false}]},{"name":"HDMI-A-1","active":true,"x":1920,"y":0,"width":2560,"height":1440,"scale":2,"tags":[]}]}
    ;
    try std.testing.expectEqual(@as(usize, 2), parseMonitorObjects(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("DP-2", ds[0].name());
    try std.testing.expectEqual(@as(u32, 0), ds[0].refresh); // mmsg has no refresh
    try std.testing.expectEqualStrings("HDMI-A-1", ds[1].name());
    try std.testing.expectEqual(@as(u32, 2560), ds[1].width);
    try std.testing.expectEqual(@as(i32, 1920), ds[1].x);
}

test "parse wlr-randr text" {
    const sample =
        \\DP-2 "Unknown Unknown (DP-2)"
        \\  Physical size: 0x0 mm
        \\  Enabled: yes
        \\  Modes:
        \\    1920x1080 px, 239.963 Hz (preferred, current)
        \\    1920x1080 px, 60.000 Hz
        \\  Position: 0,0
        \\  Transform: normal
        \\  Scale: 1.000000
        \\HDMI-A-1 "Unknown Unknown (HDMI-A-1)"
        \\  Enabled: no
        \\  Modes:
        \\    2560x1440 px, 59.951 Hz (current)
        \\  Position: 1920,0
        \\  Scale: 1.500000
    ;
    try std.testing.expectEqual(@as(usize, 1), parseWlrRandr(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("DP-2", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1920), ds[0].width);
    try std.testing.expectEqual(@as(u32, 1080), ds[0].height);
    try std.testing.expectEqual(@as(u32, 240), ds[0].refresh);
    // disabled output skipped
}

test "parse wlr-randr virtual output" {
    const sample =
        \\Virtual-1 "Unknown Unknown (Virtual-1)"
        \\  Physical size: 0x0 mm
        \\  Enabled: yes
        \\  Modes:
        \\    1280x800 px, 60.000 Hz (preferred, current)
        \\  Position: 0,0
        \\  Transform: normal
        \\  Scale: 1.000000
    ;
    try std.testing.expectEqual(@as(usize, 1), parseWlrRandr(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("Virtual-1", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1280), ds[0].width);
    try std.testing.expectEqual(@as(u32, 800), ds[0].height);
    try std.testing.expectEqual(@as(u32, 60), ds[0].refresh);
}

test "parse mmsg virtual output" {
    const sample =
        \\{"monitors":[{"name":"Virtual-1","active":true,"x":0,"y":0,"width":1280,"height":800,"scale":1,"tags":[]}]}
    ;
    try std.testing.expectEqual(@as(usize, 1), parseMonitorObjects(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("Virtual-1", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1280), ds[0].width);
}

test "parse hyprctl virtual output" {
    const sample =
        \\[{"id":0,"name":"Virtual-1","width":1280,"height":800,"refreshRate":60.0,"x":0,"y":0,"scale":1.0}]
    ;
    try std.testing.expectEqual(@as(usize, 1), parseMonitorObjects(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("Virtual-1", ds[0].name());
    try std.testing.expectEqual(@as(u32, 60), ds[0].refresh);
}

test "parse xrandr connected output" {
    const sample =
        \\Screen 0: minimum 16 x 16, current 1920 x 1080, maximum 32767 x 32767
        \\DP-2 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 700mm x 390mm
        \\   1920x1080    239.88*+
        \\   1440x1080    239.87
        \\   800x600      239.81
        \\HDMI-1 disconnected (normal left inverted right x axis y axis)
    ;
    try std.testing.expectEqual(@as(usize, 1), parseXRandr(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("DP-2", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1920), ds[0].width);
    try std.testing.expectEqual(@as(u32, 1080), ds[0].height);
    try std.testing.expectEqual(@as(u32, 240), ds[0].refresh);
    try std.testing.expectEqual(@as(i32, 0), ds[0].x);
    try std.testing.expectEqual(@as(i32, 0), ds[0].y);
}

test "parse xrandr skips xwayland mirrors and negative offsets" {
    const sample =
        \\Screen 0: minimum 16 x 16, current 3200 x 1080, maximum 32767 x 32767
        \\XWAYLAND0 connected 1920x1080+0+0 0mm x 0mm
        \\   1920x1080    60.00*+
        \\DP-2 connected 1280x800+-1920+0 (normal left inverted right x axis y axis) 700mm x 390mm
        \\   1280x800     60.00*+
    ;
    try std.testing.expectEqual(@as(usize, 1), parseXRandr(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqualStrings("DP-2", ds[0].name());
    try std.testing.expectEqual(@as(u32, 1280), ds[0].width);
    try std.testing.expectEqual(@as(i32, -1920), ds[0].x);
}

test "compose mango rule virtual output" {
    var out: [512]u8 = undefined;
    const s = composeMangoRule("Virtual-1", 1280, 800, 60, 0, 0, null, true, &out);
    try std.testing.expectEqualStrings("monitor_rule = name:Virtual-1, width:1280, height:800, refresh:60, x:0, y:0, rr:0, vrr:0", s);
}

test "parse wlr-randr at-variant mode line" {
    const sample =
        \\DP-1 "Test (DP-1)"
        \\  Enabled: yes
        \\  Modes:
        \\    3840x2160 @ 60.000 Hz (current)
        \\  Position: 0,0
    ;
    try std.testing.expectEqual(@as(usize, 1), parseWlrRandr(sample));
    const ds = detectedMonitors();
    try std.testing.expectEqual(@as(u32, 3840), ds[0].width);
    try std.testing.expectEqual(@as(u32, 2160), ds[0].height);
    try std.testing.expectEqual(@as(u32, 60), ds[0].refresh);
}

test "compose mango rule fresh with refresh" {
    var out: [512]u8 = undefined;
    const s = composeMangoRule("DP-2", 1920, 1080, 240, 0, 0, null, true, &out);
    try std.testing.expectEqualStrings("monitor_rule = name:DP-2, width:1920, height:1080, refresh:240, x:0, y:0, rr:0, vrr:0", s);
}

test "compose mango rule preserves extras, keeps old refresh" {
    var out: [512]u8 = undefined;
    const old = "name:DP-2, width:1, height:1, refresh:240, x:9, y:9, scale:2, vrr:1, mirror:HDMI-1";
    const s = composeMangoRule("DP-2", 1920, 1080, 0, 0, 0, old, false, &out);
    try std.testing.expectEqualStrings("monitor_rule = name:DP-2, width:1920, height:1080, refresh:240, x:0, y:0, scale:2, vrr:1, mirror:HDMI-1", s);
}

test "compose mango rule detected refresh wins, no extras lost" {
    var out: [512]u8 = undefined;
    const old = "name:DP-2, width:1920, height:1080, refresh:60, x:0, y:0, rr:1";
    const s = composeMangoRule("DP-2", 2560, 1440, 165, 1920, 0, old, false, &out);
    try std.testing.expectEqualStrings("monitor_rule = name:DP-2, width:2560, height:1440, refresh:165, x:1920, y:0, rr:1", s);
}

test "compose mango rule omits unknown refresh on fresh" {
    var out: [512]u8 = undefined;
    const s = composeMangoRule("DP-2", 1920, 1080, 0, 0, 0, null, true, &out);
    try std.testing.expectEqualStrings("monitor_rule = name:DP-2, width:1920, height:1080, x:0, y:0, rr:0, vrr:0", s);
}

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

//! .desktop scanning + parsing shared by simpbar-config's app picker ("Pin
//! to Bar" with real icons), the bar's in-bar taskbar, and the app-grid
//! menu. Enumerates installed applications from the freedesktop applications
//! dirs and extracts Name/Exec/Icon/StartupWMClass.
//!
//! Follows this codebase's established "declare the few libc fns we need
//! rather than pull in std.fs" pattern (see main.zig's config-file-IO
//! comment): Zig 0.16 reworked std.fs/std.posix enough that it's simpler to
//! bind open/read/close/opendir/readdir directly. libc is linked by both
//! binaries that import this module, so std.posix.system is available.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// glibc's struct dirent64 (x86_64/Linux layout) — only d_name/d_type are
/// read here; the rest are padding that keeps the layout honest.
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

/// One parsed, pinnable application. All slices are owned by the arena the
/// entry was built from.
pub const DesktopEntry = struct {
    name: []const u8,
    exec: []const u8,
    icon: []const u8,
    wm_class: []const u8,
};

/// Reads all of `path` into `allocator` — same shape as main.zig's
/// readFileAlloc (this module is compiled into binaries that already own
/// that helper elsewhere but deliberately don't share code across them).
fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    if (path.len == 0) return error.NoPath;
    const raw_fd = std.posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (raw_fd < 0) return error.OpenFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    defer _ = std.posix.system.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
        if (list.items.len > 1024 * 1024) break; // sanity cap; .desktop files are tiny
    }
    return list.toOwnedSlice(allocator);
}

fn isTrue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "true");
}

/// Drops field-code tokens (%f/%u/%U/%i/... — see config_main.zig's
/// Shortcuts-tab comment on why pinned commands must be field-code-free)
/// from a raw Exec= value, keeping the executable and any real arguments
/// ("--new-window"), and returns the rejoined command owned by `arena`.
fn stripFieldCodes(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var it = std.mem.splitAny(u8, raw, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0 or tok[0] == '%') continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, tok);
    }
    return out.toOwnedSlice(arena);
}

/// Parses the contents of one .desktop file into a DesktopEntry owned by
/// `arena`, or null when the entry shouldn't be listed (not an Application,
/// NoDisplay/Hidden, or missing Name/Exec). Only the bare (unesuffixed) keys
/// are read — localizations fall back to them, and what we launch/pin needs
/// the canonical values.
pub fn parseDesktop(data: []const u8, arena: std.mem.Allocator) ?DesktopEntry {
    var in_group = false;
    var is_app = false;
    var no_display = false;
    var hidden = false;
    var found = DesktopEntry{ .name = "", .exec = "", .icon = "", .wm_class = "" };

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Type")) {
            is_app = std.mem.eql(u8, value, "Application");
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            no_display = isTrue(value);
        } else if (std.mem.eql(u8, key, "Hidden")) {
            hidden = isTrue(value);
        } else if (std.mem.eql(u8, key, "Name") and found.name.len == 0) {
            found.name = arena.dupe(u8, value) catch return null;
        } else if (std.mem.eql(u8, key, "Exec") and found.exec.len == 0) {
            const stripped = stripFieldCodes(arena, value) catch return null;
            if (stripped.len > 0) found.exec = stripped;
        } else if (std.mem.eql(u8, key, "Icon") and found.icon.len == 0) {
            found.icon = arena.dupe(u8, value) catch return null;
        } else if (std.mem.eql(u8, key, "StartupWMClass") and found.wm_class.len == 0) {
            found.wm_class = arena.dupe(u8, value) catch return null;
        }
    }

    if (!is_app or no_display or hidden or found.name.len == 0 or found.exec.len == 0) return null;
    return found;
}

/// Scans one applications dir (opendir/readdir rather than std.fs, per the
/// module comment) and appends every parseable .desktop file. `seen` holds
/// basenames already listed, so dirs are scanned in priority order and a
/// user-level override of a system file is listed once (first wins).
fn scanApplicationsDir(
    arena: std.mem.Allocator,
    out: *std.ArrayList(DesktopEntry),
    seen: *std.ArrayList([]const u8),
    dir_path: [:0]const u8,
) void {
    const dirp = libc_dir.opendir(dir_path.ptr) orelse return;
    defer _ = libc_dir.closedir(dirp);

    while (libc_dir.readdir(dirp)) |ent| {
        const name = std.mem.sliceTo(&ent.d_name, 0);
        if (name.len == 0 or !std.mem.endsWith(u8, name, ".desktop")) continue;
        var dup = false;
        for (seen.items) |b| {
            if (std.mem.eql(u8, b, name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        const data = readFileAlloc(arena, path) catch continue;
        if (parseDesktop(data, arena)) |entry| {
            out.append(arena, entry) catch continue;
            seen.append(arena, arena.dupe(u8, name) catch continue) catch continue;
        }
    }
}

/// Appends every installed, pinnable application to `out`, all strings owned
/// by `arena`. Order: user dir first (so ~/.local/share overrides win), then
/// /usr/local, /usr, and Flatpak exports.
pub fn enumerateInstalledApps(arena: std.mem.Allocator, out: *std.ArrayList(DesktopEntry)) !void {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(arena);

    const home = std.mem.span(getenv("HOME") orelse "/root");
    var user_dir_buf: [512]u8 = undefined;
    const user_dir = std.fmt.bufPrintZ(&user_dir_buf, "{s}/.local/share/applications", .{home}) catch return;
    scanApplicationsDir(arena, out, &seen, user_dir);
    scanApplicationsDir(arena, out, &seen, "/usr/local/share/applications");
    scanApplicationsDir(arena, out, &seen, "/usr/share/applications");
    scanApplicationsDir(arena, out, &seen, "/var/lib/flatpak/exports/share/applications");
}
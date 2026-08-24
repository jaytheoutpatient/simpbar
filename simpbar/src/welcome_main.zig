// Simpbar Welcome — Zig/GTK4/libadwaita port of the original simpbar_welcome.py
// GTK companion app. Talks to GTK/libadwaita/GObject through welcome_gtk.zig's
// hand-written extern bindings (see that file for why: @cImport of the real
// headers doesn't work here).
//
// File I/O and process control are done via hand-declared libc externs
// (open/read/write/close/pipe/dup2/poll/access/mkdir/fork) rather than
// std.fs/std.posix/std.process — this Zig version (0.16) reworked those
// around a new std.Io abstraction that the rest of this codebase (main.zig)
// doesn't use either; std.c's fork() is private for the same reason
// main.zig binds it itself. Sticking to raw libc calls keeps this file on
// the same stable, well-understood layer as the bar.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------------
// libc externs
// ---------------------------------------------------------------------

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn exit(code: c_int) noreturn;

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
const POLLIN: i16 = 0x0001;

// fork() is private inside std.c (same reason noted in main.zig) — bind it
// ourselves.
const libc_proc = struct {
    extern "c" fn fork() c_int;
};

const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
const F_OK: c_int = 0;
const X_OK: c_int = 1;

// ---------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------

const APP_ID = "dev.jaytheoutpatient.simpbar.Welcome";
const REPO_URL = "https://github.com/jaytheoutpatient/simpbar";
const CONTACT_EMAIL = "jaytheoutpatient@protonmail.com";
const DISCORD_URL = "https://discord.gg/sAMMXSPx9R";
const HYPRLAND_CONF = "~/.config/hypr/hyprland.lua";

const SIMPBAR_WELCOME_AUTOSTART_LINE = "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"simpbar-welcome\") end)";
const STEAM_SILENT_AUTOSTART_LINE = "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"steam -silent\") end)";
const EASYEFFECTS_AUTOSTART_LINE = "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"easyeffects --gapplication-service\") end)";

// ---------------------------------------------------------------------
// Paths (resolved from $HOME at startup)
// ---------------------------------------------------------------------

var hyprland_lua_buf: [512]u8 = undefined;
var first_run_marker_buf: [512]u8 = undefined;
var logo_path_buf: [512]u8 = undefined;
var simpbar_config_dir_buf: [512]u8 = undefined;

var g_hyprland_lua_path: [:0]const u8 = "";
var g_first_run_marker_path: [:0]const u8 = "";
var g_logo_path: [:0]const u8 = "";
var g_simpbar_config_dir: [:0]const u8 = "";

fn resolvePaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    g_hyprland_lua_path = std.fmt.bufPrintZ(&hyprland_lua_buf, "{s}/.config/hypr/hyprland.lua", .{home}) catch "";
    g_first_run_marker_path = std.fmt.bufPrintZ(&first_run_marker_buf, "{s}/.config/simpbar/welcome-shown", .{home}) catch "";
    g_logo_path = std.fmt.bufPrintZ(&logo_path_buf, "{s}/.local/share/simpbar/logo.png", .{home}) catch "";
    g_simpbar_config_dir = std.fmt.bufPrintZ(&simpbar_config_dir_buf, "{s}/.config/simpbar", .{home}) catch "";
}

// ---------------------------------------------------------------------
// Small file helpers
// ---------------------------------------------------------------------

fn fileExists(path: [:0]const u8) bool {
    return access(path, F_OK) == 0;
}

fn readFileAll(path: [:0]const u8) ?[]u8 {
    const fd = open(path, 0, 0); // O_RDONLY
    if (fd < 0) return null;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch break;
        if (list.items.len > 8 * 1024 * 1024) break; // sanity cap
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn writeFileAll(path: [:0]const u8, data: []const u8) bool {
    const fd = open(path, 1 | O_CREAT | O_TRUNC, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
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

fn commandExists(name: []const u8) bool {
    var buf: [300]u8 = undefined;
    const dirs = [_][]const u8{ "/usr/bin/", "/usr/local/bin/" };
    for (dirs) |dir| {
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ dir, name }) catch continue;
        if (access(path, X_OK) == 0) return true;
    }
    return false;
}

fn detectAutostartMode() bool {
    const data = readFileAll("/proc/self/cmdline") orelse return false;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--autostart")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// hyprland.lua autostart-line toggling
// ---------------------------------------------------------------------

fn isHyprLineEnabled(line: []const u8) bool {
    const content = readFileAll(g_hyprland_lua_path) orelse return false;
    defer gpa.free(content);
    return std.mem.indexOf(u8, content, line) != null;
}

fn setHyprLineEnabled(line: []const u8, enabled: bool) bool {
    const existing = readFileAll(g_hyprland_lua_path);
    defer if (existing) |e| gpa.free(e);

    if (enabled) {
        if (existing) |content| {
            if (std.mem.indexOf(u8, content, line) != null) return true;
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(gpa);
            list.appendSlice(gpa, content) catch return false;
            if (content.len > 0 and content[content.len - 1] != '\n') list.append(gpa, '\n') catch return false;
            list.appendSlice(gpa, line) catch return false;
            list.append(gpa, '\n') catch return false;
            return writeFileAll(g_hyprland_lua_path, list.items);
        }
        var buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{s}\n", .{line}) catch return false;
        return writeFileAll(g_hyprland_lua_path, out);
    }

    const content = existing orelse return true;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const trimmed = std.mem.trim(u8, ln, " \t\r");
        if (std.mem.eql(u8, trimmed, line)) continue;
        list.appendSlice(gpa, ln) catch return false;
        list.append(gpa, '\n') catch return false;
    }
    return writeFileAll(g_hyprland_lua_path, list.items);
}

fn markShown() void {
    _ = mkdir(g_simpbar_config_dir, 0o755);
    const fd = open(g_first_run_marker_path, O_CREAT, 0o644);
    if (fd >= 0) _ = close(fd);
}

// ---------------------------------------------------------------------
// Launching external commands
// ---------------------------------------------------------------------

/// Fire-and-forget launch of an external command, PATH-searched via
/// /usr/bin/env, detached via the standard double-fork (mirrors
/// spawnDetached/spawnPlayerctlCommand in the bar's main.zig).
fn launchArgv(argv: []const [:0]const u8) void {
    if (argv.len == 0 or argv.len > 14) return;
    const pid = libc_proc.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const pid2 = libc_proc.fork();
        if (pid2 == 0) {
            _ = std.c.setsid();
            var buf: [16]?[*:0]const u8 = undefined;
            buf[0] = "/usr/bin/env";
            for (argv, 0..) |a, i| buf[i + 1] = a;
            buf[argv.len + 1] = null;
            _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
            std.c._exit(127);
        }
        std.c._exit(0);
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

/// Runs `argv` (PATH-searched via /usr/bin/env) and captures its stdout,
/// blocking the calling thread. Returns null on spawn failure or if no
/// output arrives within timeout_ms of any single poll — good enough for
/// "is this hung" detection without needing wall-clock bookkeeping across
/// the whole read. Caller frees the returned slice with gpa.
fn runCaptured(argv: []const [:0]const u8, timeout_ms: i32) ?[]u8 {
    if (argv.len == 0 or argv.len > 14) return null;
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return null;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const pid = libc_proc.fork();
    if (pid < 0) {
        _ = close(read_fd);
        _ = close(write_fd);
        return null;
    }
    if (pid == 0) {
        _ = close(read_fd);
        _ = dup2(write_fd, 1); // STDOUT_FILENO
        _ = close(write_fd);
        var buf: [16]?[*:0]const u8 = undefined;
        buf[0] = "/usr/bin/env";
        for (argv, 0..) |a, i| buf[i + 1] = a;
        buf[argv.len + 1] = null;
        _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
        std.c._exit(127);
    }
    _ = close(write_fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    var timed_out = false;
    while (true) {
        var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
        const pr = poll(&pfd, 1, timeout_ms);
        if (pr <= 0) {
            timed_out = true;
            break;
        }
        const n = read(read_fd, &chunk, chunk.len);
        if (n <= 0) break; // EOF or error
        list.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            timed_out = true;
            break;
        };
        if (list.items.len > 2 * 1024 * 1024) break; // sanity cap
    }
    _ = close(read_fd);

    if (timed_out) {
        _ = std.c.kill(pid, .KILL);
        var status: c_int = undefined;
        _ = std.c.waitpid(pid, &status, 0);
        list.deinit(gpa);
        return null;
    }
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    return list.toOwnedSlice(gpa) catch null;
}

fn buildInstallCmd(buf: []u8, pkg: [:0]const u8, needs_aur: bool) []const u8 {
    if (needs_aur) {
        return std.fmt.bufPrint(
            buf,
            "if command -v yay >/dev/null; then yay -S --noconfirm --needed {s}; " ++
                "elif command -v paru >/dev/null; then paru -S --noconfirm --needed {s}; " ++
                "else echo \"No AUR helper found \u{2014} install {s} manually\"; fi",
            .{ pkg, pkg, pkg },
        ) catch "";
    }
    return std.fmt.bufPrint(buf, "sudo pacman -S --noconfirm --needed {s}", .{pkg}) catch "";
}

// ---------------------------------------------------------------------
// Update checking (background thread -> g_idle_add back to the UI thread)
// ---------------------------------------------------------------------

const MAX_UPDATE_ENTRIES = 200;

const UpdateEntry = struct {
    name: [96]u8 = undefined,
    name_len: usize = 0,
    info: [96]u8 = undefined,
    info_len: usize = 0,

    fn nameZ(self: *UpdateEntry) [:0]const u8 {
        self.name[self.name_len] = 0;
        return self.name[0..self.name_len :0];
    }
    fn infoZ(self: *UpdateEntry) [:0]const u8 {
        self.info[self.info_len] = 0;
        return self.info[0..self.info_len :0];
    }
};

const UpdateList = struct {
    entries: [MAX_UPDATE_ENTRIES]UpdateEntry = undefined,
    count: usize = 0,
    ok: bool = false,
};

const UpdateCheckResult = struct {
    arch: UpdateList = .{},
    aur: UpdateList = .{},
    flatpak: UpdateList = .{},
};

/// Parses a "pkgname oldver -> newver" line (checkupdates/yay/paru format).
fn parsePkgUpdateLine(line: []const u8, list: *UpdateList) bool {
    const arrow = std.mem.indexOf(u8, line, "->") orelse return false;
    const left = std.mem.trim(u8, line[0..arrow], " \t\r");
    const new_ver = std.mem.trim(u8, line[arrow + 2 ..], " \t\r");

    var split_at: ?usize = null;
    var i: usize = left.len;
    while (i > 0) {
        i -= 1;
        if (left[i] == ' ') {
            split_at = i;
            break;
        }
    }
    const sp = split_at orelse return false;
    const name = std.mem.trim(u8, left[0..sp], " \t\r");
    const old_ver = std.mem.trim(u8, left[sp + 1 ..], " \t\r");
    if (name.len == 0 or old_ver.len == 0 or new_ver.len == 0) return false;

    const entry = &list.entries[list.count];
    if (name.len >= entry.name.len) return false;
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    const info = std.fmt.bufPrint(&entry.info, "{s} \u{2192} {s}", .{ old_ver, new_ver }) catch return false;
    entry.info_len = info.len;
    return true;
}

fn fillListFromLines(list: *UpdateList, output: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (list.count >= MAX_UPDATE_ENTRIES) break;
        if (parsePkgUpdateLine(line, list)) list.count += 1;
    }
}

fn parseFlatpakLine(raw_line: []const u8, list: *UpdateList) bool {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0) return false;

    var field0: []const u8 = undefined;
    var field1: []const u8 = undefined;
    if (std.mem.indexOfScalar(u8, line, '\t')) |_| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        field0 = std.mem.trim(u8, parts.next() orelse return false, " \t");
        field1 = std.mem.trim(u8, parts.next() orelse return false, " \t");
    } else {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        field0 = parts.next() orelse return false;
        field1 = parts.next() orelse return false;
    }
    if (field0.len == 0) return false;

    var lower_buf: [96]u8 = undefined;
    if (field0.len < lower_buf.len) {
        const lower = std.ascii.lowerString(lower_buf[0..field0.len], field0);
        if (std.mem.eql(u8, lower, "application")) return false;
    }

    const entry = &list.entries[list.count];
    if (field0.len >= entry.name.len or field1.len >= entry.info.len) return false;
    @memcpy(entry.name[0..field0.len], field0);
    entry.name_len = field0.len;
    @memcpy(entry.info[0..field1.len], field1);
    entry.info_len = field1.len;
    return true;
}

fn fetchArchUpdates(list: *UpdateList) void {
    if (!commandExists("checkupdates")) {
        list.ok = false;
        return;
    }
    const output = runCaptured(&[_][:0]const u8{"checkupdates"}, 30000) orelse {
        list.ok = false;
        return;
    };
    defer gpa.free(output);
    list.ok = true;
    fillListFromLines(list, output);
}

fn fetchAurUpdates(list: *UpdateList) void {
    var helper: ?[:0]const u8 = null;
    if (commandExists("yay")) {
        helper = "yay";
    } else if (commandExists("paru")) {
        helper = "paru";
    }
    const h = helper orelse {
        list.ok = true; // no AUR helper installed — matches Python's "empty, not an error"
        return;
    };
    const output = runCaptured(&[_][:0]const u8{ h, "-Qua" }, 60000) orelse {
        list.ok = false;
        return;
    };
    defer gpa.free(output);
    list.ok = true;
    fillListFromLines(list, output);
}

fn fetchFlatpakUpdates(list: *UpdateList) void {
    if (!commandExists("flatpak")) {
        list.ok = true;
        return;
    }
    if (runCaptured(&[_][:0]const u8{ "flatpak", "update", "--appstream", "-y" }, 60000)) |o| {
        gpa.free(o);
    } else {
        list.ok = false;
        return;
    }
    const output = runCaptured(&[_][:0]const u8{ "flatpak", "remote-ls", "--updates", "--columns=application,version", "flathub" }, 30000) orelse {
        list.ok = false;
        return;
    };
    defer gpa.free(output);
    list.ok = true;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        if (list.count >= MAX_UPDATE_ENTRIES) break;
        if (parseFlatpakLine(raw_line, list)) list.count += 1;
    }
}

fn updateCheckThreadFn(result: *UpdateCheckResult) void {
    fetchArchUpdates(&result.arch);
    fetchAurUpdates(&result.aur);
    fetchFlatpakUpdates(&result.flatpak);
    _ = gtk.g_idle_add(&onUpdateCheckIdle, result);
}

// ---------------------------------------------------------------------
// Static data tables (mirrors the Python module's constants)
// ---------------------------------------------------------------------

const KeybindEntry = struct { combo: [:0]const u8, action: [:0]const u8 };
const KEYBINDINGS = [_]KeybindEntry{
    .{ .combo = "SUPER", .action = "Windows key" },
    .{ .combo = "SUPER + Enter", .action = "Open terminal" },
    .{ .combo = "SUPER + Space", .action = "Open Rofi" },
    .{ .combo = "SUPER + E", .action = "Open Nautilus" },
    .{ .combo = "SUPER + Q", .action = "Exit the application" },
    .{ .combo = "SUPER + 1 \u{2013} 0", .action = "Switch workspaces" },
};

const SetupAction = struct {
    title: [:0]const u8,
    subtitle: [:0]const u8,
    icon: [:0]const u8,
    argv: []const [:0]const u8,
};
const SETUP_ACTIONS = [_]SetupAction{
    .{
        .title = "Update Arch Linux",
        .subtitle = "Runs a plain system update (sudo pacman -Syu) \u{2014} no config/script " ++
            "refresh, just your packages. Opens in a terminal for the password prompt.",
        .icon = "system-software-update-symbolic",
        .argv = &[_][:0]const u8{ "foot", "-e", "bash", "-lc", "sudo pacman -Syu --noconfirm; echo; read -p 'Press Enter to close...'" },
    },
    .{
        .title = "Update Simpbar and Arch Linux",
        .subtitle = "Runs a full system update, then re-fetches the latest install script " ++
            "and configs from GitHub. Opens in a terminal \u{2014} asks a few of the same " ++
            "setup questions again as part of the refresh.",
        .icon = "software-update-available-symbolic",
        .argv = &[_][:0]const u8{
            "foot", "-e", "bash", "-lc",
            "sudo pacman -Syu --noconfirm; echo; " ++
                "curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash; echo; read -p 'Press Enter to close...'",
        },
    },
    .{
        .title = "Check for updates now",
        .subtitle = "Checks for Arch/AUR package updates and new commits on the simpbar " ++
            "repo, and sends a notification if it finds anything. Runs " ++
            "automatically every few hours in the background too.",
        .icon = "view-refresh-symbolic",
        .argv = &[_][:0]const u8{"simpbar-check-updates"},
    },
    .{
        .title = "Browse and install software",
        .subtitle = "Opens Bazaar, a graphical software manager for finding and installing Flatpak apps.",
        .icon = "system-software-install-symbolic",
        .argv = &[_][:0]const u8{"bazaar"},
    },
    .{
        .title = "Pick a wallpaper",
        .subtitle = "Opens waypaper, pointed at ~/Pictures/Wallpaper by default.",
        .icon = "preferences-desktop-wallpaper-symbolic",
        .argv = &[_][:0]const u8{"waypaper"},
    },
    .{
        .title = "Customize GTK theme, icons and cursor",
        .subtitle = "Opens nwg-look. Dracula GTK/icons and Bibata Modern Classic are already set as defaults.",
        .icon = "preferences-desktop-theme-symbolic",
        .argv = &[_][:0]const u8{"nwg-look"},
    },
    .{
        .title = "Tweak Hyprland settings",
        .subtitle = "Opens HyprMod \u{2014} keybinds, monitors, animations, window rules, and " ++
            "more, with a live preview. Writes to its own config, doesn't touch hyprland.lua directly.",
        .icon = "preferences-desktop-display-symbolic",
        .argv = &[_][:0]const u8{"hyprmod"},
    },
    .{
        .title = "Adjust audio devices and volumes",
        .subtitle = "Opens pavucontrol.",
        .icon = "audio-speakers-symbolic",
        .argv = &[_][:0]const u8{"pavucontrol"},
    },
};

const EASYEFFECTS_ARGV = [_][:0]const u8{
    "foot", "-e", "bash", "-lc",
    "sudo pacman -S --noconfirm --needed easyeffects calf lsp-plugins-lv2 mda.lv2 x42-plugins-lv2 zam-plugins-lv2; echo; read -p 'Press Enter to close...'",
};

const REMOVE_NEOVIM_ARGV = [_][:0]const u8{
    "foot", "-e", "bash", "-lc",
    "sudo pacman -Rns --noconfirm neovim; " ++
        "rm -rf ~/.config/nvim ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim; " ++
        "echo; read -p 'Press Enter to close...'",
};

const APPLY_ALL_UPDATES_ARGV = [_][:0]const u8{
    "foot", "-e", "bash", "-lc",
    "sudo pacman -Syu --noconfirm; " ++
        "if command -v yay >/dev/null; then yay -Sua --noconfirm; " ++
        "elif command -v paru >/dev/null; then paru -Sua --noconfirm; fi; " ++
        "command -v flatpak >/dev/null && flatpak update -y; " ++
        "echo; read -p 'Press Enter to close...'",
};

const GRAPHICS_OPTIONS = [_][:0]const u8{ "GIMP", "Inkscape", "Krita" };
const GRAPHICS_PACKAGES = [_][:0]const u8{ "gimp", "inkscape", "krita" };

const VIDEO_PLAYER_OPTIONS = [_][:0]const u8{ "mpv", "VLC" };
const VIDEO_PLAYER_PACKAGES = [_][:0]const u8{ "mpv", "vlc" };

const EDITOR_OPTIONS = [_][:0]const u8{ "Neovim", "Gedit", "Kate", "Zed", "VS Code" };
const EDITOR_PACKAGES = [_][:0]const u8{ "neovim", "gedit", "kate", "zed", "visual-studio-code-bin" };
const EDITOR_NEEDS_AUR = [_]bool{ false, false, false, false, true };

const PinInfo = struct { binary: [:0]const u8, pkg: [:0]const u8, needs_aur: bool };

const PIN_BROWSER_OPTIONS = [_][:0]const u8{ "Brave", "Zen Browser", "Vivaldi", "Microsoft Edge", "LibreWolf", "Firefox" };
const PIN_BROWSER_INFO = [_]PinInfo{
    .{ .binary = "brave", .pkg = "brave-bin", .needs_aur = true },
    .{ .binary = "zen-browser", .pkg = "zen-browser-bin", .needs_aur = true },
    .{ .binary = "vivaldi-stable", .pkg = "vivaldi", .needs_aur = true },
    .{ .binary = "microsoft-edge-stable", .pkg = "microsoft-edge-stable-bin", .needs_aur = true },
    .{ .binary = "librewolf", .pkg = "librewolf-bin", .needs_aur = true },
    .{ .binary = "firefox", .pkg = "firefox", .needs_aur = false },
};

const PIN_DISCORD_OPTIONS = [_][:0]const u8{ "Discord", "Vesktop", "Equibop" };
const PIN_DISCORD_INFO = [_]PinInfo{
    .{ .binary = "discord", .pkg = "discord", .needs_aur = false },
    .{ .binary = "vesktop", .pkg = "vesktop-bin", .needs_aur = true },
    .{ .binary = "equibop", .pkg = "equibop-bin", .needs_aur = true },
};

const AboutLink = struct { title: [:0]const u8, subtitle: [:0]const u8, icon: [:0]const u8, url: [:0]const u8 };
const ABOUT_LINKS = [_]AboutLink{
    .{ .title = "GitHub repository", .subtitle = REPO_URL, .icon = "system-search-symbolic", .url = REPO_URL },
    .{ .title = "Report an issue", .subtitle = REPO_URL ++ "/issues", .icon = "dialog-warning-symbolic", .url = REPO_URL ++ "/issues" },
    .{ .title = "Email \u{2014} bugs and suggestions", .subtitle = CONTACT_EMAIL, .icon = "mail-send-symbolic", .url = "mailto:" ++ CONTACT_EMAIL },
    .{ .title = "Join the Discord", .subtitle = DISCORD_URL, .icon = "user-available-symbolic", .url = DISCORD_URL },
};

// ---------------------------------------------------------------------
// Widget-page builders + their signal handlers
// ---------------------------------------------------------------------

var g_autostart_switch: ?*gtk.GtkSwitch = null;

fn buildWelcomePage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_valign(@ptrCast(box), gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 48);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 48);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 36);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 36);

    if (fileExists(g_logo_path)) {
        const logo = gtk.gtk_picture_new_for_filename(g_logo_path);
        gtk.gtk_picture_set_content_fit(logo, gtk.CONTENT_FIT_CONTAIN);
        gtk.gtk_widget_set_size_request(@ptrCast(logo), 128, 128);
        gtk.gtk_widget_set_halign(@ptrCast(logo), gtk.ALIGN_CENTER);
        gtk.gtk_box_append(box, @ptrCast(logo));
    } else {
        const icon = gtk.gtk_image_new_from_icon_name("preferences-desktop-display-symbolic");
        gtk.gtk_image_set_pixel_size(icon, 64);
        gtk.gtk_widget_add_css_class(@ptrCast(icon), "dim-label");
        gtk.gtk_box_append(box, @ptrCast(icon));
    }

    const title = gtk.gtk_label_new("Welcome to Simpbar");
    gtk.gtk_widget_add_css_class(@ptrCast(title), "title-1");
    gtk.gtk_box_append(box, @ptrCast(title));

    const subtitle = gtk.gtk_label_new("Hello and welcome to Simpbar hope you'll find your\n" ++
        "home here!, If there is any bugs or any suggestions you want\n" ++
        "please send me a email in the links page!");
    gtk.gtk_widget_add_css_class(@ptrCast(subtitle), "dim-label");
    gtk.gtk_label_set_justify(subtitle, gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_wrap(subtitle, 1);
    gtk.gtk_box_append(box, @ptrCast(subtitle));

    const autostart_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(@ptrCast(autostart_box), gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(@ptrCast(autostart_box), 12);

    const autostart_label = gtk.gtk_label_new("Launch on startup");
    const autostart_switch = gtk.gtk_switch_new();
    gtk.gtk_widget_set_valign(@ptrCast(autostart_switch), gtk.ALIGN_CENTER);
    gtk.gtk_switch_set_active(autostart_switch, @intFromBool(isHyprLineEnabled(SIMPBAR_WELCOME_AUTOSTART_LINE)));
    _ = gtk.g_signal_connect_data(@ptrCast(autostart_switch), "notify::active", @ptrCast(&onAutostartToggled), null, null, 0);
    g_autostart_switch = autostart_switch;

    gtk.gtk_box_append(autostart_box, @ptrCast(autostart_label));
    gtk.gtk_box_append(autostart_box, @ptrCast(autostart_switch));
    gtk.gtk_box_append(box, @ptrCast(autostart_box));

    return box;
}

fn onAutostartToggled(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    _ = setHyprLineEnabled(SIMPBAR_WELCOME_AUTOSTART_LINE, gtk.gtk_switch_get_active(sw) != 0);
}

fn onSteamAutostartToggled(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    _ = setHyprLineEnabled(STEAM_SILENT_AUTOSTART_LINE, gtk.gtk_switch_get_active(sw) != 0);
}

fn onEasyEffectsAutostartToggled(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    _ = setHyprLineEnabled(EASYEFFECTS_AUTOSTART_LINE, gtk.gtk_switch_get_active(sw) != 0);
}

fn onSetupActionClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const action: *const SetupAction = @ptrCast(@alignCast(data orelse return));
    launchArgv(action.argv);
}

fn onEasyEffectsInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchArgv(&EASYEFFECTS_ARGV);
}

fn onRemoveNeovimClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchArgv(&REMOVE_NEOVIM_ARGV);
}

var g_graphics_row: ?*gtk.AdwComboRow = null;
var g_video_row: ?*gtk.AdwComboRow = null;
var g_editor_row: ?*gtk.AdwComboRow = null;
var g_browser_row: ?*gtk.AdwComboRow = null;
var g_discord_row: ?*gtk.AdwComboRow = null;

fn onGraphicsInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_graphics_row.?);
    if (idx >= GRAPHICS_PACKAGES.len) return;
    var buf: [256]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "sudo pacman -S --noconfirm --needed {s}; echo; read -p 'Press Enter to close...'", .{GRAPHICS_PACKAGES[idx]}) catch return;
    launchArgv(&[_][:0]const u8{ "foot", "-e", "bash", "-lc", script });
}

fn onVideoPlayerInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_video_row.?);
    if (idx >= VIDEO_PLAYER_PACKAGES.len) return;
    var buf: [256]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "sudo pacman -S --noconfirm --needed {s}; echo; read -p 'Press Enter to close...'", .{VIDEO_PLAYER_PACKAGES[idx]}) catch return;
    launchArgv(&[_][:0]const u8{ "foot", "-e", "bash", "-lc", script });
}

fn onEditorInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_editor_row.?);
    if (idx >= EDITOR_OPTIONS.len) return;
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, EDITOR_PACKAGES[idx], EDITOR_NEEDS_AUR[idx]);
    var buf: [400]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; echo; read -p 'Press Enter to close...'", .{install_cmd}) catch return;
    launchArgv(&[_][:0]const u8{ "foot", "-e", "bash", "-lc", script });
}

fn onBrowserPinApplyClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_browser_row.?);
    if (idx >= PIN_BROWSER_INFO.len) return;
    const info = PIN_BROWSER_INFO[idx];
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, info.pkg, info.needs_aur);
    var buf: [500]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; mkdir -p \"$HOME/.config/simpbar\" && echo {s} > \"$HOME/.config/simpbar/browser-choice\"; echo; read -p 'Press Enter to close...'", .{ install_cmd, info.binary }) catch return;
    launchArgv(&[_][:0]const u8{ "foot", "-e", "bash", "-lc", script });
}

fn onDiscordPinApplyClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_discord_row.?);
    if (idx >= PIN_DISCORD_INFO.len) return;
    const info = PIN_DISCORD_INFO[idx];
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, info.pkg, info.needs_aur);
    var buf: [500]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; mkdir -p \"$HOME/.config/simpbar\" && echo {s} > \"$HOME/.config/simpbar/discord-choice\"; echo; read -p 'Press Enter to close...'", .{ install_cmd, info.binary }) catch return;
    launchArgv(&[_][:0]const u8{ "foot", "-e", "bash", "-lc", script });
}

fn makeStringList(items: []const [:0]const u8) *gtk.GtkStringList {
    var buf: [16]?[*:0]const u8 = undefined;
    for (items, 0..) |s, i| buf[i] = s;
    buf[items.len] = null;
    return gtk.gtk_string_list_new(@ptrCast(&buf));
}

fn buildSetupPage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 24);

    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Setup and quick actions");
    for (&SETUP_ACTIONS) |*action| {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), action.title);
        gtk.adw_action_row_set_subtitle(row, action.subtitle);
        gtk.adw_action_row_set_icon_name(row, action.icon);
        const button = gtk.gtk_button_new_with_label("Launch");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onSetupActionClicked), @constCast(@ptrCast(action)), null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(button));
        gtk.adw_action_row_set_activatable_widget(row, @ptrCast(button));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(group));

    const media_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(media_group, "Audio and graphics");

    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Install EasyEffects");
        gtk.adw_action_row_set_subtitle(row, "Audio effects for PipeWire, with the Calf, LSP, MDA, x42, and ZAM plugin packs included.");
        gtk.adw_action_row_set_icon_name(row, "multimedia-volume-control-symbolic");
        const button = gtk.gtk_button_new_with_label("Install");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onEasyEffectsInstallClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(button));
        gtk.adw_preferences_group_add(media_group, @ptrCast(row));
    }
    {
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Install a graphics app");
        gtk.adw_action_row_set_subtitle(@ptrCast(row), "GIMP (photo editing), Inkscape (vector art), or Krita (painting).");
        gtk.adw_combo_row_set_model(row, @ptrCast(makeStringList(&GRAPHICS_OPTIONS)));
        g_graphics_row = row;
        const button = gtk.gtk_button_new_with_label("Install");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onGraphicsInstallClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(media_group, @ptrCast(row));
    }
    {
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Install a video player");
        gtk.adw_action_row_set_subtitle(@ptrCast(row), "mpv (lightweight) or VLC (more built-in codecs/features).");
        gtk.adw_combo_row_set_model(row, @ptrCast(makeStringList(&VIDEO_PLAYER_OPTIONS)));
        g_video_row = row;
        const button = gtk.gtk_button_new_with_label("Install");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onVideoPlayerInstallClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(media_group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(media_group));

    const editor_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(editor_group, "Text editors");
    gtk.adw_preferences_group_set_description(editor_group, "Neovim + LazyVim comes installed by default.");
    {
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Install a text editor");
        gtk.adw_action_row_set_subtitle(@ptrCast(row), "Gedit and Kate are GUI editors; VS Code installs via the AUR.");
        gtk.adw_combo_row_set_model(row, @ptrCast(makeStringList(&EDITOR_OPTIONS)));
        g_editor_row = row;
        const button = gtk.gtk_button_new_with_label("Install");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onEditorInstallClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(editor_group, @ptrCast(row));
    }
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Remove Neovim and LazyVim");
        gtk.adw_action_row_set_subtitle(row, "Uninstalls neovim and deletes its config/data/cache directories.");
        gtk.adw_action_row_set_icon_name(row, "user-trash-symbolic");
        const button = gtk.gtk_button_new_with_label("Remove");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "destructive-action");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onRemoveNeovimClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(button));
        gtk.adw_preferences_group_add(editor_group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(editor_group));

    const pins_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(pins_group, "Pinned apps");
    gtk.adw_preferences_group_set_description(pins_group, "Picks which app the bar's Browser/Discord pins launch. Installs it if needed.");
    {
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Pinned browser");
        gtk.adw_combo_row_set_model(row, @ptrCast(makeStringList(&PIN_BROWSER_OPTIONS)));
        g_browser_row = row;
        const button = gtk.gtk_button_new_with_label("Apply");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onBrowserPinApplyClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(pins_group, @ptrCast(row));
    }
    {
        const row = gtk.adw_combo_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Pinned Discord client");
        gtk.adw_combo_row_set_model(row, @ptrCast(makeStringList(&PIN_DISCORD_OPTIONS)));
        g_discord_row = row;
        const button = gtk.gtk_button_new_with_label("Apply");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onDiscordPinApplyClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(pins_group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(pins_group));

    const autostart_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(autostart_group, "Autostart");
    gtk.adw_preferences_group_set_description(autostart_group, "Launch these silently in the background on login.");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Start Steam silently");
        gtk.adw_action_row_set_subtitle(row, "Runs steam -silent \u{2014} Steam starts minimized to the tray.");
        gtk.adw_action_row_set_icon_name(row, "applications-games-symbolic");
        const sw = gtk.gtk_switch_new();
        gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
        gtk.gtk_switch_set_active(sw, @intFromBool(isHyprLineEnabled(STEAM_SILENT_AUTOSTART_LINE)));
        _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onSteamAutostartToggled), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
        gtk.adw_preferences_group_add(autostart_group, @ptrCast(row));
    }
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Start EasyEffects");
        gtk.adw_action_row_set_subtitle(row, "Runs easyeffects --gapplication-service \u{2014} applies your audio effects without opening a window.");
        gtk.adw_action_row_set_icon_name(row, "multimedia-volume-control-symbolic");
        const sw = gtk.gtk_switch_new();
        gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
        gtk.gtk_switch_set_active(sw, @intFromBool(isHyprLineEnabled(EASYEFFECTS_AUTOSTART_LINE)));
        _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", @ptrCast(&onEasyEffectsAutostartToggled), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
        gtk.adw_preferences_group_add(autostart_group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(autostart_group));

    return box;
}

fn buildKeybindingsPage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 24);

    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Keybindings");
    for (&KEYBINDINGS) |*kb| {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), kb.combo);
        gtk.adw_action_row_set_subtitle(row, kb.action);
        gtk.gtk_widget_add_css_class(@ptrCast(row), "property");
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(group));

    const config_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(config_group, "Editing your config");
    var desc_buf: [128]u8 = undefined;
    const desc = std.fmt.bufPrintZ(&desc_buf, "Change keybindings or monitor setup with:\nnvim {s}", .{HYPRLAND_CONF}) catch "Change keybindings or monitor setup with nvim.";
    gtk.adw_preferences_group_set_description(config_group, desc);
    gtk.gtk_box_append(box, @ptrCast(config_group));

    return box;
}

fn onAboutRowActivated(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const url_ptr: [*:0]const u8 = @ptrCast(data orelse return);
    launchArgv(&[_][:0]const u8{ "xdg-open", std.mem.span(url_ptr) });
}

fn buildAboutPage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 24);

    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Links");
    for (&ABOUT_LINKS) |*link| {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), link.title);
        gtk.adw_action_row_set_subtitle(row, link.subtitle);
        gtk.adw_action_row_set_icon_name(row, link.icon);
        gtk.gtk_list_box_row_set_activatable(@ptrCast(row), 1);
        _ = gtk.g_signal_connect_data(@ptrCast(row), "activated", @ptrCast(&onAboutRowActivated), @constCast(@ptrCast(link.url)), null, 0);
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
    gtk.gtk_box_append(box, @ptrCast(group));

    return box;
}

// ---------------------------------------------------------------------
// Updates page
// ---------------------------------------------------------------------

var g_check_button: ?*gtk.GtkButton = null;
var g_apply_button: ?*gtk.GtkButton = null;
var g_spinner: ?*gtk.GtkSpinner = null;

const GroupRows = struct {
    group: ?*gtk.AdwPreferencesGroup = null,
    rows: [MAX_UPDATE_ENTRIES + 1]*gtk.AdwActionRow = undefined,
    count: usize = 0,
};
var g_arch_rows: GroupRows = .{};
var g_aur_rows: GroupRows = .{};
var g_flatpak_rows: GroupRows = .{};

fn clearGroup(gr: *GroupRows) void {
    var i: usize = 0;
    while (i < gr.count) : (i += 1) gtk.adw_preferences_group_remove(gr.group.?, @ptrCast(gr.rows[i]));
    gr.count = 0;
}

fn setGroupMessage(gr: *GroupRows, message: [:0]const u8) void {
    clearGroup(gr);
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), message);
    gtk.adw_preferences_group_add(gr.group.?, @ptrCast(row));
    gr.rows[0] = row;
    gr.count = 1;
}

fn populateGroup(gr: *GroupRows, list: *UpdateList, empty_message: [:0]const u8) void {
    clearGroup(gr);
    if (list.count == 0) {
        setGroupMessage(gr, empty_message);
        return;
    }
    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        const entry = &list.entries[i];
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), entry.nameZ());
        gtk.adw_action_row_set_subtitle(row, entry.infoZ());
        gtk.adw_preferences_group_add(gr.group.?, @ptrCast(row));
        gr.rows[gr.count] = row;
        gr.count += 1;
    }
}

fn onCheckUpdatesClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    gtk.gtk_widget_set_sensitive(@ptrCast(g_check_button.?), 0);
    gtk.gtk_widget_set_sensitive(@ptrCast(g_apply_button.?), 0);
    gtk.gtk_spinner_start(g_spinner.?);
    setGroupMessage(&g_arch_rows, "Checking\u{2026}");
    setGroupMessage(&g_aur_rows, "Checking\u{2026}");
    setGroupMessage(&g_flatpak_rows, "Checking\u{2026}");

    const result = gpa.create(UpdateCheckResult) catch return;
    result.* = .{};
    const t = std.Thread.spawn(.{}, updateCheckThreadFn, .{result}) catch {
        gpa.destroy(result);
        return;
    };
    t.detach();
}

fn onUpdateCheckIdle(data: ?*anyopaque) callconv(.c) c_int {
    const result: *UpdateCheckResult = @ptrCast(@alignCast(data orelse return 0));
    gtk.gtk_spinner_stop(g_spinner.?);
    gtk.gtk_widget_set_sensitive(@ptrCast(g_check_button.?), 1);

    if (result.arch.ok) {
        populateGroup(&g_arch_rows, &result.arch, "Everything up to date.");
    } else {
        setGroupMessage(&g_arch_rows, "Could not check \u{2014} is pacman-contrib installed?");
    }

    if (result.aur.ok) {
        populateGroup(&g_aur_rows, &result.aur, "Everything up to date, or no AUR helper installed.");
    } else {
        setGroupMessage(&g_aur_rows, "Could not check AUR updates.");
    }

    if (result.flatpak.ok) {
        populateGroup(&g_flatpak_rows, &result.flatpak, "Everything up to date.");
    } else {
        setGroupMessage(&g_flatpak_rows, "Could not check \u{2014} is flatpak installed?");
    }

    const total = result.arch.count + result.aur.count + result.flatpak.count;
    gtk.gtk_widget_set_sensitive(@ptrCast(g_apply_button.?), @intFromBool(total > 0));

    gpa.destroy(result);
    return 0; // G_SOURCE_REMOVE
}

fn onApplyUpdatesClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchArgv(&APPLY_ALL_UPDATES_ARGV);
}

fn buildUpdatesPage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 24);

    const button_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    const check_button = gtk.gtk_button_new_with_label("Check for Updates");
    gtk.gtk_widget_add_css_class(@ptrCast(check_button), "suggested-action");
    _ = gtk.g_signal_connect_data(@ptrCast(check_button), "clicked", @ptrCast(&onCheckUpdatesClicked), null, null, 0);
    gtk.gtk_box_append(button_row, @ptrCast(check_button));
    g_check_button = check_button;

    const spinner = gtk.gtk_spinner_new();
    gtk.gtk_box_append(button_row, @ptrCast(spinner));
    g_spinner = spinner;
    gtk.gtk_box_append(box, @ptrCast(button_row));

    const arch_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(arch_group, "Arch Linux packages");
    const aur_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(aur_group, "AUR packages");
    const flatpak_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(flatpak_group, "Flatpak apps");
    g_arch_rows.group = arch_group;
    g_aur_rows.group = aur_group;
    g_flatpak_rows.group = flatpak_group;
    gtk.gtk_box_append(box, @ptrCast(arch_group));
    gtk.gtk_box_append(box, @ptrCast(aur_group));
    gtk.gtk_box_append(box, @ptrCast(flatpak_group));

    const apply_button = gtk.gtk_button_new_with_label("Apply all updates");
    gtk.gtk_widget_add_css_class(@ptrCast(apply_button), "flat");
    gtk.gtk_widget_set_sensitive(@ptrCast(apply_button), 0);
    _ = gtk.g_signal_connect_data(@ptrCast(apply_button), "clicked", @ptrCast(&onApplyUpdatesClicked), null, null, 0);
    gtk.gtk_box_append(box, @ptrCast(apply_button));
    g_apply_button = apply_button;

    setGroupMessage(&g_arch_rows, "Click \"Check for Updates\" above to scan.");
    setGroupMessage(&g_aur_rows, "Click \"Check for Updates\" above to scan.");
    setGroupMessage(&g_flatpak_rows, "Click \"Check for Updates\" above to scan.");

    return box;
}

// ---------------------------------------------------------------------
// Window / application
// ---------------------------------------------------------------------

const PAGE_NAMES = [_][:0]const u8{ "Welcome", "Setup", "Updates", "Keybindings", "About" };
const PAGE_ICONS = [_][:0]const u8{ "go-home-symbolic", "emblem-system-symbolic", "software-update-available-symbolic", "input-keyboard-symbolic", "help-about-symbolic" };

var g_sidebar_rows: [PAGE_NAMES.len]*gtk.GtkListBoxRow = undefined;
var g_content_stack: ?*gtk.GtkStack = null;
var g_window: ?*gtk.AdwApplicationWindow = null;

fn onSidebarRowSelected(_: *gtk.GtkListBox, row: ?*gtk.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const r = row orelse return;
    for (g_sidebar_rows, 0..) |sr, i| {
        if (sr == r) {
            gtk.gtk_stack_set_visible_child_name(g_content_stack.?, PAGE_NAMES[i]);
            return;
        }
    }
}

fn onWindowCloseRequest(_: *gtk.GtkWindow, _: ?*anyopaque) callconv(.c) c_int {
    markShown();
    return 0; // allow the window to actually close
}

fn buildWindow(app: *anyopaque) *gtk.AdwApplicationWindow {
    const window = gtk.adw_application_window_new(app);
    gtk.gtk_window_set_title(@ptrCast(window), "Simpbar Welcome");
    gtk.gtk_window_set_default_size(@ptrCast(window), 760, 700);

    const split_view = gtk.adw_navigation_split_view_new();

    const sidebar_list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(sidebar_list), "navigation-sidebar");
    gtk.gtk_list_box_set_selection_mode(sidebar_list, gtk.SELECTION_SINGLE);

    const pages = [_]*gtk.GtkBox{
        buildWelcomePage(),
        buildSetupPage(),
        buildUpdatesPage(),
        buildKeybindingsPage(),
        buildAboutPage(),
    };

    const content_stack = gtk.gtk_stack_new();
    gtk.gtk_stack_set_transition_type(content_stack, gtk.STACK_TRANSITION_CROSSFADE);
    gtk.gtk_widget_set_vexpand(@ptrCast(content_stack), 1);
    gtk.gtk_widget_set_hexpand(@ptrCast(content_stack), 1);
    g_content_stack = content_stack;

    for (PAGE_NAMES, 0..) |name, i| {
        const row = gtk.gtk_list_box_row_new();
        const row_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_set_margin_top(@ptrCast(row_box), 8);
        gtk.gtk_widget_set_margin_bottom(@ptrCast(row_box), 8);
        gtk.gtk_widget_set_margin_start(@ptrCast(row_box), 12);
        gtk.gtk_widget_set_margin_end(@ptrCast(row_box), 12);
        gtk.gtk_box_append(row_box, @ptrCast(gtk.gtk_image_new_from_icon_name(PAGE_ICONS[i])));
        const label = gtk.gtk_label_new(name);
        gtk.gtk_label_set_xalign(label, 0);
        gtk.gtk_box_append(row_box, @ptrCast(label));
        gtk.gtk_list_box_row_set_child(row, @ptrCast(row_box));
        gtk.gtk_list_box_append(sidebar_list, @ptrCast(row));
        g_sidebar_rows[i] = row;

        const scrolled = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
        gtk.gtk_widget_set_vexpand(@ptrCast(scrolled), 1);
        gtk.gtk_widget_set_hexpand(@ptrCast(scrolled), 1);
        gtk.gtk_scrolled_window_set_child(scrolled, @ptrCast(pages[i]));
        _ = gtk.gtk_stack_add_named(content_stack, @ptrCast(scrolled), name);
    }

    _ = gtk.g_signal_connect_data(@ptrCast(sidebar_list), "row-selected", @ptrCast(&onSidebarRowSelected), null, null, 0);

    const sidebar_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(sidebar_toolbar, @ptrCast(gtk.adw_header_bar_new()));
    gtk.adw_toolbar_view_set_content(sidebar_toolbar, @ptrCast(sidebar_list));
    const sidebar_page = gtk.adw_navigation_page_new(@ptrCast(sidebar_toolbar), "Simpbar");
    gtk.adw_navigation_split_view_set_sidebar(split_view, sidebar_page);

    const content_toolbar = gtk.adw_toolbar_view_new();
    gtk.adw_toolbar_view_add_top_bar(content_toolbar, @ptrCast(gtk.adw_header_bar_new()));
    gtk.adw_toolbar_view_set_content(content_toolbar, @ptrCast(content_stack));
    const content_page = gtk.adw_navigation_page_new(@ptrCast(content_toolbar), "");
    gtk.adw_navigation_split_view_set_content(split_view, content_page);

    gtk.adw_application_window_set_content(window, @ptrCast(split_view));

    gtk.gtk_list_box_select_row(sidebar_list, gtk.gtk_list_box_get_row_at_index(sidebar_list, 0));

    _ = gtk.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onWindowCloseRequest), null, null, 0);

    return window;
}

var g_autostart_mode: bool = false;

fn onAppActivate(app: *gtk.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_autostart_mode and fileExists(g_first_run_marker_path)) {
        gtk.g_application_quit(app);
        return;
    }

    // The system-wide icon theme (Dracula) doesn't have full coverage of
    // generic symbolic icon names like "audio-speakers-symbolic". Force
    // Adwaita for this app specifically — doesn't touch the system-wide
    // setting, just makes our own icons resolve reliably.
    if (gtk.gtk_settings_get_default()) |settings| {
        gtk.g_object_set(@ptrCast(settings), "gtk-icon-theme-name", @as([*:0]const u8, "Adwaita"), @as(?*anyopaque, null));
    }

    if (g_window == null) {
        g_window = buildWindow(@ptrCast(app));
    }
    gtk.gtk_window_present(@ptrCast(g_window.?));
}

pub fn main() !void {
    resolvePaths();
    g_autostart_mode = detectAutostartMode();

    const app = gtk.adw_application_new(APP_ID, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&onAppActivate), null, null, 0);
    const code = gtk.g_application_run(@ptrCast(app), 0, null);
    exit(code);
}

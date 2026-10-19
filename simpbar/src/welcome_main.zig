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
const logging = @import("logging.zig");

pub const panic = std.debug.FullPanic(logging.panicHandler);

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
const WNOHANG: c_int = 1;

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
var terminal_spec_buf: [512]u8 = undefined;

var g_hyprland_lua_path: [:0]const u8 = "";
var g_first_run_marker_path: [:0]const u8 = "";
var g_logo_path: [:0]const u8 = "";
var g_simpbar_config_dir: [:0]const u8 = "";
var g_terminal_spec_path: [:0]const u8 = "";

fn resolvePaths() void {
    const home = std.mem.span(getenv("HOME") orelse "/root");
    g_hyprland_lua_path = std.fmt.bufPrintZ(&hyprland_lua_buf, "{s}/.config/hypr/hyprland.lua", .{home}) catch "";
    g_first_run_marker_path = std.fmt.bufPrintZ(&first_run_marker_buf, "{s}/.config/simpbar/welcome-shown", .{home}) catch "";
    g_logo_path = std.fmt.bufPrintZ(&logo_path_buf, "{s}/.local/share/simpbar/logo.png", .{home}) catch "";
    g_simpbar_config_dir = std.fmt.bufPrintZ(&simpbar_config_dir_buf, "{s}/.config/simpbar", .{home}) catch "";
    g_terminal_spec_path = std.fmt.bufPrintZ(&terminal_spec_buf, "{s}/.config/simpbar/terminal", .{home}) catch "";
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

/// True when `name` is a runnable program on this machine's PATH — follows
/// the PATH env var itself (rather than pinning /usr/bin) so terminals
/// installed outside the usual prefixes (wezterm in ~/.cargo/bin, ...)
/// still resolve.
fn commandExists(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false; // not a bare name
    var buf: [400]u8 = undefined;
    const path_env = getenv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (access(path, X_OK) == 0) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// Package installation (Arch Linux / pacman + AUR helpers)
// ---------------------------------------------------------------------

/// The base "install this system package" command.
fn buildSystemInstallCmd(buf: []u8, pkg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "sudo pacman -S --noconfirm --needed {s}", .{pkg}) catch "";
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
    logging.step("first-run marker written to {s}", .{g_first_run_marker_path});
}

// ---------------------------------------------------------------------
// Launching external commands
// ---------------------------------------------------------------------

/// Fire-and-forget launch of an external command, PATH-searched via
/// /usr/bin/env, detached via the standard double-fork (mirrors
/// spawnDetached/spawnPlayerctlCommand in the bar's main.zig).
fn launchArgv(argv: []const [:0]const u8) void {
    if (argv.len == 0 or argv.len > 14) {
        logging.warn("launch: bad argv (len {d})", .{argv.len});
        return;
    }
    const pid = libc_proc.fork();
    if (pid < 0) {
        logging.warn("launch: fork failed for {s}", .{argv[0]});
        return;
    }
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
    if (argv.len == 0 or argv.len > 14) {
        logging.warn("runCaptured: bad argv (len {d})", .{argv.len});
        return null;
    }
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) {
        logging.warn("runCaptured: pipe failed for {s}", .{argv[0]});
        return null;
    }
    const read_fd = fds[0];
    const write_fd = fds[1];

    const pid = libc_proc.fork();
    if (pid < 0) {
        logging.warn("runCaptured: fork failed for {s}", .{argv[0]});
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
    return buildSystemInstallCmd(buf, pkg);
}

// ---------------------------------------------------------------------
// Terminal resolution — every terminal-bound action in this app runs in
// whichever terminal the user actually chose (install.sh asks and writes
// its pick down), never a hardcoded one.
// ---------------------------------------------------------------------

// Resolution order:
//   1. $SIMPBAR_TERMINAL         ("kitty", "foot -e", ...) — instant override
//   2. ~/.config/simpbar/terminal (install.sh writes its pick there; format
//                                  "<binary>[ <exec-flag>]")
//   3. xdg-terminal-exec          (the XDG default-terminal dispatcher)
//   4. PATH probe of well-known terminals, first match wins
//   5. foot (the historical default, last resort)
//
// A spec's second token is the flag that separates the terminal's own
// options from the command ("foot -e bash", "kitty bash", "gnome-terminal
// -- bash"). All of it re-resolves per launch — cheap, and it follows a
// user who edits the file or switches their setup without a restart.

var g_term_bin_buf: [256]u8 = undefined;
var g_term_flag_buf: [8]u8 = undefined;
var g_term_bin: [:0]const u8 = "foot";
var g_term_flag: ?[:0]const u8 = "-e";
var g_term_resolved: bool = false;

/// Applies one "<binary> [flag]" spec to the global state; ts:false when
/// the binary itself doesn't exist in PATH (so the caller falls through to
/// the next resolution source instead of launching a missing program).
fn applyTermSpec(spec: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, spec, " \t\r\n");
    const bin = it.next() orelse return false;
    if (bin.len == 0 or bin.len >= g_term_bin_buf.len or bin[0] == '#') return false;
    if (!commandExists(bin)) return false;
    g_term_flag = null;
    if (it.next()) |flag| {
        // A third+ tokens are not understood — only binary + flag specs work.
        if (it.next() != null) return false;
        if (flag.len >= g_term_flag_buf.len) return false;
        @memcpy(g_term_flag_buf[0..flag.len], flag);
        g_term_flag_buf[flag.len] = 0;
        g_term_flag = g_term_flag_buf[0..flag.len :0];
    }
    @memcpy(g_term_bin_buf[0..bin.len], bin);
    g_term_bin_buf[bin.len] = 0;
    g_term_bin = g_term_bin_buf[0..bin.len :0];
    return true;
}

/// One well-known terminal and the flag it wants before the command
/// (`null` = appends the command bare — or dispatches itself, in
/// xdg-terminal-exec's case).
const TermProbe = struct { bin: [:0]const u8, flag: ?[:0]const u8 };
const TERM_PROBES = [_]TermProbe{
    .{ .bin = "kitty", .flag = null }, // kitty takes the command bare
    .{ .bin = "ghostty", .flag = "-e" },
    .{ .bin = "foot", .flag = "-e" },
    .{ .bin = "alacritty", .flag = "-e" },
    .{ .bin = "wezterm", .flag = "-e" },
    .{ .bin = "konsole", .flag = "-e" },
    .{ .bin = "ptyxis", .flag = "-e" },
    .{ .bin = "tilix", .flag = "-e" },
    .{ .bin = "gnome-terminal", .flag = "--" },
    .{ .bin = "xfce4-terminal", .flag = "-x" },
    .{ .bin = "terminator", .flag = "-x" },
};

fn resolveTerminal() void {
    if (g_term_resolved) return;
    g_term_resolved = true;

    if (getenv("SIMPBAR_TERMINAL")) |v| {
        if (applyTermSpec(std.mem.span(v))) {
            logging.step("terminal: $SIMPBAR_TERMINAL: {s}", .{g_term_bin});
            return;
        }
    }
    if (readFileAll(g_terminal_spec_path)) |data| {
        defer gpa.free(data);
        if (applyTermSpec(data)) {
            logging.step("terminal: config file: {s}", .{g_term_bin});
            return;
        }
    }
    if (commandExists("xdg-terminal-exec")) {
        g_term_bin = "xdg-terminal-exec";
        g_term_flag = null; // it dispatches to the default terminal itself
        logging.step("terminal: xdg-terminal-exec", .{});
        return;
    }
    for (&TERM_PROBES) |*p| {
        if (commandExists(p.bin)) {
            g_term_bin = p.bin;
            g_term_flag = p.flag;
            logging.step("terminal: PATH probe: {s}", .{g_term_bin});
            return;
        }
    }
    logging.warn("terminal: nothing found in PATH — falling back to foot", .{});
}

/// Runs a bash script in the user's terminal (new window, detached):
/// "<terminal> [<flag>] bash -lc <script>". The `read` tail in the scripts
/// themselves keeps the window visible after the command exits.
fn launchInTerminal(script: [:0]const u8) void {
    resolveTerminal();
    if (g_term_flag) |flag| {
        launchArgv(&[_][:0]const u8{ g_term_bin, flag, "bash", "-lc", script });
    } else {
        launchArgv(&[_][:0]const u8{ g_term_bin, "bash", "-lc", script });
    }
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

/// Raw "pkgname", "old version", "new version" of one updatable package into
/// the next free slot of an UpdateList.
fn addUpdateEntry(list: *UpdateList, name: []const u8, old_ver: []const u8, new_ver: []const u8) bool {
    if (list.count >= MAX_UPDATE_ENTRIES) return false;
    if (name.len == 0 or old_ver.len == 0 or new_ver.len == 0) return false;
    const entry = &list.entries[list.count];
    if (name.len >= entry.name.len) return false;
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    const info = std.fmt.bufPrint(&entry.info, "{s} \u{2192} {s}", .{ old_ver, new_ver }) catch return false;
    entry.info_len = info.len;
    return true;
}

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
    return addUpdateEntry(list, name, old_ver, new_ver);
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
        logging.warn("update check: checkupdates not installed", .{});
        return;
    }
    const output = runCaptured(&[_][:0]const u8{"checkupdates"}, 30000) orelse {
        list.ok = false;
        logging.warn("update check: checkupdates failed or timed out", .{});
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
        logging.warn("update check: {s} -Qua failed or timed out", .{h});
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
        logging.warn("update check: flatpak update --appstream failed or timed out", .{});
        return;
    }
    const output = runCaptured(&[_][:0]const u8{ "flatpak", "remote-ls", "--updates", "--columns=application,version", "flathub" }, 30000) orelse {
        list.ok = false;
        logging.warn("update check: flatpak remote-ls --updates failed or timed out", .{});
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
    logging.step("update check thread started", .{});
    fetchArchUpdates(&result.arch);
    fetchAurUpdates(&result.aur);
    fetchFlatpakUpdates(&result.flatpak);
    logging.step("update check done: {d} arch, {d} aur, {d} flatpak", .{ result.arch.count, result.aur.count, result.flatpak.count });
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
    /// Script to run in the user's terminal, XOR a direct argv to launch
    /// bare (only one of the two is set per action).
    script: ?[:0]const u8 = null,
    argv: []const [:0]const u8 = &[_][:0]const u8{},
};

var SETUP_ACTIONS = [_]SetupAction{
    .{
        .title = "Update Simpbar",
        .subtitle = "Re-fetches the latest install script and configs from GitHub. Opens in a terminal \u{2014} asks a few of the same " ++
            "setup questions again as part of the refresh.",
        .icon = "software-update-available-symbolic",
        .script = "curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash; echo; read -p 'Press Enter to close...'",
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
        .title = "Customize GTK theme, icons and cursor",
        .subtitle = "Opens nwg-look. Dracula GTK/icons and Bibata Modern Classic are already set as defaults.",
        .icon = "preferences-desktop-theme-symbolic",
        .argv = &[_][:0]const u8{"nwg-look"},
    },
    .{
        .title = "Tweak Hyprland settings",
        .subtitle = "Opens Simpbar Config \u{2014} keybinds, monitors, animations, window rules, " ++
            "and more. Saves to ~/.config/simpbar/hyprland.json and reloads Hyprland live.",
        .icon = "preferences-desktop-display-symbolic",
        .argv = &[_][:0]const u8{"simpbar-config"},
    },
    .{
        .title = "Adjust audio devices and volumes",
        .subtitle = "Opens pavucontrol.",
        .icon = "audio-speakers-symbolic",
        .argv = &[_][:0]const u8{"pavucontrol"},
    },
};

const EASYEFFECTS_SCRIPT = "sudo pacman -S --noconfirm --needed easyeffects calf lsp-plugins-lv2 mda.lv2 x42-plugins-lv2 zam-plugins-lv2; echo; read -p 'Press Enter to close...'";

const REMOVE_NEOVIM_SCRIPT = "sudo pacman -Rns --noconfirm neovim; " ++
    "rm -rf ~/.config/nvim ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim; " ++
    "echo; read -p 'Press Enter to close...'";

const APPLY_ALL_UPDATES_SCRIPT = "sudo pacman -Syu --noconfirm; " ++
    "if command -v yay >/dev/null; then yay -Sua --noconfirm; " ++
    "elif command -v paru >/dev/null; then paru -Sua --noconfirm; fi; " ++
    "command -v flatpak >/dev/null && flatpak update -y; " ++
    "echo; read -p 'Press Enter to close...'";

// ---------------------------------------------------------------------
// Keychron keyboards: WebHID udev rule (Keychron Launcher / VIA)
// ---------------------------------------------------------------------

/// The Keychron Launcher (launcher.keychron.com) and VIA talk to keyboards
/// through WebHID, which needs raw access to /dev/hidraw*. Linux denies that
/// to unprivileged users, so Chromium silently lists no keyboards until a
/// udev rule grants the seat user access.
///
/// The `70-` prefix is load-bearing. systemd's 73-seat-late.rules applies the
/// `uaccess` ACL, and udev evaluates rule files in lexical order — a file
/// named 99-keychron.rules, as most guides suggest, is evaluated after that
/// pass and grants nothing at all.
const KEYCHRON_RULES_PATH: [:0]const u8 = "/etc/udev/rules.d/70-keychron.rules";
const KEYCHRON_LAUNCHER_URL: [:0]const u8 = "https://launcher.keychron.com";

const KEYCHRON_RULES_CONTENT =
    "# Keychron Launcher WebHID permissions (written by simpbar-welcome)\n" ++
    "#\n" ++
    "# The 70- prefix matters: 73-seat-late.rules applies the uaccess ACL,\n" ++
    "# and udev evaluates rule files in lexical order — a 99- rule is too\n" ++
    "# late and silently grants nothing.\n" ++
    "\n" ++
    "# Keychron keyboards, mice and 2.4GHz receivers (USB vendor 3434).\n" ++
    "KERNEL==\"hidraw*\", SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"3434\", MODE=\"0660\", TAG+=\"uaccess\"\n" ++
    "\n" ++
    "# STM32 bootloader mode (hold Esc while plugging in) for firmware updates.\n" ++
    "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0483\", ATTRS{idProduct}==\"df11\", MODE=\"0660\", TAG+=\"uaccess\"\n" ++
    "\n" ++
    "# The USB device nodes themselves, so Chromium can enumerate Keychron\n" ++
    "# devices for its WebHID device chooser.\n" ++
    "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"3434\", MODE=\"0660\", TAG+=\"uaccess\"\n";

/// Chromium-family browsers, in preference order. WebHID is Chromium-only:
/// Firefox never implements it, so the Launcher's Connect button cannot work
/// there no matter what the udev rules say.
const KeychronBrowserInfo = struct { bin: []const u8, label: []const u8 };

const KEYCHRON_BROWSERS = [_]KeychronBrowserInfo{
    .{ .bin = "chromium", .label = "Chromium" },
    .{ .bin = "helium-browser", .label = "Helium" },
    .{ .bin = "google-chrome-stable", .label = "Chrome" },
    .{ .bin = "google-chrome", .label = "Chrome" },
    .{ .bin = "brave-browser", .label = "Brave" },
    .{ .bin = "brave", .label = "Brave" },
    .{ .bin = "vivaldi-stable", .label = "Vivaldi" },
    .{ .bin = "microsoft-edge-stable", .label = "Edge" },
};

var keychron_browser_buf: [64]u8 = undefined;
var keychron_model_buf: [96]u8 = undefined;

var g_keychron_row: ?*gtk.AdwActionRow = null;
var g_keychron_button: ?*gtk.GtkButton = null;
var g_keychron_polling: bool = false;
var g_keychron_poll_ticks: u32 = 0;
var g_keychron_pkexec_pid: c_int = -1;

const KeychronBrowser = struct { bin: [:0]const u8, label: []const u8 };

/// First Chromium-family browser on PATH, as a NUL-terminated slice (for
/// exec) plus a friendly name (for the row subtitle).
fn keychronBrowser() ?KeychronBrowser {
    for (KEYCHRON_BROWSERS) |entry| {
        if (!commandExists(entry.bin)) continue;
        if (entry.bin.len >= keychron_browser_buf.len) continue;
        @memcpy(keychron_browser_buf[0..entry.bin.len], entry.bin);
        keychron_browser_buf[entry.bin.len] = 0;
        return .{ .bin = keychron_browser_buf[0..entry.bin.len :0], .label = entry.label };
    }
    return null;
}

/// Finds a Keychron device in `lsusb` output and returns its model name
/// (e.g. "Keychron K2 HE"). Prefers a keyboard over a Link receiver.
fn keychronUsbModel() ?[]const u8 {
    if (!commandExists("lsusb")) return null;
    const out = runCaptured(&[_][:0]const u8{"lsusb"}, 1500) orelse return null;
    defer gpa.free(out);

    var first: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "3434:") orelse continue;
        const rest = line[at..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        var model = std.mem.trim(u8, rest[space + 1 ..], " \r\t");
        // lsusb repeats the vendor name: "Keychron Keychron K2 HE".
        if (std.mem.startsWith(u8, model, "Keychron "))
            model = model["Keychron ".len..];
        if (model.len == 0 or model.len > keychron_model_buf.len) continue;
        if (std.mem.indexOf(u8, model, "Link") != null or
            std.mem.indexOf(u8, model, "Receiver") != null)
        {
            if (first == null) first = model;
            continue;
        }
        @memcpy(keychron_model_buf[0..model.len], model);
        return keychron_model_buf[0..model.len];
    }
    if (first) |model| {
        @memcpy(keychron_model_buf[0..model.len], model);
        return keychron_model_buf[0..model.len];
    }
    return null;
}

fn keychronRulesInstalled() bool {
    return fileExists(KEYCHRON_RULES_PATH);
}

fn keychronRulesCurrent() bool {
    const data = readFileAll(KEYCHRON_RULES_PATH) orelse return false;
    defer gpa.free(data);
    return std.mem.eql(u8, data, KEYCHRON_RULES_CONTENT);
}

fn keychronSetupSubtitle(buf: []u8) [:0]const u8 {
    const exists = keychronRulesInstalled();
    const current = exists and keychronRulesCurrent();
    const detected = keychronUsbModel();
    const state_text: [:0]const u8 = if (current)
        "Rules installed. Replug the keyboard, then open launcher.keychron.com in a Chromium-based browser."
    else if (exists)
        "An older rule file is installed \u{2014} update it to grant WebHID access to every Keychron device."
    else
        "Not installed. Grants your user WebHID access to every Keychron keyboard, mouse and receiver, plus the firmware-update bootloader.";
    if (detected) |model| {
        return std.fmt.bufPrintZ(buf, "{s} Detected: {s}.", .{ state_text, model }) catch state_text;
    }
    return std.fmt.bufPrintZ(buf, "{s}", .{state_text}) catch state_text;
}

fn keychronRunScript(buf: []u8, staged_path: [:0]const u8, pkexec_style: bool) ?[:0]const u8 {
    // udevadm/install are absolute because pkexec resets PATH; the same
    // string shape works for the sudo terminal fallback. bufPrintZ() wants
    // a comptime format string, hence one literal per branch.
    if (pkexec_style) {
        return std.fmt.bufPrintZ(buf, "/usr/bin/install -Dm644 '{s}' /etc/udev/rules.d/70-keychron.rules && " ++
            "/usr/bin/udevadm control --reload-rules && " ++
            "/usr/bin/udevadm trigger --subsystem-match=hidraw && " ++
            "/usr/bin/udevadm trigger --subsystem-match=usb && " ++
            "/usr/bin/rm -f '{s}'", .{ staged_path, staged_path }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "sudo /usr/bin/install -Dm644 '{s}' /etc/udev/rules.d/70-keychron.rules && " ++
        "sudo /usr/bin/udevadm control --reload-rules && " ++
        "sudo /usr/bin/udevadm trigger --subsystem-match=hidraw && " ++
        "sudo /usr/bin/udevadm trigger --subsystem-match=usb; " ++
        "rm -f '{s}'; echo; read -p 'Press Enter to close...'", .{ staged_path, staged_path }) catch null;
}

const KeychronPkexecOutcome = union(enum) {
    none,
    running,
    exited: c_int,
};

/// pkexec authorizes its *parent* process: it reads getppid() and refuses to
/// run when that is init ("Refusing to render service to dead parents").
/// launchArgv()'s double fork detaches exactly like that, which is why the
/// row's button did nothing; here the welcome process stays the direct parent
/// for the whole polkit round trip and the 1 s poll reaps the child.
fn keychronSpawnPkexec(argv: []const [:0]const u8) bool {
    if (argv.len == 0 or argv.len > 14) return false;
    const pid = libc_proc.fork();
    if (pid < 0) {
        logging.warn("keychron: fork failed for pkexec", .{});
        return false;
    }
    if (pid == 0) {
        var buf: [16]?[*:0]const u8 = undefined;
        buf[0] = "/usr/bin/env";
        for (argv, 0..) |a, i| buf[i + 1] = a;
        buf[argv.len + 1] = null;
        _ = std.c.execve("/usr/bin/env", @ptrCast(&buf), std.c.environ);
        std.c._exit(127);
    }
    g_keychron_pkexec_pid = pid;
    return true;
}

fn keychronPkexecOutcome() KeychronPkexecOutcome {
    if (g_keychron_pkexec_pid <= 0) return .none;
    var status: c_int = 0;
    const r = std.c.waitpid(g_keychron_pkexec_pid, &status, WNOHANG);
    if (r == g_keychron_pkexec_pid) {
        g_keychron_pkexec_pid = -1;
        return .{ .exited = status };
    }
    if (r < 0) {
        // ECHILD: someone else (e.g. GLib's SIGCHLD handling) reaped it.
        g_keychron_pkexec_pid = -1;
        return .none;
    }
    return .running;
}

fn keychronPkexecSucceeded(status: c_int) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn onKeychronSetupClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    // Stage the rule content as the user first: the privileged half is then
    // a plain install(1) of a known file, with no shell quoting of the rule
    // text and no stdin tricks.
    _ = mkdir(g_simpbar_config_dir, 0o755);
    var staged_buf: [512]u8 = undefined;
    const staged = std.fmt.bufPrintZ(&staged_buf, "{s}/keychron-70.rules", .{g_simpbar_config_dir}) catch return;
    if (!writeFileAll(staged, KEYCHRON_RULES_CONTENT)) {
        logging.warn("keychron: could not stage rules file at {s}", .{staged});
        return;
    }

    var cmd_buf: [1024]u8 = undefined;
    if (commandExists("pkexec")) {
        switch (keychronPkexecOutcome()) {
            .running => {
                // A prompt is still up from the previous click — don't stack
                // a second pkexec (and a second password dialog) on top.
                logging.step("keychron: already waiting on the polkit prompt", .{});
                if (!g_keychron_polling) {
                    g_keychron_polling = true;
                    g_keychron_poll_ticks = 0;
                    _ = gtk.g_timeout_add(1000, &onKeychronPoll, null);
                }
                return;
            },
            else => {},
        }
        // One graphical polkit prompt (polkit-gnome/mate-polkit ship with
        // every simpbar install) — no terminal window for a two-line write.
        const cmd = keychronRunScript(&cmd_buf, staged, true) orelse return;
        if (!keychronSpawnPkexec(&[_][:0]const u8{ "pkexec", "/usr/bin/sh", "-c", cmd })) return;
        logging.step("keychron: staged rules, pkexec prompt launched", .{});
    } else {
        // Systems stripped of polkit: same work, but sudo in a terminal so
        // the password prompt and any error stay visible.
        const script = keychronRunScript(&cmd_buf, staged, false) orelse return;
        launchInTerminal(script);
        logging.step("keychron: staged rules, terminal sudo fallback launched", .{});
    }

    // The prompt is asynchronous: poll for the file so the row flips to
    // "Reinstall" without a restart when (and only when) the rule landed.
    if (!g_keychron_polling) {
        g_keychron_polling = true;
        g_keychron_poll_ticks = 0;
        _ = gtk.g_timeout_add(1000, &onKeychronPoll, null);
    }
}

fn onKeychronPoll(_: ?*anyopaque) callconv(.c) c_int {
    g_keychron_poll_ticks += 1;

    // pkexec is a direct child of this process (see keychronSpawnPkexec), so
    // it can be reaped here: its exit distinguishes "prompt cancelled" from
    // "still waiting for the password".
    const outcome = keychronPkexecOutcome();
    const running = switch (outcome) {
        .running => true,
        else => false,
    };

    // Success: the rule is in place and pkexec has finished its udevadm
    // trigger calls (so the ACL is already applied on replug).
    if (!running and keychronRulesCurrent()) {
        keychronShowInstalled();
        return 0; // G_SOURCE_REMOVE
    }

    switch (outcome) {
        .exited => |status| {
            // pkexec returned before the rule appeared: the polkit prompt was
            // dismissed, or the install failed. Stop polling so the next
            // click starts a fresh attempt.
            g_keychron_polling = false;
            if (keychronPkexecSucceeded(status)) {
                logging.warn("keychron: pkexec finished but the udev rule is missing", .{});
            } else {
                logging.warn("keychron: pkexec exited with status {d}; rule not installed", .{status});
            }
            if (g_keychron_row) |row| gtk.adw_action_row_set_subtitle(row, "Setup didn't complete — the password prompt was cancelled or failed. Try again.");
            return 0;
        },
        else => {},
    }

    if (g_keychron_poll_ticks >= 900) {
        g_keychron_polling = false;
        return 0;
    }
    return 1; // G_SOURCE_CONTINUE
}

fn keychronShowInstalled() void {
    g_keychron_polling = false;
    if (g_keychron_button) |button| gtk.gtk_button_set_label(button, "Reinstall");
    if (g_keychron_row) |row| {
        var buf: [512]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, keychronSetupSubtitle(&buf));
    }
}

fn onKeychronOpenClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (keychronBrowser()) |browser| {
        launchArgv(&[_][:0]const u8{ browser.bin, KEYCHRON_LAUNCHER_URL });
        return;
    }
    launchInTerminal("sudo pacman -S --noconfirm --needed chromium; echo; read -p 'Press Enter to close...'");
}

fn buildKeychronGroup() *gtk.AdwPreferencesGroup {
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Keychron keyboards");
    gtk.adw_preferences_group_set_description(group, "WebHID access for the Keychron Launcher and VIA. Browser-based " ++
        "configurators cannot see the keyboard without these rules.");

    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Keychron Launcher support");
        var sub_buf: [512]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, keychronSetupSubtitle(&sub_buf));
        gtk.adw_action_row_set_icon_name(row, "input-keyboard-symbolic");
        const label: [:0]const u8 = if (keychronRulesCurrent())
            "Reinstall"
        else if (keychronRulesInstalled())
            "Update"
        else
            "Set up";
        const button = gtk.gtk_button_new_with_label(label);
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onKeychronSetupClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(button));
        gtk.adw_action_row_set_activatable_widget(row, @ptrCast(button));
        g_keychron_row = row;
        g_keychron_button = button;
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }

    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Open the Keychron Launcher");
        if (keychronBrowser()) |browser| {
            var buf: [256]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "Opens launcher.keychron.com in {s}.", .{browser.label}) catch
                "Opens launcher.keychron.com in a Chromium-based browser.";
            gtk.adw_action_row_set_subtitle(row, sub);
        } else {
            gtk.adw_action_row_set_subtitle(row, "Chromium isn't installed. Firefox cannot use WebHID, so this installs Chromium first.");
        }
        gtk.adw_action_row_set_icon_name(row, "web-browser-symbolic");
        const label: [:0]const u8 = if (keychronBrowser() != null) "Open" else "Install Chromium";
        const button = gtk.gtk_button_new_with_label(label);
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onKeychronOpenClicked), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(button));
        gtk.adw_action_row_set_activatable_widget(row, @ptrCast(button));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }

    return group;
}

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
    if (action.script) |script| {
        launchInTerminal(script);
        return;
    }
    launchArgv(action.argv);
}

fn onEasyEffectsInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchInTerminal(EASYEFFECTS_SCRIPT);
}

fn onRemoveNeovimClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchInTerminal(REMOVE_NEOVIM_SCRIPT);
}

var g_graphics_row: ?*gtk.AdwComboRow = null;
var g_video_row: ?*gtk.AdwComboRow = null;
var g_editor_row: ?*gtk.AdwComboRow = null;
var g_browser_row: ?*gtk.AdwComboRow = null;
var g_discord_row: ?*gtk.AdwComboRow = null;

fn onGraphicsInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_graphics_row.?);
    if (idx >= GRAPHICS_PACKAGES.len) return;
    var cmd_buf: [256]u8 = undefined;
    const install_cmd = buildSystemInstallCmd(&cmd_buf, GRAPHICS_PACKAGES[idx]);
    var buf: [400]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; echo; read -p 'Press Enter to close...'", .{install_cmd}) catch return;
    launchInTerminal(script);
}

fn onVideoPlayerInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_video_row.?);
    if (idx >= VIDEO_PLAYER_PACKAGES.len) return;
    var cmd_buf: [256]u8 = undefined;
    const install_cmd = buildSystemInstallCmd(&cmd_buf, VIDEO_PLAYER_PACKAGES[idx]);
    var buf: [400]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; echo; read -p 'Press Enter to close...'", .{install_cmd}) catch return;
    launchInTerminal(script);
}

fn onEditorInstallClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_editor_row.?);
    if (idx >= EDITOR_OPTIONS.len) return;
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, EDITOR_PACKAGES[idx], EDITOR_NEEDS_AUR[idx]);
    var buf: [400]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; echo; read -p 'Press Enter to close...'", .{install_cmd}) catch return;
    launchInTerminal(script);
}

fn onBrowserPinApplyClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_browser_row.?);
    if (idx >= PIN_BROWSER_INFO.len) return;
    const info = PIN_BROWSER_INFO[idx];
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, info.pkg, info.needs_aur);
    var buf: [500]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; mkdir -p \"$HOME/.config/simpbar\" && echo {s} > \"$HOME/.config/simpbar/browser-choice\"; echo; read -p 'Press Enter to close...'", .{ install_cmd, info.binary }) catch return;
    launchInTerminal(script);
}

fn onDiscordPinApplyClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(g_discord_row.?);
    if (idx >= PIN_DISCORD_INFO.len) return;
    const info = PIN_DISCORD_INFO[idx];
    var cmd_buf: [300]u8 = undefined;
    const install_cmd = buildInstallCmd(&cmd_buf, info.pkg, info.needs_aur);
    var buf: [500]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "{s}; mkdir -p \"$HOME/.config/simpbar\" && echo {s} > \"$HOME/.config/simpbar/discord-choice\"; echo; read -p 'Press Enter to close...'", .{ install_cmd, info.binary }) catch return;
    launchInTerminal(script);
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
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onSetupActionClicked), @ptrCast(@constCast(action)), null, 0);
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

    gtk.gtk_box_append(box, @ptrCast(buildKeychronGroup()));

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
        _ = gtk.g_signal_connect_data(@ptrCast(row), "activated", @ptrCast(&onAboutRowActivated), @ptrCast(@constCast(link.url)), null, 0);
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
var g_status_label: ?*gtk.GtkLabel = null;
var g_status_buf: [64]u8 = undefined;

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

/// One-line summary of the last update check, shown next to the spinner on
/// the Updates page ("N updates available" / "Everything is up to date.").
fn setStatusLabel(text: [:0]const u8) void {
    if (g_status_label) |label| gtk.gtk_label_set_text(label, text.ptr);
}

fn onCheckUpdatesClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    gtk.gtk_widget_set_sensitive(@ptrCast(g_check_button.?), 0);
    gtk.gtk_widget_set_sensitive(@ptrCast(g_apply_button.?), 0);
    gtk.gtk_spinner_start(g_spinner.?);
    setGroupMessage(&g_arch_rows, "Checking\u{2026}");
    setGroupMessage(&g_aur_rows, "Checking\u{2026}");
    setGroupMessage(&g_flatpak_rows, "Checking\u{2026}");
    setStatusLabel("Checking\u{2026}");

    const result = gpa.create(UpdateCheckResult) catch |err| {
        logging.err("update check: out of memory: {s}", .{@errorName(err)});
        return;
    };
    result.* = .{};
    const t = std.Thread.spawn(.{}, updateCheckThreadFn, .{result}) catch |err| {
        logging.err("update check: could not spawn thread: {s}", .{@errorName(err)});
        gpa.destroy(result);
        return;
    };
    t.detach();
    logging.step("update check dispatched", .{});
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

    var status: [:0]const u8 = "Everything is up to date.";
    if (total > 0) {
        status = std.fmt.bufPrintZ(&g_status_buf, "{d} update(s) available", .{total}) catch "Updates available";
    }
    setStatusLabel(status);

    gpa.destroy(result);
    return 0; // G_SOURCE_REMOVE
}

fn onApplyUpdatesClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    launchInTerminal(APPLY_ALL_UPDATES_SCRIPT);
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

    const status_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(status_label, 0);
    gtk.gtk_widget_set_valign(@ptrCast(status_label), gtk.ALIGN_CENTER);
    gtk.gtk_box_append(button_row, @ptrCast(status_label));
    g_status_label = status_label;
    setStatusLabel("Click \"Check for Updates\" above to scan.");

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
// Packages tab — GUI search over pacman (and the AUR via an installed
// helper). Installs/removals authorize through pkexec (a graphical
// password prompt, backed by the polkit agent the install ships) and
// stream pacman's progress in the user's terminal.
// ---------------------------------------------------------------------

const MAX_PKG_RESULTS = 100; // parsed search hits
const MAX_PKG_ROWS = 60; // rows shown before the "and N more" hint

/// One search hit: repository/name/version/description, all in fixed
/// buffers like UpdateEntry so the result crosses threads without any
/// heap life-time questions.
const PkgEntry = struct {
    name: [96]u8 = undefined,
    name_len: usize = 0,
    repo: [24]u8 = undefined,
    repo_len: usize = 0,
    ver: [32]u8 = undefined,
    ver_len: usize = 0,
    desc: [200]u8 = undefined,
    desc_len: usize = 0,
    installed: bool = false,
    installed_ver: [32]u8 = undefined,
    installed_ver_len: usize = 0,
    is_aur: bool = false,

    fn nameZ(self: *PkgEntry) [:0]const u8 {
        self.name[self.name_len] = 0;
        return self.name[0..self.name_len :0];
    }
    fn repoZ(self: *PkgEntry) [:0]const u8 {
        self.repo[self.repo_len] = 0;
        return self.repo[0..self.repo_len :0];
    }
    fn verZ(self: *PkgEntry) [:0]const u8 {
        self.ver[self.ver_len] = 0;
        return self.ver[0..self.ver_len :0];
    }
    fn installedVerZ(self: *PkgEntry) [:0]const u8 {
        self.installed_ver[self.installed_ver_len] = 0;
        return self.installed_ver[0..self.installed_ver_len :0];
    }
    fn descZ(self: *PkgEntry) [:0]const u8 {
        self.desc[self.desc_len] = 0;
        return self.desc[0..self.desc_len :0];
    }
};

const PkgSearchResult = struct {
    query: [64]u8 = undefined,
    query_len: usize = 0,
    entries: [MAX_PKG_RESULTS]PkgEntry = undefined,
    count: usize = 0,
    ok: bool = false,

    fn queryZ(self: *PkgSearchResult) [:0]const u8 {
        self.query[self.query_len] = 0;
        return self.query[0..self.query_len :0];
    }
};

/// A-Z a-z digits @ + . _ - : the arch package-name alphabet. Anything
/// wider gets rejected so helper output can never inject shell text into
/// the install/remove scripts built later.
fn isPkgNameByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '@' or c == '+' or c == '.' or
        c == '_' or c == '-';
}

/// Parses one header line of pacman -Ss / yay -Ss output into the next
/// free slot. Header shape: "repo/name version (…)[ [installed…]]", with
/// repo hits as "extra/foot 1.28.0-2" and AUR hits mostly the same
/// (yay prints "aur/foo 1.2-3 [votes] (Installed)"). Returns true (the
/// slot is now valid) or false — junk lines (:: banners, "( + votes)"
/// noise) all fail the split.
fn parsePkgSearchHeader(line: []const u8, list: *PkgSearchResult) bool {
    var toks = std.mem.tokenizeScalar(u8, line, ' ');
    const head = toks.next() orelse return false;
    const slash = std.mem.indexOfScalar(u8, head, '/') orelse return false;
    const repo = head[0..slash];
    const name = head[slash + 1 ..];
    const entry = &list.entries[list.count];
    entry.* = .{}; // clear the slot's (undefined) defaults before partial writes
    if (repo.len == 0 or repo.len >= entry.repo.len) return false;
    if (name.len == 0 or name.len >= entry.name.len) return false;
    for (repo) |c| if (!isPkgNameByte(c)) return false; // catches "::" banners
    for (name) |c| if (!isPkgNameByte(c)) return false; // shell-metachars can't reach the install scripts

    @memcpy(entry.repo[0..repo.len], repo);
    entry.repo_len = repo.len;
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    entry.is_aur = std.ascii.eqlIgnoreCase(repo, "aur");

    if (toks.next()) |ver| {
        if (ver.len > 0 and ver.len < entry.ver.len and ver[0] != '(' and ver[0] != '[') {
            @memcpy(entry.ver[0..ver.len], ver);
            entry.ver_len = ver.len;
        }
    }

    // Installed status. Repo format: " [installed: 1.2-3]". Helper format:
    // " [installed]" / "(Installed)" — yay capitalizes, so the marker scan
    // runs against a lowercase copy.
    var low_buf: [256]u8 = undefined;
    const low_n = @min(line.len, low_buf.len);
    const low = std.ascii.lowerString(low_buf[0..low_n], line[0..low_n]);
    const marker = std.mem.indexOf(u8, low, "[installed") orelse
        std.mem.indexOf(u8, low, "(installed");
    if (marker) |mk| {
        entry.installed = true;
        var n: usize = 0;
        var local_buf: [32]u8 = undefined;
        if (line[mk] == '[') {
            // "[installed: 1.2-3]" → the on-disk version is after the ':'
            // (pacman puts a space there).
            const after = line[mk..];
            const colon = std.mem.indexOfScalar(u8, after, ':') orelse 0;
            if (colon > 0) {
                var rest = after[colon + 1 ..];
                while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                for (rest) |c| {
                    if (c == ']' or c == ' ') break;
                    if (n >= local_buf.len) break;
                    local_buf[n] = c;
                    n += 1;
                }
            }
        }
        if (n == 0) {
            // No explicit local version — show the repo version.
            const v = entry.ver[0..entry.ver_len];
            if (v.len < local_buf.len) {
                @memcpy(local_buf[0..v.len], v);
                n = v.len;
            }
        }
        @memcpy(entry.installed_ver[0..n], local_buf[0..n]);
        entry.installed_ver_len = n;
    }
    return true;
}

/// Feeds one output line: indented lines are descriptions of the previous
/// hit, everything else is tried as a header.
fn addPkgSearchLine(raw_line: []const u8, list: *PkgSearchResult) void {
    const line = std.mem.trimEnd(u8, raw_line, " \t\r");
    if (line.len == 0) return;
    if (line[0] == ' ' or line[0] == '\t') {
        if (list.count == 0) return;
        const e = &list.entries[list.count - 1];
        if (e.desc_len != 0) return; // first description line only
        const d = std.mem.trim(u8, line, " \t");
        const n = @min(d.len, e.desc.len - 1);
        @memcpy(e.desc[0..n], d[0..n]);
        e.desc_len = n;
        return;
    }
    if (list.count >= MAX_PKG_RESULTS) return;
    if (parsePkgSearchHeader(line, list)) list.count += 1;
}

/// AUR helper for searches and aur installs, if one is installed.
fn pickedAurHelper() ?[:0]const u8 {
    if (commandExists("yay")) return "yay";
    if (commandExists("paru")) return "paru";
    if (commandExists("pikaur")) return "pikaur";
    return null;
}

fn pkgSearchThreadFn(result: *PkgSearchResult) void {
    logging.step("pkg search thread started (query {s})", .{result.queryZ()});
    const query_z = gpa.dupeZ(u8, result.queryZ()) catch {
        logging.warn("pkg search: out of memory", .{});
        gpa.destroy(result);
        return;
    };
    defer gpa.free(query_z);

    var argv: []const [:0]const u8 = undefined;
    var helper_used: bool = false;
    if (pickedAurHelper()) |helper| {
        argv = &[_][:0]const u8{ helper, "-Ss", "--color", "never", query_z };
        helper_used = true;
    } else {
        argv = &[_][:0]const u8{ "pacman", "-Ss", "--color", "never", query_z };
    }
    const output = runCaptured(argv, 90000) orelse {
        logging.warn("pkg search: {s} failed or timed out", .{if (helper_used) "helper -Ss" else "pacman -Ss"});
        _ = gtk.g_idle_add(&onPkgSearchIdle, result);
        return;
    };
    defer gpa.free(output);
    result.ok = true;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |l| addPkgSearchLine(l, result);
    logging.step("pkg search done: {d} hits", .{result.count});
    _ = gtk.g_idle_add(&onPkgSearchIdle, result);
}

const PkgRowAction = struct {
    op: enum { install, remove },
    is_aur: bool = false,
    name: [96]u8 = undefined,
    name_len: usize = 0,

    fn nameZ(self: *PkgRowAction) [:0]const u8 {
        self.name[self.name_len] = 0;
        return self.name[0..self.name_len :0];
    }
};

/// The touch-me button per result row (install when absent, remove when
/// on disk). Its row data dies with the button via the widget "destroy"
/// signal — a row can disappear either from a new search or from the
/// window closing, and the destroy signal covers both.
fn onPkgRowButtonClicked(_: *gtk.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const action: *PkgRowAction = @ptrCast(@alignCast(data orelse return));
    var cmd_buf: [400]u8 = undefined;
    var script_buf: [600]u8 = undefined;

    // Root authorization: pkexec against an absolute path (what pkexec
    // specifies) pops the polkit agent's graphical password prompt; sudo is
    // the fallback for setups stripped of polkit, where the terminal
    // wrapper below takes the password instead. Either way the pacman
    // progress bars stream into that terminal window.
    const root_pacman: []const u8 = if (commandExists("pkexec")) "pkexec /usr/bin/pacman" else "sudo pacman";
    const cmd = switch (action.op) {
        .install => blk: {
            if (action.is_aur) {
                // AUR helpers must run as the user — they build packages and
                // call sudo themselves for their pacman steps; raising them
                // wholesale would break makepkg.
                break :blk buildInstallCmd(&cmd_buf, action.nameZ(), true);
            }
            break :blk std.fmt.bufPrint(&cmd_buf, "{s} -S --noconfirm --needed {s}", .{ root_pacman, action.nameZ() }) catch return;
        },
        // AUR packages land in pacman's local db after install, so
        // "pacman -Rns" removes them regardless of where they came from.
        .remove => std.fmt.bufPrint(&cmd_buf, "{s} -Rns --noconfirm {s}", .{ root_pacman, action.nameZ() }) catch return,
    };
    const script = std.fmt.bufPrintZ(&script_buf, "{s}; echo; read -p 'Press Enter to close...'", .{cmd}) catch return;
    launchInTerminal(script);
}

fn onPkgRowButtonDestroyed(_: *gtk.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    gpa.destroy(@as(*PkgRowAction, @ptrCast(@alignCast(data orelse return))));
}

fn setPkgStatus(text: [:0]const u8) void {
    if (g_pkg_status) |label| gtk.gtk_label_set_text(label, text.ptr);
}

fn setPkgMessage(message: [:0]const u8) void {
    setGroupMessage(&g_pkg_rows, message);
}

fn onPkgSearchIdle(data: ?*anyopaque) callconv(.c) c_int {
    const result: *PkgSearchResult = @ptrCast(@alignCast(data orelse return 0));
    gtk.gtk_spinner_stop(g_pkg_spinner.?);
    g_pkg_busy = false;

    clearGroup(&g_pkg_rows);
    if (!result.ok) {
        setPkgMessage("Search failed \u{2014} could not run pacman.");
        setPkgStatus("Search failed");
        gpa.destroy(result);
        return 0;
    }
    if (result.count == 0) {
        var buf: [128]u8 = undefined;
        setPkgMessage(std.fmt.bufPrintZ(&buf, "No packages matched \"{s}\".", .{result.queryZ()}) catch "No packages matched.");
        setPkgStatus("No results");
        gpa.destroy(result);
        return 0;
    }

    const shown = @min(result.count, MAX_PKG_ROWS);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const e = &result.entries[i];
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), e.nameZ());

        var sub_buf: [420]u8 = undefined;
        var sub: []u8 = undefined;
        if (e.desc_len > 0) {
            sub = std.fmt.bufPrint(&sub_buf, "{s} \u{00b7} {s} \u{2014} {s}", .{ e.repoZ(), e.verZ(), e.desc[0..e.desc_len] }) catch
                std.fmt.bufPrint(&sub_buf, "{s} \u{00b7} {s}", .{ e.repoZ(), e.verZ() }) catch sub_buf[0..0];
        } else {
            sub = std.fmt.bufPrint(&sub_buf, "{s} \u{00b7} {s}", .{ e.repoZ(), e.verZ() }) catch sub_buf[0..0];
        }
        if (e.installed) {
            var tail: [64]u8 = undefined;
            const t = std.fmt.bufPrint(&tail, "\nInstalled ({s})", .{e.installedVerZ()}) catch "";
            if (t.len < sub_buf.len - sub.len) {
                @memcpy(sub[sub.len..][0..t.len], t);
                sub = sub[0 .. sub.len + t.len];
            }
        }
        var sub_z_buf: [512]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, std.fmt.bufPrintZ(&sub_z_buf, "{s}", .{sub}) catch "");

        const button = gtk.gtk_button_new_with_label(if (e.installed) "Remove" else "Install");
        gtk.gtk_widget_add_css_class(@ptrCast(button), "flat");
        if (e.installed) gtk.gtk_widget_add_css_class(@ptrCast(button), "destructive-action");
        gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
        const action = gpa.create(PkgRowAction) catch {
            logging.warn("pkg row: out of memory", .{});
            continue;
        };
        action.* = .{
            .op = if (e.installed) .remove else .install,
            .is_aur = e.is_aur,
            .name_len = e.name_len,
        };
        @memcpy(action.name[0..e.name_len], e.name[0..e.name_len]);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "clicked", @ptrCast(&onPkgRowButtonClicked), @ptrCast(action), null, 0);
        _ = gtk.g_signal_connect_data(@ptrCast(button), "destroy", @ptrCast(&onPkgRowButtonDestroyed), @ptrCast(action), null, 0);
        gtk.adw_action_row_add_suffix(@ptrCast(row), @ptrCast(button));
        gtk.adw_preferences_group_add(g_pkg_rows.group.?, @ptrCast(row));
        g_pkg_rows.rows[i] = row;
    }
    g_pkg_rows.count = shown;

    if (g_pkg_rows.group) |group| {
        var title_buf: [128]u8 = undefined;
        gtk.adw_preferences_group_set_title(group, std.fmt.bufPrintZ(&title_buf, "Results for \"{s}\"", .{result.queryZ()}) catch "Results");
    }

    var status_buf: [96]u8 = undefined;
    if (result.count > shown) {
        setPkgStatus(std.fmt.bufPrintZ(&status_buf, "First {d} of {d} \u{2014} refine your search to see more", .{ shown, result.count }) catch "");
    } else {
        setPkgStatus(std.fmt.bufPrintZ(&status_buf, "{d} result(s)", .{result.count}) catch "");
    }
    gpa.destroy(result);
    return 0; // G_SOURCE_REMOVE
}

var g_pkg_busy: bool = false;
var g_pkg_entry: ?*gtk.GtkSearchEntry = null;
var g_pkg_spinner: ?*gtk.GtkSpinner = null;
var g_pkg_status: ?*gtk.GtkLabel = null;
var g_pkg_rows: GroupRows = .{};

fn startPkgSearch() void {
    if (g_pkg_busy) return;
    const text = gtk.gtk_editable_get_text(@ptrCast(g_pkg_entry.?));
    const whole = std.mem.span(text);
    var query = std.mem.trim(u8, whole, " \t\r");
    while (query.len > 0 and query[0] == '-') {
        // Leading dashes would reenter pacman's option parsing — drop them.
        query = query[1..];
        while (query.len > 0 and query[0] == ' ') query = query[1..];
    }
    if (query.len == 0) {
        setPkgStatus("Type a package name first.");
        return;
    }

    const result = gpa.create(PkgSearchResult) catch |err| {
        logging.err("pkg search: out of memory: {s}", .{@errorName(err)});
        return;
    };
    result.* = .{};
    @memcpy(result.query[0..@min(query.len, result.query.len)], query[0..@min(query.len, result.query.len)]);
    result.query_len = @min(query.len, result.query.len);

    g_pkg_busy = true;
    gtk.gtk_spinner_start(g_pkg_spinner.?);
    setGroupTitle(&g_pkg_rows.group, "Searching\u{2026}");
    clearGroup(&g_pkg_rows);
    setPkgMessage("Searching\u{2026}");
    setPkgStatus("");

    const t = std.Thread.spawn(.{}, pkgSearchThreadFn, .{result}) catch |err| {
        logging.err("pkg search: could not spawn thread: {s}", .{@errorName(err)});
        g_pkg_busy = false;
        gtk.gtk_spinner_stop(g_pkg_spinner.?);
        gpa.destroy(result);
        return;
    };
    t.detach();
    logging.step("pkg search dispatched", .{});
}

fn onPkgSearchClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    startPkgSearch();
}

fn onPkgEntryActivate(_: *gtk.GtkSearchEntry, _: ?*anyopaque) callconv(.c) void {
    startPkgSearch();
}

/// Titles a preferences group (a tiny helper because the setter wants a
/// null-terminated string and the callers each juggle their own buffer).
fn setGroupTitle(gr: *?*gtk.AdwPreferencesGroup, title: [:0]const u8) void {
    if (gr.*) |g| gtk.adw_preferences_group_set_title(g, title);
}

fn buildPackagesPage() *gtk.GtkBox {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(box), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(box), 24);

    const helper = pickedAurHelper();
    var hint_buf: [256]u8 = undefined;
    const hint = if (helper) |h|
        std.fmt.bufPrintZ(&hint_buf, "Searches the official Arch repositories and the AUR (via {s}). Repo installs " ++
            "and removals authorize with a graphical pkexec prompt.", .{h}) catch "Searches the official Arch repositories and the AUR."
    else
        "Searches the official Arch repositories. Repo installs and removals " ++
            "authorize with a graphical pkexec prompt.";

    const search_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_widget_set_hexpand(@ptrCast(entry), 1);
    gtk.gtk_search_entry_set_placeholder_text(entry, "Search packages (e.g. firefox, foot)");
    _ = gtk.g_signal_connect_data(@ptrCast(entry), "activate", @ptrCast(&onPkgEntryActivate), null, null, 0);
    gtk.gtk_box_append(search_row, @ptrCast(entry));
    g_pkg_entry = entry;

    const spinner = gtk.gtk_spinner_new();
    gtk.gtk_box_append(search_row, @ptrCast(spinner));
    g_pkg_spinner = spinner;

    const search_button = gtk.gtk_button_new_with_label("Search");
    gtk.gtk_widget_add_css_class(@ptrCast(search_button), "suggested-action");
    _ = gtk.g_signal_connect_data(@ptrCast(search_button), "clicked", @ptrCast(&onPkgSearchClicked), null, null, 0);
    gtk.gtk_box_append(search_row, @ptrCast(search_button));

    const search_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(search_label, 0);
    gtk.gtk_widget_set_valign(@ptrCast(search_label), gtk.ALIGN_CENTER);
    gtk.gtk_box_append(search_row, @ptrCast(search_label));
    g_pkg_status = search_label;

    const search_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(search_group, "Search and install packages");
    gtk.adw_preferences_group_set_description(search_group, hint.ptr);
    gtk.adw_preferences_group_add(search_group, @ptrCast(search_row));
    gtk.gtk_box_append(box, @ptrCast(search_group));

    const results_group = gtk.adw_preferences_group_new();
    g_pkg_rows.group = results_group;
    gtk.gtk_box_append(box, @ptrCast(results_group));

    setGroupMessage(&g_pkg_rows, "Type a package name above and press Enter to search.");
    setPkgStatus("");

    return box;
}

test "pkg search parser: repo, installed, aur and desc lines" {
    const t = std.testing;
    var r: PkgSearchResult = .{};

    addPkgSearchLine("extra/foot 1.28.0-2", &r);
    addPkgSearchLine("    Fast, lightweight, and minimalistic Wayland terminal emulator", &r);
    addPkgSearchLine("", &r);
    addPkgSearchLine("extra/foot-terminfo 1.28.0-2 [installed]", &r);
    addPkgSearchLine("    Extra non-standard terminfo files", &r);
    addPkgSearchLine("aur/telegram-desktop 5.16.0-1 (+ 4 1.02) (Installed)", &r);
    addPkgSearchLine(":: Waiting for the AUR population to answer...", &r);
    try t.expectEqual(@as(usize, 3), r.count);

    const e0 = &r.entries[0];
    try t.expectEqualStrings("extra", e0.repoZ());
    try t.expectEqualStrings("foot", e0.nameZ());
    try t.expectEqualStrings("1.28.0-2", e0.verZ());
    try t.expect(!e0.installed);
    try t.expect(!e0.is_aur);
    try t.expect(std.mem.indexOf(u8, e0.desc[0..e0.desc_len], "Fast, lightweight") != null);

    const e1 = &r.entries[1];
    try t.expect(e1.installed);
    try t.expectEqualStrings("1.28.0-2", e1.installedVerZ());
    try t.expect(std.mem.indexOf(u8, e1.desc[0..e1.desc_len], "Extra non-standard terminfo files") != null);

    const e2 = &r.entries[2];
    try t.expect(e2.is_aur);
    try t.expect(e2.installed); // yay's (Installed) marker
    try t.expectEqualStrings("aur", e2.repoZ());
}

test "pkg search parser: installed-with-local-version form" {
    const t = std.testing;
    var r: PkgSearchResult = .{};
    addPkgSearchLine("extra/cava 0.10.5-1 [installed: 0.10.4-1]", &r);
    try t.expectEqual(@as(usize, 1), r.count);
    const e = &r.entries[0];
    try t.expect(e.installed);
    try t.expectEqualStrings("0.10.4-1", e.installedVerZ());
    try t.expectEqualStrings("0.10.5-1", e.verZ());
}

test "pkg search parser: rejects junk and malformed names" {
    const t = std.testing;
    var r: PkgSearchResult = .{};
    addPkgSearchLine(":: querying was not completed", &r);
    addPkgSearchLine("( + rejected newbie package (0) )", &r);
    addPkgSearchLine("extra/bad;name 1.0-1", &r); // shell-metachar name
    addPkgSearchLine("/nomissing 1.0-1", &r); // empty repo half
    addPkgSearchLine("justaword", &r); // no slash
    addPkgSearchLine("    stray description with no header above", &r);
    try t.expectEqual(@as(usize, 0), r.count);
}

test "terminal spec parsing" {
    const t = std.testing;

    // Bare binary: command passed without a flag (kitty / xdg-terminal-exec
    // style). "sh" exists on every Linux, so this can't be env-flaky.
    try t.expect(applyTermSpec("sh"));
    try t.expectEqualStrings("sh", g_term_bin);
    try t.expect(g_term_flag == null);

    // Binary + exec flag.
    try t.expect(applyTermSpec("sh -e"));
    try t.expectEqualStrings("sh", g_term_bin);
    try t.expectEqualStrings("-e", g_term_flag.?);

    // Everything that must fall through instead of resolving.
    try t.expect(!applyTermSpec("definitely-not-a-terminal-xyz -e")); // missing binary
    try t.expect(!applyTermSpec("sh -e one extra")); // >2 tokens not understood
    try t.expect(!applyTermSpec(""));
    try t.expect(!applyTermSpec("# comment line"));

    // The install.sh shape for a real pick.
    try t.expect(applyTermSpec("alacritty -e"));
    try t.expectEqualStrings("alacritty", g_term_bin);
    try t.expectEqualStrings("-e", g_term_flag.?);
}

// ---------------------------------------------------------------------
// Window / application
// ---------------------------------------------------------------------

const PAGE_NAMES = [_][:0]const u8{ "Welcome", "Setup", "Updates", "Packages", "Keybindings", "About" };
const PAGE_ICONS = [_][:0]const u8{ "go-home-symbolic", "emblem-system-symbolic", "software-update-available-symbolic", "system-software-install-symbolic", "input-keyboard-symbolic", "help-about-symbolic" };

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
        buildPackagesPage(),
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
    logging.step("window shown", .{});
}

pub fn main() void {
    logging.init("simpbar");
    realMain() catch |err| {
        logging.err("fatal: {s}", .{@errorName(err)});
        logging.crash("fatal error: {s}", .{@errorName(err)});
        logging.dumpCurrentStack();
        std.process.exit(1);
    };
}

fn realMain() !void {
    logging.step("starting up", .{});
    resolvePaths();
    g_autostart_mode = detectAutostartMode();
    logging.step("autostart mode: {s}", .{if (g_autostart_mode) "enabled" else "manual"});

    const app = gtk.adw_application_new(APP_ID, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&onAppActivate), null, null, 0);
    const code = gtk.g_application_run(@ptrCast(app), 0, null);
    logging.step("gtk main loop exited with code {d}", .{code});
    exit(code);
}

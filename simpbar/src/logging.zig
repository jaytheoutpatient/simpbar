//! File-based logging shared by all three simpbar binaries (the bar,
//! simpbar-welcome, simpbar-config).
//!
//! Every category is written to its own file under
//! `$HOME/.config/simpbar-config/logs/<binary>/`, one line per event, so
//! chasing a bug means opening just the stream that matches it:
//!
//!   trace.log    every step / lifecycle event ("track every step" log)
//!   warning.log  recoverable problems that don't stop the program
//!   error.log    failures that make a specific operation fail
//!   crash.log    panics, fatal signals, and top-level errors that kill the process
//!
//! Everything is also mirrored to stderr so terminal-only runs keep behaving
//! like the old `std.debug.print` calls they replaced. Writes are synchronous
//! and guarded by a spinlock, so they are safe to call from any thread (the
//! GTK apps' worker thread included) and survive noreturn exits
//! (`exit()`, `std.process.exit()`) without a flush step. Files are rotated
//! automatically once they exceed `MAX_LOG_SIZE`; the oversized file is
//! renamed to `<file>.old` (one generation kept) and then recreated.
//!
//! Crash coverage has three legs, so all three ways a process can die end up
//! in crash.log:
//!
//!   * Zig panics — each root source file declares `pub const panic =
//!     std.debug.FullPanic(logging.panicHandler)`, which writes a message +
//!     error-return context + full symbolized stack trace to crash.log before
//!     falling through to the stock `defaultPanic` (stderr + abort).
//!   * Fatal signals (SIGSEGV/SIGABRT/SIGILL/SIGFPE/SIGBUS/SIGTRAP) — a tiny
//!     async-signal-safe handler records the signal + faulting address in
//!     crash.log, restores the default disposition, then re-raises so the
//!     kernel still produces the usual core dump for a debugger.
//!   * Errors returned from `main()` — the root wrappers log the error name
//!     (plus a stack trace) to crash.log before exiting non-zero.
//!
//! The module deliberately talks to libc through hand-declared externs for the
//! few syscalls it needs (open/write/close/lseek/mkdir/rename/getpid/time/
//! localtime_r), mirroring the established style in welcome_main.zig and
//! config_main.zig, rather than depending on Zig's churning std.{fs,posix}
//! wrapper layer. Logging failures degrade silently: if the log directory
//! can't be created the module simply no-ops (still mirroring to stderr) and
//! never takes the program down with it.

const std = @import("std");
const posix = std.posix;

pub const Level = enum(u8) {
    trace,
    warning,
    err,
    crash,

    fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .warning => "WARN",
            .err => "ERROR",
            .crash => "CRASH",
        };
    }
};

const LOG_DIR_REL = "/.config/simpbar-config/logs";

const TRACE_FILE = "trace.log";
const WARNING_FILE = "warning.log";
const ERROR_FILE = "error.log";
const CRASH_FILE = "crash.log";

/// Files are rotated (renamed to `<file>.old`) once they reach this size.
const MAX_LOG_SIZE: i64 = 2 * 1024 * 1024;

// --- libc externs (mirrors the hand-declared style used elsewhere) -------

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbytes: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;

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

// O_* constants for the libc `open` extern above (Linux x86_64 values).
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
/// Same numeric value as every other *_CLOEXEC flag on Linux (the codebase's
/// main.zig makes the same point); keeps the crash fd out of forked children.
const O_CLOEXEC: c_int = 0o2000000;
const SEEK_END: c_int = 2;

// --- global state -------------------------------------------------------

var g_log_dir_buf: [600]u8 = undefined;
var g_log_dir: [:0]const u8 = "";
var g_proc_tag: []const u8 = "simpbar";
var g_pid: c_int = 0;
var g_ready = false;

/// crash.log stays open for the whole process so the async-signal-safe crash
/// handler has a ready fd to write to without calling into open().
var g_crash_fd: c_int = -1;

/// Claims the crash log so only the first crashing thread writes the record;
/// everyone else goes straight to the stock panic handler.
var g_crash_claimed = std.atomic.Value(bool).init(false);

/// Minimal spinlock — std.Thread.Mutex was removed from the 0.16 stdlib and
/// std.Io.Mutex requires an Io instance (overkill for a log guard); the two
/// competing writers are just log lines, so a tiny atomic lock is enough.
const Spinlock = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

var g_lock: Spinlock = .{};

// --- public API ----------------------------------------------------------

/// Initializes logging for `proc_name` (one of "simpbar", "simpbar-welcome",
/// "simpbar-config") and creates `$HOME/.config/simpbar-config/logs/<proc>/`.
/// Best-effort: any failure quietly disables file logging.
pub fn init(proc_name: []const u8) void {
    g_proc_tag = proc_name;
    g_pid = getpid();

    const home = std.mem.sliceTo(getenv("HOME") orelse "/root", 0);

    // Build each parent dir on its own stack buffer (g_log_dir is reserved for
    // the final per-proc dir, which every later log line depends on) and mkdir
    // immediately — failures are ignored because parents usually pre-exist.
    var parent_buf: [600]u8 = undefined;
    const d0 = std.fmt.bufPrintZ(&parent_buf, "{s}/.config", .{home}) catch null;
    if (d0) |d| _ = mkdir(d.ptr, 0o755);
    const d1 = std.fmt.bufPrintZ(&parent_buf, "{s}/.config/simpbar-config", .{home}) catch null;
    if (d1) |d| _ = mkdir(d.ptr, 0o755);
    const logs_dir = std.fmt.bufPrintZ(&parent_buf, "{s}{s}", .{ home, LOG_DIR_REL }) catch null;
    if (logs_dir) |d| _ = mkdir(d.ptr, 0o755);

    const dir = std.fmt.bufPrintZ(&g_log_dir_buf, "{s}{s}/{s}", .{ home, LOG_DIR_REL, proc_name }) catch return;
    g_log_dir = dir;
    _ = mkdir(dir.ptr, 0o755);

    // crash.log is the one file that must sit on a live fd; rotate it if it
    // outgrew its cap in a previous run, then open it for the whole process.
    var crash_buf: [600 + 16]u8 = undefined;
    const crash_path = std.fmt.bufPrintZ(&crash_buf, "{s}/{s}", .{ dir, CRASH_FILE }) catch return;
    if (logTooBig(crash_path.ptr)) rotateLogFile(crash_path.ptr);
    g_crash_fd = open(crash_path.ptr, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644);

    g_ready = true;
    step("logging online ({s})", .{dir});
    installSignalHandlers();
}

/// Closes the crash fd. Only ever reached on orderly (non-noreturn) exits;
/// `exit()`/`std.process.exit()` paths skip this and rely on the OS.
pub fn deinit() void {
    if (g_crash_fd >= 0) _ = close(g_crash_fd);
    g_crash_fd = -1;
    g_ready = false;
}

/// Every-step log: lifecycle transitions, module fetches, reloads, ... the
/// dominate-the-trace stream for "what did the program just do".
pub fn step(comptime fmt: []const u8, args: anytype) void {
    emit(.trace, fmt, args);
}

/// Recoverable problem: a fallback was used, a fetch failed and will retry,
/// a value was outside expectations, ...
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warning, fmt, args);
}

/// A failure that made a specific operation fail (a file wasn't written, a
/// draw/refresh failed, a D-Bus call errored).
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}

/// A fatal problem: logs to crash.log (and stderr) without showing a stack
/// trace for the current frame. Used for top-level `main()` errors which call
/// `logTopLevelCrash`/`dumpCurrentStack` next.
pub fn crash(comptime fmt: []const u8, args: anytype) void {
    emit(.crash, fmt, args);
}

/// Where every root's `pub const panic = std.debug.FullPanic(logging.panicHandler);`
/// points. Writes a full record to crash.log (message, error-return context,
/// symbolized stack trace) then falls through to the stock handler which
/// mirrors it to stderr and aborts.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (!g_crash_claimed.swap(true, .seq_cst)) {
        var buf: [65536]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        {
            var ts_buf: [32]u8 = undefined;
            const ts = formatTimestamp(&ts_buf);
            w.print("{s} [pid {d}] [{s}] [CRASH] panic: {s}\n", .{ ts, g_pid, g_proc_tag, msg }) catch {};
        }
        if (@errorReturnTrace()) |et| if (et.index > 0) {
            w.print("error return context:\n", .{}) catch {};
            const term = std.Io.Terminal{ .writer = &w, .mode = .no_color };
            std.debug.writeErrorReturnTrace(et, term) catch {};
        };
        w.print("stack trace:\n", .{}) catch {};
        {
            const term = std.Io.Terminal{ .writer = &w, .mode = .no_color };
            std.debug.writeCurrentStackTrace(.{
                .first_address = first_trace_addr orelse @returnAddress(),
                .allow_unsafe_unwind = true, // we're crashing anyway; give it our all
            }, term) catch {};
        }
        const fd = if (g_crash_fd >= 0) g_crash_fd else 2;
        _ = writeAll(fd, w.buffered());
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Dumps the current stack trace (from the caller's frame) into crash.log.
/// Used after logging a top-level fatal error from `main()`, where Zig's
/// stock panic machinery isn't involved.
pub fn dumpCurrentStack() void {
    if (g_crash_claimed.swap(true, .seq_cst)) return;
    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    {
        const term = std.Io.Terminal{ .writer = &w, .mode = .no_color };
        std.debug.writeCurrentStackTrace(.{
            .first_address = @returnAddress(),
            .allow_unsafe_unwind = true,
        }, term) catch {};
    }
    const fd = if (g_crash_fd >= 0) g_crash_fd else 2;
    _ = writeAll(fd, w.buffered());
}

// --- internals -----------------------------------------------------------

fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!g_ready) {
        // Not initialized (or init failed): still mirror to stderr so the
        // old terminal behavior is preserved even for startup messages.
        std.debug.print(fmt ++ "\n", args);
        return;
    }

    var body_buf: [8192]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, fmt, args) catch "(log message too long)";

    // <timestamp> [pid <pid>] [<proc>] [<LEVEL>] <body>\n
    var ts_buf: [32]u8 = undefined;
    const ts = formatTimestamp(&ts_buf);
    var line_buf: [64 + 8192]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s} [pid {d}] [{s}] [{s}] {s}\n", .{
        ts, g_pid, g_proc_tag, level.name(), body,
    }) catch blk: {
        const bare = std.fmt.bufPrint(&line_buf, "[pid {d}] [{s}] [{s}] {s}\n", .{
            g_pid, g_proc_tag, level.name(), body,
        }) catch {
            const short: []const u8 = level.name();
            const n = @min(short.len, line_buf.len);
            @memcpy(line_buf[0..n], short[0..n]);
            break :blk line_buf[0..n];
        };
        break :blk bare;
    };

    // Mirror to stderr, exactly like the std.debug.print calls this replaced.
    _ = writeAll(2, line);

    g_lock.lock();
    defer g_lock.unlock();
    switch (level) {
        .trace => appendRotated(TRACE_FILE, line),
        .warning => appendRotated(WARNING_FILE, line),
        .err => appendRotated(ERROR_FILE, line),
        .crash => appendCrashRaw(line),
    }
}

/// Appends a line to `<logdir>/<base>`, rotating to `<base>.old` first if the
/// current file has outgrown MAX_LOG_SIZE.
fn appendRotated(comptime base: []const u8, line: []const u8) void {
    var full_buf: [600 + 16]u8 = undefined;
    const full = std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ g_log_dir, base }) catch return;
    if (logTooBig(full.ptr)) rotateLogFile(full.ptr);
    const fd = open(full.ptr, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644);
    if (fd < 0) return;
    defer _ = close(fd);
    _ = writeAll(fd, line);
}

/// Appends a line to the live crash.log fd (never rotates mid-run — the fd
/// must keep pointing at the same inode for the async signal handler).
fn appendCrashRaw(line: []const u8) void {
    const fd = if (g_crash_fd >= 0) g_crash_fd else 2;
    _ = writeAll(fd, line);
}

fn rotateLogFile(path: [*:0]const u8) void {
    var old_buf: [600 + 16 + 8]u8 = undefined;
    const old = std.fmt.bufPrintZ(&old_buf, "{s}.old", .{path}) catch return;
    // rename() atomically replaces any previous .old generation.
    _ = rename(path, old.ptr);
}

fn logTooBig(path: [*:0]const u8) bool {
    const fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    return lseek(fd, 0, SEEK_END) >= MAX_LOG_SIZE;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn formatTimestamp(buf: []u8) []const u8 {
    const now = time(null);
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) {
        return std.fmt.bufPrint(buf, "{d}", .{now}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)),
        @as(u32, @intCast(tm.mon + 1)),
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
        @as(u32, @intCast(tm.sec)),
    }) catch "";
}

// --- signal handlers -----------------------------------------------------

fn installSignalHandlers() void {
    const signals = [_]posix.SIG{ .SEGV, .ABRT, .ILL, .FPE, .BUS, .TRAP };
    for (signals) |s| {
        const act = posix.Sigaction{
            .handler = .{ .sigaction = crashSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(s, &act, null);
    }
}

fn sigName(sig: posix.SIG) []const u8 {
    return switch (sig) {
        .SEGV => "SIGSEGV",
        .ABRT => "SIGABRT",
        .ILL => "SIGILL",
        .FPE => "SIGFPE",
        .BUS => "SIGBUS",
        .TRAP => "SIGTRAP",
        else => "SIGNAL",
    };
}

/// Async-signal-safe: no locking, no allocation, no libc calls beyond
/// write/time/getpid (all on the POSIX async-signal-safe list). Writes a
/// compact record to crash.log, restores the default handler, then re-raises
/// so the process dies with the usual core dump.
fn crashSignalHandler(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    var addr: usize = 0;
    switch (sig) {
        .SEGV, .BUS, .ILL, .FPE, .TRAP => addr = @intFromPtr(info.fields.sigfault.addr),
        else => {},
    }

    var buf: [256]u8 = undefined;
    const record = std.fmt.bufPrint(&buf, "\n===== CRASH =====\nunix {d} pid {d} [{s}] [{s}] faulting address 0x{x}\n", .{
        time(null), getpid(), g_proc_tag, sigName(sig), addr,
    }) catch return;
    const fd = if (g_crash_fd >= 0) g_crash_fd else 2;
    _ = writeAll(fd, record);

    // Default disposition + re-raise: kernel produces the real signal + core.
    const dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &dfl, null);
    _ = posix.raise(sig) catch {};
    // Only reachable if the signal was blocked; fall back to exiting hard.
    _ = std.c._exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}
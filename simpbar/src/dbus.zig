//! A minimal D-Bus client AND server, just enough to implement the
//! org.kde.StatusNotifierWatcher role (something has to host it — nothing
//! else on this system currently does) plus talk to registered
//! org.kde.StatusNotifierItem tray icons.
//!
//! There's no D-Bus library available for Zig here, so this hand-rolls the
//! wire protocol: the SASL auth handshake, then binary message
//! marshaling/unmarshaling per the D-Bus spec's alignment rules. It only
//! implements the handful of message shapes the tray actually needs —
//! not a general-purpose D-Bus library.

const std = @import("std");
const posix = std.posix;

// --- connecting -------------------------------------------------------

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const libc_sock = struct {
    extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
    extern "c" fn connect(sockfd: c_int, addr: *const anyopaque, addrlen: c_uint) c_int;
};

fn connectUnixSocket(path: []const u8) !posix.fd_t {
    // CLOEXEC matters here specifically: this connection lives for the
    // whole program, and without it every subprocess we fork (launcher
    // clicks, weather/pacman/mpris fetches) inherits a duplicate — if any
    // of those outlive us (a spawned terminal, browser, ...), the bus
    // daemon still sees this connection as alive and keeps the
    // StatusNotifierWatcher name held against a process that's long gone.
    const raw_fd = libc_sock.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (raw_fd < 0) return error.SocketCreateFailed;
    const fd: posix.fd_t = @intCast(raw_fd);
    errdefer _ = posix.system.close(fd);

    var addr: std.os.linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    if (libc_sock.connect(fd, &addr, @sizeOf(std.os.linux.sockaddr.un)) != 0) {
        return error.ConnectFailed;
    }
    return fd;
}

/// Parses "unix:path=/run/user/1000/bus" (the common case) out of
/// $DBUS_SESSION_BUS_ADDRESS. Doesn't handle "unix:abstract=" (abstract
/// sockets) or any of the other transports D-Bus supports — those aren't
/// what a normal Linux desktop session sets.
fn sessionBusSocketPath(buf: []u8) ![]const u8 {
    const addr = std.mem.sliceTo(getenv("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus, 0);
    const needle = "unix:path=";
    const idx = std.mem.indexOf(u8, addr, needle) orelse return error.UnsupportedTransport;
    var path: []const u8 = addr[idx + needle.len ..];
    if (std.mem.indexOfScalar(u8, path, ',')) |comma| path = path[0..comma];
    if (path.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(fd, buf[got..]);
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
}

// --- connection ---------------------------------------------------------

pub const Connection = struct {
    fd: posix.fd_t,
    serial: u32 = 1,

    /// Connects to the session bus, does the SASL EXTERNAL auth handshake,
    /// and calls the mandatory initial Hello().
    pub fn connect() !Connection {
        var path_buf: [108]u8 = undefined;
        const path = try sessionBusSocketPath(&path_buf);
        const fd = try connectUnixSocket(path);
        errdefer _ = posix.system.close(fd);

        // SASL: a leading NUL, then AUTH EXTERNAL with our uid hex-encoded
        // as ASCII decimal digits (that's the "EXTERNAL" mechanism's
        // identity — the bus already knows our uid from SO_PEERCRED, this
        // just has to be present and well-formed).
        try writeAll(fd, &[_]u8{0});
        var uid_buf: [32]u8 = undefined;
        const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{std.os.linux.getuid()}) catch return error.AuthFailed;
        var hex_buf: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (uid_str, 0..) |byte, i| {
            hex_buf[i * 2] = hex_chars[byte >> 4];
            hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
        }
        const hex = hex_buf[0 .. uid_str.len * 2];
        var auth_line_buf: [128]u8 = undefined;
        const auth_line = std.fmt.bufPrint(&auth_line_buf, "AUTH EXTERNAL {s}\r\n", .{hex}) catch return error.AuthFailed;
        try writeAll(fd, auth_line);

        var reply_buf: [512]u8 = undefined;
        const n = try posix.read(fd, &reply_buf);
        if (n < 2 or !std.mem.eql(u8, reply_buf[0..2], "OK")) return error.AuthFailed;

        try writeAll(fd, "BEGIN\r\n");

        var self = Connection{ .fd = fd };
        _ = try self.call(.{
            .destination = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
        }, .{});
        return self;
    }

    pub fn close(self: *Connection) void {
        _ = posix.system.close(self.fd);
    }

    fn nextSerial(self: *Connection) u32 {
        const s = self.serial;
        self.serial += 1;
        return s;
    }

    pub const CallTarget = struct {
        destination: ?[]const u8 = null,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
    };

    /// Sends a method call and blocks (this connection is only ever used
    /// from the main loop right after poll() says it's readable, and local
    /// D-Bus peers write complete messages in one go, so a short blocking
    /// wait here is simpler than a fully async request/reply matcher) until
    /// the matching reply arrives. Returns the reply body — ERROR replies
    /// surface as `error.DbusError`, with the raw message still parseable
    /// by the caller if it wants the error name/text (not currently used).
    pub fn call(self: *Connection, target: CallTarget, body: Body) !Message {
        const serial = self.nextSerial();
        const raw = try buildMessage(std.heap.page_allocator, .method_call, serial, .{
            .path = target.path,
            .interface = target.interface,
            .member = target.member,
            .destination = target.destination,
            .signature = if (body.signature.len > 0) body.signature else null,
        }, body.bytes);
        defer std.heap.page_allocator.free(raw);
        try writeAll(self.fd, raw);

        while (true) {
            const msg = try self.readMessage(std.heap.page_allocator);
            if (msg.reply_serial == serial) {
                if (msg.msg_type == .error_reply) return error.DbusError;
                return msg;
            }
            // Not our reply (some unrelated signal/call arrived first) —
            // free it and keep waiting. Losing track of it is fine: the
            // main loop's normal incoming-message handling only look at
            // messages it reads itself, and this blocking wait is only
            // ever used for our own outgoing calls during setup/polling,
            // not general dispatch.
            msg.deinit();
        }
    }

    /// Sends a message with no reply expected (a METHOD_RETURN we're
    /// generating ourselves, or a fire-and-forget call like Activate).
    pub fn send(self: *Connection, msg_type: MessageType, fields: HeaderFields, body: Body) !void {
        const serial = self.nextSerial();
        var f = fields;
        if (body.signature.len > 0) f.signature = body.signature;
        const raw = try buildMessage(std.heap.page_allocator, msg_type, serial, f, body.bytes);
        defer std.heap.page_allocator.free(raw);
        try writeAll(self.fd, raw);
    }

    /// Blocks until one full message has been read off the wire.
    pub fn readMessage(self: *Connection, gpa: std.mem.Allocator) !Message {
        var fixed: [16]u8 = undefined;
        try readAll(self.fd, &fixed);
        if (fixed[0] != 'l') return error.UnsupportedEndian; // we only speak little-endian
        const msg_type: MessageType = @enumFromInt(fixed[1]);
        const body_len = std.mem.readInt(u32, fixed[4..8], .little);
        const fields_len = std.mem.readInt(u32, fixed[12..16], .little);

        const header_rest_len = alignUp(fields_len, 8);
        const header_rest = try gpa.alloc(u8, header_rest_len);
        defer gpa.free(header_rest);
        try readAll(self.fd, header_rest[0..fields_len]);
        // The alignment padding between the fields array and the body
        // isn't part of fields_len — read it too so the socket stays in sync.
        if (header_rest_len > fields_len) try readAll(self.fd, header_rest[fields_len..header_rest_len]);

        const body = try gpa.alloc(u8, body_len);
        errdefer gpa.free(body);
        try readAll(self.fd, body);

        // Parse into a persisted copy, not `header_rest` — that gets freed
        // when this function returns, and the parsed string fields below
        // are slices into whatever buffer we parse, not copies.
        const header_buf = try gpa.dupe(u8, header_rest[0..fields_len]);
        errdefer gpa.free(header_buf);

        var parsed = ParsedFields{};
        var r = Reader{ .bytes = header_buf };
        while (r.pos < r.bytes.len) {
            r.alignTo(8) catch break;
            if (r.pos >= r.bytes.len) break;
            const code = try r.readU8();
            const sig = try r.readSignature();
            if (sig.len == 0) continue;
            switch (sig[0]) {
                's', 'o' => {
                    const s = try r.readStringLike();
                    switch (code) {
                        1 => parsed.path = s,
                        2 => parsed.interface = s,
                        3 => parsed.member = s,
                        4 => parsed.error_name = s,
                        6 => parsed.destination = s,
                        7 => parsed.sender = s,
                        else => {},
                    }
                },
                'g' => {
                    const s = try r.readSignature();
                    if (code == 8) parsed.signature = s;
                },
                'u' => {
                    const v = try r.readU32();
                    if (code == 5) parsed.reply_serial = v;
                },
                else => {},
            }
        }

        return Message{
            .gpa = gpa,
            .header_buf = header_buf,
            .body = body,
            .msg_type = msg_type,
            .serial = std.mem.readInt(u32, fixed[8..12], .little),
            .path = parsed.path,
            .interface = parsed.interface,
            .member = parsed.member,
            .error_name = parsed.error_name,
            .destination = parsed.destination,
            .sender = parsed.sender,
            .signature = parsed.signature,
            .reply_serial = parsed.reply_serial,
        };
    }
};

const ParsedFields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    reply_serial: ?u32 = null,
};

pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

/// A fully-read, parsed incoming message. String fields point into
/// `header_buf`/`body`, which this struct owns — call `deinit`.
pub const Message = struct {
    gpa: std.mem.Allocator,
    header_buf: []u8,
    body: []u8,
    msg_type: MessageType,
    serial: u32,
    path: ?[]const u8,
    interface: ?[]const u8,
    member: ?[]const u8,
    error_name: ?[]const u8,
    destination: ?[]const u8,
    sender: ?[]const u8,
    signature: ?[]const u8,
    reply_serial: ?u32,

    pub fn deinit(self: Message) void {
        self.gpa.free(self.header_buf);
        self.gpa.free(self.body);
    }

    pub fn bodyReader(self: *const Message) Reader {
        return Reader{ .bytes = self.body };
    }
};

pub const HeaderFields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

pub const Body = struct {
    bytes: []const u8 = &.{},
    signature: []const u8 = "",
};

fn alignUp(n: u32, a: u32) u32 {
    return (n + a - 1) / a * a;
}

// --- marshaling -----------------------------------------------------------

pub fn alignTo(list: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    while (list.items.len % n != 0) try list.append(gpa, 0);
}

pub fn appendU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    try alignTo(list, gpa, 4);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(gpa, &buf);
}

pub fn appendI32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i32) !void {
    try appendU32(list, gpa, @bitCast(v));
}

pub fn appendStringLike(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try appendU32(list, gpa, @intCast(s.len));
    try list.appendSlice(gpa, s);
    try list.append(gpa, 0);
}

pub fn appendSignature(list: *std.ArrayList(u8), gpa: std.mem.Allocator, sig: []const u8) !void {
    try list.append(gpa, @intCast(sig.len));
    try list.appendSlice(gpa, sig);
    try list.append(gpa, 0);
}

fn appendHeaderFieldString(list: *std.ArrayList(u8), gpa: std.mem.Allocator, code: u8, sig_char: u8, value: []const u8) !void {
    try alignTo(list, gpa, 8);
    try list.append(gpa, code);
    try appendSignature(list, gpa, &[_]u8{sig_char});
    // A SIGNATURE-typed value (the SIGNATURE header field itself, sig_char
    // 'g') is wire-encoded the same way as a signature — 1-byte length
    // prefix — not as a STRING/OBJECT_PATH's 4-byte length prefix.
    if (sig_char == 'g') {
        try appendSignature(list, gpa, value);
    } else {
        try appendStringLike(list, gpa, value);
    }
}

fn appendHeaderFieldU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, code: u8, value: u32) !void {
    try alignTo(list, gpa, 8);
    try list.append(gpa, code);
    try appendSignature(list, gpa, "u");
    try appendU32(list, gpa, value);
}

fn buildMessage(gpa: std.mem.Allocator, msg_type: MessageType, serial: u32, fields: HeaderFields, body: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    try list.append(gpa, 'l');
    try list.append(gpa, @intFromEnum(msg_type));
    try list.append(gpa, 0); // flags
    try list.append(gpa, 1); // protocol version
    try appendU32(&list, gpa, @intCast(body.len));
    try appendU32(&list, gpa, serial);

    try appendU32(&list, gpa, 0); // header fields array length, patched below
    const len_offset = list.items.len - 4;
    try alignTo(&list, gpa, 8);
    const fields_start = list.items.len;

    if (fields.path) |v| try appendHeaderFieldString(&list, gpa, 1, 'o', v);
    if (fields.interface) |v| try appendHeaderFieldString(&list, gpa, 2, 's', v);
    if (fields.member) |v| try appendHeaderFieldString(&list, gpa, 3, 's', v);
    if (fields.error_name) |v| try appendHeaderFieldString(&list, gpa, 4, 's', v);
    if (fields.reply_serial) |v| try appendHeaderFieldU32(&list, gpa, 5, v);
    if (fields.destination) |v| try appendHeaderFieldString(&list, gpa, 6, 's', v);
    if (fields.signature) |v| try appendHeaderFieldString(&list, gpa, 8, 'g', v);

    const fields_len: u32 = @intCast(list.items.len - fields_start);
    std.mem.writeInt(u32, list.items[len_offset..][0..4], fields_len, .little);

    try alignTo(&list, gpa, 8); // header/body boundary
    try list.appendSlice(gpa, body);

    return list.toOwnedSlice(gpa);
}

// --- unmarshaling -----------------------------------------------------------

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn alignTo(self: *Reader, n: usize) !void {
        const aligned = alignUp(@intCast(self.pos), @intCast(n));
        if (aligned > self.bytes.len) return error.Truncated;
        self.pos = aligned;
    }

    pub fn readU8(self: *Reader) !u8 {
        if (self.pos + 1 > self.bytes.len) return error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    pub fn readU32(self: *Reader) !u32 {
        try self.alignTo(4);
        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
    }

    pub fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }

    /// STRING/OBJECT_PATH wire format: u32 length, bytes, trailing NUL.
    pub fn readStringLike(self: *Reader) ![]const u8 {
        const len = try self.readU32();
        if (self.pos + len + 1 > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos..][0..len];
        self.pos += len + 1; // + NUL
        return s;
    }

    /// SIGNATURE wire format: u8 length, bytes, trailing NUL (no 4-byte
    /// alignment — signatures are always 1-aligned).
    pub fn readSignature(self: *Reader) ![]const u8 {
        const len = try self.readU8();
        if (self.pos + len + 1 > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos..][0..len];
        self.pos += len + 1;
        return s;
    }
};

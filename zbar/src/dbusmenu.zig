//! A minimal com.canonical.dbusmenu client — the protocol StatusNotifierItem
//! delegates to for right-click menus when the item itself has no
//! Activate/ContextMenu methods (Steam, Spotify: both Ayatana-style
//! indicators that only expose a "Menu" property pointing at one of these
//! objects). The tray host is expected to fetch the menu structure itself
//! and render it — there's no "just call ContextMenu and the app pops up
//! its own window" shortcut for these.
//!
//! GetLayout's reply is a recursive structure — "u(ia{sv}av)": revision,
//! then a tree of (id, properties-dict, children) nodes where each child is
//! itself one of these nodes wrapped in a variant. This is a step up in
//! parsing complexity from anything else built so far (everything else
//! this session has been flat/fixed-shape messages).

const std = @import("std");
const dbus = @import("dbus.zig");

pub const MAX_MENU_ITEMS = 64;

pub const MenuItem = struct {
    id: i32 = 0,
    /// Index into DbusMenu.items, or -1 for a top-level item.
    parent_index: i32 = -1,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    enabled: bool = true,
    visible: bool = true,
    is_separator: bool = false,
    has_children: bool = false,

    pub fn label(self: *const MenuItem) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const DbusMenu = struct {
    items: [MAX_MENU_ITEMS]MenuItem = undefined,
    item_count: usize = 0,

    fn addItem(self: *DbusMenu, parent_index: i32) ?usize {
        if (self.item_count >= self.items.len) return null; // scaffold-sized; fine for now
        const idx = self.item_count;
        self.items[idx] = .{ .parent_index = parent_index };
        self.item_count += 1;
        return idx;
    }

    /// Direct children of `parent_index`, in order. Pass 0 for the real
    /// top-level items (item[0] is always the synthetic root wrapper).
    pub fn childrenOf(self: *const DbusMenu, parent_index: i32, out: []usize) []usize {
        var n: usize = 0;
        for (self.items[0..self.item_count], 0..) |item, i| {
            if (item.parent_index == parent_index and item.visible) {
                if (n >= out.len) break;
                out[n] = i;
                n += 1;
            }
        }
        return out[0..n];
    }
};

// Requesting a fixed, known set of properties keeps the value-type switch
// in parseNode exhaustive for what apps actually send back — no need for a
// fully general D-Bus variant skipper.
const REQUESTED_PROPS = [_][]const u8{ "label", "enabled", "visible", "type", "children-display" };

fn appendStringArray(list: *std.ArrayList(u8), gpa: std.mem.Allocator, items: []const []const u8) !void {
    try dbus.appendU32(list, gpa, 0); // length placeholder
    const len_offset = list.items.len - 4;
    const start = list.items.len; // strings are 4-aligned, same as the length field — no gap to pad
    for (items) |s| try dbus.appendStringLike(list, gpa, s);
    const array_len: u32 = @intCast(list.items.len - start);
    std.mem.writeInt(u32, list.items[len_offset..][0..4], array_len, .little);
}

/// Parses one "(ia{sv}av)" node (the reader positioned right after its
/// leading struct alignment is handled internally) and recurses into its
/// children. `r.pos` is left exactly at the end of this node's encoding.
fn parseNode(r: *dbus.Reader, menu: *DbusMenu, parent_index: i32) !void {
    try r.alignTo(8);
    const id = try r.readI32();
    const idx = menu.addItem(parent_index);
    if (idx) |i| menu.items[i].id = id;

    const dict_bytes = try r.readU32();
    try r.alignTo(8);
    const dict_end = r.pos + dict_bytes;
    while (r.pos < dict_end) {
        try r.alignTo(8);
        const key = try r.readStringLike();
        const vsig = try r.readSignature();
        if (vsig.len == 0) continue;
        switch (vsig[0]) {
            's' => {
                const val = try r.readStringLike();
                if (idx) |i| {
                    if (std.mem.eql(u8, key, "label")) {
                        const len = @min(val.len, menu.items[i].label_buf.len);
                        @memcpy(menu.items[i].label_buf[0..len], val[0..len]);
                        menu.items[i].label_len = len;
                    } else if (std.mem.eql(u8, key, "type")) {
                        menu.items[i].is_separator = std.mem.eql(u8, val, "separator");
                    } else if (std.mem.eql(u8, key, "children-display")) {
                        menu.items[i].has_children = std.mem.eql(u8, val, "submenu");
                    }
                }
            },
            'b' => {
                const val = (try r.readU32()) != 0;
                if (idx) |i| {
                    if (std.mem.eql(u8, key, "enabled")) menu.items[i].enabled = val;
                    if (std.mem.eql(u8, key, "visible")) menu.items[i].visible = val;
                }
            },
            'i', 'u' => _ = try r.readU32(),
            // Anything else (icon-data as 'ay', etc.) — bail on this node
            // rather than risk misparsing the rest of the stream, since we
            // don't have a fully general skip for arbitrary signatures.
            else => return error.UnsupportedPropertyType,
        }
    }
    r.pos = dict_end; // resync to the known boundary regardless

    const children_bytes = try r.readU32();
    const children_end = r.pos + children_bytes;
    while (r.pos < children_end) {
        _ = try r.readSignature(); // each child variant's signature, "(ia{sv}av)"
        try parseNode(r, menu, if (idx) |i| @intCast(i) else -1);
    }
    r.pos = children_end;
}

/// Fetches and parses the full menu tree rooted at `path` on `dest`. Calls
/// AboutToShow(0) first (best-effort — some apps lazily populate the menu
/// on this call) before GetLayout.
pub fn fetchMenu(c: *dbus.Connection, dest: []const u8, path: []const u8) !DbusMenu {
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(std.heap.page_allocator);
        try dbus.appendI32(&body, std.heap.page_allocator, 0);
        if (c.call(.{
            .destination = dest,
            .path = path,
            .interface = "com.canonical.dbusmenu",
            .member = "AboutToShow",
        }, .{ .bytes = body.items, .signature = "i" })) |reply| {
            reply.deinit();
        } else |_| {}
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    try dbus.appendI32(&body, std.heap.page_allocator, 0); // parentId: root
    try dbus.appendI32(&body, std.heap.page_allocator, -1); // recursionDepth: all levels
    try appendStringArray(&body, std.heap.page_allocator, &REQUESTED_PROPS);

    const reply = try c.call(.{
        .destination = dest,
        .path = path,
        .interface = "com.canonical.dbusmenu",
        .member = "GetLayout",
    }, .{ .bytes = body.items, .signature = "iias" });
    defer reply.deinit();

    var r = reply.bodyReader();
    _ = try r.readU32(); // revision, unused

    // The top-level struct is written directly per the body signature
    // ("u(ia{sv}av)") — unlike the recursive children (each wrapped in a
    // variant, hence parseNode's readSignature call per child), there's no
    // signature-string prefix here to skip.
    var menu = DbusMenu{};
    try parseNode(&r, &menu, -1);

    // item[0] is always this synthetic root wrapper (GetLayout echoes back
    // parentId, 0, as its id) — not a real, clickable entry. Its direct
    // children (parent_index == 0, since it's index 0) are the actual
    // top-level menu items; query those via childrenOf(0, ...).
    return menu;
}

/// Fire-and-forget "the user clicked this item" notification.
pub fn sendClickEvent(c: *dbus.Connection, dest: []const u8, path: []const u8, id: i32) void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.heap.page_allocator);
    dbus.appendI32(&body, std.heap.page_allocator, id) catch return;
    dbus.appendStringLike(&body, std.heap.page_allocator, "clicked") catch return;
    // "data" is a variant; an empty/placeholder int32 0 is accepted by every
    // real implementation encountered — they don't inspect it for "clicked".
    body.append(std.heap.page_allocator, 1) catch return; // signature length
    body.append(std.heap.page_allocator, 'i') catch return;
    body.append(std.heap.page_allocator, 0) catch return; // signature NUL
    dbus.appendI32(&body, std.heap.page_allocator, 0) catch return;
    dbus.appendU32(&body, std.heap.page_allocator, 0) catch return; // timestamp
    c.send(.method_call, .{
        .path = path,
        .interface = "com.canonical.dbusmenu",
        .member = "Event",
        .destination = dest,
    }, .{ .bytes = body.items, .signature = "isvu" }) catch {};
}

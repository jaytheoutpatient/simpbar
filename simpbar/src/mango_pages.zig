// Simpbar Config — MangoWM settings pages (the compositor section of the
// navigation sidebar when running under MangoWM / mangowm).
//
// Unlike the Hyprland pages (which edit hyprland.zig's in-memory model and
// render a managed Lua snippet), Mango's config *is* a set of flat
// `key = value` files under ~/.config/mango/cfg/, pulled in by
// ~/.config/mango/config.conf. So these pages read those files through
// mango.zig's line-preserving Doc, edit them in place (every change writes
// the file back atomically), and call `mmsg dispatch reload_config` to apply.
//
// Layout mirrors hypr_pages.zig deliberately:
//   - 9 pages, same order/count as the Hyprland section, so the sidebar is a
//     fixed size and only the names/icons/section header change at runtime.
//   - "boxed-list" GtkListBox for the multi-value rule/bind/autostart/env
//     lists, AdwPreferencesGroup form rows for the scalar settings.
//   - Rows are backed by stable addresses (a fixed global Field/ctx pool, or
//     the doc line index as an int user_data), never dangling heap structs.
//   - Signals are connected AFTER the initial value is set, so building a
//     row never fires a spurious write.
//
// Colours here are Mango's 0xRRGGBBAA (lowercase), NOT Hyprland's #rrggbb /
// 0xAARRGGBB, so this file has its own conversion helpers and does not reuse
// hypr_pages.hexToRgba.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hp = @import("hypr_pages.zig");
const hypr = @import("hyprland.zig");
const mango = @import("mango.zig");
const desk = @import("desk_theme.zig");
const mon = @import("monitors.zig");

const gpa = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// ---------------------------------------------------------------------
// Config documents
// ---------------------------------------------------------------------

var doc_appearance: mango.Doc = .{};
var doc_input: mango.Doc = .{};
var doc_monitors: mango.Doc = .{};
var doc_keybinds: mango.Doc = .{};
var doc_rules: mango.Doc = .{};
var doc_layout: mango.Doc = .{};
var doc_autostart: mango.Doc = .{};
var doc_env: mango.Doc = .{};
var doc_misc: mango.Doc = .{};

fn cfgPath(buf: []u8, name: []const u8) []const u8 {
    const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/root";
    return std.fmt.bufPrint(buf, "{s}/.config/mango/cfg/{s}", .{ home, name }) catch "";
}

pub fn init() void {
    var b: [512]u8 = undefined;
    doc_appearance.load(cfgPath(&b, "appearance.conf"));
    doc_input.load(cfgPath(&b, "input.conf"));
    doc_monitors.load(cfgPath(&b, "monitors.conf"));
    doc_keybinds.load(cfgPath(&b, "keybinds.conf"));
    doc_rules.load(cfgPath(&b, "rules.conf"));
    doc_layout.load(cfgPath(&b, "layout.conf"));
    doc_autostart.load(cfgPath(&b, "autostart.conf"));
    doc_env.load(cfgPath(&b, "env.conf"));
    doc_misc.load(cfgPath(&b, "misc.conf"));
}

/// Applies the config now: `mmsg dispatch reload_config` re-reads every sourced
/// file. Blocking but fast; usable from a button callback.
pub fn reload() void {
    if (hypr.captureOutput(&.{ "mmsg", "dispatch", "reload_config" }, 4000)) |out| gpa.free(out);
}

// ---------------------------------------------------------------------
// Colour helpers (Mango 0xRRGGBBAA)
// ---------------------------------------------------------------------

fn mangoHexToRgba(hex: []const u8) ?gtk.GdkRGBA {
    var strip = hex;
    if (strip.len > 0 and strip[0] == '#') {
        strip = strip[1..];
    } else if (std.mem.startsWith(u8, strip, "0x") or std.mem.startsWith(u8, strip, "0X")) {
        strip = strip[2..];
    }
    if (strip.len != 6 and strip.len != 8) return null;
    const v = std.fmt.parseInt(u32, strip, 16) catch return null;
    const r: u32 = if (strip.len == 8) (v >> 24) & 0xff else (v >> 16) & 0xff;
    const g: u32 = if (strip.len == 8) (v >> 16) & 0xff else (v >> 8) & 0xff;
    const b: u32 = if (strip.len == 8) (v >> 8) & 0xff else v & 0xff;
    const a: u32 = if (strip.len == 8) v & 0xff else 0xff;
    return .{
        .red = @as(f32, @floatFromInt(r)) / 255.0,
        .green = @as(f32, @floatFromInt(g)) / 255.0,
        .blue = @as(f32, @floatFromInt(b)) / 255.0,
        .alpha = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn rgbaToMangoColor(c: gtk.GdkRGBA, buf: []u8) []const u8 {
    const clamp = std.math.clamp;
    const r: u32 = @intFromFloat(@round(clamp(c.red, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp(c.green, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp(c.blue, 0.0, 1.0) * 255.0));
    const a: u32 = @intFromFloat(@round(clamp(c.alpha, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a }) catch "0x000000ff";
}

const ColorCtx = struct { doc: *mango.Doc, key: []const u8 };
var g_color_ctx: [64]ColorCtx = undefined;
var g_color_n: usize = 0;

fn onColorChanged(button: *gtk.GtkColorDialogButton, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *ColorCtx = @ptrCast(@alignCast(user_data.?));
    const rgba = gtk.gtk_color_dialog_button_get_rgba(button).*;
    var buf: [16]u8 = undefined;
    ctx.doc.setValue(ctx.key, rgbaToMangoColor(rgba, &buf));
    _ = ctx.doc.save();
    reload();
}

fn addColorField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: []const u8) void {
    if (g_color_n >= g_color_ctx.len) g_color_n = 0;
    const ctx = &g_color_ctx[g_color_n];
    g_color_n += 1;
    ctx.* = .{ .doc = doc, .key = key };

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const dialog = gtk.gtk_color_dialog_new();
    const button = gtk.gtk_color_dialog_button_new(dialog);
    const cur = doc.value(key) orelse default;
    if (mangoHexToRgba(cur)) |rgba| gtk.gtk_color_dialog_button_set_rgba(button, &rgba);
    gtk.gtk_widget_set_valign(@ptrCast(button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(button), "notify::rgba", @ptrCast(&onColorChanged), @ptrCast(ctx), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(button));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// Scalar form fields — one stable Field per row, edited live.
// ---------------------------------------------------------------------

const Field = struct {
    doc: *mango.Doc,
    key: []const u8,
    is_float: bool = false,
    combo: ?[]const []const u8 = null,
};

var g_fields: [1024]Field = undefined;
var g_fields_n: usize = 0;

fn fieldFor(doc: *mango.Doc, key: []const u8, is_float: bool, combo: ?[]const []const u8) *Field {
    if (g_fields_n >= g_fields.len) g_fields_n = 0;
    const f = &g_fields[g_fields_n];
    g_fields_n += 1;
    f.* = .{ .doc = doc, .key = key, .is_float = is_float, .combo = combo };
    return f;
}

fn onFieldEntry(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    f.doc.setValue(f.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
    _ = f.doc.save();
}

fn onFieldSpin(spin: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    var buf: [64]u8 = undefined;
    const s = if (f.is_float)
        std.fmt.bufPrint(&buf, "{d}", .{hg.gtk_spin_button_get_value(spin)}) catch return
    else
        std.fmt.bufPrint(&buf, "{d}", .{gtk.gtk_spin_button_get_value_as_int(spin)}) catch return;
    f.doc.setValue(f.key, s);
    _ = f.doc.save();
}

fn onFieldSwitch(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    f.doc.setValue(f.key, if (gtk.gtk_switch_get_active(sw) != 0) "1" else "0");
    _ = f.doc.save();
    reload();
}

fn onFieldCombo(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const f: *Field = @ptrCast(@alignCast(user_data.?));
    const vals = f.combo orelse return;
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx >= vals.len) return;
    f.doc.setValue(f.key, vals[idx]);
    _ = f.doc.save();
    reload();
}

fn addEntryField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: []const u8, width: c_int) void {
    const cur = doc.value(key) orelse default;
    hp.addEntryRow(group, title, cur, width, @ptrCast(&onFieldEntry), @ptrCast(fieldFor(doc, key, false, null)));
}

fn addSpinField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, step: f64, doc: *mango.Doc, key: []const u8, default: f64, is_float: bool) void {
    addSpinFieldCb(group, title, min, max, step, doc, key, default, is_float, @ptrCast(&onFieldSpin));
}

fn addSpinFieldCb(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, step: f64, doc: *mango.Doc, key: []const u8, default: f64, is_float: bool, cb: gtk.GCallback) void {
    const initial = if (is_float) doc.getFloat(key, default) else @as(f64, @floatFromInt(doc.getInt(key, @intFromFloat(default))));
    hp.addSpinRow(group, title, min, max, step, initial, cb, @ptrCast(fieldFor(doc, key, is_float, null)));
}

fn addSwitchField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, doc: *mango.Doc, key: []const u8, default: bool) void {
    hp.addSwitchRow(group, title, "", doc.getBool(key, default), @ptrCast(&onFieldSwitch), @ptrCast(fieldFor(doc, key, false, null)));
}

fn addComboField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, labels: []const [*:0]const u8, values: []const []const u8, doc: *mango.Doc, key: []const u8, default: []const u8) void {
    addComboFieldCb(group, title, labels, values, doc, key, default, @ptrCast(&onFieldCombo));
}

fn addComboFieldCb(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, labels: []const [*:0]const u8, values: []const []const u8, doc: *mango.Doc, key: []const u8, default: []const u8, cb: gtk.GCallback) void {
    const cur = doc.value(key) orelse default;
    var sel: c_uint = 0;
    for (values, 0..) |v, i| {
        if (std.mem.eql(u8, cur, v)) {
            sel = @intCast(i);
            break;
        }
    }
    hp.addComboRow(group, title, labels, sel, cb, @ptrCast(fieldFor(doc, key, false, values)));
}

// ---------------------------------------------------------------------
// Per-surface blur switches — the Blur group's Bar / Desktop Widgets
// rows. These are NOT single appearance.conf keys: each toggles the
// `no_blur` param on that surface's layer_rule line in rules.conf
// (Mango only blurs a layer when blur_layer is on AND no rule opts it
// out, so the switch reads/writes that opt-out).
// ---------------------------------------------------------------------

const BlurCtx = struct { surface: []const u8 };
var g_blur_ctx: [8]BlurCtx = undefined;
var g_blur_n: usize = 0;

/// Splits one `layer_rule` value into its comma-separated params. For each
/// non-empty fragment calls `f` with (key, value) — value is "" when the
/// fragment carries no colon (kept verbatim by the writer below, mirroring
/// openRuleDialog's extras handling).
fn eachRuleParam(value: []const u8, ctx: anytype, f: fn (@TypeOf(ctx), []const u8, []const u8, []const u8) void) void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (std.mem.indexOfScalar(u8, p, ':')) |c| {
            f(ctx, p, std.mem.trim(u8, p[0..c], " \t"), std.mem.trim(u8, p[c + 1 ..], " \t"));
        } else {
            f(ctx, p, "", "");
        }
    }
}

/// Index of the LAST layer_rule line matching `surface` (later rules win),
/// or null. Mango matches layer_name as a regex; the GUI works on exact
/// names, same as the Layer Rules editor's display.
fn layerRuleIndexFor(surface: []const u8) ?usize {
    var found: ?usize = null;
    for (doc_rules.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "layer_rule")) continue;
        var name_match = false;
        var it = std.mem.splitScalar(u8, kv.value, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "layer_name") and
                std.mem.eql(u8, std.mem.trim(u8, p[c + 1 ..], " \t"), surface))
            {
                name_match = true;
                break;
            }
        }
        if (name_match) found = i;
    }
    return found;
}

/// Effective blur state for a layer-shell surface: blurred unless its
/// (last matching) layer_rule line opts out with no_blur:1. Missing line or
/// missing param both mean blurred — the default once blur_layer is on.
fn layerBlurEnabled(surface: []const u8) bool {
    const i = layerRuleIndexFor(surface) orelse return true;
    const kv = mango.parseKV(doc_rules.line(i)) orelse return true;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "no_blur")) {
            const v = std.mem.trim(u8, p[c + 1 ..], " \t");
            return !(std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true"));
        }
    }
    return true;
}

const BlurEmit = struct { out: []u8, n: *usize, first: *bool, want: []const u8, saw: *bool };

fn blurEmitSet(ctx: *BlurEmit, frag: []const u8, pk: []const u8, pv: []const u8) void {
    if (!ctx.first.*) appendStr(ctx.out, ctx.n, ", ");
    ctx.first.* = false;
    if (pk.len == 0) {
        appendStr(ctx.out, ctx.n, frag);
    } else if (std.mem.eql(u8, pk, "no_blur")) {
        appendStr(ctx.out, ctx.n, "no_blur:");
        appendStr(ctx.out, ctx.n, ctx.want);
        ctx.saw.* = true;
    } else {
        appendStr(ctx.out, ctx.n, pk);
        appendStr(ctx.out, ctx.n, ":");
        appendStr(ctx.out, ctx.n, pv);
    }
}

/// Sets the surface's blur state, preserving every other param (and any
/// colon-less extras) on its layer_rule line in place. Appends a minimal
/// opt-out line when turning off with no line to edit; turning on with no
/// line needs no write — blurring is the default for layers.
fn setLayerBlur(surface: []const u8, on: bool) void {
    const want: []const u8 = if (on) "0" else "1";
    if (layerRuleIndexFor(surface)) |mi| {
        const kv = mango.parseKV(doc_rules.line(mi)) orelse return;
        var buf: [mango.MAX_LINE]u8 = undefined;
        var n: usize = 0;
        var first = true;
        var saw = false;
        var ctx: BlurEmit = .{ .out = &buf, .n = &n, .first = &first, .want = want, .saw = &saw };
        appendStr(&buf, &n, "layer_rule = ");
        eachRuleParam(kv.value, &ctx, blurEmitSet);
        if (!saw) {
            appendStr(&buf, &n, ", no_blur:");
            appendStr(&buf, &n, want);
        }
        doc_rules.setLine(mi, buf[0..n]);
    } else if (!on) {
        var buf: [mango.MAX_LINE]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "layer_rule = no_blur:1, layer_name:{s}", .{surface}) catch return;
        doc_rules.appendLine(s);
    }
}

fn onSurfaceBlurSwitch(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *BlurCtx = @ptrCast(@alignCast(user_data.?));
    const on = gtk.gtk_switch_get_active(sw) != 0;
    if (on and !doc_appearance.getBool("blur_layer", true)) {
        // A surface switch is meaningless with layer blur off — enable it
        // (the group description says this happens).
        doc_appearance.setValue("blur_layer", "1");
        _ = doc_appearance.save();
    }
    setLayerBlur(ctx.surface, on);
    _ = doc_rules.save();
    reload();
    rebuildRuleList(&g_rp_lrules);
}

fn addSurfaceBlurSwitch(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, surface: []const u8) void {
    if (g_blur_n >= g_blur_ctx.len) g_blur_n = 0;
    const ctx = &g_blur_ctx[g_blur_n];
    g_blur_n += 1;
    ctx.* = .{ .surface = surface };
    hp.addSwitchRow(group, title, "", layerBlurEnabled(surface), @ptrCast(&onSurfaceBlurSwitch), @ptrCast(ctx));
}

// ---------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------

const MAX_DFIELDS = 24;

fn appendStr(out: []u8, n: *usize, s: []const u8) void {
    if (n.* >= out.len) return;
    const room = out.len - n.*;
    const k = @min(room, s.len);
    @memcpy(out[n.*..][0..k], s[0..k]);
    n.* += k;
}

/// AdwPreferencesGroup titles, AdwActionRow titles/subtitles are parsed as
/// Pango markup, so a literal '&'/'<'/'>' in user config (e.g. a bind whose
/// arguments contain "&&") would otherwise fail to render. Copies `s` into
/// `buf` (entity-escaped) and returns it NUL-terminated.
fn escapeZ(s: []const u8, buf: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (s) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => {
                if (n + 1 >= buf.len) break;
                buf[n] = c;
                n += 1;
                continue;
            },
        };
        if (n + rep.len >= buf.len) break;
        @memcpy(buf[n..][0..rep.len], rep);
        n += rep.len;
    }
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

fn addRowButtonEx(row: *gtk.AdwActionRow, label: [:0]const u8, cb: gtk.GCallback, user_data: ?*anyopaque, rp: ?*const RulePage) void {
    const btn = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_set_valign(@ptrCast(btn), gtk.ALIGN_CENTER);
    if (rp) |r| gtk.g_object_set_data(@ptrCast(btn), "rp", @ptrCast(@constCast(r)));
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(btn));
}

/// Local copy of hp.addEntryRow that also returns the entry widget, for the
/// dialogs that rebuild their line from several entries.
fn addEntryRowRet(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, initial: []const u8, width: c_int, cb: gtk.GCallback, user_data: ?*anyopaque) *gtk.GtkEntry {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), width, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    hp.setEntryZ(buffer, initial);
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
    return entry;
}

// ---------------------------------------------------------------------
// Edit-dialog context (one dialog at a time)
// ---------------------------------------------------------------------

const DlgKind = enum { pair, bind, raw };

const DlgCtx = struct {
    kind: DlgKind = .pair,
    doc: *mango.Doc = undefined,
    key: []const u8 = "",
    line: usize = 0,
    spec: []const [:0]const u8 = &.{},
    entries: [MAX_DFIELDS]*gtk.GtkEntry = undefined,
    nfields: usize = 0,
    extras: [1024]u8 = undefined,
    extras_len: usize = 0,
};

var g_dlg: DlgCtx = undefined;

fn buildPairValue(ctx: *DlgCtx, out: []u8) []const u8 {
    var n: usize = 0;
    var first = true;
    var i: usize = 0;
    while (i < ctx.nfields) : (i += 1) {
        const t = hp.entryText(ctx.entries[i]);
        if (t.len == 0) continue;
        if (!first) appendStr(out, &n, ", ");
        first = false;
        appendStr(out, &n, ctx.spec[i]);
        appendStr(out, &n, ":");
        appendStr(out, &n, t);
    }
    if (ctx.extras_len > 0) {
        if (!first) appendStr(out, &n, ", ");
        appendStr(out, &n, ctx.extras[0..ctx.extras_len]);
    }
    return out[0..n];
}

fn buildBindValue(ctx: *DlgCtx, out: []u8) []const u8 {
    var n: usize = 0;
    appendStr(out, &n, hp.entryText(ctx.entries[0]));
    appendStr(out, &n, ", ");
    appendStr(out, &n, hp.entryText(ctx.entries[1]));
    appendStr(out, &n, ", ");
    appendStr(out, &n, hp.entryText(ctx.entries[2]));
    const args = hp.entryText(ctx.entries[3]);
    if (args.len > 0) {
        appendStr(out, &n, ", ");
        appendStr(out, &n, args);
    }
    return out[0..n];
}

fn writeDlgLine() void {
    var vb: [2048]u8 = undefined;
    const value: []const u8 = switch (g_dlg.kind) {
        .pair => buildPairValue(&g_dlg, &vb),
        .bind => buildBindValue(&g_dlg, &vb),
        .raw => hp.entryText(g_dlg.entries[0]),
    };
    var lb: [2200]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ g_dlg.key, value }) catch return;
    g_dlg.doc.setLine(g_dlg.line, line);
    _ = g_dlg.doc.save();
}

fn onDlgEntryChanged(_: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    writeDlgLine();
}

fn onCtxDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    reload();
    rebuildAll();
}

fn presentCtxDialog(parent: *anyopaque, title: [:0]const u8, content: *gtk.GtkBox) void {
    const d = hg.adw_dialog_new();
    hg.adw_dialog_set_title(d, title);
    hg.adw_dialog_set_content_width(d, 600);
    hg.adw_dialog_set_child(d, @ptrCast(content));
    _ = gtk.g_signal_connect_data(@ptrCast(d), "closed", @ptrCast(&onCtxDialogClosed), null, null, 0);
    hp.addDialogFooter(content, d);
    hg.adw_dialog_present(d, parent);
}

// ---------------------------------------------------------------------
// Rule pages (monitor_rule / window_rule / layer_rule / tag_rule)
// ---------------------------------------------------------------------

const RulePage = struct {
    doc: *mango.Doc,
    key: []const u8,
    spec: []const [:0]const u8,
    list: *?*gtk.GtkListBox,
    title: [:0]const u8,
    desc: [:0]const u8,
    add_label: [:0]const u8,
    add_value: []const u8,
    dlg_title: [:0]const u8,
};

var g_monitors_list: ?*gtk.GtkListBox = null;
var g_wrules_list: ?*gtk.GtkListBox = null;
var g_lrules_list: ?*gtk.GtkListBox = null;
var g_tagrules_list: ?*gtk.GtkListBox = null;

const MON_SPEC = [_][:0]const u8{ "name", "width", "height", "refresh", "x", "y", "scale", "rr", "vrr", "mirror" };
const WIN_SPEC = [_][:0]const u8{ "app_id", "title", "is_floating", "is_scratchpad", "is_opensilent", "is_not_focus", "no_border", "no_animation", "no_blur", "no_shadow", "no_radius", "move_to_tag", "move_to_monitor" };
const LAYER_SPEC = [_][:0]const u8{ "layer_name", "no_animation", "no_blur", "no_shadow", "no_radius", "animation_type_open", "animation_type_close" };
const TAG_SPEC = [_][:0]const u8{ "id", "layout_name" };

var g_rp_monitors: RulePage = .{
    .doc = &doc_monitors,
    .key = "monitor_rule",
    .spec = &MON_SPEC,
    .list = &g_monitors_list,
    .title = "Monitors",
    .desc = "One row per monitor_rule. Values are comma-separated key:value pairs (name, width, height, refresh, x, y, scale, rr, vrr, mirror). Auto-detect fills them from the connected displays.",
    .add_label = "Add Monitor Rule",
    .add_value = "name:DP-1, width:1920, height:1080, refresh:60, x:0, y:0, rr:0, vrr:0",
    .dlg_title = "Edit Monitor Rule",
};
var g_rp_wrules: RulePage = .{
    .doc = &doc_rules,
    .key = "window_rule",
    .spec = &WIN_SPEC,
    .list = &g_wrules_list,
    .title = "Window Rules",
    .desc = "One row per window_rule. Match fields (app_id, title) plus options like is_floating, no_border, no_blur.",
    .add_label = "Add Window Rule",
    .add_value = "app_id:",
    .dlg_title = "Edit Window Rule",
};
var g_rp_lrules: RulePage = .{
    .doc = &doc_rules,
    .key = "layer_rule",
    .spec = &LAYER_SPEC,
    .list = &g_lrules_list,
    .title = "Layer Rules",
    .desc = "One row per layer_rule, matched by layer_name. Controls animations, blur, shadows and radius for layer-shell surfaces.",
    .add_label = "Add Layer Rule",
    .add_value = "layer_name:",
    .dlg_title = "Edit Layer Rule",
};
var g_rp_tags: RulePage = .{
    .doc = &doc_layout,
    .key = "tag_rule",
    .spec = &TAG_SPEC,
    .list = &g_tagrules_list,
    .title = "Tag Layouts",
    .desc = "One row per tag_rule, assigning a layout to each tag (workspace). Later rules win for the same tag.",
    .add_label = "Add Tag Layout",
    .add_value = "id:1, layout_name:dwindle",
    .dlg_title = "Edit Tag Layout",
};

fn ruleTitle(rp: *const RulePage, value: []const u8, buf: []u8) [*:0]const u8 {
    const keys = [_][]const u8{ "name", "app_id", "layer_name", "id" };
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        const pk = std.mem.trim(u8, p[0..c], " \t");
        const pv = std.mem.trim(u8, p[c + 1 ..], " \t");
        if (pv.len == 0) continue;
        for (keys) |k| {
            if (std.mem.eql(u8, pk, k)) return escapeZ(pv, buf);
        }
    }
    return escapeZ(rp.title, buf);
}

fn openRuleDialog(parent: *anyopaque, rp: *const RulePage, line: usize) void {
    if (line >= rp.doc.lineCount()) return;
    const kv = mango.parseKV(rp.doc.line(line)) orelse return;

    g_dlg = .{ .kind = .pair, .doc = rp.doc, .key = rp.key, .line = line, .spec = rp.spec, .nfields = rp.spec.len };

    var vals = [_][]const u8{""} ** MAX_DFIELDS;
    var extras_n: usize = 0;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        var matched = false;
        if (std.mem.indexOfScalar(u8, p, ':')) |c| {
            const pk = std.mem.trim(u8, p[0..c], " \t");
            const pv = std.mem.trim(u8, p[c + 1 ..], " \t");
            for (rp.spec, 0..) |sk, i| {
                if (std.mem.eql(u8, pk, sk)) {
                    vals[i] = pv;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            if (extras_n > 0) appendStr(&g_dlg.extras, &extras_n, ", ");
            appendStr(&g_dlg.extras, &extras_n, p);
        }
    }
    g_dlg.extras_len = extras_n;

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    var i: usize = 0;
    while (i < rp.spec.len and i < MAX_DFIELDS) : (i += 1) {
        g_dlg.entries[i] = addEntryRowRet(group, rp.spec[i], vals[i], 220, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
    }
    gtk.gtk_box_append(content, @ptrCast(group));
    presentCtxDialog(parent, rp.dlg_title, content);
}

fn onRuleEdit(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const d = gtk.g_object_get_data(@ptrCast(button), "rp") orelse return;
    const rp: *const RulePage = @ptrCast(@alignCast(d));
    const line = @intFromPtr(user_data.?) - 1;
    // Monitor rules get the capability-aware canvas dialog (resolution /
    // refresh dropdowns from wlr-randr modes); everything else keeps the
    // generic pair editor.
    if (rp == &g_rp_monitors) {
        openMangoMonitorDialog(@ptrCast(button), line);
        return;
    }
    openRuleDialog(@ptrCast(button), rp, line);
}

fn onRuleRemove(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const d = gtk.g_object_get_data(@ptrCast(button), "rp") orelse return;
    const rp: *const RulePage = @ptrCast(@alignCast(d));
    rp.doc.removeLine(@intFromPtr(user_data.?) - 1);
    _ = rp.doc.save();
    reload();
    rebuildRuleList(rp);
    if (rp == &g_rp_monitors) queueMangoCanvasDraw();
}

fn onRuleAdd(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const rp: *const RulePage = @ptrCast(@alignCast(user_data.?));
    var lb: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ rp.key, rp.add_value }) catch return;
    rp.doc.appendLine(line);
    _ = rp.doc.save();
    reload();
    rebuildRuleList(rp);
    queueMangoCanvasDraw();
    if (rp == &g_rp_monitors) {
        openMangoMonitorDialog(@ptrCast(button), rp.doc.lineCount() - 1);
        return;
    }
    openRuleDialog(@ptrCast(button), rp, rp.doc.lineCount() - 1);
}

fn rebuildRuleList(rp: *const RulePage) void {
    const listbox = rp.list.* orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (rp.doc.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, rp.key)) continue;

        const row = gtk.adw_action_row_new();
        var tb: [hp.MAX_TITLE]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), ruleTitle(rp, kv.value, &tb));
        var sb: [hp.MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, escapeZ(kv.value, &sb));
        addRowButtonEx(row, "Edit", @ptrCast(&onRuleEdit), @ptrFromInt(i + 1), rp);
        addRowButtonEx(row, "Remove", @ptrCast(&onRuleRemove), @ptrFromInt(i + 1), rp);
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn addRulePage(outer: *gtk.GtkBox, rp: *const RulePage) void {
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, rp.title);
    gtk.adw_preferences_group_set_description(group, rp.desc);
    gtk.gtk_box_append(outer, @ptrCast(group));

    const lb = hp.newListBox();
    rp.list.* = lb;
    gtk.gtk_box_append(outer, @ptrCast(lb));
    rebuildRuleList(rp);
    hp.appendActionButton(outer, rp.add_label, @ptrCast(&onRuleAdd), @ptrCast(@constCast(rp)));
}

// ---------------------------------------------------------------------
// Monitors page — Event-Horizon-style editor for MangoWM.
// monitor_rule lines keep their flat `key:value` format; the page adds:
//   - a visual arrange canvas (click to select, drag to move, snap +
//     normalize on drop),
//   - capability-aware Resolution / Refresh dropdowns parsed from the FULL
//     `wlr-randr` mode list (not just the current mode),
//   - side-by-side / align-tops helpers,
//   - and the original Auto-detect button (fills name/width/height/
//     refresh/x/y from live outputs, preserving scale/rr/vrr/mirror).
// ---------------------------------------------------------------------

const MANGO_CANVAS_W: c_int = 620;
const MANGO_CANVAS_H: c_int = 280;
const MANGO_CANVAS_PAD: f64 = 0.1;

var g_mango_canvas: ?*hg.GtkDrawingArea = null;
var g_mango_selected: usize = 0; // index into monitor_rule lines list
var g_mango_caps: [8]mon.WlrCapsEntry = undefined;
var g_mango_caps_n: usize = 0;

var g_mdrag_idx: isize = -1;
var g_mdrag_anchor_x: i32 = 0;
var g_mdrag_anchor_y: i32 = 0;
var g_mdrag_fit_min_x: f64 = 0;
var g_mdrag_fit_min_y: f64 = 0;
var g_mdrag_fit_scale: f64 = 1;

// Edit-dialog dropdown storage (one dialog at a time).
var g_mdlg_res_bufs: [mon.MAX_RES][16:0]u8 = undefined;
var g_mdlg_res_ptrs: [mon.MAX_RES][*:0]const u8 = undefined;
var g_mdlg_hz_bufs: [mon.MAX_HZ][16:0]u8 = undefined;
var g_mdlg_hz_ptrs: [mon.MAX_HZ][*:0]const u8 = undefined;
// The doc line the open dialog edits (dropdown callbacks need it; the
// generic DlgCtx is not used for monitor rules).
var g_mdlg_line: usize = 0;

fn queueMangoCanvasDraw() void {
    if (g_mango_canvas) |c| hg.gtk_widget_queue_draw(@ptrCast(c));
}

fn findMonitorRuleLine(name: []const u8) ?usize {
    for (doc_monitors.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        var it = std.mem.splitScalar(u8, kv.value, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), "name") and
                std.mem.eql(u8, std.mem.trim(u8, p[c + 1 ..], " \t"), name)) return i;
        }
    }
    return null;
}

/// Geometry keys rewritten from detection (see desk.composeMangoRule).
/// Everything else on the line is preserved verbatim — except refresh,
/// kept from the old line only when detection has nothing newer to say.

fn onMonitorsDetectClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (desk.detectMango() == 0) return;
    refreshMangoCaps();
    for (desk.detectedMonitors()) |*d| {
        if (d.name().len == 0 or d.width == 0 or d.height == 0) continue;
        const li = findMonitorRuleLine(d.name());
        var old: ?[]const u8 = null;
        if (li) |idx| {
            if (mango.parseKV(doc_monitors.line(idx))) |kv| old = kv.value;
        }
        var vbuf: [mango.MAX_LINE]u8 = undefined;
        const line = desk.composeMangoRule(d.name(), d.width, d.height, d.refresh, d.x, d.y, old, li == null, &vbuf);
        if (li) |idx| doc_monitors.setLine(idx, line) else doc_monitors.appendLine(line);
    }
    _ = doc_monitors.save();
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

// --- Caps (full wlr-randr mode list) ---

fn refreshMangoCaps() void {
    g_mango_caps_n = 0;
    const out = hypr.captureOutput(&.{ "wlr-randr" }, 3000) orelse return;
    defer gpa.free(out);
    g_mango_caps_n = mon.parseWlrRandrCaps(out, &g_mango_caps);
}

fn mangoCapsFor(name: []const u8) ?*const mon.OutputCaps {
    if (name.len == 0) return null;
    var i: usize = 0;
    while (i < g_mango_caps_n) : (i += 1) {
        if (std.mem.eql(u8, g_mango_caps[i].name(), name)) return &g_mango_caps[i].caps;
    }
    return null;
}

// --- Rule value helpers ---

fn ruleField(value: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const c = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..c], " \t"), key)) {
            return std.mem.trim(u8, p[c + 1 ..], " \t");
        }
    }
    return "";
}

fn ruleInt(value: []const u8, key: []const u8, fallback: i32) i32 {
    const s = ruleField(value, key);
    if (s.len == 0) return fallback;
    return std.fmt.parseInt(i32, s, 10) catch fallback;
}

/// Collects doc line indices for every monitor_rule. Returns count.
fn mangoMonitorLines(out: []usize) usize {
    var n: usize = 0;
    for (doc_monitors.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!std.mem.eql(u8, kv.key, "monitor_rule")) continue;
        if (n < out.len) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

fn mangoRects(rects: []mon.ArrangeRect, line_idxs: []const usize) usize {
    var n: usize = 0;
    for (line_idxs, 0..) |li, k| {
        if (k >= rects.len) break;
        const kv = mango.parseKV(doc_monitors.line(li)) orelse continue;
        const w = ruleInt(kv.value, "width", 1920);
        const h = ruleInt(kv.value, "height", 1080);
        const x = ruleInt(kv.value, "x", 0);
        const y = ruleInt(kv.value, "y", 0);
        const scale_s = ruleField(kv.value, "scale");
        const ss: []const u8 = if (scale_s.len != 0) scale_s else "1";
        var lw: i32 = 0;
        var lh: i32 = 0;
        mon.logicalExtents(w, h, ss, 0, &lw, &lh);
        rects[k] = .{ .x = x, .y = y, .w = lw, .h = lh };
        n += 1;
    }
    return n;
}

fn mangoRuleName(line_idx: usize, buf: []u8) []const u8 {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return "";
    const nm = ruleField(kv.value, "name");
    const n = @min(nm.len, buf.len);
    @memcpy(buf[0..n], nm[0..n]);
    return buf[0..n];
}

/// Rewrites x/y for each monitor_rule, preserving every other pair
/// (width/height/refresh/scale/rr/vrr/mirror) via composeMangoRule.
fn writeMangoPositions(rects: []const mon.ArrangeRect, line_idxs: []const usize) void {
    for (rects, 0..) |r, k| {
        if (k >= line_idxs.len) break;
        const li = line_idxs[k];
        const kv = mango.parseKV(doc_monitors.line(li)) orelse continue;
        const nm = ruleField(kv.value, "name");
        if (nm.len == 0) continue;
        const w = ruleInt(kv.value, "width", 0);
        const h = ruleInt(kv.value, "height", 0);
        if (w == 0 or h == 0) continue;
        const rf = ruleField(kv.value, "refresh");
        const refresh: u32 = if (rf.len != 0) std.fmt.parseInt(u32, rf, 10) catch 0 else 0;
        var vbuf: [mango.MAX_LINE]u8 = undefined;
        const line = desk.composeMangoRule(nm, @intCast(w), @intCast(h), refresh, r.x, r.y, kv.value, false, &vbuf);
        doc_monitors.setLine(li, line);
    }
    _ = doc_monitors.save();
    reload();
}

/// Sets one key:value pair on a monitor_rule line, preserving the rest.
fn setMangoRuleField(line_idx: usize, key: []const u8, value: []const u8) void {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return;
    var out: [mango.MAX_LINE]u8 = undefined;
    var n: usize = 0;
    const W = struct {
        fn s(buf: []u8, nn: *usize, t: []const u8) void {
            if (nn.* >= buf.len) return;
            const k = @min(t.len, buf.len - nn.*);
            @memcpy(buf[nn.*..][0..k], t[0..k]);
            nn.* += k;
        }
    };
    W.s(&out, &n, "monitor_rule = ");
    var first = true;
    var saw = false;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        const c = std.mem.indexOfScalar(u8, p, ':');
        const pk: []const u8 = if (c) |cc| std.mem.trim(u8, p[0..cc], " \t") else p;
        if (std.mem.eql(u8, pk, key)) {
            saw = true;
            if (value.len == 0) continue;
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, key);
            W.s(&out, &n, ":");
            W.s(&out, &n, value);
        } else {
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, p);
        }
    }
    if (!saw and value.len != 0) {
        if (!first) W.s(&out, &n, ", ");
        W.s(&out, &n, key);
        W.s(&out, &n, ":");
        W.s(&out, &n, value);
    }
    doc_monitors.setLine(line_idx, out[0..n]);
    _ = doc_monitors.save();
}

// --- Canvas paint + interaction ---

fn onMangoCanvasDraw(_: *hg.GtkDrawingArea, cr: *hg.CairoT, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const cw: i32 = @intCast(w);
    const ch: i32 = @intCast(h);
    hg.cairo_set_source_rgb(cr, 0.11, 0.11, 0.14);
    hg.cairo_rectangle(cr, 0, 0, @floatFromInt(@max(1, cw)), @floatFromInt(@max(1, ch)));
    hg.cairo_fill(cr);
    if (n == 0) {
        hg.cairo_set_source_rgb(cr, 0.6, 0.6, 0.65);
        hg.cairo_select_font_face(cr, "monospace", 0, 0);
        hg.cairo_set_font_size(cr, 13);
        hg.cairo_move_to(cr, 16, 24);
        var msg: [128:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&msg, "No monitor rules — Add one or hit Auto-detect.", .{}) catch "No monitors.";
        hg.cairo_show_text(cr, s.ptr);
        return;
    }
    const fit = mon.computeCanvasFit(rects[0..n], cw, ch, MANGO_CANVAS_PAD);
    const sf = @max(fit.fit_scale, 1e-6);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = rects[i];
        if (r.w <= 0 or r.h <= 0) continue;
        const sx = (r.x - fit.min_x) * sf;
        const sy = (r.y - fit.min_y) * sf;
        const sw: f64 = @as(f64, @floatFromInt(r.w)) * sf;
        const sh: f64 = @as(f64, @floatFromInt(r.h)) * sf;
        if (i == g_mango_selected) {
            hg.cairo_set_source_rgba(cr, 0.28, 0.55, 0.95, 0.45);
        } else {
            hg.cairo_set_source_rgba(cr, 0.35, 0.38, 0.48, 0.55);
        }
        hg.cairo_rectangle(cr, sx, sy, @max(4, sw), @max(4, sh));
        hg.cairo_fill(cr);
        if (i == g_mango_selected) {
            hg.cairo_set_source_rgb(cr, 0.45, 0.7, 1.0);
        } else {
            hg.cairo_set_source_rgb(cr, 0.55, 0.58, 0.65);
        }
        hg.cairo_set_line_width(cr, if (i == g_mango_selected) 2.5 else 1.5);
        hg.cairo_rectangle(cr, sx, sy, @max(4, sw), @max(4, sh));
        hg.cairo_stroke(cr);
        hg.cairo_set_source_rgb(cr, 0.92, 0.92, 0.95);
        hg.cairo_select_font_face(cr, "monospace", 0, 0);
        hg.cairo_set_font_size(cr, 12);
        hg.cairo_move_to(cr, sx + 6, sy + 16);
        var nbuf: [64]u8 = undefined;
        const nm = mangoRuleName(line_idxs[i], &nbuf);
        var lbuf: [72:0]u8 = undefined;
        const zs = std.fmt.bufPrintZ(&lbuf, "{s}", .{if (nm.len != 0) nm else "???"}) catch "?";
        hg.cairo_show_text(cr, zs.ptr);
    }
}

fn mangoCanvasHit(px: f64, py: f64) isize {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return -1;
    const fit = mon.computeCanvasFit(rects[0..n], MANGO_CANVAS_W, MANGO_CANVAS_H, MANGO_CANVAS_PAD);
    const sf = @max(fit.fit_scale, 1e-6);
    var i: isize = @intCast(n);
    while (i > 0) {
        i -= 1;
        const idx: usize = @intCast(i);
        const r = rects[idx];
        if (r.w <= 0 or r.h <= 0) continue;
        const sx = (r.x - fit.min_x) * sf;
        const sy = (r.y - fit.min_y) * sf;
        const sw: f64 = @as(f64, @floatFromInt(r.w)) * sf;
        const sh: f64 = @as(f64, @floatFromInt(r.h)) * sf;
        if (px >= sx and px < sx + sw and py >= sy and py < sy + sh) return i;
    }
    return -1;
}

fn onMangoCanvasPressed(_: *hg.GtkGestureClick, n_press: c_int, x: f64, y: f64, user_data: ?*anyopaque) callconv(.c) void {
    const hit = mangoCanvasHit(x, y);
    if (hit >= 0) {
        g_mango_selected = @intCast(hit);
        queueMangoCanvasDraw();
        if (n_press >= 2) {
            var line_idxs: [8]usize = undefined;
            const m = mangoMonitorLines(&line_idxs);
            if (@as(usize, @intCast(hit)) < m) {
                if (user_data) |parent| openMangoMonitorDialog(parent, line_idxs[@intCast(hit)]);
            }
        }
    }
}

fn onMangoDragBegin(_: *hg.GtkGestureDrag, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    const hit = mangoCanvasHit(x, y);
    g_mdrag_idx = hit;
    if (hit < 0) return;
    g_mango_selected = @intCast(hit);
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const fit = mon.computeCanvasFit(rects[0..n], MANGO_CANVAS_W, MANGO_CANVAS_H, MANGO_CANVAS_PAD);
    g_mdrag_fit_min_x = fit.min_x;
    g_mdrag_fit_min_y = fit.min_y;
    g_mdrag_fit_scale = @max(fit.fit_scale, 1e-6);
    const idx: usize = @intCast(hit);
    if (idx < m) {
        const kv = mango.parseKV(doc_monitors.line(line_idxs[idx])) orelse return;
        g_mdrag_anchor_x = ruleInt(kv.value, "x", 0);
        g_mdrag_anchor_y = ruleInt(kv.value, "y", 0);
    }
    queueMangoCanvasDraw();
}

fn setMangoRuleFieldNoSave(line_idx: usize, key: []const u8, value: []const u8) void {
    const kv = mango.parseKV(doc_monitors.line(line_idx)) orelse return;
    var out: [mango.MAX_LINE]u8 = undefined;
    var n: usize = 0;
    const W = struct {
        fn s(buf: []u8, nn: *usize, t: []const u8) void {
            if (nn.* >= buf.len) return;
            const k = @min(t.len, buf.len - nn.*);
            @memcpy(buf[nn.*..][0..k], t[0..k]);
            nn.* += k;
        }
    };
    W.s(&out, &n, "monitor_rule = ");
    var first = true;
    var saw = false;
    var it = std.mem.splitScalar(u8, kv.value, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        const c = std.mem.indexOfScalar(u8, p, ':');
        const pk: []const u8 = if (c) |cc| std.mem.trim(u8, p[0..cc], " \t") else p;
        if (std.mem.eql(u8, pk, key)) {
            saw = true;
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, key);
            W.s(&out, &n, ":");
            W.s(&out, &n, value);
        } else {
            if (!first) W.s(&out, &n, ", ");
            first = false;
            W.s(&out, &n, p);
        }
    }
    if (!saw) {
        if (!first) W.s(&out, &n, ", ");
        W.s(&out, &n, key);
        W.s(&out, &n, ":");
        W.s(&out, &n, value);
    }
    doc_monitors.setLine(line_idx, out[0..n]);
}

fn onMangoDragUpdate(gesture: *hg.GtkGestureDrag, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (g_mdrag_idx < 0) return;
    const idx: usize = @intCast(g_mdrag_idx);
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    if (idx >= m) return;
    var ox: f64 = 0;
    var oy: f64 = 0;
    hg.gtk_gesture_drag_get_offset(gesture, &ox, &oy);
    const inv = 1.0 / @max(g_mdrag_fit_scale, 1e-9);
    const nx: i32 = g_mdrag_anchor_x + @as(i32, @intFromFloat(@round(ox * inv)));
    const ny: i32 = g_mdrag_anchor_y + @as(i32, @intFromFloat(@round(oy * inv)));
    var xbuf: [16]u8 = undefined;
    var ybuf: [16]u8 = undefined;
    const xs = std.fmt.bufPrint(&xbuf, "{d}", .{nx}) catch return;
    const ys = std.fmt.bufPrint(&ybuf, "{d}", .{ny}) catch return;
    setMangoRuleFieldNoSave(line_idxs[idx], "x", xs);
    setMangoRuleFieldNoSave(line_idxs[idx], "y", ys);
    queueMangoCanvasDraw();
}

fn onMangoDragEnd(_: *hg.GtkGestureDrag, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (g_mdrag_idx < 0) return;
    const moved: usize = @intCast(g_mdrag_idx);
    g_mdrag_idx = -1;
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    const dis = [_]bool{false} ** 8;
    mon.finalizeDrag(rects[0..n], dis[0..n], moved);
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoArrangeClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return;
    const dis = [_]bool{false} ** 8;
    mon.arrangeSideBySide(rects[0..n], dis[0..n]);
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoAlignTopsClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var line_idxs: [8]usize = undefined;
    const m = mangoMonitorLines(&line_idxs);
    var rects: [8]mon.ArrangeRect = undefined;
    const n = mangoRects(&rects, line_idxs[0..m]);
    if (n == 0) return;
    const dis = [_]bool{false} ** 8;
    mon.alignTops(rects[0..n], dis[0..n]);
    var mn_y: i32 = std.math.maxInt(i32);
    for (rects[0..n]) |r| mn_y = @min(mn_y, r.y);
    if (mn_y != std.math.maxInt(i32)) {
        for (rects[0..n]) |*r| r.y -= mn_y;
    }
    writeMangoPositions(rects[0..n], line_idxs[0..m]);
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoCapsRefreshClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    refreshMangoCaps();
    queueMangoCanvasDraw();
}

// --- Capability-aware monitor_rule dialog ---

fn onMangoResChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    const kv = mango.parseKV(doc_monitors.line(g_mdlg_line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const caps = mangoCapsFor(nm) orelse return;
    if (idx >= caps.n_res) return;
    const res = caps.resolution(idx);
    const x = std.mem.indexOfScalar(u8, res, 'x') orelse return;
    const ws = res[0..x];
    const hs = res[x + 1 ..];
    const list = caps.hzList(idx);
    if (list.len > 0) {
        var rib: [16]u8 = undefined;
        const ri = std.fmt.bufPrint(&rib, "{d}", .{@as(i32, @intFromFloat(@round(list[0])))}) catch return;
        setMangoRuleField(g_mdlg_line, "width", ws);
        setMangoRuleField(g_mdlg_line, "height", hs);
        setMangoRuleField(g_mdlg_line, "refresh", ri);
    } else {
        setMangoRuleField(g_mdlg_line, "width", ws);
        setMangoRuleField(g_mdlg_line, "height", hs);
    }
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoHzChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx: usize = @intCast(gtk.adw_combo_row_get_selected(row));
    const kv = mango.parseKV(doc_monitors.line(g_mdlg_line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const ws = ruleField(kv.value, "width");
    const hs = ruleField(kv.value, "height");
    const caps = mangoCapsFor(nm) orelse return;
    var ri: usize = 0;
    var found = false;
    var i: usize = 0;
    while (i < caps.n_res) : (i += 1) {
        const r = caps.resolution(i);
        const x = std.mem.indexOfScalar(u8, r, 'x') orelse continue;
        if (std.mem.eql(u8, r[0..x], ws) and std.mem.eql(u8, r[x + 1 ..], hs)) {
            ri = i;
            found = true;
            break;
        }
    }
    if (!found) return;
    const list = caps.hzList(ri);
    if (idx >= list.len) return;
    var rib: [16]u8 = undefined;
    const ri_s = std.fmt.bufPrint(&rib, "{d}", .{@as(i32, @intFromFloat(@round(list[idx])))}) catch return;
    setMangoRuleField(g_mdlg_line, "refresh", ri_s);
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn onMangoCtxDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    reload();
    rebuildRuleList(&g_rp_monitors);
    queueMangoCanvasDraw();
}

fn openMangoMonitorDialog(parent: *anyopaque, line: usize) void {
    if (line >= doc_monitors.lineCount()) return;
    const kv0 = mango.parseKV(doc_monitors.line(line)) orelse return;
    if (!std.mem.eql(u8, kv0.key, "monitor_rule")) {
        openRuleDialog(parent, &g_rp_monitors, line);
        return;
    }
    g_mdlg_line = line;
    const kv = mango.parseKV(doc_monitors.line(line)) orelse return;
    const nm = ruleField(kv.value, "name");
    const ws = ruleField(kv.value, "width");
    const hs = ruleField(kv.value, "height");
    const rf = ruleField(kv.value, "refresh");
    const xs = ruleField(kv.value, "x");
    const ys = ruleField(kv.value, "y");
    const ss = ruleField(kv.value, "scale");
    const rrs = ruleField(kv.value, "rr");
    const vrs = ruleField(kv.value, "vrr");
    const mir = ruleField(kv.value, "mirror");

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Monitor Rule");
    {
        const row = gtk.adw_action_row_new();
        gtk.adw_preferences_row_set_title(@ptrCast(row), "Name");
        const entry = gtk.gtk_entry_new();
        gtk.gtk_widget_set_size_request(@ptrCast(entry), 180, -1);
        gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
        hp.setEntryZ(gtk.gtk_entry_get_buffer(entry), nm);
        _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(entry)), "notify::text", @ptrCast(&onMangoNameChanged), null, null, 0);
        gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
        gtk.adw_preferences_group_add(group, @ptrCast(row));
    }
    const caps = mangoCapsFor(nm);
    if (caps != null and caps.?.n_res > 0) {
        const c = caps.?;
        var cur_res_buf: [32]u8 = undefined;
        const cur_res = std.fmt.bufPrint(&cur_res_buf, "{s}x{s}", .{ ws, hs }) catch "";
        var ri = c.findResolution(cur_res) orelse 0;
        if (ri >= c.n_res) ri = 0;
        var rn: usize = 0;
        while (rn < c.n_res and rn < mon.MAX_RES) : (rn += 1) {
            const s = c.resolution(rn);
            const n = @min(s.len, 15);
            @memcpy(g_mdlg_res_bufs[rn][0..n], s[0..n]);
            g_mdlg_res_bufs[rn][n] = 0;
            g_mdlg_res_ptrs[rn] = g_mdlg_res_bufs[rn][0..n :0];
        }
        hp.addComboRow(group, "Resolution", g_mdlg_res_ptrs[0..rn], @intCast(ri), @ptrCast(&onMangoResChanged), null);
        const list = c.hzList(ri);
        var hn: usize = 0;
        var sel: usize = 0;
        for (list, 0..) |hz, hi| {
            if (hn >= mon.MAX_HZ) break;
            var hzb: [16]u8 = undefined;
            const s = mon.formatHz(hz, &hzb);
            const n = @min(s.len, 15);
            @memcpy(g_mdlg_hz_bufs[hn][0..n], s[0..n]);
            g_mdlg_hz_bufs[hn][n] = 0;
            g_mdlg_hz_ptrs[hn] = g_mdlg_hz_bufs[hn][0..n :0];
            const rounded: i32 = @intFromFloat(@round(hz));
            var rib: [16]u8 = undefined;
            const rs = std.fmt.bufPrint(&rib, "{d}", .{rounded}) catch "";
            if (std.mem.eql(u8, rs, rf)) sel = hn;
            hn += 1;
            _ = hi;
        }
        if (hn > 0) {
            hp.addComboRow(group, "Refresh Rate", g_mdlg_hz_ptrs[0..hn], @intCast(sel), @ptrCast(&onMangoHzChanged), null);
        }
    }
    addMangoField(group, "Width", ws, "width", 100);
    addMangoField(group, "Height", hs, "height", 100);
    addMangoField(group, "Refresh", rf, "refresh", 100);
    addMangoField(group, "X", xs, "x", 100);
    addMangoField(group, "Y", ys, "y", 100);
    addMangoField(group, "Scale", ss, "scale", 100);
    addMangoField(group, "RR", rrs, "rr", 100);
    addMangoField(group, "VRR", vrs, "vrr", 100);
    addMangoField(group, "Mirror", mir, "mirror", 160);
    gtk.gtk_box_append(content, @ptrCast(group));
    const d = hg.adw_dialog_new();
    hg.adw_dialog_set_title(d, "Edit Monitor Rule");
    hg.adw_dialog_set_content_width(d, 600);
    hg.adw_dialog_set_child(d, @ptrCast(content));
    _ = gtk.g_signal_connect_data(@ptrCast(d), "closed", @ptrCast(&onMangoCtxDialogClosed), null, null, 0);
    hp.addDialogFooter(content, d);
    hg.adw_dialog_present(d, parent);
}

const MangoFieldCtx = struct { key: []const u8 };
var g_mango_field_ctx: [16]MangoFieldCtx = undefined;
var g_mango_field_n: usize = 0;

fn onMangoFieldChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *MangoFieldCtx = @ptrCast(@alignCast(user_data.?));
    setMangoRuleField(g_mdlg_line, ctx.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
}

fn onMangoNameChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    setMangoRuleField(g_mdlg_line, "name", std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
}

fn addMangoField(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, initial: []const u8, key: []const u8, width: c_int) void {
    if (g_mango_field_n >= g_mango_field_ctx.len) g_mango_field_n = 0;
    const ctx = &g_mango_field_ctx[g_mango_field_n];
    g_mango_field_n += 1;
    ctx.* = .{ .key = key };
    hp.addEntryRow(group, title, initial, width, @ptrCast(&onMangoFieldChanged), @ptrCast(ctx));
}

// ---------------------------------------------------------------------
// Keybinds page
// ---------------------------------------------------------------------

var g_keybinds_list: ?*gtk.GtkListBox = null;

fn isBindKey(k: []const u8) bool {
    return std.mem.eql(u8, k, "bind") or std.mem.eql(u8, k, "mousebind") or
        std.mem.eql(u8, k, "axisbind") or std.mem.eql(u8, k, "gesturebind");
}

fn parseBind(v: []const u8, mods: *[]const u8, key: *[]const u8, action: *[]const u8, args: *[]const u8) void {
    var parts = [_][]const u8{ "", "", "", "" };
    var idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < v.len and idx < 4) : (i += 1) {
        if (v[i] == ',') {
            if (idx < 3) {
                parts[idx] = std.mem.trim(u8, v[start..i], " \t");
                idx += 1;
                start = i + 1;
            } else break;
        }
    }
    parts[idx] = std.mem.trim(u8, v[start..], " \t");
    mods.* = parts[0];
    key.* = parts[1];
    action.* = parts[2];
    args.* = parts[3];
}

fn openBindDialog(parent: *anyopaque, line: usize) void {
    if (line >= doc_keybinds.lineCount()) return;
    const kv = mango.parseKV(doc_keybinds.line(line)) orelse return;
    const is_bind = std.mem.eql(u8, kv.key, "bind");
    // Use a static key: kv.key points into the doc line, which setLine()
    // replaces (and frees) on the first edit, so a stored slice would dangle.
    const bkey: []const u8 = if (std.mem.eql(u8, kv.key, "mousebind"))
        "mousebind"
    else if (std.mem.eql(u8, kv.key, "axisbind"))
        "axisbind"
    else if (std.mem.eql(u8, kv.key, "gesturebind"))
        "gesturebind"
    else
        "bind";

    g_dlg = .{ .kind = if (is_bind) .bind else .raw, .doc = &doc_keybinds, .key = bkey, .line = line };

    const content = hp.newDialogBox();
    const group = gtk.adw_preferences_group_new();
    if (is_bind) {
        var m: []const u8 = "";
        var k: []const u8 = "";
        var a: []const u8 = "";
        var ar: []const u8 = "";
        parseBind(kv.value, &m, &k, &a, &ar);
        const titles = [_][:0]const u8{ "Modifiers", "Key", "Action", "Arguments" };
        const inits = [_][]const u8{ m, k, a, ar };
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            g_dlg.entries[i] = addEntryRowRet(group, titles[i], inits[i], 220, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
        }
        g_dlg.nfields = 4;
    } else {
        g_dlg.entries[0] = addEntryRowRet(group, "Value", kv.value, 360, @ptrCast(&onDlgEntryChanged), @ptrCast(&g_dlg));
        g_dlg.nfields = 1;
    }
    gtk.gtk_box_append(content, @ptrCast(group));
    presentCtxDialog(parent, "Edit Keybind", content);
}

fn onBindEdit(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openBindDialog(@ptrCast(button), @intFromPtr(user_data.?) - 1);
}

fn onBindRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_keybinds.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_keybinds.save();
    reload();
    rebuildKeybindsList();
}

fn onBindAdd(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_keybinds.appendLine("bind = SUPER, q, killclient");
    _ = doc_keybinds.save();
    reload();
    rebuildKeybindsList();
    openBindDialog(@ptrCast(button), doc_keybinds.lineCount() - 1);
}

fn rebuildKeybindsList() void {
    const listbox = g_keybinds_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_keybinds.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (!isBindKey(kv.key)) continue;

        const row = gtk.adw_action_row_new();
        var tb: [hp.MAX_TITLE]u8 = undefined;
        if (std.mem.eql(u8, kv.key, "bind")) {
            var m: []const u8 = "";
            var k: []const u8 = "";
            var a: []const u8 = "";
            var ar: []const u8 = "";
            parseBind(kv.value, &m, &k, &a, &ar);
            gtk.adw_preferences_row_set_title(@ptrCast(row), hp.fmtZ(&tb, "{s} + {s}", .{ m, k }));
            var raw_sub: [hp.MAX_ZBUF]u8 = undefined;
            const rs = std.fmt.bufPrint(&raw_sub, "{s} {s}", .{ a, ar }) catch "";
            var esc: [hp.MAX_ZBUF * 6]u8 = undefined;
            gtk.adw_action_row_set_subtitle(row, escapeZ(rs, &esc));
        } else {
            gtk.adw_preferences_row_set_title(@ptrCast(row), escapeZ(kv.key, &tb));
            var esc: [hp.MAX_ZBUF * 6]u8 = undefined;
            gtk.adw_action_row_set_subtitle(row, escapeZ(kv.value, &esc));
        }
        addRowButtonEx(row, "Edit", @ptrCast(&onBindEdit), @ptrFromInt(i + 1), null);
        addRowButtonEx(row, "Remove", @ptrCast(&onBindRemove), @ptrFromInt(i + 1), null);
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

// ---------------------------------------------------------------------
// Autostart page
// ---------------------------------------------------------------------

var g_autostart_list: ?*gtk.GtkListBox = null;

const AutoCtx = struct { doc: *mango.Doc, key: []const u8, line: usize };
var g_auto_ctx: [1024]AutoCtx = undefined;
var g_auto_n: usize = 0;

fn onAutoChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *AutoCtx = @ptrCast(@alignCast(user_data.?));
    var lb: [mango.MAX_LINE]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "{s} = {s}", .{ ctx.key, std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)) }) catch return;
    ctx.doc.setLine(ctx.line, line);
    _ = ctx.doc.save();
}

fn onAutoRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_autostart.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_autostart.save();
    reload();
    rebuildAutostartList();
}

fn addAutostartRow(listbox: *gtk.GtkListBox, key: []const u8, line: usize) void {
    const kv = mango.parseKV(doc_autostart.line(line)) orelse return;
    const is_exec = std.mem.eql(u8, key, "exec");
    // Static key (see openBindDialog): the doc line is rewritten on edit.
    const skey: []const u8 = if (is_exec) "exec" else "exec_once";
    if (g_auto_n >= g_auto_ctx.len) g_auto_n = 0;
    const ctx = &g_auto_ctx[g_auto_n];
    g_auto_n += 1;
    ctx.* = .{ .doc = &doc_autostart, .key = skey, .line = line };

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), if (is_exec) "Startup Command (exec)" else "Startup Command (exec_once)");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), 360, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    hp.setEntryZ(buffer, kv.value);
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", @ptrCast(&onAutoChanged), @ptrCast(ctx), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    hp.addRowButton(row, "Remove", @ptrCast(&onAutoRemove), @ptrFromInt(line + 1));
    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn rebuildAutostartList() void {
    const listbox = g_autostart_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_autostart.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (std.mem.eql(u8, kv.key, "exec_once") or std.mem.eql(u8, kv.key, "exec")) {
            addAutostartRow(listbox, kv.key, i);
        }
    }
}

fn onAutostartAdd(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_autostart.appendLine("exec_once = ");
    _ = doc_autostart.save();
    rebuildAutostartList();
}

fn buildAutostartPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Autostart");
    gtk.adw_preferences_group_set_description(group, "exec_once runs once at startup; exec runs every reload. Both are read from ~/.config/mango/cfg/autostart.conf.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_autostart_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_autostart_list.?));
    rebuildAutostartList();
    hp.appendActionButton(outer, "Add Startup Command", @ptrCast(&onAutostartAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Environment page
// ---------------------------------------------------------------------

var g_env_list: ?*gtk.GtkListBox = null;

const EnvCtx = struct { doc: *mango.Doc, line: usize, name: *gtk.GtkEntry, value: *gtk.GtkEntry };
var g_env_ctx: [1024]EnvCtx = undefined;
var g_env_n: usize = 0;

fn onEnvChanged(_: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *EnvCtx = @ptrCast(@alignCast(user_data.?));
    var lb: [mango.MAX_LINE]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "env = {s},{s}", .{ hp.entryText(ctx.name), hp.entryText(ctx.value) }) catch return;
    ctx.doc.setLine(ctx.line, line);
    _ = ctx.doc.save();
}

fn onEnvRemove(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    doc_env.removeLine(@intFromPtr(user_data.?) - 1);
    _ = doc_env.save();
    reload();
    rebuildEnvList();
}

fn addEnvRow(listbox: *gtk.GtkListBox, line: usize) void {
    const kv = mango.parseKV(doc_env.line(line)) orelse return;

    var nm = kv.value;
    var vl: []const u8 = "";
    if (std.mem.indexOfScalar(u8, kv.value, ',')) |c| {
        nm = kv.value[0..c];
        vl = kv.value[c + 1 ..];
    }
    nm = std.mem.trim(u8, nm, " \t");
    vl = std.mem.trim(u8, vl, " \t");

    if (g_env_n >= g_env_ctx.len) g_env_n = 0;
    const ctx = &g_env_ctx[g_env_n];
    g_env_n += 1;

    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Variable");

    const name_entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(name_entry), 180, -1);
    gtk.gtk_widget_set_valign(@ptrCast(name_entry), gtk.ALIGN_CENTER);
    hp.setEntryZ(gtk.gtk_entry_get_buffer(name_entry), nm);

    const value_entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(value_entry), 260, -1);
    gtk.gtk_widget_set_valign(@ptrCast(value_entry), gtk.ALIGN_CENTER);
    hp.setEntryZ(gtk.gtk_entry_get_buffer(value_entry), vl);

    ctx.* = .{ .doc = &doc_env, .line = line, .name = name_entry, .value = value_entry };
    _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(name_entry)), "notify::text", @ptrCast(&onEnvChanged), @ptrCast(ctx), null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(gtk.gtk_entry_get_buffer(value_entry)), "notify::text", @ptrCast(&onEnvChanged), @ptrCast(ctx), null, 0);

    gtk.adw_action_row_add_suffix(row, @ptrCast(name_entry));
    gtk.adw_action_row_add_suffix(row, @ptrCast(value_entry));
    hp.addRowButton(row, "Remove", @ptrCast(&onEnvRemove), @ptrFromInt(line + 1));
    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn rebuildEnvList() void {
    const listbox = g_env_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (doc_env.lines.items, 0..) |l, i| {
        const kv = mango.parseKV(l) orelse continue;
        if (std.mem.eql(u8, kv.key, "env")) addEnvRow(listbox, i);
    }
}

fn onEnvAdd(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    doc_env.appendLine("env = VARIABLE,");
    _ = doc_env.save();
    rebuildEnvList();
}

fn buildEnvPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Environment Variables");
    gtk.adw_preferences_group_set_description(group, "env = NAME,VALUE entries from env.conf. Values replace the inherited variable and are re-applied on every reload.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_env_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_env_list.?));
    rebuildEnvList();
    hp.appendActionButton(outer, "Add Environment Variable", @ptrCast(&onEnvAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Cursor + GTK theme (General page). Cursor theme comes from a dropdown of
// real cursor directories (~/.cursors first, then ~/.icons and the XDG /
// system icon dirs) instead of free text; the size spin additionally pushes
// the size through gsettings. GTK theme is desktop-global (gsettings +
// settings.ini) with no appearance.conf key, so it gets a plain combo row.
// ---------------------------------------------------------------------

fn onMangoCursorThemeChanged(row: *gtk.AdwComboRow, pspec: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    onFieldCombo(row, pspec, user_data);
    const idx = gtk.adw_combo_row_get_selected(row);
    const vals = desk.cursorValues();
    if (idx >= vals.len) return;
    desk.applyCursorTheme(vals[idx]);
}

fn onMangoCursorSizeChanged(spin: *gtk.GtkSpinButton, user_data: ?*anyopaque) callconv(.c) void {
    onFieldSpin(spin, user_data);
    desk.applyCursorSize(@intCast(gtk.gtk_spin_button_get_value_as_int(spin)));
}

fn onMangoGtkThemeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const idx = gtk.adw_combo_row_get_selected(row);
    const vals = desk.gtkValues();
    if (idx >= vals.len) return;
    desk.applyGtkTheme(vals[idx]);
}

fn buildCursorGroup(outer: *gtk.GtkBox) void {
    desk.discoverCursors();
    const cur = doc_appearance.value("cursor_theme") orelse "";
    desk.ensureCursorPresent(cur);
    const cursor = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(cursor, "Cursor");
    gtk.adw_preferences_group_set_description(cursor, "Cursor theme and size (appearance.conf). Drop themes into ~/.cursors to list them here.");
    if (desk.cursorValues().len == 0) {
        addEntryField(cursor, "Cursor Theme", &doc_appearance, "cursor_theme", "", 160);
    } else {
        addComboFieldCb(cursor, "Cursor Theme", desk.cursorLabels(), desk.cursorValues(), &doc_appearance, "cursor_theme", cur, @ptrCast(&onMangoCursorThemeChanged));
    }
    addSpinFieldCb(cursor, "Cursor Size (px)", 8, 128, 1, &doc_appearance, "cursor_size", 24, false, @ptrCast(&onMangoCursorSizeChanged));
    gtk.gtk_box_append(outer, @ptrCast(cursor));
}

fn buildMangoGtkThemeGroup(outer: *gtk.GtkBox) void {
    desk.discoverGtkThemes();
    var cbuf: [desk.MAX_NAME]u8 = undefined;
    const cur = desk.currentGtkThemeBuf(&cbuf);
    desk.ensureGtkPresent(cur);
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "GTK Theme");
    gtk.adw_preferences_group_set_description(group, "Theme for GTK apps (gsettings + settings.ini). Drop themes into ~/.themes to list them here.");
    const vals = desk.gtkValues();
    if (vals.len == 0) {
        gtk.gtk_box_append(outer, @ptrCast(group));
        return;
    }
    var sel: c_uint = 0;
    for (vals, 0..) |v, i| {
        if (std.mem.eql(u8, cur, v)) {
            sel = @intCast(i);
            break;
        }
    }
    hp.addComboRow(group, "GTK Theme", desk.gtkLabels(), sel, @ptrCast(&onMangoGtkThemeChanged), null);
    gtk.gtk_box_append(outer, @ptrCast(group));
}

// ---------------------------------------------------------------------
// General page (appearance.conf visuals + input.conf)
// ---------------------------------------------------------------------

fn buildGeneralPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const gaps = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(gaps, "Window Gaps");
    gtk.adw_preferences_group_set_description(gaps, "Inner spacing is between tiles; outer is the screen edge.");
    addSpinField(gaps, "Inner Gap (px)", 0, 128, 1, &doc_appearance, "gap_inner_horizontal", 5, false);
    addSpinField(gaps, "Inner Gap Vertical (px)", 0, 128, 1, &doc_appearance, "gap_inner_vertical", 5, false);
    addSpinField(gaps, "Outer Gap (px)", 0, 128, 1, &doc_appearance, "gap_outer_horizontal", 10, false);
    addSpinField(gaps, "Outer Gap Vertical (px)", 0, 128, 1, &doc_appearance, "gap_outer_vertical", 10, false);
    gtk.gtk_box_append(outer, @ptrCast(gaps));

    const decor = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(decor, "Borders and Opacity");
    addSpinField(decor, "Border Size (px)", 0, 32, 1, &doc_appearance, "border_px", 4, false);
    addSpinField(decor, "Corner Radius (px)", 0, 64, 1, &doc_appearance, "border_radius", 6, false);
    addSwitchField(decor, "No Radius When Single", &doc_appearance, "no_radius_when_single", false);
    addSpinField(decor, "Focused Opacity", 0.1, 1.0, 0.05, &doc_appearance, "focused_opacity", 1.0, true);
    addSpinField(decor, "Unfocused Opacity", 0.1, 1.0, 0.05, &doc_appearance, "unfocused_opacity", 1.0, true);
    gtk.gtk_box_append(outer, @ptrCast(decor));

    const blur = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(blur, "Blur");
    gtk.adw_preferences_group_set_description(blur, "Blur needs something translucent to show through: for the bar use Background Opacity under the Appearance tab, for the widgets card_bg_opacity in ~/.config/simpbar/shell.json. Turning a surface on also enables Blur on Layer Surfaces, which it needs.");
    addSwitchField(blur, "Enable Blur", &doc_appearance, "blur", true);
    addSwitchField(blur, "Blur on Layer Surfaces", &doc_appearance, "blur_layer", true);
    addSurfaceBlurSwitch(blur, "Bar Blur", "simpbar");
    addSurfaceBlurSwitch(blur, "Desktop Widgets Blur", "simpbar-shell");
    addSpinField(blur, "Blur Radius", 1, 32, 1, &doc_appearance, "blur_params_radius", 4, false);
    addSpinField(blur, "Blur Passes", 1, 8, 1, &doc_appearance, "blur_params_num_passes", 2, false);
    gtk.gtk_box_append(outer, @ptrCast(blur));

    const colors = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(colors, "Colors");
    gtk.adw_preferences_group_set_description(colors, "Base colours in appearance.conf. If ~/.config/mango/cfg/matugen-colors.conf exists, matugen's generated colours override these on reload.");
    addColorField(colors, "Root Background", &doc_appearance, "root_color", "0x201b14ff");
    addColorField(colors, "Border", &doc_appearance, "border_color", "0x444444ff");
    addColorField(colors, "Focused Border", &doc_appearance, "focus_color", "0x47add6ff");
    addColorField(colors, "Maximized Screen", &doc_appearance, "maximized_screen_color", "0x47add6ff");
    addColorField(colors, "Urgent", &doc_appearance, "urgent_color", "0xad401fff");
    addColorField(colors, "Scratchpad", &doc_appearance, "scratchpad_color", "0x516c93ff");
    addColorField(colors, "Global", &doc_appearance, "global_color", "0xb153a7ff");
    addColorField(colors, "Overlay", &doc_appearance, "overlay_color", "0x14a57cff");
    gtk.gtk_box_append(outer, @ptrCast(colors));

    buildCursorGroup(outer);
    buildMangoGtkThemeGroup(outer);

    const input = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(input, "Input (input.conf)");
    gtk.adw_preferences_group_set_description(input, "Some device options only apply after re-login.");
    addEntryField(input, "Keyboard Layout", &doc_input, "xkb_rules_layout", "us", 120);
    addSpinField(input, "Repeat Rate (/s)", 1, 100, 1, &doc_input, "repeat_rate", 25, false);
    addSpinField(input, "Repeat Delay (ms)", 100, 2000, 10, &doc_input, "repeat_delay", 600, false);
    addSwitchField(input, "Numlock On", &doc_input, "numlock_on", false);
    addSwitchField(input, "Disable Trackpad", &doc_input, "disable_trackpad", false);
    addSwitchField(input, "Tap To Click", &doc_input, "tap_to_click", true);
    addSwitchField(input, "Tap And Drag", &doc_input, "tap_and_drag", true);
    addSwitchField(input, "Drag Lock", &doc_input, "drag_lock", true);
    addSwitchField(input, "Trackpad Natural Scrolling", &doc_input, "trackpad_natural_scrolling", false);
    addSwitchField(input, "Trackpad Disable While Typing", &doc_input, "trackpad_disable_while_typing", true);
    addSwitchField(input, "Trackpad Left Handed", &doc_input, "trackpad_left_handed", false);
    addSwitchField(input, "Trackpad Middle Button Emulation", &doc_input, "trackpad_middle_button_emulation", false);
    addSpinField(input, "Swipe Min Threshold", 0, 64, 1, &doc_input, "swipe_min_threshold", 1, false);
    addSwitchField(input, "Mouse Natural Scrolling", &doc_input, "mouse_natural_scrolling", false);
    gtk.gtk_box_append(outer, @ptrCast(input));

    return outer;
}

// ---------------------------------------------------------------------
// Animations page (appearance.conf)
// ---------------------------------------------------------------------

const ANIM_TYPE_LABELS = [_][*:0]const u8{ "zoom", "slide" };
const ANIM_TYPE_VALUES = [_][]const u8{ "zoom", "slide" };
const DIR_LABELS = [_][*:0]const u8{ "Vertical", "Horizontal" };
const DIR_VALUES = [_][]const u8{ "0", "1" };

fn buildAnimationsPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    const anim = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(anim, "Animations");
    addSwitchField(anim, "Enable Animations", &doc_appearance, "animations", true);
    addSwitchField(anim, "Layer Animations", &doc_appearance, "layer_animations", true);
    addComboField(anim, "Open Type", &ANIM_TYPE_LABELS, &ANIM_TYPE_VALUES, &doc_appearance, "animation_type_open", "zoom");
    addComboField(anim, "Close Type", &ANIM_TYPE_LABELS, &ANIM_TYPE_VALUES, &doc_appearance, "animation_type_close", "zoom");
    addComboField(anim, "Tag Direction", &DIR_LABELS, &DIR_VALUES, &doc_appearance, "tag_animation_direction", "1");
    addSwitchField(anim, "Fade In", &doc_appearance, "animation_fade_in", true);
    addSwitchField(anim, "Fade Out", &doc_appearance, "animation_fade_out", true);
    gtk.gtk_box_append(outer, @ptrCast(anim));

    const timing = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(timing, "Durations (ms)");
    addSpinField(timing, "Move", 0, 5000, 10, &doc_appearance, "animation_duration_move", 300, false);
    addSpinField(timing, "Open", 0, 5000, 10, &doc_appearance, "animation_duration_open", 100, false);
    addSpinField(timing, "Tag Switch", 0, 5000, 10, &doc_appearance, "animation_duration_tag", 300, false);
    addSpinField(timing, "Close", 0, 5000, 10, &doc_appearance, "animation_duration_close", 400, false);
    addSpinField(timing, "Focus", 0, 5000, 10, &doc_appearance, "animation_duration_focus", 0, false);
    gtk.gtk_box_append(outer, @ptrCast(timing));

    const zf = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(zf, "Zoom and Fade");
    addSpinField(zf, "Zoom Initial Ratio", 0.0, 1.0, 0.05, &doc_appearance, "zoom_initial_ratio", 0.1, true);
    addSpinField(zf, "Zoom End Ratio", 0.0, 1.0, 0.05, &doc_appearance, "zoom_end_ratio", 0.5, true);
    addSpinField(zf, "Fade In Begin Opacity", 0.0, 1.0, 0.05, &doc_appearance, "fade_in_begin_opacity", 0.3, true);
    addSpinField(zf, "Fade Out Begin Opacity", 0.0, 1.0, 0.05, &doc_appearance, "fade_out_begin_opacity", 0.2, true);
    gtk.gtk_box_append(outer, @ptrCast(zf));

    const curves = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(curves, "Curves");
    gtk.adw_preferences_group_set_description(curves, "Bézier control points, e.g. 0.46, 1.0, 0.29, 1.");
    addEntryField(curves, "Open", &doc_appearance, "animation_curve_open", "0.87, 0, 0.13, 1", 260);
    addEntryField(curves, "Move", &doc_appearance, "animation_curve_move", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Tag", &doc_appearance, "animation_curve_tag", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Close", &doc_appearance, "animation_curve_close", "0.87, 0, 0.13, 1", 260);
    addEntryField(curves, "Focus", &doc_appearance, "animation_curve_focus", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Opacity Fade In", &doc_appearance, "animation_curve_opacity_fade_in", "0.46, 1.0, 0.29, 1", 260);
    addEntryField(curves, "Opacity Fade Out", &doc_appearance, "animation_curve_opacity_fade_out", "0.5, 0.5, 0.5, 0.5", 260);
    gtk.gtk_box_append(outer, @ptrCast(curves));

    return outer;
}

// ---------------------------------------------------------------------
// Layout page (layout.conf: tag_rule list + scroller/master settings)
// ---------------------------------------------------------------------

fn buildLayoutPage() *gtk.GtkBox {
    const outer = hp.pageBox();

    addRulePage(outer, &g_rp_tags);

    const scroller = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(scroller, "Scroller Layout");
    addSpinField(scroller, "Structs (px)", 0, 512, 1, &doc_layout, "scroller_structs", 40, false);
    addSpinField(scroller, "Default Proportion", 0.0, 4.0, 0.05, &doc_layout, "scroller_default_proportion", 0.5, true);
    addSpinField(scroller, "Single Proportion", 0.0, 8.0, 0.05, &doc_layout, "scroller_default_proportion_single", 2.0, true);
    addSwitchField(scroller, "Focus Center", &doc_layout, "scroller_focus_center", false);
    addSwitchField(scroller, "Prefer Center", &doc_layout, "scroller_prefer_center", false);
    addSwitchField(scroller, "Prefer Overspread", &doc_layout, "scroller_prefer_overspread", true);
    addSwitchField(scroller, "Edge Pointer Focus", &doc_layout, "edge_scroller_pointer_focus", true);
    addEntryField(scroller, "Proportion Presets", &doc_layout, "scroller_proportion_preset", "0.5, 0.8, 1.0", 220);
    gtk.gtk_box_append(outer, @ptrCast(scroller));

    const master = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(master, "Master-Stack Layout");
    addSwitchField(master, "New Window Is Master", &doc_layout, "new_is_master", true);
    addSpinField(master, "Master Factor", 0.05, 1.0, 0.05, &doc_layout, "default_master_factor", 0.55, true);
    addSpinField(master, "Master Count", 1, 16, 1, &doc_layout, "default_master_count", 1, false);
    addSwitchField(master, "Smart Gaps", &doc_layout, "smart_gaps", false);
    gtk.gtk_box_append(outer, @ptrCast(master));

    return outer;
}

// ---------------------------------------------------------------------
// Monitors / Window Rules pages
// ---------------------------------------------------------------------

fn buildMonitorsPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    // Update the description to mention the canvas + modes.
    g_rp_monitors.desc = "One row per monitor_rule. Drag cards on the canvas to arrange; Auto-detect fills name, resolution, refresh and position from the connected displays (extras like scale/rr/vrr/mirror are preserved). Resolution choices come from wlr-randr's full mode list.";
    addRulePage(outer, &g_rp_monitors);

    refreshMangoCaps();

    g_mango_canvas = hg.gtk_drawing_area_new();
    hg.gtk_drawing_area_set_content_width(g_mango_canvas.?, MANGO_CANVAS_W);
    hg.gtk_drawing_area_set_content_height(g_mango_canvas.?, MANGO_CANVAS_H);
    hg.gtk_drawing_area_set_draw_func(g_mango_canvas.?, &onMangoCanvasDraw, null, null);
    gtk.gtk_box_append(outer, @ptrCast(g_mango_canvas.?));

    const click = hg.gtk_gesture_click_new();
    _ = gtk.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onMangoCanvasPressed), g_mango_canvas.?, null, 0);
    gtk.gtk_widget_add_controller(@ptrCast(g_mango_canvas.?), @ptrCast(click));

    const drag = hg.gtk_gesture_drag_new();
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-begin", @ptrCast(&onMangoDragBegin), null, null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-update", @ptrCast(&onMangoDragUpdate), null, null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(drag), "drag-end", @ptrCast(&onMangoDragEnd), null, null, 0);
    gtk.gtk_widget_add_controller(@ptrCast(g_mango_canvas.?), @ptrCast(drag));

    hp.appendActionButton(outer, "Auto-detect Monitors", @ptrCast(&onMonitorsDetectClicked), null);
    hp.appendActionButton(outer, "Arrange Side-by-Side", @ptrCast(&onMangoArrangeClicked), null);
    hp.appendActionButton(outer, "Align Tops", @ptrCast(&onMangoAlignTopsClicked), null);
    hp.appendActionButton(outer, "Refresh Modes", @ptrCast(&onMangoCapsRefreshClicked), null);
    return outer;
}

fn buildWindowRulesPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addRulePage(outer, &g_rp_wrules);
    return outer;
}

fn buildLayerRulesPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    addRulePage(outer, &g_rp_lrules);
    return outer;
}

// ---------------------------------------------------------------------
// Keybinds page
// ---------------------------------------------------------------------

fn buildKeybindsPage() *gtk.GtkBox {
    const outer = hp.pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Keybinds");
    gtk.adw_preferences_group_set_description(group, "bind / mousebind / axisbind / gesturebind lines from keybinds.conf. Binds are MODIFIERS, KEY, ACTION, ARGUMENTS.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_keybinds_list = hp.newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_keybinds_list.?));
    rebuildKeybindsList();
    hp.appendActionButton(outer, "Add Keybind", @ptrCast(&onBindAdd), null);
    return outer;
}

// ---------------------------------------------------------------------
// Rebuild everything / page registry
// ---------------------------------------------------------------------

fn rebuildAll() void {
    rebuildRuleList(&g_rp_monitors);
    rebuildRuleList(&g_rp_wrules);
    rebuildRuleList(&g_rp_lrules);
    rebuildRuleList(&g_rp_tags);
    rebuildKeybindsList();
    rebuildAutostartList();
    rebuildEnvList();
}

pub const pages = struct {
    pub const names = [_][:0]const u8{ "General", "Monitors", "Animations", "Keybinds", "Window Rules", "Layout", "Layer Rules", "Autostart", "Environment" };
    pub const icons = [_][:0]const u8{ "emblem-system-symbolic", "video-display-symbolic", "media-playlist-repeat-symbolic", "input-keyboard-symbolic", "preferences-system-windows-symbolic", "view-grid-symbolic", "layer-group-symbolic", "system-run-symbolic", "preferences-system-symbolic" };

    pub fn widgets() [9]*gtk.GtkBox {
        return .{
            buildGeneralPage(),
            buildMonitorsPage(),
            buildAnimationsPage(),
            buildKeybindsPage(),
            buildWindowRulesPage(),
            buildLayoutPage(),
            buildLayerRulesPage(),
            buildAutostartPage(),
            buildEnvPage(),
        };
    }
};

// ---------------------------------------------------------------------
// Tests — layer-blur switch logic (pure Doc operations, no display).
// Run: zig test src/mango_pages.zig
// ---------------------------------------------------------------------

test "layer blur round-trip" {
    const t = std.testing;
    doc_rules.reset();
    defer doc_rules.reset();
    // In-memory fixture mirroring a real rules.conf (selection opt-out,
    // bar line with extra params, widgets line, comment).
    doc_rules.appendLine("# Layer rules fixture");
    doc_rules.appendLine("layer_rule = no_animation:1, no_blur:1, layer_name:selection");
    doc_rules.appendLine("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar");
    doc_rules.appendLine("layer_rule = no_blur:0, layer_name:simpbar-shell");

    // Fixture state: bar + widgets blurred, selection opted out.
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expect(layerBlurEnabled("simpbar-shell"));
    try t.expect(!layerBlurEnabled("selection"));
    try t.expect(layerBlurEnabled("never-seen")); // no line = default blur

    // Turning the bar off preserves its other params in place.
    setLayerBlur("simpbar", false);
    try t.expect(!layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:1, layer_name:simpbar", doc_rules.line(2));

    // ...and back on.
    setLayerBlur("simpbar", true);
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar", doc_rules.line(2));

    // Turning off a surface with no line appends a minimal opt-out.
    doc_rules.removeLine(3); // drop the simpbarshell line
    try t.expect(layerBlurEnabled("simpbar-shell"));
    setLayerBlur("simpbar-shell", false);
    try t.expect(!layerBlurEnabled("simpbar-shell"));
    try t.expectEqualStrings("layer_rule = no_blur:1, layer_name:simpbar-shell", doc_rules.line(doc_rules.lineCount() - 1));

    // Turning on a lineless surface writes nothing (default already blurs).
    const n_before = doc_rules.lineCount();
    setLayerBlur("never-seen", true);
    try t.expectEqual(n_before, doc_rules.lineCount());

    // Last matching line wins, for both read and write.
    doc_rules.appendLine("layer_rule = no_blur:1, layer_name:simpbar");
    try t.expect(!layerBlurEnabled("simpbar"));
    setLayerBlur("simpbar", true);
    try t.expect(layerBlurEnabled("simpbar"));
    try t.expectEqualStrings("layer_rule = no_blur:0, layer_name:simpbar", doc_rules.line(doc_rules.lineCount() - 1));
    try t.expectEqualStrings("layer_rule = no_animation:0, no_blur:0, layer_name:simpbar", doc_rules.line(2));
}

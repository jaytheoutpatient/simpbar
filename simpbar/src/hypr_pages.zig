// Simpbar Config — Hyprland settings pages (the "Hyprland" section of the
// navigation sidebar). Every page reads/writes hyprland.zig's in-memory
// model (hypr.state), which hyprland.zig persists to
// ~/.config/simpbar/hyprland.json and renders into the managed Lua snippet
// (~/.config/hypr/hyprland-simpbar.lua). Every change that lands in the
// model immediately calls hypr.saveAll(), matching the Appearance tab's
// "every single change writes the config back to disk" convention.
//
// Convention notes (mirroring config_main.zig):
//   - GTK4/libadwaita is reached only through welcome_gtk.zig (+ hypr_gtk.zig's
//     extra bindings), never @cImport.
//   - List pages back their rows with a plain GtkListBox ("boxed-list" CSS,
//     exactly like the Modules tab) so rows can be removed/rebuild freely —
//     AdwPreferencesGroup doesn't expose its internal listbox.
//   - Edit dialogs are AdwDialog (hypr_gtk.zig) hosting AdwPreferencesGroup
//     form rows. Fields edit the model LIVE via their notify::*/value-changed
//     signals (user_data = a stable address inside hypr.state), the "Done"
//     button just closes, and the dialog's "closed" signal rebuilds the list.
//   - Rows/buttons get stable addresses (fixed-capacity arrays in hypr.state)
//     or plain small ints as GObject user_data — never heap structs that can
//     dangle.

const std = @import("std");
const gtk = @import("welcome_gtk.zig");
const hg = @import("hypr_gtk.zig");
const hypr = @import("hyprland.zig");

// ---------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------

const MAX_ZBUF = 512;
const MAX_TITLE = 260;

/// Copies `s` into `buf` (must be >= s.len + 1) and returns it zero-terminated.
fn zCopy(s: []const u8, buf: []u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

/// bufPrintZ wrapper returning a zero-terminated pointer ("" on overflow).
fn fmtZ(buf: []u8, comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(buf, fmt, args) catch return "";
    return s.ptr;
}

fn pageBox() *gtk.GtkBox {
    const outer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_margin_top(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_start(@ptrCast(outer), 24);
    gtk.gtk_widget_set_margin_end(@ptrCast(outer), 24);
    return outer;
}

fn sectionHeading(outer: *gtk.GtkBox, title: [:0]const u8) void {
    const h = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(@ptrCast(h), "heading");
    gtk.gtk_label_set_xalign(h, 0);
    gtk.gtk_box_append(outer, @ptrCast(h));
}

fn newListBox() *gtk.GtkListBox {
    const lb = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(@ptrCast(lb), "boxed-list");
    return lb;
}

fn appendActionButton(parent: *gtk.GtkBox, label: [:0]const u8, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_halign(@ptrCast(row), gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(@ptrCast(row), 6);
    const btn = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_add_css_class(@ptrCast(btn), "suggested-action");
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", cb, user_data, null, 0);
    gtk.gtk_box_append(row, @ptrCast(btn));
    gtk.gtk_box_append(parent, @ptrCast(row));
}

fn addRowButton(row: *gtk.AdwActionRow, label: [:0]const u8, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const btn = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_set_valign(@ptrCast(btn), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(btn));
}

fn addRowSwitch(row: *gtk.AdwActionRow, active: bool, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (active) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
}

// Hex <-> GdkRGBA (accepts "#rrggbb", "#rrggbbaa", "0xrrggbbaa").
fn hexToRgba(hex: []const u8) ?gtk.GdkRGBA {
    var strip = hex;
    if (strip.len > 0 and strip[0] == '#') {
        strip = strip[1..];
    } else if (std.mem.startsWith(u8, strip, "0x")) {
        strip = strip[2..];
    }
    if (strip.len != 6 and strip.len != 8) return null;
    const v = std.fmt.parseInt(u32, strip, 16) catch return null;
    const alpha = if (strip.len == 8) @as(f32, @floatFromInt((v >> 24) & 0xff)) / 255.0 else 1.0;
    return .{
        .red = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        .green = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        .blue = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        .alpha = alpha,
    };
}

fn rgbaToHex(c: gtk.GdkRGBA, buf: []u8) []const u8 {
    const clamp = std.math.clamp;
    const r: u32 = @intFromFloat(@round(clamp(c.red, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp(c.green, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp(c.blue, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch "#000000";
}

/// Hyprland shadow colors keep their alpha as a trailing byte ("0xrrggbbaa"),
/// unlike border colors (plain "#rrggbb").
fn rgbaToShadowHex(c: gtk.GdkRGBA, buf: []u8) []const u8 {
    const clamp = std.math.clamp;
    const r: u32 = @intFromFloat(@round(clamp(c.red, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp(c.green, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp(c.blue, 0.0, 1.0) * 255.0));
    const a: u32 = @intFromFloat(@round(clamp(c.alpha, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ a, r, g, b }) catch "0xee1a1a1a";
}

fn setEntryZ(buffer: *gtk.GtkEntryBuffer, s: []const u8) void {
    var buf: [300]u8 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    gtk.gtk_entry_buffer_set_text(buffer, buf[0..n :0].ptr, @intCast(n));
}

fn entryText(entry: *gtk.GtkEntry) []const u8 {
    return std.mem.span(gtk.gtk_entry_buffer_get_text(gtk.gtk_entry_get_buffer(entry)));
}

// ---------------------------------------------------------------------
// Generic model-changing callbacks. user_data is always a stable field
// address inside hypr.state (or a static marker for enum/color targets).
// ---------------------------------------------------------------------

fn onTextChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const t: *hypr.Text = @ptrCast(@alignCast(user_data.?));
    t.set(std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
    _ = hypr.saveAll();
}

fn onIntChanged(spin: *gtk.GtkSpinButton, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const v: *i32 = @ptrCast(@alignCast(user_data.?));
    v.* = gtk.gtk_spin_button_get_value_as_int(spin);
    _ = hypr.saveAll();
}

fn onFloatChanged(spin: *gtk.GtkSpinButton, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const v: *f64 = @ptrCast(@alignCast(user_data.?));
    v.* = hg.gtk_spin_button_get_value(spin);
    _ = hypr.saveAll();
}

fn onBoolChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const v: *bool = @ptrCast(@alignCast(user_data.?));
    v.* = gtk.gtk_switch_get_active(sw) != 0;
    _ = hypr.saveAll();
}

fn onLayoutChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const v: *hypr.LayoutChoice = @ptrCast(@alignCast(user_data.?));
    v.* = enumFromIntSafe(hypr.LayoutChoice, gtk.adw_combo_row_get_selected(row)) orelse return;
    _ = hypr.saveAll();
}

/// std.meta.intToEnum was removed in Zig 0.16; range-checked replacement.
fn enumFromIntSafe(comptime T: type, v: anytype) ?T {
    const Info = @typeInfo(T).@"enum";
    const last_name = Info.fields[Info.fields.len - 1].name;
    const max_value: i128 = @intFromEnum(@field(T, last_name));
    const value: i128 = @intCast(v);
    if (value < 0 or value > max_value) return null;
    return @enumFromInt(@as(Info.tag_type, @intCast(value)));
}

const LAYOUT_LABELS = [_][*:0]const u8{ "Master", "Dwindle", "Scrolling" };

const FOLLOW_MOUSE_LABELS = [_][*:0]const u8{ "Disabled", "Follow", "Follow + raise", "Follow + raise + ws cycle" };

fn onAccelChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const t: *hypr.Text = @ptrCast(@alignCast(user_data.?));
    const idx = gtk.adw_combo_row_get_selected(row);
    t.set(switch (idx) {
        0 => "none",
        1 => "flat",
        2 => "adaptive",
        else => "flat",
    });
    _ = hypr.saveAll();
}

const ACCEL_LABELS = [_][*:0]const u8{ "None", "Flat", "Adaptive" };

fn accelIndexOf(current: []const u8) c_uint {
    if (std.mem.eql(u8, current, "none")) return 0;
    if (std.mem.eql(u8, current, "adaptive")) return 2;
    return 1;
}

// Tri-state combos (xwayland / float_state in window rules): Any / No / Yes
// <-> stored i32 -1 / 0 / 1.
const TRISTATE_LABELS = [_][*:0]const u8{ "Any", "No", "Yes" };

fn triStateIndex(v: i32) c_uint {
    return switch (v) {
        0 => 1,
        1 => 2,
        else => 0,
    };
}

fn onTriStateChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const v: *i32 = @ptrCast(@alignCast(user_data.?));
    const idx = gtk.adw_combo_row_get_selected(row);
    v.* = switch (idx) {
        0 => -1,
        1 => 0,
        2 => 1,
        else => -1,
    };
    _ = hypr.saveAll();
}

// VRR combo (monitors): Default / Off / On / Auto <-> -1 / 0 / 1 / 2.
const VRR_LABELS = [_][*:0]const u8{ "Default", "Off", "On", "Auto" };

fn vrrIndex(v: i32) c_uint {
    const clamped = @max(@min(v, 2), -1);
    return @intCast(clamped + 1);
}

fn onVrrChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const v: *i32 = @ptrCast(@alignCast(user_data.?));
    const idx = gtk.adw_combo_row_get_selected(row);
    v.* = @as(i32, @intCast(idx)) - 1;
    _ = hypr.saveAll();
}

// Color buttons (borders + shadow).
const BorderField = enum { active_border, inactive_border, shadow_color };
var f_active_border: BorderField = .active_border;
var f_inactive_border: BorderField = .inactive_border;
var f_shadow_color: BorderField = .shadow_color;

fn onBorderColorChanged(button: *gtk.GtkColorDialogButton, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const which: *const BorderField = @ptrCast(@alignCast(user_data.?));
    const rgba = gtk.gtk_color_dialog_button_get_rgba(button).*;
    var buf: [16]u8 = undefined;
    const hex = switch (which.*) {
        .shadow_color => rgbaToShadowHex(rgba, &buf),
        else => rgbaToHex(rgba, &buf),
    };
    switch (which.*) {
        .active_border => hypr.state.general.active_border.set(hex),
        .inactive_border => hypr.state.general.inactive_border.set(hex),
        .shadow_color => hypr.state.general.shadow_color.set(hex),
    }
    _ = hypr.saveAll();
}

// ---------------------------------------------------------------------
// Form-row helpers — every one appends an AdwActionRow into an
// AdwPreferencesGroup (used for on-page rows AND inside edit dialogs).
// Each connects its signal AFTER the initial value is set so construction
// doesn't fire a spurious saveAll/rebuild.
// ---------------------------------------------------------------------

fn addEntryRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, initial: []const u8, width: c_int, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), width, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    setEntryZ(buffer, initial);
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn addTextRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, target: *hypr.Text, width: c_int) void {
    addEntryRow(group, title, target.slice(), width, @ptrCast(&onTextChanged), @ptrCast(target));
}

fn addSpinRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, min: f64, max: f64, step: f64, initial: f64, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    const spin = gtk.gtk_spin_button_new_with_range(min, max, step);
    gtk.gtk_spin_button_set_value(spin, initial);
    gtk.gtk_widget_set_valign(@ptrCast(spin), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(spin), "value-changed", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(spin));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn addComboRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, labels: []const [*:0]const u8, selected: c_uint, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    var arr: [128]?[*:0]const u8 = undefined;
    const n = @min(labels.len, arr.len - 1);
    for (labels[0..n], 0..) |l, i| arr[i] = l;
    arr[n] = null;
    const row = gtk.adw_combo_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    gtk.adw_combo_row_set_model(row, @ptrCast(gtk.gtk_string_list_new(@ptrCast(&arr))));
    gtk.adw_combo_row_set_selected(row, selected);
    _ = gtk.g_signal_connect_data(@ptrCast(row), "notify::selected", cb, user_data, null, 0);
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

fn addSwitchRow(group: *gtk.AdwPreferencesGroup, title: [:0]const u8, subtitle: [:0]const u8, active: bool, cb: gtk.GCallback, user_data: ?*anyopaque) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), title);
    gtk.adw_action_row_set_subtitle(row, subtitle);
    const sw = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(sw, if (active) 1 else 0);
    gtk.gtk_widget_set_valign(@ptrCast(sw), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(sw), "notify::active", cb, user_data, null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(sw));
    gtk.adw_preferences_group_add(group, @ptrCast(row));
}

// ---------------------------------------------------------------------
// Edit-dialog scaffolding
// ---------------------------------------------------------------------

const DIALOG_KEY = "simpbar-dialog";

fn onDialogDoneClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (gtk.g_object_get_data(@ptrCast(button), DIALOG_KEY)) |d| {
        hg.adw_dialog_close(@ptrCast(@alignCast(d)));
    }
}

fn addDialogFooter(box: *gtk.GtkBox, dialog: *hg.AdwDialog) void {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_halign(@ptrCast(row), gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(@ptrCast(row), 12);
    const btn = gtk.gtk_button_new_with_label("Done");
    gtk.gtk_widget_add_css_class(@ptrCast(btn), "suggested-action");
    gtk.g_object_set_data(@ptrCast(btn), DIALOG_KEY, @ptrCast(dialog));
    _ = gtk.g_signal_connect_data(@ptrCast(btn), "clicked", @ptrCast(&onDialogDoneClicked), null, null, 0);
    gtk.gtk_box_append(row, @ptrCast(btn));
    gtk.gtk_box_append(box, @ptrCast(row));
}

fn newDialogBox() *gtk.GtkBox {
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_set_margin_top(@ptrCast(content), 12);
    gtk.gtk_widget_set_margin_bottom(@ptrCast(content), 12);
    gtk.gtk_widget_set_margin_start(@ptrCast(content), 12);
    gtk.gtk_widget_set_margin_end(@ptrCast(content), 12);
    return content;
}

fn presentDialog(parent: *anyopaque, title: [:0]const u8, content: *gtk.GtkBox, on_closed: gtk.GCallback) void {
    const d = hg.adw_dialog_new();
    hg.adw_dialog_set_title(d, title);
    hg.adw_dialog_set_content_width(d, 560);
    hg.adw_dialog_set_child(d, @ptrCast(content));
    _ = gtk.g_signal_connect_data(@ptrCast(d), "closed", on_closed, null, null, 0);
    addDialogFooter(content, d);
    hg.adw_dialog_present(d, parent);
}

// ---------------------------------------------------------------------
// Array mutation helpers (fixed-capacity model arrays)
// ---------------------------------------------------------------------

fn removeAt(comptime T: type, arr: [*]T, len: *usize, idx: usize) void {
    if (idx >= len.*) return;
    var i = idx;
    while (i + 1 < len.*) : (i += 1) arr[i] = arr[i + 1];
    len.* -= 1;
}

fn pushAt(comptime T: type, arr: [*]T, max: usize, len: *usize, v: T) ?*T {
    if (len.* >= max) return null;
    arr[len.*] = v;
    len.* += 1;
    return &arr[len.* - 1];
}

// ---------------------------------------------------------------------
// Connected-monitor discovery (hyprctl monitors -j). config_main.zig has
// the same scan; this binary can't import config_main, so it's duplicated.
// ---------------------------------------------------------------------

const MAX_EXT_MONITORS = 8;
const MonitorName = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const MonitorName) []const u8 {
        return self.buf[0..self.len];
    }
};
var monitor_names: [MAX_EXT_MONITORS]MonitorName = undefined;
var monitor_name_count: usize = 0;

fn discoverMonitorsExternal() void {
    if (monitor_name_count != 0) return;
    const output = hypr.captureOutput(&.{ "hyprctl", "monitors", "-j" }, 3000) orelse return;
    defer std.heap.c_allocator.free(output);

    const needle = "\"name\"";
    var depth: usize = 0;
    var captured_this_object = false;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const c = output[i];
        if (c == '{') {
            depth += 1;
            if (depth == 1) captured_this_object = false;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth != 1 or captured_this_object) continue;
        if (i + needle.len > output.len or !std.mem.eql(u8, output[i .. i + needle.len], needle)) continue;

        var j = i + needle.len;
        while (j < output.len and (output[j] == ' ' or output[j] == '\t')) : (j += 1) {}
        if (j >= output.len or output[j] != ':') continue;
        j += 1;
        while (j < output.len and (output[j] == ' ' or output[j] == '\t')) : (j += 1) {}
        if (j >= output.len or output[j] != '"') continue;
        j += 1;
        const value_start = j;
        while (j < output.len and output[j] != '"') : (j += 1) {}
        if (j >= output.len) continue;
        const value = output[value_start..j];

        captured_this_object = true;
        if (monitor_name_count < MAX_EXT_MONITORS) {
            const n = &monitor_names[monitor_name_count];
            const nn = @min(value.len, n.buf.len);
            @memcpy(n.buf[0..nn], value[0..nn]);
            n.len = nn;
            monitor_name_count += 1;
        }
        i = j;
    }
}

// ---------------------------------------------------------------------
// General page
// ---------------------------------------------------------------------

pub fn buildGeneralPage() *gtk.GtkBox {
    const outer = pageBox();

    const general_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(general_group, "General");
    gtk.adw_preferences_group_set_description(general_group, "Gaps, borders and the window layout algorithm.");
    addSpinRow(general_group, "Inner Gap (px)", 0, 64, 1, @floatFromInt(hypr.state.general.gaps_in), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.gaps_in));
    addSpinRow(general_group, "Outer Gap (px)", 0, 64, 1, @floatFromInt(hypr.state.general.gaps_out), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.gaps_out));
    addSpinRow(general_group, "Border Size (px)", 0, 16, 1, @floatFromInt(hypr.state.general.border_size), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.border_size));
    addComboRow(general_group, "Layout", &LAYOUT_LABELS, @intFromEnum(hypr.state.general.layout), @ptrCast(&onLayoutChanged), @ptrCast(&hypr.state.general.layout));
    addSwitchRow(general_group, "Allow Tearing", "Permit tearing (no vsync) where the window chooses to.", hypr.state.general.allow_tearing, @ptrCast(&onBoolChanged), @ptrCast(&hypr.state.general.allow_tearing));
    gtk.gtk_box_append(outer, @ptrCast(general_group));

    const decor_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(decor_group, "Decorations");
    addSpinRow(decor_group, "Rounding (px)", 0, 32, 1, @floatFromInt(hypr.state.general.rounding), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.rounding));
    addSpinRow(decor_group, "Rounding Power", 0, 10, 0.1, hypr.state.general.rounding_power, @ptrCast(&onFloatChanged), @ptrCast(&hypr.state.general.rounding_power));
    addSpinRow(decor_group, "Active Opacity", 0.1, 1, 0.05, hypr.state.general.active_opacity, @ptrCast(&onFloatChanged), @ptrCast(&hypr.state.general.active_opacity));
    addSpinRow(decor_group, "Inactive Opacity", 0.1, 1, 0.05, hypr.state.general.inactive_opacity, @ptrCast(&onFloatChanged), @ptrCast(&hypr.state.general.inactive_opacity));

    const border_row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(border_row), "Active Border Color");
    const active_dialog = gtk.gtk_color_dialog_new();
    const active_button = gtk.gtk_color_dialog_button_new(active_dialog);
    if (hexToRgba(hypr.state.general.active_border.slice())) |r| gtk.gtk_color_dialog_button_set_rgba(active_button, &r);
    gtk.gtk_widget_set_valign(@ptrCast(active_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(active_button), "notify::rgba", @ptrCast(&onBorderColorChanged), @ptrCast(&f_active_border), null, 0);
    gtk.adw_action_row_add_suffix(border_row, @ptrCast(active_button));
    gtk.adw_preferences_group_add(decor_group, @ptrCast(border_row));

    const inactive_row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(inactive_row), "Inactive Border Color");
    const inactive_dialog = gtk.gtk_color_dialog_new();
    const inactive_button = gtk.gtk_color_dialog_button_new(inactive_dialog);
    if (hexToRgba(hypr.state.general.inactive_border.slice())) |r| gtk.gtk_color_dialog_button_set_rgba(inactive_button, &r);
    gtk.gtk_widget_set_valign(@ptrCast(inactive_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(inactive_button), "notify::rgba", @ptrCast(&onBorderColorChanged), @ptrCast(&f_inactive_border), null, 0);
    gtk.adw_action_row_add_suffix(inactive_row, @ptrCast(inactive_button));
    gtk.adw_preferences_group_add(decor_group, @ptrCast(inactive_row));

    gtk.gtk_box_append(outer, @ptrCast(decor_group));

    const blur_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(blur_group, "Blur");
    addSwitchRow(blur_group, "Enable Blur", "Blur window backgrounds (\"blue\" and \"glass\" style).", hypr.state.general.blur_enabled, @ptrCast(&onBoolChanged), @ptrCast(&hypr.state.general.blur_enabled));
    addSpinRow(blur_group, "Blur Size", 0, 16, 1, @floatFromInt(hypr.state.general.blur_size), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.blur_size));
    addSpinRow(blur_group, "Blur Passes", 1, 8, 1, @floatFromInt(hypr.state.general.blur_passes), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.blur_passes));
    addSpinRow(blur_group, "Blur Vibrancy", 0, 2, 0.05, hypr.state.general.blur_vibrancy, @ptrCast(&onFloatChanged), @ptrCast(&hypr.state.general.blur_vibrancy));
    gtk.gtk_box_append(outer, @ptrCast(blur_group));

    const shadow_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(shadow_group, "Shadows");
    addSwitchRow(shadow_group, "Enable Shadows", "Window shadows (also needs shadows enabled in the compositor).", hypr.state.general.shadow_enabled, @ptrCast(&onBoolChanged), @ptrCast(&hypr.state.general.shadow_enabled));
    addSpinRow(shadow_group, "Shadow Range", 0, 32, 1, @floatFromInt(hypr.state.general.shadow_range), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.shadow_range));
    addSpinRow(shadow_group, "Shadow Render Power", 1, 8, 1, @floatFromInt(hypr.state.general.shadow_render_power), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.general.shadow_render_power));

    const shadow_color_row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(shadow_color_row), "Shadow Color");
    const shadow_dialog = gtk.gtk_color_dialog_new();
    const shadow_button = gtk.gtk_color_dialog_button_new(shadow_dialog);
    if (hexToRgba(hypr.state.general.shadow_color.slice())) |r| gtk.gtk_color_dialog_button_set_rgba(shadow_button, &r);
    gtk.gtk_widget_set_valign(@ptrCast(shadow_button), gtk.ALIGN_CENTER);
    _ = gtk.g_signal_connect_data(@ptrCast(shadow_button), "notify::rgba", @ptrCast(&onBorderColorChanged), @ptrCast(&f_shadow_color), null, 0);
    gtk.adw_action_row_add_suffix(shadow_color_row, @ptrCast(shadow_button));
    gtk.adw_preferences_group_add(shadow_group, @ptrCast(shadow_color_row));

    gtk.gtk_box_append(outer, @ptrCast(shadow_group));

    const input_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(input_group, "Input");
    addTextRow(input_group, "Keyboard Layout", &hypr.state.input.kb_layout, 120);
    addTextRow(input_group, "Keyboard Variant", &hypr.state.input.kb_variant, 120);
    addComboRow(input_group, "Mouse Follows", &FOLLOW_MOUSE_LABELS, @intCast(hypr.state.input.follow_mouse), @ptrCast(&onIntChanged), @ptrCast(&hypr.state.input.follow_mouse));
    addComboRow(input_group, "Mouse Acceleration", &ACCEL_LABELS, accelIndexOf(hypr.state.input.accel_profile.slice()), @ptrCast(&onAccelChanged), @ptrCast(&hypr.state.input.accel_profile));
    addSpinRow(input_group, "Mouse Sensitivity", -1, 1, 0.05, hypr.state.input.sensitivity, @ptrCast(&onFloatChanged), @ptrCast(&hypr.state.input.sensitivity));
    addSwitchRow(input_group, "Natural Scrolling", "Invert the touchpad scroll direction.", hypr.state.input.natural_scroll, @ptrCast(&onBoolChanged), @ptrCast(&hypr.state.input.natural_scroll));
    gtk.gtk_box_append(outer, @ptrCast(input_group));

    return outer;
}

// ---------------------------------------------------------------------
// Monitors page
// ---------------------------------------------------------------------

var g_monitors_list: ?*gtk.GtkListBox = null;

fn onMonitorEnableChanged(sw: *gtk.GtkSwitch, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const m: *hypr.Monitor = @ptrCast(@alignCast(user_data.?));
    m.enabled = gtk.gtk_switch_get_active(sw) != 0;
    _ = hypr.saveAll();
}

fn onMonitorEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const idx: usize = @intFromPtr(user_data.?);
    openMonitorDialog(@ptrCast(button), idx);
}

fn onMonitorRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const idx: usize = @intFromPtr(user_data.?);
    removeAt(hypr.Monitor, &hypr.state.monitors, &hypr.state.monitors_len, idx);
    _ = hypr.saveAll();
    rebuildMonitorsList();
}

fn rebuildMonitorsList() void {
    const listbox = g_monitors_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.monitors[0..hypr.state.monitors_len], 0..) |*m, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (m.output.len != 0) zCopy(m.output.slice(), &tzb) else "New monitor";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        const scale_txt = if (m.scale.len != 0) m.scale.slice() else "1";
        const vrr_txt: [:0]const u8 = if (m.vrr == 1) "on" else if (m.vrr == 2) "auto" else if (m.vrr == 0) "off" else "default";
        gtk.adw_action_row_set_subtitle(row, fmtZ(&sub, "{s} @ {s} scale {s}  vrr {s}", .{ m.mode.slice(), m.position.slice(), scale_txt, vrr_txt }));

        addRowSwitch(row, m.enabled, @ptrCast(&onMonitorEnableChanged), @ptrCast(m));
        addRowButton(row, "Edit", @ptrCast(&onMonitorEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onMonitorRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onMonitorsDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildMonitorsList();
}

fn openMonitorDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.monitors_len) return;
    const m = &hypr.state.monitors[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Output", &m.output, 180);
    addTextRow(group, "Mode", &m.mode, 180);
    addTextRow(group, "Position", &m.position, 180);
    addTextRow(group, "Scale", &m.scale, 80);
    addComboRow(group, "VRR", &VRR_LABELS, vrrIndex(m.vrr), @ptrCast(&onVrrChanged), @ptrCast(&m.vrr));
    addSwitchRow(group, "Enabled", "Write this monitor to the config.", m.enabled, @ptrCast(&onBoolChanged), @ptrCast(&m.enabled));
    gtk.gtk_box_append(content, @ptrCast(group));
    presentDialog(parent, "Edit Monitor", content, @ptrCast(&onMonitorsDialogClosed));
}

fn onMonitorAddClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.monitors_len >= hypr.MAX_MONITORS) return;
    discoverMonitorsExternal();
    const m = pushAt(hypr.Monitor, &hypr.state.monitors, hypr.MAX_MONITORS, &hypr.state.monitors_len, .{ .enabled = true });
    if (m) |mm| {
        if (monitor_name_count > 0) mm.output.set(monitor_names[0].slice());
        _ = hypr.saveAll();
        rebuildMonitorsList();
    }
}

pub fn buildMonitorsPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Monitors");
    gtk.adw_preferences_group_set_description(group, "Written via hl.monitor(). Reload Hyprland (or let its config auto-reload) to apply.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_monitors_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_monitors_list.?));
    rebuildMonitorsList();

    appendActionButton(outer, "Add Monitor", @ptrCast(&onMonitorAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Animations page
// ---------------------------------------------------------------------

var g_curves_list: ?*gtk.GtkListBox = null;
var g_leaves_list: ?*gtk.GtkListBox = null;

const CURVE_TYPE_LABELS = [_][*:0]const u8{ "Bezier", "Spring" };

fn onCurveTypeChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const c: *hypr.Curve = @ptrCast(@alignCast(user_data.?));
    c.ctype = enumFromIntSafe(hypr.CurveType, gtk.adw_combo_row_get_selected(row)) orelse .bezier;
    _ = hypr.saveAll();
}

fn curveSubtitle(buf: []u8, c: *const hypr.Curve) [*:0]const u8 {
    return switch (c.ctype) {
        .bezier => fmtZ(buf, "bezier  x {d:.2} {d:.2}  y {d:.2} {d:.2}", .{ c.x1, c.x2, c.y1, c.y2 }),
        .spring => fmtZ(buf, "spring  mass {d:.2}  stiffness {d:.2}  dampening {d:.2}", .{ c.mass, c.stiffness, c.dampening }),
    };
}

fn onCurveEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openCurveDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onCurveRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.Curve, &hypr.state.anim.curves, &hypr.state.anim.curves_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildCurvesList();
}

fn rebuildCurvesList() void {
    const listbox = g_curves_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.anim.curves[0..hypr.state.anim.curves_len], 0..) |*c, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), zCopy(c.name.slice(), &tzb));
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, curveSubtitle(&sub, c));
        addRowButton(row, "Edit", @ptrCast(&onCurveEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onCurveRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onCurveDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildCurvesList();
}

fn openCurveDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.anim.curves_len) return;
    const c = &hypr.state.anim.curves[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Name", &c.name, 160);
    addComboRow(group, "Type", &CURVE_TYPE_LABELS, @intFromEnum(c.ctype), @ptrCast(&onCurveTypeChanged), @ptrCast(c));

    const bezier_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(bezier_group, "Bezier");
    addSpinRow(bezier_group, "Control Point 1 X", -2, 2, 0.05, c.x1, @ptrCast(&onFloatChanged), @ptrCast(&c.x1));
    addSpinRow(bezier_group, "Control Point 1 Y", -2, 2, 0.05, c.y1, @ptrCast(&onFloatChanged), @ptrCast(&c.y1));
    addSpinRow(bezier_group, "Control Point 2 X", -2, 2, 0.05, c.x2, @ptrCast(&onFloatChanged), @ptrCast(&c.x2));
    addSpinRow(bezier_group, "Control Point 2 Y", -2, 2, 0.05, c.y2, @ptrCast(&onFloatChanged), @ptrCast(&c.y2));

    const spring_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(spring_group, "Spring");
    addSpinRow(spring_group, "Mass", 0.1, 100, 0.5, c.mass, @ptrCast(&onFloatChanged), @ptrCast(&c.mass));
    addSpinRow(spring_group, "Stiffness", 0, 1000, 5, c.stiffness, @ptrCast(&onFloatChanged), @ptrCast(&c.stiffness));
    addSpinRow(spring_group, "Dampening", 0, 1000, 5, c.dampening, @ptrCast(&onFloatChanged), @ptrCast(&c.dampening));

    gtk.gtk_box_append(content, @ptrCast(group));
    gtk.gtk_box_append(content, @ptrCast(bezier_group));
    gtk.gtk_box_append(content, @ptrCast(spring_group));
    presentDialog(parent, "Edit Curve", content, @ptrCast(&onCurveDialogClosed));
}

fn onCurveAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.anim.curves_len >= hypr.MAX_CURVES) return;
    const c = pushAt(hypr.Curve, &hypr.state.anim.curves, hypr.MAX_CURVES, &hypr.state.anim.curves_len, .{});
    if (c) |cc| {
        cc.name.set("custom");
        _ = hypr.saveAll();
        rebuildCurvesList();
        openCurveDialog(@ptrCast(button), hypr.state.anim.curves_len - 1);
    }
}

// "default" + every named curve, as AdwComboRow labels.
fn leafCurveLabels(scratch: *[hypr.MAX_CURVES + 1][64]u8, out: [][*:0]const u8) usize {
    if (out.len == 0) return 0;
    out[0] = "default";
    var n: usize = 1;
    for (hypr.state.anim.curves[0..hypr.state.anim.curves_len], 0..) |*c, i| {
        if (n >= out.len) break;
        out[n] = zCopy(c.name.slice(), &scratch[i]);
        n += 1;
    }
    return n;
}

fn leafCurveIndex(curve: []const u8) c_uint {
    if (std.mem.eql(u8, curve, "default")) return 0;
    for (hypr.state.anim.curves[0..hypr.state.anim.curves_len], 0..) |*c, i| {
        if (std.mem.eql(u8, curve, c.name.slice())) return @intCast(i + 1);
    }
    return 0;
}

fn onLeafCurveChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const l: *hypr.Leaf = @ptrCast(@alignCast(user_data.?));
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx == 0) {
        l.curve.set("default");
    } else {
        const cidx = idx - 1;
        if (cidx < hypr.state.anim.curves_len) l.curve.set(hypr.state.anim.curves[cidx].name.slice());
    }
    _ = hypr.saveAll();
}

fn onLeafEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openLeafDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onLeafRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.Leaf, &hypr.state.anim.leaves, &hypr.state.anim.leaves_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildLeavesList();
}

fn rebuildLeavesList() void {
    const listbox = g_leaves_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.anim.leaves[0..hypr.state.anim.leaves_len], 0..) |*l, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), zCopy(l.leaf.slice(), &tzb));
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, fmtZ(&sub, "speed {d:.1}  curve {s}  style {s}", .{ l.speed, l.curve.slice(), l.style.slice() }));
        addRowSwitch(row, l.enabled, @ptrCast(&onBoolChanged), @ptrCast(&l.enabled));
        addRowButton(row, "Edit", @ptrCast(&onLeafEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onLeafRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onLeafDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildLeavesList();
}

fn openLeafDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.anim.leaves_len) return;
    const l = &hypr.state.anim.leaves[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Leaf", &l.leaf, 160);
    addSwitchRow(group, "Enabled", "Emit hl.animation() for this leaf.", l.enabled, @ptrCast(&onBoolChanged), @ptrCast(&l.enabled));
    addSpinRow(group, "Speed", 0, 20, 0.5, l.speed, @ptrCast(&onFloatChanged), @ptrCast(&l.speed));
    var scratch: [hypr.MAX_CURVES + 1][64]u8 = undefined;
    var labels: [hypr.MAX_CURVES + 1][*:0]const u8 = undefined;
    const n = leafCurveLabels(&scratch, &labels);
    addComboRow(group, "Curve", labels[0..n], leafCurveIndex(l.curve.slice()), @ptrCast(&onLeafCurveChanged), @ptrCast(l));
    addTextRow(group, "Style", &l.style, 200);
    gtk.gtk_box_append(content, @ptrCast(group));
    presentDialog(parent, "Edit Animation Leaf", content, @ptrCast(&onLeafDialogClosed));
}

fn onLeafAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.anim.leaves_len >= hypr.MAX_LEAVES) return;
    const l = pushAt(hypr.Leaf, &hypr.state.anim.leaves, hypr.MAX_LEAVES, &hypr.state.anim.leaves_len, .{ .enabled = true });
    if (l) |ll| {
        ll.leaf.set("customLeaf");
        ll.curve.set("default");
        _ = hypr.saveAll();
        rebuildLeavesList();
        openLeafDialog(@ptrCast(button), hypr.state.anim.leaves_len - 1);
    }
}

pub fn buildAnimationsPage() *gtk.GtkBox {
    const outer = pageBox();

    const anim_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(anim_group, "Animations");
    addSwitchRow(anim_group, "Enable Animations", "Master switch, sets hl.animation(\"global\", ...).", hypr.state.anim.enabled, @ptrCast(&onBoolChanged), @ptrCast(&hypr.state.anim.enabled));
    gtk.gtk_box_append(outer, @ptrCast(anim_group));

    sectionHeading(outer, "Curves");
    g_curves_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_curves_list.?));
    rebuildCurvesList();
    appendActionButton(outer, "Add Curve", @ptrCast(&onCurveAddClicked), null);

    sectionHeading(outer, "Animation Leaves");
    g_leaves_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_leaves_list.?));
    rebuildLeavesList();
    appendActionButton(outer, "Add Leaf", @ptrCast(&onLeafAddClicked), null);

    return outer;
}

// ---------------------------------------------------------------------
// Keybinds page
// ---------------------------------------------------------------------

const BIND_ACTION_LABELS = blk: {
    const Info = @typeInfo(hypr.BindAction).@"enum";
    var arr: [Info.fields.len][*:0]const u8 = undefined;
    for (Info.fields, 0..) |f, i| {
        arr[i] = @field(hypr.BindAction, f.name).displayName();
    }
    break :blk arr;
};

var g_binds_list: ?*gtk.GtkListBox = null;

fn onBindActionChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const b: *hypr.Bind = @ptrCast(@alignCast(user_data.?));
    b.action = enumFromIntSafe(hypr.BindAction, gtk.adw_combo_row_get_selected(row)) orelse .exec;
    _ = hypr.saveAll();
}

fn onBindEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openBindDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onBindRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.Bind, &hypr.state.binds, &hypr.state.binds_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildBindsList();
}

fn rebuildBindsList() void {
    const listbox = g_binds_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.binds[0..hypr.state.binds_len], 0..) |*b, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (b.combo.len != 0) zCopy(b.combo.slice(), &tzb) else "Mouse bind";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, fmtZ(&sub, "{s}{s}", .{ b.action.displayName(), if (b.arg.len != 0) b.arg.slice() else "" }));
        addRowSwitch(row, b.enabled, @ptrCast(&onBoolChanged), @ptrCast(&b.enabled));
        addRowButton(row, "Edit", @ptrCast(&onBindEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onBindRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onBindDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildBindsList();
}

fn openBindDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.binds_len) return;
    const b = &hypr.state.binds[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Combo", &b.combo, 200);
    addComboRow(group, "Action", &BIND_ACTION_LABELS, @intFromEnum(b.action), @ptrCast(&onBindActionChanged), @ptrCast(b));
    addTextRow(group, "Argument", &b.arg, 300);
    addSwitchRow(group, "Locked", "Binds while the keyboard is locked (e.g. screen blank).", b.locked, @ptrCast(&onBoolChanged), @ptrCast(&b.locked));
    addSwitchRow(group, "Repeating", "Repeats while held (e.g. workspace/move binds).", b.repeating, @ptrCast(&onBoolChanged), @ptrCast(&b.repeating));
    addSwitchRow(group, "Mouse",
        "Mouse bind: combo is a button like <code>BTN_LEFT</code>; leave Combo empty and enter the button here.",
        b.mouse, @ptrCast(&onBoolChanged), @ptrCast(&b.mouse));
    gtk.gtk_box_append(content, @ptrCast(group));
    presentDialog(parent, if (b.combo.len != 0) "Edit Keybind" else "Edit Mouse Bind", content, @ptrCast(&onBindDialogClosed));
}

fn onBindAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.binds_len >= hypr.MAX_BINDS) return;
    const b = pushAt(hypr.Bind, &hypr.state.binds, hypr.MAX_BINDS, &hypr.state.binds_len, .{ .enabled = true });
    if (b) |bb| {
        bb.combo.set("SUPER, A");
        _ = hypr.saveAll();
        rebuildBindsList();
        openBindDialog(@ptrCast(button), hypr.state.binds_len - 1);
    }
}

pub fn buildKeybindsPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Binds");
    gtk.adw_preferences_group_set_description(group, "One row per hl.bind() (combo, dispatcher, flags). Combo uses Hyprland syntax, e.g. SUPER, SHIFT, A. Empty combo = mouse bind.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_binds_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_binds_list.?));
    rebuildBindsList();
    appendActionButton(outer, "Add Keybind", @ptrCast(&onBindAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Window rules page
// ---------------------------------------------------------------------

var g_wrules_list: ?*gtk.GtkListBox = null;

fn winRuleSubtitle(scratch: []u8, r: *const hypr.WindowRule) [*:0]const u8 {
    var i: usize = 0;
    var first = true;
    const parts = [_]struct { tag: []const u8, v: []const u8 }{
        .{ .tag = "class", .v = r.class.slice() },
        .{ .tag = "title", .v = r.title.slice() },
        .{ .tag = "app_id", .v = r.app_id.slice() },
        .{ .tag = "workspace", .v = r.workspace.slice() },
        .{ .tag = "xwayland", .v = if (r.xwayland == 1) "yes" else if (r.xwayland == 0) "no" else "" },
        .{ .tag = "float", .v = if (r.float_state == 1) "yes" else if (r.float_state == 0) "no" else "" },
    };
    for (parts) |p| {
        if (p.v.len == 0) continue;
        const sep: [:0]const u8 = if (first) "" else ", ";
        const written = std.fmt.bufPrint(scratch[i..], "{s}{s} {s}", .{ sep, p.tag, p.v }) catch return "";
        i += written.len;
        first = false;
    }
    if (r.opts.len != 0) {
        const sep: [:0]const u8 = if (first) "" else "  =>  ";
        const written = std.fmt.bufPrint(scratch[i..], "{s}{s}", .{ sep, r.opts.slice() }) catch return "";
        i += written.len;
    }
    if (i == 0) {
        i = (std.fmt.bufPrint(scratch[0..], "no match fields", .{}) catch return "").len;
    }
    scratch[i] = 0;
    return scratch[0..i :0].ptr;
}

fn onWRuleEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openWindowRuleDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onWRuleRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.WindowRule, &hypr.state.wrules, &hypr.state.wrules_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildWRulesList();
}

fn rebuildWRulesList() void {
    const listbox = g_wrules_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.wrules[0..hypr.state.wrules_len], 0..) |*r, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (r.name.len != 0) zCopy(r.name.slice(), &tzb) else "Window rule";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, winRuleSubtitle(&sub, r));
        addRowSwitch(row, r.enabled, @ptrCast(&onBoolChanged), @ptrCast(&r.enabled));
        addRowButton(row, "Edit", @ptrCast(&onWRuleEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onWRuleRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onWRuleDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildWRulesList();
}

fn openWindowRuleDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.wrules_len) return;
    const r = &hypr.state.wrules[idx];
    const content = newDialogBox();
    const match_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(match_group, "Match");
    addTextRow(match_group, "Name", &r.name, 220);
    addTextRow(match_group, "Class", &r.class, 220);
    addTextRow(match_group, "Title", &r.title, 220);
    addTextRow(match_group, "App ID", &r.app_id, 220);
    addTextRow(match_group, "Workspace", &r.workspace, 120);
    addComboRow(match_group, "XWayland", &TRISTATE_LABELS, triStateIndex(r.xwayland), @ptrCast(&onTriStateChanged), @ptrCast(&r.xwayland));
    addComboRow(match_group, "Floating", &TRISTATE_LABELS, triStateIndex(r.float_state), @ptrCast(&onTriStateChanged), @ptrCast(&r.float_state));

    const opts_group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(opts_group, "Options");
    addTextRow(opts_group, "Rule Options", &r.opts, 300);
    gtk.gtk_box_append(content, @ptrCast(match_group));
    gtk.gtk_box_append(content, @ptrCast(opts_group));
    presentDialog(parent, "Edit Window Rule", content, @ptrCast(&onWRuleDialogClosed));
}

fn onWRuleAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.wrules_len >= hypr.MAX_RULES) return;
    const r = pushAt(hypr.WindowRule, &hypr.state.wrules, hypr.MAX_RULES, &hypr.state.wrules_len, .{ .enabled = true });
    if (r) |rr| {
        rr.name.set("New rule");
        _ = hypr.saveAll();
        rebuildWRulesList();
        openWindowRuleDialog(@ptrCast(button), hypr.state.wrules_len - 1);
    }
}

pub fn buildWindowRulesPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Window Rules");
    gtk.adw_preferences_group_set_description(group, "One row per hl.window_rule(). Fill only the match fields you want; leave others empty.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_wrules_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_wrules_list.?));
    rebuildWRulesList();
    appendActionButton(outer, "Add Window Rule", @ptrCast(&onWRuleAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Workspace rules page
// ---------------------------------------------------------------------

var g_wsrules_list: ?*gtk.GtkListBox = null;

fn monitorComboLabels(scratch: *[hypr.MAX_RULES + 1][64]u8, out: [][*:0]const u8) usize {
    if (out.len == 0) return 0;
    out[0] = "Default";
    var n: usize = 1;
    for (monitor_names[0..monitor_name_count], 0..) |*m, i| {
        if (n >= out.len) break;
        out[n] = zCopy(m.slice(), &scratch[i]);
        n += 1;
    }
    return n;
}

fn monitorIndex(sel: []const u8) c_uint {
    for (monitor_names[0..monitor_name_count], 0..) |*m, i| {
        if (std.mem.eql(u8, sel, m.slice())) return @intCast(i + 1);
    }
    return 0;
}

fn onRuleMonitorChanged(row: *gtk.AdwComboRow, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const r: *hypr.WorkspaceRule = @ptrCast(@alignCast(user_data.?));
    const idx = gtk.adw_combo_row_get_selected(row);
    if (idx == 0) {
        r.monitor.set("");
    } else {
        const midx = idx - 1;
        if (midx < monitor_name_count) r.monitor.set(monitor_names[midx].slice());
    }
    _ = hypr.saveAll();
}

fn onWSRuleEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openWorkspaceRuleDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onWSRuleRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.WorkspaceRule, &hypr.state.wsrules, &hypr.state.wsrules_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildWSRulesList();
}

fn rebuildWSRulesList() void {
    const listbox = g_wsrules_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.wsrules[0..hypr.state.wsrules_len], 0..) |*r, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (r.workspace.len != 0) zCopy(r.workspace.slice(), &tzb) else "Workspace rule";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, fmtZ(&sub, "monitor {s}{s}{s}", .{
            if (r.monitor.len != 0) r.monitor.slice() else "default",
            if (r.opts.len != 0) "  =>  " else "",
            r.opts.slice(),
        }));
        addRowSwitch(row, r.enabled, @ptrCast(&onBoolChanged), @ptrCast(&r.enabled));
        addRowButton(row, "Edit", @ptrCast(&onWSRuleEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onWSRuleRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onWSRuleDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildWSRulesList();
}

fn openWorkspaceRuleDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.wsrules_len) return;
    const r = &hypr.state.wsrules[idx];
    discoverMonitorsExternal();
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Workspace", &r.workspace, 120);
    var scratch: [hypr.MAX_RULES + 1][64]u8 = undefined;
    var labels: [hypr.MAX_RULES + 1][*:0]const u8 = undefined;
    const n = monitorComboLabels(&scratch, &labels);
    addComboRow(group, "Monitor", labels[0..n], monitorIndex(r.monitor.slice()), @ptrCast(&onRuleMonitorChanged), @ptrCast(r));
    addTextRow(group, "Options", &r.opts, 300);

    const group2 = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_description(group2, "Later rules override earlier ones for the same workspace.");
    gtk.gtk_box_append(content, @ptrCast(group));
    gtk.gtk_box_append(content, @ptrCast(group2));
    presentDialog(parent, "Edit Workspace Rule", content, @ptrCast(&onWSRuleDialogClosed));
}

fn onWSRuleAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.wsrules_len >= hypr.MAX_RULES) return;
    const r = pushAt(hypr.WorkspaceRule, &hypr.state.wsrules, hypr.MAX_RULES, &hypr.state.wsrules_len, .{ .enabled = true });
    if (r) |rr| {
        rr.workspace.set("1");
        _ = hypr.saveAll();
        rebuildWSRulesList();
        openWorkspaceRuleDialog(@ptrCast(button), hypr.state.wsrules_len - 1);
    }
}

pub fn buildWorkspaceRulesPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Workspace Rules");
    gtk.adw_preferences_group_set_description(group, "One row per hl.workspace_rule(), e.g. prefer monitor, gaps, rounding.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_wsrules_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_wsrules_list.?));
    rebuildWSRulesList();
    appendActionButton(outer, "Add Workspace Rule", @ptrCast(&onWSRuleAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Layer rules page
// ---------------------------------------------------------------------

var g_lrules_list: ?*gtk.GtkListBox = null;

fn onLRuleEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openLayerRuleDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onLRuleRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.LayerRule, &hypr.state.lrules, &hypr.state.lrules_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildLRulesList();
}

fn rebuildLRulesList() void {
    const listbox = g_lrules_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.lrules[0..hypr.state.lrules_len], 0..) |*r, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (r.namespace.len != 0) zCopy(r.namespace.slice(), &tzb) else "Layer rule";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, fmtZ(&sub, "{s}{s}{s}", .{
            if (r.name.len != 0) r.name.slice() else "",
            if (r.opts.len != 0) "  =>  " else "",
            r.opts.slice(),
        }));
        addRowSwitch(row, r.enabled, @ptrCast(&onBoolChanged), @ptrCast(&r.enabled));
        addRowButton(row, "Edit", @ptrCast(&onLRuleEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onLRuleRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onLRuleDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildLRulesList();
}

fn openLayerRuleDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.lrules_len) return;
    const r = &hypr.state.lrules[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Name", &r.name, 200);
    addTextRow(group, "Namespace", &r.namespace, 200);
    addTextRow(group, "Options", &r.opts, 300);
    gtk.gtk_box_append(content, @ptrCast(group));
    presentDialog(parent, "Edit Layer Rule", content, @ptrCast(&onLRuleDialogClosed));
}

fn onLRuleAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.lrules_len >= hypr.MAX_RULES) return;
    const r = pushAt(hypr.LayerRule, &hypr.state.lrules, hypr.MAX_RULES, &hypr.state.lrules_len, .{ .enabled = true, .name = .{}, .namespace = .{}, .opts = .{} });
    if (r) |rr| {
        rr.namespace.set("waybar");
        rr.opts.set("animation unset, noanim");
        _ = hypr.saveAll();
        rebuildLRulesList();
        openLayerRuleDialog(@ptrCast(button), hypr.state.lrules_len - 1);
    }
}

pub fn buildLayerRulesPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Layer Rules");
    gtk.adw_preferences_group_set_description(group, "One row per hl.layer_rule(), applied to bars and overlays by namespace.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_lrules_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_lrules_list.?));
    rebuildLRulesList();
    appendActionButton(outer, "Add Layer Rule", @ptrCast(&onLRuleAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Autostart page
// ---------------------------------------------------------------------

var g_autostart_list: ?*gtk.GtkListBox = null;

fn onAutostartChanged(buffer: *gtk.GtkEntryBuffer, _: *gtk.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    const t: *hypr.Text = @ptrCast(@alignCast(user_data.?));
    t.set(std.mem.span(gtk.gtk_entry_buffer_get_text(buffer)));
    _ = hypr.saveAll();
}

fn addAutostartRow(listbox: *gtk.GtkListBox, idx: usize) void {
    const row = gtk.adw_action_row_new();
    gtk.adw_preferences_row_set_title(@ptrCast(row), "Startup Command");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_set_size_request(@ptrCast(entry), 320, -1);
    gtk.gtk_widget_set_valign(@ptrCast(entry), gtk.ALIGN_CENTER);
    const buffer = gtk.gtk_entry_get_buffer(entry);
    setEntryZ(buffer, hypr.state.autostart[idx].slice());
    _ = gtk.g_signal_connect_data(@ptrCast(buffer), "notify::text", @ptrCast(&onAutostartChanged), @ptrCast(&hypr.state.autostart[idx]), null, 0);
    gtk.adw_action_row_add_suffix(row, @ptrCast(entry));
    addRowButton(row, "Remove", @ptrCast(&onAutostartRemoveClicked), @ptrFromInt(idx));
    gtk.gtk_list_box_append(listbox, @ptrCast(row));
}

fn onAutostartRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.Text, &hypr.state.autostart, &hypr.state.autostart_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildAutostartList();
}

fn rebuildAutostartList() void {
    const listbox = g_autostart_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (0..hypr.state.autostart_len) |i| addAutostartRow(listbox, i);
}

fn onAutostartAddClicked(_: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.autostart_len >= hypr.MAX_AUTOSTART) return;
    const t = pushAt(hypr.Text, &hypr.state.autostart, hypr.MAX_AUTOSTART, &hypr.state.autostart_len, .{});
    if (t) |tt| {
        tt.set("sh -c \"\"");
        _ = hypr.saveAll();
        rebuildAutostartList();
    }
}

pub fn buildAutostartPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Autostart");
    gtk.adw_preferences_group_set_description(group, "Commands starting with Hyprland (exec'd in order). Keep them short and non-blocking.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_autostart_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_autostart_list.?));
    rebuildAutostartList();
    appendActionButton(outer, "Add Command", @ptrCast(&onAutostartAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Env page
// ---------------------------------------------------------------------

var g_envs_list: ?*gtk.GtkListBox = null;

fn onEnvEditClicked(button: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    openEnvDialog(@ptrCast(button), @intFromPtr(user_data.?));
}

fn onEnvRemoveClicked(_: *gtk.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    removeAt(hypr.EnvVar, &hypr.state.envs, &hypr.state.envs_len, @intFromPtr(user_data.?));
    _ = hypr.saveAll();
    rebuildEnvsList();
}

fn rebuildEnvsList() void {
    const listbox = g_envs_list orelse return;
    gtk.gtk_list_box_remove_all(listbox);
    for (hypr.state.envs[0..hypr.state.envs_len], 0..) |*e, i| {
        const row = gtk.adw_action_row_new();
        var tzb: [MAX_TITLE]u8 = undefined;
        const title: [*:0]const u8 = if (e.key.len != 0) zCopy(e.key.slice(), &tzb) else "env var";
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        var sub: [MAX_ZBUF]u8 = undefined;
        gtk.adw_action_row_set_subtitle(row, zCopy(e.value.slice(), &sub));
        addRowButton(row, "Edit", @ptrCast(&onEnvEditClicked), @ptrFromInt(i));
        addRowButton(row, "Remove", @ptrCast(&onEnvRemoveClicked), @ptrFromInt(i));
        gtk.gtk_list_box_append(listbox, @ptrCast(row));
    }
}

fn onEnvDialogClosed(_: *hg.AdwDialog, _: ?*anyopaque) callconv(.c) void {
    rebuildEnvsList();
}

fn openEnvDialog(parent: *anyopaque, idx: usize) void {
    if (idx >= hypr.state.envs_len) return;
    const e = &hypr.state.envs[idx];
    const content = newDialogBox();
    const group = gtk.adw_preferences_group_new();
    addTextRow(group, "Variable", &e.key, 180);
    addTextRow(group, "Value", &e.value, 300);
    gtk.gtk_box_append(content, @ptrCast(group));
    presentDialog(parent, "Edit Environment Variable", content, @ptrCast(&onEnvDialogClosed));
}

fn onEnvAddClicked(button: *gtk.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (hypr.state.envs_len >= hypr.MAX_ENV) return;
    const e = pushAt(hypr.EnvVar, &hypr.state.envs, hypr.MAX_ENV, &hypr.state.envs_len, .{ .key = .{}, .value = .{} });
    if (e) |ee| {
        ee.key.set("VARIABLE");
        _ = hypr.saveAll();
        rebuildEnvsList();
        openEnvDialog(@ptrCast(button), hypr.state.envs_len - 1);
    }
}

pub fn buildEnvPage() *gtk.GtkBox {
    const outer = pageBox();
    const group = gtk.adw_preferences_group_new();
    gtk.adw_preferences_group_set_title(group, "Environment Variables");
    gtk.adw_preferences_group_set_description(group, "hl.env() calls, applied before Hyprland starts.");
    gtk.gtk_box_append(outer, @ptrCast(group));

    g_envs_list = newListBox();
    gtk.gtk_box_append(outer, @ptrCast(g_envs_list.?));
    rebuildEnvsList();
    appendActionButton(outer, "Add Environment Variable", @ptrCast(&onEnvAddClicked), null);
    return outer;
}

// ---------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------

pub fn init() void {
    hypr.loadOrInit();
    _ = hypr.ensureBootstrapped();
    discoverMonitorsExternal();
}

pub const pages = struct {
    pub const names = [_][:0]const u8{ "General", "Monitors", "Animations", "Keybinds", "Window Rules", "Workspace Rules", "Layer Rules", "Autostart", "Environment" };
    pub const icons = [_][:0]const u8{ "emblem-system-symbolic", "video-display-symbolic", "media-playlist-repeat-symbolic", "input-keyboard-symbolic", "preferences-system-windows-symbolic", "gnome-panel-window-list-symbolic", "layer-group-symbolic", "system-run-symbolic", "preferences-system-symbolic" };

    pub fn widgets() [9]*gtk.GtkBox {
        return .{
            buildGeneralPage(),
            buildMonitorsPage(),
            buildAnimationsPage(),
            buildKeybindsPage(),
            buildWindowRulesPage(),
            buildWorkspaceRulesPage(),
            buildLayerRulesPage(),
            buildAutostartPage(),
            buildEnvPage(),
        };
    }
};
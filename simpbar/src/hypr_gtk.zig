// Additional hand-written GTK4 / libadwaita extern bindings used by the
// Hyprland settings pages (hypr_pages.zig). Extends welcome_gtk.zig's set —
// kept separate so the shared bar/welcome/config binaries' binding file stays
// the minimal common surface, and this file is only imported by the config
// binary's Hyprland pages. Every symbol here was verified with `nm -D` on the
// installed libgtk-4.so.1 / libadwaita-1.so.0 before binding.
//
// Same ABI rationale as welcome_gtk.zig: GObject single inheritance means a
// bare @ptrCast between "compatible" opaque types is always valid, so we
// reuse welcome_gtk.zig's opaque types (AdwActionRow, GtkListBox, ...) for
// subclasses without declaring new ones.

const gtk = @import("welcome_gtk.zig");

pub const AdwSwitchRow = opaque {};
pub const AdwDialog = opaque {};

pub extern "c" fn adw_switch_row_new() *AdwSwitchRow;
pub extern "c" fn adw_switch_row_set_active(self: *AdwSwitchRow, is_active: c_int) void;
pub extern "c" fn adw_switch_row_get_active(self: *AdwSwitchRow) c_int;

pub extern "c" fn adw_dialog_new() *AdwDialog;
pub extern "c" fn adw_dialog_set_title(self: *AdwDialog, title: [*:0]const u8) void;
pub extern "c" fn adw_dialog_set_content_width(self: *AdwDialog, width: c_int) void;
pub extern "c" fn adw_dialog_set_content_height(self: *AdwDialog, height: c_int) void;
pub extern "c" fn adw_dialog_set_child(self: *AdwDialog, child: ?*anyopaque) void;
pub extern "c" fn adw_dialog_present(self: *AdwDialog, parent: *anyopaque) void;
pub extern "c" fn adw_dialog_close(self: *AdwDialog) void;

pub extern "c" fn gtk_button_set_label(self: *anyopaque, label: [*:0]const u8) void;
pub extern "c" fn gtk_list_box_remove(self: *gtk.GtkListBox, child: *anyopaque) void;
pub extern "c" fn gtk_list_box_row_set_selectable(self: *gtk.GtkListBoxRow, selectable: c_int) void;
pub extern "c" fn gtk_widget_set_tooltip_text(self: *anyopaque, text: [*:0]const u8) void;

// GtkSpinButton — gtk_spin_button_get_value_as_int is already exposed by
// welcome_gtk.zig; the float getter is needed for the opacity/sensitivity/
// spring-spin fields on the Hyprland pages.
pub extern "c" fn gtk_spin_button_get_value(self: *gtk.GtkSpinButton) f64;

// GtkHeaderBar child packing — used by config_main.zig to add a "Reload
// Hyprland" action button to the content header bar.
pub extern "c" fn gtk_header_bar_pack_start(self: *anyopaque, child: *anyopaque) void;
pub extern "c" fn adw_header_bar_pack_end(self: *anyopaque, child: *anyopaque) void;
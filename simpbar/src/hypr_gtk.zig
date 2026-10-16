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

// --- Monitor arrange canvas (Hyprland + Mango pages) -------------------
// GtkDrawingArea + GtkGestureClick/Drag + cairo, verified via `nm -D`
// against libgtk-4.so.1 / libcairo.so.2 on this machine.

pub const GtkDrawingArea = opaque {};
pub const GtkGestureClick = opaque {};
pub const GtkGestureDrag = opaque {};
pub const CairoT = opaque {};

pub extern "c" fn gtk_drawing_area_new() *GtkDrawingArea;
pub extern "c" fn gtk_drawing_area_set_content_width(self: *GtkDrawingArea, width: c_int) void;
pub extern "c" fn gtk_drawing_area_set_content_height(self: *GtkDrawingArea, height: c_int) void;
pub extern "c" fn gtk_drawing_area_set_draw_func(
    self: *GtkDrawingArea,
    draw_func: ?*const fn (*GtkDrawingArea, *CairoT, c_int, c_int, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
pub extern "c" fn gtk_widget_queue_draw(self: *anyopaque) void;

pub extern "c" fn gtk_gesture_click_new() *GtkGestureClick;
pub extern "c" fn gtk_gesture_drag_new() *GtkGestureDrag;
pub extern "c" fn gtk_gesture_drag_get_offset(self: *GtkGestureDrag, x: ?*f64, y: ?*f64) void;
pub extern "c" fn gtk_event_controller_get_widget(self: *anyopaque) ?*anyopaque;

// cairo (libcairo.so.2)
pub extern "c" fn cairo_set_source_rgb(cr: *CairoT, r: f64, g: f64, b: f64) void;
pub extern "c" fn cairo_set_source_rgba(cr: *CairoT, r: f64, g: f64, b: f64, a: f64) void;
pub extern "c" fn cairo_rectangle(cr: *CairoT, x: f64, y: f64, w: f64, h: f64) void;
pub extern "c" fn cairo_fill(cr: *CairoT) void;
pub extern "c" fn cairo_stroke(cr: *CairoT) void;
pub extern "c" fn cairo_set_line_width(cr: *CairoT, w: f64) void;
pub extern "c" fn cairo_move_to(cr: *CairoT, x: f64, y: f64) void;
pub extern "c" fn cairo_show_text(cr: *CairoT, text: [*:0]const u8) void;
pub extern "c" fn cairo_select_font_face(cr: *CairoT, family: [*:0]const u8, slant: c_int, weight: c_int) void;
pub extern "c" fn cairo_set_font_size(cr: *CairoT, size: f64) void;
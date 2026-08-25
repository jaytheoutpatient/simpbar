// Hand-written GTK4 / libadwaita / GObject bindings — plain `extern "c" fn`
// declarations against the real .so ABI, no @cImport. Header parsing
// (@cImport of gtk/gtk.h + adwaita.h) fails with ~13k translate-c errors
// because GLib's G_GNUC_BEGIN_IGNORE_DEPRECATIONS macros expand to
// back-to-back _Pragma(...) invocations translate-c can't parse — the same
// class of problem gdkpixbuf_shim.c works around for gdk-pixbuf, just at a
// much larger scale here. The GObject C ABI itself is stable and doesn't
// need a shim: every object is just an opaque pointer, and every "is-a"
// relationship (AdwActionRow is-a AdwPreferencesRow is-a GtkListBoxRow is-a
// GtkWidget is-a GObject, ...) is a plain pointer reinterpretation with no
// offset adjustment, since GObject uses single inheritance with the parent
// struct embedded at offset 0. So a bare @ptrCast between "compatible"
// opaque types below is always valid as long as the runtime object really
// is an instance of that type (or a subclass of it).

pub const GObject = opaque {};
pub const GParamSpec = opaque {};
pub const GApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkApplication = opaque {};
pub const GtkSettings = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkImage = opaque {};
pub const GtkPicture = opaque {};
pub const GtkSwitch = opaque {};
pub const GtkButton = opaque {};
pub const GtkSpinner = opaque {};
pub const GtkStringList = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkStack = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const AdwApplication = opaque {};
pub const AdwApplicationWindow = opaque {};
pub const AdwPreferencesGroup = opaque {};
pub const AdwActionRow = opaque {};
pub const AdwComboRow = opaque {};
pub const AdwToolbarView = opaque {};
pub const AdwHeaderBar = opaque {};
pub const AdwNavigationPage = opaque {};
pub const AdwNavigationSplitView = opaque {};

// GCallback is GLib's generic no-arg/no-return function-pointer typedef —
// every signal handler is cast to this at the g_signal_connect_data call
// site, regardless of its real signature.
pub const GCallback = ?*const fn () callconv(.c) void;

// GtkOrientation
pub const ORIENTATION_HORIZONTAL: c_int = 0;
pub const ORIENTATION_VERTICAL: c_int = 1;

// GtkAlign
pub const ALIGN_CENTER: c_int = 3;

// GtkJustification
pub const JUSTIFY_CENTER: c_int = 2;

// GtkContentFit
pub const CONTENT_FIT_CONTAIN: c_int = 1;

// GtkSelectionMode
pub const SELECTION_SINGLE: c_int = 1;

// GtkPolicyType
pub const POLICY_ALWAYS: c_int = 0;
pub const POLICY_AUTOMATIC: c_int = 1;
pub const POLICY_NEVER: c_int = 2;

// GtkStackTransitionType
pub const STACK_TRANSITION_CROSSFADE: c_int = 1;

// GLib / GObject
pub extern "c" fn g_signal_connect_data(instance: *anyopaque, detailed_signal: [*:0]const u8, c_handler: GCallback, data: ?*anyopaque, destroy_data: ?*anyopaque, connect_flags: c_uint) c_ulong;
pub extern "c" fn g_object_set(object: *anyopaque, first_property_name: [*:0]const u8, ...) void;
pub extern "c" fn g_idle_add(function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern "c" fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]const ?[*:0]u8) c_int;
pub extern "c" fn g_application_quit(application: *GApplication) void;

// GtkSettings
pub extern "c" fn gtk_settings_get_default() ?*GtkSettings;

// GtkWidget (base)
pub extern "c" fn gtk_widget_set_valign(widget: *anyopaque, @"align": c_int) void;
pub extern "c" fn gtk_widget_set_halign(widget: *anyopaque, @"align": c_int) void;
pub extern "c" fn gtk_widget_set_margin_top(widget: *anyopaque, margin: c_int) void;
pub extern "c" fn gtk_widget_set_margin_bottom(widget: *anyopaque, margin: c_int) void;
pub extern "c" fn gtk_widget_set_margin_start(widget: *anyopaque, margin: c_int) void;
pub extern "c" fn gtk_widget_set_margin_end(widget: *anyopaque, margin: c_int) void;
pub extern "c" fn gtk_widget_add_css_class(widget: *anyopaque, css_class: [*:0]const u8) void;
pub extern "c" fn gtk_widget_set_size_request(widget: *anyopaque, width: c_int, height: c_int) void;
pub extern "c" fn gtk_widget_set_sensitive(widget: *anyopaque, sensitive: c_int) void;
pub extern "c" fn gtk_widget_set_vexpand(widget: *anyopaque, expand: c_int) void;
pub extern "c" fn gtk_widget_set_hexpand(widget: *anyopaque, expand: c_int) void;

// GtkBox
pub extern "c" fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkBox;
pub extern "c" fn gtk_box_append(box: *GtkBox, child: *anyopaque) void;

// GtkPicture / GtkImage
pub extern "c" fn gtk_picture_new_for_filename(filename: [*:0]const u8) *GtkPicture;
pub extern "c" fn gtk_picture_set_content_fit(self: *GtkPicture, content_fit: c_int) void;
pub extern "c" fn gtk_image_new_from_icon_name(icon_name: [*:0]const u8) *GtkImage;
pub extern "c" fn gtk_image_set_pixel_size(self: *GtkImage, pixel_size: c_int) void;

// GtkLabel
pub extern "c" fn gtk_label_new(str: ?[*:0]const u8) *GtkLabel;
pub extern "c" fn gtk_label_set_justify(self: *GtkLabel, jtype: c_int) void;
pub extern "c" fn gtk_label_set_wrap(self: *GtkLabel, wrap: c_int) void;
pub extern "c" fn gtk_label_set_xalign(self: *GtkLabel, xalign: f32) void;

// GtkSwitch
pub extern "c" fn gtk_switch_new() *GtkSwitch;
pub extern "c" fn gtk_switch_set_active(self: *GtkSwitch, is_active: c_int) void;
pub extern "c" fn gtk_switch_get_active(self: *GtkSwitch) c_int;

// GtkButton
pub extern "c" fn gtk_button_new_with_label(label: [*:0]const u8) *GtkButton;

// GtkSpinner
pub extern "c" fn gtk_spinner_new() *GtkSpinner;
pub extern "c" fn gtk_spinner_start(self: *GtkSpinner) void;
pub extern "c" fn gtk_spinner_stop(self: *GtkSpinner) void;

// GtkStringList
pub extern "c" fn gtk_string_list_new(strings: ?[*]const ?[*:0]const u8) *GtkStringList;

// GtkListBox / GtkListBoxRow
pub extern "c" fn gtk_list_box_new() *GtkListBox;
pub extern "c" fn gtk_list_box_append(self: *GtkListBox, child: *anyopaque) void;
pub extern "c" fn gtk_list_box_set_selection_mode(self: *GtkListBox, mode: c_int) void;
pub extern "c" fn gtk_list_box_select_row(self: *GtkListBox, row: ?*GtkListBoxRow) void;
pub extern "c" fn gtk_list_box_get_row_at_index(self: *GtkListBox, index: c_int) ?*GtkListBoxRow;
pub extern "c" fn gtk_list_box_row_new() *GtkListBoxRow;
pub extern "c" fn gtk_list_box_row_set_child(self: *GtkListBoxRow, child: ?*anyopaque) void;
pub extern "c" fn gtk_list_box_row_set_activatable(self: *anyopaque, activatable: c_int) void;

// GtkStack
pub extern "c" fn gtk_stack_new() *GtkStack;
pub extern "c" fn gtk_stack_add_named(self: *GtkStack, child: *anyopaque, name: ?[*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_stack_set_visible_child_name(self: *GtkStack, name: [*:0]const u8) void;
pub extern "c" fn gtk_stack_set_transition_type(self: *GtkStack, transition: c_int) void;

// GtkScrolledWindow
pub extern "c" fn gtk_scrolled_window_new() *GtkScrolledWindow;
pub extern "c" fn gtk_scrolled_window_set_policy(self: *GtkScrolledWindow, hscrollbar_policy: c_int, vscrollbar_policy: c_int) void;
pub extern "c" fn gtk_scrolled_window_set_child(self: *GtkScrolledWindow, child: ?*anyopaque) void;

// GtkWindow
pub extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn gtk_window_set_default_size(window: *anyopaque, width: c_int, height: c_int) void;
pub extern "c" fn gtk_window_present(window: *anyopaque) void;

// AdwApplication
pub extern "c" fn adw_application_new(application_id: [*:0]const u8, flags: c_uint) *AdwApplication;

// AdwApplicationWindow
pub extern "c" fn adw_application_window_new(app: *anyopaque) *AdwApplicationWindow;
pub extern "c" fn adw_application_window_set_content(self: *AdwApplicationWindow, content: ?*anyopaque) void;

// AdwPreferencesGroup
pub extern "c" fn adw_preferences_group_new() *AdwPreferencesGroup;
pub extern "c" fn adw_preferences_group_set_title(self: *AdwPreferencesGroup, title: [*:0]const u8) void;
pub extern "c" fn adw_preferences_group_set_description(self: *AdwPreferencesGroup, description: [*:0]const u8) void;
pub extern "c" fn adw_preferences_group_add(self: *AdwPreferencesGroup, child: *anyopaque) void;
pub extern "c" fn adw_preferences_group_remove(self: *AdwPreferencesGroup, child: *anyopaque) void;

// AdwPreferencesRow / AdwActionRow
pub extern "c" fn adw_action_row_new() *AdwActionRow;
pub extern "c" fn adw_preferences_row_set_title(self: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn adw_action_row_set_subtitle(self: *AdwActionRow, subtitle: [*:0]const u8) void;
pub extern "c" fn adw_action_row_set_icon_name(self: *AdwActionRow, icon_name: ?[*:0]const u8) void;
pub extern "c" fn adw_action_row_add_suffix(self: *AdwActionRow, widget: *anyopaque) void;
pub extern "c" fn adw_action_row_set_activatable_widget(self: *AdwActionRow, widget: ?*anyopaque) void;

// AdwComboRow
pub extern "c" fn adw_combo_row_new() *AdwComboRow;
pub extern "c" fn adw_combo_row_set_model(self: *AdwComboRow, model: ?*anyopaque) void;
pub extern "c" fn adw_combo_row_get_selected(self: *AdwComboRow) c_uint;
pub extern "c" fn adw_combo_row_set_selected(self: *AdwComboRow, position: c_uint) void;

// AdwToolbarView / AdwHeaderBar
pub extern "c" fn adw_toolbar_view_new() *AdwToolbarView;
pub extern "c" fn adw_toolbar_view_add_top_bar(self: *AdwToolbarView, widget: *anyopaque) void;
pub extern "c" fn adw_toolbar_view_set_content(self: *AdwToolbarView, content: ?*anyopaque) void;
pub extern "c" fn adw_header_bar_new() *AdwHeaderBar;

// AdwNavigationPage / AdwNavigationSplitView
pub extern "c" fn adw_navigation_page_new(child: *anyopaque, title: [*:0]const u8) *AdwNavigationPage;
pub extern "c" fn adw_navigation_split_view_new() *AdwNavigationSplitView;
pub extern "c" fn adw_navigation_split_view_set_sidebar(self: *AdwNavigationSplitView, sidebar: ?*AdwNavigationPage) void;
pub extern "c" fn adw_navigation_split_view_set_content(self: *AdwNavigationSplitView, content: ?*AdwNavigationPage) void;

// GdkRGBA — unlike every other type in this file, this is a real,
// ABI-stable plain struct (not an opaque GObject pointer): GTK4's actual
// public layout, four packed floats. Safe to mirror directly.
pub const GdkRGBA = extern struct {
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32,
};

// GtkColorDialog / GtkColorDialogButton — used by the Appearance tab's per-
// color pickers (config_main.zig). GtkColorDialogButton owns a reference to
// the dialog it's constructed with; we only ever need one dialog per button
// (no shared-dialog reuse), so callers just pass a fresh gtk_color_dialog_new()
// to each button.
pub const GtkColorDialog = opaque {};
pub const GtkColorDialogButton = opaque {};
pub extern "c" fn gtk_color_dialog_new() *GtkColorDialog;
pub extern "c" fn gtk_color_dialog_button_new(dialog: ?*GtkColorDialog) *GtkColorDialogButton;
pub extern "c" fn gtk_color_dialog_button_set_rgba(self: *GtkColorDialogButton, rgba: *const GdkRGBA) void;
pub extern "c" fn gtk_color_dialog_button_get_rgba(self: *GtkColorDialogButton) *GdkRGBA;

// GtkSpinButton — used by the Appearance tab's numeric spacing fields.
pub const GtkSpinButton = opaque {};
pub extern "c" fn gtk_spin_button_new_with_range(min: f64, max: f64, step: f64) *GtkSpinButton;
pub extern "c" fn gtk_spin_button_get_value_as_int(self: *GtkSpinButton) c_int;
pub extern "c" fn gtk_spin_button_set_value(self: *GtkSpinButton, value: f64) void;

// GtkEntry / GtkEntryBuffer — used by the Modules tab's custom-script
// label/command fields (config_main.zig). GtkEntry owns its buffer
// internally by default (gtk_entry_new() creates one for you); we read/write
// through the buffer rather than the entry widget itself since that's where
// the "notify::text" signal actually lives.
pub const GtkEntry = opaque {};
pub const GtkEntryBuffer = opaque {};
pub extern "c" fn gtk_entry_new() *GtkEntry;
pub extern "c" fn gtk_entry_get_buffer(self: *GtkEntry) *GtkEntryBuffer;
pub extern "c" fn gtk_entry_buffer_get_text(self: *GtkEntryBuffer) [*:0]const u8;
pub extern "c" fn gtk_entry_buffer_set_text(self: *GtkEntryBuffer, text: [*:0]const u8, len: c_int) void;

// --- Drag-and-drop (Modules tab row reordering, config_main.zig) ----------
//
// Every symbol here was verified against this machine's real installed
// headers/.gir before binding (not guessed) — a wrong signal signature is a
// silent ABI mismatch that corrupts the stack/crashes at runtime:
//   - "drop"'s real signature (gtk/gtkdroptarget.c's doc example + the .gir
//     <glib:signal name="drop"> block) is
//     gboolean (GtkDropTarget*, const GValue*, gdouble x, gdouble y, gpointer)
//     — NOT the raw-bytes shape a first guess might reach for.
//   - "prepare"'s real signature (.gir <glib:signal name="prepare"> under
//     the DragSource class) is
//     GdkContentProvider* (GtkDragSource*, gdouble x, gdouble y, gpointer).
//   - gdk_content_provider_new_for_value/gtk_drop_target_new/
//     gtk_list_box_remove_all/gtk_list_box_get_row_at_y/
//     gtk_widget_add_controller and the g_value_*/g_object_*_data symbols
//     below were all confirmed present via `nm -D` against the actual
//     linked libgtk-4.so.1/libgobject-2.0.so.0 on this machine.
//
// Drag payload: a raw process-local pointer (the dragged AdwActionRow's
// backing ModuleRow) boxed in a G_TYPE_POINTER GValue, rather than
// GBytes/mime-type plumbing — this is the standard GTK4 pattern for
// same-process, same-widget-tree reordering (the exact thing GDK restricts
// G_TYPE_POINTER content to: it can never round-trip through a different
// process, which is exactly the scope wanted here) and avoids the much
// larger binding surface GBytes or a real serialized format would need.

// GValue — a real, ABI-stable plain struct (not opaque), matching GLib's
// public layout: a GType tag followed by a 2-word union big enough for
// every fundamental type glib/gobject/gvalue.h defines (int/long/int64/
// float/double/pointer, ...). We only ever populate/read it as
// G_TYPE_POINTER here, but the struct's layout doesn't depend on which
// union member is active.
pub const GValue = extern struct {
    g_type: usize = 0,
    data: [2]u64 = .{ 0, 0 },
};

// Fundamental GType IDs are compile-time constants in glib's gtype.h
// (`G_TYPE_MAKE_FUNDAMENTAL(x) = x << G_TYPE_FUNDAMENTAL_SHIFT(2)`), not
// something you look up at runtime — G_TYPE_POINTER is fundamental #17.
pub const G_TYPE_POINTER: usize = 17 << 2;

// GdkDragAction (gdk/gdkenums.h): GDK_ACTION_MOVE = 1 << 1.
pub const GDK_ACTION_MOVE: c_uint = 2;

pub extern "c" fn g_value_init(value: *GValue, g_type: usize) *GValue;
pub extern "c" fn g_value_set_pointer(value: *GValue, v_pointer: ?*anyopaque) void;
pub extern "c" fn g_value_get_pointer(value: *const GValue) ?*anyopaque;

pub extern "c" fn g_object_set_data(object: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern "c" fn g_object_get_data(object: *anyopaque, key: [*:0]const u8) ?*anyopaque;

pub const GdkContentProvider = opaque {};
pub extern "c" fn gdk_content_provider_new_for_value(value: *const GValue) *GdkContentProvider;

pub const GtkDragSource = opaque {};
pub extern "c" fn gtk_drag_source_new() *GtkDragSource;
pub extern "c" fn gtk_drag_source_set_actions(self: *GtkDragSource, actions: c_uint) void;

pub const GtkDropTarget = opaque {};
pub extern "c" fn gtk_drop_target_new(gtype: usize, actions: c_uint) *GtkDropTarget;

pub extern "c" fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;

pub extern "c" fn gtk_list_box_remove_all(self: *GtkListBox) void;
pub extern "c" fn gtk_list_box_get_row_at_y(self: *GtkListBox, y: c_int) ?*GtkListBoxRow;

// GtkImage — set_from_icon_name lets the Shortcuts tab (config_main.zig)
// live-update an icon preview as the user types an icon name, reusing GTK's
// own icon-theme resolution (fallback/sizing/dark-light variants) rather
// than pulling icontheme.zig's raw-pixel decoder (built for the bar's SHM
// buffer, not a GTK widget) into this binary.
pub extern "c" fn gtk_image_set_from_icon_name(self: *GtkImage, icon_name: ?[*:0]const u8) void;

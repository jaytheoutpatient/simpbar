#!/usr/bin/env python3
"""
Simpbar Welcome — a small GTK4 + libadwaita companion app for the
simpbar Hyprland setup (github.com/jaytheoutpatient/simpbar).

Usage:
    simpbar_welcome.py              Show the window normally.
    simpbar_welcome.py --autostart  Only show the window if it hasn't
                                     been shown before (first-login use).
"""

import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

APP_ID = "dev.jaytheoutpatient.simpbar.Welcome"
FIRST_RUN_MARKER = Path.home() / ".config" / "simpbar" / "welcome-shown"
LOGO_PATH = Path.home() / ".local" / "share" / "simpbar" / "logo.png"
REPO_URL = "https://github.com/jaytheoutpatient/simpbar"
CONTACT_EMAIL = "jaytheoutpatient@protonmail.com"
HYPRLAND_CONF = "~/.config/hypr/hyprland.lua"

KEYBINDINGS = [
    ("SUPER", "Windows key"),
    ("SUPER + Enter", "Open terminal"),
    ("SUPER + Space", "Open Rofi"),
    ("SUPER + E", "Open Nautilus"),
    ("SUPER + Q", "Exit the application"),
    ("SUPER + 1 – 0", "Switch workspaces"),
]

SETUP_ACTIONS = [
    (
        "Run the simpbar install script",
        "Installs/updates packages, configs, and themes. Opens in a terminal "
        "since it needs your password and asks a few questions.",
        "utilities-terminal-symbolic",
        ["foot", "-e", "bash", "-lc",
         "curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/"
         "simpbar/main/install.sh | bash; echo; read -p 'Press Enter to close...'"],
    ),
    (
        "Update Simpbar and Arch Linux",
        "Runs a full system update, then re-fetches the latest install script "
        "and configs from GitHub. Opens in a terminal — asks a few of the same "
        "setup questions again as part of the refresh.",
        "software-update-available-symbolic",
        ["foot", "-e", "bash", "-lc",
         "sudo pacman -Syu --noconfirm; echo; "
         "curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/"
         "simpbar/main/install.sh | bash; echo; read -p 'Press Enter to close...'"],
    ),
    (
        "Pick a wallpaper",
        "Opens waypaper, pointed at ~/Pictures/Wallpaper by default.",
        "preferences-desktop-wallpaper-symbolic",
        ["waypaper"],
    ),
    (
        "Customize GTK theme, icons and cursor",
        "Opens nwg-look. Dracula GTK/icons and Bibata Modern Classic are "
        "already set as defaults.",
        "preferences-desktop-theme-symbolic",
        ["nwg-look"],
    ),
    (
        "Tweak Hyprland settings",
        "Opens HyprMod — keybinds, monitors, animations, window rules, and "
        "more, with a live preview. Writes to its own config, doesn't touch "
        "hyprland.lua directly.",
        "preferences-desktop-display-symbolic",
        ["hyprmod"],
    ),
    (
        "Adjust audio devices and volumes",
        "Opens pavucontrol.",
        "audio-speakers-symbolic",
        ["pavucontrol"],
    ),
]


def launch(argv: list[str]) -> None:
    """Fire-and-forget launch of an external command."""
    try:
        subprocess.Popen(argv, start_new_session=True)
    except FileNotFoundError:
        print(f"simpbar-welcome: couldn't find '{argv[0]}' on PATH", file=sys.stderr)


class WelcomePage(Gtk.Box):
    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.set_valign(Gtk.Align.CENTER)
        self.set_margin_top(48)
        self.set_margin_bottom(48)
        self.set_margin_start(36)
        self.set_margin_end(36)

        if LOGO_PATH.exists():
            logo = Gtk.Picture.new_for_filename(str(LOGO_PATH))
            logo.set_content_fit(Gtk.ContentFit.CONTAIN)
            logo.set_size_request(128, 128)
            logo.set_halign(Gtk.Align.CENTER)
            self.append(logo)
        else:
            icon = Gtk.Image.new_from_icon_name("preferences-desktop-display-symbolic")
            icon.set_pixel_size(64)
            icon.add_css_class("dim-label")
            self.append(icon)

        title = Gtk.Label(label="Welcome to Simpbar")
        title.add_css_class("title-1")
        self.append(title)

        subtitle = Gtk.Label(
            label="Hello and welcome to Simpbar hope you'll find your\n"
            "home here!, If there is any bugs or any suggestions you want\n"
            "please send me a email in the links page!"
        )
        subtitle.add_css_class("dim-label")
        subtitle.set_justify(Gtk.Justification.CENTER)
        subtitle.set_wrap(True)
        self.append(subtitle)


class SetupPage(Gtk.Box):
    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.set_margin_top(24)
        self.set_margin_bottom(24)
        self.set_margin_start(24)
        self.set_margin_end(24)

        group = Adw.PreferencesGroup(title="Setup and quick actions")
        for title, subtitle, icon_name, argv in SETUP_ACTIONS:
            row = Adw.ActionRow(title=title, subtitle=subtitle)
            row.set_icon_name(icon_name)

            button = Gtk.Button(label="Launch")
            button.add_css_class("flat")
            button.set_valign(Gtk.Align.CENTER)
            button.connect("clicked", lambda _b, a=argv: launch(a))

            row.add_suffix(button)
            row.set_activatable_widget(button)
            group.add(row)

        self.append(group)


class KeybindingsPage(Gtk.Box):
    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.set_margin_top(24)
        self.set_margin_bottom(24)
        self.set_margin_start(24)
        self.set_margin_end(24)

        group = Adw.PreferencesGroup(title="Keybindings")
        for combo, action in KEYBINDINGS:
            row = Adw.ActionRow(title=combo, subtitle=action)
            row.add_css_class("property")
            group.add(row)
        self.append(group)

        config_group = Adw.PreferencesGroup(
            title="Editing your config",
            description=f"Change keybindings or monitor setup with:\nnvim {HYPRLAND_CONF}",
        )
        self.append(config_group)


class AboutPage(Gtk.Box):
    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(24)
        self.set_margin_bottom(24)
        self.set_margin_start(24)
        self.set_margin_end(24)

        group = Adw.PreferencesGroup(title="Links")

        repo_row = Adw.ActionRow(
            title="GitHub repository",
            subtitle=REPO_URL,
            activatable=True,
        )
        repo_row.set_icon_name("system-search-symbolic")
        repo_row.connect("activated", lambda _r: launch(["xdg-open", REPO_URL]))
        group.add(repo_row)

        issues_row = Adw.ActionRow(
            title="Report an issue",
            subtitle=f"{REPO_URL}/issues",
            activatable=True,
        )
        issues_row.set_icon_name("dialog-warning-symbolic")
        issues_row.connect(
            "activated", lambda _r: launch(["xdg-open", f"{REPO_URL}/issues"])
        )
        group.add(issues_row)

        email_row = Adw.ActionRow(
            title="Email — bugs and suggestions",
            subtitle=CONTACT_EMAIL,
            activatable=True,
        )
        email_row.set_icon_name("mail-send-symbolic")
        email_row.connect(
            "activated", lambda _r: launch(["xdg-open", f"mailto:{CONTACT_EMAIL}"])
        )
        group.add(email_row)

        self.append(group)


class WelcomeWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="Simpbar Welcome")
        self.set_default_size(760, 520)

        split_view = Adw.NavigationSplitView()
        self.set_content(split_view)

        # Sidebar
        sidebar_list = Gtk.ListBox()
        sidebar_list.add_css_class("navigation-sidebar")
        sidebar_list.set_selection_mode(Gtk.SelectionMode.SINGLE)

        self.pages = {
            "Welcome": WelcomePage(),
            "Setup": SetupPage(),
            "Keybindings": KeybindingsPage(),
            "About": AboutPage(),
        }
        icons = {
            "Welcome": "go-home-symbolic",
            "Setup": "emblem-system-symbolic",
            "Keybindings": "input-keyboard-symbolic",
            "About": "help-about-symbolic",
        }

        for name in self.pages:
            row = Gtk.ListBoxRow()
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            box.set_margin_top(8)
            box.set_margin_bottom(8)
            box.set_margin_start(12)
            box.set_margin_end(12)
            box.append(Gtk.Image.new_from_icon_name(icons[name]))
            box.append(Gtk.Label(label=name, xalign=0))
            row.set_child(box)
            row.page_name = name
            sidebar_list.append(row)

        sidebar_list.connect("row-selected", self._on_row_selected)

        sidebar_toolbar = Adw.ToolbarView()
        sidebar_toolbar.add_top_bar(Adw.HeaderBar())
        sidebar_toolbar.set_content(sidebar_list)

        sidebar_page = Adw.NavigationPage(title="Simpbar", child=sidebar_toolbar)
        split_view.set_sidebar(sidebar_page)

        # Content
        self.content_stack = Gtk.Stack()
        self.content_stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        for name, widget in self.pages.items():
            self.content_stack.add_named(widget, name)

        content_toolbar = Adw.ToolbarView()
        content_toolbar.add_top_bar(Adw.HeaderBar())
        content_toolbar.set_content(self.content_stack)

        content_page = Adw.NavigationPage(title="", child=content_toolbar)
        split_view.set_content(content_page)

        sidebar_list.select_row(sidebar_list.get_row_at_index(0))

        self.connect("close-request", self._on_close_request)

    def _on_row_selected(self, _listbox: Gtk.ListBox, row: Gtk.ListBoxRow) -> None:
        if row is not None:
            self.content_stack.set_visible_child_name(row.page_name)

    def _on_close_request(self, *_args) -> bool:
        mark_shown()
        return False  # allow the window to actually close


def mark_shown() -> None:
    FIRST_RUN_MARKER.parent.mkdir(parents=True, exist_ok=True)
    FIRST_RUN_MARKER.touch(exist_ok=True)


class WelcomeApp(Adw.Application):
    def __init__(self, autostart_mode: bool) -> None:
        super().__init__(application_id=APP_ID)
        self.autostart_mode = autostart_mode

    def do_activate(self) -> None:
        if self.autostart_mode and FIRST_RUN_MARKER.exists():
            # Already shown once before — nothing to do on this login.
            self.quit()
            return

        # The system-wide icon theme (Dracula) doesn't have full coverage
        # of generic symbolic icon names like "audio-speakers-symbolic".
        # Force Adwaita for this app specifically — doesn't touch the
        # system-wide setting, just makes our own icons resolve reliably.
        settings = Gtk.Settings.get_default()
        if settings is not None:
            settings.set_property("gtk-icon-theme-name", "Adwaita")

        win = self.props.active_window or WelcomeWindow(self)
        win.present()


def main() -> int:
    autostart_mode = "--autostart" in sys.argv
    app = WelcomeApp(autostart_mode)
    return app.run([])


if __name__ == "__main__":
    sys.exit(main())

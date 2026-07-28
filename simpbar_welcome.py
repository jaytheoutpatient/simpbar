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
HYPRLAND_LUA_PATH = Path.home() / ".config" / "hypr" / "hyprland.lua"
AUTOSTART_LINE = 'hl.exec_cmd("simpbar-welcome")'


def is_autostart_enabled() -> bool:
    try:
        return AUTOSTART_LINE in HYPRLAND_LUA_PATH.read_text()
    except OSError:
        return False


def set_autostart_enabled(enabled: bool) -> bool:
    """Add or remove AUTOSTART_LINE in hyprland.lua. Returns True on success."""
    try:
        if enabled:
            HYPRLAND_LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
            content = HYPRLAND_LUA_PATH.read_text() if HYPRLAND_LUA_PATH.exists() else ""
            if AUTOSTART_LINE not in content:
                if content and not content.endswith("\n"):
                    content += "\n"
                content += AUTOSTART_LINE + "\n"
                HYPRLAND_LUA_PATH.write_text(content)
        elif HYPRLAND_LUA_PATH.exists():
            lines = HYPRLAND_LUA_PATH.read_text().splitlines(keepends=True)
            lines = [ln for ln in lines if ln.strip() != AUTOSTART_LINE]
            HYPRLAND_LUA_PATH.write_text("".join(lines))
        return True
    except OSError as exc:
        print(f"simpbar-welcome: couldn't update hyprland.lua: {exc}", file=sys.stderr)
        return False


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
        "Check for updates now",
        "Checks for Arch/AUR package updates and new commits on the simpbar "
        "repo, and sends a notification if it finds anything. Runs "
        "automatically every few hours in the background too.",
        "view-refresh-symbolic",
        ["simpbar-check-updates"],
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


EDITOR_OPTIONS = ["Neovim", "Gedit", "Kate", "Zed", "VS Code"]
EDITOR_PACKAGES = {
    "Neovim": "neovim",
    "Gedit": "gedit",
    "Kate": "kate",
    "Zed": "zed",
    "VS Code": "visual-studio-code-bin",
}
EDITOR_NEEDS_AUR = {"VS Code"}  # not in the official repos


def build_editor_install_argv(name: str) -> list[str]:
    pkg = EDITOR_PACKAGES[name]
    if name in EDITOR_NEEDS_AUR:
        install_cmd = (
            f"if command -v yay >/dev/null; then yay -S --noconfirm --needed {pkg}; "
            f"elif command -v paru >/dev/null; then paru -S --noconfirm --needed {pkg}; "
            f'else echo "No AUR helper found — install {pkg} manually"; fi'
        )
    else:
        install_cmd = f"sudo pacman -S --noconfirm --needed {pkg}"
    full_cmd = f"{install_cmd}; echo; read -p 'Press Enter to close...'"
    return ["foot", "-e", "bash", "-lc", full_cmd]


REMOVE_NEOVIM_ARGV = [
    "foot", "-e", "bash", "-lc",
    "sudo pacman -Rns --noconfirm neovim; "
    "rm -rf ~/.config/nvim ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim; "
    "echo; read -p 'Press Enter to close...'",
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
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=18)
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

        editor_group = Adw.PreferencesGroup(
            title="Text editors",
            description="Neovim + LazyVim comes installed by default.",
        )

        install_row = Adw.ComboRow(
            title="Install a text editor",
            subtitle="Gedit and Kate are GUI editors; VS Code installs via the AUR.",
            model=Gtk.StringList.new(EDITOR_OPTIONS),
        )
        install_button = Gtk.Button(label="Install")
        install_button.add_css_class("flat")
        install_button.set_valign(Gtk.Align.CENTER)
        install_button.connect(
            "clicked",
            lambda _b: launch(
                build_editor_install_argv(EDITOR_OPTIONS[install_row.get_selected()])
            ),
        )
        install_row.add_suffix(install_button)
        editor_group.add(install_row)

        remove_row = Adw.ActionRow(
            title="Remove Neovim and LazyVim",
            subtitle="Uninstalls neovim and deletes its config/data/cache directories.",
        )
        remove_row.set_icon_name("user-trash-symbolic")
        remove_button = Gtk.Button(label="Remove")
        remove_button.add_css_class("flat")
        remove_button.add_css_class("destructive-action")
        remove_button.set_valign(Gtk.Align.CENTER)
        remove_button.connect("clicked", lambda _b: launch(REMOVE_NEOVIM_ARGV))
        remove_row.add_suffix(remove_button)
        editor_group.add(remove_row)

        self.append(editor_group)


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

        overlay = Gtk.Overlay()
        overlay.set_child(split_view)
        self.set_content(overlay)

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

        # Floating "launch on startup" toggle, bottom-right, visible on every page.
        autostart_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        autostart_box.add_css_class("osd")
        autostart_box.add_css_class("toolbar")
        autostart_box.set_halign(Gtk.Align.END)
        autostart_box.set_valign(Gtk.Align.END)
        autostart_box.set_margin_end(16)
        autostart_box.set_margin_bottom(16)

        autostart_label = Gtk.Label(label="Launch on startup")
        autostart_switch = Gtk.Switch()
        autostart_switch.set_valign(Gtk.Align.CENTER)
        autostart_switch.set_active(is_autostart_enabled())
        autostart_switch.connect("notify::active", self._on_autostart_toggled)

        autostart_box.append(autostart_label)
        autostart_box.append(autostart_switch)
        overlay.add_overlay(autostart_box)

        sidebar_list.select_row(sidebar_list.get_row_at_index(0))

        self.connect("close-request", self._on_close_request)

    def _on_autostart_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        set_autostart_enabled(switch.get_active())

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

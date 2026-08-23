#!/usr/bin/env python3
"""
Simpbar Welcome — a small GTK4 + libadwaita companion app for the
simpbar Hyprland setup (github.com/jaytheoutpatient/simpbar).

Usage:
    simpbar_welcome.py              Show the window normally.
    simpbar_welcome.py --autostart  Only show the window if it hasn't
                                     been shown before (first-login use).
"""

import shutil
import subprocess
import sys
import threading
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
DISCORD_URL = "https://discord.gg/sAMMXSPx9R"
HYPRLAND_CONF = "~/.config/hypr/hyprland.lua"
HYPRLAND_LUA_PATH = Path.home() / ".config" / "hypr" / "hyprland.lua"

# Autostart commands must be wrapped in hl.on("hyprland.start", ...) — a bare
# top-level hl.exec_cmd(...) line would re-run on every config reload (Hyprland
# reparses hyprland.lua on every save), not just once at actual startup.
SIMPBAR_WELCOME_AUTOSTART_LINE = 'hl.on("hyprland.start", function() hl.exec_cmd("simpbar-welcome") end)'
STEAM_SILENT_AUTOSTART_LINE = 'hl.on("hyprland.start", function() hl.exec_cmd("steam -silent") end)'
EASYEFFECTS_AUTOSTART_LINE = 'hl.on("hyprland.start", function() hl.exec_cmd("easyeffects --gapplication-service") end)'


def is_hypr_line_enabled(line: str) -> bool:
    try:
        return line in HYPRLAND_LUA_PATH.read_text()
    except OSError:
        return False


def set_hypr_line_enabled(line: str, enabled: bool) -> bool:
    """Add or remove an exact line in hyprland.lua. Returns True on success."""
    try:
        if enabled:
            HYPRLAND_LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
            content = HYPRLAND_LUA_PATH.read_text() if HYPRLAND_LUA_PATH.exists() else ""
            if line not in content:
                if content and not content.endswith("\n"):
                    content += "\n"
                content += line + "\n"
                HYPRLAND_LUA_PATH.write_text(content)
        elif HYPRLAND_LUA_PATH.exists():
            lines = HYPRLAND_LUA_PATH.read_text().splitlines(keepends=True)
            lines = [ln for ln in lines if ln.strip() != line]
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
        "Update Arch Linux",
        "Runs a plain system update (sudo pacman -Syu) — no config/script "
        "refresh, just your packages. Opens in a terminal for the password prompt.",
        "system-software-update-symbolic",
        ["foot", "-e", "bash", "-lc",
         "sudo pacman -Syu --noconfirm; echo; read -p 'Press Enter to close...'"],
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
        "Check for updates now",
        "Checks for Arch/AUR package updates and new commits on the simpbar "
        "repo, and sends a notification if it finds anything. Runs "
        "automatically every few hours in the background too.",
        "view-refresh-symbolic",
        ["simpbar-check-updates"],
    ),
    (
        "Browse and install software",
        "Opens Bazaar, a graphical software manager for finding and "
        "installing Flatpak apps.",
        "system-software-install-symbolic",
        ["bazaar"],
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


SIMPBAR_CONFIG_DIR = Path.home() / ".config" / "simpbar"
BROWSER_PREF_FILE = SIMPBAR_CONFIG_DIR / "browser-choice"
DISCORD_PREF_FILE = SIMPBAR_CONFIG_DIR / "discord-choice"

# name -> (binary to launch, package to install, needs an AUR helper)
PIN_BROWSER_OPTIONS = ["Brave", "Zen Browser", "Vivaldi", "Microsoft Edge", "LibreWolf", "Firefox"]
PIN_BROWSER_INFO = {
    "Brave": ("brave", "brave-bin", True),
    "Zen Browser": ("zen-browser", "zen-browser-bin", True),
    "Vivaldi": ("vivaldi-stable", "vivaldi", True),
    "Microsoft Edge": ("microsoft-edge-stable", "microsoft-edge-stable-bin", True),
    "LibreWolf": ("librewolf", "librewolf-bin", True),
    "Firefox": ("firefox", "firefox", False),
}

PIN_DISCORD_OPTIONS = ["Discord", "Vesktop", "Equibop"]
PIN_DISCORD_INFO = {
    "Discord": ("discord", "discord", False),
    "Vesktop": ("vesktop", "vesktop-bin", True),
    "Equibop": ("equibop", "equibop-bin", True),
}


def build_apply_pin_argv(binary: str, pkg: str, needs_aur: bool, pref_file: Path) -> list[str]:
    """Install the package (if needed) and write it as the bar pin's
    preferred binary, checked by simpbar-launch-browser/-discord."""
    if needs_aur:
        install_cmd = (
            f"if command -v yay >/dev/null; then yay -S --noconfirm --needed {pkg}; "
            f"elif command -v paru >/dev/null; then paru -S --noconfirm --needed {pkg}; "
            f'else echo "No AUR helper found — install {pkg} manually"; fi'
        )
    else:
        install_cmd = f"sudo pacman -S --noconfirm --needed {pkg}"
    write_pref = f"mkdir -p {SIMPBAR_CONFIG_DIR} && echo {binary} > {pref_file}"
    full_cmd = f"{install_cmd}; {write_pref}; echo; read -p 'Press Enter to close...'"
    return ["foot", "-e", "bash", "-lc", full_cmd]


EASYEFFECTS_PKGS = ["easyeffects", "calf", "lsp-plugins-lv2", "mda.lv2", "x42-plugins-lv2", "zam-plugins-lv2"]
EASYEFFECTS_ARGV = [
    "foot", "-e", "bash", "-lc",
    f"sudo pacman -S --noconfirm --needed {' '.join(EASYEFFECTS_PKGS)}; "
    "echo; read -p 'Press Enter to close...'",
]

GRAPHICS_OPTIONS = ["GIMP", "Inkscape", "Krita"]
GRAPHICS_PACKAGES = {
    "GIMP": "gimp",
    "Inkscape": "inkscape",
    "Krita": "krita",
}

VIDEO_PLAYER_OPTIONS = ["mpv", "VLC"]
VIDEO_PLAYER_PACKAGES = {
    "mpv": "mpv",
    "VLC": "vlc",
}


def build_pacman_install_argv(pkg: str) -> list[str]:
    full_cmd = f"sudo pacman -S --noconfirm --needed {pkg}; echo; read -p 'Press Enter to close...'"
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


def _parse_pkg_update_line(line: str):
    """Parses a "pkgname oldver -> newver" line (checkupdates/yay/paru format)."""
    if "->" not in line:
        return None
    left, _, new_ver = line.partition("->")
    parts = left.strip().rsplit(" ", 1)
    if len(parts) != 2:
        return None
    name, old_ver = parts
    return name.strip(), f"{old_ver.strip()} \u2192 {new_ver.strip()}"


def fetch_arch_updates():
    """Returns a list of (name, "old → new") tuples, or None if checkupdates
    isn't available/failed. Runs quickly and never needs sudo."""
    if not shutil.which("checkupdates"):
        return None
    try:
        result = subprocess.run(["checkupdates"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    entries = []
    for line in result.stdout.strip().splitlines():
        parsed = _parse_pkg_update_line(line)
        if parsed:
            entries.append(parsed)
    return entries


def fetch_aur_updates():
    """Returns [] (not an error) if no AUR helper is installed at all."""
    helper = "yay" if shutil.which("yay") else ("paru" if shutil.which("paru") else None)
    if helper is None:
        return []
    try:
        result = subprocess.run([helper, "-Qua"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    entries = []
    for line in result.stdout.strip().splitlines():
        parsed = _parse_pkg_update_line(line)
        if parsed:
            entries.append(parsed)
    return entries


def fetch_flatpak_updates():
    """Returns [] (not an error) if flatpak isn't installed at all."""
    if not shutil.which("flatpak"):
        return []
    try:
        # Refresh available-update metadata first — safe, doesn't install anything.
        subprocess.run(["flatpak", "update", "--appstream", "-y"],
                       capture_output=True, text=True, timeout=60)
        result = subprocess.run(
            ["flatpak", "remote-ls", "--updates", "--columns=application,version", "flathub"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    entries = []
    for line in result.stdout.strip().splitlines():
        if not line.strip():
            continue
        fields = line.split("\t") if "\t" in line else line.split()
        if len(fields) < 2 or fields[0].strip().lower() == "application":
            continue
        entries.append((fields[0].strip(), fields[1].strip()))
    return entries


APPLY_ALL_UPDATES_ARGV = [
    "foot", "-e", "bash", "-lc",
    "sudo pacman -Syu --noconfirm; "
    "if command -v yay >/dev/null; then yay -Sua --noconfirm; "
    "elif command -v paru >/dev/null; then paru -Sua --noconfirm; fi; "
    "command -v flatpak >/dev/null && flatpak update -y; "
    "echo; read -p 'Press Enter to close...'",
]


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

        autostart_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        autostart_box.set_halign(Gtk.Align.CENTER)
        autostart_box.set_margin_top(12)

        autostart_label = Gtk.Label(label="Launch on startup")
        autostart_switch = Gtk.Switch()
        autostart_switch.set_valign(Gtk.Align.CENTER)
        autostart_switch.set_active(is_hypr_line_enabled(SIMPBAR_WELCOME_AUTOSTART_LINE))
        autostart_switch.connect("notify::active", self._on_autostart_toggled)

        autostart_box.append(autostart_label)
        autostart_box.append(autostart_switch)
        self.append(autostart_box)

    def _on_autostart_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        set_hypr_line_enabled(SIMPBAR_WELCOME_AUTOSTART_LINE, switch.get_active())


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

        media_group = Adw.PreferencesGroup(title="Audio and graphics")

        easyeffects_row = Adw.ActionRow(
            title="Install EasyEffects",
            subtitle="Audio effects for PipeWire, with the Calf, LSP, MDA, x42, "
            "and ZAM plugin packs included.",
        )
        easyeffects_row.set_icon_name("multimedia-volume-control-symbolic")
        easyeffects_button = Gtk.Button(label="Install")
        easyeffects_button.add_css_class("flat")
        easyeffects_button.set_valign(Gtk.Align.CENTER)
        easyeffects_button.connect("clicked", lambda _b: launch(EASYEFFECTS_ARGV))
        easyeffects_row.add_suffix(easyeffects_button)
        media_group.add(easyeffects_row)

        graphics_row = Adw.ComboRow(
            title="Install a graphics app",
            subtitle="GIMP (photo editing), Inkscape (vector art), or Krita (painting).",
            model=Gtk.StringList.new(GRAPHICS_OPTIONS),
        )
        graphics_button = Gtk.Button(label="Install")
        graphics_button.add_css_class("flat")
        graphics_button.set_valign(Gtk.Align.CENTER)
        graphics_button.connect(
            "clicked",
            lambda _b: launch(build_pacman_install_argv(
                GRAPHICS_PACKAGES[GRAPHICS_OPTIONS[graphics_row.get_selected()]]
            )),
        )
        graphics_row.add_suffix(graphics_button)
        media_group.add(graphics_row)

        video_player_row = Adw.ComboRow(
            title="Install a video player",
            subtitle="mpv (lightweight) or VLC (more built-in codecs/features).",
            model=Gtk.StringList.new(VIDEO_PLAYER_OPTIONS),
        )
        video_player_button = Gtk.Button(label="Install")
        video_player_button.add_css_class("flat")
        video_player_button.set_valign(Gtk.Align.CENTER)
        video_player_button.connect(
            "clicked",
            lambda _b: launch(build_pacman_install_argv(
                VIDEO_PLAYER_PACKAGES[VIDEO_PLAYER_OPTIONS[video_player_row.get_selected()]]
            )),
        )
        video_player_row.add_suffix(video_player_button)
        media_group.add(video_player_row)

        self.append(media_group)

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

        pins_group = Adw.PreferencesGroup(
            title="Pinned apps",
            description="Picks which app the bar's Browser/Discord pins launch. "
            "Installs it if needed.",
        )

        browser_row = Adw.ComboRow(
            title="Pinned browser",
            model=Gtk.StringList.new(PIN_BROWSER_OPTIONS),
        )
        browser_button = Gtk.Button(label="Apply")
        browser_button.add_css_class("flat")
        browser_button.set_valign(Gtk.Align.CENTER)
        browser_button.connect(
            "clicked",
            lambda _b: launch(build_apply_pin_argv(
                *PIN_BROWSER_INFO[PIN_BROWSER_OPTIONS[browser_row.get_selected()]],
                BROWSER_PREF_FILE,
            )),
        )
        browser_row.add_suffix(browser_button)
        pins_group.add(browser_row)

        discord_row = Adw.ComboRow(
            title="Pinned Discord client",
            model=Gtk.StringList.new(PIN_DISCORD_OPTIONS),
        )
        discord_button = Gtk.Button(label="Apply")
        discord_button.add_css_class("flat")
        discord_button.set_valign(Gtk.Align.CENTER)
        discord_button.connect(
            "clicked",
            lambda _b: launch(build_apply_pin_argv(
                *PIN_DISCORD_INFO[PIN_DISCORD_OPTIONS[discord_row.get_selected()]],
                DISCORD_PREF_FILE,
            )),
        )
        discord_row.add_suffix(discord_button)
        pins_group.add(discord_row)

        self.append(pins_group)

        autostart_group = Adw.PreferencesGroup(
            title="Autostart",
            description="Launch these silently in the background on login.",
        )

        steam_row = Adw.ActionRow(
            title="Start Steam silently",
            subtitle="Runs steam -silent — Steam starts minimized to the tray.",
        )
        steam_row.set_icon_name("applications-games-symbolic")
        steam_switch = Gtk.Switch()
        steam_switch.set_valign(Gtk.Align.CENTER)
        steam_switch.set_active(is_hypr_line_enabled(STEAM_SILENT_AUTOSTART_LINE))
        steam_switch.connect(
            "notify::active",
            lambda sw, _p: set_hypr_line_enabled(STEAM_SILENT_AUTOSTART_LINE, sw.get_active()),
        )
        steam_row.add_suffix(steam_switch)
        autostart_group.add(steam_row)

        easyeffects_autostart_row = Adw.ActionRow(
            title="Start EasyEffects",
            subtitle="Runs easyeffects --gapplication-service — applies your audio "
            "effects without opening a window.",
        )
        easyeffects_autostart_row.set_icon_name("multimedia-volume-control-symbolic")
        easyeffects_autostart_switch = Gtk.Switch()
        easyeffects_autostart_switch.set_valign(Gtk.Align.CENTER)
        easyeffects_autostart_switch.set_active(is_hypr_line_enabled(EASYEFFECTS_AUTOSTART_LINE))
        easyeffects_autostart_switch.connect(
            "notify::active",
            lambda sw, _p: set_hypr_line_enabled(EASYEFFECTS_AUTOSTART_LINE, sw.get_active()),
        )
        easyeffects_autostart_row.add_suffix(easyeffects_autostart_switch)
        autostart_group.add(easyeffects_autostart_row)

        self.append(autostart_group)


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

        discord_row = Adw.ActionRow(
            title="Join the Discord",
            subtitle=DISCORD_URL,
            activatable=True,
        )
        discord_row.set_icon_name("user-available-symbolic")
        discord_row.connect("activated", lambda _r: launch(["xdg-open", DISCORD_URL]))
        group.add(discord_row)

        self.append(group)


class UpdatesPage(Gtk.Box):
    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.set_margin_top(24)
        self.set_margin_bottom(24)
        self.set_margin_start(24)
        self.set_margin_end(24)

        button_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.check_button = Gtk.Button(label="Check for Updates")
        self.check_button.add_css_class("suggested-action")
        self.check_button.connect("clicked", self._on_check_clicked)
        button_row.append(self.check_button)

        self.spinner = Gtk.Spinner()
        button_row.append(self.spinner)
        self.append(button_row)

        self.arch_group = Adw.PreferencesGroup(title="Arch Linux packages")
        self.aur_group = Adw.PreferencesGroup(title="AUR packages")
        self.flatpak_group = Adw.PreferencesGroup(title="Flatpak apps")
        self._group_rows: dict[Adw.PreferencesGroup, list[Adw.ActionRow]] = {
            self.arch_group: [], self.aur_group: [], self.flatpak_group: []
        }
        for group in (self.arch_group, self.aur_group, self.flatpak_group):
            self.append(group)

        self.apply_button = Gtk.Button(label="Apply all updates")
        self.apply_button.add_css_class("flat")
        self.apply_button.set_sensitive(False)
        self.apply_button.connect("clicked", self._on_apply_clicked)
        self.append(self.apply_button)

        for group in (self.arch_group, self.aur_group, self.flatpak_group):
            self._set_group_message(group, 'Click "Check for Updates" above to scan.')

    def _clear_group(self, group: Adw.PreferencesGroup) -> None:
        for row in self._group_rows[group]:
            group.remove(row)
        self._group_rows[group] = []

    def _set_group_message(self, group: Adw.PreferencesGroup, message: str) -> None:
        self._clear_group(group)
        row = Adw.ActionRow(title=message)
        group.add(row)
        self._group_rows[group].append(row)

    def _populate_group(
        self, group: Adw.PreferencesGroup, entries: list[tuple[str, str]], empty_message: str
    ) -> None:
        self._clear_group(group)
        if not entries:
            row = Adw.ActionRow(title=empty_message)
            group.add(row)
            self._group_rows[group].append(row)
            return
        for name, version_info in entries:
            row = Adw.ActionRow(title=name, subtitle=version_info)
            group.add(row)
            self._group_rows[group].append(row)

    def _on_check_clicked(self, _button: Gtk.Button) -> None:
        self.check_button.set_sensitive(False)
        self.apply_button.set_sensitive(False)
        self.spinner.start()
        for group in (self.arch_group, self.aur_group, self.flatpak_group):
            self._set_group_message(group, "Checking\u2026")
        threading.Thread(target=self._check_updates_thread, daemon=True).start()

    def _check_updates_thread(self) -> None:
        arch_updates = fetch_arch_updates()
        aur_updates = fetch_aur_updates()
        flatpak_updates = fetch_flatpak_updates()
        GLib.idle_add(self._on_check_finished, arch_updates, aur_updates, flatpak_updates)

    def _on_check_finished(self, arch_updates, aur_updates, flatpak_updates) -> bool:
        self.spinner.stop()
        self.check_button.set_sensitive(True)

        if arch_updates is None:
            self._set_group_message(self.arch_group, "Could not check — is pacman-contrib installed?")
        else:
            self._populate_group(self.arch_group, arch_updates, "Everything up to date.")

        if aur_updates is None:
            self._set_group_message(self.aur_group, "Could not check AUR updates.")
        else:
            self._populate_group(
                self.aur_group, aur_updates,
                "Everything up to date, or no AUR helper installed.",
            )

        if flatpak_updates is None:
            self._set_group_message(self.flatpak_group, "Could not check — is flatpak installed?")
        else:
            self._populate_group(self.flatpak_group, flatpak_updates, "Everything up to date.")

        total = len(arch_updates or []) + len(aur_updates or []) + len(flatpak_updates or [])
        self.apply_button.set_sensitive(total > 0)
        return False  # GLib.idle_add: run once, don't repeat

    def _on_apply_clicked(self, _button: Gtk.Button) -> None:
        launch(APPLY_ALL_UPDATES_ARGV)


class WelcomeWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="Simpbar Welcome")
        self.set_default_size(760, 700)

        split_view = Adw.NavigationSplitView()
        self.set_content(split_view)

        # Sidebar
        sidebar_list = Gtk.ListBox()
        sidebar_list.add_css_class("navigation-sidebar")
        sidebar_list.set_selection_mode(Gtk.SelectionMode.SINGLE)

        self.pages = {
            "Welcome": WelcomePage(),
            "Setup": SetupPage(),
            "Updates": UpdatesPage(),
            "Keybindings": KeybindingsPage(),
            "About": AboutPage(),
        }
        icons = {
            "Welcome": "go-home-symbolic",
            "Setup": "emblem-system-symbolic",
            "Updates": "software-update-available-symbolic",
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
        self.content_stack.set_vexpand(True)
        self.content_stack.set_hexpand(True)
        for name, widget in self.pages.items():
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            scrolled.set_vexpand(True)
            scrolled.set_hexpand(True)
            scrolled.set_child(widget)
            self.content_stack.add_named(scrolled, name)

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

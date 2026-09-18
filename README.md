# Simpbar

A status bar for Hyprland — simpbar, a native Zig/Wayland bar built for this repo — that's simple, looks nice, and isn't distracting, plus an install script that sets up a whole ricing-friendly Arch desktop around it, and a companion GTK app to manage it all afterward.

Built for **Arch Linux** (and Arch-based distros like EndeavourOS, CachyOS, Garuda, XeroLinux — your mileage may vary depending on how much those ship pre-configured). Assumes **Hyprland 0.55+** (Lua config, `~/.config/hypr/hyprland.lua`).

A **Debian** edition of the installer (`install-debian.sh`) is also available — see [Debian install](#debian-install) below.

## Install

```
curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash
```

The script is interactive — it'll ask a handful of questions (browser, Discord client, whether you want OBS/a video editor/game launchers/falcond/matugen, etc.) and needs your sudo password partway through. Grab a coffee; it installs a lot.

## Debian install

```
curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install-debian.sh | bash
```

Same interactive flow as the Arch script, adapted to apt. It's regularly tested against **Debian sid/testing**; older releases may be missing newer packages (notably Hyprland). Differences from the Arch installer:

- i386 architecture is enabled automatically for Steam (apt's equivalent of multilib)
- zig 0.16.0 and the JetBrainsMono Nerd Font aren't in Debian repos — they're fetched from the official upstream tarball/zip and installed to `/usr/local/zig` (symlinked into `/usr/local/bin`) and `/usr/share/fonts/TTF`
- The bar, `simpbar-welcome`, and `simpbar-config` are built once with zig during install into `/usr/bin`
- No Chaotic-AUR (not a thing on Debian) — explicit repositories are added only for the browser you pick (Brave/Vivaldi/Microsoft Edge/LibreWolf official apt repos, or Firefox ESR straight from Debian)
- AUR-only items are skipped with working replacements: `sway-notification-center` instead of swaync, `mate-polkit` autostart instead of the Arch polkit path, `wlogout`/`steam-devices` from apt, `azote` + a `swaybg.service` (systemd user service) instead of waypaper for the Bing wallpaper (both pickers are just front-ends to swaybg), plus an `azote-restore.service` so the wallpaper you pick in azote comes back after every login, and rofi's bundled Material theme instead of installing one
- Dropped in favour of a fast AUR package set on Arch; on Debian, matugen (the Material You colorscheme generator) isn't packaged either — the installer offers a `cargo install matugen` route instead (see [Auto-theming with matugen](#auto-theming-with-matugen))
- Heroic takes the Flatpak route (`com.heroicgameslauncher.hgl`), Discord the official `.deb`; ProtonPlus, falcond, nwg-drawer, and the dracula/zafiro themes aren't packaged on Debian and are skipped with a warning
- The GPU detection picks Debian's actual driver/repo names: `nvidia-driver` + `libnvidia-egl-wayland` (with a prompt to enable `non-free` if unavailable), `mesa-vulkan-drivers`/`intel-media-va-driver` for AMD/Intel

The shipped binaries are distro-aware — `simpbar`, `simpbar-welcome`, `simpbar-config`, `simpbar-check-updates`, and `simpbar-launch-browser` detect apt vs pacman at runtime, so a single build works on either family.

## Auto-theming with matugen

simbar can recolor itself to match your wallpaper — Material You style — via **[matugen](https://github.com/InioX/matugen)**. Pick a wallpaper in waypaper (Arch) or azote (Debian) and the bar recolors automatically.

`auto-theme`: the `appearance` section of `~/.config/simpbar/config.json` has an `auto_theme` field (`"matugen"` or `"manual"`, defaulting to `"matugen"`). Toggle it anytime from **simpbar-config** → Appearance → Theming → the "Auto-theme with matugen" switch. Right below it, a **Matugen color scheme** dropdown picks the palette matugen derives from the image — Tonal spot (default), Content, Expressive, Fidelity, Fruit salad, Monochrome, Neutral, Rainbow, Vibrant, or Smart. Changing it regenerates the scheme immediately.

How it works — matugen never touches your bar config, wallpaper, or anything else:

1. matugen renders `~/.config/matugen/templates/simpbar.json` (installed by the installer) to `~/.config/simpbar/matugen.json` — ten Material color roles (bg, text, border, hover, workspace active/inactive, popup bg/hover/separator/disabled).
2. The bar merges those into the appearance on every reload (startup **and** live `SIGUSR1` reload). Missing/corrupt `matugen.json` leaves the bar's config colors alone; any invalid hex aborts the whole merge.
3. matugen's shipping config (`~/.config/matugen/config.toml`, `set = false` under `[config.wallpaper]`) means it never sets the wallpaper — your picker owns that — and its `post_hook` reloads the running bar (`kill -USR1` via `~/.config/simpbar/simpbar.pid`) as soon as new colors land. The hook runs under `sh -c '…'` so it's safe for any `$SHELL` (fish, zsh, …).
4. The wallpaper picker re-triggers it: waypaper via `post_command = simpbar-matugen "$wallpaper"`, azote via the `matugen-wallpaper.path`/`.service` systemd user units watching `~/.azotebg-hyprland`. `simpbar-matugen` (in `/usr/bin`) also works standalone — `simpbar-matugen /path/to/image.jpg`, or no argument to auto-find the current wallpaper (waypaper config, then azote's restore script, then the newest `~/Pictures/Wallpaper/bing-*.jpg`).

The chosen scheme type lives in `~/.config/simpbar/matugen-type` (a simpbar-owned file, since matugen 4.x only accepts `--type` on the command line and **ignores** a `type` key in its own config.toml); `simpbar-matugen` reads it on every run. The installer wires all of this when you opt into matugen: Arch pulls it from the AUR, Debian from crates.io (rustc + cargo), then places the config + template, installs `simpbar-matugen`, adds the picker hook, and pre-generates a scheme from that day's Bing wallpaper.

## What the install script sets up

**Bar, compositor & theming**
- simpbar (this repo's source, built from scratch during install), Hyprland, foot (terminal), rofi with its bundled Material theme, swaync (notifications)
- Dracula GTK theme, Zafiro-Dracula icon theme, Bibata Modern Classic cursor — all applied automatically via nwg-look's settings, no manual toggling needed
- nwg-drawer as the app-menu behind the bar's Menu button (ArcMenu-style GNOME Shell extensions don't run under Hyprland at all — this is the actual Wayland-native equivalent)
- fastfetch (also wired into every new bash/fish shell)

**Wallpaper**
- Downloads that day's Bing wallpaper into `~/Pictures/Wallpaper` and points the wallpaper picker at it (waypaper on Arch, azote on Debian)
- swaybg is enabled as a systemd user service so it's already showing the wallpaper on login — no need to add anything to your Hyprland autostart yourself
- Optional **matugen** auto-theming — the bar recolors to match whatever wallpaper is up (picks it up from your picker; see [Auto-theming with matugen](#auto-theming-with-matugen))

**Shell**
- fish, set as your default login shell, empty greeting, fastfetch on launch

**Editors**
- Neovim + LazyVim installed by default
- The Welcome app's Setup tab can install Gedit, Kate, Zed, or VS Code instead/alongside, or fully remove Neovim + LazyVim if you'd rather not have it

**Gaming**
- Steam (multilib enabled automatically), ProtonPlus, optional Lutris/Heroic
- falcond + falcond-gui (per-game performance profiles) with scx-scheds/scx-tools for sched_ext scheduler switching, if you opt in
- game-devices-udev for proper Xbox/PlayStation/generic controller permissions — no root or relog needed

**Browsers & chat** — pick one of each during install (or skip):
- Brave, Zen Browser, Vivaldi, Microsoft Edge, or LibreWolf
- Discord, Vesktop, or Equibop

**Extras**
- OBS Studio and a video editor (Kdenlive, Shotcut, or Flowblade), both optional
- cliphist (clipboard history), grim + slurp + xdg-desktop-portal-hyprland (screenshots/screen-share)
- HyprMod — a native GTK4/libadwaita settings app for tweaking Hyprland itself (keybinds, monitors, animations, window rules) without touching `hyprland.lua` by hand
- Chaotic-AUR set up automatically for faster package installs
- A background update checker (systemd timer, runs every 6h) that notifies you when there's a new Arch/AUR update or a new commit on this repo

**Pinned apps in the bar**
simpbar ships with quick-launch icons next to the menu button: Browser, Discord, Files (Nautilus), Terminal, Steam, HyprMod, and Simpbar Welcome. Browser and Discord are smart about it — whichever one you actually installed is what launches by default, and you can change your mind later from the Welcome app without needing to touch any config directly.

## Simpbar Welcome

A small GTK4 + libadwaita app that pops up once on first login (and is always reachable afterward — pinned in the bar, or via rofi/nwg-drawer). Tabs:

- **Welcome** — quick intro, plus a "Launch on startup" switch (toggles whether the app opens automatically each login)
- **Setup**
  - Update Simpbar & Arch Linux in one click, or just check for updates now
  - Quick launchers for the wallpaper picker (azote on Debian, waypaper on Arch), nwg-look, HyprMod, and pavucontrol
  - Install or remove text editors (Neovim/Gedit/Kate/Zed/VS Code)
  - Set which browser and Discord client the bar's pinned buttons should launch
- **Keybindings** — the list below, always at hand
- **About** — links to this repo, issues, and a contact email for bugs/suggestions

## Keybindings

| Keys | Action |
|---|---|
| `SUPER` | (modifier) |
| `SUPER + Enter` | Open terminal |
| `SUPER + Space` | Open Rofi |
| `SUPER + E` | Open Nautilus |
| `SUPER + Q` | Exit the focused app |
| `SUPER + [1–0]` | Switch workspaces |

To change keybindings or your monitor setup:

```
nvim ~/.config/hypr/hyprland.lua
```

Don't forget to reboot once the install finishes (`systemctl reboot`) so everything (shell, theme, services) is fully in effect.

## Credits

The Beginning of the install script is thanks to **Ryzendew**.

The HyprMod Developer **BlueManCZ**.

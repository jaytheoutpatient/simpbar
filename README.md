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
- AUR-only items are skipped with working replacements: `sway-notification-center` instead of swaync, `mate-polkit` autostart instead of the Arch polkit path, `wlogout`/`steam-devices` from apt, azote instead of waypaper as an extra picker (the wallpaper engine itself is distro-agnostic — see [Wallpapers](#wallpapers)), and rofi's bundled Material theme instead of installing one
- Dropped in favour of a fast AUR package set on Arch; on Debian, matugen (the Material You colorscheme generator) isn't packaged either — the installer offers a `cargo install matugen` route instead (see [Auto-theming with matugen](#auto-theming-with-matugen))
- Heroic takes the Flatpak route (`com.heroicgameslauncher.hgl`), Discord the official `.deb`; ProtonPlus, falcond, nwg-drawer, and the dracula/zafiro themes aren't packaged on Debian and are skipped with a warning
- The app drawer needs **quickshell**, which is in Arch's `extra` repo but isn't packaged on Debian in any suite (checked bookworm/trixie/sid). The Debian installer skips the drawer with a warning and rofi remains the launcher, but it still places the QML and the toggle script ready to go, so installing quickshell later is all it takes to switch over (see [App drawer](#app-drawer))
- The GPU detection picks Debian's actual driver/repo names: `nvidia-driver` + `libnvidia-egl-wayland` (with a prompt to enable `non-free` if unavailable), `mesa-vulkan-drivers`/`intel-media-va-driver` for AMD/Intel

The shipped binaries are distro-aware — `simpbar`, `simpbar-welcome`, `simpbar-config`, `simpbar-check-updates`, and `simpbar-launch-browser` detect apt vs pacman at runtime, so a single build works on either family.

## Auto-theming with matugen

simbar can recolor itself to match your wallpaper — Material You style — via **[matugen](https://github.com/InioX/matugen)**. Pick a wallpaper in waypaper (Arch) or azote (Debian) and the bar recolors automatically.

`auto-theme`: the `appearance` section of `~/.config/simpbar/config.json` has an `auto_theme` field (`"matugen"` or `"manual"`, defaulting to `"matugen"`). Toggle it anytime from **simpbar-config** → Appearance → Theming → the "Auto-theme with matugen" switch. Right below it, a **Matugen color scheme** dropdown picks the palette matugen derives from the image — Tonal spot (default), Content, Expressive, Fidelity, Fruit salad, Monochrome, Neutral, Rainbow, Vibrant, or Smart. Changing it regenerates the scheme immediately.

How it works — matugen never touches your bar config, wallpaper, or anything else:

1. matugen renders `~/.config/matugen/templates/simpbar.json` (installed by the installer) to `~/.config/simpbar/matugen.json` — ten Material color roles (bg, text, border, hover, workspace active/inactive, popup bg/hover/separator/disabled).
2. The bar merges those into the appearance on every reload (startup **and** live `SIGUSR1` reload). Missing/corrupt `matugen.json` leaves the bar's config colors alone; any invalid hex aborts the whole merge.
3. matugen's shipping config (`~/.config/matugen/config.toml`, `set = false` under `[config.wallpaper]`) means it never sets the wallpaper — your picker owns that — and its `post_hook` reloads the running bar (`kill -USR1` via `~/.config/simpbar/simpbar.pid`) as soon as new colors land. The hook runs under `sh -c '…'` so it's safe for any `$SHELL` (fish, zsh, …).
4. The wallpaper engine re-triggers it on every change (see [Wallpapers](#wallpapers)). `simpbar-matugen` (in `/usr/bin`) also works standalone — `simpbar-matugen /path/to/image.jpg` themes a specific image, and with no argument it finds the current wallpaper for you, asking: swaybg's own command line, then `~/.config/simpbar/wallpaper`, then waypaper's `config.ini`, then azote's restore script, then the newest image in your wallpaper folders. Each candidate is checked for existence before it's accepted, so a stale entry falls through instead of failing.

   Any image matugen can read is valid input. That last step is deliberately "the newest image", not "the newest Bing image" — an earlier version only ever fell back to `bing-*.jpg`, and combined with a bug below it meant matugen appeared to work *only* on Bing wallpapers.

   > **The bug worth knowing about**, if you ever see your bar themed to a different image than the one on screen: waypaper writes `~/Pictures/...` into its `config.ini` with a literal tilde, and expands it itself on read (`pathlib.Path(...).expanduser()`). Anything reimplementing that parsing in shell has to expand it too — and `"$IMG"` where `IMG` is `~/Pictures/x.jpg` never matches a file, because a tilde inside double quotes is just a character. The helper used to bail out there, the Bing-only fallback caught it, and the desktop stayed themed to the Bing picture no matter what you picked. Both halves are fixed: the tilde is expanded, and paths are read out of `/proc/<pid>/cmdline` (NUL-separated argv) rather than `pgrep -a`, because every AI-generated wallpaper has spaces in its filename and a space-joined `ps` line can't tell you where the path ends.

The chosen scheme type lives in `~/.config/simpbar/matugen-type` (a simpbar-owned file, since matugen 4.x only accepts `--type` on the command line and **ignores** a `type` key in its own config.toml); `simpbar-matugen` reads it on every run. The installer wires all of this when you opt into matugen: Arch pulls it from the AUR, Debian from crates.io (rustc + cargo), then places the config + template, installs `simpbar-matugen`, adds the picker hook, and pre-generates a scheme from that day's Bing wallpaper.

## App drawer

An ArcMenu-style launcher that slides up from under the bar — app grid, categories, search, pinned favourites, and a power menu (lock / suspend / log out / restart / power off). It reads the same `matugen.json` as the bar, so both repaint together when you change wallpaper.

Three ways to open it:

- **Click empty bar space** (see below)
- **`SUPER + Tab`**
- **`appdrawer`** by hand — `toggle` (default), `open`, `close`, `wallpapers`, `apps`, or `start`. It's in `/usr/bin`, so no path needed.

It's a [quickshell](https://quickshell.org) panel living in `~/.config/quickshell/appdrawer/`, not a plain Qt/QML app: layer-shell support (the thing that lets a window dock to a screen edge like a panel) lives in quickshell's QtWayland fork rather than upstream `qt6-wayland`, so a stock Qt6 QML app has no way to make one.

- **Arch**: quickshell is in the official `extra` repo, so the installer pulls it and deploys the panel.
- **Debian**: quickshell isn't packaged in any suite, and building it isn't a good option — it uses private Qt APIs and must be compiled against the exact Qt version it ships with or it crashes on ABI mismatch. The installer skips the drawer with a warning and leaves rofi as the launcher, but still stages the QML in `~/.local/share/simpbar/appdrawer/` and the toggle script, so installing quickshell yourself is all that's needed afterwards.

Your pinned apps live in `favourites.json` next to the panel — under `$XDG_CONFIG_HOME/quickshell/appdrawer/` when `XDG_CONFIG_HOME` is set, `~/.config/quickshell/appdrawer/` otherwise. That is the same place quickshell itself searches for configs, so the panel and its state can never drift apart. The installer never overwrites an existing `favourites.json`.

## Wallpapers

The drawer's second tab is a wallpaper picker: a grid of thumbnails of everything in your wallpaper folder, the active one outlined in the accent colour, a **Random** button, and live filtering through the same search box as the app grid. Picking one swaps the wallpaper and re-themes the whole desktop behind the drawer, which stays open on purpose so you can watch the colors change. `appdrawer wallpapers` opens straight onto that tab — which is where the bar's wallpaper button goes.

It's backed by `simpbar-wallpaper`, which owns the wallpaper rather than delegating to a front-end. That's a deliberate simplification: waypaper and azote are both GUI wrappers around swaybg, and the previous arrangement had two programs each keeping their own idea of the current wallpaper — one of which couldn't parse a filename containing spaces, so the bar ended up themed from a different image than the one on screen (see [the note above](#auto-theming-with-matugen)). One engine means one answer.

```
simpbar-wallpaper              open the picker (drawer's Wallpapers tab)
simpbar-wallpaper list         print "path<TAB>name" per wallpaper
simpbar-wallpaper set <img>    apply it: swaybg + matugen + remember it
simpbar-wallpaper random       apply a random wallpaper
simpbar-wallpaper current      print the wallpaper currently applied
```

Bare `simpbar-wallpaper` opens the drawer when quickshell is available, and falls back to rofi, then waypaper/azote, so it still does something useful on a machine without the drawer.

**How a wallpaper gets applied.** The new swaybg is started *before* the old one is killed (with a short pause in between), so the screen never flashes black — the reverse order shows bare desktop for a frame on every switch. Then matugen runs (its output goes to `~/.local/state/simpbar/matugen.log`; it's ~140 lines of post-hook chatter per run, which would otherwise drown out this script's machine-readable output), and finally the path is written to `~/.config/simpbar/wallpaper`. Remembering it *before* theming means a matugen crash still leaves a restorable wallpaper.

**Across reboots.** `simpbar-restore-wallpaper` runs from your Hyprland autostart and replays `~/.config/simpbar/wallpaper` through the engine — so the wallpaper comes back *and* the colors match it from the first frame, instead of showing last session's palette until you change it. If you never used the engine it falls back to azote's restore script (`~/.azotebg-hyprland` or `~/.azotebg`), and does nothing at all if neither exists. Because of this, the installer no longer writes a `swaybg.service`: that unit baked today's Bing path into `ExecStart`, which cannot express "whatever was last picked", and its `Restart=on-failure` meant it could resurrect the Bing picture over the top of a newer choice. Any existing one is disabled on install.

**Which folders.** `~/Pictures/Wallpaper` by default. For more, create `~/.config/simpbar/wallpaper-dirs` with one path per line (`~` is expanded, blank lines and `#` comments ignored):

```
~/Pictures/Wallpaper
~/wallpapers
```

Missing folders are skipped rather than treated as an error. The extension list is the set swaybg can decode, matched case-insensitively, because real collections contain things like `.JPG`.

## Clicking empty bar space

`empty_click_command`: the `appearance` section of `~/.config/simpbar/config.json` takes a command to run when you **left-click bare bar background** — any spot no module occupies, i.e. the gaps between them:

```json
{ "appearance": { "empty_click_command": "appdrawer" } }
```

It runs through `sh -c`, so `$HOME` expands and shell operators work. Empty (the default) disables the behaviour and the click does nothing, exactly as before. Right-clicking empty space is deliberately left alone.

This is *not* the same as the bar's own drawer toggle (the `⌄` button, which reveals `in_drawer` modules like volume and tray) — the two are independent and can be enabled separately.

There is no widget for this in **simpbar-config**, but it is round-tripped from disk on every save, so hand-editing it in `config.json` and then using the GUI is safe.

## What the install script sets up

**Bar, compositor & theming**
- simpbar (this repo's source, built from scratch during install), Hyprland, foot (terminal), rofi with its bundled Material theme, swaync (notifications)
- Dracula GTK theme, Zafiro-Dracula icon theme, Bibata Modern Classic cursor — all applied automatically via nwg-look's settings, no manual toggling needed
- nwg-drawer, usable from rofi as a fallback app-menu (ArcMenu-style GNOME Shell extensions don't run under Hyprland at all)
- fastfetch (also wired into every new bash/fish shell)

**Wallpaper**
- Downloads that day's Bing wallpaper into `~/Pictures/Wallpaper`
- Seeds the wallpaper engine's state file with it, so the wallpaper you had at logout is the one that comes back at login — nothing to add to your Hyprland autostart yourself (see [Wallpapers](#wallpapers))
- Installs `simpbar-wallpaper` (the engine) and `simpbar-restore-wallpaper` (the login-time restore) to `/usr/bin`
- Optional **matugen** auto-theming — the bar recolors to match whatever wallpaper is up (see [Auto-theming with matugen](#auto-theming-with-matugen))

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
- Hyprland settings built into **Simpbar Config** — a native GTK4/libadwaita manager for keybinds, monitors, animations, window/workspace/layer rules, autostart, and environment, without hand-editing `hyprland.lua`
- Chaotic-AUR set up automatically for faster package installs
- A background update checker (systemd timer, runs every 6h) that notifies you when there's a new Arch/AUR update or a new commit on this repo

**Pinned apps in the bar**
simpbar ships with quick-launch icons: Browser, Discord, Files (Nautilus), Terminal, Steam, Config (Hyprland settings), and Simpbar Welcome. Browser and Discord are smart about it — whichever one you actually installed is what launches by default, and you can change your mind later from the Welcome app without needing to touch any config directly.

## Simpbar Welcome

A small GTK4 + libadwaita app that pops up once on first login (and is always reachable afterward — pinned in the bar, or via rofi/nwg-drawer). Tabs:

- **Welcome** — quick intro, plus a "Launch on startup" switch (toggles whether the app opens automatically each login)
- **Setup**
  - Update Simpbar & Arch Linux in one click, or just check for updates now
  - Quick launchers for the wallpaper picker, nwg-look, the Hyprland settings (simpbar-config), and pavucontrol
  - Install or remove text editors (Neovim/Gedit/Kate/Zed/VS Code)
  - Set which browser and Discord client the bar's pinned buttons should launch
- **Keybindings** — the list below, always at hand
- **About** — links to this repo, issues, and a contact email for bugs/suggestions

## Simpbar Config

Simpbar Config is the app in the "Tweak Hyprland settings" card: a sidebar of nine
Hyprland pages (General, Monitors, Animations, Keybinds, Window Rules, Workspace
Rules, Layer Rules, Autostart, Environment) sitting next to the original bar
pages (Appearance, Modules, Shortcuts).

- Settings are saved to `~/.config/simpbar/hyprland.json` (the source of truth).
- Each change regenerates `~/.config/hypr/hyprland-simpbar.lua` and both files are
  written atomically, then Hyprland is reloaded automatically.
- `hyprland-simpbar.lua` is loaded from `hyprland.lua` via an idempotent
  `pcall(require, "hyprland-simpbar")` line — the first app run adds it if missing,
  and install.sh adds it to fresh configs, so a manual `hyprland.lua` stays yours.
- Hit the header-bar **Reload Hyprland** button to re-apply from disk at any time.

## Keybindings

| Keys | Action |
|---|---|
| `SUPER` | (modifier) |
| `SUPER + Enter` | Open terminal |
| `SUPER + Space` | Open Rofi |
| `SUPER + Tab` | Toggle the app drawer |
| `SUPER + Shift + Tab` | Open the wallpaper picker |
| `SUPER + W` | Restart the bar |
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

The Hyprland-settings experience is inspired by **HyprMod** by **BlueManCZ**.

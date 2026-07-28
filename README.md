# simpbar

A Waybar setup for Hyprland that's simple, looks nice, and isn't distracting — plus an install script that sets up a whole ricing-friendly Arch desktop around it, and a companion GTK app to manage it all afterward.

Built for **Arch Linux** (and Arch-based distros like EndeavourOS, CachyOS, Garuda, XeroLinux — your mileage may vary depending on how much those ship pre-configured). Assumes **Hyprland 0.55+** (Lua config, `~/.config/hypr/hyprland.lua`).

## Install

```
curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash
```

The script is interactive — it'll ask a handful of questions (browser, Discord client, whether you want OBS/a video editor/game launchers/falcond, etc.) and needs your sudo password partway through. Grab a coffee; it installs a lot.

## What the install script sets up

**Bar, compositor & theming**
- Waybar (this repo's config), Hyprland, foot (terminal), rofi with its bundled Material theme, swaync (notifications)
- Dracula GTK theme, Zafiro-Dracula icon theme, Bibata Modern Classic cursor — all applied automatically via nwg-look's settings, no manual toggling needed
- nwg-drawer as the app-menu behind the bar's Menu button (ArcMenu-style GNOME Shell extensions don't run under Hyprland at all — this is the actual Wayland-native equivalent)
- fastfetch (also wired into every new bash/fish shell)

**Wallpaper**
- Downloads that day's Bing wallpaper into `~/Pictures/Wallpaper` and points waypaper at it
- swaybg is enabled as a systemd user service so it's already showing the wallpaper on login — no need to add anything to your Hyprland autostart yourself

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
Waybar ships with quick-launch icons next to the menu button: Browser, Discord, Files (Nautilus), Terminal, Steam, HyprMod, and Simpbar Welcome. Browser and Discord are smart about it — whichever one you actually installed is what launches by default, and you can change your mind later from the Welcome app without needing to touch waybar's config directly.

## Simpbar Welcome

A small GTK4 + libadwaita app that pops up once on first login (and is always reachable afterward — pinned in the bar, or via rofi/nwg-drawer). Tabs:

- **Welcome** — quick intro, plus a "Launch on startup" switch (toggles whether the app opens automatically each login)
- **Setup**
  - Update Simpbar & Arch Linux in one click, or just check for updates now
  - Quick launchers for waypaper, nwg-look, HyprMod, and pavucontrol
  - Install or remove text editors (Neovim/Gedit/Kate/Zed/VS Code)
  - Set which browser and Discord client the bar's pinned buttons should launch
  - Waybar controls: bar position (top/bottom), screen resolution (bar width), and font — each applies immediately and restarts the bar
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

The install script is all thanks to **@Ryzendew** aka **Mattscreative**.


<img width="1254" height="1254" alt="Neon Gradient Feather Emblem" src="https://github.com/user-attachments/assets/a04835bf-6f32-4dc9-8dc7-68c03ae6553a" />

# Simpbar

A native Zig/Wayland status bar for **Hyprland and MangoWM** — simple, clean, out of the way — plus an installer that sets up a ricing-friendly Arch desktop around it.

Built for **Arch Linux** (EndeavourOS, CachyOS, Garuda, XeroLinux should work too). Pick your window manager (**Hyprland** or **MangoWM**) up front; **Chaotic-AUR** is configured for binary packages.

## Install

```
curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash
```

Interactive — answers a few questions, asks for sudo **once**, then installs everything. Reboot when done (`systemctl reboot`).

What you get: bar + desktop widgets + app drawer with Bluetooth, wallpaper picker with matugen auto-theming, foot, rofi, swaync, fish, Neovim, browser/Discord of your choice, OBS/video tools optional. Gaming launchers (Steam/Lutris/Heroic) come from the Xero installer's GAMING picks.

## Desktop widgets

`simpbar-shell` paints widget cards on the wallpaper layer: clock, weather, media controls, system monitor, calendar with reminders, analog watch, sticky note.

- Same matugen colors as the bar, translucent cards.
- **Ctrl + drag** any card to move it — position saves to `~/.config/simpbar/shell.json`.
- Calendar reminders live in `~/.config/simpbar/reminders.txt` (`YYYY-MM-DD HH:MM text`).
- Notes save to `~/.config/simpbar/notes/`.

**Overview (`Alt + W`):** GNOME-style grid of live window screenshots with search + workspace strip + favorites dash. `simpbar-shell overview toggle` works from scripts too.

## Welcome & Config

**Simpbar Welcome** (first login, then pinned in the bar): intro, one-click updates, wallpaper picker, text-editor/browser/Discord picks, keybinding reference.

**Simpbar Config:** bar appearance + modules + nine WM pages (General, Monitors, Animations, Keybinds, Window/Workspace/Layer Rules, Autostart, Environment). Hyprland writes `hyprland-simpbar.lua`, MangoWM edits `~/.config/mango/cfg/` directly.

## Keybindings

Hyprland set (MangoWM in `~/.config/mango/cfg/keybinds.conf`, same spirit):

| Keys | Action |
|---|---|
| `SUPER + Enter` | Terminal |
| `SUPER + Space` | Rofi |
| `SUPER + Tab` | App drawer |
| `SUPER + Shift + Tab` | Wallpapers |
| `SUPER + W` | Restart bar |
| `Alt + W` | Overview |
| `SUPER + E` | Files |
| `SUPER + Q` | Close window |
| `SUPER + 1–0` | Workspaces |


## Images

<img width="1920" height="1080" alt="screenshot-2026-10-19_11-47-27" src="https://github.com/user-attachments/assets/b220c3cb-e8b4-43aa-8b16-ec077d18ae85" />
<img width="1920" height="1080" alt="screenshot-2026-10-19_11-48-40" src="https://github.com/user-attachments/assets/cdabfa9e-d839-43d6-9a3d-d0ad3a2809fe" />
<img width="1920" height="1080" alt="screenshot-2026-10-19_11-48-18" src="https://github.com/user-attachments/assets/a72ed3a5-118b-4d20-b88a-47dfa004dd5e" />
<img width="1919" height="1080" alt="screenshot-2026-10-19_11-48-00" src="https://github.com/user-attachments/assets/94a141d8-cf41-43c7-8448-b72c604dbd89" />
<img width="1919" height="1080" alt="screenshot-2026-10-19_11-47-43" src="https://github.com/user-attachments/assets/f005fcda-d05b-43d4-a554-895af6de5eda" />






## Credits

- Install script start: **Ryzendew**.
- `xero/xero-install.sh`: **XeroLinux Team** (Xero Arch Installer, GPL-3.0) — base-system installer this fork builds on.
- Hyprland-settings UX inspired by **HyprMod** by **BlueManCZ**.

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

simbar can recolor itself to match your wallpaper — Material You style — via **[matugen](https://github.com/InioX/matugen)**. Pick a wallpaper in the app drawer's Wallpapers tab and the bar recolors automatically; `simpbar-wallpaper` can also fetch new ones from Bing's archive and wallhaven.cc (see [Wallpapers](#wallpapers)).

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

## Desktop widgets (simpbar-shell)

A second native Zig binary beside the bar: `simpbar-shell` paints desktop widget cards — **clock**, **weather**, **media**, **system monitor**, **calendar**, an **analog watch**, and a **sticky note** — on a layer just above the wallpaper (below windows), reinventing the Event-Horizon-Shell style of desktop widgets on simpbar's own Wayland/shm/font plumbing. The installer builds and autostarts it, and it reads the same `matugen.json` colors, the same nerd font, and its own `~/.config/simpbar/shell.json` for layout:

```json
{
  "font_path": "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
  "card_bg_opacity": 55,
  "card_corner_radius": 12,
  "holiday_country": "AU",
  "holiday_region": "",
  "widgets": [
    { "id": "clock",    "x": 24, "y": 24 },
    { "id": "weather",  "x": 24, "y": 106 },
    { "id": "media",    "x": 24, "y": 176 },
    { "id": "system",   "x": 24, "y": 350 },
    { "id": "calendar", "x": 24, "y": 470 },
    { "id": "watch",    "x": 1711, "y": 24 },
    { "id": "note1",    "x": 24, "y": 700 }
  ]
}
```

Missing or malformed keys keep the defaults above (`font_path` empty defaults to the bar's JetBrainsMono Nerd). Cards are translucent (55% opacity by default) so the wallpaper shows through, frosted by a Hyprland layer rule for the `simpbar-shell` namespace — like the bar, a Wayland client can't blur what's behind its own surface, so the desktop config supplies it.

Each card repaints on its own lazy schedule — clock every second, system every 2s, media progress every second while playing (metadata refetched every 2s), weather every 20 minutes, calendar every 30s, watch six times a second for the sweep — and the shell only commits a new frame when something changed (widgets render into per-card tile caches first, so the watch's cadence only re-rasters its own 190×200 tile). Clicks do something where there's something to do: the media card has shuffle / previous / play-pause / next / repeat controls plus the real cover art from MPRIS (`file://` read directly, `http(s)://` downloaded with curl and decoded with gdk-pixbuf like the bar's tray icons; anything else keeps the music-note placeholder tile), weather opens wttr.in, and clicking the watch swaps the dial. The surface's input region is exactly the union of the cards, so the rest of the desktop passes clicks straight through.

**Repositioning cards** — hold **Ctrl** and drag any card with the left mouse button; it follows the pointer and snaps back on-screen if you drop it off the edge. Releasing writes the new positions back to `shell.json` (every other key round-tripped untouched), so the layout survives restarts.

**The analog watch** is drawn like a Seiko SKX diver — knurled steel case with a black 60-minute bezel (numerals, triangle pip at 12), lume plots (triangle at 12, bars at 6/9, dots elsewhere), a Mercedes hour hand and sword minute over a lollipop seconds hand, day–date window at 3, crown at 4, and SEIKO / Automatic dial print. No bracelet: just the head on short lug stubs. The seconds hand steps in 1/6-second beats: the 21,600 vph sweep of the 7S26 movement instead of a dead-beat tick. It's the one widget without a frosted card — the case *is* the chrome — paints straight from the wall clock (no hand angles to drift), and a click swaps between the black (SKX007) and a deep-blue dial. Like every other widget it can be Ctrl+dragged anywhere.

**The calendar card** shows a month grid (arrows step months, the month title jumps back to today) with a dot on every day that has a reminder. Click a day to edit its reminders through rofi: *+ New reminder* accepts free text (notified at 09:00 that day) or a full `HH:MM lead text` line, and selecting an existing entry deletes it. Reminders live in `~/.config/simpbar/reminders.txt`, one per line:

```
YYYY-MM-DD HH:MM [lead] text
2026-10-12 14:00 0 dentist appointment   # notify on the day at 14:00
2026-11-03 09:00 2 buy mum a gift        # notify two days before, at 09:00
2026-10-20 10:00 PayDay                  # hand-written: lead defaults to 0
```

A reminder notifies once at its date minus `lead` days (via `notify-send`), delivered up to 15 minutes late if the machine was asleep, and entries edited straight in the file are picked up on the next tick.

**Holidays** come from the free [date.nager.at](https://date.nager.at) API for `holiday_country` (ISO country code, default `AU`): public holidays are drawn on their day numbers in the matugen template's `holiday_color`, regional/state holidays dimmed, and the card's footer names today's holiday or the next upcoming one. Set `holiday_region` (e.g. `"WA"`) to show only your region's regional holidays alongside the nationwide ones; empty shows all. `holiday_color` is generated with the rest of the theme — a missing key falls back to a warm accent.

**The sticky note** — one fixed slot (`note1`) lets you type straight onto the desktop, fridge-door style. Click the card and the shell takes the keyboard: it decodes raw evdev keycodes with **xkbcommon** rather than asking for a focused window, so your layout's symbols still land even though no window has focus. **Enter** starts a new line, the arrow keys move the caret (Home/End jump to the line, Up/Down walk to the same column on the wrapped line above/below), and **Escape** saves and exits the field. The note lives in `~/.config/simpbar/notes/note1.txt`, so text survives restarts — the note only dies when you erase its text. Emptying the card and pressing Escape empties the file and the card falls back to a dim "click to type" placeholder, which is what an untouched note shows. Saves also fire when you click away from the card and, while editing, automatically shortly after you stop typing — so a crash can't eat your last sentence. There are no add/remove buttons: one card, always there, Ctrl+dragged like any other.

## Wallpapers

The drawer's second tab is a wallpaper picker: a grid of thumbnails of everything in your wallpaper folder, the active one outlined in the accent colour, a **Random** button, and live filtering through the same search box as the app grid. Picking one swaps the wallpaper and re-themes the whole desktop behind the drawer, which stays open on purpose so you can watch the colors change. `appdrawer wallpapers` opens straight onto that tab — which is where the bar's wallpaper button goes.

The footer grows a couple of buttons on this tab: **Bing** downloads today's Bing wallpaper and puts it on screen, **Online** fetches a random wallpaper from wallhaven.cc and applies it, and **Random** keeps picking locally — all three share a "Working…" busy state so they can't race each other. Next to them, **Options** opens a small *Wallhaven* panel paste your own API key into a masked field, pick the content rating (SFW / Sketchy / Explicit), and Save. It writes `~/.config/simpbar/wallhaven` — the same file `simpbar-wallpaper` reads — so a key pasted here is exactly a key typed in a terminal, one source of truth. When `WALLHAVEN_APIKEY` is set the key field is disabled with "managed by WALLHAVEN_APIKEY" rather than lying to you about which key will be used; the rating still applies. Whatever the fetch brought in is there in the grid the moment it lands, and the tile for what's on screen is badged, so the picker feels alive rather than static.

The search box up top becomes a wallhaven.cc search when you flip its **Local / Wallhaven** switch in the tab strip: type a query, press Enter, and the grid swaps to a *preview feed* of up to 24 matching thumbnails fetched over the network — nothing is downloaded yet. Each tile carries a rating badge (SFW green, Sketchy amber, NSFW red) straight from the API, which is exactly what the key is for: with `purity=111` configured you can scan explicit results before committing to one. Click a tile to download it and put it on screen, same as any other fetch; the file lands in your wallpaper folder so it's sitting in the local grid the next time you look. Switch back to **Local** to live-filter the folder again. The search reads the same key and purity from `~/.config/simpbar/wallhaven` as everything else — one set of credentials, no separate login for the drawer.

It's backed by `simpbar-wallpaper`, which owns the wallpaper rather than delegating to a front-end. That's a deliberate simplification: waypaper and azote are both GUI wrappers around swaybg, and the previous arrangement had two programs each keeping their own idea of the current wallpaper — one of which couldn't parse a filename containing spaces, so the bar ended up themed from a different image than the one on screen (see [the note above](#auto-theming-with-matugen)). One engine means one answer.

```
simpbar-wallpaper              open the picker (drawer's Wallpapers tab)
simpbar-wallpaper list         print "path<TAB>name" per wallpaper
simpbar-wallpaper set <img>    apply it: swaybg + matugen + remember it
simpbar-wallpaper random       apply a random wallpaper
simpbar-wallpaper current      print the wallpaper currently applied
```

Bare `simpbar-wallpaper` opens the drawer when quickshell is available, and falls back to rofi, then waypaper/azote, so it still does something useful on a machine without the drawer.

### Getting new wallpapers

The engine also fetches. Downloads land in your first wallpaper folder — so they show up in the picker immediately — and are *not* applied unless you pass `--apply`:

```
simpbar-wallpaper bing [--count N]          download N of the last 8 Bing wallpapers (1–8)
simpbar-wallpaper search <query> [opts]     list wallhaven.cc matches
simpbar-wallpaper search <query> --save N   ...and download the first N of them
simpbar-wallpaper fetch <id|url> [--apply]  download one wallhaven.cc wallpaper
simpbar-wallpaper random --online           fetch a random wallhaven.cc wallpaper and apply it
```

Useful `search` options: `--category general|anime|nature|people`, `--atleast 1920x1080` (or `any`), `--maxsize 10` in MB, `--sorting favorites|date_added|toplist`, `--purity`, `--page`, `--seed`, and `--thumbs`, which appends each result's small-thumbnail URL as an extra column after the image URL (that's what the drawer's preview grid reads). `--save`/`--apply` work on `bing` and `search` too.

`random --online` is the one that applies what it downloads — `random` is the verb that means "put something on my screen", so fetching without showing it would just be `fetch` with dice. Everything else leaves your current wallpaper alone. It draws from **every** category by default, not just `general`: the random feed's `general` rows are almost all SFW (page after page), while sketchy/explicit rows cluster in `anime` and `people`, so filtering to `general` would keep serving SFW even after you configured a key and `purity=110/111` — hiding exactly what the key unlocks. Purity still gates everything, so if you never configure a key it behaves exactly as before; `--category` works if you want to steer it.

**Output is paths, one per line, on stdout**; progress and diagnostics go to stderr. So it composes:

```sh
simpbar-wallpaper search 'northern lights' --maxsize 5 | head -1
simpbar-wallpaper bing --count 8 | tail -1 | xargs -I{} simpbar-wallpaper set {}
```

**Accounts and content rating.** SFW search needs no credentials and is the default. For anything else, put your own key from <https://wallhaven.cc/user/settings/api> in `~/.config/simpbar/wallhaven` (or export `WALLHAVEN_APIKEY`):

```
key=your-key-here
purity=100
```

`purity` is wallhaven's 3-digit mask: `100` SFW, `110` adds questionable, `111` adds explicit. Anything but `100` requires the key, and is refused without one. SFW stays the default when no key is present — an adult-rated wallpaper appearing on screen because a key happened to be lying around is not a trade this script makes on your behalf.

**Three things about the wallhaven API that the defaults here work around**, all found by testing rather than by reading docs:

- `sorting=toplist` is the API's own default and is a small hand-picked set — "aurora borealis" has 2 results under it and 588 under `favorites`. Most wallpaper wants people who actually saved a wallpaper, so `favorites` is the default here.
- `categories` is accepted by `/search` and then ignored: `general`, `nature` and `anime` all return the same total, and `nature`/`people` never come back at all — paging through hundreds of rows turns up general, anime and people only. The category is therefore filtered locally, so `--category` means what it says. The cost is that a filtered page can come back empty while later pages have matches — the "no matches" message says so rather than pretending the query found nothing. `nature` is the casualty: the API simply never serves it, so `--category nature` on `random --online` fails with an honest message after a few pages, and on `search` it finds nothing. general, people and anime all work.
- The single-wallpaper lookup `/api/v1/f/<id>` needs an API key even for SFW content, and `/api/v1/random` currently answers HTTP 404 to every anonymous request. So `search` returns the direct image URL as its last column, `search --save N` downloads straight from those, `fetch` takes a URL as readily as an id, and `random --online` is built on `/search?sorting=random`. Nothing in the common path needs an account.

**Downloads are verified, not trusted.** A response has to start with real image magic bytes *and* be at least 16 KB before it is moved into the wallpaper folder, and it is written to a `.part` sibling and renamed, so a half-finished or bogus file never becomes a wallpaper the picker offers. Both checks exist because of real behaviour: Bing answers an unknown image id with HTTP 200 and a 1192-byte 1×1 JPEG that passes every byte check but would sit on your desktop as a blurry black rectangle that matugen then themes from. Real Bing files are 330 KB (1080p) and 3.6 MB (UHD). Existing files are never re-downloaded without `--force`.

Only the fetch subcommands need `curl` and `python3`; `list`, `set`, `random` and `current` work without either, so a wallpaper you already have is never gated behind being able to download a new one.

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
- simpbar-shell: desktop widget cards (clock/weather/media/system monitor/calendar/analog watch/sticky note) on a layer just above the wallpaper, themed from the same matugen colors (see [Desktop widgets](#desktop-widgets-simpbar-shell))
- Dracula GTK theme, Zafiro-Dracula icon theme, Bibata Modern Classic cursor — all applied automatically via nwg-look's settings, no manual toggling needed
- nwg-drawer, usable from rofi as a fallback app-menu (ArcMenu-style GNOME Shell extensions don't run under Hyprland at all)
- fastfetch (also wired into every new bash/fish shell)

**Wallpaper**
- Downloads that day's Bing wallpaper into `~/Pictures/Wallpaper` (through the wallpaper engine, so it's verified and de-duplicated like every other fetch — see [Wallpapers](#wallpapers)) (via the wallpaper engine, so the download is verified and de-duplicated the same way as every other fetch)
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

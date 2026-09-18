#!/bin/bash
# Simpbar Installer
# Debian Linux only (built against Debian sid/testing — package names may
# differ on older Debian releases)
#
# One-liner:
#   curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install-debian.sh | bash

set -e

# ── Colors ──────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_BLUE=$(tput setaf 4); C_GREEN=$(tput setaf 2)
    C_RED=$(tput setaf 1); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
    C_MAGENTA=$(tput setaf 5)
else
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""
fi

TOTAL_STEPS=8
STEP=0

banner() {
    local logo_text art_text
    logo_text=$(cat <<'LOGO'
    _,met$$$g.
  ,g$$$$$$$$P.
 ,d$$P''  "$$b
,$$P'      `$$$
,$$$         $$
 `$$b.    ,d$$'
  `Y$$$$$$$$P'

LOGO
)
    art_text=$(cat <<'ART'
   _____ _                 _
  / ____(_)               | |
 | (___  _ _ __ ___  _ __ | |__   __ _ _ __
  \___ \| | '_ ` _ \| '_ \| '_ \ / _` | '__|
  ____) | | | | | | | |_) | |_) | (_| | |
 |_____/|_|_| |_| |_| .__/|_.__/ \__,_|_|
                     | |
                     |_|          installer
ART
)
    mapfile -t logo_lines <<< "$logo_text"
    mapfile -t art_lines <<< "$art_text"

    printf '\n'
    local i n
    n=${#art_lines[@]}
    for ((i = 0; i < n; i++)); do
        printf '  %s%-18s%s   %s%s%s\n' \
            "$C_BLUE$C_BOLD" "${logo_lines[$i]:-}" "$C_RESET" \
            "$C_MAGENTA$C_BOLD" "${art_lines[$i]:-}" "$C_RESET"
    done
    printf '\n'
}

step() {
    STEP=$((STEP + 1))
    printf '\n%s[%d/%d]%s %s%s%s\n' "$C_BLUE$C_BOLD" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
}

ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"; }

die() {
    fail "$1"
    printf '\n%sInstall aborted.%s\n' "$C_RED$C_BOLD" "$C_RESET"
    exit 1
}

# Run a command quietly, showing a spinner, then a check/cross line.
run_spinner() {
    local msg="$1"; shift
    if [ "${#msg}" -gt 60 ]; then
        msg="${msg:0:57}..."
    fi
    sudo -v 2>/dev/null
    local logfile
    logfile=$(mktemp)
    ( "$@" >"$logfile" 2>&1 ) &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#spin} ))
        printf '\r  %s %s' "${spin:$i:1}" "$msg"
        sleep 0.1
    done
    if wait "$pid"; then
        printf '\r  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$msg"
        rm -f "$logfile"
        return 0
    else
        printf '\r  %s✗%s %s\n' "$C_RED" "$C_RESET" "$msg"
        echo "----- output -----"
        cat "$logfile"
        echo "-------------------"
        rm -f "$logfile"
        return 1
    fi
}

# Print a numbered menu, read one choice from /dev/tty, and fall back to
# a default when input isn't available or left blank.
#   prompt_choice RESULT_VAR DEFAULT "Question?" "Option 1" "Option 2" ...
prompt_choice() {
    local result_var="$1" default="$2" question="$3"; shift 3
    local n=1 opt choice

    printf '\n  %s%s%s\n' "$C_YELLOW" "$question" "$C_RESET"
    for opt in "$@"; do
        printf '    %s%d)%s %s\n' "$C_CYAN" "$n" "$C_RESET" "$opt"
        n=$((n + 1))
    done
    printf '  %sChoice [%s]: %s' "$C_BOLD" "$default" "$C_RESET"

    if [ -r /dev/tty ]; then
        read -r choice < /dev/tty
    else
        warn "No interactive terminal available — defaulting to option $default"
        choice="$default"
    fi
    [ -z "$choice" ] && choice="$default"

    printf -v "$result_var" '%s' "$choice"
}

# Add an official .deb repo (for browsers), keyring under /etc/apt/keyrings
# and a sources.list entry, then refresh package lists. Returns 1 on failure.
#   add_apt_repo <name> <key-url> "<deb line after the arch=/signed-by= part>"
add_apt_repo() {
    local name="$1" keyurl="$2" deb_uri="$3" arch
    arch=$(dpkg --print-architecture)
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "$keyurl" | sudo gpg --batch --yes --dearmor \
        -o "/etc/apt/keyrings/$name.gpg" || return 1
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/%s.gpg] %s\n' "$arch" "$name" "$deb_uri" \
        | sudo tee "/etc/apt/sources.list.d/$name.list" >/dev/null || return 1
    sudo apt-get update -qq || return 1
}

# zig (0.16.0) isn't packaged in Debian — if the right version isn't already
# on PATH, download the official prebuilt and install it under /usr/local/zig
# (symlinked into /usr/local/bin) so it survives and rebuilds keep working.
ZIG_VER=0.16.0
ensure_zig() {
    if command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VER" ]; then
        ok "zig $ZIG_VER already installed"
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) ZIG_TRIPLE=x86_64 ;;
        aarch64|arm64) ZIG_TRIPLE=aarch64 ;;
        *)
            warn "Unsupported architecture for the official zig build — install zig $ZIG_VER manually, then re-run"
            return 1
            ;;
    esac
    local tmpdir tarball
    tmpdir=$(mktemp -d)
    tarball="zig-$ZIG_TRIPLE-linux-$ZIG_VER.tar.xz"
    run_spinner "Downloading zig $ZIG_VER" \
        curl -fsSL -o "$tmpdir/$tarball" "https://ziglang.org/download/$ZIG_VER/$tarball" \
        || { rm -rf "$tmpdir"; return 1; }
    run_spinner "Extracting zig to /usr/local/zig" \
        sudo bash -c "rm -rf /usr/local/zig && mkdir -p /usr/local/zig && tar -xJf '$tmpdir/$tarball' -C /usr/local/zig --strip-components=1" \
        || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    run_spinner "Symlinking /usr/local/bin/zig" sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig \
        || return 1
    ok "zig $ZIG_VER ready"
}

# The Nerd Font is required by the bar (font.zig points at
# /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf) but isn't in any
# Debian repo, so grab it straight from the upstream release.
NERD_FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
install_nerd_font() {
    local tmpdir
    tmpdir=$(mktemp -d)
    run_spinner "Downloading JetBrainsMono Nerd Font" \
        curl -fsSL -o "$tmpdir/jbm.zip" "$NERD_FONT_URL" \
        || { rm -rf "$tmpdir"; return 1; }
    sudo mkdir -p /usr/share/fonts/TTF
    run_spinner "Installing Nerd Font to /usr/share/fonts/TTF" \
        sudo unzip -o -q "$tmpdir/jbm.zip" -d /usr/share/fonts/TTF \
        || { rm -rf "$tmpdir"; return 1; }
    # Keep only the TTFs; drop the LICENSE/README the zip also contains.
    sudo find /usr/share/fonts/TTF -maxdepth 1 -type f ! -iname '*.ttf' -delete 2>/dev/null || true
    rm -rf "$tmpdir"
}

banner

# ── Step 0: platform check ─────────────────────────────────────────
command -v apt-get >/dev/null || die "This script is Debian-family only (apt-get not found)."

printf '\n%sThis installer needs sudo access.%s\n' "$C_BOLD" "$C_RESET"
sudo -v || die "Could not authenticate with sudo."
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ── Step 1: prerequisites ──────────────────────────────────────────
step "Checking prerequisites"
MISSING_PREREQS=()
command -v curl  >/dev/null || MISSING_PREREQS+=(curl)
command -v unzip >/dev/null || MISSING_PREREQS+=(unzip)
command -v gawk  >/dev/null || MISSING_PREREQS+=(gawk)
command -v git   >/dev/null || MISSING_PREREQS+=(git)
command -v gpg   >/dev/null || MISSING_PREREQS+=(gnupg)
command -v fc-cache >/dev/null || MISSING_PREREQS+=(fontconfig)
command -v lspci >/dev/null || MISSING_PREREQS+=(pciutils)

if [ "${#MISSING_PREREQS[@]}" -gt 0 ]; then
    run_spinner "Installing ${MISSING_PREREQS[*]}" sudo apt-get install -y "${MISSING_PREREQS[@]}" \
        || die "Failed to install prerequisites: ${MISSING_PREREQS[*]}"
else
    ok "prerequisites already installed"
fi

HOME_DIRS=(Pictures Videos Documents Music Projects)
mkdir -p "${HOME_DIRS[@]/#/$HOME/}"
ok "Created ~/{${HOME_DIRS[*]// /,}}"

# ── Step 2: fetch simpbar config + source ─────────────────────────────
step "Fetching simpbar theme"
mkdir -p ~/.config

run_spinner "Downloading simpbar config" \
    curl -fL -o /tmp/simpbar.zip https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip \
    || die "Could not download simpbar (check your network connection)."

run_spinner "Extracting archive" \
    unzip -o /tmp/simpbar.zip -d /tmp/simpbar-temp \
    || die "Could not extract simpbar archive."
rm -f /tmp/simpbar.zip

CONFIG_DIRS=(hypr swaync fastfetch)
for d in "${CONFIG_DIRS[@]}" simpbar; do
    if [ ! -d "/tmp/simpbar-temp/simpbar-main/$d" ]; then
        rm -rf /tmp/simpbar-temp
        die "Downloaded archive did not contain a $d/ directory — layout may have changed upstream."
    fi
done

for d in "${CONFIG_DIRS[@]}"; do
    cp -r "/tmp/simpbar-temp/simpbar-main/$d" ~/.config/
done
ok "Configs placed in ~/.config/{${CONFIG_DIRS[*]// /,}}"

mkdir -p ~/.local/share/simpbar
rm -rf ~/.local/share/simpbar/simpbar
cp -r /tmp/simpbar-temp/simpbar-main/simpbar ~/.local/share/simpbar/simpbar
ok "simpbar source placed in ~/.local/share/simpbar/simpbar"

# The repo also tracks the files install.sh normally embeds inline — copy
# them across now so they end up with the source here (installed to /usr/bin
# in Step 6). simpbar-check-updates, the launchers, and the .desktop entries
# are all distro-aware (they detect apt vs pacman at runtime).
AUX_FILES=(logo.png simpbar-check-updates simpbar-launch-browser simpbar-launch-discord simpbar-wallpaper simpbar-restore-wallpaper simpbar-welcome.desktop simpbar-config.desktop)
for f in "${AUX_FILES[@]}"; do
    if [ ! -e "/tmp/simpbar-temp/simpbar-main/$f" ]; then
        rm -rf /tmp/simpbar-temp
        die "Downloaded archive did not contain $f — layout may have changed upstream."
    fi
    cp "/tmp/simpbar-temp/simpbar-main/$f" ~/.local/share/simpbar/
done
ok "simpbar aux files (logo, update-checker, launchers, .desktop entries) placed in ~/.local/share/simpbar"
rm -rf /tmp/simpbar-temp

# waypaper is Arch/AUR-only — not in Debian. Azote (installed above) is the
# wallpaper picker instead; both are front-ends to swaybg and ~/Pictures/
# Wallpaper is created later in Step 4 (the Bing wallpaper download).
# Comment waypaper's autostart line out of hyprland.lua — the systemd
# swaybg.service (Bing default) and azote-restore.service (last azote pick)
# installed later handle the wallpaper on Debian.
sed -i -E 's|^(\s*)hl\.exec_cmd\("waypaper --restore"\)|\1--hl.exec_cmd("waypaper --restore")  # Debian: not packaged, swaybg.service + azote-restore.service handle the wallpaper|' ~/.config/hypr/hyprland.lua
ok "waypaper autostart disabled in hyprland.lua (not packaged on Debian) — swaybg.service sets Bing, azote-restore.service restores your last azote pick"

# ── Step 3: enable i386 (for Steam) + refresh lists ──────────────────
# Steam on Debian ships 32-bit binaries, so the i386 foreign architecture
# has to be enabled (the apt equivalent of Arch's multilib). Harmless on
# machines that never install Steam.
step "Enabling i386 architecture (for Steam)"
if dpkg --print-foreign-architectures | grep -qx i386; then
    ok "i386 architecture already enabled"
else
    run_spinner "Adding i386 architecture" sudo dpkg --add-architecture i386 \
        || die "Could not enable the i386 architecture."
    ok "i386 architecture enabled"
fi

run_spinner "Updating package lists" sudo apt-get update \
    || die "Could not refresh package lists — check /etc/apt/sources.list"

# ── Step 4: detect GPU and install packages ──────────────────────────
step "Detecting GPU"

GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga compatible controller|3d controller')
GPU_PKGS=()

if echo "$GPU_INFO" | grep -qi nvidia; then
    ok "NVIDIA GPU detected — checking for the proprietary driver"
    NVIDIA_CAND=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}')
    if [ -n "$NVIDIA_CAND" ] && [ "$NVIDIA_CAND" != "(none)" ]; then
        GPU_PKGS+=(nvidia-driver nvidia-settings libnvidia-egl-wayland nvidia-vulkan-icd)
    else
        warn "nvidia-driver is not in your enabled repos (it lives in Debian 'non-free') — enable non-free, then run: sudo apt-get update && sudo apt-get install nvidia-driver"
    fi
fi
if echo "$GPU_INFO" | grep -Eqi 'amd|advanced micro devices|radeon'; then
    ok "AMD GPU detected — adding Mesa + Vulkan (RADV) packages"
    GPU_PKGS+=(mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri)
fi
if echo "$GPU_INFO" | grep -qi intel; then
    ok "Intel GPU detected — adding Mesa + Vulkan packages"
    GPU_PKGS+=(mesa-vulkan-drivers libvulkan1 intel-media-va-driver)
fi

if [ "${#GPU_PKGS[@]}" -eq 0 ]; then
    warn "Could not detect a known GPU vendor (NVIDIA/AMD/Intel) via lspci — install graphics drivers manually if needed"
else
    mapfile -t GPU_PKGS < <(printf '%s\n' "${GPU_PKGS[@]}" | sort -u)
fi

step "Installing packages"

# Build dependencies for the Zig apps: freetype (font rendering), gdk-pixbuf
# (tray icon decoding), wayland client + protocols, GTK4/libadwaita/glib
# (the Welcome + Config companion apps). Everything else is what the Hyprland
# setup + bar widgets shell out to, mirrored from the Arch installer.
# Debian name changes vs the Arch list: swaync → sway-notification-center,
# ttf-jetbrains-mono-nerd → not packaged (downloaded in Step 4), nwg-drawer →
# not packaged (rofi is the launcher), bazaar → not packaged, waypaper →
# azote (both are "pick a wallpaper" front-ends to swaybg), and the
# pacman/AUR-only items from the Arch list (zafiro, dracula,
# protonplus, bazaar, nwg-drawer, heroic, discord) are handled
# below where they have a real Debian package or a manual/flatpak path.
APT_PKGS=(
    # simpbar build/run deps
    libfreetype-dev libgdk-pixbuf-2.0-dev libwayland-dev wayland-protocols
    libgtk-4-dev libadwaita-1-dev libglib2.0-dev
    playerctl gnome-calendar mate-polkit
    libglib2.0-bin gsettings-desktop-schemas dconf-gsettings-backend
    # Hyprland setup
    hyprland foot fastfetch neovim usbutils
    swaybg azote sway-notification-center rofi flatpak nwg-look pavucontrol
    pipewire pipewire-pulse wireplumber gnome-disk-utility fish
    grim slurp xdg-desktop-portal-hyprland cliphist wl-clipboard
    fonts-noto-core fonts-noto-color-emoji
    qt6ct breeze libnotify-bin
    wlogout steam-devices libvulkan1 libgl1-mesa-dri
    bibata-cursor-theme
)
# 'noto-fonts' is the Arch name; drop anything apt doesn't know from the
# desired set rather than failing the whole install over one stale name.
APT_PKGS_AVAIL=()
for p in "${APT_PKGS[@]}"; do
    if apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{c=$2} END{exit !(c && c != "(none)")}'; then
        APT_PKGS_AVAIL+=("$p")
    else
        warn "Package '$p' not found in your repos — skipping it"
    fi
done
APT_PKGS=("${APT_PKGS_AVAIL[@]}")
APT_PKGS+=("${GPU_PKGS[@]}")

prompt_choice FILE_MANAGER_CHOICE 1 "Which file manager would you like to use?" \
    "Nautilus" "Nemo" "Dolphin"
case "$FILE_MANAGER_CHOICE" in
    2) FILE_MANAGER_NAME="Nemo";    FILE_MANAGER_BIN="nemo";    APT_PKGS+=(nemo) ;;
    3) FILE_MANAGER_NAME="Dolphin"; FILE_MANAGER_BIN="dolphin"; APT_PKGS+=(dolphin) ;;
    *) FILE_MANAGER_NAME="Nautilus"; FILE_MANAGER_BIN="nautilus"; APT_PKGS+=(nautilus) ;;
esac

# hyprland.lua (copied to ~/.config/hypr in Step 2) hardcodes its
# fileManager variable to nautilus — point it at whichever one was chosen.
if [ -e ~/.config/hypr/hyprland.lua ]; then
    sed -i "s/^local fileManager = \".*\"/local fileManager = \"$FILE_MANAGER_BIN\"/" ~/.config/hypr/hyprland.lua
fi

prompt_choice OBS_CHOICE 2 "Will you be using OBS Studio for recording/streaming?" "Yes" "No"
[ "$OBS_CHOICE" = 1 ] && APT_PKGS+=(obs-studio)

prompt_choice VIDEO_EDITOR_YN 2 "Would you like to install a video editor?" "Yes" "No"
if [ "$VIDEO_EDITOR_YN" = 1 ]; then
    prompt_choice VIDEO_EDITOR_CHOICE 1 "Which video editor would you like to install?" \
        "Kdenlive" "Shotcut" "Flowblade"
    case "$VIDEO_EDITOR_CHOICE" in
        1) VIDEO_EDITOR_NAME="Kdenlive";  APT_PKGS+=(kdenlive) ;;
        2) VIDEO_EDITOR_NAME="Shotcut";   APT_PKGS+=(shotcut) ;;
        3) VIDEO_EDITOR_NAME="Flowblade"; APT_PKGS+=(flowblade) ;;
        *) VIDEO_EDITOR_NAME="" ;;
    esac
else
    VIDEO_EDITOR_NAME=""
fi

# Game launchers: Lutris is packaged; Heroic isn't in Debian repos, but
# ships on Flathub (added later in this step) — both are offered, same as
# the Arch installer's "Lutris / Heroic / Both / Neither".
prompt_choice LAUNCHER_CHOICE 4 "Would you like to install any game launchers?" \
    "Lutris" "Heroic (via Flatpak)" "Both" "Neither"
INSTALL_HEROIC=0
case "$LAUNCHER_CHOICE" in
    1) APT_PKGS+=(lutris) ;;
    2) INSTALL_HEROIC=1 ;;
    3) APT_PKGS+=(lutris); INSTALL_HEROIC=1 ;;
    *) ;;
esac

# Discord clients: on Debian the official client isn't packaged either —
# install the official .deb (deps come from the repos). Vesktop/Equibop
# aren't offered on Debian, so only the official client is selectable.
prompt_choice DISCORD_CHOICE 2 "Which Discord client would you like to install?" \
    "Discord (official .deb)" "Skip — don't install a Discord client"

INSTALL_DISCORD=0
DISCORD_NAME=""
case "$DISCORD_CHOICE" in
    1) INSTALL_DISCORD=1; DISCORD_NAME="Discord" ;;
    *) DISCORD_NAME="" ;;
esac

# matugen isn't in Debian repos — it's pulled from crates.io (which needs
# Rust, hence rustc + cargo below when requested). simpbar reads its output
# (~/.config/simpbar/matugen.json) for wallpaper-based auto-theming.
printf '\n  %smatugen%s is the Material You colorscheme generator simpbar uses for\n' "$C_BOLD" "$C_RESET"
printf '  auto-theming: pick a wallpaper and it recolors the bar to match it\n'
printf '  (the bar has an %sAuto-theme with matugen%s toggle in simpbar-config). It is\n' "$C_BOLD" "$C_RESET"
printf '  not in the Debian repos, so installing it compiles it from source.\n'
prompt_choice MATUGEN_CHOICE 1 "Would you like to install matugen for wallpaper-based auto-theming?" "Yes — install Rust + matugen" "No"
INSTALL_MATUGEN=0
[ "$MATUGEN_CHOICE" = 1 ] && INSTALL_MATUGEN=1
[ "$INSTALL_MATUGEN" -eq 1 ] && APT_PKGS+=(rustc cargo)

printf '  Installing %d packages via apt:\n    %s\n' "${#APT_PKGS[@]}" "${APT_PKGS[*]}"
run_spinner "apt: installing ${#APT_PKGS[@]} packages" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PKGS[@]}" \
    || die "Failed to install packages: ${APT_PKGS[*]}"

MISSING_PKGS=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || dpkg -s "${pkg/:amd64}" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    warn "apt reported success but these packages aren't actually installed: ${MISSING_PKGS[*]}"
else
    ok "Verified all apt packages are installed"
fi

# Nerd font (packaged nowhere in Debian) — required by the bar's font.zig.
install_nerd_font || warn "Could not install the Nerd Font — run install-debian.sh again or drop JetBrainsMono Nerd Font TTF files into /usr/share/fonts/TTF manually"

# polkit auth agent: mate-polkit's agent path differs from the Arch one
# hardcoded in hyprland.lua — point the autostart at the real binary.
POLKIT_DEBIAN=""
for cand in /usr/libexec/polkit-mate-authentication-agent-1 /usr/lib/mate-polkit/polkit-mate-authentication-agent-1; do
    [ -x "$cand" ] && POLKIT_DEBIAN="$cand"
done
if [ -n "$POLKIT_DEBIAN" ]; then
    sed -i -E "s|hl\.exec_cmd\(\"[^\"]*authentication-agent-1[^\"]*\"\)|hl.exec_cmd(\"$POLKIT_DEBIAN\")|" ~/.config/hypr/hyprland.lua
    ok "polkit autostart pointed at $POLKIT_DEBIAN"
else
    warn "Could not locate the mate-polkit agent — add its path to ~/.config/hypr/hyprland.lua manually"
fi

run_spinner "Refreshing font cache" fc-cache -f \
    || warn "Could not refresh the font cache — run 'fc-cache -f' manually if icons look missing"

# Build simpbar (the bar), simpbar-welcome, and simpbar-config from the
# source placed in ~/.local/share/simpbar/simpbar in Step 2. The bar uses
# zig-wayland (net-fetched at build time), freetype2, gdk-pixbuf; the two
# GTK4 apps need gtk4/libadwaita — all installed above. With zig now in
# PATH, one invocation builds all three (build.zig's default install step).
ensure_zig || die "zig $ZIG_VER is required to build simpbar."

run_spinner "Building simpbar" bash -c 'cd ~/.local/share/simpbar/simpbar && zig build -Doptimize=ReleaseFast' \
    || die "Failed to build simpbar — check libfreetype-dev, libgdk-pixbuf-2.0-dev, libwayland-dev, wayland-protocols, libgtk-4-dev, and libadwaita-1-dev installed correctly."

run_spinner "Installing simpbar to /usr/bin" \
    sudo install -Dm755 ~/.local/share/simpbar/simpbar/zig-out/bin/simpbar /usr/bin/simpbar \
    || die "Failed to install the simpbar binary to /usr/bin."
ok "simpbar built and installed to /usr/bin/simpbar"

run_spinner "Installing simpbar-welcome to /usr/bin" \
    sudo install -Dm755 ~/.local/share/simpbar/simpbar/zig-out/bin/simpbar-welcome /usr/bin/simpbar-welcome \
    || die "Failed to install the simpbar-welcome binary to /usr/bin."
ok "simpbar-welcome built and installed to /usr/bin/simpbar-welcome"

run_spinner "Installing simpbar-config to /usr/bin" \
    sudo install -Dm755 ~/.local/share/simpbar/simpbar/zig-out/bin/simpbar-config /usr/bin/simpbar-config \
    || die "Failed to install the simpbar-config binary to /usr/bin."
ok "simpbar-config built and installed to /usr/bin/simpbar-config"

# Enable the pipewire audio stack as user services so pavucontrol has
# something to control without needing a reboot/relogin first.
PIPEWIRE_UNITS=(pipewire.socket pipewire-pulse.socket wireplumber.service)
for unit in "${PIPEWIRE_UNITS[@]}"; do
    run_spinner "Enabling $unit" systemctl --user enable --now "$unit" \
        || warn "Could not enable $unit — enable it manually: systemctl --user enable --now $unit"
done

run_spinner "Adding Flathub remote" \
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo \
    || warn "Could not add Flathub remote — add it manually: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"

if [ "$INSTALL_HEROIC" -eq 1 ]; then
    run_spinner "Installing Heroic Games Launcher (Flatpak)" \
        flatpak install -y --noninteractive flathub com.heroicgameslauncher.hgl \
        || warn "Heroic install failed — try manually: flatpak install flathub com.heroicgameslauncher.hgl"
fi

if [ "$INSTALL_DISCORD" -eq 1 ]; then
    DEB_TMP=$(mktemp -d)
    if run_spinner "Downloading Discord (.deb)" \
        curl -fsSL -o "$DEB_TMP/discord.deb" "https://discord.com/api/download?platform=linux&format=deb"; then
        run_spinner "Installing Discord" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB_TMP/discord.deb" \
            || warn "Discord .deb install failed — retry manually: sudo apt-get install ./discord.deb"
    else
        warn "Could not download Discord's .deb — install it from discord.com/download manually"
    fi
    rm -rf "$DEB_TMP"
fi

# nwg-look reads/writes gsettings directly (no private config file), so setting
# these keys ourselves has the same effect as toggling "Prefer dark" in its GUI.
if command -v gsettings >/dev/null; then
    run_spinner "Setting nwg-look theme to prefer dark" \
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' \
        || warn "Could not set dark theme preference — toggle 'Prefer dark' manually in nwg-look"
else
    warn "gsettings not found — open nwg-look and toggle 'Prefer dark' manually"
fi

# Bibata cursor theme is packaged on Debian (bibata-cursor-theme) — apply it
# the same way the Arch installer does (best-effort: confirm the folder name).
if dpkg -s bibata-cursor-theme >/dev/null 2>&1 && command -v gsettings >/dev/null; then
    BIBATA_DIR=$(find /usr/share/icons -maxdepth 1 -iname 'Bibata-Modern-Classic*' -print -quit 2>/dev/null)
    if [ -n "$BIBATA_DIR" ]; then
        run_spinner "Applying Bibata Modern Classic cursor" \
            gsettings set org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Classic' \
            || warn "Could not apply the cursor theme — select it manually in nwg-look"
    else
        warn "bibata-cursor-theme installed but no Bibata-Modern-Classic folder found — check: ls /usr/share/icons | grep -i bibata"
    fi
fi

# Rofi ships a bundled "material" theme in /usr/share/rofi/themes — just
# point config.rasi at it rather than fetching anything extra.
mkdir -p ~/.config/rofi
if [ -e ~/.config/rofi/config.rasi ]; then
    warn "~/.config/rofi/config.rasi already exists — leaving your existing rofi config alone"
else
    cat > ~/.config/rofi/config.rasi <<'EOF'
configuration {
    display-drun: "Apps";
    display-run: "Run";
    display-window: "Window";
    show-icons: true;
}

@theme "material"
EOF
    if [ -e /usr/share/rofi/themes/material.rasi ]; then
        ok "rofi set to use the Material theme"
    else
        warn "rofi shipped without a material theme here — tweak @theme in ~/.config/rofi/config.rasi to taste"
    fi
fi

# foot terminal config — same one-liner as the Arch installer.
mkdir -p ~/.config/foot
if [ -e ~/.config/foot/foot.ini ]; then
    warn "~/.config/foot/foot.ini already exists — leaving your existing foot config alone"
else
    cat > ~/.config/foot/foot.ini <<'FOOTEOF'
# -*- conf -*-

# shell=$SHELL (if set, otherwise user's default shell from /etc/passwd)
# term=foot (or xterm-256color if built with -Dterminfo=disabled)
# login-shell=no

# app-id=foot # globally set wayland app-id. Default values are "foot" and "footclient" for desktop and server mode
# title=foot
# locked-title=no

font=JetBrainsMonoNL:size=10
# font-bold=<bold variant of regular font>
# font-italic=<italic variant of regular font>
# font-bold-italic=<bold+italic variant of regular font>
# font-size-adjustment=0.5
# line-height=<font metrics>
# letter-spacing=0
# horizontal-letter-offset=0
# vertical-letter-offset=0
# underline-offset=<font metrics>
# underline-thickness=<font underline thickness>
# strikeout-thickness=<font strikeout thickness>
# box-drawings-uses-font-glyphs=no
# dpi-aware=no
# gamma-correct-blending=no

# initial-color-theme=dark
# initial-window-size-pixels=700x500  # Or,
# initial-window-size-chars=<COLSxROWS>
# initial-window-mode=windowed
# pad=0x0 center-when-maximized-and-fullscreen
# resize-by-cells=yes
# resize-keep-grid=yes
# resize-delay-ms=100

# bold-text-in-bright=no
# word-delimiters=,│`|:"'()[]{}<>
# selection-target=primary
# workers=<number of logical CPUs>
# utmp-helper=/usr/lib/utempter/utempter  # When utmp backend is ‘libutempter’ (Linux)
# utmp-helper=/usr/libexec/ulog-helper    # When utmp backend is ‘ulog’ (FreeBSD)

# uppercase-regex-insert=yes

[environment]
# name=value

[security]
# osc52=enabled  # disabled|copy-enabled|paste-enabled|enabled

[bell]
# system=yes
# urgent=no
# notify=no
# visual=no
# command=
# command-focused=no

[desktop-notifications]
# command=notify-send --wait --app-name ${app-id} --icon ${app-id} --category ${category} --urgency ${urgency} --expire-time ${expire-time} --hint STRING:image-path:${icon} --hint BOOLEAN:suppress-sound:${muted} --hint STRING:sound-name:${sound-name} --replace-id ${replace-id} ${action-argument} --print-id -- ${title} ${body}
# command-action-argument=--action ${action-name}=${action-label}
# close=""
# inhibit-when-focused=yes


[scrollback]
# lines=1000
# multiplier=3.0
# indicator-position=relative
# indicator-format=""

[url]
# launch=xdg-open ${url}
# label-letters=sadfjklewcmpgh
# style=dotted  (none|single|double|curly|dotted|dashed)
# osc8-underline=url-mode
# regex=(((https?://|mailto:|ftp://|file:|ssh:|ssh://|git://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:)|www\.)([0-9a-zA-Z:/?#@!$&*+,;=.~_%^\-]+|\([]\["0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*\)|\[[\(\)"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*\]|"[]\[\(\)0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*"|'[]\[\(\)0-9a-zA-Z:/?#@!$&*+,;=.~_%^\-]*')+([0-9a-zA-Z/#@$&*+=~_%^\-]|\([]\["0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*\)|\[[\(\)"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*\]|"[]\[\(\)0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\-]*"|'[]\[\(\)0-9a-zA-Z:/?#@!$&*+,;=.~_%^\-]*'))

# You can define your own regex's, by adding a section called
# 'regex:<ID>' with a 'regex' and 'launch' key. These can then be tied
# to a key-binding. See foot.ini(5) for details

# [regex:your-fancy-name]
# regex=<a POSIX-Extended Regular Expression>
# launch=<path to script or application> ${match}
#
# [key-bindings]
# regex-launch=[your-fancy-name] Control+Shift+q
# regex-copy=[your-fancy-name] Control+Alt+Shift+q

[cursor]
 style=underline
# blink=no
# blink-rate=500
# beam-thickness=1.5
# underline-thickness=<font underline thickness>

[mouse]
hide-when-typing=no
# alternate-scroll-mode=yes

[touch]
# long-press-delay=400

[colors-dark]
alpha=0.8
# alpha-mode=default # Can be `default`, `matching` or `all`
background=0f0f0f
foreground=ff00ff
# flash=7f7f00
# flash-alpha=0.5

# cursor=<inverse foreground/background>

## Normal/regular colors (color palette 0-7)
# regular0=242424  # black
# regular1=f62b5a  # red
# regular2=47b413  # green
# regular3=e3c401  # yellow
# regular4=24acd4  # blue
# regular5=f2affd  # magenta
# regular6=13c299  # cyan
# regular7=e6e6e6  # white

## Bright colors (color palette 8-15)
# bright0=616161   # bright black
# bright1=ff4d51   # bright red
# bright2=35d450   # bright green
# bright3=e9e836   # bright yellow
# bright4=5dc5f8   # bright blue
# bright5=feabf2   # bright magenta
# bright6=24dfc4   # bright cyan
# bright7=ffffff   # bright white

## dimmed colors (see foot.ini(5) man page)
# dim-blend-towards=black
# dim0=<not set>
# ...
# dim7=<not-set>

## The remaining 256-color palette
# 16 = <256-color palette #16>
# ...
# 255 = <256-color palette #255>

## Sixel colors
# sixel0 =  000000
# sixel1 =  3333cc
# sixel2 =  cc2121
# sixel3 =  33cc33
# sixel4 =  cc33cc
# sixel5 =  33cccc
# sixel6 =  cccc33
# sixel7 =  878787
# sixel8 =  424242
# sixel9 =  545499
# sixel10 = 994242
# sixel11 = 549954
# sixel12 = 995499
# sixel13 = 549999
# sixel14 = 999954
# sixel15 = cccccc

## Misc colors
# selection-foreground=<inverse foreground/background>
# selection-background=<inverse foreground/background>
# jump-labels=<regular0> <regular3>          # black-on-yellow
# scrollback-indicator=<regular0> <bright4>  # black-on-bright-blue
# search-box-no-match=<regular0> <regular1>  # black-on-red
# search-box-match=<regular0> <regular3>     # black-on-yellow
# urls=<regular3>

[colors-light]
# Alternative color theme, see man page foot.ini(5)
# Same builtin defaults as [color], except for:
# dim-blend-towards=white

[csd]
# preferred=server
# size=26
# font=JetBrains Mono NL
# color=<foreground colo>
# hide-when-maximized=no
# double-click-to-maximize=yes
# border-width=0
# border-color=<csd.color>
# button-width=26
# button-color=<background color>
# button-minimize-color=<regular4>
# button-maximize-color=<regular2>
# button-close-color=<regular1>

[key-bindings]
# scrollback-up-page=Shift+Page_Up Shift+KP_Page_Up
# scrollback-up-half-page=none
# scrollback-up-line=none
# scrollback-down-page=Shift+Page_Down Shift+KP_Page_Down
# scrollback-down-half-page=none
# scrollback-down-line=none
# scrollback-home=none
# scrollback-end=none
# clipboard-copy=Control+Shift+c XF86Copy
# clipboard-paste=Control+Shift+v XF86Paste
# primary-paste=Shift+Insert
# search-start=Control+Shift+r
# font-increase=Control+plus Control+equal Control+KP_Add
# font-decrease=Control+minus Control+KP_Subtract
# font-reset=Control+0 Control+KP_0
# spawn-terminal=Control+Shift+n
# minimize=none
# maximize=none
# fullscreen=none
# pipe-visible=[sh -c "xurls | fuzzel | xargs -r firefox"] none
# pipe-scrollback=[sh -c "xurls | fuzzel | xargs -r firefox"] none
# pipe-selected=[xargs -r firefox] none
# pipe-command-output=[wl-copy] none # Copy last command's output to the clipboard
# show-urls-launch=Control+Shift+o
# show-urls-copy=none
# show-urls-persistent=none
# prompt-prev=Control+Shift+z
# prompt-next=Control+Shift+x
# unicode-input=Control+Shift+u
# color-theme-switch-1=none
# color-theme-switch-2=none
# color-theme-toggle=none
# noop=none
# quit=none

[search-bindings]
# cancel=Control+g Control+c Escape
# commit=Return KP_Enter
# find-prev=Control+r
# find-next=Control+s
# cursor-left=Left Control+b
# cursor-left-word=Control+Left Mod1+b
# cursor-right=Right Control+f
# cursor-right-word=Control+Right Mod1+f
# cursor-home=Home Control+a
# cursor-end=End Control+e
# delete-prev=BackSpace
# delete-prev-word=Mod1+BackSpace Control+BackSpace
# delete-next=Delete
# delete-next-word=Mod1+d Control+Delete
# delete-to-start=Control+u
# delete-to-end=Control+k
# extend-char=Shift+Right
# extend-to-word-boundary=Control+w Control+Shift+Right
# extend-to-next-whitespace=Control+Shift+w
# extend-line-down=Shift+Down
# extend-backward-char=Shift+Left
# extend-backward-to-word-boundary=Control+Shift+Left
# extend-backward-to-next-whitespace=none
# extend-line-up=Shift+Up
# clipboard-paste=Control+v Control+Shift+v Control+y XF86Paste
# primary-paste=Shift+Insert
# unicode-input=none
# scrollback-up-page=Shift+Page_Up Shift+KP_Page_Up
# scrollback-up-half-page=none
# scrollback-up-line=none
# scrollback-down-page=Shift+Page_Down Shift+KP_Page_Down
# scrollback-down-half-page=none
# scrollback-down-line=none
# scrollback-home=none
# scrollback-end=none

[url-bindings]
# cancel=Control+g Control+c Control+d Escape
# toggle-url-visible=t

[text-bindings]
# \x03=Mod4+c  # Map Super+c -> Ctrl+c

[mouse-bindings]
# scrollback-up-mouse=BTN_WHEEL_BACK
# scrollback-down-mouse=BTN_WHEEL_FORWARD
# font-increase=Control+BTN_WHEEL_BACK
# font-decrease=Control+BTN_WHEEL_FORWARD
# selection-override-modifiers=Shift
# primary-paste=BTN_MIDDLE
# select-begin=BTN_LEFT
# select-begin-block=Control+BTN_LEFT
# select-extend=BTN_RIGHT
# select-extend-character-wise=Control+BTN_RIGHT
# select-word=BTN_LEFT-2
# select-word-whitespace=Control+BTN_LEFT-2
# select-quote = BTN_LEFT-3
# select-row=BTN_LEFT-4

# vim: ft=dosini
FOOTEOF
    ok "foot config placed in ~/.config/foot/foot.ini"
fi

# Nerd Fonts v3+ registers the family as "JetBrainsMonoNL Nerd Font" (the
# upstream zip here) — the "JetBrainsMonoNL" name foot.ini ships with won't
# resolve via fontconfig, so point it at the actual family.
if [ -e ~/.config/foot/foot.ini ]; then
    sed -i -E 's~^( *)font=JetBrainsMonoNL(:|\b)~\1font=JetBrainsMonoNL Nerd Font\2~' ~/.config/foot/foot.ini
fi

# qt6ct is the Qt6 settings app; QT_QPA_PLATFORMTHEME=qt6ct (set in
# hypr/hyprland.lua) is what makes Qt6 apps actually read its config instead
# of falling back to their own default style. breeze ships both the Breeze
# widget style and the BreezeDark.colors scheme qt6ct points at below.
BREEZE_DARK_SCHEME="/usr/share/color-schemes/BreezeDark.colors"
if dpkg -s qt6ct >/dev/null 2>&1 && dpkg -s breeze >/dev/null 2>&1; then
    if [ -e "$BREEZE_DARK_SCHEME" ]; then
        mkdir -p ~/.config/qt6ct
        if [ -e ~/.config/qt6ct/qt6ct.conf ]; then
            warn "~/.config/qt6ct/qt6ct.conf already exists — leaving your existing qt6ct config alone"
        else
            cat > ~/.config/qt6ct/qt6ct.conf <<EOF
[Appearance]
style=Breeze
color_scheme_path=$BREEZE_DARK_SCHEME
custom_palette=true
EOF
            ok "qt6ct set to use the Breeze Dark color scheme"
        fi
    else
        warn "BreezeDark.colors not found under /usr/share/color-schemes — select Breeze Dark manually in qt6ct"
    fi
else
    warn "qt6ct or breeze isn't installed — skipping Qt6 theme setup"
fi

# ── Step 5: choose a browser ─────────────────────────────────────────
# None of the six Arch options are in Debian repos, so each is installed from
# its official apt repo/.deb where one exists, or Firefox ESR from Debian.
step "Choosing a browser"
prompt_choice BROWSER_CHOICE 6 "Which browser would you like to install?" \
    "Brave" "Vivaldi" "Microsoft Edge" "LibreWolf" "Firefox ESR" "Skip — don't install a browser"

BROWSER_NAME=""
BROWSER_BIN=""
BROWSER_INSTALLED=0

case "$BROWSER_CHOICE" in
    1)
        BROWSER_NAME="Brave"; BROWSER_BIN="brave-browser"
        if add_apt_repo brave "https://brave-browser-apt-release.s3.brave.com/brave-core.asc" "https://brave-browser-apt-release.s3.brave.com/ stable main"; then
            run_spinner "Installing Brave" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y brave-browser && BROWSER_INSTALLED=1
        fi
        [ "$BROWSER_INSTALLED" -eq 1 ] || warn "Brave install failed — see https://brave.com/linux/"
        ;;
    2)
        BROWSER_NAME="Vivaldi"; BROWSER_BIN="vivaldi"
        if add_apt_repo vivaldi "https://repo.vivaldi.com/archive/vivaldi-archive.gpg.key" "https://repo.vivaldi.com/stable/deb/ stable main"; then
            run_spinner "Installing Vivaldi" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y vivaldi-stable && BROWSER_INSTALLED=1
        fi
        [ "$BROWSER_INSTALLED" -eq 1 ] || warn "Vivaldi install failed — see https://vivaldi.com/download/"
        ;;
    3)
        BROWSER_NAME="Microsoft Edge"; BROWSER_BIN="microsoft-edge"
        if add_apt_repo microsoft-edge "https://packages.microsoft.com/keys/microsoft.asc" "https://packages.microsoft.com/repos/edge stable main"; then
            run_spinner "Installing Microsoft Edge" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y microsoft-edge-stable && BROWSER_INSTALLED=1
        fi
        [ "$BROWSER_INSTALLED" -eq 1 ] || warn "Edge install failed — see https://www.microsoft.com/edge/download"
        ;;
    4)
        BROWSER_NAME="LibreWolf"; BROWSER_BIN="librewolf"
        # librewolf publishes a repo from deb.librewolf.net (the "bookworm"
        # line works for sid/trixie too — it ships standard .deb packages).
        if add_apt_repo librewolf "https://deb.librewolf.net/keyring.gpg" "https://deb.librewolf.net bookworm main"; then
            run_spinner "Installing LibreWolf" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y librewolf && BROWSER_INSTALLED=1
        fi
        [ "$BROWSER_INSTALLED" -eq 1 ] || warn "LibreWolf install failed — see https://librewolf.net/installation/"
        ;;
    5)
        BROWSER_NAME="Firefox ESR"; BROWSER_BIN="firefox-esr"
        run_spinner "Installing Firefox ESR" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y firefox-esr && BROWSER_INSTALLED=1
        ;;
    *) warn "Skipping browser install, as requested" ;;
esac

if [ "$BROWSER_INSTALLED" -eq 1 ]; then
    mkdir -p ~/.config/simpbar
    printf '%s\n' "$BROWSER_BIN" > ~/.config/simpbar/browser-choice
    ok "$BROWSER_NAME installed — pinned in ~/.config/simpbar/browser-choice"
fi

# Firefox often ships preinstalled — ask before touching it.
if dpkg -s firefox-esr >/dev/null 2>&1; then
    prompt_choice FIREFOX_CHOICE 1 "Firefox (ESR) is currently installed. Keep it or remove it?" \
        "Keep Firefox" "Remove Firefox"
    case "$FIREFOX_CHOICE" in
        2)
            run_spinner "Removing Firefox" sudo apt-get purge -y firefox-esr \
                || warn "Could not remove Firefox — remove it manually: sudo apt-get purge firefox-esr"
            ;;
        1) ok "Keeping Firefox" ;;
        *) warn "Unrecognized choice — keeping Firefox" ;;
    esac
fi

# ── Step 6: LazyVim + helpers + services ─────────────────────────────
step "Setting up LazyVim"

if [ -e ~/.config/nvim ]; then
    warn "~/.config/nvim already exists — skipping LazyVim install (back it up and re-run to install fresh)"
else
    for d in ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim; do
        [ -e "$d" ] && mv "$d" "$d.bak.$(date +%s)"
    done
    run_spinner "Cloning LazyVim starter" git clone --quiet https://github.com/LazyVim/starter ~/.config/nvim \
        && rm -rf ~/.config/nvim/.git \
        || warn "Could not clone LazyVim starter — install manually: https://www.lazyvim.org/installation"
fi

# Run fastfetch on new terminal sessions, without duplicating the line if
# the script gets re-run.
touch ~/.bashrc
if grep -qx 'fastfetch' ~/.bashrc 2>/dev/null; then
    ok "fastfetch already set to run in ~/.bashrc"
else
    printf '\nfastfetch\n' >> ~/.bashrc
    ok "fastfetch added to ~/.bashrc"
fi

mkdir -p ~/.config/fish
touch ~/.config/fish/config.fish
if grep -qx 'set -g fish_greeting' ~/.config/fish/config.fish 2>/dev/null; then
    ok "fish greeting already set to empty"
else
    printf '\nset -g fish_greeting\n' >> ~/.config/fish/config.fish
    ok "fish greeting set to empty"
fi
if grep -qx 'fastfetch' ~/.config/fish/config.fish 2>/dev/null; then
    ok "fastfetch already set to run in fish"
else
    printf '\nfastfetch\n' >> ~/.config/fish/config.fish
    ok "fastfetch added to fish config"
fi

FISH_PATH=$(command -v fish) || true

# The bar's pinned-app launchers, wallpaper picker + restore, and the
# background update checker come from the downloaded simpbar repo (they're
# distro-aware — azote/waypaper for wallpapers on Debian/Arch, apt/pacman
# for updates). Desktop entries + the logo.png asset end up next to them.
mkdir -p ~/.local/share/applications ~/.config/systemd/user

sudo install -Dm755 ~/.local/share/simpbar/simpbar-check-updates  /usr/bin/simpbar-check-updates
sudo install -Dm755 ~/.local/share/simpbar/simpbar-launch-browser /usr/bin/simpbar-launch-browser
sudo install -Dm755 ~/.local/share/simpbar/simpbar-launch-discord /usr/bin/simpbar-launch-discord
sudo install -Dm755 ~/.local/share/simpbar/simpbar-wallpaper      /usr/bin/simpbar-wallpaper
sudo install -Dm755 ~/.local/share/simpbar/simpbar-restore-wallpaper /usr/bin/simpbar-restore-wallpaper
cp ~/.local/share/simpbar/simpbar-welcome.desktop ~/.local/share/applications/
cp ~/.local/share/simpbar/simpbar-config.desktop   ~/.local/share/applications/
ok "Pinned-app launchers (browser, Discord), wallpaper picker + restore, update checker, and .desktop entries installed"

cat > ~/.config/systemd/user/simpbar-update-checker.service <<'CHECKERSVCEOF'
[Unit]
Description=Check for simpbar/system updates

[Service]
Type=oneshot
ExecStart=/usr/bin/simpbar-check-updates
CHECKERSVCEOF

cat > ~/.config/systemd/user/simpbar-update-checker.timer <<'CHECKERTIMEREOF'
[Unit]
Description=Periodically check for simpbar/system updates

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
CHECKERTIMEREOF

if command -v notify-send >/dev/null 2>&1; then
    run_spinner "Enabling simpbar-update-checker.timer" systemctl --user enable --now simpbar-update-checker.timer \
        || warn "Could not enable simpbar-update-checker.timer — enable it manually: systemctl --user enable --now simpbar-update-checker.timer"
else
    warn "notify-send not found — skipping the update-checker timer"
fi

cat > ~/.config/systemd/user/simpbar-welcome.service <<EOF
[Unit]
Description=Simpbar Welcome (first-login popup)
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/simpbar-welcome --autostart

[Install]
WantedBy=graphical-session.target
EOF

if [ -x /usr/bin/simpbar-welcome ]; then
    run_spinner "Enabling simpbar-welcome.service" systemctl --user enable --now simpbar-welcome.service \
        || warn "Could not enable simpbar-welcome.service — launch it manually: simpbar-welcome"
    ok "Simpbar Welcome app installed — will show once on first login, or launch it anytime from rofi"
else
    warn "simpbar-welcome binary missing — skipping Welcome autostart"
fi

# Bing wallpaper for swaybg (Debian doesn't ship waypaper — azote is the
# wallpaper picker; getting Bing on login needs this download plus the
# swaybg.service below).
WALLPAPER_DIR="$HOME/Pictures/Wallpaper"
mkdir -p "$WALLPAPER_DIR"

BING_JSON=$(curl -fsSL "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US" 2>/dev/null)
BING_URLBASE=$(printf '%s' "$BING_JSON" | grep -o '"urlbase":"[^"]*"' | head -1 | cut -d'"' -f4)
BING_URL=$(printf '%s' "$BING_JSON" | grep -o '"url":"[^"]*"' | head -1 | cut -d'"' -f4)
BING_FILE=""

if [ -n "$BING_URLBASE" ]; then
    BING_FILE="$WALLPAPER_DIR/bing-$(date +%F).jpg"
    if ! run_spinner "Downloading today's Bing wallpaper (UHD)" \
        curl -fsSL -o "$BING_FILE" "https://www.bing.com${BING_URLBASE}_UHD.jpg"; then
        if [ -n "$BING_URL" ]; then
            run_spinner "UHD unavailable — downloading standard resolution instead" \
                curl -fsSL -o "$BING_FILE" "https://www.bing.com${BING_URL}" \
                || { warn "Could not download today's Bing wallpaper"; BING_FILE=""; }
        else
            warn "Could not download today's Bing wallpaper"
            BING_FILE=""
        fi
    fi
else
    warn "Could not fetch Bing's wallpaper metadata — skipping wallpaper download"
fi

# swaybg is the actual wallpaper daemon (azote and waypaper are just GUI
# pickers; waypaper isn't packaged on Debian) — give it a systemd user
# service so the wallpaper survives logins. This replaces the Arch
# installer's waypaper config path.
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ] && command -v swaybg >/dev/null; then
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/swaybg.service <<EOF
[Unit]
Description=swaybg wallpaper
PartOf=graphical-session.target

[Service]
ExecStart=$(command -v swaybg) -i $BING_FILE -m fill
Restart=on-failure

[Install]
WantedBy=graphical-session.target
EOF
    run_spinner "Enabling swaybg.service" systemctl --user enable --now swaybg.service \
        || warn "Could not enable swaybg.service — set the wallpaper manually: swaybg -i $BING_FILE -m fill"
    ok "swaybg pointed at today's Bing wallpaper via ~/.config/systemd/user/swaybg.service"
else
    warn "No downloaded wallpaper or swaybg not installed — skipping swaybg service setup"
fi

# Make azote picks survive reboots: azote writes its own restore script
# (~/.azotebg-hyprland on Hyprland, v1.12.0+) the first time it applies a
# wallpaper — run it after swaybg.service so the last azote pick wins over
# the Bing default. azote's restore script does `pkill swaybg`, and
# swaybg.service has Restart=on-failure, so the service would otherwise just
# come back and fight azote — stop it first to hand the session over cleanly.
# simpbar-restore-wallpaper no-ops until azote has set a wallpaper, so the
# swaybg default stays up until then.
if command -v azote >/dev/null && command -v swaybg >/dev/null && [ -x /usr/bin/simpbar-restore-wallpaper ]; then
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/azote-restore.service <<'AZOTERESTORESVCEOF'
[Unit]
Description=Restore last azote wallpaper
PartOf=graphical-session.target
After=swaybg.service

[Service]
Type=oneshot
# azote's restore script backgrounds swaybg ("&") and exits — KillMode=none
# stops systemd from reaping those backgrounded swaybgs when the oneshot
# finishes (default control-group killmode would take the wallpaper down).
ExecStartPre=systemctl --user stop swaybg.service
KillMode=none
ExecStart=/usr/bin/simpbar-restore-wallpaper

[Install]
WantedBy=graphical-session.target
AZOTERESTORESVCEOF
    run_spinner "Enabling azote-restore.service" systemctl --user enable --now azote-restore.service \
        || warn "Could not enable azote-restore.service — your last azote wallpaper won't auto-restore on login"
    ok "azote-restore.service enabled — the wallpaper you pick in azote comes back each session (swaybg's default until azote picks one)"
else
    warn "azote/restore script not available — skipping azote-restore.service (azote still picks wallpapers on demand)"
fi

# matugen — the Material You colorscheme generator simpbar reads for
# wallpaper-based auto-theming. Not in Debian repos: rustc/cargo were added
# to the apt step above when requested, and matugen itself comes from
# crates.io here. It renders its simpbar template to
# ~/.config/simpbar/matugen.json, which the bar merges in on reload; an azote
# path unit re-runs it every time azote rewrites its restore script. matugen
# never sets the wallpaper itself, so azote stays the sole owner of it.
if [ "$INSTALL_MATUGEN" -eq 1 ]; then
    MATUGEN_BIN="$(command -v matugen 2>/dev/null || true)"
    if [ -z "$MATUGEN_BIN" ] && command -v cargo >/dev/null 2>&1; then
        run_spinner "Installing matugen from crates.io (this compiles it from source — be patient)" \
            cargo install matugen --locked \
            || warn "cargo install matugen failed — retry later with: cargo install matugen"
    fi
    # cargo install puts binaries in ~/.cargo/bin, which isn't always on PATH.
    [ -z "$MATUGEN_BIN" ] && [ -x "$HOME/.cargo/bin/matugen" ] && MATUGEN_BIN="$HOME/.cargo/bin/matugen"

    if [ -n "$MATUGEN_BIN" ] && [ -e "$MATUGEN_BIN" ]; then
        mkdir -p ~/.config/matugen/templates

        if [ -e ~/.config/matugen/config.toml ]; then
            warn "~/.config/matugen/config.toml already exists — leaving your existing matugen config alone"
        else
            cat > ~/.config/matugen/config.toml <<'MATUGENCONF'
# Matugen config for simpbar auto-theming. Writes ~/.config/simpbar/matugen.json,
# which the bar merges in on every reload (see the "Auto-theme with matugen"
# toggle in simpbar-config). To merge this into an existing matugen setup
# instead of copying it wholesale, just add the [templates.simpbar] block to
# your current ~/.config/matugen/config.toml.

[config]
# Non-interactive: never prompt for a source color to pick from the image,
# so wallpaper pickers can run this in the background.
version_check = false
# fallback_color + prefer are what make `matugen image …` deterministic —
# the color closest to this Material-ish teal wins, so no "Multiple source
# colors found" prompt ever appears. Change it to taste.
fallback_color = "#80CBC4"
prefer = "closest-to-fallback"

# simpbar doesn't want matugen touching the wallpaper — azote owns that.
[config.wallpaper]
set = false
# matugen 4.2.0 requires this key even with set = false (it only runs when
# set = true, it just must exist for the config to parse).
command = "true"

[templates.simpbar]
input_path = "~/.config/matugen/templates/simpbar.json"
output_path = "~/.config/simpbar/matugen.json"
# Reload the running bar (SIGUSR1) right after the colors land. Wrapped in
# `sh -c '…'` so it works no matter what the user's $SHELL is (fish, zsh,
# …) — the hook runs through matugen via the login shell. NO-ops if the bar
# isn't running or never wrote its pidfile.
post_hook = "sh -c 'if [ -s \"$HOME/.config/simpbar/simpbar.pid\" ]; then kill -USR1 \"$(cat \"$HOME/.config/simpbar/simpbar.pid\")\" 2>/dev/null; fi'"
MATUGENCONF
            ok "matugen config placed in ~/.config/matugen/config.toml"
        fi

        if [ -e ~/.config/matugen/templates/simpbar.json ]; then
            warn "~/.config/matugen/templates/simpbar.json already exists — leaving your existing template alone"
        else
            cat > ~/.config/matugen/templates/simpbar.json <<'MATUGENTPL'
{
  "bg_color": "#{{ colors.surface_container_lowest.default.hex_stripped }}",
  "text_color": "#{{ colors.on_surface.default.hex_stripped }}",
  "border_color": "#{{ colors.primary.default.hex_stripped }}",
  "hover_color": "#{{ colors.primary_container.default.hex_stripped }}",
  "workspace_active_color": "#{{ colors.primary.default.hex_stripped }}",
  "workspace_inactive_color": "#{{ colors.on_surface_variant.default.hex_stripped }}",
  "popup_bg_color": "#{{ colors.surface_container.default.hex_stripped }}",
  "popup_hover_color": "#{{ colors.primary_container.default.hex_stripped }}",
  "popup_separator_color": "#{{ colors.outline_variant.default.hex_stripped }}",
  "popup_disabled_color": "#{{ colors.on_surface_variant.default.hex_stripped }}"
}
MATUGENTPL
            ok "matugen template placed in ~/.config/matugen/templates/simpbar.json"
        fi

        run_spinner "Installing simpbar-matugen to /usr/bin" \
            sudo install -Dm755 ~/.local/share/simpbar/simpbar-matugen /usr/bin/simpbar-matugen \
            || warn "Could not install the simpbar-matugen helper to /usr/bin"

        # Re-run on every azote wallpaper apply: azote rewrites its restore
        # script each time, so watch that file. The service just runs
        # simpbar-matugen with no argument, which reads the current wallpaper
        # out of that same script and feeds it to matugen.
        mkdir -p ~/.config/systemd/user
        cat > ~/.config/systemd/user/matugen-wallpaper.path <<'MATUGENPATHEOF'
[Unit]
Description=Watch for azote wallpaper changes

[Path]
PathChanged=%h/.azotebg-hyprland
PathChanged=%h/.azotebg

[Install]
WantedBy=default.target
MATUGENPATHEOF
        cat > ~/.config/systemd/user/matugen-wallpaper.service <<'MATUGENSVCEOF'
[Unit]
Description=Recolor simpbar for the current wallpaper (matugen)

[Service]
Type=oneshot
ExecStart=/usr/bin/simpbar-matugen
MATUGENSVCEOF
        run_spinner "Enabling matugen-wallpaper.path (azote hook)" \
            systemctl --user enable --now matugen-wallpaper.path \
            || warn "Could not enable matugen-wallpaper.path — wallpapers picked in azote won't auto-recolor the bar"

        if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
            run_spinner "Generating the initial matugen scheme from the Bing wallpaper" \
                "$MATUGEN_BIN" image "$BING_FILE" \
                || warn "Could not generate the initial matugen scheme — it'll apply on the next wallpaper change"
        else
            warn "No wallpaper available for the initial matugen scheme — the bar keeps its configured colors until you pick a wallpaper"
        fi
    else
        warn "matugen isn't available (Rust/crates.io needed) — skipping simpbar matugen auto-theme setup"
    fi
fi

run_spinner "Updating the full system (apt full-upgrade)" sudo env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
    || warn "Full system update failed — run 'sudo apt-get update && sudo apt-get full-upgrade' manually to check for issues"

# ── Step 7: done ────────────────────────────────────────────────────
step "Done"
ok "Full system updated (apt full-upgrade)"
ok "simpbar, simpbar-welcome, simpbar-config built with zig $ZIG_VER and installed to /usr/bin"
ok "libfreetype-dev, libgdk-pixbuf-2.0-dev, libwayland-dev, wayland-protocols, libgtk-4-dev, libadwaita-1-dev, libglib2.0-dev, playerctl, gnome-calendar, mate-polkit, swaybg, azote, Noto Fonts, Noto Emoji, hyprland, foot, fastfetch, neovim, steam, steam-devices, sway-notification-center, rofi, flatpak, nwg-look, pavucontrol, pipewire, pipewire-pulse, wireplumber, gnome-disk-utility, wlogout, libnotify-bin installed (apt)"
ok "JetBrainsMono Nerd Font installed to /usr/share/fonts/TTF"
ok "$FILE_MANAGER_NAME installed and bound to SUPER + E"
ok "pipewire, pipewire-pulse, wireplumber enabled as user services"
if dpkg -s cliphist >/dev/null 2>&1; then
    ok "cliphist installed (bind a key to it yourself, e.g. in hyprland.lua)"
fi
if dpkg -s obs-studio >/dev/null 2>&1; then
    ok "OBS Studio installed"
fi
if [ -n "$VIDEO_EDITOR_NAME" ]; then
    ok "$VIDEO_EDITOR_NAME installed"
else
    ok "Video editor install skipped, as requested"
fi
if dpkg -s lutris >/dev/null 2>&1; then
    ok "Lutris installed"
fi
if [ "$INSTALL_HEROIC" -eq 1 ]; then
    if flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1; then
        ok "Heroic Games Launcher installed via Flatpak"
    else
        warn "Heroic Games Launcher not confirmed installed — see: flatpak install flathub com.heroicgameslauncher.hgl"
    fi
fi
if [ -n "$DISCORD_NAME" ]; then
    ok "$DISCORD_NAME installed"
else
    ok "Discord client install skipped, as requested"
fi
ok "Flathub remote added for flatpak"
ok "nwg-look set to prefer dark theme"
if dpkg -s bibata-cursor-theme >/dev/null 2>&1; then
    ok "Bibata Modern Classic cursor installed and applied"
fi
if [ -e ~/.config/rofi/config.rasi ]; then
    ok "rofi configured with the Material theme"
fi
if [ -e ~/.config/systemd/user/simpbar-update-checker.timer ]; then
    ok "Update checker enabled — notifies on new apt package updates or new commits on the simpbar repo (checks every 6h)"
fi
ok "Not on Debian: waypaper (azote + swaybg.service replace it), dracula-gtk-theme, zafiro-icon-theme, protonplus, game-devices-udev, falcond, bazaar, nwg-drawer (AUR-only or re-named) — skipped with their closest apt/flatpak equivalents where listed above"
if [ -n "$BROWSER_NAME" ]; then
    ok "$BROWSER_NAME installed from its official repo"
else
    ok "Browser install skipped, as requested"
fi
if [ -e ~/.config/systemd/user/swaybg.service ]; then
    ok "swaybg.service enabled — Bing wallpaper set automatically each session"
fi
if [ -e ~/.config/systemd/user/azote-restore.service ] && systemctl --user is-enabled azote-restore.service >/dev/null 2>&1; then
    ok "azote-restore.service enabled — the wallpaper you pick in azote returns after every login"
fi
if [ "$INSTALL_MATUGEN" -eq 1 ] && [ -e ~/.config/simpbar/matugen.json ]; then
    ok "matugen auto-theming set up — the bar recolors to each azote wallpaper (toggle off in simpbar-config anytime)"
fi
if [ -e ~/.config/waypaper/config.ini ]; then
    :
else
    ok "Wallpaper picking is azote (waypaper is Arch-only) — swaybg.service sets Bing by default, azote-restore.service brings back your last azote pick"
fi
if [ -x /usr/bin/simpbar ]; then
    ok "simpbar built and installed to /usr/bin/simpbar (source in ~/.local/share/simpbar/simpbar)"
fi
if [ -x /usr/bin/simpbar-config ]; then
    ok "simpbar-config installed to /usr/bin/simpbar-config — configure the bar's appearance, modules, and shortcuts anytime from rofi, or run 'simpbar-config'"
fi
ok "hypr config in ~/.config/hypr"
ok "swaync config in ~/.config/swaync"
ok "LazyVim config in ~/.config/nvim (run 'nvim' to finish plugin install)"
ok "fastfetch runs automatically in new terminal sessions (~/.bashrc)"
if dpkg -s fish >/dev/null 2>&1; then
    ok "fish shell installed with an empty greeting message and fastfetch on launch"
fi

printf '\n%s%s Setup complete!%s\n' "$C_GREEN$C_BOLD" "✔" "$C_RESET"
printf '%sRestart your session, or run:%s\n' "$C_BOLD" "$C_RESET"
printf '  %ssimpbar &%s\n' "$C_CYAN" "$C_RESET"
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    printf '  %sswaybg -i %s -m fill &%s\n' "$C_CYAN" "$BING_FILE" "$C_RESET"
else
    printf '  %sswaybg -i /path/to/your/wallpaper.jpg -m fill &%s   # example\n' "$C_CYAN" "$C_RESET"
fi
printf '  %s%s%s                          # polkit auth agent (already in hyprland.lua)\n' "$C_CYAN" "$POLKIT_DEBIAN" "$C_RESET"

printf '\n%sKeybindings:%s\n' "$C_BOLD" "$C_RESET"
printf '  %sSUPER%s                    = Windows key\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Enter%s            = Open terminal\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Space%s            = Open Rofi\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + E%s                = Open %s\n' "$C_CYAN" "$C_RESET" "$FILE_MANAGER_NAME"
printf '  %sSUPER + Q%s                = Exit the application\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + [1-0]%s            = Switch workspaces\n' "$C_CYAN" "$C_RESET"
printf '  %sPrint%s                     = Screenshot: region\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Print%s             = Screenshot: active window\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + SHIFT + Print%s     = Screenshot: full screen\n' "$C_CYAN" "$C_RESET"
printf '\n%sTo change your keybindings or set your monitor resolution, edit the config with:%s\n' "$C_BOLD" "$C_RESET"
printf '  %snvim ~/.config/hypr/hyprland.lua%s\n' "$C_CYAN" "$C_RESET"
printf '\n%sEnjoy your new home & workflow! :)%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '\n%sDon'"'"'t forget to reboot! Please use: systemctl reboot%s\n' "$C_YELLOW" "$C_RESET"

# Switch the default login shell to fish. This runs last, on its own, with
# stdin/stdout attached directly to /dev/tty — chsh needs a real interactive
# terminal to prompt for your password, which it doesn't have if this
# script is being run as `curl ... | bash` (stdin is the piped script, not
# your keyboard). Same approach as the Arch installer.
if [ -z "$FISH_PATH" ]; then
    warn "Could not find the fish binary — skipping default shell switch"
elif [ "$SHELL" = "$FISH_PATH" ]; then
    ok "fish is already the default shell"
elif [ ! -r /dev/tty ]; then
    warn "No interactive terminal available — run 'chsh -s $FISH_PATH' manually to switch your default shell"
else
    grep -qx "$FISH_PATH" /etc/shells 2>/dev/null \
        || printf '%s\n' "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
    printf '\n%sSwitching your default shell to fish — enter your password if asked:%s\n' "$C_BOLD" "$C_RESET"
    if chsh -s "$FISH_PATH" < /dev/tty > /dev/tty 2>&1; then
        ok "Default login shell switched to fish (takes effect next login)"
    else
        warn "Could not switch the default shell — run 'chsh -s $FISH_PATH' manually"
    fi
fi

#!/bin/bash
# Simpbar Installer
# Arch Linux only

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

TOTAL_STEPS=6
STEP=0

banner() {
    local logo_text art_text
    logo_text=$(cat <<'LOGO'
        /\
       /  \
      /    \
     /      \
    /   ,,   \
   /   |  |  -\
  /_-''    ''-_\

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

# Build & install yay-bin from the AUR. Returns 1 on failure without dying,
# so callers can fall back to a manual-install warning.
install_yay() {
    local build_dir
    build_dir=$(mktemp -d)

    run_spinner "Installing git & base-devel" sudo pacman -S --noconfirm --needed git base-devel \
        || { rm -rf "$build_dir"; return 1; }

    run_spinner "Cloning yay-bin" git clone --quiet https://aur.archlinux.org/yay-bin.git "$build_dir/yay-bin" \
        || { rm -rf "$build_dir"; return 1; }

    run_spinner "Building yay-bin (makepkg -si)" bash -c "cd '$build_dir/yay-bin' && makepkg -si --noconfirm" \
        || { rm -rf "$build_dir"; return 1; }

    rm -rf "$build_dir"
    return 0
}

# Build & install paru from the AUR. Same contract as install_yay.
install_paru() {
    local build_dir
    build_dir=$(mktemp -d)

    run_spinner "Installing git & base-devel" sudo pacman -S --noconfirm --needed git base-devel \
        || { rm -rf "$build_dir"; return 1; }

    run_spinner "Cloning paru" git clone --quiet https://aur.archlinux.org/paru.git "$build_dir/paru" \
        || { rm -rf "$build_dir"; return 1; }

    run_spinner "Building paru (makepkg -si)" bash -c "cd '$build_dir/paru' && makepkg -si --noconfirm" \
        || { rm -rf "$build_dir"; return 1; }

    rm -rf "$build_dir"
    return 0
}

# Run a command quietly, showing a spinner, then a check/cross line.
run_spinner() {
    local msg="$1"; shift
    # Cap the label length: a message long enough to wrap the terminal
    # line breaks the \r redraw below (it only returns to the start of
    # the current wrapped row, not the true start), which prints a new
    # stacked line every tick instead of overwriting one line in place.
    if [ "${#msg}" -gt 60 ]; then
        msg="${msg:0:57}..."
    fi
    # Refresh (or acquire) the sudo timestamp synchronously first. If a
    # password prompt is actually needed, it happens here on its own
    # line — before any spinner output starts — instead of colliding
    # with the spinner's carriage-return line mid-command.
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
# RESULT_VAR is set to the chosen number (as a string), or DEFAULT.
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

# Try installing an AUR package with whichever helper is available.
# install_aur_pkg <display name> <package>
install_aur_pkg() {
    local name="$1" pkg="$2"
    if command -v yay >/dev/null; then
        run_spinner "yay: $pkg (AUR)" yay -S --noconfirm --needed "$pkg" \
            || { warn "Could not install $name via yay — install manually: yay -S $pkg"; return 1; }
    elif command -v paru >/dev/null; then
        run_spinner "paru: $pkg (AUR)" paru -S --noconfirm --needed "$pkg" \
            || { warn "Could not install $name via paru — install manually: paru -S $pkg"; return 1; }
    else
        warn "No AUR helper available — install $name manually: yay -S $pkg"
        return 1
    fi
}

banner

# ── Step 0: platform check ─────────────────────────────────────────
command -v pacman >/dev/null || die "This script is Arch-only (pacman not found)."

# Authenticate sudo up front so the password prompt never lands in the
# middle of a spinner later on. Keep it alive in the background for the
# rest of the script, and make sure that background loop dies with us.
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

if [ "${#MISSING_PREREQS[@]}" -gt 0 ]; then
    run_spinner "Installing ${MISSING_PREREQS[*]}" sudo pacman -S --noconfirm --needed "${MISSING_PREREQS[@]}" \
        || die "Failed to install prerequisites: ${MISSING_PREREQS[*]}"
else
    ok "curl and unzip already installed"
fi

HOME_DIRS=(Pictures Videos Documents Music Projects)
mkdir -p "${HOME_DIRS[@]/#/$HOME/}"
ok "Created ~/{${HOME_DIRS[*]// /,}}"

# ── Step 2: fetch waybar config ────────────────────────────────────
step "Fetching simpbar theme"
mkdir -p ~/.config

run_spinner "Downloading simpbar config" \
    curl -fL -o /tmp/simpbar.zip https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip \
    || die "Could not download simpbar (check your network connection)."

run_spinner "Extracting archive" \
    unzip -o /tmp/simpbar.zip -d /tmp/simpbar-temp \
    || die "Could not extract simpbar archive."

CONFIG_DIRS=(waybar hypr swaync fastfetch)
for d in "${CONFIG_DIRS[@]}"; do
    if [ ! -d "/tmp/simpbar-temp/simpbar-main/$d" ]; then
        rm -rf /tmp/simpbar-temp /tmp/simpbar.zip
        die "Downloaded archive did not contain a $d/ directory — layout may have changed upstream."
    fi
done

for d in "${CONFIG_DIRS[@]}"; do
    cp -r "/tmp/simpbar-temp/simpbar-main/$d" ~/.config/
done
rm -rf /tmp/simpbar-temp /tmp/simpbar.zip
ok "Configs placed in ~/.config/{${CONFIG_DIRS[*]// /,}}"

# ── Step 3: install packages ───────────────────────────────────────
step "Installing packages"

# Steam lives in the multilib repo, which isn't enabled by default.
if ! grep -Pzoq '(?m)^\[multilib\]\nInclude' /etc/pacman.conf 2>/dev/null; then
    warn "multilib repo not enabled — enabling it for Steam"
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    if ! grep -Pzoq '(?m)^\[multilib\]\nInclude' /etc/pacman.conf 2>/dev/null; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    run_spinner "Syncing package databases" sudo pacman -Sy \
        || die "Failed to sync package databases after enabling multilib."
fi

PACMAN_PKGS=(waybar gnome-calendar nautilus mate-polkit swaybg ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji hyprland foot fastfetch neovim steam swaync rofi flatpak bazaar nwg-look pavucontrol pipewire pipewire-pulse wireplumber gnome-disk-utility)

prompt_choice OBS_CHOICE 2 "Will you be using OBS Studio for recording/streaming?" "Yes" "No"
[ "$OBS_CHOICE" = 1 ] && PACMAN_PKGS+=(obs-studio)

prompt_choice VIDEO_EDITOR_YN 2 "Would you like to install a video editor?" "Yes" "No"
if [ "$VIDEO_EDITOR_YN" = 1 ]; then
    prompt_choice VIDEO_EDITOR_CHOICE 1 "Which video editor would you like to install?" \
        "Kdenlive" "Shotcut" "Flowblade"
    case "$VIDEO_EDITOR_CHOICE" in
        1) VIDEO_EDITOR_NAME="Kdenlive";  PACMAN_PKGS+=(kdenlive) ;;
        2) VIDEO_EDITOR_NAME="Shotcut";   PACMAN_PKGS+=(shotcut) ;;
        3) VIDEO_EDITOR_NAME="Flowblade"; PACMAN_PKGS+=(flowblade) ;;
        *) VIDEO_EDITOR_NAME="" ;;
    esac
else
    VIDEO_EDITOR_NAME=""
fi

prompt_choice LAUNCHER_CHOICE 4 "Would you like to install any game launchers?" \
    "Lutris" "Heroic" "Both" "Neither"

INSTALL_HEROIC=0
case "$LAUNCHER_CHOICE" in
    1) PACMAN_PKGS+=(lutris) ;;
    2) INSTALL_HEROIC=1 ;;
    3) PACMAN_PKGS+=(lutris); INSTALL_HEROIC=1 ;;
    *) ;;
esac

prompt_choice DISCORD_CHOICE 4 "Which Discord client would you like to install?" \
    "Discord" "Vesktop" "Equibop" "Skip — don't install a Discord client"

DISCORD_AUR_PKG=""
case "$DISCORD_CHOICE" in
    1) DISCORD_NAME="Discord"; PACMAN_PKGS+=(discord) ;;
    2) DISCORD_NAME="Vesktop"; DISCORD_AUR_PKG="vesktop-bin" ;;
    3) DISCORD_NAME="Equibop"; DISCORD_AUR_PKG="equibop-bin" ;;
    *) DISCORD_NAME="" ;;
esac

printf '  Installing %d packages via pacman:\n    %s\n' "${#PACMAN_PKGS[@]}" "${PACMAN_PKGS[*]}"
run_spinner "pacman: installing ${#PACMAN_PKGS[@]} packages" sudo pacman -S --noconfirm --needed "${PACMAN_PKGS[@]}" \
    || die "Failed to install official packages: ${PACMAN_PKGS[*]}"

MISSING_PKGS=()
for pkg in "${PACMAN_PKGS[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    warn "pacman reported success but these packages aren't actually installed: ${MISSING_PKGS[*]}"
else
    ok "Verified all pacman packages are installed"
fi

run_spinner "Refreshing font cache" fc-cache -f \
    || warn "Could not refresh the font cache — run 'fc-cache -f' manually if icons look missing"

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

# nwg-look reads/writes gsettings directly (no private config file), so setting
# these keys ourselves has the same effect as toggling "Prefer dark" in its GUI.
if command -v gsettings >/dev/null; then
    run_spinner "Setting nwg-look theme to prefer dark" \
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' \
        || warn "Could not set dark theme preference — toggle 'Prefer dark' manually in nwg-look"
else
    warn "gsettings not found — open nwg-look and toggle 'Prefer dark' manually"
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
    ok "rofi set to use the Material theme"
fi

# wlogout, waypaper & protonplus are AUR-only — need an AUR helper
AUR_PKGS=(wlogout waypaper protonplus)
[ "$INSTALL_HEROIC" -eq 1 ] && AUR_PKGS+=(heroic-games-launcher-bin)
[ -n "$DISCORD_AUR_PKG" ] && AUR_PKGS+=("$DISCORD_AUR_PKG")

if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
    prompt_choice AUR_CHOICE 1 "No AUR helper found. Install which one?" "yay" "paru" "skip"
    case "$AUR_CHOICE" in
        2) install_paru || warn "Could not install paru automatically — install manually: ${AUR_PKGS[*]}" ;;
        3) warn "Skipping AUR helper install — install manually: ${AUR_PKGS[*]}" ;;
        1) install_yay || warn "Could not install yay automatically — install manually: ${AUR_PKGS[*]}" ;;
        *)
            warn "Unrecognized choice — defaulting to yay"
            install_yay || warn "Could not install yay automatically — install manually: ${AUR_PKGS[*]}"
            ;;
    esac
fi

printf '  Installing %d AUR packages:\n    %s\n' "${#AUR_PKGS[@]}" "${AUR_PKGS[*]}"
if command -v yay >/dev/null; then
    run_spinner "yay: installing ${#AUR_PKGS[@]} AUR packages" yay -S --noconfirm --needed "${AUR_PKGS[@]}" \
        || warn "Some AUR packages failed via yay — install manually: yay -S ${AUR_PKGS[*]}"
elif command -v paru >/dev/null; then
    run_spinner "paru: installing ${#AUR_PKGS[@]} AUR packages" paru -S --noconfirm --needed "${AUR_PKGS[@]}" \
        || warn "Some AUR packages failed via paru — install manually: paru -S ${AUR_PKGS[*]}"
else
    warn "No AUR helper available — install manually: yay -S ${AUR_PKGS[*]}"
fi

MISSING_AUR=()
for pkg in "${AUR_PKGS[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || MISSING_AUR+=("$pkg")
done
if [ "${#MISSING_AUR[@]}" -gt 0 ]; then
    warn "AUR packages not installed: ${MISSING_AUR[*]} — install manually if needed"
else
    ok "Verified all AUR packages are installed"
fi

# ── Step 4: choose a browser ─────────────────────────────────────────
step "Choosing a browser"

prompt_choice BROWSER_CHOICE 6 "Which browser would you like to install?" \
    "Brave" "Zen Browser" "Vivaldi" "Microsoft Edge" "LibreWolf" "Skip — don't install a browser"

case "$BROWSER_CHOICE" in
    1) BROWSER_NAME="Brave";          BROWSER_PKG="brave-bin" ;;
    2) BROWSER_NAME="Zen Browser";    BROWSER_PKG="zen-browser-bin" ;;
    3) BROWSER_NAME="Vivaldi";        BROWSER_PKG="vivaldi" ;;
    4) BROWSER_NAME="Microsoft Edge"; BROWSER_PKG="microsoft-edge-stable-bin" ;;
    5) BROWSER_NAME="LibreWolf";      BROWSER_PKG="librewolf-bin" ;;
    *) BROWSER_NAME=""; BROWSER_PKG="" ;;
esac

if [ -z "$BROWSER_NAME" ]; then
    warn "Skipping browser install, as requested"
else
    install_aur_pkg "$BROWSER_NAME" "$BROWSER_PKG"
fi

if [ -n "$BROWSER_PKG" ] && pacman -Qq "$BROWSER_PKG" >/dev/null 2>&1; then
    ok "$BROWSER_NAME installed"
fi

# Firefox often ships preinstalled — ask before touching it.
if pacman -Qq firefox >/dev/null 2>&1; then
    prompt_choice FIREFOX_CHOICE 1 "Firefox is currently installed. Keep it or remove it?" \
        "Keep Firefox" "Remove Firefox"
    case "$FIREFOX_CHOICE" in
        2)
            run_spinner "Removing Firefox" sudo pacman -Rns --noconfirm firefox \
                || warn "Could not remove Firefox — remove it manually: sudo pacman -Rns firefox"
            ;;
        1) ok "Keeping Firefox" ;;
        *) warn "Unrecognized choice — keeping Firefox" ;;
    esac
fi

# ── Step 5: LazyVim ─────────────────────────────────────────────────
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

# ── Step 6: done ────────────────────────────────────────────────────
step "Done"
ok "waybar, gnome-calendar, nautilus, mate-polkit, swaybg, JetBrainsMono Nerd Font, Noto Fonts, Noto Emoji, hyprland, foot, fastfetch, neovim, steam, swaync, rofi, flatpak, bazaar, nwg-look, pavucontrol, pipewire, gnome-disk-utility installed (pacman)"
ok "pipewire, pipewire-pulse, wireplumber enabled as user services"
if pacman -Qq obs-studio >/dev/null 2>&1; then
    ok "OBS Studio installed"
fi
if [ -n "$VIDEO_EDITOR_NAME" ]; then
    ok "$VIDEO_EDITOR_NAME installed"
else
    ok "Video editor install skipped, as requested"
fi
if pacman -Qq lutris >/dev/null 2>&1; then
    ok "Lutris installed"
fi
if pacman -Qq heroic-games-launcher-bin >/dev/null 2>&1; then
    ok "Heroic Games Launcher installed via AUR helper (if available)"
fi
if [ -n "$DISCORD_NAME" ]; then
    ok "$DISCORD_NAME installed"
else
    ok "Discord client install skipped, as requested"
fi
ok "Flathub remote added for flatpak/bazaar"
ok "nwg-look set to prefer dark theme"
if [ -e ~/.config/rofi/config.rasi ]; then
    ok "rofi configured with the Material theme"
fi
ok "wlogout, waypaper, protonplus installed via AUR helper (if available)"
if [ -n "$BROWSER_NAME" ]; then
    ok "$BROWSER_NAME installed via AUR helper (if available)"
else
    ok "Browser install skipped, as requested"
fi
ok "waybar config in ~/.config/waybar"
ok "hypr config in ~/.config/hypr"
ok "swaync config in ~/.config/swaync"
ok "LazyVim config in ~/.config/nvim (run 'nvim' to finish plugin install)"

printf '\n%s%s Setup complete!%s\n' "$C_GREEN$C_BOLD" "✔" "$C_RESET"
printf '%sRestart your session, or run:%s\n' "$C_BOLD" "$C_RESET"
printf '  %swaybar &%s\n' "$C_CYAN" "$C_RESET"
printf '  %sswaybg -i /path/to/your/wallpaper.jpg -m fill &%s   # example\n' "$C_CYAN" "$C_RESET"
printf '  %swaypaper%s                                          # pick a wallpaper\n' "$C_CYAN" "$C_RESET"
printf '  %s/usr/lib/mate-polkit/polkit-mate-authentication-agent-1 &%s   # needed for GUI auth prompts\n' "$C_CYAN" "$C_RESET"

printf '\n%sKeybindings:%s\n' "$C_BOLD" "$C_RESET"
printf '  %sSUPER%s                    = Windows key\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Enter%s            = Open terminal\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Space%s                = Open Rofi\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + E%s                = Open Nautilus\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Q%s                = Exit the application\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + [1-0]%s            = Switch workspaces\n' "$C_CYAN" "$C_RESET"
printf '\n%sTo change your keybindings or set your monitor resolution, edit the config with:%s\n' "$C_BOLD" "$C_RESET"
printf '  %snvim ~/.config/hypr/hyprland.lua%s\n' "$C_CYAN" "$C_RESET"
printf '\n%sEnjoy your new home & workflow! :)%s\n' "$C_GREEN$C_BOLD" "$C_RESET"

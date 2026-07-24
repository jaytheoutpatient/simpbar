#!/bin/bash
# Simpbar Installer
# Arch Linux only

set -e

# ── Colors ──────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_BLUE=$(tput setaf 4); C_GREEN=$(tput setaf 2)
    C_RED=$(tput setaf 1); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
else
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

TOTAL_STEPS=6
STEP=0

banner() {
    printf '%s%s\n' "$C_CYAN$C_BOLD" "
   _____ _                 _
  / ____(_)               | |
 | (___  _ _ __ ___  _ __ | |__   __ _ _ __
  \___ \| | '_ \` _ \| '_ \| '_ \ / _\` | '__|
  ____) | | | | | | | |_) | |_) | (_| | |
 |_____/|_|_| |_| |_| .__/|_.__/ \__,_|_|
                     | |
                     |_|          installer
"
    printf '%s\n' "$C_RESET"
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

banner

# ── Step 0: platform check ─────────────────────────────────────────
command -v pacman >/dev/null || die "This script is Arch-only (pacman not found)."

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

# ── Step 2: fetch waybar config ────────────────────────────────────
step "Fetching simpbar theme"
mkdir -p ~/.config

run_spinner "Downloading simpbar config" \
    curl -fL -o /tmp/simpbar.zip https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip \
    || die "Could not download simpbar (check your network connection)."

run_spinner "Extracting archive" \
    unzip -o /tmp/simpbar.zip -d /tmp/simpbar-temp \
    || die "Could not extract simpbar archive."

CONFIG_DIRS=(waybar hypr swaync)
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

PACMAN_PKGS=(waybar gnome-calendar nautilus mate-polkit swaybg ttf-jetbrains-mono-nerd hyprland foot fastfetch neovim steam swaync rofi flatpak bazaar)
run_spinner "pacman: ${PACMAN_PKGS[*]}" sudo pacman -S --noconfirm --needed "${PACMAN_PKGS[@]}" \
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

run_spinner "Adding Flathub remote" \
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo \
    || warn "Could not add Flathub remote — add it manually: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"

# wlogout, waypaper & protonplus are AUR-only — need an AUR helper
AUR_PKGS=(wlogout waypaper protonplus)

if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
    printf '\n  %sNo AUR helper found. Install which one?%s\n' "$C_YELLOW" "$C_RESET"
    printf '    %s1)%s yay\n'  "$C_CYAN" "$C_RESET"
    printf '    %s2)%s paru\n' "$C_CYAN" "$C_RESET"
    printf '    %s3)%s skip\n' "$C_CYAN" "$C_RESET"
    printf '  %sChoice [1]: %s' "$C_BOLD" "$C_RESET"
    if [ -r /dev/tty ]; then
        read -r AUR_CHOICE < /dev/tty
    else
        warn "No interactive terminal available — defaulting to yay"
        AUR_CHOICE=1
    fi
    case "$AUR_CHOICE" in
        2)
            install_paru || warn "Could not install paru automatically — install manually: ${AUR_PKGS[*]}"
            ;;
        3)
            warn "Skipping AUR helper install — install manually: ${AUR_PKGS[*]}"
            ;;
        1|"")
            install_yay || warn "Could not install yay automatically — install manually: ${AUR_PKGS[*]}"
            ;;
        *)
            warn "Unrecognized choice — defaulting to yay"
            install_yay || warn "Could not install yay automatically — install manually: ${AUR_PKGS[*]}"
            ;;
    esac
fi

if command -v yay >/dev/null; then
    run_spinner "yay: ${AUR_PKGS[*]} (AUR)" yay -S --noconfirm --needed "${AUR_PKGS[@]}" \
        || warn "Some AUR packages failed via yay — install manually: yay -S ${AUR_PKGS[*]}"
elif command -v paru >/dev/null; then
    run_spinner "paru: ${AUR_PKGS[*]} (AUR)" paru -S --noconfirm --needed "${AUR_PKGS[@]}" \
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

# ── Step 4: LazyVim ─────────────────────────────────────────────────
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

# ── Step 5: choose & switch login manager ───────────────────────────
step "Choosing a login manager"

printf '\n  %sWhich login manager would you like to use?%s\n' "$C_YELLOW" "$C_RESET"
printf '    %s1)%s Ly (lightweight TUI)\n' "$C_CYAN" "$C_RESET"
printf '    %s2)%s SDDM\n' "$C_CYAN" "$C_RESET"
printf '    %s3)%s GDM\n' "$C_CYAN" "$C_RESET"
printf '    %s4)%s LightDM\n' "$C_CYAN" "$C_RESET"
printf '    %s5)%s Skip — don'"'"'t touch my login manager\n' "$C_CYAN" "$C_RESET"
printf '  %sChoice [1]: %s' "$C_BOLD" "$C_RESET"
if [ -r /dev/tty ]; then
    read -r LM_CHOICE < /dev/tty
else
    warn "No interactive terminal available — defaulting to Ly"
    LM_CHOICE=1
fi

case "$LM_CHOICE" in
    2) LM_NAME="SDDM";    LM_PKGS=(sddm);                     LM_SERVICE="sddm.service" ;;
    3) LM_NAME="GDM";     LM_PKGS=(gdm);                      LM_SERVICE="gdm.service" ;;
    4) LM_NAME="LightDM"; LM_PKGS=(lightdm lightdm-gtk-greeter); LM_SERVICE="lightdm.service" ;;
    5) LM_NAME="";        LM_PKGS=();                         LM_SERVICE="" ;;
    1|"") LM_NAME="Ly";   LM_PKGS=(ly);                       LM_SERVICE="ly@tty2.service" ;;
    *) warn "Unrecognized choice — defaulting to Ly"
       LM_NAME="Ly"; LM_PKGS=(ly); LM_SERVICE="ly@tty2.service" ;;
esac

if [ -z "$LM_NAME" ]; then
    warn "Skipping login manager setup, as requested"
else
    run_spinner "pacman: ${LM_PKGS[*]}" sudo pacman -S --noconfirm --needed "${LM_PKGS[@]}" \
        || die "Failed to install $LM_NAME (${LM_PKGS[*]})"

    LM_MISSING=()
    for pkg in "${LM_PKGS[@]}"; do
        pacman -Qq "$pkg" >/dev/null 2>&1 || LM_MISSING+=("$pkg")
    done

    if [ "${#LM_MISSING[@]}" -gt 0 ]; then
        warn "$LM_NAME package(s) not actually installed (${LM_MISSING[*]}) — skipping the switch"
    else
        OTHER_DMS=(gdm gdm3 sddm lightdm lxdm xdm slim entrance greetd ly)
        for dm in "${OTHER_DMS[@]}"; do
            [ "$dm" = "${LM_PKGS[0]}" ] && continue
            if systemctl is-enabled --quiet "$dm.service" 2>/dev/null; then
                run_spinner "Disabling $dm" sudo systemctl disable --now "$dm.service" \
                    || warn "Could not disable $dm — you may need to do this manually"
            fi
        done
        if [ "$LM_NAME" = "Ly" ] && systemctl is-enabled --quiet getty@tty1.service 2>/dev/null; then
            run_spinner "Disabling getty@tty1" sudo systemctl disable --now getty@tty1.service \
                || warn "Could not disable getty@tty1 — it may keep competing with ly@tty2 for the console"
        fi

        run_spinner "Enabling $LM_NAME" sudo systemctl enable "$LM_SERVICE" \
            && ok "$LM_NAME set as the login manager (takes effect on next reboot)" \
            || warn "Failed to enable $LM_SERVICE — enable it manually with: sudo systemctl enable $LM_SERVICE"
    fi
fi

# ── Step 6: done ────────────────────────────────────────────────────
step "Done"
ok "waybar, gnome-calendar, nautilus, mate-polkit, swaybg, JetBrainsMono Nerd Font, hyprland, foot, fastfetch, neovim, steam, swaync, rofi, flatpak, bazaar installed (pacman)"
ok "Flathub remote added for flatpak/bazaar"
ok "wlogout, waypaper, protonplus installed via AUR helper (if available)"
if [ -n "$LM_NAME" ]; then
    ok "$LM_NAME installed and set as login manager"
else
    ok "Login manager setup skipped, as requested"
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

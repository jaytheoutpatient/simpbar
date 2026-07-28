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

TOTAL_STEPS=7
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

# ── Step 3: set up Chaotic-AUR ───────────────────────────────────────
step "Setting up Chaotic-AUR"

if grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
    ok "Chaotic-AUR already configured"
else
    run_spinner "Importing Chaotic-AUR signing key" \
        sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com \
        || die "Failed to import the Chaotic-AUR signing key."

    run_spinner "Trusting Chaotic-AUR signing key" \
        sudo pacman-key --lsign-key 3056513887B78AEB \
        || die "Failed to locally sign the Chaotic-AUR key."

    run_spinner "Installing Chaotic-AUR keyring & mirrorlist" \
        sudo pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
        || die "Failed to install the Chaotic-AUR keyring/mirrorlist packages."

    printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null

    run_spinner "Syncing package databases" sudo pacman -Sy \
        || die "Failed to sync package databases after enabling Chaotic-AUR."

    ok "Chaotic-AUR enabled"
fi

# ── Step 4: install packages ───────────────────────────────────────
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

PACMAN_PKGS=(waybar gnome-calendar nautilus mate-polkit swaybg ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji hyprland foot fastfetch neovim steam swaync rofi flatpak bazaar nwg-look pavucontrol pipewire pipewire-pulse wireplumber gnome-disk-utility fish polkit-gnome grim slurp xdg-desktop-portal-hyprland cliphist wl-clipboard python-gobject gtk4 libadwaita pacman-contrib libnotify nwg-drawer)

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

printf '\n  %sfalcond%s is a gaming performance daemon: it watches for running games\n' "$C_BOLD" "$C_RESET"
printf '  (including Proton/Wine) and automatically applies performance profiles —\n'
printf '  CPU scheduler switching, AMD 3D V-Cache mode, performance mode — without\n'
printf '  you having to flip settings manually. %sfalcond-gui%s is a GTK app to\n' "$C_BOLD" "$C_RESET"
printf '  configure and monitor it.\n'
prompt_choice FALCOND_CHOICE 2 "Would you like to install falcond & falcond-gui?" "Yes" "No"
INSTALL_FALCOND=0
if [ "$FALCOND_CHOICE" = 1 ]; then
    INSTALL_FALCOND=1
    # falcond's scx_sched option switches between sched_ext schedulers —
    # scx-scheds (official repo) provides the actual scheduler binaries.
    # falcond-gui detects/manages them via scx_loader's D-Bus service,
    # which ships in the separate scx-tools package — without it there's
    # nothing for falcond-gui to query, so the scheduler list shows empty.
    PACMAN_PKGS+=(scx-scheds scx-tools)
fi

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

# foot terminal config, embedded directly since it's not fetched from
# the simpbar repo like the other configs.
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

# wlogout, waypaper & protonplus are AUR-only — need an AUR helper
AUR_PKGS=(wlogout waypaper protonplus dracula-gtk-theme bibata-cursor-theme hyprmod game-devices-udev zafiro-icon-theme)
[ "$INSTALL_HEROIC" -eq 1 ] && AUR_PKGS+=(heroic-games-launcher-bin)
[ -n "$DISCORD_AUR_PKG" ] && AUR_PKGS+=("$DISCORD_AUR_PKG")
[ "$INSTALL_FALCOND" -eq 1 ] && AUR_PKGS+=(falcond falcond-gui)

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

if pacman -Qq game-devices-udev >/dev/null 2>&1; then
    run_spinner "Reloading udev rules for game controllers" \
        sudo bash -c 'udevadm control --reload-rules && udevadm trigger' \
        || warn "Could not reload udev rules — replug your controller or reboot for the new rules to apply"
fi

if pacman -Qq falcond >/dev/null 2>&1; then
    # falcond-gui needs the user in the 'falcond' group to talk to the
    # daemon without root. The package creates the group; existing users
    # aren't added to it automatically.
    if getent group falcond >/dev/null 2>&1; then
        run_spinner "Adding $USER to the falcond group" sudo usermod -aG falcond "$USER" \
            || warn "Could not add $USER to the falcond group — run 'sudo usermod -aG falcond $USER' manually"
    else
        warn "falcond group not found — falcond-gui may need to be run as root, or check the package docs"
    fi

    run_spinner "Enabling falcond.service" sudo systemctl enable --now falcond.service \
        || warn "Could not enable falcond.service — check 'systemctl status falcond' after reboot"

    if pacman -Qq scx-tools >/dev/null 2>&1; then
        run_spinner "Enabling scx_loader.service" sudo systemctl enable --now scx_loader.service \
            || warn "Could not enable scx_loader.service — falcond-gui won't detect schedulers without it running"
    fi
fi

# Download today's Bing wallpaper and set up waypaper to use it by default.
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

if pacman -Qq waypaper >/dev/null 2>&1; then
    mkdir -p ~/.config/waypaper
    if [ -e ~/.config/waypaper/config.ini ]; then
        warn "~/.config/waypaper/config.ini already exists — leaving your existing waypaper config alone"
    else
        cat > ~/.config/waypaper/config.ini <<EOF
[Settings]
language = en
folder = $WALLPAPER_DIR
wallpaper = $BING_FILE
backend = swaybg
monitors = All
fill = Fill
sort = name
color = #ffffff
subfolders = False
all_subfolders = False
show_hidden = False
show_gifs_only = False
show_path_in_tooltip = True
number_of_columns = 3
use_xdg_state = False
zen_mode = False
swww_transition_type = any
swww_transition_step = 63
swww_transition_angle = 0
swww_transition_duration = 2
swww_transition_fps = 60
mpvpaper_sound = False
mpvpaper_options =
post_command =
keybindings = ~/.config/waypaper/keybindings.ini
EOF
        ok "waypaper set to use ~/Pictures/Wallpaper as its default folder"
    fi
else
    warn "waypaper isn't installed — skipping wallpaper folder setup"
fi

# waypaper is just a GUI front-end — the actual wallpaper daemon is swaybg,
# and it has no config file of its own. Give it a systemd user service
# pointed at today's wallpaper so it starts automatically each session,
# rather than only being set inside waypaper's own config.
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
    run_spinner "Enabling swaybg.service" systemctl --user enable swaybg.service \
        || warn "Could not enable swaybg.service — it'll still work if launched manually or via Hyprland autostart"
    ok "swaybg pointed at today's Bing wallpaper via ~/.config/systemd/user/swaybg.service"
else
    warn "No downloaded wallpaper or swaybg not installed — skipping swaybg service setup"
fi

# Apply the Dracula GTK theme and the Bibata cursor theme, now that
# they're actually installed. This uses the same gsettings mechanism
# nwg-look reads/writes, so it shows up as already selected there too.
if pacman -Qq dracula-gtk-theme >/dev/null 2>&1 && command -v gsettings >/dev/null; then
    run_spinner "Applying Dracula GTK theme" \
        gsettings set org.gnome.desktop.interface gtk-theme 'Dracula' \
        || warn "Could not apply the Dracula GTK theme — select it manually in nwg-look"
elif ! pacman -Qq dracula-gtk-theme >/dev/null 2>&1; then
    warn "dracula-gtk-theme isn't installed — skipping GTK theme apply"
else
    warn "gsettings not found — select the Dracula theme manually in nwg-look"
fi

# Zafiro's AUR package has had reported issues with how it lays out its
# newer color-variant folders, so check the exact folder actually exists
# before pointing gsettings at it rather than assuming the name.
if pacman -Qq zafiro-icon-theme >/dev/null 2>&1 && command -v gsettings >/dev/null; then
    ZAFIRO_DRACULA_DIR=$(find /usr/share/icons -maxdepth 1 -iname 'zafiro-dracula*' -print -quit 2>/dev/null)
    if [ -n "$ZAFIRO_DRACULA_DIR" ]; then
        run_spinner "Applying Zafiro-Dracula icon theme" \
            gsettings set org.gnome.desktop.interface icon-theme "$(basename "$ZAFIRO_DRACULA_DIR")" \
            || warn "Could not apply the Zafiro-Dracula icon theme — select it manually in nwg-look"
    else
        warn "zafiro-icon-theme installed but no Zafiro-Dracula folder found under /usr/share/icons — check available variants with: ls /usr/share/icons | grep -i zafiro"
    fi
elif ! pacman -Qq zafiro-icon-theme >/dev/null 2>&1; then
    warn "zafiro-icon-theme isn't installed — skipping icon theme apply"
else
    warn "gsettings not found — select the Zafiro-Dracula icon theme manually in nwg-look"
fi

if pacman -Qq bibata-cursor-theme >/dev/null 2>&1 && command -v gsettings >/dev/null; then
    run_spinner "Applying Bibata Modern Classic cursor" \
        gsettings set org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Classic' \
        || warn "Could not apply the cursor theme — select it manually in nwg-look"
elif ! pacman -Qq bibata-cursor-theme >/dev/null 2>&1; then
    warn "bibata-cursor-theme isn't installed — skipping cursor theme apply"
else
    warn "gsettings not found — select the Bibata cursor theme manually in nwg-look"
fi

# ── Step 5: choose a browser ─────────────────────────────────────────
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

# ── Step 6: LazyVim ─────────────────────────────────────────────────
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

# Keep fish's default greeting message empty.
mkdir -p ~/.config/fish
touch ~/.config/fish/config.fish
if grep -qx 'set -g fish_greeting' ~/.config/fish/config.fish 2>/dev/null; then
    ok "fish greeting already set to empty"
else
    printf '\nset -g fish_greeting\n' >> ~/.config/fish/config.fish
    ok "fish greeting set to empty"
fi

# Run fastfetch on new fish sessions too.
if grep -qx 'fastfetch' ~/.config/fish/config.fish 2>/dev/null; then
    ok "fastfetch already set to run in fish"
else
    printf '\nfastfetch\n' >> ~/.config/fish/config.fish
    ok "fastfetch added to fish config"
fi

FISH_PATH=$(command -v fish)

# Deploy the Simpbar Welcome app (GTK4 + libadwaita) — setup shortcuts,
# keybindings reference, and links. Always refreshed from source since
# it's a shipped tool, not something meant to be hand-edited locally.
mkdir -p ~/.local/share/simpbar ~/.local/share/applications ~/.config/systemd/user

base64 -d > ~/.local/share/simpbar/logo.png <<'LOGOB64EOF'
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
LOGOB64EOF


cat > ~/.local/share/simpbar/simpbar_welcome.py <<'WELCOMEPYEOF'
#!/usr/bin/env python3
"""
Simpbar Welcome — a small GTK4 + libadwaita companion app for the
simpbar Hyprland setup (github.com/jaytheoutpatient/simpbar).

Usage:
    simpbar_welcome.py              Show the window normally.
    simpbar_welcome.py --autostart  Only show the window if it hasn't
                                     been shown before (first-login use).
"""

import re
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
    """Install the package (if needed) and write it as the waybar pin's
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


WAYBAR_CONFIG_PATH = Path.home() / ".config" / "waybar" / "config"
POSITION_RE = re.compile(r'"position"\s*:\s*"(top|bottom)"')


def get_waybar_position() -> str:
    try:
        match = POSITION_RE.search(WAYBAR_CONFIG_PATH.read_text())
        return match.group(1) if match else "bottom"
    except OSError:
        return "bottom"


def set_waybar_position(position: str) -> bool:
    """position is 'top' or 'bottom'. Restarts waybar so it takes effect
    right away. Returns True on success."""
    try:
        content = WAYBAR_CONFIG_PATH.read_text()
        new_content, count = POSITION_RE.subn(f'"position": "{position}"', content, count=1)
        if count == 0:
            return False
        WAYBAR_CONFIG_PATH.write_text(new_content)
        subprocess.run(["pkill", "-x", "waybar"], check=False)
        subprocess.Popen(["waybar"], start_new_session=True)
        return True
    except OSError as exc:
        print(f"simpbar-welcome: couldn't update waybar position: {exc}", file=sys.stderr)
        return False


COMMON_RESOLUTIONS = [
    "1920x1080",
    "2560x1440",
    "3840x2160",
    "1366x768",
    "1600x900",
    "1280x1024",
    "2560x1080",
    "3440x1440",
]
WIDTH_RE = re.compile(r'"width"\s*:\s*(\d+)')


def get_waybar_width() -> str:
    try:
        match = WIDTH_RE.search(WAYBAR_CONFIG_PATH.read_text())
        return match.group(1) if match else "1920"
    except OSError:
        return "1920"


def set_waybar_width(width: int) -> bool:
    """Restarts waybar so it takes effect right away. Returns True on success."""
    try:
        content = WAYBAR_CONFIG_PATH.read_text()
        new_content, count = WIDTH_RE.subn(f'"width": {width}', content, count=1)
        if count == 0:
            return False
        WAYBAR_CONFIG_PATH.write_text(new_content)
        subprocess.run(["pkill", "-x", "waybar"], check=False)
        subprocess.Popen(["waybar"], start_new_session=True)
        return True
    except OSError as exc:
        print(f"simpbar-welcome: couldn't update waybar width: {exc}", file=sys.stderr)
        return False


WAYBAR_STYLE_PATH = Path.home() / ".config" / "waybar" / "style.css"
FONT_RE = re.compile(r'font-family:\s*([^;]+);')

# name -> (CSS font-family value, package to install)
FONT_OPTIONS = [
    "JetBrainsMono Nerd Font (default)",
    "FiraCode Nerd Font",
    "Hack Nerd Font",
    "CaskaydiaCove Nerd Font",
    "Iosevka Nerd Font",
]
FONT_INFO = {
    "JetBrainsMono Nerd Font (default)": ("JetBrainsMonoNLNerdFontRegular", "ttf-jetbrains-mono-nerd"),
    "FiraCode Nerd Font": ("FiraCode Nerd Font", "ttf-firacode-nerd"),
    "Hack Nerd Font": ("Hack Nerd Font", "ttf-hack-nerd"),
    "CaskaydiaCove Nerd Font": ("CaskaydiaCove Nerd Font", "ttf-cascadia-code-nerd"),
    "Iosevka Nerd Font": ("Iosevka Nerd Font", "ttf-iosevka-nerd"),
}


def get_current_font_family() -> str:
    try:
        match = FONT_RE.search(WAYBAR_STYLE_PATH.read_text())
        return match.group(1).strip() if match else "JetBrainsMonoNLNerdFontRegular"
    except OSError:
        return "JetBrainsMonoNLNerdFontRegular"


def build_apply_font_argv(family: str, pkg: str) -> list[str]:
    """Installs the font package (all official-repo, so a plain pacman
    install), edits waybar's style.css, then restarts waybar."""
    install_cmd = f"sudo pacman -S --noconfirm --needed {pkg}"
    edit_cmd = f"sed -i 's/font-family:.*/font-family: {family};/' {WAYBAR_STYLE_PATH}"
    restart_cmd = "pkill -x waybar; (waybar & disown)"
    full_cmd = f"{install_cmd}; {edit_cmd}; {restart_cmd}; echo; read -p 'Press Enter to close...'"
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
            description="Picks which app the waybar Browser/Discord pins launch. "
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

        waybar_group = Adw.PreferencesGroup(title="Waybar")

        position_row = Adw.ComboRow(
            title="Bar position",
            subtitle="Moves the bar and restarts waybar right away.",
            model=Gtk.StringList.new(["Top", "Bottom"]),
        )
        position_row.set_selected(0 if get_waybar_position() == "top" else 1)

        position_button = Gtk.Button(label="Apply")
        position_button.add_css_class("flat")
        position_button.set_valign(Gtk.Align.CENTER)

        def _on_position_apply(_b: Gtk.Button) -> None:
            choice = "top" if position_row.get_selected() == 0 else "bottom"
            if set_waybar_position(choice):
                position_row.set_subtitle(f"Bar moved to the {choice}.")
            else:
                position_row.set_subtitle(
                    "Could not update the config — check ~/.config/waybar/config exists."
                )

        position_button.connect("clicked", _on_position_apply)
        position_row.add_suffix(position_button)
        waybar_group.add(position_row)

        resolution_row = Adw.ComboRow(
            title="Screen resolution",
            subtitle="Sets the bar's width to span your monitor.",
            model=Gtk.StringList.new(COMMON_RESOLUTIONS),
        )
        current_width = get_waybar_width()
        resolution_row.set_selected(next(
            (i for i, res in enumerate(COMMON_RESOLUTIONS) if res.split("x")[0] == current_width),
            0,
        ))

        resolution_button = Gtk.Button(label="Apply")
        resolution_button.add_css_class("flat")
        resolution_button.set_valign(Gtk.Align.CENTER)

        def _on_resolution_apply(_b: Gtk.Button) -> None:
            res = COMMON_RESOLUTIONS[resolution_row.get_selected()]
            width = int(res.split("x")[0])
            if set_waybar_width(width):
                resolution_row.set_subtitle(f"Bar width set to {width}px ({res}).")
            else:
                resolution_row.set_subtitle(
                    "Could not update the config — check ~/.config/waybar/config exists."
                )

        resolution_button.connect("clicked", _on_resolution_apply)
        resolution_row.add_suffix(resolution_button)
        waybar_group.add(resolution_row)

        font_row = Adw.ComboRow(
            title="Font",
            subtitle="Installs the font if needed, then applies it to the bar.",
            model=Gtk.StringList.new(FONT_OPTIONS),
        )
        current_family = get_current_font_family()
        font_row.set_selected(next(
            (i for i, name in enumerate(FONT_OPTIONS) if FONT_INFO[name][0] == current_family),
            0,
        ))

        font_button = Gtk.Button(label="Apply")
        font_button.add_css_class("flat")
        font_button.set_valign(Gtk.Align.CENTER)
        font_button.connect(
            "clicked",
            lambda _b: launch(build_apply_font_argv(*FONT_INFO[FONT_OPTIONS[font_row.get_selected()]])),
        )
        font_row.add_suffix(font_button)
        waybar_group.add(font_row)

        self.append(waybar_group)

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
WELCOMEPYEOF
chmod +x ~/.local/share/simpbar/simpbar_welcome.py

# A thin /usr/bin wrapper so it's launchable by name — from a terminal,
# rofi's "run" mode, etc. — not just via the .desktop entry. Uses $HOME
# at runtime (not baked in), so it works correctly for any user.
sudo tee /usr/bin/simpbar-welcome >/dev/null <<'WRAPPEREOF'
#!/bin/bash
exec python3 "$HOME/.local/share/simpbar/simpbar_welcome.py" "$@"
WRAPPEREOF
sudo chmod +x /usr/bin/simpbar-welcome

# Background update checker — Arch/AUR package updates + new commits on
# the simpbar repo — fires a desktop notification via notify-send/swaync.
sudo tee /usr/bin/simpbar-check-updates >/dev/null <<'CHECKERPEOF'
#!/bin/bash
# simpbar-check-updates — checks for Arch/AUR package updates and new
# commits on the simpbar GitHub repo, and fires a desktop notification
# (via notify-send / swaync) if either is found. Safe to run repeatedly
# and safe with no network (just does nothing that turn).

CACHE_DIR="$HOME/.cache/simpbar"
COMMIT_CACHE="$CACHE_DIR/last-commit-sha"
mkdir -p "$CACHE_DIR"

MESSAGES=()

# Official repo updates — checkupdates syncs its own temp db, no root needed.
if command -v checkupdates >/dev/null 2>&1; then
    PKG_COUNT=$(checkupdates 2>/dev/null | wc -l)
    [ "$PKG_COUNT" -gt 0 ] && MESSAGES+=("$PKG_COUNT Arch package update(s) available")
fi

# AUR updates, if a helper is available.
if command -v yay >/dev/null 2>&1; then
    AUR_COUNT=$(yay -Qua 2>/dev/null | wc -l)
    [ "$AUR_COUNT" -gt 0 ] && MESSAGES+=("$AUR_COUNT AUR update(s) available")
elif command -v paru >/dev/null 2>&1; then
    AUR_COUNT=$(paru -Qua 2>/dev/null | wc -l)
    [ "$AUR_COUNT" -gt 0 ] && MESSAGES+=("$AUR_COUNT AUR update(s) available")
fi

# New commits on the simpbar repo's main branch.
LATEST_SHA=$(curl -fsSL "https://api.github.com/repos/jaytheoutpatient/simpbar/commits/main" 2>/dev/null \
    | grep -m1 '"sha"' | cut -d'"' -f4)
if [ -n "$LATEST_SHA" ]; then
    PREV_SHA=$(cat "$COMMIT_CACHE" 2>/dev/null || echo "")
    # Only notify if we've seen a previous commit before (i.e. not the very
    # first run) and it's actually different.
    if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "$LATEST_SHA" ]; then
        MESSAGES+=("New commit(s) on the simpbar GitHub repo")
    fi
    echo "$LATEST_SHA" > "$COMMIT_CACHE"
fi

if [ "${#MESSAGES[@]}" -gt 0 ] && command -v notify-send >/dev/null 2>&1; then
    BODY=$(printf '%s\n' "${MESSAGES[@]}")
    notify-send -a "Simpbar" -i software-update-available-symbolic \
        "Simpbar updates available" "$BODY"
fi
CHECKERPEOF
sudo chmod +x /usr/bin/simpbar-check-updates

# Pinned-app launchers for waybar — browser and Discord client are both
# user-chosen at install time, so these try known binaries in order and
# launch whichever's actually installed.
sudo tee /usr/bin/simpbar-launch-browser >/dev/null <<'BROWSERWRAPEOF'
#!/bin/bash
# simpbar-launch-browser — checks ~/.config/simpbar/browser-choice first (set
# via the Welcome app's Setup tab); falls back to trying known binaries in
# order if no preference is set or the preferred one isn't actually installed.
PREF_FILE="$HOME/.config/simpbar/browser-choice"
if [ -r "$PREF_FILE" ]; then
    preferred=$(cat "$PREF_FILE")
    [ -n "$preferred" ] && command -v "$preferred" >/dev/null 2>&1 && exec "$preferred"
fi
for bin in brave zen-browser zen vivaldi-stable vivaldi microsoft-edge-stable librewolf firefox; do
    if command -v "$bin" >/dev/null 2>&1; then
        exec "$bin"
    fi
done
command -v notify-send >/dev/null 2>&1 && \
    notify-send -a "Simpbar" "No browser found" \
        "Install one from the Simpbar Welcome app or install script."
BROWSERWRAPEOF
sudo chmod +x /usr/bin/simpbar-launch-browser

sudo tee /usr/bin/simpbar-launch-discord >/dev/null <<'DISCORDWRAPEOF'
#!/bin/bash
# simpbar-launch-discord — checks ~/.config/simpbar/discord-choice first (set
# via the Welcome app's Setup tab); falls back to trying known binaries in
# order if no preference is set or the preferred one isn't actually installed.
PREF_FILE="$HOME/.config/simpbar/discord-choice"
if [ -r "$PREF_FILE" ]; then
    preferred=$(cat "$PREF_FILE")
    [ -n "$preferred" ] && command -v "$preferred" >/dev/null 2>&1 && exec "$preferred"
fi
for bin in vesktop equibop discord; do
    if command -v "$bin" >/dev/null 2>&1; then
        exec "$bin"
    fi
done
command -v notify-send >/dev/null 2>&1 && \
    notify-send -a "Simpbar" "No Discord client found" \
        "Install one from the Simpbar Welcome app or install script."
DISCORDWRAPEOF
sudo chmod +x /usr/bin/simpbar-launch-discord
ok "Pinned-app launchers (browser, Discord) ready for waybar"


cat > ~/.config/systemd/user/simpbar-update-checker.service <<'CHECKERSVCEOF'
[Unit]
Description=Check for simpbar/Arch updates

[Service]
Type=oneshot
ExecStart=/usr/bin/simpbar-check-updates
CHECKERSVCEOF

cat > ~/.config/systemd/user/simpbar-update-checker.timer <<'CHECKERTIMEREOF'
[Unit]
Description=Periodically check for simpbar/Arch updates

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
CHECKERTIMEREOF

if pacman -Qq pacman-contrib >/dev/null 2>&1 && pacman -Qq libnotify >/dev/null 2>&1; then
    run_spinner "Enabling simpbar-update-checker.timer" systemctl --user enable --now simpbar-update-checker.timer \
        || warn "Could not enable simpbar-update-checker.timer — enable it manually: systemctl --user enable --now simpbar-update-checker.timer"
else
    warn "pacman-contrib/libnotify not fully installed — skipping the update-checker timer"
fi


cat > ~/.local/share/applications/simpbar-welcome.desktop <<'WELCOMEDESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Simpbar Welcome
Comment=Setup actions, keybindings, and links for the simpbar Hyprland setup
Exec=simpbar-welcome
Icon=preferences-desktop-display-symbolic
Terminal=false
Categories=Settings;
StartupNotify=true
WELCOMEDESKTOPEOF

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

if pacman -Qq gtk4 >/dev/null 2>&1 && pacman -Qq libadwaita >/dev/null 2>&1 && pacman -Qq python-gobject >/dev/null 2>&1; then
    run_spinner "Enabling simpbar-welcome.service" systemctl --user enable --now simpbar-welcome.service \
        || warn "Could not enable simpbar-welcome.service — launch it manually: simpbar-welcome"
    ok "Simpbar Welcome app installed — will show once on first login, or launch it anytime from rofi"
else
    warn "GTK4/libadwaita/python-gobject not fully installed — skipping Simpbar Welcome autostart"
fi


run_spinner "Updating the full system (pacman -Syu)" sudo pacman -Syu --noconfirm \
    || warn "Full system update failed — run 'sudo pacman -Syu' manually to check for issues"

# ── Step 7: done ────────────────────────────────────────────────────
step "Done"
ok "Full system updated (pacman -Syu)"
ok "waybar, gnome-calendar, nautilus, mate-polkit, swaybg, JetBrainsMono Nerd Font, Noto Fonts, Noto Emoji, hyprland, foot, fastfetch, neovim, steam, swaync, rofi, flatpak, bazaar, nwg-look, pavucontrol, pipewire, gnome-disk-utility, nwg-drawer installed (pacman)"
ok "pipewire, pipewire-pulse, wireplumber enabled as user services"
if pacman -Qq cliphist >/dev/null 2>&1; then
    ok "cliphist installed (bind a key to it yourself, e.g. in hyprland.lua)"
fi
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
if pacman -Qq dracula-gtk-theme >/dev/null 2>&1; then
    ok "Dracula GTK theme installed and applied"
fi
if pacman -Qq zafiro-icon-theme >/dev/null 2>&1; then
    ok "Zafiro-Dracula icon theme installed"
fi
if pacman -Qq bibata-cursor-theme >/dev/null 2>&1; then
    ok "Bibata Modern Classic cursor installed and applied"
fi
if pacman -Qq hyprmod >/dev/null 2>&1; then
    ok "HyprMod installed (GTK4 settings app for Hyprland — writes only to its own hyprland-gui.conf)"
fi
if pacman -Qq game-devices-udev >/dev/null 2>&1; then
    ok "game-devices-udev installed — Xbox/PlayStation/generic controllers get proper permissions"
fi
if [ -e ~/.config/systemd/user/simpbar-update-checker.timer ]; then
    ok "Update checker enabled — notifies on new Arch/AUR updates or new commits on the simpbar repo (checks every 6h)"
fi
if pacman -Qq falcond >/dev/null 2>&1; then
    ok "falcond & falcond-gui installed (log out/in for group membership to apply)"
fi
if pacman -Qq scx-scheds >/dev/null 2>&1; then
    ok "scx-scheds installed (provides the sched_ext schedulers falcond can switch between)"
fi
if pacman -Qq scx-tools >/dev/null 2>&1; then
    ok "scx-tools installed and scx_loader.service enabled (lets falcond-gui detect schedulers)"
fi
if [ -e ~/.config/rofi/config.rasi ]; then
    ok "rofi configured with the Material theme"
fi
ok "wlogout, waypaper, protonplus installed via AUR helper (if available)"
if [ -n "$BROWSER_NAME" ]; then
    ok "$BROWSER_NAME installed via AUR helper (if available)"
else
    ok "Browser install skipped, as requested"
fi
if grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
    ok "Chaotic-AUR repo enabled"
fi
if [ -e ~/.config/waypaper/config.ini ]; then
    ok "waypaper default folder set to ~/Pictures/Wallpaper"
fi
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    ok "Today's Bing wallpaper downloaded to ~/Pictures/Wallpaper"
fi
if [ -e ~/.config/systemd/user/swaybg.service ]; then
    ok "swaybg.service enabled — will set the wallpaper automatically each session"
fi
ok "waybar config in ~/.config/waybar"
ok "hypr config in ~/.config/hypr"
ok "swaync config in ~/.config/swaync"
ok "LazyVim config in ~/.config/nvim (run 'nvim' to finish plugin install)"
ok "fastfetch runs automatically in new terminal sessions (~/.bashrc)"
ok "fish shell installed with an empty greeting message and fastfetch on launch"

printf '\n%s%s Setup complete!%s\n' "$C_GREEN$C_BOLD" "✔" "$C_RESET"
printf '%sRestart your session, or run:%s\n' "$C_BOLD" "$C_RESET"
printf '  %swaybar &%s\n' "$C_CYAN" "$C_RESET"
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    printf '  %sswaybg -i %s -m fill &%s\n' "$C_CYAN" "$BING_FILE" "$C_RESET"
else
    printf '  %sswaybg -i /path/to/your/wallpaper.jpg -m fill &%s   # example\n' "$C_CYAN" "$C_RESET"
fi
printf '  %swaypaper%s                                          # pick a wallpaper\n' "$C_CYAN" "$C_RESET"
printf '  %s/usr/lib/mate-polkit/polkit-mate-authentication-agent-1 &%s   # needed for GUI auth prompts\n' "$C_CYAN" "$C_RESET"

printf '\n%sKeybindings:%s\n' "$C_BOLD" "$C_RESET"
printf '  %sSUPER%s                    = Windows key\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Enter%s            = Open terminal\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Space%s            = Open Rofi\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + E%s                = Open Nautilus\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Q%s                = Exit the application\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + [1-0]%s            = Switch workspaces\n' "$C_CYAN" "$C_RESET"
printf '\n%sTo change your keybindings or set your monitor resolution, edit the config with:%s\n' "$C_BOLD" "$C_RESET"
printf '  %snvim ~/.config/hypr/hyprland.lua%s\n' "$C_CYAN" "$C_RESET"
printf '\n%sEnjoy your new home & workflow! :)%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '\n%sDon'"'"'t forget to reboot! Please use: systemctl reboot%s\n' "$C_YELLOW" "$C_RESET"

# Switch the default login shell to fish. This runs last, on its own, with
# stdin/stdout attached directly to /dev/tty — chsh needs a real interactive
# terminal to prompt for your password, which it doesn't have if this
# script is being run as `curl ... | bash` (stdin is the piped script, not
# your keyboard). Running it through run_spinner earlier made this worse,
# since that also backgrounds the command and swallows its output.
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

#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════════════════╗
# ║                                                                               ║
# ║                     ✨ Xero Arch Installer v2.0.0 ✨                          ║
# ║                                                                               ║
# ║          A beautiful, streamlined Arch Linux installer for XeroLinux         ║
# ║                                                                               ║
# ╚═══════════════════════════════════════════════════════════════════════════════╝
#
# Author: XeroLinux Team
# License: GPL-3.0
#
# Simpbar fork: optional simpbar desktop (Hyprland or MangoWM — bar,
# widgets, configs and helpers built and deployed into the new system),
# Limine bootloader instead of GRUB. Base-system flow otherwise unchanged
# from upstream v2.0.0.

set -Eeuo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

VERSION="2.0.0"
SCRIPT_NAME="Xero Arch Installer"
PART_LABEL="Part 1 - Pacstrap"

# Mountpoint for installation
MOUNTPOINT="/mnt"

# Colors (fallback)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Screen-size-aware centering ────────────────────────────────────────────────
# Real terminal width, not a hardcoded guess — so centering actually centers on
# whatever console resolution the ISO booted into, not just an assumed 80 cols.
term_cols() {
    local cols
    cols=$(tput cols 2>/dev/null) || cols=80
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    echo "$cols"
}

term_lines() {
    local lines
    lines=$(tput lines 2>/dev/null) || lines=24
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
    echo "$lines"
}

# Number of blank lines to print above a block of $1 lines so it sits
# vertically centered on the real terminal height, instead of pinned to
# the top row.
vpad_for() {
    local content_height="$1"
    local rows; rows=$(term_lines)
    local pad=$(( (rows - content_height) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    echo "$pad"
}

print_vpad() {
    local n="$1" i
    for (( i = 0; i < n; i++ )); do echo ""; done
}

# Pads $1 with leading spaces to center it within $2 columns (default: real
# terminal width). Used for gum choose/filter lists, which have no native
# alignment flag of their own — gum renders each line's text exactly as
# given, so centering the text itself is what actually centers the list.
center_pad() {
    local text="$1" width="${2:-$(term_cols)}"
    local len=${#text}
    local pad=$(( (width - len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf '%*s%s' "$pad" '' "$text"
}

# Installation configuration (associative array)
declare -A CONFIG
CONFIG[installer_lang]="English"
CONFIG[locale]="en_US.UTF-8"
CONFIG[keyboard]="us"
CONFIG[timezone]="UTC"
CONFIG[hostname]="xerolinux"
CONFIG[username]=""
CONFIG[user_password]=""
CONFIG[root_password]=""
CONFIG[disk]=""
CONFIG[filesystem]="btrfs"
CONFIG[encrypt]="no"
CONFIG[encrypt_boot]="no"
CONFIG[encrypt_password]=""
CONFIG[swap]="zram"
CONFIG[swap_algo]="zstd"
CONFIG[gfx_driver]="mesa"
CONFIG[parallel_downloads]="5"
CONFIG[aur_helper]="paru"
CONFIG[extra_kernel]=""
# Simpbar desktop (Hyprland/MangoWM + bar, widgets, configs). "none" keeps
# the old base-only behavior; the file-manager/terminal picks only matter
# when a desktop is chosen (keybinds + default pins), and default to the
# same values install.sh uses.
CONFIG[desktop]="none"
CONFIG[file_manager]="nautilus"
CONFIG[terminal_bin]="alacritty"
CONFIG[terminal_class]="Alacritty"
CONFIG[terminal_e]="-e"
CONFIG[uefi]="no"
CONFIG[boot_part]=""
CONFIG[root_part]=""
CONFIG[root_device]=""
CONFIG[partition_mode]="auto"
CONFIG[reuse_efi]="no"
# Desktop-phase extra packages (picked from the main menu, installed later
# by install_user_packages once the desktop phase runs as the new user).
CONFIG[extra_browser]=""
CONFIG[extra_social]=""
CONFIG[extra_dev]=""
CONFIG[extra_pass]=""
CONFIG[extra_imaging]=""
CONFIG[extra_music]=""
CONFIG[extra_video]=""
CONFIG[extra_gaming]=""
CONFIG[wants_libreoffice]="no"
CONFIG[lo_locale]=""
CONFIG[lo_hunspell]=""

# ────────────────────────────────────────────────────────────────────────────────
# ERROR HANDLING
# ────────────────────────────────────────────────────────────────────────────────

have_gum() { command -v gum &>/dev/null; }

on_err() {
    local exit_code=$?
    local line_no=${1:-?}
    local cmd=${2:-?}

    # run_step_visual redirects each step's stdout/stderr to a logfile, so
    # without this an error here would vanish into it instead of the user.
    exec > /dev/tty 2>&1 || true
    tput cnorm 2>/dev/null || true

    if have_gum; then
        gum style --foreground 196 --bold --margin "1 2" \
            "❌ ERROR (exit=$exit_code) at line $line_no" \
            "$cmd"
        echo ""
        gum style --foreground 245 --margin "0 2" \
            "Tip: If this was during formatting, it's often missing partitions (udev timing) or empty device paths."
        echo ""
        gum input --placeholder "Press Enter to exit..." --width 50
    else
        echo -e "${RED}ERROR (exit=$exit_code) at line $line_no${NC}"
        echo -e "${RED}$cmd${NC}"
    fi

    exit "$exit_code"
}

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
# Always restore the cursor and kill run_step_visual's background redraw
# loop (a forked process, not a child that dies on its own) on any exit.
DISPLAY_PID=""
trap 'kill "$DISPLAY_PID" 2>/dev/null || true; tput cnorm 2>/dev/null || true' EXIT

# ────────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ────────────────────────────────────────────────────────────────────────────────

# Set up sudo command (empty if running as root/in chroot)
setup_sudo() {
    if [ "${EUID:-0}" -eq 0 ]; then
        SUDO_CMD=""
    else
        SUDO_CMD="sudo"
    fi
}

check_root() {
    if [[ ${EUID:-0} -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Please run: sudo $0"
        exit 1
    fi
    setup_sudo
}

check_uefi() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        CONFIG[uefi]="yes"
    else
        CONFIG[uefi]="no"
    fi
}

# Cache so we never "re-check" during the same run
INTERNET_OK="no"

check_internet() {
    [[ "$INTERNET_OK" == "yes" ]] && return 0

    if ping -c 1 -W 3 archlinux.org &>/dev/null; then
        INTERNET_OK="yes"
        return 0
    fi

    echo -e "${RED}Error: No internet connection (or DNS is broken)${NC}"
    echo "Fix networking, then re-run the installer."
    exit 1
}

ensure_dependencies() {
    local deps_needed=()

    command -v gum &>/dev/null || deps_needed+=("gum")
    command -v parted &>/dev/null || deps_needed+=("parted")
    command -v arch-chroot &>/dev/null || deps_needed+=("arch-install-scripts")

    command -v sgdisk &>/dev/null || deps_needed+=("gptfdisk")
    command -v mkfs.btrfs &>/dev/null || deps_needed+=("btrfs-progs")
    command -v mkfs.fat &>/dev/null || deps_needed+=("dosfstools")
    command -v mkfs.ext4 &>/dev/null || deps_needed+=("e2fsprogs")
    command -v mkfs.xfs &>/dev/null || deps_needed+=("xfsprogs")
    command -v cryptsetup &>/dev/null || deps_needed+=("cryptsetup")
    command -v curl &>/dev/null || deps_needed+=("curl")
    # Needed by the desktop step (simpbar source arrives as a zip).
    command -v unzip &>/dev/null || deps_needed+=("unzip")

    if [[ ${#deps_needed[@]} -gt 0 ]]; then
        echo -e "${CYAN}Installing required dependencies...${NC}"
        # Fresh ISOs often have an uninitialized pacman keyring, which
        # fails every install with signature errors. Initializing it here
        # is a harmless no-op when already done and fixes the cold-boot
        # case. `timeout` guards entropy-starved VMs where --init could
        # otherwise sit forever waiting on randomness.
        if ! pacman-key --list-keys &>/dev/null; then
            if command -v timeout &>/dev/null; then
                timeout 120 pacman-key --init &>/dev/null || true
            else
                pacman-key --init &>/dev/null || true
            fi
            pacman-key --populate archlinux &>/dev/null || true
        fi
        # Never swallow pacman's output: a failed dependency install used
        # to die silently here, leaving only a confusing missing binary
        # several steps later.
        local dep_log
        dep_log=$(mktemp)
        if ! pacman -Sy --noconfirm "${deps_needed[@]}" >"$dep_log" 2>&1; then
            echo -e "${RED}Dependency install failed — pacman's output:${NC}"
            tail -n 12 "$dep_log"
        fi
        rm -f "$dep_log"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# GUM UI HELPERS
# ────────────────────────────────────────────────────────────────────────────────

show_splash() {
    local cols; cols=$(term_cols)
    clear
    tput civis
    # Content height: title (padding "2 0" = 2+1+2=5) + subtitle (1) +
    # blank (1) + version (1) = 8 lines.
    print_vpad "$(vpad_for 8)"
    gum style --foreground 198 --bold --align center --width "$cols" --padding "2 0" \
        "X E R O L I N U X"
    gum style --foreground 45 --align center --width "$cols" \
        "A R C H   I N S T A L L E R"
    echo ""
    gum style --foreground 245 --align center --width "$cols" \
        "v$VERSION"
    sleep 3

    # Discard any keystrokes buffered during the sleep (an impatient Enter
    # meant to skip the splash) so they can't leak into the main menu's
    # gum choose right after and get consumed as a selection before the
    # user ever sees the menu. Drains /dev/tty, never fd0: when launched
    # via `curl | bash` (no file argument), fd0 IS bash's own script
    # source being read incrementally — draining it here could eat bytes
    # of the script itself that bash hasn't consumed yet.
    while read -r -t 0.05 -n 1000 _ < /dev/tty 2>/dev/null; do :; done
}

show_header() {
    clear
    local cols; cols=$(term_cols)
    local box_width=$(( cols - 4 ))
    [[ $box_width -lt 40 ]] && box_width=40
    # Small top margin so the header doesn't sit glued to row 0 on
    # submenu screens (whose own content below varies in height, so it
    # can't be fully vertically centered here without knowing that).
    print_vpad "$(( $(term_lines) / 10 ))"
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --align center --width "$box_width" --margin "0 2" --padding "1 2" \
        "✨ $SCRIPT_NAME v$VERSION ✨" \
        "" \
        "Installs a base Arch system (optional simpbar desktop: Hyprland/MangoWM)," \
        "with more configuration options than the ISO installer." \
        "For experienced Arch/Linux users. NOT beginner-friendly."
}

show_submenu_header() {
    local title="$1"
    gum style \
        --foreground 212 --bold --margin "1 2" \
        "$title"
}

# Fall back to plain echo when gum isn't installed yet (true early in the
# desktop phase, which reuses these same helpers before install_packages runs).
show_info() {
    if have_gum; then
        gum style --foreground 81 --margin "0 2" "$1"
    else
        echo "$1"
    fi
}

show_success() {
    if have_gum; then
        gum style --foreground 82 "  ✓ $1"
    else
        echo "  OK: $1"
    fi
}

show_error() {
    if have_gum; then
        gum style --foreground 196 "  ✗ $1"
    else
        echo "  ERROR: $1"
    fi
}

show_warning() {
    if have_gum; then
        gum style --foreground 214 "  ⚠ $1"
    else
        echo "  WARN: $1"
    fi
}

confirm_action() {
    # $2="no" focuses the "No" button by default — used for encryption
    # prompts so an impatient double Enter can't silently turn it on.
    if [[ "${2:-}" == "no" ]]; then
        gum confirm --affirmative "Yes" --negative "No" --default=false "$1"
    else
        gum confirm --affirmative "Yes" --negative "No" "$1"
    fi
}

# Big block-letter "XEROLINUX" wordmark, 53 cols wide — drawn with the same
# U+2588 FULL BLOCK used by the progress bar itself, so it's exactly as
# console-safe as the bar already proven to render correctly here. Skipped
# entirely on a narrow terminal (see draw_progress_bar) rather than wrapped.
XEROLOGO=(
    "█   █ █████ ████   ███  █     █████ █   █ █   █ █   █"
    " █ █  █     █   █ █   █ █       █   ██  █ █   █  █ █ "
    "  █   ████  ████  █   █ █       █   █ █ █ █   █   █  "
    " █ █  █     █  █  █   █ █       █   █  ██ █   █  █ █ "
    "█   █ █████ █   █  ███  █████ █████ █   █  ███  █   █"
)

# Pure bash/tput/printf, no gum — redrawn many times a second from
# run_step_visual's background loop, and gum (a separate process per call)
# hit real panics there under rapid repeated invocation.
draw_progress_bar() {
    local pct="$1" step_num="$2" total="$3" title="$4"
    # $5 lets the caller pin the column width for the whole redraw loop
    # instead of re-querying term_cols() every 0.3s, which occasionally
    # flickered between values across frames and (since frames are never
    # cleared between redraws) left two widths' text visible at once.
    local cols="${5:-$(term_cols)}"
    local width=50
    [[ $width -gt $(( cols - 10 )) ]] && width=$(( cols - 10 ))
    [[ $width -lt 10 ]] && width=10
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    [[ $filled -gt 0 ]] && bar+=$(printf '█%.0s' $(seq 1 "$filled"))
    [[ $empty -gt 0 ]] && bar+=$(printf '░%.0s' $(seq 1 "$empty"))

    # Wordmark only fits a real terminal, not the narrowest ones this still
    # has to support — skipped below that width rather than wrapped/clipped.
    if [[ $cols -ge 58 ]]; then
        local logo_line
        for logo_line in "${XEROLOGO[@]}"; do
            printf '\033[38;5;198m\033[1m%s\033[0m\033[K\n' "$(center_pad "$logo_line" "$cols")"
        done
        printf '\033[K\n'
    fi

    # \033[K erases to end of line: center_pad only adds leading padding,
    # so without this a wider previous frame's tail would never get
    # overwritten (frames are never cleared between redraws, to avoid flicker).
    printf '\033[38;5;198m\033[1m%s\033[0m\033[K\n' "$(center_pad "${pct}%" "$cols")"
    printf '\033[K\n'
    printf '\033[38;5;45m%s\033[0m\033[K\n' "$(center_pad "$bar" "$cols")"
    printf '\033[K\n'
    printf '\033[38;5;45m\033[1m%s\033[0m\033[K\n' "$(center_pad "$PART_LABEL" "$cols")"
    printf '\033[38;5;212m\033[1m%s\033[0m\033[K\n' "$(center_pad "Step $step_num of $total: $title" "$cols")"
    printf '\033[K\n'
    printf '\033[38;5;245m%s\033[0m\033[K\n' "$(center_pad "(Be patient while system installs. If it looks stuck it's normal.)" "$cols")"
}

run_step_visual() {
    # Runs a function/command in the CURRENT shell (no subshell), so CONFIG
    # changes persist. Additionally shows a live percent bar + step title +
    # a live-scrolling box of the step's own command output while it runs.
    local step_num="$1" total="$2" title="$3"
    shift 3
    local func="$1"; shift

    local logfile
    logfile=$(mktemp)

    # Percent range this step owns, from where the previous step left off to
    # where the next starts. Progress within it is approximated from how
    # much log output has appeared so far, capped short of the next step's
    # value so it never overshoots before the step actually finishes.
    local base_pct=$(( (step_num - 1) * 100 / total ))
    local next_pct=$(( step_num * 100 / total ))
    local range=$(( next_pct - base_pct ))
    [[ $range -lt 1 ]] && range=1

    # Redraws reposition to the top (`tput cup`) instead of re-clearing —
    # frames are a fixed size, so this avoids visible flicker. Content
    # height must match what draw_progress_bar prints at this width: 6
    # extra lines for the logo when the terminal is wide enough to show it.
    local cols; cols=$(term_cols)
    local content_height=8
    [[ $cols -ge 58 ]] && content_height=$(( content_height + 6 ))
    local top_row; top_row=$(vpad_for "$content_height")

    clear
    tput civis
    (
        # Geometry is re-checked every frame, not pinned: a mid-step
        # terminal resize otherwise leaves cup repositioning stale
        # coordinates and shreds overlapping frames across the screen.
        # A real size change clears and rebuilds; identical geometry
        # keeps the flicker-free cup repositioning.
        last_cols="$cols"
        while true; do
            cols=$(term_cols)
            if [[ "$cols" != "$last_cols" ]]; then
                clear
                content_height=8
                [[ $cols -ge 58 ]] && content_height=$(( content_height + 6 ))
                top_row=$(vpad_for "$content_height")
                last_cols=$cols
            else
                tput cup "$top_row" 0
            fi
            local lines sub live_pct
            lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
            sub=$(( lines / 4 ))
            [[ $sub -gt $(( range - 1 )) ]] && sub=$(( range - 1 ))
            [[ $sub -lt 0 ]] && sub=0
            live_pct=$(( base_pct + sub ))
            draw_progress_bar "$live_pct" "$step_num" "$total" "$title" "$cols"
            sleep 0.3
        done
    ) &
    local display_pid=$!
    DISPLAY_PID="$display_pid"

    "$func" "$@" > "$logfile" 2>&1
    local status=$?

    # `wait` on a job we just killed reports its SIGTERM exit status (143) —
    # that's expected, not a real failure, but under `set -e` a bare nonzero
    # return here would trigger the global ERR trap and kill the whole
    # installer. `|| true` on both is required, not cosmetic.
    kill "$display_pid" 2>/dev/null || true
    wait "$display_pid" 2>/dev/null || true
    DISPLAY_PID=""
    tput cnorm

    if [[ $status -ne 0 ]]; then
        clear
        print_vpad "$top_row"
        draw_progress_bar "$base_pct" "$step_num" "$total" "$title" "$cols"
        show_error "Step failed: $title"
        # The live output box is gone by design, but on an actual failure
        # "Step failed: X" with no detail at all is worse than the box —
        # show the tail of what the step actually printed before it died.
        if [[ -s "$logfile" ]]; then
            echo ""
            echo "Last output before failure:"
            tail -n 15 "$logfile"
        fi
        rm -f "$logfile"
        return $status
    fi
    rm -f "$logfile"
    return 0
}

# ────────────────────────────────────────────────────────────────────────────────
# 1. INSTALLER LANGUAGE
# ────────────────────────────────────────────────────────────────────────────────

select_installer_language() {
    show_header
    show_submenu_header "🌐 Installer Language"
    echo ""
    show_info "Select the language for this installer interface"
    echo ""

    local languages=(
        "English"
        "Deutsch (German)"
        "Español (Spanish)"
        "Français (French)"
        "Italiano (Italian)"
        "Português (Portuguese)"
        "Русский (Russian)"
        "日本語 (Japanese)"
        "中文 (Chinese)"
        "한국어 (Korean)"
        "العربية (Arabic)"
        "Polski (Polish)"
        "Nederlands (Dutch)"
        "Türkçe (Turkish)"
    )

    local selection=""
    selection=$(printf '%s\n' "${languages[@]}" | gum choose --height 15 --header "Choose language:") || true

    if [[ -n "$selection" ]]; then
        CONFIG[installer_lang]="$selection"
        show_success "Language set to: $selection"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 2. LOCALES (System Language + Keyboard)
# ────────────────────────────────────────────────────────────────────────────────

select_locales() {
    show_header
    show_submenu_header "🗺️ System Locales"
    echo ""

    show_info "Select your system locale (language & encoding)"
    echo ""

    local locales=(
        "en_US.UTF-8"
        "en_GB.UTF-8"
        "de_DE.UTF-8"
        "fr_FR.UTF-8"
        "es_ES.UTF-8"
        "it_IT.UTF-8"
        "pt_BR.UTF-8"
        "pt_PT.UTF-8"
        "ru_RU.UTF-8"
        "ja_JP.UTF-8"
        "ko_KR.UTF-8"
        "zh_CN.UTF-8"
        "zh_TW.UTF-8"
        "ar_SA.UTF-8"
        "pl_PL.UTF-8"
        "nl_NL.UTF-8"
        "tr_TR.UTF-8"
        "vi_VN.UTF-8"
        "sv_SE.UTF-8"
        "da_DK.UTF-8"
        "fi_FI.UTF-8"
        "nb_NO.UTF-8"
        "cs_CZ.UTF-8"
        "hu_HU.UTF-8"
        "el_GR.UTF-8"
        "he_IL.UTF-8"
        "th_TH.UTF-8"
        "id_ID.UTF-8"
        "uk_UA.UTF-8"
        "ro_RO.UTF-8"
    )

    local locale_selection=""
    locale_selection=$(printf '%s\n' "${locales[@]}" | gum filter --placeholder "Search locale..." --height 12) || true

    if [[ -n "$locale_selection" ]]; then
        CONFIG[locale]="$locale_selection"
        show_success "System locale: $locale_selection"
    fi

    echo ""

    show_info "Select your keyboard layout"
    echo ""

    local keyboards=(
        "us"
        "uk"
        "de"
        "fr"
        "es"
        "it"
        "pt-latin9"
        "br-abnt2"
        "ru"
        "pl"
        "cz"
        "hu"
        "se"
        "no"
        "dk"
        "fi"
        "nl"
        "be"
        "ch"
        "at"
        "jp106"
        "kr"
        "ara"
        "tr"
        "gr"
        "il"
        "latam"
        "dvorak"
        "colemak"
    )

    local kb_selection=""
    kb_selection=$(printf '%s\n' "${keyboards[@]}" | gum filter --placeholder "Search keyboard layout..." --height 12) || true

    if [[ -n "$kb_selection" ]]; then
        CONFIG[keyboard]="$kb_selection"
        loadkeys "$kb_selection" 2>/dev/null || true
        show_success "Keyboard layout: $kb_selection"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 3. DISK CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

# ────────────────────────────────────────────────────────────────────────────────
# 3a. PARTITIONING MODE SELECTION
# ────────────────────────────────────────────────────────────────────────────────

select_partitioning_mode() {
    show_header
    show_submenu_header "💾 Disk Configuration"
    echo ""

    local mode_options=(
        "Auto    │ Wipe entire disk and partition automatically (Recommended)"
        "Manual  │ Choose existing partitions (dual-boot, custom layouts)"
    )

    local mode_sel=""
    mode_sel=$(printf '%s\n' "${mode_options[@]}" | gum choose --height 4 \
        --header "Select partitioning mode:") || true

    if [[ "$mode_sel" == "Manual"* ]]; then
        CONFIG[partition_mode]="manual"
        manual_partitioning
    else
        CONFIG[partition_mode]="auto"
        select_disk
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# 3b. MANUAL PARTITIONING
# ────────────────────────────────────────────────────────────────────────────────

manual_partitioning() {
    show_header
    show_submenu_header "💾 Manual Partitioning"
    echo ""

    gum style --foreground 226 --bold --margin "0 2" \
        "ℹ️  Your partitions will not be wiped — only the ones you assign will be formatted."
    echo ""

    # Show current layout
    gum style --foreground 245 --margin "0 2" \
        "$(lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINT 2>/dev/null)"
    echo ""

    # Optionally launch cfdisk so the user can create partitions first
    if confirm_action "Launch cfdisk to create or modify partitions first?"; then
        local disks=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && disks+=("$line")
        done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null \
            | { grep -E '^/dev/(sd|nvme|vd|mmcblk)' || true; } | sed 's/  */ /g')

        if [[ ${#disks[@]} -gt 0 ]]; then
            local disk_sel=""
            disk_sel=$(printf '%s\n' "${disks[@]}" | gum choose --height 10 \
                --header "Select disk to open in cfdisk:") || true
            if [[ -n "$disk_sel" ]]; then
                local target_disk
                target_disk=$(echo "$disk_sel" | awk '{print $1}')
                cfdisk "$target_disk" || true
                partprobe "$target_disk" || true
                udevadm settle
            fi
        fi

        # Refresh view after cfdisk
        show_header
        show_submenu_header "💾 Manual Partitioning"
        echo ""
        gum style --foreground 245 --margin "0 2" "Updated disk layout:"
        echo ""
        gum style --foreground 245 --margin "0 2" \
            "$(lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINT 2>/dev/null)"
        echo ""
    fi

    # Build list of all available partitions
    local partitions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && partitions+=("$line")
    done < <(lsblk -lpno NAME,SIZE,FSTYPE,LABEL 2>/dev/null \
        | { grep -E '^/dev/(sd|nvme|vd|mmcblk)[^ ]*[0-9]' || true; } \
        | sed 's/  */ /g')

    if [[ ${#partitions[@]} -eq 0 ]]; then
        show_error "No partitions found. Create partitions first and try again."
        gum input --placeholder "Press Enter to continue..." --width 50
        return
    fi

    # ── Boot / EFI partition ──────────────────────────────────────────────────
    echo ""
    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        show_info "Select EFI System Partition (ESP)"
    else
        show_info "Select boot partition  (or skip to keep /boot on the root partition)"
    fi
    echo ""

    local boot_options=("-- Skip (no separate boot partition) --")
    for p in "${partitions[@]}"; do boot_options+=("$p"); done

    local boot_sel=""
    boot_sel=$(printf '%s\n' "${boot_options[@]}" | gum choose --height 14 \
        --header "Boot / EFI partition:") || true

    if [[ "$boot_sel" == "-- Skip"* ]]; then
        CONFIG[boot_part]=""
        CONFIG[reuse_efi]="no"
        show_info "No separate boot partition — /boot will live on the root partition"
    else
        CONFIG[boot_part]=$(echo "$boot_sel" | awk '{print $1}')
        show_success "Boot/EFI partition: ${CONFIG[boot_part]}"

        if [[ "${CONFIG[uefi]}" == "yes" ]]; then
            echo ""
            gum style --foreground 226 --bold --margin "0 2" \
                "Dual-boot tip: If this ESP already contains Windows boot files, choose 'Reuse'." \
                "Choosing 'Format' will wipe the ESP and break the Windows boot entry."
            echo ""

            local efi_action=""
            efi_action=$(printf '%s\n' \
                "Format  │ Wipe and format as FAT32  (single-OS or new ESP)" \
                "Reuse   │ Mount without formatting   (Windows dual-boot)" \
                | gum choose --height 4 --header "What to do with this EFI partition:") || true

            if [[ "$efi_action" == "Reuse"* ]]; then
                CONFIG[reuse_efi]="yes"
                show_success "EFI partition will be reused — dual-boot safe"
            else
                CONFIG[reuse_efi]="no"
                show_success "EFI partition will be formatted as FAT32"
            fi
        fi
    fi

    # ── Root partition ────────────────────────────────────────────────────────
    echo ""
    show_info "Select root partition"
    echo ""

    local root_sel=""
    root_sel=$(printf '%s\n' "${partitions[@]}" | gum choose --height 14 \
        --header "Root ( / ) partition:") || true

    if [[ -z "$root_sel" ]]; then
        show_error "No root partition selected."
        gum input --placeholder "Press Enter to continue..." --width 50
        return
    fi

    CONFIG[root_part]=$(echo "$root_sel" | awk '{print $1}')
    show_success "Root partition: ${CONFIG[root_part]}"

    # Derive parent disk for the bootloader install
    local parent_disk
    parent_disk=$(lsblk -no PKNAME "${CONFIG[root_part]}" 2>/dev/null | head -1)
    if [[ -n "$parent_disk" ]]; then
        CONFIG[disk]="/dev/$parent_disk"
    else
        CONFIG[disk]="${CONFIG[root_part]}"
    fi

    # ── Filesystem ───────────────────────────────────────────────────────────
    echo ""
    show_info "Select filesystem for root partition"
    echo ""

    local filesystems=(
        "btrfs    │ Modern CoW filesystem with snapshots (Recommended)"
        "ext4     │ Traditional reliable filesystem"
        "xfs      │ High-performance filesystem"
    )

    local fs_selection=""
    fs_selection=$(printf '%s\n' "${filesystems[@]}" | gum choose --height 5 \
        --header "Filesystem:") || true

    if [[ -z "$fs_selection" ]]; then
        show_error "No filesystem selected."
        gum input --placeholder "Press Enter to continue..." --width 50
        return
    fi

    CONFIG[filesystem]=$(echo "$fs_selection" | awk '{print $1}')
    show_success "Filesystem: ${CONFIG[filesystem]}"

    # ── Encryption ───────────────────────────────────────────────────────────
    echo ""
    show_info "Root Partition Encryption (LUKS2)"
    echo ""

    if confirm_action "Enable encryption on the root partition?" "no"; then
        CONFIG[encrypt]="yes"
        CONFIG[encrypt_boot]="no"   # manual mode: root-only encryption only

        echo ""
        local enc_pass1="" enc_pass2=""
        enc_pass1=$(gum input --password --placeholder "Enter encryption password" --width 50) || true
        enc_pass2=$(gum input --password --placeholder "Confirm encryption password" --width 50) || true

        if [[ "$enc_pass1" == "$enc_pass2" && -n "$enc_pass1" ]]; then
            CONFIG[encrypt_password]="$enc_pass1"
            show_success "Root encryption enabled"
        else
            show_error "Passwords don't match or empty. Encryption disabled."
            CONFIG[encrypt]="no"
            CONFIG[encrypt_password]=""
        fi
    else
        CONFIG[encrypt]="no"
        CONFIG[encrypt_boot]="no"
        CONFIG[encrypt_password]=""
        show_info "Encryption disabled"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 3c. AUTO DISK SELECTION (original select_disk)
# ────────────────────────────────────────────────────────────────────────────────

select_disk() {
    show_header
    show_submenu_header "💾 Disk Configuration"
    echo ""

    gum style --foreground 196 --bold --margin "0 2" \
        "⚠️  WARNING: The selected disk will be COMPLETELY ERASED!"
    echo ""

    show_info "Select the target disk for installation"
    echo ""

    local disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disks+=("$line")
    done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | { grep -E '^/dev/(sd|nvme|vd|mmcblk)' || true; } | sed 's/  */ /g')

    if [[ ${#disks[@]} -eq 0 ]]; then
        show_error "No suitable disks found!"
        gum input --placeholder "Press Enter to exit..." --width 50
        exit 1
    fi

    local disk_selection=""
    disk_selection=$(printf '%s\n' "${disks[@]}" | gum choose --height 10 --header "Available disks:") || true

    if [[ -n "$disk_selection" ]]; then
        CONFIG[disk]=$(echo "$disk_selection" | awk '{print $1}')
        show_success "Selected disk: ${CONFIG[disk]}"

        echo ""
        gum style --foreground 245 --margin "0 2" \
            "$(lsblk "${CONFIG[disk]}" 2>/dev/null)"
    fi

    echo ""

    show_info "Select filesystem type"
    echo ""

    local filesystems=(
        "btrfs    │ Modern CoW filesystem with snapshots (Recommended)"
        "ext4     │ Traditional reliable filesystem"
        "xfs      │ High-performance filesystem"
    )

    local fs_selection=""
    fs_selection=$(printf '%s\n' "${filesystems[@]}" | gum choose --height 5 --header "Filesystem:") || true

    if [[ -n "$fs_selection" ]]; then
        CONFIG[filesystem]=$(echo "$fs_selection" | awk '{print $1}')
        show_success "Filesystem: ${CONFIG[filesystem]}"
    fi

    echo ""

    show_info "Disk Encryption (LUKS2)"
    echo ""

    if confirm_action "Enable full disk encryption?" "no"; then
        CONFIG[encrypt]="yes"

        echo ""
        local enc_pass1="" enc_pass2=""
        enc_pass1=$(gum input --password --placeholder "Enter encryption password" --width 50) || true
        enc_pass2=$(gum input --password --placeholder "Confirm encryption password" --width 50) || true

        if [[ "$enc_pass1" == "$enc_pass2" && -n "$enc_pass1" ]]; then
            CONFIG[encrypt_password]="$enc_pass1"
            show_success "Disk encryption enabled"

            # No separate boot-encryption scope: Limine boots kernels from
            # an unencrypted ESP at /boot in every layout, so there is only
            # ever one LUKS password, asked by the initramfs — never by the
            # bootloader. CONFIG[encrypt_boot] stays "no".
        else
            show_error "Passwords don't match or empty. Encryption disabled."
            CONFIG[encrypt]="no"
            CONFIG[encrypt_boot]="no"
            CONFIG[encrypt_password]=""
        fi
    else
        CONFIG[encrypt]="no"
        CONFIG[encrypt_boot]="no"
        CONFIG[encrypt_password]=""
        show_info "Disk encryption disabled"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 4. SWAP CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────────

configure_swap() {
    show_header
    show_submenu_header "🔄 Swap Configuration"
    echo ""

    show_info "Select swap type for your system"
    echo ""

    local swap_options=(
        "zram     │ Compressed RAM swap (Recommended, fast)"
        "file     │ Traditional swap file on disk"
        "none     │ No swap (not recommended)"
    )

    local swap_selection=""
    swap_selection=$(printf '%s\n' "${swap_options[@]}" | gum choose --height 5 --header "Swap type:") || true

    if [[ -n "$swap_selection" ]]; then
        CONFIG[swap]=$(echo "$swap_selection" | awk '{print $1}')
        show_success "Swap type: ${CONFIG[swap]}"

        if [[ "${CONFIG[swap]}" == "zram" ]]; then
            echo ""
            show_info "Select zram compression algorithm"
            echo ""

            local algos=(
                "zstd     │ Best compression ratio (Recommended)"
                "lz4      │ Fastest compression"
                "lzo      │ Balanced speed/ratio"
            )

            local algo_selection=""
            algo_selection=$(printf '%s\n' "${algos[@]}" | gum choose --height 5 --header "Algorithm:") || true

            if [[ -n "$algo_selection" ]]; then
                CONFIG[swap_algo]=$(echo "$algo_selection" | awk '{print $1}')
                show_success "Compression: ${CONFIG[swap_algo]}"
            fi
        fi
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 5. HOSTNAME
# ────────────────────────────────────────────────────────────────────────────────

configure_hostname() {
    show_header
    show_submenu_header "💻 Hostname"
    echo ""

    show_info "Enter a hostname for your system"
    show_info "(lowercase letters, numbers, and hyphens only)"
    echo ""

    local hostname=""
    hostname=$(gum input --placeholder "xerolinux" --value "${CONFIG[hostname]}" --width 40 --header "Hostname:") || true

    if [[ "$hostname" =~ ^[a-z][a-z0-9-]*$ && ${#hostname} -le 63 ]]; then
        CONFIG[hostname]="$hostname"
        show_success "Hostname: ${CONFIG[hostname]}"
    else
        show_warning "Invalid hostname, using default: xerolinux"
        CONFIG[hostname]="xerolinux"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 6. GRAPHICS DRIVER
# ────────────────────────────────────────────────────────────────────────────────

select_graphics_driver() {
    show_header
    show_submenu_header "🎮 Graphics Driver"
    echo ""

    local is_vm="no"
    if systemd-detect-virt -q 2>/dev/null; then
        is_vm="yes"
        gum style --foreground 82 --margin "0 2" "🔍 Virtual Machine detected."
        echo ""
    fi

    show_info "Select the graphics driver configuration for your system"
    echo ""

    # If VM, put "vm" first (better UX)
    local drivers=()
    if [[ "$is_vm" == "yes" ]]; then
        drivers+=("vm                   │ Virtual Machine")
    fi
    drivers+=(
        "intel                │ Intel Graphics"
        "amd                  │ AMD Graphics"
        "nvidia-turing        │ NVIDIA Turing+ (RTX 20/30/40, GTX 1650+)"
        "nvidia-legacy        │ NVIDIA Legacy (GTX 900/1000 series)"
        "intel-amd            │ Intel + AMD (Hybrid)"
        "intel-nvidia-turing  │ Intel + NVIDIA Turing+ (Optimus)"
        "intel-nvidia-legacy  │ Intel + NVIDIA Legacy (Optimus)"
        "amd-nvidia-turing    │ AMD + NVIDIA Turing+ (Hybrid)"
        "amd-nvidia-legacy    │ AMD + NVIDIA Legacy (Hybrid)"
    )
    if [[ "$is_vm" != "yes" ]]; then
        drivers+=("vm                   │ Virtual Machine")
    fi

    local driver_selection=""
    driver_selection=$(printf '%s\n' "${drivers[@]}" | gum choose --height 12 --header "Graphics driver:") || true

    if [[ -n "$driver_selection" ]]; then
        CONFIG[gfx_driver]=$(echo "$driver_selection" | awk '{print $1}')
        show_success "Graphics driver: ${CONFIG[gfx_driver]}"

        echo ""
        case "${CONFIG[gfx_driver]}" in
            "intel")
                gum style --foreground 245 --margin "0 2" "Packages: intel-drv"
                ;;
            "amd")
                gum style --foreground 245 --margin "0 2" "Packages: amd-drv"
                ;;
            "nvidia-turing")
                gum style --foreground 245 --margin "0 2" "Packages: nvidia-open-dkms nvidia-utils + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "nvidia-legacy")
                gum style --foreground 245 --margin "0 2" "Packages: nvidia-580xx-dkms nvidia-580xx-utils + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "intel-amd")
                gum style --foreground 245 --margin "0 2" "Packages: intel-drv + amd-drv"
                ;;
            "intel-nvidia-turing")
                gum style --foreground 245 --margin "0 2" "Packages: intel-drv + nvidia-open-dkms + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "intel-nvidia-legacy")
                gum style --foreground 245 --margin "0 2" "Packages: intel-drv + nvidia-580xx-dkms + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "amd-nvidia-turing")
                gum style --foreground 245 --margin "0 2" "Packages: amd-drv + nvidia-open-dkms + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "amd-nvidia-legacy")
                gum style --foreground 245 --margin "0 2" "Packages: amd-drv + nvidia-580xx-dkms + extras"
                gum style --foreground 214 --margin "0 2" "⚠ Will configure: mkinitcpio modules + Limine kernel parameters"
                ;;
            "vm")
                gum style --foreground 245 --margin "0 2" "Packages: Foss"
                ;;
        esac
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 7. AUTHENTICATION (Users & Root)
# ────────────────────────────────────────────────────────────────────────────────

configure_authentication() {
    show_header
    show_submenu_header "👤 User Account Setup"
    echo ""

    show_info "Create your user account"
    echo ""

    local username=""
    username=$(gum input --placeholder "username" --width 40 --header "Username (lowercase):") || true

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ || ${#username} -gt 32 || -z "$username" ]]; then
        show_warning "Invalid username. Using 'user'"
        username="user"
    fi
    CONFIG[username]="$username"
    show_success "Username: ${CONFIG[username]}"

    echo ""

    local user_pass1="" user_pass2=""
    user_pass1=$(gum input --password --placeholder "Password for $username" --width 50) || true
    user_pass2=$(gum input --password --placeholder "Confirm password" --width 50) || true

    if [[ "$user_pass1" == "$user_pass2" && ${#user_pass1} -ge 1 ]]; then
        CONFIG[user_password]="$user_pass1"
        show_success "User password set"
    else
        show_error "Passwords don't match. Please reconfigure."
        sleep 1
        configure_authentication
        return
    fi

    echo ""
    show_submenu_header "🔐 Root Password"
    echo ""

    if confirm_action "Use same password for root?"; then
        CONFIG[root_password]="${CONFIG[user_password]}"
        show_success "Root password set (same as user)"
    else
        local root_pass1="" root_pass2=""
        root_pass1=$(gum input --password --placeholder "Root password" --width 50) || true
        root_pass2=$(gum input --password --placeholder "Confirm root password" --width 50) || true

        if [[ "$root_pass1" == "$root_pass2" && -n "$root_pass1" ]]; then
            CONFIG[root_password]="$root_pass1"
            show_success "Root password set"
        else
            show_warning "Passwords don't match. Using user password for root."
            CONFIG[root_password]="${CONFIG[user_password]}"
        fi
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 8. TIMEZONE
# ────────────────────────────────────────────────────────────────────────────────

select_timezone() {
    show_header
    show_submenu_header "🕐 Timezone"
    echo ""

    show_info "Select your timezone"
    echo ""

    local regions=""
    regions=$(find /usr/share/zoneinfo -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | \
              grep -vE '^(\+|posix|right|zoneinfo)$' | sort) || true

    local region=""
    region=$(echo "$regions" | gum filter --placeholder "Search region..." --height 12 --header "Select region:") || true

    if [[ -n "$region" ]]; then
        local cities=""
        cities=$(find "/usr/share/zoneinfo/$region" -type f -printf '%f\n' 2>/dev/null | sort) || true

        if [[ -n "$cities" ]]; then
            echo ""
            local city=""
            city=$(echo "$cities" | gum filter --placeholder "Search city..." --height 12 --header "Select city:") || true

            if [[ -n "$city" ]]; then
                CONFIG[timezone]="$region/$city"
            else
                CONFIG[timezone]="$region"
            fi
        else
            CONFIG[timezone]="$region"
        fi

        show_success "Timezone: ${CONFIG[timezone]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 9. PARALLEL DOWNLOADS
# ────────────────────────────────────────────────────────────────────────────────

configure_parallel_downloads() {
    show_header
    show_submenu_header "⚡ Parallel Downloads"
    echo ""

    show_info "Set number of parallel package downloads (speeds up installation)"
    echo ""

    local options=(
        "3      │ Conservative (slow connections)"
        "5      │ Default (recommended)"
        "10     │ Fast (good connections)"
        "15     │ Maximum (excellent connections)"
    )

    local selection=""
    selection=$(printf '%s\n' "${options[@]}" | gum choose --height 6 --header "Parallel downloads:") || true

    if [[ -n "$selection" ]]; then
        CONFIG[parallel_downloads]=$(echo "$selection" | awk '{print $1}')
        show_success "Parallel downloads: ${CONFIG[parallel_downloads]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 10. AUR HELPER
# ────────────────────────────────────────────────────────────────────────────────

select_aur_helper() {
    show_header
    show_submenu_header "📦 AUR Helper"
    echo ""
    show_info "Select the AUR helper to install with the base system"
    echo ""

    local helpers=(
        "paru   │ Rust-based, feature-rich (Recommended)"
        "yay    │ Go-based, popular choice"
    )

    local selection=""
    selection=$(printf '%s\n' "${helpers[@]}" | gum choose --height 4 --header "AUR Helper:") || true

    if [[ -n "$selection" ]]; then
        CONFIG[aur_helper]=$(echo "$selection" | awk '{print $1}')
        show_success "AUR helper: ${CONFIG[aur_helper]}"
    fi

    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# 11. ADDITIONAL KERNEL
# ────────────────────────────────────────────────────────────────────────────────

select_extra_kernel() {
    show_header
    show_submenu_header "🐧 Additional Kernel"
    echo ""

    gum style --foreground 220 --bold --border normal --border-foreground 220 \
        --align left --margin "0 2" --padding "0 1" \
        "These kernels install ALONGSIDE the default linux kernel." \
        "Do NOT select too many — each takes ~100 MB on the boot partition."
    echo ""

    local options=(
        "None"
        "linux-cachyos   │ CachyOS optimized kernel  (Chaotic-AUR)"
        "linux-lts       │ Long Term Support kernel   (official repos)"
    )

    local selections=""
    selections=$(printf '%s\n' "${options[@]}" | gum choose --no-limit \
        --header "Additional kernels (Space to toggle, Enter to confirm):") || true

    CONFIG[extra_kernel]=""
    if [[ -z "$selections" ]] || echo "$selections" | grep -q "^None$"; then
        show_success "No additional kernel selected"
        sleep 0.5
        return
    fi

    while IFS= read -r line; do
        case "$line" in
            "linux-cachyos"*) CONFIG[extra_kernel]+="linux-cachyos linux-cachyos-headers " ;;
            "linux-lts"*)     CONFIG[extra_kernel]+="linux-lts linux-lts-headers " ;;
        esac
    done <<< "$selections"

    CONFIG[extra_kernel]="${CONFIG[extra_kernel]% }"
    show_success "Extra kernels queued: ${CONFIG[extra_kernel]}"
    sleep 0.5
}

# ────────────────────────────────────────────────────────────────────────────────
# DESKTOP (simpbar: Hyprland or MangoWM + bar, widgets, configs, helpers)
# ────────────────────────────────────────────────────────────────────────────────
# install.sh's Steps 2/4/6 ported to phase 1: the window-manager question,
# the file-manager/terminal picks that feed keybinds + default pins, and
# the actual build/deploy later in install_simpbar_desktop (which runs in
# the install order after the user exists). Browser/Discord/games/LazyVim
# stay post-reboot choices — install.sh's own defaults skip them too, and
# the Welcome app covers them on first login.

select_desktop() {
    show_header
    show_submenu_header "🖥️ Desktop Environment"
    echo ""

    local options=(
        "none      │ Base system only (no desktop — run install.sh after reboot)"
        "hyprland  │ Hyprland + simpbar bar, widgets, configs and helpers"
        "mango     │ MangoWM + simpbar bar, widgets, configs and helpers"
    )

    local selection=""
    selection=$(printf '%s\n' "${options[@]}" | gum choose --height 5 --header "Desktop:") || true

    case "$selection" in
        "hyprland"*)
            CONFIG[desktop]="hyprland"
            show_success "Desktop: Hyprland + simpbar"
            ;;
        "mango"*)
            CONFIG[desktop]="mango"
            show_success "Desktop: MangoWM + simpbar"
            ;;
        *)
            CONFIG[desktop]="none"
            show_success "Desktop: none (base system only)"
            sleep 0.5
            return
            ;;
    esac
    echo ""

    # File manager: feeds the SUPER+E bind and the Files pin. Same default
    # (Nautilus) as install.sh.
    local fm_options=(
        "nautilus  │ Nautilus (GNOME Files)"
        "nemo      │ Nemo"
        "dolphin   │ Dolphin"
    )
    local fm_sel=""
    fm_sel=$(printf '%s\n' "${fm_options[@]}" | gum choose --height 5 --header "File manager:") || true
    case "$fm_sel" in
        "nemo"*)    CONFIG[file_manager]="nemo" ;;
        "dolphin"*) CONFIG[file_manager]="dolphin" ;;
        *)          CONFIG[file_manager]="nautilus" ;;
    esac
    show_success "File manager: ${CONFIG[file_manager]}"
    echo ""

    # Terminal: feeds SUPER+Return, the keybind viewer, and the Term pin.
    # Same default (Alacritty) as install.sh.
    local term_options=(
        "kitty     │ Kitty"
        "foot      │ Foot"
        "ghostty   │ Ghostty"
        "alacritty │ Alacritty"
        "wezterm   │ WezTerm"
        "konsole   │ Konsole"
        "ptyxis    │ Ptyxis"
    )
    local term_sel=""
    term_sel=$(printf '%s\n' "${term_options[@]}" | gum choose --height 9 --header "Terminal:") || true
    # CLASS is the Wayland app-id the Hyprland float rule matches; misses
    # only skip the float rule, the terminal itself always launches.
    case "$term_sel" in
        "kitty"*)     CONFIG[terminal_bin]="kitty";     CONFIG[terminal_class]="kitty";               CONFIG[terminal_e]="" ;;
        "foot"*)      CONFIG[terminal_bin]="foot";      CONFIG[terminal_class]="foot";                CONFIG[terminal_e]="-e" ;;
        "ghostty"*)   CONFIG[terminal_bin]="ghostty";   CONFIG[terminal_class]="ghostty";             CONFIG[terminal_e]="-e" ;;
        "wezterm"*)   CONFIG[terminal_bin]="wezterm";   CONFIG[terminal_class]="wezterm";             CONFIG[terminal_e]="-e" ;;
        "konsole"*)   CONFIG[terminal_bin]="konsole";   CONFIG[terminal_class]="org.kde.konsole";     CONFIG[terminal_e]="-e" ;;
        "ptyxis"*)    CONFIG[terminal_bin]="ptyxis";    CONFIG[terminal_class]="app.ptyxis.Terminal"; CONFIG[terminal_e]="-e" ;;
        *)            CONFIG[terminal_bin]="alacritty"; CONFIG[terminal_class]="Alacritty";           CONFIG[terminal_e]="-e" ;;
    esac
    show_success "Terminal: ${CONFIG[terminal_bin]}"
    sleep 0.5
}

# One-line summary label for menus and the install summary.
desktop_label() {
    case "${CONFIG[desktop]}" in
        hyprland) echo "Hyprland + simpbar" ;;
        mango)    echo "MangoWM + simpbar" ;;
        *)        echo "none (base only)" ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────────
# EXTRA PACKAGES (desktop-phase optional apps, picked up front like every
# other setting instead of deferring to a desktop phase — the actual `pacman -S` calls
# for these happen later, in install_user_packages, once the desktop phase
# is running as the target user with a real chroot pacman database; nothing
# here queries package existence, it only records the choice)
# ────────────────────────────────────────────────────────────────────────────────

LO_LANG_MENU=(
    "Use system locale|SYSTEM|"
    "English (US)|en_US|hunspell-en_us"
    "English (GB)|en_GB|hunspell-en_gb"
    "English (AU)|en_AU|hunspell-en_au"
    "English (CA)|en_CA|hunspell-en_ca"
    "German|de_DE|hunspell-de"
    "Greek|el_GR|hunspell-el"
    "French|fr_FR|hunspell-fr"
    "Hebrew|he_IL|hunspell-he"
    "Hungarian|hu_HU|hunspell-hu"
    "Italian|it_IT|hunspell-it"
    "Dutch|nl_NL|hunspell-nl"
    "Polish|pl_PL|hunspell-pl"
    "Romanian|ro_RO|hunspell-ro"
    "Russian|ru_RU|hunspell-ru"
    "Spanish (generic)|es|hunspell-es_any"
    "Spanish (Argentina)|es_AR|hunspell-es_ar"
    "Spanish (Bolivia)|es_BO|hunspell-es_bo"
    "Spanish (Chile)|es_CL|hunspell-es_cl"
    "Spanish (Colombia)|es_CO|hunspell-es_co"
    "Spanish (Costa Rica)|es_CR|hunspell-es_cr"
    "Spanish (Cuba)|es_CU|hunspell-es_cu"
    "Spanish (Dominican Republic)|es_DO|hunspell-es_do"
    "Spanish (Ecuador)|es_EC|hunspell-es_ec"
    "Spanish (Spain)|es_ES|hunspell-es_es"
    "Spanish (Guatemala)|es_GT|hunspell-es_gt"
    "Spanish (Honduras)|es_HN|hunspell-es_hn"
    "Spanish (Mexico)|es_MX|hunspell-es_mx"
    "Spanish (Nicaragua)|es_NI|hunspell-es_ni"
    "Spanish (Panama)|es_PA|hunspell-es_pa"
    "Spanish (Peru)|es_PE|hunspell-es_pe"
    "Spanish (Puerto Rico)|es_PR|hunspell-es_pr"
    "Spanish (Paraguay)|es_PY|hunspell-es_py"
    "Spanish (El Salvador)|es_SV|hunspell-es_sv"
    "Spanish (Uruguay)|es_UY|hunspell-es_uy"
    "Spanish (Venezuela)|es_VE|hunspell-es_ve"
    "Custom (enter locale code)|CUSTOM|"
)

configure_extra_packages() {
    show_header
    show_submenu_header "📦 Extra Packages"
    echo ""
    show_info "To select hit x, to save hit Enter key."
    echo ""

    # Label -> package lookup, scoped per category below.
    declare -A PKG_MAP=(
        ["Floorp"]="floorp" ["Firefox"]="firefox" ["Brave"]="brave-bin"
        ["LibreWolf"]="librewolf" ["Vivaldi"]="vivaldi-meta" ["Tor Browser"]="tor-browser-bin"
        ["Mullvad Browser"]="mullvad-browser-bin" ["Ungoogled Chromium"]="ungoogled-chromium-bin"
        ["FileZilla"]="filezilla" ["Helium Browser"]="helium-browser-bin" ["Zen Browser"]="zen-browser-bin"
        ["ZapZap (WhatsApp)"]="zapzap" ["Discord"]="discord" ["Vesktop"]="vesktop"
        ["Telegram"]="telegram-desktop" ["Ferdium (All-in-one)"]="ferdium-bin"
        ["Hugo"]="hugo" ["Meld (diff viewer)"]="meld" ["VSCodium"]="vscodium" ["GitHub Desktop"]="github-desktop"
        ["KeePassXC"]="keepassxc" ["Bitwarden"]="bitwarden" ["pass"]="pass"
        ["GIMP"]="gimp" ["Krita"]="krita" ["Inkscape"]="inkscape"
        ["MPV"]="mpv" ["Amarok"]="amarok" ["Spotify"]="spotify"
        ["Tenacity"]="tenacity" ["JamesDSP"]="jamesdsp"
        # EasyEffects ships with its full plugin set (same set the Welcome
        # app installs): the app alone is useless without effects to load.
        # Multi-word values flow through fine — every downstream user
        # word-splits (picker echo, wc -w counts, install loop).
        ["EasyEffects"]="easyeffects calf lsp-plugins-lv2 mda.lv2 x42-plugins-lv2 zam-plugins-lv2"
        ["MakeMKV"]="makemkv" ["Kdenlive"]="kdenlive" ["Avidemux"]="avidemux-qt" ["MKVToolNix"]="mkvtoolnix-gui"
        ["Steam"]="steam" ["Lutris"]="lutris" ["Heroic"]="heroic-games-launcher-bin"
    )

    # Checkbox picker for one category; echoes chosen package names. Header
    # goes through gum's own --header, not a plain echo above it — gum
    # choose repaints its draw region on start and would wipe that.
    pick_category() {
        local color="$1" label="$2"; shift 2
        local sel line out=""
        sel=$(printf '%s\n' "$@" | gum choose --no-limit --height 12 \
            --header="-- ${label} --" --header.foreground "$color" \
            --selected-prefix "[x] " --unselected-prefix "[ ] " \
            --selected.foreground "198") || true
        while IFS= read -r line; do
            [[ -n "$line" ]] && out="$out ${PKG_MAP[$line]-}"
        done <<< "$sel"
        echo ""
        echo "$out"
    }

    local browser social dev pass imaging music video gaming wants_lo=""

    browser=$(pick_category 6 "WEB BROWSERS" \
        "Floorp" "Firefox" "Brave" "LibreWolf" "Vivaldi" "Tor Browser" \
        "Mullvad Browser" "Ungoogled Chromium" "FileZilla" "Helium Browser" "Zen Browser")

    social=$(pick_category 2 "SOCIAL & COMMUNICATION" \
        "ZapZap (WhatsApp)" "Discord" "Vesktop" "Telegram" "Ferdium (All-in-one)")

    dev=$(pick_category 5 "DEVELOPMENT TOOLS" \
        "Hugo" "Meld (diff viewer)" "VSCodium" "GitHub Desktop")

    pass=$(pick_category 3 "PASSWORD MANAGERS" \
        "KeePassXC" "Bitwarden" "pass")

    imaging=$(pick_category 4 "CREATIVE & IMAGING" \
        "GIMP" "Krita" "Inkscape")

    music=$(pick_category 1 "MUSIC & AUDIO" \
        "MPV" "Amarok" "Spotify" "Tenacity" "JamesDSP" "EasyEffects")

    video=$(pick_category 2 "VIDEO EDITING" \
        "MakeMKV" "Kdenlive" "Avidemux" "MKVToolNix")

    gaming=$(pick_category 2 "GAMING" \
        "Steam" "Lutris" "Heroic")

    local office_sel=""
    office_sel=$(printf '%s\n' "LibreOffice" | gum choose --no-limit --height 3 \
        --header="-- OFFICE --" --header.foreground 6 \
        --selected-prefix "[x] " --unselected-prefix "[ ] " \
        --selected.foreground "198") || true
    echo ""
    [[ "$office_sel" == "LibreOffice" ]] && wants_lo="yes"

    CONFIG[extra_browser]="$(echo $browser)"
    CONFIG[extra_social]="$(echo $social)"
    CONFIG[extra_dev]="$(echo $dev)"
    CONFIG[extra_pass]="$(echo $pass)"
    CONFIG[extra_imaging]="$(echo $imaging)"
    CONFIG[extra_music]="$(echo $music)"
    CONFIG[extra_video]="$(echo $video)"
    CONFIG[extra_gaming]="$(echo $gaming)"
    CONFIG[wants_libreoffice]="${wants_lo:-no}"
    CONFIG[lo_locale]=""
    CONFIG[lo_hunspell]=""

    if [[ "${CONFIG[wants_libreoffice]}" == "yes" ]]; then
        echo ""
        show_info "LibreOffice selected — choose your language (UI + spellcheck):"
        echo ""

        local i idx label loc sys_loc
        for i in "${!LO_LANG_MENU[@]}"; do
            idx=$((i + 1))
            IFS='|' read -r label loc _ <<< "${LO_LANG_MENU[$i]}"
            if [[ "$loc" == "SYSTEM" ]]; then
                sys_loc="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tr -d '"')"
                sys_loc="${sys_loc:-en_US}"
                echo -e "  ${BLUE}${idx})${NC} ${label} (${sys_loc})"
            elif [[ "$loc" == "CUSTOM" ]]; then
                echo -e "  ${BLUE}${idx})${NC} ${label}"
            else
                echo -e "  ${BLUE}${idx})${NC} ${label} (${loc})"
            fi
        done
        echo ""

        local lang_choice=""
        read -r -p "Enter choice (default: English US): " lang_choice < /dev/tty
        [[ -z "$lang_choice" ]] && lang_choice=2
        if ! [[ "$lang_choice" =~ ^[0-9]+$ ]] || (( lang_choice < 1 || lang_choice > ${#LO_LANG_MENU[@]} )); then
            lang_choice=2
        fi

        local hunspell_selected=""
        IFS='|' read -r _ loc hunspell_selected <<< "${LO_LANG_MENU[$((lang_choice - 1))]}"

        if [[ "$loc" == "SYSTEM" ]]; then
            loc="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tr -d '"')"
            loc="${loc:-en_US}"
        elif [[ "$loc" == "CUSTOM" ]]; then
            read -r -p "Enter locale code (examples: en_US, en_GB, fr_FR, es_MX, ru_RU, zh_CN): " loc < /dev/tty
            loc="${loc:-en_US}"
            hunspell_selected=""
        fi

        CONFIG[lo_locale]="$loc"
        CONFIG[lo_hunspell]="$hunspell_selected"
    fi

    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Selection Summary:${NC}"
    [[ -n "${CONFIG[extra_browser]}" ]]  && echo -e "  Browsers:    ${CYAN}${CONFIG[extra_browser]}${NC}"
    [[ -n "${CONFIG[extra_social]}" ]]   && echo -e "  Social:      ${CYAN}${CONFIG[extra_social]}${NC}"
    [[ -n "${CONFIG[extra_dev]}" ]]      && echo -e "  Dev Tools:   ${CYAN}${CONFIG[extra_dev]}${NC}"
    [[ -n "${CONFIG[extra_pass]}" ]]     && echo -e "  Passwords:   ${CYAN}${CONFIG[extra_pass]}${NC}"
    [[ -n "${CONFIG[extra_imaging]}" ]]  && echo -e "  Creative:    ${CYAN}${CONFIG[extra_imaging]}${NC}"
    [[ -n "${CONFIG[extra_music]}" ]]    && echo -e "  Music/Audio: ${CYAN}${CONFIG[extra_music]}${NC}"
    [[ -n "${CONFIG[extra_video]}" ]]    && echo -e "  Video:       ${CYAN}${CONFIG[extra_video]}${NC}"
    [[ -n "${CONFIG[extra_gaming]}" ]]   && echo -e "  Gaming:      ${CYAN}${CONFIG[extra_gaming]}${NC}"
    [[ "${CONFIG[wants_libreoffice]}" == "yes" ]] && echo -e "  LibreOffice: ${CYAN}yes (${CONFIG[lo_locale]})${NC}"
    if [[ -z "${CONFIG[extra_browser]}${CONFIG[extra_social]}${CONFIG[extra_dev]}${CONFIG[extra_pass]}${CONFIG[extra_imaging]}${CONFIG[extra_music]}${CONFIG[extra_video]}${CONFIG[extra_gaming]}" && "${CONFIG[wants_libreoffice]}" != "yes" ]]; then
        echo -e "  ${YELLOW}(no extra packages selected)${NC}"
    fi
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    gum input --placeholder "Press Enter to continue..." --width 50
}

# ────────────────────────────────────────────────────────────────────────────────
# PACMAN HELPERS
# ────────────────────────────────────────────────────────────────────────────────

apply_parallel_downloads() {
    local conf="$1"
    local count="${CONFIG[parallel_downloads]}"
    if grep -q '^#*ParallelDownloads' "$conf"; then
        sed -i "s/^#*ParallelDownloads.*/ParallelDownloads = $count/" "$conf"
    else
        sed -i '/^\[options\]/a ParallelDownloads = '"$count" "$conf"
    fi
}

configure_pacman_options() {
    local conf="$1"
    local simple_opts=(Color ILoveCandy VerbosePkgLists DisableDownloadTimeout)

    for opt in "${simple_opts[@]}"; do
        if grep -q "^#\s*${opt}" "$conf"; then
            sed -i "s/^#\s*${opt}.*/${opt}/" "$conf"
        elif ! grep -q "^${opt}" "$conf"; then
            sed -i '/^\[options\]/a '"${opt}" "$conf"
        fi
    done

    if grep -q '^#*DownloadUser' "$conf"; then
        sed -i 's/^#*DownloadUser.*/DownloadUser = alpm/' "$conf"
    elif ! grep -q '^DownloadUser' "$conf"; then
        sed -i '/^\[options\]/a DownloadUser = alpm' "$conf"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ────────────────────────────────────────────────────────────────────────────────

show_main_menu() {
    while true; do
        clear
        local cols; cols=$(term_cols)
        local box_width=$(( cols - 4 ))
        [[ $box_width -lt 40 ]] && box_width=40

        # Vertically center the WHOLE screen (header + boot mode line +
        # the choose list) as one block, instead of centering the header
        # alone and leaving everything below it pinned under it — header
        # (border 2 + padding 2 + 5 text lines = 9) + boot-mode line (1)
        # + blank (1) + the choose widget's fixed --height 20 = 31.
        print_vpad "$(vpad_for 31)"

        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width "$box_width" --margin "0 2" --padding "1 2" \
            "✨ $SCRIPT_NAME v$VERSION ✨" \
            "" \
            "Installs a base Arch system (optional simpbar desktop: Hyprland/MangoWM)," \
            "with more configuration options than the ISO installer." \
            "For experienced Arch/Linux users. NOT beginner-friendly."

        local boot_mode="BIOS"
        [[ "${CONFIG[uefi]}" == "yes" ]] && boot_mode="UEFI"

        gum style --foreground 245 --align center --width "$cols" \
            "Boot Mode: $boot_mode"
        echo ""

        # Build disk info line for menu display
        local disk_info=""
        if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
            if [[ -n "${CONFIG[root_part]}" ]]; then
                disk_info="Manual: root=${CONFIG[root_part]}"
                [[ -n "${CONFIG[boot_part]}" ]] && disk_info+=" boot=${CONFIG[boot_part]}"
                disk_info+=" (${CONFIG[filesystem]}"
                [[ "${CONFIG[encrypt]}" == "yes" ]] && disk_info+=", encrypted"
                disk_info+=")"
            else
                disk_info="Manual: Not configured"
            fi
        else
            disk_info="${CONFIG[disk]:-Not configured}"
            if [[ -n "${CONFIG[disk]}" ]]; then
                disk_info+=" (${CONFIG[filesystem]}"
                if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
                    disk_info+=", encrypted root"
                fi
                disk_info+=")"
            fi
        fi

        local kernel_label="None"
        if [[ "${CONFIG[extra_kernel]}" == *"linux-cachyos"* && "${CONFIG[extra_kernel]}" == *"linux-lts"* ]]; then
            kernel_label="CachyOS + LTS"
        elif [[ "${CONFIG[extra_kernel]}" == *"linux-cachyos"* ]]; then
            kernel_label="CachyOS"
        elif [[ "${CONFIG[extra_kernel]}" == *"linux-lts"* ]]; then
            kernel_label="LTS"
        fi

        local extra_pkg_count=0
        for _grp in extra_browser extra_social extra_dev extra_pass extra_imaging extra_music extra_video extra_gaming; do
            [[ -n "${CONFIG[$_grp]}" ]] && (( extra_pkg_count += $(wc -w <<< "${CONFIG[$_grp]}") ))
        done
        [[ "${CONFIG[wants_libreoffice]}" == "yes" ]] && (( extra_pkg_count++ ))
        local extra_pkg_label="None"
        [[ $extra_pkg_count -gt 0 ]] && extra_pkg_label="$extra_pkg_count selected"

        local desktop_item_label
        desktop_item_label=$(desktop_label)

        local menu_items=(
            ""
            "1.  Installer Language    │ ${CONFIG[installer_lang]}"
            "2.  Locales               │ ${CONFIG[locale]} / ${CONFIG[keyboard]}"
            "3.  Disk Configuration    │ $disk_info"
            "4.  Swap                  │ ${CONFIG[swap]}"
            "5.  Hostname              │ ${CONFIG[hostname]}"
            "6.  Graphics Driver       │ ${CONFIG[gfx_driver]}"
            "7.  Authentication        │ ${CONFIG[username]:-Not configured}"
            "8.  Timezone              │ ${CONFIG[timezone]}"
            "9.  Parallel Downloads    │ ${CONFIG[parallel_downloads]}"
            "10. AUR Helper            │ ${CONFIG[aur_helper]}"
            "11. Additional Kernel     │ $kernel_label"
            "12. Extra Packages        │ $extra_pkg_label"
            "13. Desktop               │ $desktop_item_label"
            "──────────────────────────────────────────────"
            "14. Start Installation"
            "0.  Exit"
        )

        # gum choose has no alignment/centering flag, but --padding wraps
        # the WHOLE widget (header, every item, footer help text) in a
        # uniform box — unlike padding each item's own text, this also
        # doesn't get stripped off the highlighted cursor line the way
        # manual leading-space padding does (a genuine gum quirk: the
        # cursor line's own leading whitespace gets trimmed, so a manually
        # left-padded item snaps back to column 0 the moment it's
        # selected; verified empirically).
        local max_len=0 item
        for item in "${menu_items[@]}"; do
            [[ ${#item} -gt $max_len ]] && max_len=${#item}
        done
        local block_pad=$(( ($(term_cols) - max_len) / 2 ))
        [[ $block_pad -lt 0 ]] && block_pad=0

        local selection=""
        selection=$(printf '%s\n' "${menu_items[@]}" | gum choose --height 20 \
            --padding "0 $block_pad" --header "Configure your installation:"$'\n') || true

        case "$selection" in
            "1."*)  select_installer_language ;;
            "2."*)  select_locales ;;
            "3."*)  select_partitioning_mode ;;
            "4."*)  configure_swap ;;
            "5."*)  configure_hostname ;;
            "6."*)  select_graphics_driver ;;
            "7."*)  configure_authentication ;;
            "8."*)  select_timezone ;;
            "9."*)  configure_parallel_downloads ;;
            "10."*) select_aur_helper ;;
            "11."*) select_extra_kernel ;;
            "12."*) configure_extra_packages ;;
            "13."*) select_desktop ;;
            "14."*)
                if validate_config; then
                    show_summary
                    local confirm_msg=""
                    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
                        confirm_msg="Start installation? ${CONFIG[root_part]} will be formatted as root"
                    else
                        confirm_msg="Start installation? THIS WILL ERASE ${CONFIG[disk]}"
                    fi
                    if confirm_action "$confirm_msg"; then
                        perform_installation
                        break
                    fi
                fi
                ;;
            "0."*)
                if confirm_action "Exit installer?"; then
                    echo "Installation cancelled."
                    exit 0
                fi
                ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ────────────────────────────────────────────────────────────────────────────────

validate_config() {
    local errors=()

    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
        [[ -z "${CONFIG[root_part]}" ]] && errors+=("Root partition not configured (Manual mode)")
        [[ -n "${CONFIG[root_part]}" && ! -b "${CONFIG[root_part]}" ]] && \
            errors+=("Root partition '${CONFIG[root_part]}' is not a valid block device")
        [[ -n "${CONFIG[boot_part]}" && ! -b "${CONFIG[boot_part]}" ]] && \
            errors+=("Boot partition '${CONFIG[boot_part]}' is not a valid block device")
    else
        [[ -z "${CONFIG[disk]}" ]] && errors+=("Disk not configured")
    fi

    [[ -z "${CONFIG[username]}" ]] && errors+=("User account not configured")
    [[ -z "${CONFIG[user_password]}" ]] && errors+=("User password not set")
    [[ -z "${CONFIG[root_password]}" ]] && errors+=("Root password not set")

    if [[ ${#errors[@]} -gt 0 ]]; then
        show_header
        gum style --foreground 196 --bold --margin "1 2" \
            "❌ Configuration Incomplete"
        echo ""
        for error in "${errors[@]}"; do
            show_error "$error"
        done
        echo ""
        gum input --placeholder "Press Enter to continue..." --width 50
        return 1
    fi

    return 0
}

# ────────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ────────────────────────────────────────────────────────────────────────────────

show_summary() {
    show_header
    show_submenu_header "📋 Installation Summary"
    echo ""

    local encrypt_status="No"
    if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
        encrypt_status="Yes (LUKS2, root only)"
    fi

    local boot_mode="BIOS/Legacy"
    [[ "${CONFIG[uefi]}" == "yes" ]] && boot_mode="UEFI"

    local extra_pkg_summary="None"
    local _epc=0 _grp
    for _grp in extra_browser extra_social extra_dev extra_pass extra_imaging extra_music extra_video extra_gaming; do
        [[ -n "${CONFIG[$_grp]}" ]] && (( _epc += $(wc -w <<< "${CONFIG[$_grp]}") ))
    done
    [[ "${CONFIG[wants_libreoffice]}" == "yes" ]] && (( _epc++ ))
    [[ $_epc -gt 0 ]] && extra_pkg_summary="$_epc selected"

    local desktop_summary
    desktop_summary=$(desktop_label)
    if [[ "${CONFIG[desktop]}" != "none" ]]; then
        desktop_summary+=" (${CONFIG[file_manager]} / ${CONFIG[terminal_bin]})"
    fi

    if [[ "${CONFIG[partition_mode]}" == "manual" ]]; then
        local efi_note=""
        [[ "${CONFIG[reuse_efi]}" == "yes" ]] && efi_note=" (reused, not formatted)"
        local boot_line="None (boot on root)"
        [[ -n "${CONFIG[boot_part]}" ]] && boot_line="${CONFIG[boot_part]}$efi_note"

        gum style --border rounded --border-foreground 212 --padding "1 2" --margin "0 2" \
            "Locale:           ${CONFIG[locale]}" \
            "Keyboard:         ${CONFIG[keyboard]}" \
            "Timezone:         ${CONFIG[timezone]}" \
            "Hostname:         ${CONFIG[hostname]}" \
            "" \
            "Username:         ${CONFIG[username]}" \
            "" \
            "Partition mode:   Manual" \
            "Root partition:   ${CONFIG[root_part]}" \
            "Boot partition:   $boot_line" \
            "Filesystem:       ${CONFIG[filesystem]}" \
            "Encryption:       $encrypt_status" \
            "Swap:             ${CONFIG[swap]}" \
            "" \
            "Desktop:          $desktop_summary" \
            "AUR Helper:       ${CONFIG[aur_helper]}" \
            "Graphics:         ${CONFIG[gfx_driver]}" \
            "Boot Mode:        $boot_mode" \
            "Bootloader:       Limine (on ${CONFIG[disk]})" \
            "Downloads:        ${CONFIG[parallel_downloads]} parallel" \
            "Extra Packages:   $extra_pkg_summary"

        echo ""
        gum style --foreground 196 --bold --margin "0 2" \
            "⚠️  ${CONFIG[root_part]} will be FORMATTED as the root partition!"
        [[ "${CONFIG[reuse_efi]}" != "yes" && -n "${CONFIG[boot_part]}" ]] && \
            gum style --foreground 196 --bold --margin "0 2" \
                "⚠️  ${CONFIG[boot_part]} will be FORMATTED as the boot/EFI partition!"
    else
        gum style --border rounded --border-foreground 212 --padding "1 2" --margin "0 2" \
            "Locale:           ${CONFIG[locale]}" \
            "Keyboard:         ${CONFIG[keyboard]}" \
            "Timezone:         ${CONFIG[timezone]}" \
            "Hostname:         ${CONFIG[hostname]}" \
            "" \
            "Username:         ${CONFIG[username]}" \
            "" \
            "Partition mode:   Auto (whole disk)" \
            "Target Disk:      ${CONFIG[disk]}" \
            "Filesystem:       ${CONFIG[filesystem]}" \
            "Encryption:       $encrypt_status" \
            "Swap:             ${CONFIG[swap]}" \
            "" \
            "Desktop:          $desktop_summary" \
            "AUR Helper:       ${CONFIG[aur_helper]}" \
            "Graphics:         ${CONFIG[gfx_driver]}" \
            "Boot Mode:        $boot_mode" \
            "Bootloader:       Limine" \
            "Downloads:        ${CONFIG[parallel_downloads]} parallel" \
            "Extra Packages:   $extra_pkg_summary"

        echo ""
        gum style --foreground 196 --bold --margin "0 2" \
            "⚠️  ALL DATA ON ${CONFIG[disk]} WILL BE PERMANENTLY ERASED!"
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# INSTALLATION
# ────────────────────────────────────────────────────────────────────────────────

install_extra_kernels() {
    # shellcheck disable=SC2086
    arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm ${CONFIG[extra_kernel]} \
        || echo "Some extra kernel packages failed — continuing"
    # No grub-mkconfig: limine.conf entries are static paths (written by
    # install_bootloader below) that stay valid across kernel upgrades,
    # and limine-snapper-sync keeps snapshot entries current.
}

# Extra software picked in the main menu (browsers, social, dev, office,
# ...). Upstream installed these in the post-reboot Part 2; with no Part 2
# they go in here via the target's own pacman. Repo packages install
# directly; AUR-only names are collected into ~/AUR-EXTRAS.txt with the
# exact install command (AUR helpers refuse to run as root, so building
# them inside the install chroot is not an option). Nothing here aborts
# the install — every package is best-effort with a warning.
install_extra_software() {
    local pkgs="${CONFIG[extra_browser]} ${CONFIG[extra_social]} ${CONFIG[extra_dev]}"
    pkgs+=" ${CONFIG[extra_pass]} ${CONFIG[extra_imaging]} ${CONFIG[extra_music]} ${CONFIG[extra_video]} ${CONFIG[extra_gaming]}"
    local aur_left=""
    local p
    # shellcheck disable=SC2086
    for p in $pkgs; do
        [[ -z "$p" ]] && continue
        if arch-chroot "$MOUNTPOINT" pacman -Si "$p" >/dev/null 2>&1; then
            arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "$p" \
                || show_warning "Extra package $p failed — continuing"
        else
            aur_left+=" $p"
        fi
    done
    if [[ "${CONFIG[wants_libreoffice]}" == "yes" ]]; then
        arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm libreoffice-fresh \
            || show_warning "libreoffice-fresh failed — continuing"
        # UI language pack is best-effort: derive the short code from the
        # menu's locale (de_DE -> de) and try it; spellcheck below is exact.
        local loc="${CONFIG[lo_locale]}"
        if [[ "$loc" == "SYSTEM" ]]; then
            loc="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tr -d '\"')"
            loc="${loc:-en_US}"
        fi
        local short=""
        short="$(echo "$loc" | tr '[:upper:]' '[:lower:]' | cut -d_ -f1)"
        if [[ -n "$short" && "$short" != "en" && "$short" != "c" ]]; then
            arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "libreoffice-fresh-$short" \
                || show_warning "libreoffice-fresh-$short not found — UI stays English"
        fi
        if [[ -n "${CONFIG[lo_hunspell]}" ]]; then
            arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "${CONFIG[lo_hunspell]}" \
                || show_warning "${CONFIG[lo_hunspell]} failed — spellcheck may miss that language"
        fi
    fi
    aur_left="$(echo "$aur_left")"
    if [[ -n "$aur_left" ]]; then
        local user_home="$MOUNTPOINT/home/${CONFIG[username]}"
        echo "paru -S --needed$aur_left" > "$user_home/AUR-EXTRAS.txt"
        show_warning "AUR-only extras saved to ~/AUR-EXTRAS.txt — install after reboot"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# SIMPBAR DESKTOP (phase-1 port of install.sh Steps 2/4/6 + build/deploy)
# ────────────────────────────────────────────────────────────────────────────────
# Installs the chosen WM + desktop stack, builds the bar/shell/config/
# welcome from the simpbar repo, and deploys configs + helpers + pins into
# the new user's home — so first login via ly lands on a working desktop.
# Everything here targets $MOUNTPOINT (host-side file ops as ISO root,
# package/build calls via arch-chroot); NOTHING touches the live ISO.
#
# Failure policy: NEVER abort the provisioning run. This runs under
# `set -Eeuo pipefail` with a global ERR trap, so every fallible command
# carries `|| show_warning ...` — a missing theme package must not kill a
# 30-minute install. The function itself always returns 0; gaps are
# reported as warnings and remain fillable post-reboot via install.sh
# (whose reuse-detection degrades gracefully over what's already here).
# Browser/Discord/games/LazyVim are deliberately NOT installed here —
# install.sh's own defaults skip them too; they come post-reboot.
install_simpbar_desktop() {
    local tu="${CONFIG[username]}"
    local th="$MOUNTPOINT/home/$tu"
    [[ -d "$th" ]] || { show_warning "Home $th missing — skipping desktop install"; return 0; }

    local wm_label="Hyprland"
    [[ "${CONFIG[desktop]}" == "mango" ]] && wm_label="MangoWM"

    # ── 1. packages ──────────────────────────────────────────────────
    # install.sh's Step-6 set verbatim (bar build/runtime deps, portals
    # handled per-WM below, fonts, tools) + the pinned Mesa ICDs (same
    # steam-provider reasoning as install.sh) + matugen (official extra,
    # no AUR needed) + the WM/FM/terminal picks.
    local pkgs=(zig freetype2 gdk-pixbuf2 wayland wayland-protocols playerctl
        mate-polkit swaybg ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
        fastfetch neovim steam swaync rofi flatpak bazaar nwg-look pavucontrol
        cava pipewire pipewire-pulse wireplumber gnome-disk-utility
        polkit-gnome grim slurp cliphist wl-clipboard python-gobject gtk4
        libadwaita pacman-contrib libnotify nwg-drawer qt6ct breeze gawk
        kdeconnect quickshell brightnessctl mesa lib32-mesa vulkan-radeon
        lib32-vulkan-radeon vulkan-intel lib32-vulkan-intel vulkan-swrast
        lib32-vulkan-swrast matugen)
    if [[ "${CONFIG[desktop]}" == "mango" ]]; then
        # easyeffects rides with its full plugin set (same bundle as the
        # Extra Packages picker) — Mango autostarts it, so it must arrive
        # usable, not empty.
        pkgs+=(mangowm xdg-desktop-portal-wlr xdg-desktop-portal-gtk easyeffects calf lsp-plugins-lv2 mda.lv2 x42-plugins-lv2 zam-plugins-lv2)
    else
        pkgs+=(hyprland xdg-desktop-portal-hyprland)
    fi
    pkgs+=("${CONFIG[file_manager]}" "${CONFIG[terminal_bin]}")

    arch-chroot "$MOUNTPOINT" pacman -Sy >/dev/null 2>&1 \
        || show_warning "Database sync failed — package installs may fail below"
    # One bad package aborts a --noconfirm batch, so a batch failure
    # retries per package and only true failures are reported (same shape
    # as install.sh's install_repo_or_aur).
    if ! arch-chroot "$MOUNTPOINT" pacman -S --noconfirm --needed "${pkgs[@]}" >/dev/null 2>&1; then
        show_warning "Desktop batch install failed — retrying per package"
        local p
        for p in "${pkgs[@]}"; do
            arch-chroot "$MOUNTPOINT" pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 \
                || show_warning "Could not install $p — install post-reboot: sudo pacman -S $p"
        done
    fi

    # Theme/cursor packs: best-effort repo installs (chaotic-aur usually
    # carries them as binaries). Whatever misses stays a warning — the
    # desktop works without themes, and nothing here may use an AUR
    # helper (none is installed in the target yet). Dracula, Zafiro and
    # fish were deliberately dropped from this list (install failures /
    # unused), so they are not attempted at all.
    local theme_pkgs=(protonplus bibata-cursor-theme game-devices-udev)
    local tp
    for tp in "${theme_pkgs[@]}"; do
        arch-chroot "$MOUNTPOINT" pacman -S --noconfirm --needed "$tp" >/dev/null 2>&1 \
            || show_warning "Could not install $tp — theming falls back to defaults"
    done

    # ── 2. simpbar source (same main.zip install.sh fetches) ─────────
    local src_tmp=""
    src_tmp=$(mktemp -d) || { show_warning "mktemp failed — skipping desktop deploy"; return 0; }
    if ! curl -fL -o "$src_tmp/simpbar.zip" \
        https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip >/dev/null 2>&1; then
        show_warning "Could not download simpbar source — desktop deploy skipped"
        rm -rf "$src_tmp"
        return 0
    fi
    if ! unzip -o "$src_tmp/simpbar.zip" -d "$src_tmp" >/dev/null 2>&1; then
        show_warning "Could not extract simpbar source — desktop deploy skipped"
        rm -rf "$src_tmp"
        return 0
    fi
    local src="$src_tmp/simpbar-main"

    local cfg_dirs=()
    if [[ "${CONFIG[desktop]}" == "mango" ]]; then
        cfg_dirs=(mango swaync fastfetch matugen)
    else
        cfg_dirs=(hypr swaync fastfetch matugen)
    fi
    local d
    for d in "${cfg_dirs[@]}" simpbar simpbar-shell; do
        if [[ ! -d "$src/$d" ]]; then
            show_warning "Archive lacks $d/ — desktop deploy skipped (layout changed upstream?)"
            rm -rf "$src_tmp"
            return 0
        fi
    done

    mkdir -p "$th/.config" "$th/.local/share/simpbar" "$th/Pictures/Wallpaper" \
        "$th/Videos" "$th/Documents" "$th/Music" "$th/Projects" || true
    for d in "${cfg_dirs[@]}"; do
        rm -rf "$th/.config/$d"
        cp -r "$src/$d" "$th/.config/" || show_warning "Could not deploy $d config"
    done
    # matugen layout: templates live in templates/.
    if [[ -d "$th/.config/matugen" ]]; then
        mkdir -p "$th/.config/matugen/templates"
        for f in "$th/.config/matugen/"*.json "$th/.config/matugen/"*.css \
                 "$th/.config/matugen/"*.lua "$th/.config/matugen/"*.ini \
                 "$th/.config/matugen/"*.conf; do
            [[ -f "$f" ]] && mv -f "$f" "$th/.config/matugen/templates/" 2>/dev/null || true
        done
    fi
    # The shipped mango config keeps __HOME__ placeholders for the target
    # user's home; hyprland.lua hardcodes nautilus/foot — point both at the
    # picks from the desktop menu.
    if [[ "${CONFIG[desktop]}" == "mango" ]]; then
        sed -i "s|__HOME__|/home/$tu|g" "$th/.config/mango/config.conf" "$th/.config/mango/cfg/"*.conf 2>/dev/null \
            || show_warning "Mango home substitution failed"
        sed -i "s/bind = SUPER, e, spawn, dolphin/bind = SUPER, e, spawn, ${CONFIG[file_manager]}/" \
            "$th/.config/mango/cfg/keybinds.conf" 2>/dev/null || true
        sed -i "s/^bind = SUPER, Return, spawn, .*/bind = SUPER, Return, spawn, ${CONFIG[terminal_bin]}/" \
            "$th/.config/mango/cfg/keybinds.conf" 2>/dev/null || true
        if [[ -n "${CONFIG[terminal_e]}" ]]; then
            sed -i "s|spawn, .* less __HOME__/.config/mango/cfg/keybinds.conf|spawn, ${CONFIG[terminal_bin]} ${CONFIG[terminal_e]} less /home/$tu/.config/mango/cfg/keybinds.conf|" \
                "$th/.config/mango/cfg/keybinds.conf" 2>/dev/null || true
        else
            sed -i "s|spawn, .* less __HOME__/.config/mango/cfg/keybinds.conf|spawn, ${CONFIG[terminal_bin]} less /home/$tu/.config/mango/cfg/keybinds.conf|" \
                "$th/.config/mango/cfg/keybinds.conf" 2>/dev/null || true
        fi
    else
        if [[ -f "$th/.config/hypr/hyprland.lua" ]]; then
            sed -i "s/^local fileManager = \".*\"/local fileManager = \"${CONFIG[file_manager]}\"/" \
                "$th/.config/hypr/hyprland.lua" 2>/dev/null || true
            sed -i "s/^local terminal = \".*\"/local terminal = \"${CONFIG[terminal_bin]}\"/" \
                "$th/.config/hypr/hyprland.lua" 2>/dev/null || true
            sed -i "s/^\tname = \"foot\",/\tname = \"${CONFIG[terminal_class]}\",/" \
                "$th/.config/hypr/hyprland.lua" 2>/dev/null || true
            sed -i "s/match = { class = \"foot\" }/match = { class = \"${CONFIG[terminal_class]}\" }/" \
                "$th/.config/hypr/hyprland.lua" 2>/dev/null || true
        fi
    fi

    # Sources + single-file helpers staged beside them (the /tmp archive is
    # removed at the end of this step, so everything needed later is
    # copied out now — same staging install.sh does under ~/.local/share).
    rm -rf "$th/.local/share/simpbar/simpbar" "$th/.local/share/simpbar/simpbar-shell"
    cp -r "$src/simpbar" "$th/.local/share/simpbar/simpbar" \
        || show_warning "Could not stage simpbar source"
    cp -r "$src/simpbar-shell" "$th/.local/share/simpbar/simpbar-shell" \
        || show_warning "Could not stage simpbar-shell source"
    mkdir -p "$th/.local/share/simpbar/assets/icons"
    cp "$src/assets/icons/simpbar-config.svg" "$th/.local/share/simpbar/assets/icons/" 2>/dev/null \
        || show_warning "simpbar-config.svg missing (bar pin falls back to text)"
    # NOTE: the repo tracks the toggle script as `appdrawer` (no suffix);
    # install.sh stages it as appdrawer-bin. Mirror that mapping here.
    for f in simpbar-matugen simpbar-wallpaper simpbar-restore-wallpaper appdrawer appdrawer.desktop; do
        if [[ -f "$src/$f" ]]; then
            local dest="$f"
            [[ "$f" == "appdrawer" ]] && dest="appdrawer-bin"
            cp "$src/$f" "$th/.local/share/simpbar/$dest" 2>/dev/null \
                || show_warning "Could not stage $f"
        else
            show_warning "$f missing from archive (layout changed upstream?)"
        fi
    done
    unset dest

    # ── 3. build (in-chroot, ReleaseFast like install.sh) ────────────
    if [[ -f "$MOUNTPOINT/home/$tu/.local/share/simpbar/simpbar/build.zig" ]]; then
        arch-chroot "$MOUNTPOINT" bash -c "cd '/home/$tu/.local/share/simpbar/simpbar' && zig build -Doptimize=ReleaseFast" \
            >/dev/null 2>&1 \
            || show_warning "simpbar build failed — bar/config/welcome missing; rebuild post-reboot in ~/.local/share/simpbar/simpbar"
        arch-chroot "$MOUNTPOINT" bash -c "cd '/home/$tu/.local/share/simpbar/simpbar-shell' && zig build -Doptimize=ReleaseFast" \
            >/dev/null 2>&1 \
            || show_warning "simpbar-shell build failed — widgets missing; rebuild post-reboot in ~/.local/share/simpbar/simpbar-shell"
    else
        show_warning "Staged source has no build.zig — binaries skipped"
    fi
    local zb="$MOUNTPOINT/home/$tu/.local/share/simpbar"
    [[ -f "$zb/simpbar/zig-out/bin/simpbar" ]] \
        && install -Dm755 "$zb/simpbar/zig-out/bin/simpbar" "$MOUNTPOINT/usr/bin/simpbar" \
        || show_warning "simpbar binary missing — /usr/bin/simpbar not installed"
    [[ -f "$zb/simpbar-shell/zig-out/bin/simpbar-shell" ]] \
        && install -Dm755 "$zb/simpbar-shell/zig-out/bin/simpbar-shell" "$MOUNTPOINT/usr/bin/simpbar-shell" \
        || show_warning "simpbar-shell binary missing — widgets not installed"
    [[ -f "$zb/simpbar/zig-out/bin/simpbar-config" ]] \
        && install -Dm755 "$zb/simpbar/zig-out/bin/simpbar-config" "$MOUNTPOINT/usr/bin/simpbar-config" \
        || show_warning "simpbar-config binary missing"
    [[ -f "$zb/simpbar/zig-out/bin/simpbar-welcome" ]] \
        && install -Dm755 "$zb/simpbar/zig-out/bin/simpbar-welcome" "$MOUNTPOINT/usr/bin/simpbar-welcome" \
        || show_warning "simpbar-welcome binary missing"

    # ── 4. helpers + launchers (same contents as install.sh) ────────
    install -Dm755 "$th/.local/share/simpbar/simpbar-matugen" "$MOUNTPOINT/usr/bin/simpbar-matugen" 2>/dev/null \
        || show_warning "simpbar-matugen helper not installed"
    install -Dm755 "$th/.local/share/simpbar/simpbar-wallpaper" "$MOUNTPOINT/usr/bin/simpbar-wallpaper" 2>/dev/null \
        || show_warning "simpbar-wallpaper engine not installed"
    install -Dm755 "$th/.local/share/simpbar/simpbar-restore-wallpaper" "$MOUNTPOINT/usr/bin/simpbar-restore-wallpaper" 2>/dev/null \
        || show_warning "wallpaper restore helper not installed"
    install -Dm755 "$th/.local/share/simpbar/appdrawer-bin" "$MOUNTPOINT/usr/bin/appdrawer" 2>/dev/null \
        || show_warning "/usr/bin/appdrawer not installed"
    install -Dm644 "$th/.local/share/simpbar/appdrawer.desktop" "$MOUNTPOINT/usr/share/applications/appdrawer.desktop" 2>/dev/null \
        || show_warning "appdrawer.desktop not installed"
    install -Dm644 "$th/.local/share/simpbar/assets/icons/simpbar-config.svg" \
        "$MOUNTPOINT/usr/share/icons/hicolor/scalable/apps/simpbar-config.svg" 2>/dev/null \
        || show_warning "cog icon not installed (bar pin falls back to text)"

    cat > "$MOUNTPOINT/usr/bin/simpbar-launch-browser" << 'BROWSERWRAPEOF'
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
    chmod 755 "$MOUNTPOINT/usr/bin/simpbar-launch-browser" 2>/dev/null || true

    cat > "$MOUNTPOINT/usr/bin/simpbar-launch-discord" << 'DISCORDWRAPEOF'
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
    chmod 755 "$MOUNTPOINT/usr/bin/simpbar-launch-discord" 2>/dev/null || true

    mkdir -p "$th/.local/share/applications"
    cat > "$th/.local/share/applications/simpbar-welcome.desktop" << 'WELCOMEDESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Simpbar Welcome
Comment=Setup actions, keybindings, and links for the simpbar Hyprland setup
Exec=simpbar-welcome
Icon=help-about
Terminal=false
Categories=Settings;
StartupNotify=true
WELCOMEDESKTOPEOF
    cat > "$th/.local/share/applications/simpbar-config.desktop" << 'CONFIGDESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Simpbar Config
Comment=Configure simpbar's appearance, module layout, and desktop shortcuts
Exec=simpbar-config
Icon=simpbar-config
Terminal=false
Categories=Settings;
StartupNotify=true
CONFIGDESKTOPEOF

    # ── 5. app drawer QML ────────────────────────────────────────────
    if [[ -d "$th/.local/share/simpbar/appdrawer" ]]; then
        local qs_dir="$th/.config/quickshell/appdrawer"
        mkdir -p "$qs_dir"
        local qml
        for qml in AppModel.qml AppTile.qml Distro.qml Drawer.qml Icons.qml shell.qml Theme.qml WallpaperModel.qml WallpaperTile.qml WallhavenSearch.qml; do
            if [[ -f "$th/.local/share/simpbar/appdrawer/$qml" ]]; then
                cp "$th/.local/share/simpbar/appdrawer/$qml" "$qs_dir/$qml" 2>/dev/null || true
            else
                show_warning "appdrawer $qml missing — the drawer may not load"
            fi
        done
        [[ -f "$qs_dir/favourites.json" ]] || printf '{ "ids": [] }\n' > "$qs_dir/favourites.json"
    fi

    # ── 6. matugen config (always — auto-theming is core, not optional) ─
    if [[ -f "$src/matugen/config.toml" ]]; then
        mkdir -p "$th/.config/matugen/templates"
        [[ -e "$th/.config/matugen/config.toml" ]] \
            || cp "$src/matugen/config.toml" "$th/.config/matugen/config.toml" 2>/dev/null \
            || show_warning "matugen config.toml not deployed"
        if [[ -f "$src/matugen/simpbar.json" ]]; then
            [[ -e "$th/.config/matugen/templates/simpbar.json" ]] \
                || cp "$src/matugen/simpbar.json" "$th/.config/matugen/templates/simpbar.json" 2>/dev/null \
                || show_warning "matugen simpbar template not deployed"
        fi
    else
        show_warning "matugen/ missing from archive — theming config skipped"
    fi

    # ── 7. bar config + default pins ────────────────────────────────
    # Empty icons: the bar derives them at runtime via the desktop index,
    # so the picked file manager/terminal wear their own theme icons.
    # Steam only when it actually landed; browser/Discord pins come
    # post-reboot (neither is installed in phase 1).
    local pins='[{"label":"Files","command":"'"${CONFIG[file_manager]}"'","icon":""},'
    pins+='{"label":"Term","command":"'"${CONFIG[terminal_bin]}"'","icon":""},'
    if [[ -x "$MOUNTPOINT/usr/bin/steam" ]]; then
        pins+='{"label":"Steam","command":"steam","icon":""},'
    fi
    pins+='{"label":"Config","command":"simpbar-config","icon":"simpbar-config"},'
    pins+='{"label":"Welcome","command":"simpbar-welcome","icon":"help-about"}]'
    mkdir -p "$th/.config/simpbar"
    if [[ ! -f "$th/.config/simpbar/config.json" ]]; then
        printf '{"appearance":{"empty_click_command":"appdrawer"},"launchers":%s}\n' "$pins" \
            > "$th/.config/simpbar/config.json" \
            || show_warning "config.json not seeded"
    elif ! grep -q '"launchers"' "$th/.config/simpbar/config.json" 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$th/.config/simpbar/config.json" "$pins" << 'PYEOF' 2>/dev/null \
                || show_warning "pin seeding failed (bar falls back to built-in pins)"
import json, sys
path, frag = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
if "launchers" not in cfg:
    cfg["launchers"] = json.loads(frag)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PYEOF
        else
            show_warning "python3 unavailable — pin seeding skipped"
        fi
    fi
    if [[ ! -f "$th/.config/simpbar/reminders.txt" ]]; then
        cat > "$th/.config/simpbar/reminders.txt" << 'REMIN'
# Reminders — one per line: YYYY-MM-DD HH:MM lead text
#   lead = days before the date to notify (0 = on the day)
# Click a day on the calendar card to add/remove via rofi.
REMIN
    fi

    # ── 8. small user configs (rofi, qt6ct) ─────────────────────────
    mkdir -p "$th/.config/rofi"
    if [[ ! -e "$th/.config/rofi/config.rasi" ]]; then
        cat > "$th/.config/rofi/config.rasi" << 'EOF'
configuration {
    display-drun: "Apps";
    display-run: "Run";
    display-window: "Window";
    show-icons: true;
}

@theme "material"
EOF
    fi
    if [[ -f "$MOUNTPOINT/usr/share/color-schemes/BreezeDark.colors" ]]; then
        mkdir -p "$th/.config/qt6ct"
        if [[ ! -e "$th/.config/qt6ct/qt6ct.conf" ]]; then
            cat > "$th/.config/qt6ct/qt6ct.conf" << EOF
[Appearance]
style=Breeze
color_scheme_path=/usr/share/color-schemes/BreezeDark.colors
custom_palette=true
EOF
        fi
    fi

    # ── 9. user services WITHOUT a user manager ─────────────────────
    # systemctl --user needs a DBus session (absent in chroot), so enable by
    # symlink — exactly what `systemctl --user enable` would create. Each
    # link is guarded on its unit existing in the target.
    local u_dir="$th/.config/systemd/user"
    mkdir -p "$u_dir/sockets.target.wants" "$u_dir/pipewire.service.wants" \
        "$u_dir/timers.target.wants" "$u_dir/graphical-session.target.wants"
    [[ -f "$MOUNTPOINT/usr/lib/systemd/user/pipewire.socket" ]] \
        && ln -sf /usr/lib/systemd/user/pipewire.socket "$u_dir/sockets.target.wants/pipewire.socket"
    [[ -f "$MOUNTPOINT/usr/lib/systemd/user/pipewire-pulse.socket" ]] \
        && ln -sf /usr/lib/systemd/user/pipewire-pulse.socket "$u_dir/sockets.target.wants/pipewire-pulse.socket"
    if [[ -f "$MOUNTPOINT/usr/lib/systemd/user/wireplumber.service" ]]; then
        ln -sf /usr/lib/systemd/user/wireplumber.service "$u_dir/pipewire.service.wants/wireplumber.service"
        ln -sf /usr/lib/systemd/user/wireplumber.service "$u_dir/pipewire-session-manager.service"
    else
        show_warning "wireplumber.service missing — audio session mgmt needs manual enable"
    fi

    cat > "$u_dir/simpbar-update-checker.service" << 'CHECKERSVCEOF'
[Unit]
Description=Check for simpbar/Arch updates

[Service]
Type=oneshot
ExecStart=/usr/bin/simpbar-check-updates
CHECKERSVCEOF
    cat > "$u_dir/simpbar-update-checker.timer" << 'CHECKERTIMEREOF'
[Unit]
Description=Periodically check for simpbar/Arch updates

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
CHECKERTIMEREOF
    if arch-chroot "$MOUNTPOINT" pacman -Qq pacman-contrib libnotify >/dev/null 2>&1; then
        ln -sf "/home/$tu/.config/systemd/user/simpbar-update-checker.timer" \
            "$u_dir/timers.target.wants/simpbar-update-checker.timer"
    else
        show_warning "pacman-contrib/libnotify missing — update-checker timer left disabled"
    fi

    cat > "$u_dir/simpbar-welcome.service" << 'WELCOMESVCEOF'
[Unit]
Description=Simpbar Welcome (first-login popup)
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/simpbar-welcome --autostart

[Install]
WantedBy=graphical-session.target
WELCOMESVCEOF
    if arch-chroot "$MOUNTPOINT" pacman -Qq gtk4 libadwaita python-gobject >/dev/null 2>&1; then
        ln -sf "/home/$tu/.config/systemd/user/simpbar-welcome.service" \
            "$u_dir/graphical-session.target.wants/simpbar-welcome.service"
    else
        show_warning "GTK4/libadwaita/python-gobject missing — Welcome autostart left disabled"
    fi

    # ── 10. flathub + wallpaper (best-effort, never fatal) ──────────
    arch-chroot "$MOUNTPOINT" su -l "$tu" -c \
        'flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' \
        >/dev/null 2>&1 \
        || show_warning "Flathub remote not added — add post-reboot from the Welcome app"
    local bing_tmp=""
    bing_tmp=$(mktemp) || true
    if [[ -n "$bing_tmp" && -x "$src/simpbar-wallpaper" ]] \
        && bash "$src/simpbar-wallpaper" bing > "$bing_tmp" 2>/dev/null; then
        local bing_file=""
        bing_file=$(head -n1 "$bing_tmp")
        if [[ -n "$bing_file" && -f "$bing_file" ]]; then
            cp "$bing_file" "$th/Pictures/Wallpaper/" 2>/dev/null || true
            if [[ ! -r "$th/.config/simpbar/wallpaper" ]]; then
                printf 'path=%s\nfill=fill\ncolor=#ffffff\n' \
                    "$th/Pictures/Wallpaper/$(basename "$bing_file")" \
                    > "$th/.config/simpbar/wallpaper" 2>/dev/null || true
            fi
        fi
    else
        show_warning "No wallpaper fetched — pick one from the app drawer after login"
    fi
    [[ -n "$bing_tmp" ]] && rm -f "$bing_tmp"

    # ── 11. mango session sanity ────────────────────────────────────
    # ly lists /usr/share/wayland-sessions: hyprland's package ships its
    # entry, but if mangowm's doesn't (or the glob finds nothing mango),
    # ly would boot to a chooser with no Mango in it.
    if [[ "${CONFIG[desktop]}" == "mango" ]]; then
        if ! ls "$MOUNTPOINT/usr/share/wayland-sessions/" 2>/dev/null | grep -qi mango; then
            show_warning "No MangoWG session file in wayland-sessions — check 'ls /usr/share/wayland-sessions' after reboot; ly needs an entry to offer Mango"
        fi
    fi

    # ── 12. fastfetch on shell start ────────────────────────────────
    # useradd -m seeds .bashrc from /etc/skel; append once (grep-guarded
    # so re-runs never duplicate it). Guarded on the binary too — a
    # failed fastfetch install must not leave every shell printing errors.
    if [[ -f "$MOUNTPOINT/usr/bin/fastfetch" ]]; then
        touch "$th/.bashrc" 2>/dev/null || true
        if ! grep -q "command -v fastfetch" "$th/.bashrc" 2>/dev/null; then
            cat >> "$th/.bashrc" << 'BASHEOF' 2>/dev/null \
                || show_warning ".bashrc fastfetch hook not added"

# Featherlite: show system info on interactive shells.
command -v fastfetch >/dev/null 2>&1 && fastfetch
BASHEOF
        fi
    else
        show_warning "fastfetch missing — no shell-start hook added"
    fi

    # ── 13. drawer chain verification ───────────────────────────────
    # The drawer failing silently post-boot is always one of these four;
    # check them all here (read-only) and report exactly which link broke
    # instead of leaving it to guesswork after reboot.
    local drawer_ok=1
    if ! arch-chroot "$MOUNTPOINT" pacman -Qq quickshell >/dev/null 2>&1; then
        show_warning "DRAWER: quickshell not installed — install post-reboot: sudo pacman -S quickshell"
        drawer_ok=0
    fi
    if [[ ! -x "$MOUNTPOINT/usr/bin/appdrawer" ]]; then
        show_warning "DRAWER: /usr/bin/appdrawer missing — empty-clicks and SUPER+Space/SUPER+Tab do nothing"
        drawer_ok=0
    fi
    if [[ ! -f "$th/.config/quickshell/appdrawer/shell.qml" ]]; then
        show_warning "DRAWER: appdrawer QML not deployed to ~/.config/quickshell/appdrawer"
        drawer_ok=0
    fi
    if ! grep -q '"empty_click_command"' "$th/.config/simpbar/config.json" 2>/dev/null; then
        show_warning "DRAWER: empty_click_command not set — empty bar clicks do nothing"
        drawer_ok=0
    fi
    [[ "$drawer_ok" == "1" ]] || show_warning "App drawer chain incomplete — fix the DRAWER lines above post-reboot"

    rm -rf "$src_tmp"
    arch-chroot "$MOUNTPOINT" chown -R "$tu:$tu" "/home/$tu" 2>/dev/null \
        || show_warning "Could not chown home dir — check ownership after reboot"
    show_success "Simpbar desktop ($wm_label) installed — pick it in ly after reboot"
    return 0
}

perform_installation() {
    # Build the ordered step list dynamically based on config, so the
    # percent bar's total always matches what will actually run.
    local step_labels=() step_funcs=()

    step_labels+=("Partitioning disk");            step_funcs+=("partition_disk")
    if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
        step_labels+=("Setting up encryption");    step_funcs+=("setup_encryption")
    fi
    step_labels+=("Formatting partitions");         step_funcs+=("format_partitions")
    step_labels+=("Mounting filesystems");          step_funcs+=("mount_filesystems")
    step_labels+=("Installing base system");        step_funcs+=("install_base_system")
    step_labels+=("Adding repositories");           step_funcs+=("add_repos")
    if [[ -n "${CONFIG[extra_kernel]}" ]]; then
        step_labels+=("Installing additional kernels"); step_funcs+=("install_extra_kernels")
    fi
    # Extra software only gets a step when something was actually picked —
    # otherwise this would flash a no-op line in the progress bar.
    {
        local _has_extra=0 _grp
        for _grp in extra_browser extra_social extra_dev extra_pass extra_imaging extra_music extra_video extra_gaming; do
            [[ -n "${CONFIG[$_grp]}" ]] && _has_extra=1
        done
        [[ "${CONFIG[wants_libreoffice]}" == "yes" ]] && _has_extra=1
        if [[ "$_has_extra" == "1" ]]; then
            step_labels+=("Installing extra software"); step_funcs+=("install_extra_software")
        fi
    }
    step_labels+=("Configuring system");            step_funcs+=("configure_system")
    step_labels+=("Installing Limine bootloader");    step_funcs+=("install_bootloader")
    step_labels+=("Configuring Btrfs snapshots");   step_funcs+=("setup_snapper")
    step_labels+=("Creating user account");         step_funcs+=("create_user")
    # Desktop needs the user + home to exist (configs, builds, pins all
    # land in the new user's home), so it runs right after create_user.
    if [[ "${CONFIG[desktop]}" != "none" ]]; then
        local _wm_step="Hyprland"
        [[ "${CONFIG[desktop]}" == "mango" ]] && _wm_step="MangoWM"
        step_labels+=("Installing simpbar desktop ($_wm_step)"); step_funcs+=("install_simpbar_desktop")
    fi
    step_labels+=("Installing graphics drivers");   step_funcs+=("install_graphics")
    step_labels+=("Configuring swap");              step_funcs+=("setup_swap_system")

    local total=${#step_labels[@]}
    local i
    for i in "${!step_labels[@]}"; do
        run_step_visual "$((i + 1))" "$total" "${step_labels[$i]}" "${step_funcs[$i]}"
    done

    # No desktop phase here by design (there is no Part 2 in this fork):
    # the base system above is the whole job unless a desktop was chosen.
    # After rebooting, install.sh finishes whatever is left (browsers,
    # Discord, games — its reuse-detection skips everything phase 1
    # already did).
    show_header
    if [[ "${CONFIG[desktop]}" != "none" ]]; then
        local _wm_done="Hyprland"
        [[ "${CONFIG[desktop]}" == "mango" ]] && _wm_done="MangoWM"
        gum style --foreground 82 --bold --border double --border-foreground 82 \
            --align center --width 60 --margin "1 2" --padding "1 2" \
            "✨ Installation Complete! ✨" \
            "" \
            "Your simpbar desktop ($_wm_done) is installed." \
            "" \
            "Remove the installation media and reboot, then" \
            "pick $_wm_done in ly and log in." \
            "" \
            "For browsers, Discord and extras, run post-reboot:" \
            "  curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash"
    else
        gum style --foreground 82 --bold --border double --border-foreground 82 \
            --align center --width 60 --margin "1 2" --padding "1 2" \
            "✨ Base System Installed! ✨" \
            "" \
            "No desktop environment was installed — that is intentional." \
            "" \
            "Remove the installation media and reboot, then set up" \
            "the simpbar desktop:" \
            "  curl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash"
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# DISK OPERATIONS
# ────────────────────────────────────────────────────────────────────────────────

partition_disk() {
    # Manual mode: user already selected partitions — nothing to partition
    [[ "${CONFIG[partition_mode]}" == "manual" ]] && return 0

    local disk="${CONFIG[disk]}"

    # A prior run against this same disk (aborted, retried without reboot)
    # can leave its old partitions mounted under $MOUNTPOINT — the kernel
    # then refuses to re-read the partition table ("... unable to inform
    # the kernel of the change, probably because it/they are in use"),
    # failing `parted mklabel` outright. Clear that state before wiping.
    swapoff -a 2>/dev/null || true
    umount -R "$MOUNTPOINT" 2>/dev/null || true
    [[ -e /dev/mapper/cryptroot ]] && cryptsetup close cryptroot 2>/dev/null || true

    [[ -n "$disk" ]] || { echo "ERROR: CONFIG[disk] is empty"; return 1; }

    wipefs -af "$disk" 2>/dev/null || true
    sgdisk -Z "$disk" &>/dev/null || true

    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart ESP fat32 1MiB 2049MiB
        parted -s "$disk" set 1 esp on
        parted -s "$disk" mkpart primary 2049MiB 100%
    else
        # BIOS always gets a separate ext4 /boot: Limine reads kernels and
        # stages from a plain partition and cannot unlock an encrypted
        # /boot the way GRUB's cryptodisk did.
        parted -s "$disk" mklabel msdos
        parted -s "$disk" mkpart primary ext4 1MiB 2049MiB
        parted -s "$disk" set 1 boot on
        parted -s "$disk" mkpart primary 2049MiB 100%
    fi

    # Make sure kernel/udev creates partition nodes (common VM timing issue)
    partprobe "$disk" || true
    udevadm settle
    sleep 1

    if [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* ]]; then
        CONFIG[boot_part]="${disk}p1"
        CONFIG[root_part]="${disk}p2"
    else
        CONFIG[boot_part]="${disk}1"
        CONFIG[root_part]="${disk}2"
    fi

    # Validate partitions exist as block devices BEFORE formatting
    if [[ -n "${CONFIG[boot_part]}" && ! -b "${CONFIG[boot_part]}" ]]; then
        echo "ERROR: Boot partition not ready after partitioning."
        echo "  boot_part='${CONFIG[boot_part]}' block? no"
        lsblk -f "$disk" || true
        return 1
    fi
    if [[ ! -b "${CONFIG[root_part]}" ]]; then
        echo "ERROR: Root partition not ready after partitioning."
        echo "  root_part='${CONFIG[root_part]}' block? no"
        lsblk -f "$disk" || true
        return 1
    fi
}

setup_encryption() {
    [[ "${CONFIG[encrypt]}" == "yes" ]] || return 0

    [[ -n "${CONFIG[encrypt_password]}" ]] || { echo "ERROR: Encryption enabled but password is empty"; return 1; }
    [[ -b "${CONFIG[root_part]}" ]] || { echo "ERROR: root_part '${CONFIG[root_part]}' is not a block device"; return 1; }

    echo -n "${CONFIG[encrypt_password]}" | cryptsetup luksFormat --type luks2 "${CONFIG[root_part]}" - 2>/dev/null
    echo -n "${CONFIG[encrypt_password]}" | cryptsetup open "${CONFIG[root_part]}" cryptroot -

    CONFIG[root_device]="/dev/mapper/cryptroot"

    [[ -b "${CONFIG[root_device]}" ]] || { echo "ERROR: cryptroot mapper not created"; return 1; }
}

format_partitions() {
    local root_device="${CONFIG[root_part]}"
    [[ "${CONFIG[encrypt]}" == "yes" ]] && root_device="${CONFIG[root_device]}"

    [[ -b "$root_device" ]] || { echo "ERROR: root device '$root_device' is not a block device"; return 1; }

    # Format boot partition (skipped for BIOS encrypted boot or when reusing existing EFI)
    if [[ -n "${CONFIG[boot_part]}" ]]; then
        [[ -b "${CONFIG[boot_part]}" ]] || { echo "ERROR: boot_part '${CONFIG[boot_part]}' is not a block device"; return 1; }

        if [[ "${CONFIG[reuse_efi]}" == "yes" ]]; then
            echo "Reusing existing EFI partition ${CONFIG[boot_part]} — skipping format"
        elif [[ "${CONFIG[uefi]}" == "yes" ]]; then
            wipefs -af "${CONFIG[boot_part]}" &>/dev/null
            mkfs.fat -F32 "${CONFIG[boot_part]}"
        else
            wipefs -af "${CONFIG[boot_part]}" &>/dev/null
            mkfs.ext4 -F "${CONFIG[boot_part]}"
        fi
    fi

    wipefs -af "$root_device" &>/dev/null
    case "${CONFIG[filesystem]}" in
        btrfs) mkfs.btrfs -f "$root_device" ;;
        ext4)  mkfs.ext4 -F "$root_device" ;;
        xfs)   mkfs.xfs -f "$root_device" ;;
        *)     echo "ERROR: Unknown filesystem '${CONFIG[filesystem]}'"; return 1 ;;
    esac
}

mount_filesystems() {
    local root_device="${CONFIG[root_part]}"
    [[ "${CONFIG[encrypt]}" == "yes" ]] && root_device="${CONFIG[root_device]}"

    [[ -b "$root_device" ]] || { echo "ERROR: root device '$root_device' is not a block device"; return 1; }

    if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        mount "$root_device" "$MOUNTPOINT"
        btrfs subvolume create "$MOUNTPOINT/@"
        btrfs subvolume create "$MOUNTPOINT/@home"
        btrfs subvolume create "$MOUNTPOINT/@var"
        btrfs subvolume create "$MOUNTPOINT/@tmp"
        # @snapshots NOT created here — snapper creates /.snapshots as a nested
        # child subvolume of @ in setup_snapper(). A top-level sibling subvolume
        # breaks snapper's subvolume relationship check and prevents snapshot creation.
        umount "$MOUNTPOINT"

        mount -o noatime,compress=zstd,subvol=@ "$root_device" "$MOUNTPOINT"
        mkdir -p "$MOUNTPOINT"/{home,var,tmp,boot}
        mount -o noatime,compress=zstd,subvol=@home "$root_device" "$MOUNTPOINT/home"
        mount -o noatime,compress=zstd,subvol=@var "$root_device" "$MOUNTPOINT/var"
        mount -o noatime,compress=zstd,subvol=@tmp "$root_device" "$MOUNTPOINT/tmp"
    else
        mount "$root_device" "$MOUNTPOINT"
        mkdir -p "$MOUNTPOINT/boot"
    fi

    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        # Limine reads kernels straight off the ESP, so it IS /boot in
        # every UEFI layout (encrypted or not) — kernels stay unencrypted
        # and the initramfs alone handles LUKS unlock.
        mkdir -p "$MOUNTPOINT/boot"
        mount "${CONFIG[boot_part]}" "$MOUNTPOINT/boot"
    elif [[ -n "${CONFIG[boot_part]}" ]]; then
        # BIOS: separate ext4 boot partition holds kernels + Limine stages
        mount "${CONFIG[boot_part]}" "$MOUNTPOINT/boot"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# SYSTEM INSTALLATION
# ────────────────────────────────────────────────────────────────────────────────

# Import chaotic-aur key with fallback keyservers and retries
import_chaotic_key() {
    local keyid="3056513887B78AEB"
    local keyservers=(
        "keyserver.ubuntu.com"
        "keys.openpgp.org"
        "pgp.mit.edu"
    )
    local imported=0

    for ks in "${keyservers[@]}"; do
        if timeout 20 pacman-key --recv-key "$keyid" --keyserver "$ks" 2>/dev/null; then
            imported=1
            break
        fi
        show_warning "Keyserver $ks failed, trying next..."
    done

    if [[ $imported -eq 0 ]]; then
        show_warning "All keyservers failed — trying hkps fallback..."
        timeout 20 pacman-key --recv-key "$keyid" \
            --keyserver hkps://keyserver.ubuntu.com 2>/dev/null || true
    fi

    pacman-key --lsign-key "$keyid" || true
}

add_temp_repo() {
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' /etc/pacman.conf

    if ! grep -q "\[xerolinux\]" /etc/pacman.conf; then
        echo -e '\n[xerolinux]\nSigLevel = Optional TrustAll\nServer = https://repos.xerolinux.xyz/$repo/$arch' >> /etc/pacman.conf
    fi

    if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
        import_chaotic_key
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
            || show_warning "chaotic-keyring install failed — repo may not work fully"
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
            || show_warning "chaotic-mirrorlist install failed"
        # chaotic-aur is a bonus repo — a transient CDN outage on either
        # package above must not wire pacman.conf to a nonexistent Include
        # file, which would hard-fail every subsequent pacman call.
        if [[ -f /etc/pacman.d/chaotic-mirrorlist ]]; then
            echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
        else
            show_warning "chaotic-mirrorlist missing — skipping chaotic-aur repo for this install"
        fi
    fi

    apply_parallel_downloads /etc/pacman.conf
    configure_pacman_options /etc/pacman.conf
    pacman -Sy || show_warning "pacman -Sy had errors — continuing"
}

install_base_system() {
    add_temp_repo

    # ── Critical base (pacstrap aborts if these fail) ─────────────────────────
    local critical="base base-devel linux linux-headers mkinitcpio-fw linux-atm"

    # Microcode (auto-detect)
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        critical+=" intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        critical+=" amd-ucode"
    fi

    # Boot & filesystems
    critical+=" limine efibootmgr"
    critical+=" btrfs-progs dosfstools e2fsprogs xfsprogs gptfdisk"

    # Base utilities
    # Base utilities (ly rides here too: the TUI login manager that owns
    # tty1 after install — sessions come later from the desktop setup).
    critical+=" sudo nano vim git wget curl ly"

    # Network stack
    critical+=" networkmanager iw iwd ppp lftp ldns avahi samba netctl dhcpcd openssh"
    critical+=" openvpn dnsmasq dhclient openldap nss-mdns smbclient net-tools"
    critical+=" darkhttpd reflector pptpclient cloud-init openconnect traceroute"
    critical+=" b43-fwcutter nm-cloud-setup wireless-regdb wireless_tools wpa_supplicant"
    critical+=" modemmanager-qt openpgp-card-tools xl2tpd"

    # Bluetooth
    critical+=" bluez bluez-libs bluez-utils bluez-tools bluez-hid2hci"

    # Audio (PipeWire)
    critical+=" pipewire wireplumber pipewire-jack pipewire-support lib32-pipewire-jack"
    critical+=" alsa-utils alsa-plugins alsa-firmware pavucontrol-qt libdvdcss"

    # GStreamer
    critical+=" gstreamer gst-libav gst-plugins-bad gst-plugins-base gst-plugins-ugly"
    critical+=" gst-plugins-good gst-plugins-espeak gst-plugin-pipewire"

    # Printing & scanning
    critical+=" cups hplip print-manager scanner-support printer-support"

    # Xorg & input
    critical+=" xorg-apps xorg-xinit xorg-server xorg-xwayland"
    critical+=" libinput xf86-input-void xf86-input-libinput"

    # Install critical packages — abort on failure. --noconfirm is explicit
    # here (not just relying on pacstrap's own default) so nothing can ever
    # block waiting on stdin; stdbuf forces line-buffered output since
    # pacman fully-buffers once it detects stdout isn't a real terminal,
    # which otherwise made output arrive in large delayed chunks instead of
    # scrolling live in the progress display.
    # shellcheck disable=SC2086
    stdbuf -oL -eL pacstrap -K "$MOUNTPOINT" --noconfirm $critical

    # ── Optional packages (failures logged, install continues) ────────────────
    local optional=""

    # Extra input / accessibility
    optional+=" orca onboard xf86-input-evdev iio-sensor-proxy"
    optional+=" game-devices-udev xf86-input-vmmouse xf86-input-synaptics"
    optional+=" xf86-input-elographics"

    # Firmware (some may not apply to all hardware)
    optional+=" fwupd sof-firmware linux-firmware-intel"

    show_info "Installing optional base packages (failures non-fatal)..."
    # shellcheck disable=SC2086
    stdbuf -oL -eL pacstrap -K "$MOUNTPOINT" --noconfirm $optional 2>/dev/null || \
        show_warning "Some optional base packages failed — continuing"

    # Btrfs snapshot support — only when btrfs is selected
    if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        show_info "Installing Btrfs snapshot support..."
        # snap-pac omitted here — its pacman hooks would fire on every package install
        # during the chroot setup phase, creating unwanted snapshots before first login.
        # It gets installed by xero-snapper-init on first boot instead.
        stdbuf -oL -eL pacstrap -K "$MOUNTPOINT" --noconfirm snapper limine-snapper-sync 2>/dev/null || \
            show_warning "Some Btrfs snapshot packages failed — continuing"
    fi

    genfstab -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"
}

add_repos() {
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' "$MOUNTPOINT/etc/pacman.conf"

    if ! grep -q "\[xerolinux\]" "$MOUNTPOINT/etc/pacman.conf"; then
        echo -e '\n[xerolinux]\nSigLevel = Optional TrustAll\nServer = https://repos.xerolinux.xyz/$repo/$arch' >> "$MOUNTPOINT/etc/pacman.conf"
    fi

    if ! grep -q "\[chaotic-aur\]" "$MOUNTPOINT/etc/pacman.conf"; then
        local keyid="3056513887B78AEB"
        local keyservers=("keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu")
        local imported=0

        for ks in "${keyservers[@]}"; do
            if timeout 20 arch-chroot "$MOUNTPOINT" pacman-key --recv-key "$keyid" --keyserver "$ks" 2>/dev/null; then
                imported=1
                break
            fi
            show_warning "Keyserver $ks failed, trying next..."
        done

        [[ $imported -eq 0 ]] && \
            timeout 20 arch-chroot "$MOUNTPOINT" pacman-key --recv-key "$keyid" \
                --keyserver hkps://keyserver.ubuntu.com 2>/dev/null || true

        arch-chroot "$MOUNTPOINT" pacman-key --lsign-key "$keyid" || true

        arch-chroot "$MOUNTPOINT" pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
            || show_warning "chaotic-keyring install failed — repo may not work fully"

        arch-chroot "$MOUNTPOINT" pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
            || show_warning "chaotic-mirrorlist install failed"

        # chaotic-aur is a bonus repo, not required for the install to
        # succeed — a transient CDN outage on either package above (a real
        # 503 from cdn-mirror.chaotic.cx has been observed live) must not
        # wire pacman.conf to an Include file that doesn't exist, which
        # would hard-fail every subsequent `pacman -Sy`/-S for the rest of
        # the install over a repo nobody asked to depend on.
        if [[ -f "$MOUNTPOINT/etc/pacman.d/chaotic-mirrorlist" ]]; then
            echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> "$MOUNTPOINT/etc/pacman.conf"
        else
            show_warning "chaotic-mirrorlist missing — skipping chaotic-aur repo for this install"
        fi
    fi

    apply_parallel_downloads "$MOUNTPOINT/etc/pacman.conf"
    configure_pacman_options "$MOUNTPOINT/etc/pacman.conf"
    arch-chroot "$MOUNTPOINT" pacman -Sy || show_warning "pacman -Sy had errors — continuing"
}

configure_system() {
    arch-chroot "$MOUNTPOINT" ln -sf "/usr/share/zoneinfo/${CONFIG[timezone]}" /etc/localtime
    arch-chroot "$MOUNTPOINT" hwclock --systohc

    echo "${CONFIG[locale]} UTF-8" >> "$MOUNTPOINT/etc/locale.gen"
    echo "en_US.UTF-8 UTF-8" >> "$MOUNTPOINT/etc/locale.gen"
    arch-chroot "$MOUNTPOINT" locale-gen
    echo "LANG=${CONFIG[locale]}" > "$MOUNTPOINT/etc/locale.conf"

    echo "KEYMAP=${CONFIG[keyboard]}" > "$MOUNTPOINT/etc/vconsole.conf"

    # Map console keymap names to X11 layout names where they differ
    local xkb_layout="${CONFIG[keyboard]}"
    local xkb_variant=""
    case "${CONFIG[keyboard]}" in
        pt-latin9) xkb_layout="pt" ;;
        br-abnt2)  xkb_layout="br" ;;
        jp106)     xkb_layout="jp" ;;
        dvorak)    xkb_layout="us"; xkb_variant="dvorak" ;;
        colemak)   xkb_layout="us"; xkb_variant="colemak" ;;
    esac

    # X11/Wayland keyboard config — read by systemd-localed (used by KWin via D-Bus)
    mkdir -p "$MOUNTPOINT/etc/X11/xorg.conf.d"
    cat > "$MOUNTPOINT/etc/X11/xorg.conf.d/00-keyboard.conf" << EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${xkb_layout}"
$([ -n "$xkb_variant" ] && echo "    Option \"XkbVariant\" \"${xkb_variant}\"")
EndSection
EOF

    # Wayland-native XKB env vars — read directly by libxkbcommon / KWin Wayland
    {
        echo "XKB_DEFAULT_LAYOUT=${xkb_layout}"
        [ -n "$xkb_variant" ] && echo "XKB_DEFAULT_VARIANT=${xkb_variant}"
    } >> "$MOUNTPOINT/etc/environment"

    echo "${CONFIG[hostname]}" > "$MOUNTPOINT/etc/hostname"
    cat > "$MOUNTPOINT/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${CONFIG[hostname]}.localdomain ${CONFIG[hostname]}
EOF

    # Distro branding: this is Featherlite, not Arch — but it IS Arch
    # under the hood, so ID_LIKE=arch stays. That one line keeps every
    # Arch-aware tool working: the bar/drawer distro badges (direct ID
    # miss → ID_LIKE → Arch glyph), AUR helpers, installer scripts.
    # Overwritten here (not shipped as a file) because the `filesystem`
    # package owns /etc/os-release and a packaged file would fight it.
    cat > "$MOUNTPOINT/etc/os-release" << 'FEATHEROS'
NAME="Featherlite Linux"
PRETTY_NAME="Featherlite Linux"
ID=featherlite
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="0;36"
HOME_URL="https://github.com/jaytheoutpatient/simpbar"
DOCUMENTATION_URL="https://wiki.archlinux.org/"
SUPPORT_URL="https://github.com/jaytheoutpatient/simpbar"
BUG_REPORT_URL="https://github.com/jaytheoutpatient/simpbar/issues"
LOGO=archlinux
FEATHEROS

    arch-chroot "$MOUNTPOINT" systemctl enable NetworkManager

    # ly owns tty1 after install: the package ships only the template
    # ly@.service, so it is enabled as an instance (ly@tty1) — a plain
    # "ly.service" does not exist and would fail. getty@tty1 stands down
    # per the wiki (ly@ conflicts with it anyway; other ttys keep their
    # gettys, so a broken ly can never lock out console access entirely).
    # Sessions themselves (Hyprland/MangoWM entries) arrive later with
    # the desktop setup.
    arch-chroot "$MOUNTPOINT" systemctl enable ly@tty1 \
        || show_warning "Could not enable ly@tty1 — enable it manually after reboot: systemctl enable ly@tty1"
    arch-chroot "$MOUNTPOINT" systemctl disable getty@tty1.service 2>/dev/null || true

    # Force NetworkManager to use wpa_supplicant for WiFi (not iwd)
    mkdir -p "$MOUNTPOINT/etc/NetworkManager/conf.d"
    cat > "$MOUNTPOINT/etc/NetworkManager/conf.d/wifi-backend.conf" << EOF
[device]
wifi.backend=wpa_supplicant
EOF

    if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' "$MOUNTPOINT/etc/mkinitcpio.conf"
        if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
            # Snapshot booting needs the overlay hook (provided by
            # limine-mkinitcpio-hook): without it a snapshot entry boots
            # read-only or not at all.
            sed -i 's/ filesystems/ filesystems sd-btrfs-overlayfs/' "$MOUNTPOINT/etc/mkinitcpio.conf"
        fi
        arch-chroot "$MOUNTPOINT" mkinitcpio -P
    elif [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        # Same overlay hook for the stock (udev-style) HOOKS line.
        sed -i 's/ filesystems/ filesystems btrfs-overlayfs/' "$MOUNTPOINT/etc/mkinitcpio.conf"
        arch-chroot "$MOUNTPOINT" mkinitcpio -P
    fi
}

# Limine config writer: one entry per installed kernel (+fallback),
# shared by install_bootloader (initial write) and install_graphics
# (re-write when NVIDIA appends kernel parameters). Idempotent — safe to
# run repeatedly. Kernels, microcode and initramfs live on the boot
# partition, so every path is boot():/-relative and entries stay valid
# across kernel upgrades (files are replaced in place).
write_limine_conf() {
    local boot_mnt="$MOUNTPOINT/boot"
    [[ -d "$boot_mnt" ]] || { echo "ERROR: $boot_mnt missing"; return 1; }

    # Root device line: LUKS mapper when encrypted (unlocked by the
    # initramfs sd-encrypt hook — same rd.luks.name form GRUB used), plain
    # UUID otherwise; btrfs roots name their subvolume explicitly.
    local uuid=""
    uuid=$(blkid -s UUID -o value "${CONFIG[root_part]}")
    [[ -n "$uuid" ]] || { echo "ERROR: no UUID for ${CONFIG[root_part]}"; return 1; }
    local rootline=""
    if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
        rootline="rd.luks.name=${uuid}=cryptroot root=/dev/mapper/cryptroot"
    else
        rootline="root=UUID=${uuid}"
    fi
    if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
        rootline+=" rootflags=subvol=@"
    fi
    local cmdline="rw quiet splash loglevel=3 nvme_load=yes $rootline"
    if [[ -f "$MOUNTPOINT/etc/limine-cmdline-extra" ]]; then
        # shellcheck disable=SC2086
        cmdline+=" $(cat "$MOUNTPOINT/etc/limine-cmdline-extra")"
    fi

    # Microcode first, like every other bootloader: whichever ucode the
    # base install laid down (exactly one of these exists).
    local ucode=""
    if [[ -f "$boot_mnt/intel-ucode.img" ]]; then
        ucode="    module_path: boot():/intel-ucode.img"$'\n'
    elif [[ -f "$boot_mnt/amd-ucode.img" ]]; then
        ucode="    module_path: boot():/amd-ucode.img"$'\n'
    fi

    {
        echo "timeout: 5"
        echo "default_entry: 1"
        echo ""
        local k stem title entries=0
        # Base kernel first, then every extra (headers skipped). Missing
        # files warn-and-skip instead of aborting the whole install — but
        # zero entries at all is a hard failure, not a bootloader.
        # shellcheck disable=SC2086
        for k in linux ${CONFIG[extra_kernel]}; do
            [[ "$k" == *-headers ]] && continue
            stem="$k"
            if [[ ! -f "$boot_mnt/vmlinuz-$stem" ]]; then
                echo "WARNING: $boot_mnt/vmlinuz-$stem missing — skipping entry"
                continue
            fi
            entries=$((entries + 1))
            title="Featherlite Linux"
            [[ "$stem" != "linux" ]] && title="Featherlite Linux ($stem)"
            printf '%s\n' "/$title"
            echo "    protocol: linux"
            echo "    path: boot():/vmlinuz-$stem"
            echo "    cmdline: $cmdline"
            printf '%s' "$ucode"
            echo "    module_path: boot():/initramfs-$stem.img"
            echo ""
            if [[ -f "$boot_mnt/initramfs-$stem-fallback.img" ]]; then
                printf '%s\n' "/$title (fallback)"
                echo "    protocol: linux"
                echo "    path: boot():/vmlinuz-$stem"
                echo "    cmdline: $cmdline"
                printf '%s' "$ucode"
                echo "    module_path: boot():/initramfs-$stem-fallback.img"
                echo ""
            fi
        done
    } > "$boot_mnt/limine.conf"
    if [[ "$entries" -eq 0 ]]; then
        echo "ERROR: no kernel entries written to $boot_mnt/limine.conf"
        return 1
    fi
    # Limine probes several standard paths; the ESP copy covers UEFI
    # fallback boots that never look at /boot/limine.conf.
    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        mkdir -p "$boot_mnt/EFI/BOOT"
        cp "$boot_mnt/limine.conf" "$boot_mnt/EFI/BOOT/limine.conf"
    fi
}

install_bootloader() {
    # Limine: kernels, microcode and config all live on the boot
    # partition, so deployment is copying files, not generating them —
    # entries stay valid across kernel upgrades (paths are stable) and
    # limine-snapper-sync keeps snapshot entries current.
    local boot_mnt="$MOUNTPOINT/boot"
    [[ -d "$boot_mnt" ]] || { echo "ERROR: $boot_mnt missing"; return 1; }

    write_limine_conf || return 1

    if [[ "${CONFIG[uefi]}" == "yes" ]]; then
        # Fallback bootloader path: boots with or without an NVRAM entry.
        mkdir -p "$boot_mnt/EFI/BOOT"
        if [[ -f "$MOUNTPOINT/usr/share/limine/BOOTX64.EFI" ]]; then
            cp "$MOUNTPOINT/usr/share/limine/BOOTX64.EFI" "$boot_mnt/EFI/BOOT/BOOTX64.EFI"
        else
            echo "ERROR: BOOTX64.EFI missing from the limine package"
            return 1
        fi
        # Plus a named NVRAM entry where firmware allows it. The ESP is
        # always partition 1 in auto mode; derive it for manual layouts.
        local esp_part="${CONFIG[boot_part]#${CONFIG[disk]}}"
        esp_part="${esp_part#p}"
        [[ "$esp_part" =~ ^[0-9]+$ ]] || esp_part=1
        arch-chroot "$MOUNTPOINT" efibootmgr --create             --disk "${CONFIG[disk]}" --part "$esp_part"             --label "XeroLinux"             --loader /EFI/BOOT/BOOTX64.EFI 2>/dev/null             || show_warning "NVRAM boot entry failed — the fallback EFI path still boots on most firmware"
    else
        # BIOS: stage onto the ext4 /boot partition + MBR of the disk.
        # Runs in chroot so the target's limine version deploys itself.
        arch-chroot "$MOUNTPOINT" limine bios-install "${CONFIG[disk]}"             || { echo "ERROR: limine bios-install failed"; return 1; }
    fi

    # limine-snapper-sync targets the OS entry by name: pin it to ours so
    # snapshot entries attach even if os-release ever says otherwise. The
    # ESP is auto-detected (/boot here), so no path config is needed.
    # Must match the entry titles written by write_limine_conf above.
    if [[ -f "$MOUNTPOINT/etc/limine-snapper-sync.conf" ]]; then
        if grep -q '^#*TARGET_OS_NAME=' "$MOUNTPOINT/etc/limine-snapper-sync.conf"; then
            sed -i 's/^#*TARGET_OS_NAME=.*/TARGET_OS_NAME="Featherlite Linux"/' "$MOUNTPOINT/etc/limine-snapper-sync.conf"
        else
            echo 'TARGET_OS_NAME="Featherlite Linux"' >> "$MOUNTPOINT/etc/limine-snapper-sync.conf"
        fi
    fi
}

setup_snapper() {
    [[ "${CONFIG[filesystem]}" != "btrfs" ]] && return 0

    show_info "Configuring Snapper for Btrfs..."

    # snapper create-config requires dbus/PolicyKit — not available in a bare chroot.
    # Write the config file and create the subvolume directly instead; functionally
    # identical to what snapper create-config produces.

    # 1. Write snapper config file directly into the mounted system
    mkdir -p "$MOUNTPOINT/etc/snapper/configs"
    cat > "$MOUNTPOINT/etc/snapper/configs/root" << 'SNAPCFG'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPCFG

    # 2. Register config name with snapper's conf.d so it knows it exists
    mkdir -p "$MOUNTPOINT/etc/conf.d"
    if [[ -f "$MOUNTPOINT/etc/conf.d/snapper" ]]; then
        sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' "$MOUNTPOINT/etc/conf.d/snapper"
    else
        echo 'SNAPPER_CONFIGS="root"' > "$MOUNTPOINT/etc/conf.d/snapper"
    fi

    # 3. Create /.snapshots as a btrfs subvolume nested inside @ from the host side —
    #    no dbus needed, no chroot needed, just a direct btrfs command on the mountpoint.
    if ! btrfs subvolume create "$MOUNTPOINT/.snapshots" 2>/dev/null; then
        show_warning "Could not create /.snapshots subvolume — snapshot support may not work"
        return 0
    fi
    chmod 750 "$MOUNTPOINT/.snapshots"

    # 4. Add /.snapshots to fstab so rollbacks don't swallow the snapshots dir.
    #    The subvolume path inside the btrfs pool is @/.snapshots.
    local root_uuid=""
    if [[ "${CONFIG[encrypt]}" == "yes" ]]; then
        root_uuid=$(blkid -s UUID -o value /dev/mapper/cryptroot 2>/dev/null)
    else
        root_uuid=$(blkid -s UUID -o value "${CONFIG[root_part]}" 2>/dev/null)
    fi
    if [[ -n "$root_uuid" ]]; then
        echo "UUID=$root_uuid  /.snapshots  btrfs  noatime,compress=zstd,subvol=@/.snapshots  0  0" \
            >> "$MOUNTPOINT/etc/fstab"
    fi

    # 5. Defer snapper timers + limine-snapper-sync to first desktop login
    # via a oneshot service. Enabling them here (in a bare chroot) causes
    # them to fire before the user's filesystem is fully settled.
    mkdir -p "$MOUNTPOINT/usr/local/bin"
    cat > "$MOUNTPOINT/usr/local/bin/xero-snapper-init" << 'SNAPINIT'
#!/bin/bash
# Install snap-pac now — its pacman hooks will fire on the NEXT package operation,
# which is the first real user-initiated install, not during system setup.
pacman -S --needed --noconfirm snap-pac
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer
# Snapshot boot entries for Limine (warns instead of failing: the main
# entries in limine.conf boot fine with or without it).
systemctl enable --now limine-snapper-sync.service \
    || echo "WARNING: could not enable limine-snapper-sync.service"
touch /var/lib/xero-snapper-initialized
systemctl disable xero-snapper-init.service
SNAPINIT
    chmod +x "$MOUNTPOINT/usr/local/bin/xero-snapper-init"

    cat > "$MOUNTPOINT/etc/systemd/system/xero-snapper-init.service" << 'SVCEOF'
[Unit]
Description=Initialize Snapper timers on first boot (XeroLinux)
ConditionPathExists=!/var/lib/xero-snapper-initialized
After=sysinit.target local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/xero-snapper-init

[Install]
WantedBy=multi-user.target
SVCEOF

    arch-chroot "$MOUNTPOINT" systemctl enable xero-snapper-init.service 2>/dev/null || true

    show_success "Snapper configured — timers activate on first boot."
}

create_user() {
    echo "root:${CONFIG[root_password]}" | arch-chroot "$MOUNTPOINT" chpasswd

    local groups_to_create="sys network scanner power cups realtime sambashare rfkill lp users video storage kvm optical audio wheel adm falcond"
    for grp in $groups_to_create; do
        arch-chroot "$MOUNTPOINT" groupadd -f "$grp" 2>/dev/null || true
    done

    arch-chroot "$MOUNTPOINT" useradd -m -G sys,network,scanner,power,cups,realtime,sambashare,rfkill,lp,users,video,storage,kvm,optical,audio,wheel,adm,falcond -s /bin/bash "${CONFIG[username]}"
    echo "${CONFIG[username]}:${CONFIG[user_password]}" | arch-chroot "$MOUNTPOINT" chpasswd

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$MOUNTPOINT/etc/sudoers"
}

install_graphics() {
    local packages=""
    local needs_nvidia_config="no"

    # Base mesa/VM drivers (installed for all configurations)
    local base_drivers="mesa autorandr mesa-utils lib32-mesa xf86-video-qxl xf86-video-fbdev lib32-mesa-utils"

    case "${CONFIG[gfx_driver]}" in
        "intel")
            packages="intel-drv $base_drivers"
            ;;
        "amd")
            packages="amd-drv $base_drivers"
            ;;
        "nvidia-turing")
            packages="libvdpau nvidia-utils opencl-nvidia libvdpau-va-gl nvidia-settings nvidia-open-dkms vulkan-icd-loader lib32-nvidia-utils lib32-opencl-nvidia linux-firmware-nvidia lib32-vulkan-icd-loader $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "nvidia-legacy")
            packages="nvidia-580xx-dkms nvidia-580xx-utils opencl-nvidia-580xx lib32-opencl-nvidia-580xx lib32-nvidia-580xx-utils $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "intel-amd")
            packages="intel-drv amd-drv $base_drivers"
            ;;
        "intel-nvidia-turing")
            packages="intel-drv libvdpau nvidia-utils opencl-nvidia libvdpau-va-gl nvidia-settings nvidia-open-dkms vulkan-icd-loader lib32-nvidia-utils lib32-opencl-nvidia linux-firmware-nvidia lib32-vulkan-icd-loader $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "intel-nvidia-legacy")
            packages="intel-drv nvidia-580xx-dkms nvidia-580xx-utils opencl-nvidia-580xx lib32-opencl-nvidia-580xx lib32-nvidia-580xx-utils $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "amd-nvidia-turing")
            packages="amd-drv libvdpau nvidia-utils opencl-nvidia libvdpau-va-gl nvidia-settings nvidia-open-dkms vulkan-icd-loader lib32-nvidia-utils lib32-opencl-nvidia linux-firmware-nvidia lib32-vulkan-icd-loader $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "amd-nvidia-legacy")
            packages="amd-drv nvidia-580xx-dkms nvidia-580xx-utils opencl-nvidia-580xx lib32-opencl-nvidia-580xx lib32-nvidia-580xx-utils $base_drivers"
            needs_nvidia_config="yes"
            ;;
        "vm")
            packages="$base_drivers xorg-server xorg-xinit"
            # Auto-detect VM type and install appropriate guest utilities
            local vm_type=""
            vm_type=$(systemd-detect-virt 2>/dev/null || echo "unknown")
            case "$vm_type" in
                "qemu"|"kvm")
                    packages+=" spice-vdagent qemu-guest-agent"
                    ;;
                "vmware")
                    packages+=" open-vm-tools"
                    ;;
                "oracle")
                    packages+=" virtualbox-guest-utils"
                    ;;
                *)
                    # Install all if we can't detect
                    packages+=" spice-vdagent qemu-guest-agent open-vm-tools virtualbox-guest-utils"
                    ;;
            esac
            ;;
    esac

    if [[ -n "$packages" ]]; then
        # shellcheck disable=SC2086
        arch-chroot "$MOUNTPOINT" pacman -S --noconfirm --needed $packages \
            || show_warning "Some graphics packages failed — system may still work with basic drivers"
    fi

    if [[ "$needs_nvidia_config" == "yes" ]]; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$MOUNTPOINT/etc/mkinitcpio.conf"
        sed -i 's/MODULES=( /MODULES=(/' "$MOUNTPOINT/etc/mkinitcpio.conf"
        arch-chroot "$MOUNTPOINT" mkinitcpio -P
        # Kernel parameters live in limine.conf now (no /etc/default/grub):
        # stash them where write_limine_conf picks them up, then rewrite it
        # (install_bootloader already ran earlier in the step order).
        echo "nvidia_drm.modeset=1 nvidia_drm.fbdev=1" > "$MOUNTPOINT/etc/limine-cmdline-extra"
        write_limine_conf || show_warning "Could not refresh limine.conf with NVIDIA parameters"
    fi
}

setup_swap_system() {
    case "${CONFIG[swap]}" in
        "zram")
            arch-chroot "$MOUNTPOINT" pacman -S --noconfirm zram-generator
            cat > "$MOUNTPOINT/etc/systemd/zram-generator.conf" << EOF
[zram0]
zram-size = ram / 2
compression-algorithm = ${CONFIG[swap_algo]}
EOF
            ;;
        "file")
            if [[ "${CONFIG[filesystem]}" == "btrfs" ]]; then
                arch-chroot "$MOUNTPOINT" truncate -s 0 /swapfile
                arch-chroot "$MOUNTPOINT" chattr +C /swapfile
                arch-chroot "$MOUNTPOINT" fallocate -l 4G /swapfile
            else
                arch-chroot "$MOUNTPOINT" dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
            fi
            arch-chroot "$MOUNTPOINT" chmod 600 /swapfile
            arch-chroot "$MOUNTPOINT" mkswap /swapfile
            echo "/swapfile none swap defaults 0 0" >> "$MOUNTPOINT/etc/fstab"
            ;;
        "none")
            ;;
    esac
}


# ────────────────────────────────────────────────────────────────────────────────
# MAIN ENTRY POINT
# ────────────────────────────────────────────────────────────────────────────────

main() {
    check_root
    # Dependencies BEFORE any gum call: show_splash is all gum, and with
    # set -Eeuo pipefail the first missing-gum call is instantly fatal
    # (exit 127 before a single menu renders). check_internet and
    # ensure_dependencies use no gum themselves, so they are safe here.
    if ! command -v gum &>/dev/null; then
        check_internet
        ensure_dependencies
    fi
    if ! command -v gum &>/dev/null; then
        echo "ERROR: 'gum' is required but could not be installed (pacman -S gum) — re-run once it is." >&2
        exit 1
    fi
    show_splash
    check_uefi
    show_main_menu
}

main "$@"

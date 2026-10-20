#!/bin/bash
# Simpbar Installer
# Arch Linux only
# ligma

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

TOTAL_STEPS=9
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

# Bash-builtin sleep for spinner/keepalive/retry waits. /usr/bin/sleep is a
# dynamically linked external that cannot even execute mid-libc-upgrade
# (a repo sync can swap libc under us — every tick then faults with
# "cannot execute" / bus errors), while this already-running shell and its
# builtins keep working. The fd opens once up front (RDWR so the pipe never
# sees EOF) and `read -t` does the waiting: no fork, no exec.
exec {SPIN_SLEEP_FD}<> <(:)
spin_sleep() { read -t "${1:-0.1}" -u "$SPIN_SLEEP_FD" || true; }

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
        spin_sleep 0.1
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

# ── Saved-answer machinery ─────────────────────────────────────────────
# The installer is normally run as `curl ... | bash`, so every run starts from
# a blank script with no memory of the last one. To keep re-runs (updates)
# from re-asking the whole questionnaire, every choice is persisted as a
# key=value line in ANSWERS_FILE. On the next run the same questions are
# skipped and their previous answer is replayed — see prompt_choice below.
#
# Two refinements on top of plain replay:
#  * Installed software wins. Before each question the script checks whether
#    what's already installed answers it (reuse_detected/detect_one below) —
#    e.g. mangowm installed means MangoWM, zen-browser-bin means Zen. Ground
#    truth beats a stale saved answer, including a remembered "skip" from
#    before you installed the thing by hand.
#  * Destructive choices never replay. The Firefox prompt's "Remove Firefox"
#    is marked _HAS_SKIP_, so a remembered removal can't silently nuke a
#    Firefox you installed later — that one always re-asks while present.
#
# The file lives under ~/.config/simpbar/ (already the installer's home for
# reminders.txt / wallpaper / browser-choice). A prompt only auto-replays an
# answer when the remembered choice is still a valid option; a prompt whose
# options ever change upstream falls back to asking rather than picking
# blindly.
ANSWERS_FILE="$HOME/.config/simpbar/install-answers"

# force_ask=1 makes every prompt ask again instead of replaying a saved
# answer (set by the re-run review prompt). Declared here, before any
# prompt_choice call, so it's always defined even if the review block is
# skipped on a first run.
force_ask=0

# Record one answer: key=value. Appends/updates in place so a re-run refreshes
# the stored value instead of piling up duplicates.
save_answer() {
    local key="$1" value="$2" tmp
    mkdir -p "$(dirname "$ANSWERS_FILE")"
    tmp="${ANSWERS_FILE}.tmp.$$"
    if [ -r "$ANSWERS_FILE" ]; then
        grep -v "^${key}=" "$ANSWERS_FILE" > "$tmp" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv -f "$tmp" "$ANSWERS_FILE"
}

# Read back a previously saved answer, or empty if none/unknown.
load_answer() {
    local key="$1"
    [ -r "$ANSWERS_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$ANSWERS_FILE" | head -n1
}

# True when the installer is being re-run over an existing saved setup. Used
# once, up front, to offer a review of the remembered answers before skipping
# them all (see the review block after Step 0).
has_saved_answers() {
    [ -r "$ANSWERS_FILE" ] && [ -s "$ANSWERS_FILE" ]
}

# True when pacman knows the package (official repos or a foreign/AUR build
# already installed — `pacman -Q` covers both).
pkg_installed() {
    pacman -Qq "$1" >/dev/null 2>&1
}

# Map installed packages to a prompt choice. Each argument is
# "<number>:<pkg> [<pkg> ...]" — the number to pick when one of its packages
# is installed. Prints the number when the installed packages point at exactly
# ONE choice, and nothing when nothing matches or two different choices both
# have something installed (ambiguous — the caller falls through to the saved
# answer or the question). Always succeeds, so it composes with `if`.
detect_one() {
    local hit="" spec c pkgs p
    for spec in "$@"; do
        c="${spec%%:*}"; pkgs="${spec#*:}"
        for p in $pkgs; do
            if pkg_installed "$p"; then
                if [ -n "$hit" ] && [ "$hit" != "$c" ]; then
                    return 0 # ambiguous: leave it to the saved answer/question
                fi
                hit="$c"
                break
            fi
        done
    done
    [ -n "$hit" ] && printf '%s' "$hit"
    return 0
}

# When installed packages point at exactly one choice, take it as the answer:
# store it and return 0 so the caller skips its prompt_choice. Otherwise
# return 1 and the caller asks (or replays a saved answer) as usual.
# Installed software is ground truth — it beats a stale saved answer, e.g. a
# remembered "skip the browser" from before you installed one by hand.
reuse_detected() {
    local var="$1"; shift
    local hit
    hit="$(detect_one "$@")" || return 1
    [ -n "$hit" ] || return 1
    printf -v "$var" '%s' "$hit"
    save_answer "$var" "$hit"
    return 0
}

# One-line "detected, skipping" note, mirroring prompt_choice's replay note.
detected_note() {
    printf '  %s·%s %s — detected installed %s%s%s, skipping question\n' \
        "$C_GREEN" "$C_RESET" "$1" "$C_BOLD" "$2" "$C_RESET"
}

# Print a numbered menu, read one choice from /dev/tty, and fall back to
# a default when input isn't available or left blank.
#   prompt_choice RESULT_VAR DEFAULT "Question?" "Option 1" "Option 2" ...
# RESULT_VAR is set to the chosen number (as a string), or DEFAULT.
#
# When RESULT_VAR has a previously saved answer (keyed by the variable name
# itself) that answer is still a valid option, the question is skipped
# entirely: the saved value is replayed and a one-line note shown. Press Enter
# at the review prompt (or delete the answers file) to force every question to
# be asked again. Callers check installed software FIRST (reuse_detected) so a
# saved answer only replays when detection found nothing either way.
#
# A prompt may pass the literal token _HAS_SKIP_ as the final argument to
# mark its last option as never-replayable. Only the destructive Firefox
# "Remove Firefox" option uses this: a remembered removal must never silently
# nuke a Firefox installed later, so that prompt always re-asks while Firefox
# is present. Ordinary "skip / install nothing" answers DO replay — the
# re-run review prompt is the way to change your mind.
prompt_choice() {
    local result_var="$1" default="$2" question="$3"; shift 3
    local n=1 opt choice saved opt_count=$#

    # Detect (and strip) the trailing _HAS_SKIP_ marker.
    local has_skip=0
    if [ "$opt_count" -gt 0 ] && [ "${!opt_count}" = "_HAS_SKIP_" ]; then
        has_skip=1
        opt_count=$((opt_count - 1))
        set -- "${@:1:$opt_count}"
    fi

    saved="$(load_answer "$result_var")"

    # Replay a saved answer only when it's a real selection: a number inside
    # the current option range, and (for skip-capable prompts) not the skip
    # option itself. Anything else — stale index after the option list grew,
    # a remembered skip — falls through and asks normally.
    if [ -n "$saved" ] && [ "$saved" -eq "$saved" ] 2>/dev/null \
        && [ "$saved" -ge 1 ] && [ "$saved" -le "$opt_count" ] \
        && { [ "$has_skip" -eq 0 ] || [ "$saved" -lt "$opt_count" ]; }; then
        :
    else
        saved=""
    fi

    if [ -n "$saved" ] && [ "$force_ask" != 1 ]; then
        # Resolve the saved number to its label purely for the note, so the
        # user can see what was reused without re-reading the menu.
        local idx=1 label=""
        for opt in "$@"; do
            [ "$idx" -eq "$saved" ] && { label="$opt"; break; }
            idx=$((idx + 1))
        done
        printf '  %s·%s %s — using saved answer %s(%s)%s\n' \
            "$C_GREEN" "$C_RESET" "$question" "$C_BOLD" "$label" "$C_RESET"
        printf -v "$result_var" '%s' "$saved"
        return 0
    fi

    printf '\n  %s%s%s\n' "$C_YELLOW" "$question" "$C_RESET"
    for opt in "$@"; do
        printf '    %s%d)%s %s\n' "$C_CYAN" "$n" "$C_RESET" "$opt"
        n=$((n + 1))
    done
    printf '  %sChoice [%s]: %s' "$C_BOLD" "$default" "$C_RESET"

    # Validate: anything that isn't a number in range gets re-asked instead
    # of sliding into the `*)` default arm (typing "brave" used to read as
    # "skip the browser"). Empty (Enter) and unreadable tty still take the
    # curated default, so the loop always terminates.
    while true; do
        if [ -r /dev/tty ]; then
            read -r choice < /dev/tty || true
        else
            warn "No interactive terminal available — defaulting to option $default"
            choice="$default"
        fi
        # Strip whitespace (including \r): pasted input and some VM consoles
    # smuggle in carriage returns, which would otherwise fail numeric
    # validation below and force a re-ask for a choice that was valid.
    # Pure builtins — no fork, safe anywhere in the run.
    choice="${choice//[[:space:]]/}"
    [ -z "$choice" ] && choice="$default"
        if [ "$choice" -eq "$choice" ] 2>/dev/null && [ "$choice" -ge 1 ] && [ "$choice" -le "$opt_count" ]; then
            break
        fi
        printf '  %sPlease type a number between 1 and %d.%s\n' "$C_RED" "$opt_count" "$C_RESET"
        printf '  %sChoice [%s]: %s' "$C_BOLD" "$default" "$C_RESET"
    done

    # Remember the answer so a future re-run/update doesn't ask it again.
    save_answer "$result_var" "$choice"
    printf -v "$result_var" '%s' "$choice"
}

# Try installing a "would-be-AUR" package from the enabled pacman repos
# first (Chaotic-AUR carries these as binary packages), falling back to an
# AUR helper only when the repos don't have it.
# install_aur_pkg <display name> <package>
install_aur_pkg() {
    local name="$1" pkg="$2"
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        run_spinner "pacman: $pkg (${REPO_NAME})" sudo pacman -S --noconfirm --needed "$pkg" \
            || { warn "Could not install $name from ${REPO_NAME} — install manually: sudo pacman -S $pkg"; return 1; }
        return 0
    fi
    if command -v yay >/dev/null; then
        run_spinner "yay: $pkg (AUR)" yay -S --noconfirm --needed "$pkg" \
            || { warn "Could not install $name via yay — install manually: yay -S $pkg"; return 1; }
    elif command -v paru >/dev/null; then
        run_spinner "paru: $pkg (AUR)" paru -S --noconfirm --needed "$pkg" \
            || { warn "Could not install $name via paru — install manually: paru -S $pkg"; return 1; }
    else
        warn "Could not install $name from ${REPO_NAME} and no AUR helper is available — install manually: yay -S $pkg"
        return 1
    fi
}

# Install a batch of packages from the enabled pacman repos when possible,
# falling back to an AUR helper for anything the repos don't carry. Only asks
# to install yay/paru when it is actually needed.
#   install_repo_or_aur <pkg> [<pkg> ...]
# Returns 0 when everything installed.
install_repo_or_aur() {
    local repo=() aur=() pkg count="$#"
    for pkg in "$@"; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then
            repo+=("$pkg")
        else
            aur+=("$pkg")
        fi
    done

    if [ "${#repo[@]}" -gt 0 ]; then
        # One bad package (a conflict, a 404) aborts the whole transaction
        # under --noconfirm — so a batch failure retries per package, and
        # only the true failures are reported at the end.
        if ! run_spinner "pacman: ${#repo[@]} of $count packages from ${REPO_NAME}" \
            sudo pacman -S --noconfirm --needed "${repo[@]}"; then
            warn "Batch install failed — retrying packages individually"
            local failed=() p
            for p in "${repo[@]}"; do
                run_spinner "pacman: $p" sudo pacman -S --noconfirm --needed "$p" \
                    || { warn "Could not install $p — install manually: sudo pacman -S $p"; failed+=("$p"); }
            done
            if [ "${#failed[@]}" -gt 0 ]; then
                warn "Some ${REPO_NAME} installs failed: ${failed[*]}"
                return 1
            fi
        fi
    fi

    if [ "${#aur[@]}" -eq 0 ]; then
        return 0
    fi

    printf '  %d package(s) are not in %s: %s\n' "${#aur[@]}" "$REPO_NAME" "${aur[*]}"
    if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
        # Xero defaults to paru — take it without asking. Anything else
        # genuinely lacks a helper, so the question stands.
        if [ "$XERO_SYSTEM" = 1 ]; then
            AUR_CHOICE=2
        else
            prompt_choice AUR_CHOICE 1 "No AUR helper found — ${#aur[@]} package(s) need the AUR. Install which one?" "yay" "paru" "skip"
        fi
        case "$AUR_CHOICE" in
            2) install_paru || warn "Could not install paru automatically — install manually: ${aur[*]}" ;;
            3) warn "Skipping AUR helper install — install manually: ${aur[*]}" ;;
            *) install_yay || warn "Could not install yay automatically — install manually: ${aur[*]}" ;;
        esac
    fi

    if command -v yay >/dev/null; then
        if ! run_spinner "yay: installing ${#aur[@]} AUR packages" yay -S --noconfirm --needed "${aur[@]}"; then
            warn "Batch AUR install failed — retrying packages individually"
            local afailed=() ap
            for ap in "${aur[@]}"; do
                run_spinner "yay: $ap" yay -S --noconfirm --needed "$ap" \
                    || { warn "Could not install $ap via yay — install manually: yay -S $ap"; afailed+=("$ap"); }
            done
            if [ "${#afailed[@]}" -gt 0 ]; then
                warn "Some AUR packages failed via yay — install manually: yay -S ${afailed[*]}"
                return 1
            fi
        fi
    elif command -v paru >/dev/null; then
        if ! run_spinner "paru: installing ${#aur[@]} AUR packages" paru -S --noconfirm --needed "${aur[@]}"; then
            warn "Batch AUR install failed — retrying packages individually"
            local afailed=() ap
            for ap in "${aur[@]}"; do
                run_spinner "paru: $ap" paru -S --noconfirm --needed "$ap" \
                    || { warn "Could not install $ap via paru — install manually: paru -S $ap"; afailed+=("$ap"); }
            done
            if [ "${#afailed[@]}" -gt 0 ]; then
                warn "Some AUR packages failed via paru — install manually: paru -S ${afailed[*]}"
                return 1
            fi
        fi
    else
        warn "No AUR helper available — install manually: ${aur[*]}"
        return 1
    fi
}

banner

# ── Step 0: platform check ─────────────────────────────────────────
command -v pacman >/dev/null || die "This script is Arch-only (pacman not found)."

# ── Step -1: XeroLinux provisioning (Arch ISO live environments only) ─
# /run/archiso exists only on a booted Arch ISO. There — and ONLY there —
# offer our Xero-based provisioning script first: it installs a whole base
# system (partitioning, base, users, drivers, Limine bootloader — no
# desktop environment) where this script only ever configures an
# already-running one. Opt-in behind a typed y (it can wipe disks);
# declining, or running on an installed system, continues below with zero
# behavior change. Fetched from this repo (versioned with it) rather than
# Xero upstream, downloaded first so a failed fetch can't feed a half-pipe
# to bash. stdin is forced to /dev/tty so its prompts work even when this
# script itself runs as `curl | bash`. A SUCCESSFUL base install ends this
# run outright: the new system sits at /mnt and this live ISO (root, no
# real user, nothing persists past reboot) is the wrong place for desktop
# setup — every later step would pacman into the ISO and write configs to
# root's home, then evaporate on reboot. So success prints the reboot
# handoff and exits; only a failed/skipped base install falls through
# below, where the operator owns the consequences.
if [ -d /run/archiso ]; then
    printf '\n  %sArch ISO live environment detected.%s\n' "$C_YELLOW" "$C_RESET"
    prompt_choice XERO_CHOICE 2 "Provision this machine with the simpbar base-system installer first?" \
        "Yes, run the base installer" "No, configure with simpbar"
    if [ "$XERO_CHOICE" = 1 ]; then
        printf '\n  %sWARNING: the base installer partitions disks and can%s\n' "$C_RED" "$C_RESET"
        printf '  %sDESTROY DATA. Only continue on a machine (or VM) you can wipe.%s\n' "$C_RED" "$C_RESET"
        printf '  %sType y to launch it, anything else skips:%s ' "$C_BOLD" "$C_RESET"
        if [ -r /dev/tty ]; then
            IFS= read -r xero_confirm < /dev/tty || xero_confirm=""
        else
            xero_confirm=""
        fi
        # Same paste hygiene as prompt_choice: a smuggled \r must not turn
        # an explicit y into a silent skip (nor vice versa — the comparison
        # below stays an exact match either way).
        xero_confirm="${xero_confirm//[[:space:]]/}"
        if [ "$xero_confirm" = "y" ] || [ "$xero_confirm" = "Y" ]; then
            if curl -fsSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/xero/xero-install.sh -o /tmp/xero-install.sh; then
                if bash /tmp/xero-install.sh < /dev/tty; then
                    rm -f /tmp/xero-install.sh
                    printf '\n  %sBase system installed — reboot into it now.%s\n' "$C_GREEN" "$C_RESET"
                    printf '  Remove the installation media, reboot, log in as the user you just created.\n'
                    printf '  If you chose a first-boot WM, a terminal opens with the desktop setup running.\n'
                    printf '  Otherwise (or if it never opens), run it yourself post-reboot:\n'
                    printf '  %scurl -sSL https://raw.githubusercontent.com/jaytheoutpatient/simpbar/main/install.sh | bash%s\n' "$C_BOLD" "$C_RESET"
                    printf '  (Running the steps below here would install into this live ISO as root —\n'
                    printf '  nothing would survive the reboot.)\n'
                    exit 0
                else
                    warn "Base installer exited early — continuing with simpbar setup"
                fi
                rm -f /tmp/xero-install.sh
                ok "Continuing with simpbar setup"
            else
                warn "Could not download the base installer — continuing with simpbar setup"
            fi
        else
            ok "Skipping base-system provisioning"
        fi
        unset xero_confirm
    fi
fi

# ── Re-run review ──────────────────────────────────────────────────
# If a previous run saved answers (curl|bash has no other memory between
# runs), offer to review them before they're silently replayed. Pressing
# Enter (default No) keeps every remembered answer and skips all the
# questions; answering Yes sets force_ask=1 so every question is asked
# again this run, and whatever is chosen overwrites the saved answer.
#
# This reads the answer directly instead of going through prompt_choice:
# the review menu must stay reachable on every re-run, and prompt_choice
# would replay a stale saved answer and hide it forever.
force_ask=0
# Only when a previous run got past the first real question (repo choice):
# an answers file holding just XERO_CHOICE (aborted before Step 1) would
# otherwise print a review of blank values for nothing that was configured.
if has_saved_answers && [ -n "$(load_answer REPO_CHOICE)" ]; then
    printf '\n  %sExisting simpbar setup found%s — your previous answers will be\n' "$C_YELLOW" "$C_RESET"
    printf '  reused and the questions below will be skipped.\n'
    printf '  %s·%s repository     %s\n' "$C_GREEN" "$C_RESET" "Chaotic-AUR"
    printf '  %s·%s window manager %s\n' "$C_GREEN" "$C_RESET" "$(load_answer WM_CHOICE | sed 's/^1$/Hyprland/;s/^2$/MangoWM/')"
    printf '\n  %sReview and change these answers? [y/N]: %s' "$C_BOLD" "$C_RESET"
    if [ -r /dev/tty ]; then
        IFS= read -r review_reply < /dev/tty || review_reply=""
    else
        review_reply=""
    fi
    case "$review_reply" in
        [Yy]*) force_ask=1 ;;
    esac
fi

# ── XeroLinux-provisioned systems ────────────────────────────────────
# Xero's own installer sets up [xerolinux] + [chaotic-aur], a paru default,
# and Phase-2 browsers/social apps — so on its systems this script skips
# the overlapping choices below (repos, browser, Discord, AUR helper,
# graphics-driver pins) instead of re-asking or fighting them. Everything
# else (WM, terminals, theming, simpbar itself) still runs. Non-Xero
# systems never see this.
XERO_SYSTEM=0
if grep -qE '^\[xerolinux\]' /etc/pacman.conf 2>/dev/null; then
    XERO_SYSTEM=1
    ok "XeroLinux-provisioned system detected — repo, browser, Discord, and AUR-helper choices are covered by the Xero install"
fi

# ── Step 1: package repositories ─────────────────────────────────────
step "Choosing package repositories"

if [ "$XERO_SYSTEM" = 1 ]; then
    # Chaotic-AUR is already there via Xero, so take it silently.
    REPO_CHOICE=2; save_answer REPO_CHOICE 2; REPO_DETECTED=0
    REPO_NAME="Chaotic-AUR"; REPO_LABEL="Chaotic-AUR"
else

printf '\n  %sChaotic-AUR%s adds a binary repo to pacman so most packages —\n' "$C_YELLOW" "$C_RESET"
printf '  including things that are AUR-only on plain Arch — install through\n'
printf '  %ssudo pacman -S%s instead of being compiled by an AUR helper (yay/\n' "$C_CYAN" "$C_RESET"
printf '  paru only gets used for the few stragglers the repo does not carry).\n\n'

# Chaotic-AUR already configured means nothing to ask — otherwise take it.
REPO_DETECTED=0
have_chaotic=0
grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null && have_chaotic=1
if [ "$have_chaotic" = 1 ]; then
    REPO_CHOICE=2; save_answer REPO_CHOICE 2; REPO_DETECTED=1
else
    REPO_CHOICE=2; save_answer REPO_CHOICE 2; REPO_DETECTED=0
fi
REPO_NAME="Chaotic-AUR"; REPO_LABEL="Chaotic-AUR"
[ "$REPO_DETECTED" = 1 ] && detected_note "Repositories" "$REPO_NAME"
ok "Selected ${REPO_NAME} repositories"
fi

# ── Step 2: window manager ───────────────────────────────────────────
step "Choosing your window manager"
step "Choosing your window manager"

printf '\n  %sHyprland%s is the default setup (Lua config, %s~/.config/hypr%s).\n' "$C_YELLOW" "$C_RESET" "$C_CYAN" "$C_RESET"
printf '  %sMangoWM%s uses your shipped %s~/.config/mango%s config (flat files\n' "$C_YELLOW" "$C_RESET" "$C_CYAN" "$C_RESET"
printf '  under %scfg/%s — where simpbar-config writes its Mango pages).\n' "$C_CYAN" "$C_RESET"

# A WM package already installed is the answer — asking "which WM" when only
# mangowm is present just burns a prompt. Both/neither installed falls
# through to the saved answer or the question.
if reuse_detected WM_CHOICE '1:hyprland' '2:mangowm'; then
    WM_DETECTED=1
else
    WM_DETECTED=0
    prompt_choice WM_CHOICE 1 "Which window manager would you like to install?" "Hyprland" "MangoWM"
fi
case "$WM_CHOICE" in
    2) WM_NAME="MangoWM"; WM_IS_HYPRLAND=0; WM_IS_MANGO=1
       CONFIG_DIRS=(mango swaync fastfetch matugen) ;;
    *) WM_NAME="Hyprland"; WM_IS_HYPRLAND=1; WM_IS_MANGO=0
       CONFIG_DIRS=(hypr swaync fastfetch matugen) ;;
esac
[ "$WM_DETECTED" = 1 ] && detected_note "Window manager" "$WM_NAME"
ok "Selected ${WM_NAME}"

# ── Step 3: prerequisites ────────────────────────────────────────────
step "Checking prerequisites"

# ── Sudo: authenticate ONCE, then hold the password ────────────────
# The script asks for the sudo password exactly once, up front, then serves
# every later `sudo` from that stored copy through an askpass helper. A `sudo`
# wrapper placed first on PATH means child processes (pacman, makepkg,
# yay/paru, pacman key imports) inherit it too, so nothing re-prompts
# for the rest of the run.
SUDO_PASS=""
SUDO_KEEPALIVE_PID=""
SUDO_TMP_DIR=""

printf '\n%sThis installer needs sudo access — enter the password once and\n' "$C_BOLD"
printf 'it will be held for the whole run.%s\n' "$C_RESET"
if [ ! -r /dev/tty ]; then
    die "No interactive terminal available — run this script from a real TTY."
fi
printf '  %sPassword: %s' "$C_BOLD" "$C_RESET"
IFS= read -rs SUDO_PASS < /dev/tty
printf '\n'
[ -n "$SUDO_PASS" ] || die "No password entered."

SUDO_TMP_DIR=$(mktemp -d)
chmod 700 "$SUDO_TMP_DIR"
export SIMPBAR_SUDO_PASS="$SUDO_PASS"

cat > "$SUDO_TMP_DIR/askpass.sh" <<'SUDOASKPASS'
#!/bin/bash
printf '%s\n' "$SIMPBAR_SUDO_PASS"
SUDOASKPASS
chmod 700 "$SUDO_TMP_DIR/askpass.sh"

cat > "$SUDO_TMP_DIR/sudo" <<'SUDOWRAPPER'
#!/bin/bash
exec /usr/bin/sudo -A "$@"
SUDOWRAPPER
chmod 755 "$SUDO_TMP_DIR/sudo"

export SUDO_ASKPASS="$SUDO_TMP_DIR/askpass.sh"
export PATH="$SUDO_TMP_DIR:$PATH"

cleanup_sudo() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    [ -n "$SUDO_TMP_DIR" ] && rm -rf "$SUDO_TMP_DIR"
    unset SIMPBAR_SUDO_PASS
}
trap 'cleanup_sudo' EXIT

# Verify the password now so a wrong one fails loudly at the start, not in the
# middle of a spinner. The keepalive loop refreshes the sudo timestamp every
# minute (via the same askpass path) so expiry can never cause a prompt.
if ! sudo -v >/dev/null 2>&1; then
    die "Could not authenticate with sudo (wrong password?)."
fi
ok "Sudo access confirmed — one prompt, held for the whole run"
( while true; do sudo -v >/dev/null 2>&1 || exit 1; spin_sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!

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

# ── Step 4: fetch simpbar config + source ─────────────────────────────
step "Fetching simpbar theme"
mkdir -p ~/.config

run_spinner "Downloading simpbar config" \
    curl -fL -o /tmp/simpbar.zip https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip \
    || die "Could not download simpbar (check your network connection)."

run_spinner "Extracting archive" \
    unzip -o /tmp/simpbar.zip -d /tmp/simpbar-temp \
    || die "Could not extract simpbar archive."
rm -f /tmp/simpbar.zip

# CONFIG_DIRS was chosen in Step 2 (hypr… for Hyprland, mango… for MangoWM);
# verify the archive actually carries the whole set.
for d in "${CONFIG_DIRS[@]}" simpbar; do
    if [ ! -d "/tmp/simpbar-temp/simpbar-main/$d" ]; then
        rm -rf /tmp/simpbar-temp
        die "Downloaded archive did not contain a $d/ directory — layout may have changed upstream."
    fi
done

# First-boot stubs (written by xero-install.sh into ~/.config/hypr and
# ~/.config/mango, all carrying a `simpbar-firstboot stub` marker) share
# paths with the real configs and are MEANT to be overwritten by them —
# but the no-clobber deploy below would preserve them forever, leaving a
# fresh install stuck on stubs (no bar autostart, no wallpaper restore).
# Remove marker-bearing files first; real user configs carry no marker and
# are never touched by this.
for _stubdir in ~/.config/hypr ~/.config/mango; do
    [ -d "$_stubdir" ] || continue
    grep -rIl "simpbar-firstboot stub" "$_stubdir" 2>/dev/null | while IFS= read -r _stub; do
        rm -f "$_stub"
    done
done
unset _stubdir _stub
for d in "${CONFIG_DIRS[@]}"; do
    # No-clobber deploy: on a fresh install everything lands; on an update
    # re-run (Welcome -> "Update Simpbar" just re-runs this script) existing
    # files are left alone and only genuinely new files are added. A plain
    # `cp -r` would overwrite the user's live configs every update —
    # notably ~/.config/mango/cfg/monitors.conf and ~/.config/hypr/*.lua —
    # wiping monitor settings back to shipped defaults.
    cp -rn "/tmp/simpbar-temp/simpbar-main/$d" ~/.config/
done
# Fix matugen layout: templates in templates/ subdir, scripts in root
if [ -d ~/.config/matugen ]; then
    mkdir -p ~/.config/matugen/templates
    for f in ~/.config/matugen/*.json ~/.config/matugen/*.css ~/.config/matugen/*.lua ~/.config/matugen/*.ini ~/.config/matugen/*.conf; do
        [ -f "$f" ] && mv -f "$f" ~/.config/matugen/templates/ 2>/dev/null || true
    done
fi
ok "Configs placed in ~/.config/{${CONFIG_DIRS[*]// /,}}"

# The shipped Mango config keeps user-specific paths as the __HOME__
# placeholder (the repo can't know the target user's home); substitute the
# real home directory into the deployed copy now.
if [ "$WM_IS_MANGO" -eq 1 ]; then
    sed -i "s|__HOME__|$HOME|g" ~/.config/mango/config.conf ~/.config/mango/cfg/*.conf
    ok "Mango config deployed (~/.config/mango)"
fi

# simpbar is source, not a config dir — kept out of CONFIG_DIRS/~/.config on
# purpose, and copied somewhere persistent (rather than built straight out
# of /tmp) so the source is still there afterward if anyone wants to poke
# at it or rebuild by hand. The actual build happens later, once the
# packages below (zig, freetype2, ...) are installed.
mkdir -p ~/.local/share/simpbar
rm -rf ~/.local/share/simpbar/simpbar
cp -r /tmp/simpbar-temp/simpbar-main/simpbar ~/.local/share/simpbar/simpbar
ok "simpbar source placed in ~/.local/share/simpbar/simpbar"

# simpbar-shell (desktop widgets) is source like the bar, staged beside it so
# its build.zig can import the bar's font/logging modules over ../simpbar/...
if [ ! -d "/tmp/simpbar-temp/simpbar-main/simpbar-shell" ]; then
    rm -rf /tmp/simpbar-temp
    die "Downloaded archive did not contain a simpbar-shell/ directory — layout may have changed upstream."
fi
rm -rf ~/.local/share/simpbar/simpbar-shell
cp -r /tmp/simpbar-temp/simpbar-main/simpbar-shell ~/.local/share/simpbar/simpbar-shell
ok "simpbar-shell source placed in ~/.local/share/simpbar/simpbar-shell"

# The bar's config-pin icon stages with the sources: the /tmp archive is
# cleaned below to free space for package installs and builds, long before
# the .desktop/icon step runs — referencing the archive there always misses.
mkdir -p ~/.local/share/simpbar/assets/icons
if cp /tmp/simpbar-temp/simpbar-main/assets/icons/simpbar-config.svg ~/.local/share/simpbar/assets/icons/ 2>/dev/null; then
    ok "simpbar-config icon staged"
else
    warn "simpbar-config.svg missing from the repo checkout (bar pin falls back to text)"
fi
# Same deal for the welcome-pin icon (bird logo SVG, traced from the
# pasted PNG master — vectors scale to any size, so it lives in scalable/).
if cp /tmp/simpbar-temp/simpbar-main/assets/icons/simpbar-welcome.svg ~/.local/share/simpbar/assets/icons/ 2>/dev/null; then
    ok "simpbar-welcome icon staged"
else
    warn "simpbar-welcome.svg missing from the repo checkout (welcome pin falls back to theme icon)"
fi

# simpbar-matugen (the wallpaper→Material You recolor helper, tracked at the
# repo root alongside the source) is staged beside the source now while the
# archive is still around — the matugen section lower down installs it to
# /usr/bin. It's a single file, not part of the source tree, so it needs its
# own copy line here.
if [ ! -f "/tmp/simpbar-temp/simpbar-main/simpbar-matugen" ]; then
    rm -rf /tmp/simpbar-temp
    die "Downloaded archive did not contain simpbar-matugen — layout may have changed upstream."
fi
cp /tmp/simpbar-temp/simpbar-main/simpbar-matugen ~/.local/share/simpbar/simpbar-matugen

# The wallpaper engine and its login-time restore, same deal: single files at
# the repo root, staged here while the archive still exists.
for f in simpbar-wallpaper simpbar-restore-wallpaper; do
    if [ ! -f "/tmp/simpbar-temp/simpbar-main/$f" ]; then
        rm -rf /tmp/simpbar-temp
        die "Downloaded archive did not contain $f — layout may have changed upstream."
    fi
    cp "/tmp/simpbar-temp/simpbar-main/$f" ~/.local/share/simpbar/
done

# The app drawer's QML and its toggle script. Staged under ~/.local/share/simpbar
# (NOT /tmp/simpbar-temp, which is deleted on the next line, and NOT ~/.config,
# because the drawer needs quickshell, which isn't installed until Step 4).
if [ ! -d "/tmp/simpbar-temp/simpbar-main/quickshell/appdrawer" ]; then
    rm -rf /tmp/simpbar-temp
    die "Downloaded archive did not contain quickshell/appdrawer/ — layout may have changed upstream."
fi
rm -rf ~/.local/share/simpbar/appdrawer
cp -r /tmp/simpbar-temp/simpbar-main/quickshell/appdrawer ~/.local/share/simpbar/appdrawer

if [ ! -f "/tmp/simpbar-temp/simpbar-main/appdrawer" ]; then
    rm -rf /tmp/simpbar-temp
    die "Downloaded archive did not contain the appdrawer script — layout may have changed upstream."
fi
cp /tmp/simpbar-temp/simpbar-main/appdrawer ~/.local/share/simpbar/appdrawer-bin

if [ ! -f "/tmp/simpbar-temp/simpbar-main/appdrawer.desktop" ]; then
    rm -rf /tmp/simpbar-temp
    die "Downloaded archive did not contain appdrawer.desktop — layout may have changed upstream."
fi
cp /tmp/simpbar-temp/simpbar-main/appdrawer.desktop ~/.local/share/simpbar/appdrawer.desktop

rm -rf /tmp/simpbar-temp

# ── Step 5: set up Chaotic-AUR ─────────────────────────────────────
step "Setting up ${REPO_NAME}"

# ── Chaotic-AUR ─────────────────────────────────────────────────
if grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
    ok "Chaotic-AUR already configured"
else
    # Keyservers flake — retry a few times before giving up (recv-key
    # is idempotent, so retries are safe).
    _key_ok=0
    for _try in 1 2 3; do
        if run_spinner "Importing Chaotic-AUR signing key (attempt $_try/3)" \
            sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com; then
            _key_ok=1
            break
        fi
        [ "$_try" -lt 3 ] && spin_sleep 5
    done
    [ "$_key_ok" = 1 ] || die "Failed to import the Chaotic-AUR signing key."

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

# ── AUR-helper safety net ───────────────────────────────────────
# The base installer is supposed to leave an AUR helper in place (paru/yay
# from Chaotic-AUR). If that step was skipped — e.g. a transient Chaotic
# CDN/keyserver outage during provisioning — grab paru from the repo now,
# so nothing downstream unexpectedly lands on the build-from-AUR path.
if [ "$XERO_SYSTEM" = 1 ] && ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
    if run_spinner "AUR helper: paru (from Chaotic-AUR)" \
        bash -c "sudo pacman -Sy --noconfirm >/dev/null 2>&1; sudo pacman -S --noconfirm --needed paru"; then
        ok "AUR helper: paru"
    else
        warn "Could not install paru from Chaotic-AUR — it will be built on demand if AUR packages are needed"
    fi
fi

# ── Step 6: install packages ─────────────────────────────────────────
# Graphics: the official Mesa Vulkan stack is pinned explicitly below (see the
# `PACMAN_PKGS+=` for the Vulkan ICDs). There is deliberately no GPU detection:
# pinning the official ICDs keeps pacman from pulling a conflicting mesa-git /
# lib32-mesa-git that aborts the whole transaction ("Remove mesa? [Y/n]"
# answered N by --noconfirm); radeon/intel cover real hardware and swrast
# covers GPU-less machines (test VMs), so the same fixed set works everywhere.
step "Installing packages"

# The lib32 graphics stack below lives in the multilib repo, which isn't
# enabled by default.
if ! grep -Pzoq '(?m)^\[multilib\]\nInclude' /etc/pacman.conf 2>/dev/null; then
    warn "multilib repo not enabled — enabling it for the lib32 graphics stack"
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    if ! grep -Pzoq '(?m)^\[multilib\]\nInclude' /etc/pacman.conf 2>/dev/null; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    run_spinner "Syncing package databases" sudo pacman -Sy \
        || die "Failed to sync package databases after enabling multilib."
fi

# freetype2, gdk-pixbuf2, wayland, wayland-protocols, playerctl are
# simpbar's build/runtime deps (Wayland client + layer-shell, FreeType glyph
# rendering, gdk-pixbuf for tray icon-name decode, and the mpris source it
# shells out to) — all official-repo, no AUR needed. Zig itself is handled by
# ensure_zig_016 below, which pins the 0.16 API this tree builds against
# instead of trusting whatever version the distro currently ships. pacman-contrib
# (checkupdates) and wireplumber (wpctl) were already here for other
# reasons but simpbar's pacman-update-count and volume widgets need them too.
# grim + slurp + wl-clipboard + libnotify + gawk cover the screenshot binds
# (region/window/fullscreen capture, clipboard copy via wl-copy, notify-send
# for the toast, and awk to parse the compositor's active-window info for the
# window-only capture) — the binds are spelled the same in hyprland.lua and
# the shipped mango keybinds.conf. gawk ships in Arch's base group already on
# almost every install, but it's listed explicitly rather than assumed.
# quickshell (official extra repo) runs the app drawer panel. Plain Qt6/QML
# cannot do this: layer-shell support lives in quickshell's QtWayland fork
# rather than upstream qt6-wayland, so a hand-rolled QML panel has no way to
# make a layer-shell surface at all. See the "App drawer" section below for
# what actually gets deployed.
# brightnessctl backs both WMs' XF86MonBrightness* binds.
# gnome-keyring backs both file managers' remote-share auth (nautilus/nemo
# network mounts, dolphin via kio's credentials dialogue) and anything
# storing secrets (secret-service D-Bus API); the PAM auto-unlock lines go
# in at Step 8.
PACMAN_PKGS=(freetype2 gdk-pixbuf2 wayland wayland-protocols playerctl mate-polkit swaybg ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji fastfetch neovim swaync rofi flatpak bazaar nwg-look pavucontrol cava pipewire pipewire-pulse wireplumber gnome-disk-utility polkit-gnome gnome-keyring grim slurp wlr-randr cliphist wl-clipboard python-gobject gtk4 libadwaita pacman-contrib libnotify nwg-drawer qt6ct breeze gawk kdeconnect quickshell brightnessctl)

# Official Mesa Vulkan stack — see the Step 6 header: pinning these keeps
# pacman from resolving the vulkan-driver virtuals to a conflicting mesa-git.
# Skipped on XeroLinux-provisioned systems: Xero's own graphics-driver step
# already set up mesa + the vendor stack (possibly custom bundles that
# conflict with official mesa).
if [ "$XERO_SYSTEM" = 1 ]; then
    ok "Graphics drivers skipped (covered by the Xero install)"
else
    PACMAN_PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-intel lib32-vulkan-intel vulkan-swrast lib32-vulkan-swrast)
fi

# The compositor itself plus its desktop portal, chosen in Step 2. MangoWM
# also needs the apps the shipped mango config starts/binds on login
# (alacritty terminal, easyeffects from autostart).
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    PACMAN_PKGS+=(hyprland xdg-desktop-portal-hyprland)
else
    PACMAN_PKGS+=(mangowm xdg-desktop-portal-wlr xdg-desktop-portal-gtk)
    # NOTE: no terminal here — TERMINAL_CHOICE below adds exactly one, so
    # mango's old hardcoded alacritty doesn't double-install or fight the pick.
    PACMAN_PKGS+=(easyeffects)
fi

if reuse_detected FILE_MANAGER_CHOICE '1:nautilus' '2:nemo' '3:dolphin'; then
    FILE_MANAGER_DETECTED=1
else
    FILE_MANAGER_DETECTED=0
    prompt_choice FILE_MANAGER_CHOICE 1 "Which file manager would you like to use?" \
        "Nautilus" "Nemo" "Dolphin"
fi
case "$FILE_MANAGER_CHOICE" in
    2) FILE_MANAGER_NAME="Nemo";    FILE_MANAGER_BIN="nemo";    PACMAN_PKGS+=(nemo) ;;
    3) FILE_MANAGER_NAME="Dolphin"; FILE_MANAGER_BIN="dolphin"; PACMAN_PKGS+=(dolphin) ;;
    *) FILE_MANAGER_NAME="Nautilus"; FILE_MANAGER_BIN="nautilus"; PACMAN_PKGS+=(nautilus) ;;
esac
[ "$FILE_MANAGER_DETECTED" = 1 ] && detected_note "File manager" "$FILE_MANAGER_NAME"

# Archive companions ride the file-manager pick so archive extracting is
# covered out of the box: the GTK pair (nautilus/nemo) gets file-roller's
# extract-here integration, KDE's dolphin gets its ark counterpart.
if [ "$FILE_MANAGER_CHOICE" = 3 ]; then
    PACMAN_PKGS+=(ark)
    ARCHIVER_NAME="Ark"
else
    PACMAN_PKGS+=(file-roller)
    ARCHIVER_NAME="File Roller"
fi

# Point whichever config the chosen WM ships at the picked file manager.
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    # hyprland.lua (copied to ~/.config/hypr in Step 4) hardcodes its
    # fileManager variable to nautilus — point it at whichever one was chosen.
    if [ -e ~/.config/hypr/hyprland.lua ]; then
        sed -i "s/^local fileManager = \".*\"/local fileManager = \"$FILE_MANAGER_BIN\"/" ~/.config/hypr/hyprland.lua
    fi
else
    # The shipped mango keybinds.conf binds SUPER+E to dolphin — match it to
    # the user's pick so the bind works regardless of the choice above.
    # (SUPER+Return and the keybind viewer follow TERMINAL_CHOICE in the
    # WM fixup block further down — the prompt hasn't run yet here.)
    if [ -e ~/.config/mango/cfg/keybinds.conf ]; then
        sed -i "s/bind = SUPER, e, spawn, dolphin/bind = SUPER, e, spawn, $FILE_MANAGER_BIN/" ~/.config/mango/cfg/keybinds.conf
    fi
fi

if reuse_detected TERMINAL_CHOICE '1:kitty' '2:foot' '3:ghostty' '4:alacritty' '5:wezterm' '6:konsole' '7:ptyxis'; then
    TERMINAL_DETECTED=1
else
    TERMINAL_DETECTED=0
    prompt_choice TERMINAL_CHOICE 4 "Which terminal emulator would you like to use?" \
        "Kitty" "Foot" "Ghostty" "Alacritty" "WezTerm" "Konsole" "Ptyxis"
fi
case "$TERMINAL_CHOICE" in
    # CLASS is the Wayland app-id the Hyprland float rule matches. The last
    # three are best-effort (reverse-DNS ids): a miss only skips the float
    # rule, the terminal itself always launches.
    1) TERMINAL_NAME="Kitty";     TERMINAL_BIN="kitty";     TERMINAL_PKG="kitty";     TERMINAL_CLASS="kitty";               TERMINAL_E="" ;;
    2) TERMINAL_NAME="Foot";      TERMINAL_BIN="foot";      TERMINAL_PKG="foot";      TERMINAL_CLASS="foot";                TERMINAL_E="-e" ;;
    3) TERMINAL_NAME="Ghostty";   TERMINAL_BIN="ghostty";   TERMINAL_PKG="ghostty";   TERMINAL_CLASS="ghostty";             TERMINAL_E="-e" ;;
    4) TERMINAL_NAME="Alacritty"; TERMINAL_BIN="alacritty"; TERMINAL_PKG="alacritty"; TERMINAL_CLASS="Alacritty";           TERMINAL_E="-e" ;;
    5) TERMINAL_NAME="WezTerm";   TERMINAL_BIN="wezterm";   TERMINAL_PKG="wezterm";   TERMINAL_CLASS="wezterm";             TERMINAL_E="-e" ;;
    6) TERMINAL_NAME="Konsole";   TERMINAL_BIN="konsole";   TERMINAL_PKG="konsole";   TERMINAL_CLASS="org.kde.konsole";     TERMINAL_E="-e" ;;
    7) TERMINAL_NAME="Ptyxis";    TERMINAL_BIN="ptyxis";    TERMINAL_PKG="ptyxis";    TERMINAL_CLASS="app.ptyxis.Terminal"; TERMINAL_E="-e" ;;
    *) TERMINAL_NAME="Foot";      TERMINAL_BIN="foot";      TERMINAL_PKG="foot";      TERMINAL_CLASS="foot";                TERMINAL_E="-e" ;;
esac
PACMAN_PKGS+=("$TERMINAL_PKG")
[ "$TERMINAL_DETECTED" = 1 ] && detected_note "Terminal emulator" "$TERMINAL_NAME"

# Persist the pick for the GTK apps: every terminal-bound action in
# simpbar-welcome (script launches, package installs) runs in whichever
# terminal this file names rather than assuming foot. Format: one line,
# "<binary>[ <exec-flag>]" — the flag separates the terminal's own options
# from the command ("foot -e", "kitty" takes it bare).
mkdir -p ~/.config/simpbar
printf '%s\n' "$TERMINAL_BIN${TERMINAL_E:+ $TERMINAL_E}" > ~/.config/simpbar/terminal

# Point whichever config the chosen WM ships at the picked terminal.
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    # hyprland.lua (copied to ~/.config/hypr in Step 4) hardcodes its
    # terminal variable to foot — point it and the float rule's app-id at
    # whichever one was chosen. The class match is the only line of its
    # shape, so this can't touch other rules.
    if [ -e ~/.config/hypr/hyprland.lua ]; then
        sed -i "s/^local terminal = \".*\"/local terminal = \"$TERMINAL_BIN\"/" ~/.config/hypr/hyprland.lua
        sed -i "s/^\tname = \"foot\",/\tname = \"$TERMINAL_CLASS\",/" ~/.config/hypr/hyprland.lua
        sed -i "s/match = { class = \"foot\" }/match = { class = \"$TERMINAL_CLASS\" }/" ~/.config/hypr/hyprland.lua
    fi
else
    # The shipped mango keybinds.conf binds SUPER+Return to alacritty —
    # match it and the keybind viewer to the pick. The viewer keeps a pager
    # flag for terminals that take `-e` (kitty runs its command bare).
    if [ -e ~/.config/mango/cfg/keybinds.conf ]; then
        sed -i "s/^bind = SUPER, Return, spawn, .*/bind = SUPER, Return, spawn, $TERMINAL_BIN/" ~/.config/mango/cfg/keybinds.conf
        sed -i "s|spawn, .* less __HOME__/.config/mango/cfg/keybinds.conf|spawn, $TERMINAL_BIN${TERMINAL_E:+ $TERMINAL_E} less __HOME__/.config/mango/cfg/keybinds.conf|" ~/.config/mango/cfg/keybinds.conf
    fi
fi

# NOTE: OBS Studio and video-editor prompts used to live here. They were
# removed outright (not gated): neither is needed for the desktop to
# function, and anyone who wants one installs it directly. Saved
# OBS_CHOICE / VIDEO_EDITOR_* answers in install-answers are now inert.
# NOTE: the Lutris/Heroic game-launcher prompt used to live here. It was
# removed outright (not gated): gaming launchers (Steam, Lutris, Heroic) are
# picked in the Xero installer's GAMING category, so asking again here would
# fight it. Saved LAUNCHER_CHOICE answers in install-answers are now inert.

if [ "$XERO_SYSTEM" = 1 ]; then
    # Xero's Phase 2 covers Discord clients — skip the question and the
    # install entirely (pin seeding below sees the empty name and skips).
    DISCORD_DETECTED=0
    DISCORD_NAME=""
    DISCORD_AUR_PKG=""
else
if reuse_detected DISCORD_CHOICE '1:discord' '2:vesktop-bin' '3:equibop-bin equibop'; then
    DISCORD_DETECTED=1
else
    DISCORD_DETECTED=0
    prompt_choice DISCORD_CHOICE 4 "Which Discord client would you like to install?" \
        "Discord" "Vesktop" "Equibop" "Skip — don't install a Discord client"
fi

DISCORD_AUR_PKG=""
case "$DISCORD_CHOICE" in
    1) DISCORD_NAME="Discord"; PACMAN_PKGS+=(discord) ;;
    2) DISCORD_NAME="Vesktop"; DISCORD_AUR_PKG="vesktop-bin" ;;
    3) DISCORD_NAME="Equibop"
       # Either installed twin satisfies the choice — installing the other
       # would conflict-abort the whole batch (pacman can't resolve [y/N]
       # under --noconfirm), so install nothing in that case. Otherwise
       # prefer the repo package name (Chaotic-AUR ships `equibop`; bare
       # `-bin` only exists in the AUR) with the AUR name as fallback.
       if pacman -Qq equibop >/dev/null 2>&1 || pacman -Qq equibop-bin >/dev/null 2>&1; then DISCORD_AUR_PKG=""
       elif pacman -Si equibop >/dev/null 2>&1; then DISCORD_AUR_PKG="equibop"
       else DISCORD_AUR_PKG="equibop-bin"; fi ;;
    *) DISCORD_NAME="" ;;
esac
[ "$DISCORD_DETECTED" = 1 ] && [ -n "$DISCORD_NAME" ] && detected_note "Discord client" "$DISCORD_NAME"
fi

printf '\n  %smatugen%s is the Material You colorscheme generator simpbar uses for\n' "$C_BOLD" "$C_RESET"
printf '  auto-theming: pick a wallpaper and it recolors the bar to match it\n'
printf '  (the bar has an %sAuto-theme with matugen%s toggle in simpbar-config).\n' "$C_BOLD" "$C_RESET"
printf '  It is AUR-only and compiled from source, so it is the slowest install step.\n'
# NOTE: matugen used to be a Yes/No prompt. It is now always installed:
# auto-theming is core to the bar, not optional. A saved MATUGEN_CHOICE
# answer in install-answers is inert.
if reuse_detected MATUGEN_CHOICE '1:matugen'; then
    MATUGEN_DETECTED=1
else
    MATUGEN_DETECTED=0
fi
INSTALL_MATUGEN=1
[ "$MATUGEN_DETECTED" = 1 ] && detected_note "matugen" "matugen"

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

# The source tree targets Zig 0.16 (build.zig.zon's minimum_zig_version).
# Do not trust the distro's current package: it may be a different API level
# and lack std.fmt.bufPrintZ, which this tree and its wayland scanner still
# use, while older ones lack other 0.16 APIs. Use a cached/system 0.16.0 when
# present, otherwise fetch the official 0.16.0 tarball into the user's
# simpbar data dir and put it first on PATH for both build steps. Pin the
# exact release: a 0.16.0-dev snapshot can predate bufPrintZ being restored.
ensure_zig_016() {
    local want="0.16.0"
    local zigdir="$HOME/.local/share/simpbar/zig-$want"
    local parent="$HOME/.local/share/simpbar"
    local arch url tarball extracted

    if [ -x "$zigdir/zig" ] \
       && [ "$("$zigdir/zig" version 2>/dev/null || true)" = "$want" ]; then
        export PATH="$zigdir:$PATH"
        ok "Using cached Zig $("$zigdir/zig" version)"
        return 0
    fi

    if command -v zig >/dev/null 2>&1; then
        local system_version system_std
        system_version=$(zig version 2>/dev/null || true)
        system_std=$(zig env 2>/dev/null \
            | sed -n 's/^[[:space:]]*\.std_dir = "\(.*\)",$/\1/p' \
            | head -n1) || system_std=""
        # Version alone is not enough: a broken/partial install can report
        # 0.16.0 while its stdlib no longer has the API this tree needs.
        if [ "$system_version" = "$want" ] \
           && [ -n "$system_std" ] \
           && grep -q 'pub fn bufPrintZ' "$system_std/fmt.zig" 2>/dev/null; then
            ok "Using system Zig $system_version"
            return 0
        fi
        warn "System Zig is ${system_version:-unknown} without the 0.16 std.fmt API; installing pinned Zig $want for the build"
    fi

    case "$(uname -m)" in
        x86_64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) die "Unsupported architecture for Zig $want: $(uname -m)" ;;
    esac

    mkdir -p "$parent" \
        || die "Could not create $parent"
    tarball="$parent/zig-$want.tar.xz"
    url="https://ziglang.org/download/$want/zig-$arch-linux-$want.tar.xz"
    extracted="$parent/zig-$arch-linux-$want"

    run_spinner "Downloading Zig $want" \
        curl -fL --retry 3 -o "$tarball" "$url" \
        || { rm -f "$tarball"; die "Could not download Zig $want from $url"; }

    rm -rf "$extracted" "$zigdir"
    run_spinner "Extracting Zig $want" \
        tar -xJf "$tarball" -C "$parent" \
        || { rm -f "$tarball"; die "Could not extract Zig $want"; }
    rm -f "$tarball"

    if [ ! -x "$extracted/zig" ]; then
        die "Zig archive did not contain $extracted/zig"
    fi
    mv "$extracted" "$zigdir" \
        || die "Could not move Zig $want into $zigdir"
    if [ "$("$zigdir/zig" version 2>/dev/null || true)" != "$want" ]; then
        die "Downloaded Zig at $zigdir is not version $want"
    fi
    export PATH="$zigdir:$PATH"
    ok "Using pinned Zig $("$zigdir/zig" version) from $zigdir"
}

ensure_zig_016

# Build simpbar (the bar) and simpbar-welcome (the GTK4 + libadwaita
# companion app) from the source placed in ~/.local/share/simpbar/simpbar
# back in Step 2, now that zig/freetype2/gdk-pixbuf2/wayland-protocols/gtk4/
# libadwaita are actually installed. build.zig defines both as executables
# under the default install step, so this one invocation builds both. A
# release build (not the plain debug build simpbar's own dev workflow
# uses) — this is what ends up running on every login.
run_spinner "Building simpbar" bash -c 'cd ~/.local/share/simpbar/simpbar && zig build -Doptimize=ReleaseFast' \
    || die "Failed to build simpbar — check zig, freetype2, gdk-pixbuf2, wayland, wayland-protocols, gtk4, and libadwaita installed correctly."

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

# Build simpbar-shell (the desktop widgets) too — same zig, against the bar's
# source layout it was staged next to above. Autostarted on login by whichever
# WM was chosen (hyprland.lua or the mango autostart.conf).
run_spinner "Building simpbar-shell" bash -c 'cd ~/.local/share/simpbar/simpbar-shell && zig build -Doptimize=ReleaseFast' \
    || die "Failed to build simpbar-shell — check zig, freetype2, gdk-pixbuf2, wayland, and wayland-protocols installed correctly."

run_spinner "Installing simpbar-shell to /usr/bin" \
    sudo install -Dm755 ~/.local/share/simpbar/simpbar-shell/zig-out/bin/simpbar-shell /usr/bin/simpbar-shell \
    || die "Failed to install the simpbar-shell binary to /usr/bin."
ok "simpbar-shell built and installed to /usr/bin/simpbar-shell"

# Seed the calendar widget's reminders file with its format reference on
# first install (the widget appends it on demand too — this just documents
# the line format for anyone editing it by hand).
if [ ! -f ~/.config/simpbar/reminders.txt ]; then
    mkdir -p ~/.config/simpbar
    cat > ~/.config/simpbar/reminders.txt <<'REMIN'
# Reminders — one per line: YYYY-MM-DD HH:MM lead text
#   lead = days before the date to notify (0 = on the day)
# Click a day on the calendar card to add/remove via rofi.
REMIN
    ok "Seeded ~/.config/simpbar/reminders.txt (calendar reminder format)"
fi

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


# protonplus etc. used to mean an AUR helper — with Chaotic-AUR
# enabled most of these are now binary packages, so they install
# through pacman from the chosen repo, and yay/paru are only reached for the
# stragglers the repo doesn't carry. wlogout is deliberately gone: the app
# drawer's Power menu (bar power button / SUPER+SHIFT+Q) replaces it.
# waypaper is deliberately gone too: the app drawer's wallpaper tab owns
# picking now (see the Wallpaper Button tombstone in the bar source). Users
# who already have waypaper keep it working — nothing here uninstalls it.
AUR_PKGS=(protonplus bibata-cursor-theme game-devices-udev)
[ -n "$DISCORD_AUR_PKG" ] && AUR_PKGS+=("$DISCORD_AUR_PKG")
[ "$INSTALL_MATUGEN" -eq 1 ] && AUR_PKGS+=(matugen)

printf '  Installing %d packages (%s first, AUR helper only if needed):\n    %s\n' "${#AUR_PKGS[@]}" "$REPO_NAME" "${AUR_PKGS[*]}"
install_repo_or_aur "${AUR_PKGS[@]}" \
    || warn "Some packages were not installed — install them manually if needed"

MISSING_AUR=()
for pkg in "${AUR_PKGS[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || MISSING_AUR+=("$pkg")
done
if [ "${#MISSING_AUR[@]}" -gt 0 ]; then
    warn "Packages not installed: ${MISSING_AUR[*]} — install manually if needed"
else
    ok "Verified all requested packages are installed"
fi


if pacman -Qq game-devices-udev >/dev/null 2>&1; then
    run_spinner "Reloading udev rules for game controllers" \
        sudo bash -c 'udevadm control --reload-rules && udevadm trigger' \
        || warn "Could not reload udev rules — replug your controller or reboot for the new rules to apply"
fi

# Download today's Bing wallpaper — through the wallpaper engine, not by
# parsing Bing's JSON here.
#
# The engine already does exactly this, and does it better: it falls back from
# Bing's undocumented UHD URL to the standard crop, checks that what came back
# is really an image rather than Bing's 1192-byte 1x1 placeholder for an unknown
# id, refuses to re-download a wallpaper already on disk, and only ever creates
# the file atomically. A second copy of that logic here is precisely how the
# installer's idea of "today's wallpaper" and the engine's would drift apart —
# the same class of bug this repo keeps removing.
WALLPAPER_DIR="$HOME/Pictures/Wallpaper"
mkdir -p "$WALLPAPER_DIR"

WALLPAPER_ENGINE="$HOME/.local/share/simpbar/simpbar-wallpaper"
BING_FILE=""
BING_TMP=$(mktemp)
if [ -x "$WALLPAPER_ENGINE" ] \
   && run_spinner "Downloading today's Bing wallpaper via the wallpaper engine" \
        bash -c "'$WALLPAPER_ENGINE' bing > '$BING_TMP' 2>>'$BING_TMP.err'"; then
    BING_FILE=$(head -n1 "$BING_TMP")
    rm -f "$BING_TMP.err"
fi
rm -f "$BING_TMP"

if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    ok "Bing wallpaper ready ($(basename "$BING_FILE"))"
else
    BING_FILE=""
    warn "Could not download today's Bing wallpaper — nothing is wrong, the wallpaper engine simply starts empty"
    printf '       %sFetch one any time with:%s simpbar-wallpaper bing\n' "$C_BOLD" "$C_RESET"
fi

# One owner for the wallpaper. This used to hand login to a swaybg.service
# unit with $BING_FILE baked into ExecStart, which cannot express "whatever the
# user last picked" — every wallpaper change made it stale, and its
# Restart=on-failure meant killing it could resurrect the Bing picture over the
# top of a new choice. simpbar-wallpaper now keeps the path in
# ~/.config/simpbar/wallpaper and simpbar-restore-wallpaper reads that at login,
# so the picked wallpaper is what comes back.
#
# Any swaybg.service left over from a previous install is stopped and disabled:
# it is the one thing that could fight the engine for the same surface.
if systemctl --user list-unit-files swaybg.service >/dev/null 2>&1 \
   && systemctl --user is-enabled swaybg.service >/dev/null 2>&1; then
    run_spinner "Handing the wallpaper over from swaybg.service to simpbar-wallpaper" \
        bash -c 'systemctl --user disable --now swaybg.service 2>/dev/null || true' \
        || warn "Could not disable swaybg.service — disable it yourself, or it may reassert the old wallpaper"
    ok "swaybg.service disabled so it cannot fight the wallpaper engine"
fi

if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    # Seed the engine's state with today's download so the very first login
    # already restores it. Never overwrites an existing path: re-running the
    # installer must not undo wallpapers the user has since picked.
    mkdir -p ~/.config/simpbar
    if [ -r ~/.config/simpbar/wallpaper ]; then
        ok "Keeping your remembered wallpaper ($(sed -n 's/^path=//p' ~/.config/simpbar/wallpaper | head -n1))"
    else
        printf 'path=%s\nfill=fill\ncolor=#ffffff\n' "$BING_FILE" > ~/.config/simpbar/wallpaper
        ok "swaybg will restore today's Bing wallpaper at login (remembered in ~/.config/simpbar/wallpaper)"
    fi
else
    warn "No downloaded wallpaper — the wallpaper engine starts empty; pick one whenever you like"
fi


# The wallpaper-switcher repo used to be downloaded here and shelled out to for
# the bar's wallpaper button. It is gone on purpose: it drives swww + pywal, not
# swaybg + matugen, so it theming-wise disagreed with everything else on the
# desktop, and it kept its own copy of the images. The engine in this repo does
# the same job against swaybg and matugen and shares one wallpaper folder.

# matugen — the Material You colorscheme generator simpbar reads for
# wallpaper-based auto-theming. It renders its simpbar template to
# ~/.config/simpbar/matugen.json, which the bar merges in on reload;
# simpbar-wallpaper re-runs it whenever the wallpaper changes.
# matugen never sets the wallpaper itself (the [config.wallpaper] block below
# keeps set = false), so simpbar-wallpaper stays the sole owner of it.
if [ "$INSTALL_MATUGEN" -eq 1 ]; then
    if pacman -Qq matugen >/dev/null 2>&1; then
        mkdir -p ~/.config/matugen/templates

        if [ -e ~/.config/matugen/config.toml ]; then
            warn "~/.config/matugen/config.toml already exists — leaving your existing matugen config alone"
            # Migrate pre-fix Steam skin paths: older configs wrote to
            # ~/.steam/steam/millennium/..., which creates ~/.steam/steam as a
            # real directory on fresh installs and breaks Steam with
            # "Couldn't set up Steam data" (bin_steam.sh needs it to be a
            # symlink to ~/.local/share/Steam). New path works with or without
            # the symlink.
            if grep -q '\.steam/steam/millennium' ~/.config/matugen/config.toml 2>/dev/null; then
                sed -i 's|~/.steam/steam/millennium|~/.local/share/Steam/millennium|g' ~/.config/matugen/config.toml 2>/dev/null || true
                ok "migrated Steam skin paths in matugen config to ~/.local/share/Steam"
            fi
        else
            warn "matugen config missing — copying from repo's full config"
            cp "/tmp/simpbar-temp/simpbar-main/matugen/config.toml" ~/.config/matugen/config.toml 2>/dev/null || true
            ok "matugen config placed in ~/.config/matugen/config.toml"
        fi

        # simpbar template is in repo; ensure it's present
        if [ ! -e ~/.config/matugen/templates/simpbar.json ]; then
            cp "/tmp/simpbar-temp/simpbar-main/matugen/simpbar.json" ~/.config/matugen/templates/simpbar.json 2>/dev/null || true
            ok "simpbar template placed in ~/.config/matugen/templates/simpbar.json"
        else
            warn "~/.config/matugen/templates/simpbar.json already exists — leaving your existing template alone"
        fi

        # The helper normally comes from the downloaded archive (staged
        # beside the simpbar source in Step 2). Fall back to an embedded copy
        # if that ever didn't happen (e.g. this script run from an older
        # Installed from the repo copy rather than an inline heredoc. A second,
        # drifting copy of this script is exactly how it ended up disagreeing
        # with the engine about which wallpaper was current.
        run_spinner "Installing simpbar-matugen to /usr/bin" \
            sudo install -Dm755 ~/.local/share/simpbar/simpbar-matugen /usr/bin/simpbar-matugen \
            || warn "Could not install the simpbar-matugen helper to /usr/bin"

        if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
            # Never let this step wedge the installer: run_spinner hides all
            # output until failure, so if matugen stops to prompt (missing
            # prefer/fallback in an older config.toml) or blocks on its
            # network version check, the prompt is invisible and the install
            # waits forever. Closing stdin turns any prompt into an instant
            # EOF error; the 45 s cap (a healthy run takes <1 s) guarantees
            # progress either way, and a failure prints matugen's captured
            # output so the real cause is visible.
            # Pre-fix guard: remove a blocking ~/.steam/steam real directory
            # (left by old configs) so the initial matugen run + later Steam
            # launch can't hit "Couldn't set up Steam data". Real Steam data
            # lives in ~/.local/share/Steam; this dir only ever held skins.
            if [ -e "$HOME/.steam/steam" ] && [ ! -L "$HOME/.steam/steam" ]; then
                [ -d "$HOME/.steam/steam/millennium" ] && {
                    mkdir -p "$HOME/.local/share/Steam" 2>/dev/null || true
                    cp -a "$HOME/.steam/steam/millennium/." "$HOME/.local/share/Steam/millennium/" 2>/dev/null || true
                }
                [ -L "$HOME/.steam/steam/Steam" ] && rm -f "$HOME/.steam/steam/Steam" 2>/dev/null || true
                rm -rf "$HOME/.steam/steam" 2>/dev/null || true
                warn "removed blocking ~/.steam/steam directory (Steam needs it to be a symlink)"
            fi
            [ ! -e "$HOME/.steam/steam" ] && [ -d "$HOME/.local/share/Steam" ] && ln -sfn "$HOME/.local/share/Steam" "$HOME/.steam/steam" 2>/dev/null || true
            run_spinner "Generating the initial matugen scheme from the Bing wallpaper" \
                timeout 45 bash -c '"$0" "$@" </dev/null' /usr/bin/simpbar-matugen "$BING_FILE" \
                || warn "Could not generate the initial matugen scheme — it'll apply on the next wallpaper change"
        else
            warn "No wallpaper available for the initial matugen scheme — the bar keeps its configured colors until you pick a wallpaper"
        fi
    else
        warn "matugen isn't installed — skipping matugen setup (install manually: yay -S matugen)"
    fi
fi

# Apply the Bibata cursor theme, now that it's actually installed. This
# uses the same gsettings mechanism nwg-look reads/writes, so it shows up
# as already selected there too.

if pacman -Qq bibata-cursor-theme >/dev/null 2>&1 && command -v gsettings >/dev/null; then
    run_spinner "Applying Bibata Modern Classic cursor" \
        gsettings set org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Classic' \
        || warn "Could not apply the cursor theme — select it manually in nwg-look"
elif ! pacman -Qq bibata-cursor-theme >/dev/null 2>&1; then
    warn "bibata-cursor-theme isn't installed — skipping cursor theme apply"
else
    warn "gsettings not found — select the Bibata cursor theme manually in nwg-look"
fi

# User drop-in dirs for simpbar-config's theme pickers: cursor themes land
# in ~/.cursors, GTK themes in ~/.themes (both scanned first, ahead of the
# XDG/system locations). Empty by default — just a discoverable place.
mkdir -p ~/.cursors ~/.themes 2>/dev/null || true

# qt6ct is the Qt6 settings app; QT_QPA_PLATFORMTHEME=qt6ct (set in the chosen
# WM's env — hyprland.lua or the mango env.conf) is what makes Qt6 apps read
# its config instead of falling back to their own default style. breeze ships
# both the Breeze widget style and the BreezeDark.colors scheme qt6ct points
# at below.
BREEZE_DARK_SCHEME="/usr/share/color-schemes/BreezeDark.colors"
if pacman -Qq qt6ct >/dev/null 2>&1 && pacman -Qq breeze >/dev/null 2>&1; then
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

# ── App drawer (quickshell panel) ────────────────────────────────────
# An ArcMenu-style launcher that slides up from under the bar: app grid,
# categories, search, pinned favourites, and a system-actions menu, all
# themed from the same matugen.json the bar reads so the two repaint
# together on a wallpaper change. Clicking empty bar space opens it too
# (see the empty_click_command option).
#
# Three deliberate choices worth knowing before editing this:
#
#   * The QML goes to ~/.config/quickshell/appdrawer rather than /usr/share,
#     because quickshell loads configs by name from
#     $XDG_CONFIG_HOME/quickshell/<name>/shell.qml and 0.3.x has no system-wide
#     config path.
#   * The QML reads $HOME at runtime (Quickshell.env("HOME")) instead of
#     hardcoding a home directory, so this install works for any user.
#   * favourites.json (pinned apps) is NOT shipped in the repo and is NOT
#     overwritten when it already exists — it is per-user state, not config.
if command -v quickshell >/dev/null 2>&1; then
    # Where quickshell actually looks for configs: XDG_CONFIG_HOME when set,
    # ~/.config otherwise. Hardcoding ~/.config here would install the panel
    # somewhere quickshell never searches, so on a system with XDG_CONFIG_HOME
    # pointed elsewhere the drawer would silently never open. AppModel.qml
    # resolves its own path the same way, so the two always agree.
    QS_APPDRAWER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/appdrawer"
    mkdir -p "$QS_APPDRAWER_DIR"
    for qml in AppModel.qml AppTile.qml BluetoothDeviceRow.qml BluetoothPanel.qml Distro.qml Drawer.qml Icons.qml shell.qml Theme.qml WallpaperModel.qml WallpaperTile.qml WallhavenSearch.qml; do
        if [ ! -f "$HOME/.local/share/simpbar/appdrawer/$qml" ]; then
            warn "appdrawer $qml missing from the archive — the drawer may not load (skipped)"
        else
            cp "$HOME/.local/share/simpbar/appdrawer/$qml" "$QS_APPDRAWER_DIR/$qml"
        fi
    done
    ok "App drawer QML placed in $QS_APPDRAWER_DIR"

    if [ ! -f "$QS_APPDRAWER_DIR/favourites.json" ]; then
        printf '{ "ids": [] }\n' > "$QS_APPDRAWER_DIR/favourites.json"
        ok "App drawer favourites file created (empty — pin apps from the drawer)"
    else
        ok "Existing app drawer favourites kept"
    fi

    # /usr/bin (like every other helper here) rather than ~/.local/bin, so the
    # Hyprland bind and the .desktop entry can both call a bare `appdrawer`.
    # ~/.local/bin is NOT on the session PATH, and a .desktop Exec has no
    # environment-variable expansion to fall back on.
    # Checked rather than assumed: an unchecked `sudo install` still prints the
    # ok line when it fails (no set -e here), so a user without sudo rights or
    # a read-only /usr/bin would get a cheerful message and a drawer that never
    # opens. Same pattern the other helper installs below use.
    if sudo install -Dm755 ~/.local/share/simpbar/appdrawer-bin /usr/bin/appdrawer \
       && sudo install -Dm644 ~/.local/share/simpbar/appdrawer.desktop /usr/share/applications/appdrawer.desktop; then
        ok "App drawer toggle installed to /usr/bin/appdrawer"
    else
        warn "could not install to /usr/bin — put appdrawer somewhere on your PATH yourself, then point"
        warn "  empty_click_command and the SUPER+Tab bind at it"
    fi

    # Make empty-space bar clicks open the drawer. Only writes the key when
    # config.json is absent or already lacks it: the bar's own default is ""
    # (feature off), and rewriting a key the user has since changed would be
    # rude. On an existing config this needs a bar restart to take effect, so
    # say so rather than pretending it's live.
    mkdir -p ~/.config/simpbar
    if [ ! -f ~/.config/simpbar/config.json ]; then
        printf '{"appearance":{"empty_click_command":"appdrawer"}}\n' \
            > ~/.config/simpbar/config.json
        ok "Wrote ~/.config/simpbar/config.json with empty_click_command set"
    elif grep -q '"empty_click_command"' ~/.config/simpbar/config.json; then
        ok "config.json already sets empty_click_command — leaving your value alone"
    else
        warn "config.json exists but doesn't set empty_click_command — add \"empty_click_command\": \"appdrawer\" to its appearance block to enable empty-bar clicks (restart the bar after)"
    fi
else
    warn "quickshell isn't installed — skipping the app drawer. Install it with 'sudo pacman -S quickshell' and re-run this script."
    if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
        warn "  The SUPER+Tab bind in hyprland.lua and the 'App Drawer' menu entry do nothing until then."
    else
        warn "  The SUPER+Space bind in keybinds.conf and the 'App Drawer' menu entry do nothing until then."
    fi
    warn "  Empty bar clicks are unaffected: empty_click_command defaults to off."
fi

# ── Step 7: choose a browser ─────────────────────────────────────────
step "Choosing a browser"

if [ "$XERO_SYSTEM" = 1 ]; then
    # Xero's Phase 2 covers browsers (and the Firefox keep/remove choice
    # below) — skip the question and the install entirely (pin seeding
    # below sees the empty name and skips).
    BROWSER_DETECTED=0
    BROWSER_NAME=""
    BROWSER_PKG=""
else
if reuse_detected BROWSER_CHOICE '1:brave-bin' '2:zen-browser-bin' '3:vivaldi' '4:microsoft-edge-stable-bin' '5:librewolf-bin'; then
    BROWSER_DETECTED=1
else
    BROWSER_DETECTED=0
    prompt_choice BROWSER_CHOICE 6 "Which browser would you like to install?" \
        "Brave" "Zen Browser" "Vivaldi" "Microsoft Edge" "LibreWolf" "Skip — don't install a browser"
fi

case "$BROWSER_CHOICE" in
    1) BROWSER_NAME="Brave";          BROWSER_PKG="brave-bin" ;;
    2) BROWSER_NAME="Zen Browser";    BROWSER_PKG="zen-browser-bin" ;;
    3) BROWSER_NAME="Vivaldi";        BROWSER_PKG="vivaldi" ;;
    4) BROWSER_NAME="Microsoft Edge"; BROWSER_PKG="microsoft-edge-stable-bin" ;;
    5) BROWSER_NAME="LibreWolf";      BROWSER_PKG="librewolf-bin" ;;
    *) BROWSER_NAME=""; BROWSER_PKG="" ;;
esac
[ "$BROWSER_DETECTED" = 1 ] && [ -n "$BROWSER_NAME" ] && detected_note "Browser" "$BROWSER_NAME"

if [ -z "$BROWSER_NAME" ]; then
    if [ "$XERO_SYSTEM" = 1 ]; then ok "Browser install skipped (covered by the Xero install)"; else warn "Skipping browser install, as requested"; fi
else
    install_aur_pkg "$BROWSER_NAME" "$BROWSER_PKG" || true
fi

if [ -n "$BROWSER_PKG" ] && pacman -Qq "$BROWSER_PKG" >/dev/null 2>&1; then
    ok "$BROWSER_NAME installed"
fi

# Firefox often ships preinstalled — ask before touching it. The Remove
# option is marked _HAS_SKIP_ so a remembered removal never replays: that
# choice is destructive and must always be a live decision.
if pacman -Qq firefox >/dev/null 2>&1; then
    prompt_choice FIREFOX_CHOICE 1 "Firefox is currently installed. Keep it or remove it?" \
        "Keep Firefox" "Remove Firefox" _HAS_SKIP_
    case "$FIREFOX_CHOICE" in
        2)
            run_spinner "Removing Firefox" sudo pacman -Rns --noconfirm firefox \
                || warn "Could not remove Firefox — remove it manually: sudo pacman -Rns firefox"
            ;;
        1) ok "Keeping Firefox" ;;
        *) warn "Unrecognized choice — keeping Firefox" ;;
    esac
fi
fi

# ── Default bar pins ───────────────────────────────────────────────
# Seed config.json's launchers from this run's choices so a fresh install
# opens on working icon pins instead of the compiled fallbacks (which sit
# in text mode until their apps exist). Only when the file lacks launchers
# entirely — existing pins are never touched. Third-party pins probe what
# actually landed (package names like zen-browser-bin aren't commands); our
# own helpers always pin. Labels stay plain text (no nerd glyphs): with
# icons resolving, the label only shows in the GUI list.
probe_bin() {
    local b
    for b in "$@"; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '%s' "$b"
            return 0
        fi
    done
    return 1
}
SEED_PINS=()
if [ -n "$BROWSER_NAME" ]; then
    case "$BROWSER_CHOICE" in
        1) _cands="brave brave-browser" ;;
        2) _cands="zen-browser zen zen-bin" ;;
        3) _cands="vivaldi-stable vivaldi" ;;
        4) _cands="microsoft-edge-stable microsoft-edge" ;;
        5) _cands="librewolf" ;;
        *) _cands="" ;;
    esac
    # Word-splitting intended: _cands is our own literal list above.
    # shellcheck disable=SC2086
    if [ -n "$_cands" ] && BROWSER_BIN="$(probe_bin $_cands)"; then
        SEED_PINS+=("Browser|$BROWSER_BIN|$BROWSER_BIN")
    fi
fi
if [ -n "$DISCORD_NAME" ]; then
    case "$DISCORD_CHOICE" in
        1) _dbin="discord" ;;
        2) _dbin="vesktop" ;;
        3) _dbin="equibop" ;;
        *) _dbin="" ;;
    esac
    if [ -n "$_dbin" ] && command -v "$_dbin" >/dev/null 2>&1; then
        SEED_PINS+=("Discord|$_dbin|$_dbin")
    fi
fi
if command -v "$FILE_MANAGER_BIN" >/dev/null 2>&1; then
    # Empty icon: the bar derives it at runtime via the desktop index
    # (Exec/WMClass/id-stem → real Icon=, e.g. nautilus → org.gnome.Nautilus),
    # so whatever file manager was chosen wears its own theme icon. Seeding
    # the binary name as the icon would bypass that lookup and usually
    # resolve to nothing.
    SEED_PINS+=("Files|$FILE_MANAGER_BIN|")
fi
if command -v "$TERMINAL_BIN" >/dev/null 2>&1; then
    # Same derivation as above: kitty/foot/ghostty/etc. each resolve to
    # their own icon without a per-terminal mapping here.
    SEED_PINS+=("Term|$TERMINAL_BIN|")
fi
if command -v steam >/dev/null 2>&1; then
    SEED_PINS+=("Steam|steam|steam")
fi
SEED_PINS+=("Config|simpbar-config|simpbar-config")
SEED_PINS+=("Welcome|simpbar-welcome|simpbar-welcome")
unset _cands _dbin
mkdir -p ~/.config/simpbar
if [ ! -f ~/.config/simpbar/config.json ]; then
    SEED_HAVE_FILE=0
else
    SEED_HAVE_FILE=1
fi
if [ "$SEED_HAVE_FILE" = 1 ] && grep -q '"launchers"' ~/.config/simpbar/config.json 2>/dev/null; then
    ok "config.json already has launchers — leaving your pins alone"
elif ! command -v python3 >/dev/null 2>&1; then
    warn "python3 unavailable — skipping default pin seeding (bar falls back to built-in pins)"
else
    SEED_JSON="["
    _first=1
    for _pin in "${SEED_PINS[@]}"; do
        _label="${_pin%%|*}"
        _rest="${_pin#*|}"
        _cmd="${_rest%%|*}"
        _icon="${_rest#*|}"
        # Values are our own literals and PATH-probed basenames — no JSON
        # metacharacters possible, so plain interpolation is safe.
        if [ "$_first" = 1 ]; then _first=0; else SEED_JSON="$SEED_JSON,"; fi
        SEED_JSON="$SEED_JSON{\"label\":\"$_label\",\"command\":\"$_cmd\",\"icon\":\"$_icon\"}"
    done
    SEED_JSON="$SEED_JSON]"
    unset _first _pin _label _rest _cmd _icon
    if SEED_OUT="$(python3 - ~/.config/simpbar/config.json "$SEED_JSON" <<'PYEOF'
import json, sys
path, frag = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {"appearance": {}}
except Exception as e:
    print("could not parse {0}: {1} — leaving it alone".format(path, e))
    sys.exit(1)
if not isinstance(cfg, dict):
    print("config root is not an object — leaving it alone")
    sys.exit(1)
if "launchers" in cfg:
    print("launchers already present")
    sys.exit(0)
cfg["launchers"] = json.loads(frag)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("seeded {0} pins".format(len(cfg["launchers"])))
PYEOF
)"; then
        ok "Default bar pins seeded ($SEED_OUT)"
    else
        warn "Default pin seeding failed ($SEED_OUT) — bar falls back to built-in pins"
    fi
    unset SEED_OUT
fi
unset SEED_PINS SEED_JSON SEED_HAVE_FILE

# ── Step 8: LazyVim ─────────────────────────────────────────────────
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

# Simpbar's logs live in ~/Documents/simpbar-logs — create the folder now and
# export SIMPBAR_LOG_DIR from the login + interactive shells so the bar,
# simpbar-welcome, and simpbar-config launched under Hyprland all write there
# (the app falls back to ~/.config/simpbar-config/logs when it isn't set).
SIMPBAR_ENV_LINE='export SIMPBAR_LOG_DIR="$HOME/Documents/simpbar-logs"'
mkdir -p ~/Documents/simpbar-logs
for profile in ~/.profile ~/.bashrc; do
    touch "$profile"
    if grep -q 'SIMPBAR_LOG_DIR' "$profile" 2>/dev/null; then
        ok "SIMPBAR_LOG_DIR already exported in $profile"
    else
        printf '\n%s\n' "$SIMPBAR_ENV_LINE" >> "$profile"
        ok "SIMPBAR_LOG_DIR exported in $profile"
    fi
done
ok "simpbar logs will be written to ~/Documents/simpbar-logs"

# logo.png for the Simpbar Welcome app (GTK4 + libadwaita) — the app itself
# was already built as a native Zig binary and installed to /usr/bin back
# in Step 4, alongside the bar.
mkdir -p ~/.local/share/simpbar ~/.local/share/applications ~/.config/systemd/user

base64 -d > ~/.local/share/simpbar/logo.png <<'LOGOB64EOF'
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
LOGOB64EOF


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

# Pinned-app launchers for the bar — browser and Discord client are both
# user-chosen at install time, so these try known binaries in order and
# launch whichever's actually installed. simpbar-wallpaper is the wallpaper
# engine: bare, it opens the picker's Wallpapers tab, and it also exposes
# list/set/random/current for scripting.
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

# The wallpaper engine and its login-time restore come straight from the repo.
sudo install -Dm755 ~/.local/share/simpbar/simpbar-wallpaper        /usr/bin/simpbar-wallpaper
sudo install -Dm755 ~/.local/share/simpbar/simpbar-restore-wallpaper /usr/bin/simpbar-restore-wallpaper
ok "Pinned-app launchers (browser, Discord), wallpaper picker, and update checker ready for simpbar"


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
Icon=simpbar-welcome
Terminal=false
Categories=Settings;
StartupNotify=true
WELCOMEDESKTOPEOF

cat > ~/.local/share/applications/simpbar-config.desktop <<'CONFIGDESKTOPEOF'
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

# simpbar-config's bar icon (blue/purple cog): hicolor scalable, then
# refresh the icon cache so the new icon resolves without a logout.
# Sourced from the staged copy (the /tmp archive is long cleaned by now).
if [ -f ~/.local/share/simpbar/assets/icons/simpbar-config.svg ]; then
    sudo install -Dm644 ~/.local/share/simpbar/assets/icons/simpbar-config.svg /usr/share/icons/hicolor/scalable/apps/simpbar-config.svg \
        && ok "simpbar-config icon installed to hicolor" \
        || warn "could not install simpbar-config icon (bar pin falls back to text)"
fi
# simpbar-welcome's bar icon (bird logo SVG): hicolor scalable, same as
# above. The cache refresh below covers both icons.
if [ -f ~/.local/share/simpbar/assets/icons/simpbar-welcome.svg ]; then
    sudo install -Dm644 ~/.local/share/simpbar/assets/icons/simpbar-welcome.svg /usr/share/icons/hicolor/scalable/apps/simpbar-welcome.svg \
        && ok "simpbar-welcome icon installed to hicolor" \
        || warn "could not install simpbar-welcome icon (welcome pin falls back to theme icon)"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 \
        || warn "icon cache refresh failed (log out and back in if an icon doesn't appear)"
fi

# Existing installs pinned the welcome launcher with the old help-about
# icon — point just that pin at the bird logo, leaving everything else
# in the user's config alone.
if command -v python3 >/dev/null 2>&1 && [ -f ~/.config/simpbar/config.json ]; then
    if python3 - ~/.config/simpbar/config.json <<'PYEOF' 2>/dev/null; then
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
launchers = cfg.get("launchers")
if not isinstance(launchers, list):
    sys.exit(1)
changed = False
for entry in launchers:
    if isinstance(entry, dict) and entry.get("command") == "simpbar-welcome" and entry.get("icon") == "help-about":
        entry["icon"] = "simpbar-welcome"
        changed = True
if not changed:
    sys.exit(1)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("welcome pin now uses the simpbar-welcome icon")
PYEOF
        ok "Welcome pin migrated to the simpbar-welcome icon"
    fi
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

if pacman -Qq gtk4 >/dev/null 2>&1 && pacman -Qq libadwaita >/dev/null 2>&1 && pacman -Qq python-gobject >/dev/null 2>&1; then
    run_spinner "Enabling simpbar-welcome.service" systemctl --user enable --now simpbar-welcome.service \
        || warn "Could not enable simpbar-welcome.service — launch it manually: simpbar-welcome"
    ok "Simpbar Welcome app installed — will show once on first login, or launch it anytime from rofi"
else
    warn "GTK4/libadwaita/python-gobject not fully installed — skipping Simpbar Welcome autostart"
fi


run_spinner "Updating the full system (pacman -Syu)" sudo pacman -Syu --noconfirm \
    || warn "Full system update failed — run 'sudo pacman -Syu' manually to check for issues"

# ── Step 9: done ────────────────────────────────────────────────────
step "Done"
ok "Full system updated (pacman -Syu)"
ok "Zig 0.16.0 build tool ready"
ok "freetype2, gdk-pixbuf2, wayland, wayland-protocols, playerctl, mate-polkit, swaybg, JetBrainsMono Nerd Font, Noto Fonts, Noto Emoji, ${TERMINAL_PKG}, fastfetch, neovim, swaync, rofi, flatpak, bazaar, nwg-look, pavucontrol, cava, pipewire, gnome-disk-utility, nwg-drawer, kdeconnect, brightnessctl, wlr-randr installed (pacman)"

# gnome-keyring auto-unlock at login: two `optional` PAM lines (optional =
# they can never block login, even if the module ever disappears) appended
# to the greeter's stack AFTER the password prompt (the module just caches
# the already-entered password) so the first "Enter password for the
# default keyring" prompt on login disappears. Idempotent — grep first,
# skip files that don't exist (greeter may not be ly on this system).
if grep -qs "pam_gnome_keyring\.so" /etc/pam.d/ly; then
    ok "gnome-keyring PAM unlock already configured for ly"
else
    if [ -f /etc/pam.d/ly ]; then
        run_spinner "gnome-keyring: PAM unlock for ly" \
            bash -c 'printf "\nauth\t\toptional\tpam_gnome_keyring.so\nsession\toptional\tpam_gnome_keyring.so auto_start\n" >> /etc/pam.d/ly' \
            || warn "Could not edit /etc/pam.d/ly — keyring will prompt on first use"
        ok "gnome-keyring unlocks automatically at the ly login prompt"
    else
        warn "/etc/pam.d/ly not found — keyring PAM setup skipped (it will prompt once per session instead)"
    fi
fi
# Keep the keyring synced when the login password changes later (the
# wiki's standard line for /etc/pam.d/passwd; same idempotence rule).
if grep -qs "pam_gnome_keyring\.so" /etc/pam.d/passwd; then
    :
else
    if [ -f /etc/pam.d/passwd ]; then
        run_spinner "gnome-keyring: PAM sync for passwd" \
            bash -c 'printf "\npassword\toptional\tpam_gnome_keyring.so\n" >> /etc/pam.d/passwd' \
            || warn "Could not edit /etc/pam.d/passwd — keyring password may drift from the login password"
        ok "gnome-keyring stays in sync on password changes"
    fi
fi
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    ok "Hyprland + xdg-desktop-portal-hyprland installed (pacman)"
else
    ok "MangoWM + xdg-desktop-portal-wlr installed (pacman) — start it with 'mango' from a TTY or via your display manager"
fi
ok "$FILE_MANAGER_NAME installed and bound to SUPER + E"
ok "$ARCHIVER_NAME installed alongside it (archive extract/compress in $FILE_MANAGER_NAME)"
ok "pipewire, pipewire-pulse, wireplumber enabled as user services"
if pacman -Qq cliphist >/dev/null 2>&1; then
    ok "cliphist installed (bind a key to it yourself — e.g. SUPER+C in the config)"
fi
if [ -n "$DISCORD_NAME" ]; then
    ok "$DISCORD_NAME installed"
elif [ "$XERO_SYSTEM" = 1 ]; then
    ok "Discord client install skipped (covered by the Xero install)"
else
    ok "Discord client install skipped, as requested"
fi
ok "Flathub remote added for flatpak/bazaar"
ok "nwg-look set to prefer dark theme"
if pacman -Qq bibata-cursor-theme >/dev/null 2>&1; then
    ok "Bibata Modern Classic cursor installed and applied"
fi
if [ "$WM_IS_HYPRLAND" -eq 1 ] && [ -e ~/.config/hypr/hyprland-simpbar.lua ]; then
    ok "Hyprland settings active — simpbar-config manages hyprland-simpbar.lua (first run bootstrapped it into hyprland.lua via pcall)"
fi
if [ "$WM_IS_MANGO" -eq 1 ]; then
    ok "Mango settings active — simpbar-config writes its Mango pages straight to ~/.config/mango/cfg/*.conf"
fi
if pacman -Qq game-devices-udev >/dev/null 2>&1; then
    ok "game-devices-udev installed — Xbox/PlayStation/generic controllers get proper permissions"
fi
if [ -e ~/.config/systemd/user/simpbar-update-checker.timer ]; then
    ok "Update checker enabled — notifies on new Arch/AUR updates or new commits on the simpbar repo (checks every 6h)"
fi
if [ -e ~/.config/rofi/config.rasi ]; then
    ok "rofi configured with the Material theme"
fi
ok "protonplus and the theme packages installed (from ${REPO_NAME} or AUR helper)"
if [ -n "$BROWSER_NAME" ]; then
    ok "$BROWSER_NAME installed (from ${REPO_NAME} or AUR helper)"
elif [ "$XERO_SYSTEM" = 1 ]; then
    ok "Browser install skipped (covered by the Xero install)"
else
    ok "Browser install skipped, as requested"
fi
ok "Chaotic-AUR repo enabled"
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    ok "Today's Bing wallpaper downloaded to ~/Pictures/Wallpaper"
fi
if [ -r ~/.config/simpbar/wallpaper ]; then
    ok "Wallpaper engine seeded — your wallpaper is restored at login and rethemes the desktop"
fi
if [ "$INSTALL_MATUGEN" -eq 1 ] && [ -e ~/.config/simpbar/matugen.json ]; then
    ok "matugen auto-theming set up — the bar recolors to each wallpaper (toggle off in simpbar-config anytime)"
fi
if [ -x /usr/bin/simpbar ]; then
    ok "simpbar built and installed to /usr/bin/simpbar (source in ~/.local/share/simpbar/simpbar)"
fi
if [ -x /usr/bin/simpbar-config ]; then
    ok "simpbar-config installed to /usr/bin/simpbar-config — configure the bar's appearance, modules, and shortcuts anytime from rofi/nwg-drawer, or run 'simpbar-config'"
fi
if [ -x /usr/bin/simpbar-shell ]; then
    ok "simpbar-shell installed to /usr/bin/simpbar-shell — desktop widget cards on every output"
fi
if command -v quickshell >/dev/null 2>&1; then
    if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
        ok "App drawer installed — SUPER+Tab, or click empty bar space, to open it (themed from matugen)"
    else
        ok "App drawer installed — SUPER+Space, or click empty bar space, to open it (themed from matugen); SUPER+SHIFT+Q opens its Power menu"
    fi
fi
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    ok "hypr config in ~/.config/hypr"
else
    ok "mango config in ~/.config/mango (monitors shipped blank, so Mango auto-detects your display — set them in simpbar-config anytime)"
fi
ok "swaync config in ~/.config/swaync"
ok "LazyVim config in ~/.config/nvim (run 'nvim' to finish plugin install)"
ok "fastfetch runs automatically in new terminal sessions (~/.bashrc)"

# First-boot handoff: if this system was provisioned by the xero base
# installer, an autostart stub may still call /usr/local/bin/simpbar-firstboot
# on graphical logins. Record success so the next login retracts the stubs
# instead of re-opening this installer — and remove the launcher itself,
# whose job is done. Harmless no-ops on systems that never had phase 1.
mkdir -p ~/.config/simpbar
touch ~/.config/simpbar/.firstboot-done 2>/dev/null || true
sudo rm -f /usr/local/bin/simpbar-firstboot 2>/dev/null || true

printf '\n%s%s Setup complete!%s\n' "$C_GREEN$C_BOLD" "✔" "$C_RESET"
printf '%sRestart your session, or run:%s\n' "$C_BOLD" "$C_RESET"
if [ "$WM_IS_MANGO" -eq 1 ]; then
    printf '  %smango%s                       # start MangoWM from a TTY (or configure your display manager)\n' "$C_CYAN" "$C_RESET"
fi
printf '  %ssimpbar &%s\n' "$C_CYAN" "$C_RESET"
printf '  %ssimpbar-shell &%s          # desktop widget cards (clock/weather/media/system)\n' "$C_CYAN" "$C_RESET"
if [ -n "$BING_FILE" ] && [ -e "$BING_FILE" ]; then
    printf '  %ssimpbar-wallpaper set %q%s   # apply a wallpaper directly\n' "$C_CYAN" "$BING_FILE" "$C_RESET"
else
    printf '  %ssimpbar-wallpaper set /path/to/your/wallpaper.jpg%s   # example\n' "$C_CYAN" "$C_RESET"
fi
printf '  %ssimpbar-wallpaper%s                    # open the picker (Wallpapers tab)\n' "$C_CYAN" "$C_RESET"
printf '  %ssimpbar-wallpaper random%s             # set a random wallpaper\n' "$C_CYAN" "$C_RESET"
printf '  %ssimpbar-wallpaper bing%s               # fetch today'"'"'s Bing wallpaper\n' "$C_CYAN" "$C_RESET"
printf '  %ssimpbar-wallpaper search '"'"'northern lights'"'"'%s   # search wallhaven.cc\n' "$C_CYAN" "$C_RESET"
printf '  %s/usr/lib/mate-polkit/polkit-mate-authentication-agent-1 &%s   # needed for GUI auth prompts\n' "$C_CYAN" "$C_RESET"

printf '\n%sKeybindings:%s\n' "$C_BOLD" "$C_RESET"
printf '  %sSUPER%s                    = Windows key\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + Enter%s            = Open terminal\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + E%s                = Open %s\n' "$C_CYAN" "$C_RESET" "$FILE_MANAGER_NAME"
printf '  %sSUPER + Q%s                = Close / exit the focused window\n' "$C_CYAN" "$C_RESET"
printf '  %sSUPER + [1-0]%s            = Switch workspaces/tags\n' "$C_CYAN" "$C_RESET"
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    printf '  %sSUPER + Space%s            = Open Rofi (app launcher)\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + Tab%s              = Open the app drawer (begin typing to search)\n' "$C_CYAN" "$C_RESET"
    printf '  %sPrint%s                     = Screenshot: region\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + Print%s             = Screenshot: active window\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + SHIFT + Print%s     = Screenshot: full screen\n' "$C_CYAN" "$C_RESET"
else
    printf '  %sSUPER + Space%s            = Open the app drawer (begin typing to search)\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + SHIFT + Q%s        = Power menu (lock / log out / reboot / power off)\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + S%s                = Toggle notifications (SwayNC)\n' "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + SHIFT + S%s        = Open simpbar-config (bar settings + Mango pages)\n' "$C_CYAN" "$C_RESET"
    printf '  %sPrint%s / %sSUPER + P%s       = Screenshot: region (saved + copied)\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '  %sSUPER + SHIFT + P%s        = Screenshot: full screen\n' "$C_CYAN" "$C_RESET"
fi
printf '\n%sTo change your keybindings or set your monitor resolution, edit the config with:%s\n' "$C_BOLD" "$C_RESET"
if [ "$WM_IS_HYPRLAND" -eq 1 ]; then
    printf '  %snvim ~/.config/hypr/hyprland.lua%s\n' "$C_CYAN" "$C_RESET"
else
    printf '  %snvim ~/.config/mango/cfg/keybinds.conf%s   (monitors: ~/.config/mango/cfg/monitors.conf)\n' "$C_CYAN" "$C_RESET"
fi
printf '\n%sEnjoy your new home & workflow! :)%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '\n%sDon'"'"'t forget to reboot! Please use: systemctl reboot%s\n' "$C_YELLOW" "$C_RESET"

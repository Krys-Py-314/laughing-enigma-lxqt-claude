#!/usr/bin/env bash
#
# inst-lowmem-lxqt-rpi5.sh
#
# Minimal-memory LXQt + Openbox desktop for Raspberry Pi 5 (tuned for 2 GB)
# Target: Raspberry Pi OS Lite 64-bit (Bookworm / Trixie), arm64
#
# Run it as your normal user - no sudo needed:
#     bash inst-lowmem-lxqt-rpi5.sh
# It asks for your password once and uses sudo internally where root is
# required. If you start it with sudo anyway, it drops back to your user.
#
# On top of the desktop install, this script applies the memory fixes that
# close most of the gap to a Pi Zero 2 W running the same desktop:
#   - 4 KB-page kernel (kernel8.img) instead of the 16 KB-page Pi 5 kernel
#   - glamor (GPU acceleration inside Xorg) turned off
#   - screen resolution capped (default 1920x1080)
#   - zram compressed swap
#   - a 'memcheck' command to measure the result after reboot
#
# Environment overrides:
#     SKIP_KERNEL4K=1     keep the 16 KB-page Pi 5 kernel (kernel_2712.img)
#     KEEP_GLAMOR=1       leave glamor (GPU acceleration in Xorg) enabled
#     MAX_RES=WxH         resolution cap at login (default 1920x1080, 'off' = none)
#     SKIP_ZRAM=1         do not set up zram swap
#     SKIP_SSH_SWAP=1     keep OpenSSH, do not install/switch to dropbear
#     SKIP_PI_APPS=1      skip Pi-Apps + Min + Geany Dark Mode
#     SKIP_TRIM=1         do not disable triggerhappy
#     ASSUME_YES=1        never prompt (non-interactive)
#

set -uo pipefail
clear -x
# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Everything this script writes to $HOME must belong to the desktop user, so
# it runs as that user and calls sudo itself. Started with sudo, it re-runs
# itself as the invoking user; sudo's cached credentials cover the password.
if [ "$EUID" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        print_warning "Started with sudo - re-running as '${SUDO_USER}' (no sudo needed next time)."
        exec sudo -u "$SUDO_USER" -H env \
            SKIP_KERNEL4K="${SKIP_KERNEL4K:-0}" KEEP_GLAMOR="${KEEP_GLAMOR:-0}" \
            MAX_RES="${MAX_RES:-1920x1080}" SKIP_ZRAM="${SKIP_ZRAM:-0}" \
            SKIP_SSH_SWAP="${SKIP_SSH_SWAP:-0}" SKIP_PI_APPS="${SKIP_PI_APPS:-0}" \
            SKIP_TRIM="${SKIP_TRIM:-0}" ASSUME_YES="${ASSUME_YES:-0}" \
            bash "$(readlink -f "$0")" "$@"
    fi
    print_error "Do not run this as the root account. Log in as your normal user and run:"
    print_error "    bash $(basename "$0")"
    exit 1
fi

print_status "Starting Raspberry Pi 5 low-memory LXQt/Openbox setup..."

# ---------------------------------------------------------------------------
# Globals / helpers
# ---------------------------------------------------------------------------
LOGFILE="$HOME/.inst-lowmem-lxqt-rpi5.log"
SKIPPED_PKGS=()
FAILED_STEPS=()
REBOOT_NEEDED=0

SKIP_KERNEL4K="${SKIP_KERNEL4K:-0}"
KEEP_GLAMOR="${KEEP_GLAMOR:-0}"
MAX_RES="${MAX_RES:-1920x1080}"
SKIP_ZRAM="${SKIP_ZRAM:-0}"
SKIP_SSH_SWAP="${SKIP_SSH_SWAP:-0}"
SKIP_PI_APPS="${SKIP_PI_APPS:-0}"
SKIP_TRIM="${SKIP_TRIM:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# Interface font size, applied to Qt/LXQt, GTK, Openbox and urxvt alike.
FONT_SIZE=12

# Desktop background colour requested: R:56 G:60 B:72
BG_COLOR="#383C48"
BG_DARKER="#2B2E38"
BG_LIGHTER="#4A4F60"
BORDER_COLOR="#22252E"
FG_COLOR="#E6E6E6"

banner() {
    print_status " "
    print_status " $1"
    print_status " "
}

note_fail() {
    FAILED_STEPS+=("$1")
    print_error "$1"
}

# True when apt has an installable candidate for the package.
pkg_available() {
    local cand
    cand="$(apt-cache policy -- "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# Install only packages that actually exist in the configured repositories.
# This is what keeps the run free of "Unable to locate package" failures.
apt_install() {
    local want=("$@") ok=() miss=() p
    for p in "${want[@]}"; do
        if pkg_available "$p"; then ok+=("$p"); else miss+=("$p"); fi
    done
    if [ "${#miss[@]}" -gt 0 ]; then
        print_warning "Not offered by this release, skipping: ${miss[*]}"
        SKIPPED_PKGS+=("${miss[@]}")
    fi
    if [ "${#ok[@]}" -eq 0 ]; then
        return 0
    fi
    print_status "apt-get install: ${ok[*]}"
    if ! sudo apt-get install -y --no-install-recommends "${ok[@]}" >>"$LOGFILE" 2>&1; then
        note_fail "apt-get install failed for: ${ok[*]} (see $LOGFILE)"
        return 1
    fi
    return 0
}

# Install the first package in the list that exists (for name changes across releases).
apt_install_first() {
    local p
    for p in "$@"; do
        if pkg_available "$p"; then
            apt_install "$p"
            return $?
        fi
    done
    print_warning "None of these packages exist here: $*"
    SKIPPED_PKGS+=("$*")
    return 1
}

confirm() {
    local prompt="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    [ -t 0 ] || return 0
    local reply=""
    read -r -p "$(echo -e "${YELLOW}[WARN]${NC} ${prompt} [Y/n] ")" reply
    case "$reply" in
        [nN]*) return 1 ;;
        *)     return 0 ;;
    esac
}

# Replace a marked block in a file (idempotent edits).
write_block() {
    local file="$1" marker="$2" content="$3"
    touch "$file"
    if grep -q "^# >>> ${marker} >>>" "$file" 2>/dev/null; then
        sed -i "/^# >>> ${marker} >>>/,/^# <<< ${marker} <<</d" "$file"
    fi
    {
        echo ""
        echo "# >>> ${marker} >>>"
        printf '%s\n' "$content"
        echo "# <<< ${marker} <<<"
    } >>"$file"
}

# write_block for root-owned files (config.txt lives on the vfat boot partition).
sudo_write_block() {
    local file="$1" marker="$2" content="$3"
    sudo touch "$file"
    if sudo grep -q "^# >>> ${marker} >>>" "$file" 2>/dev/null; then
        sudo sed -i "/^# >>> ${marker} >>>/,/^# <<< ${marker} <<</d" "$file"
        # Drop the blank lines left at the end so re-runs do not pile them up.
        sudo sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file"
    fi
    printf '\n# >>> %s >>>\n%s\n# <<< %s <<<\n' "$marker" "$content" "$marker" \
        | sudo tee -a "$file" >/dev/null
}

: >"$LOGFILE"
print_status "Full command output is being logged to: $LOGFILE"

# ===========================================================================
banner "01 - Pre-flight checks (architecture, OS, sudo, network)"
# ===========================================================================

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "arm64" ]; then
    print_warning "Architecture is '$ARCH', expected 'arm64' (64-bit Raspberry Pi OS)."
    confirm "Continue anyway?" || exit 1
else
    print_status "Architecture: arm64 OK"
fi

OS_ID=""; OS_CODENAME=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
fi
print_status "Detected OS: ${PRETTY_NAME:-unknown} (codename: ${OS_CODENAME:-unknown})"
case "$OS_ID" in
    debian|raspbian) : ;;
    *) print_warning "OS id is '${OS_ID:-unknown}', expected debian/raspbian. Package names may differ." ;;
esac

if [ -r /proc/device-tree/model ]; then
    PI_MODEL="$(tr -d '\0' </proc/device-tree/model)"
    print_status "Board: $PI_MODEL"
    case "$PI_MODEL" in
        *"Raspberry Pi 5"*) : ;;
        *) print_warning "This script targets the Raspberry Pi 5; some tuning may not apply." ;;
    esac
else
    print_warning "Not running on a Raspberry Pi (no /proc/device-tree/model)."
fi

print_status "Your password is asked for once; the script runs sudo itself from here on."
if ! sudo -v; then
    print_error "This script needs a user with sudo rights (it installs packages)."
    exit 1
fi
# Keep sudo alive for the whole run.
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# Firmware config: /boot/firmware on Bookworm and later, /boot before that.
BOOTCFG=""
for f in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$f" ] && { BOOTCFG="$f"; break; }
done
BOOTDIR="${BOOTCFG%/*}"

if ! ping -c1 -W3 deb.debian.org >/dev/null 2>&1 && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
    print_warning "Network check was inconclusive; continuing anyway."
fi

# ===========================================================================
banner "02 - APT policy: no recommends, no printing stack, refresh index"
# ===========================================================================

# Minimal footprint: never pull Recommends system-wide for this run's installs.
sudo tee /etc/apt/apt.conf.d/99-min-lxqt >/dev/null <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

# No printing or printer access is wanted: make the print stack uninstallable.
sudo tee /etc/apt/preferences.d/99-no-printing >/dev/null <<'EOF'
Package: cups cups-daemon cups-browsed cups-common cups-client cups-filters
Pin: release *
Pin-Priority: -1

Package: printer-driver-*
Pin: release *
Pin-Priority: -1

Package: system-config-printer* hplip* ipp-usb
Pin: release *
Pin-Priority: -1
EOF
print_status "Printing packages pinned out (Pin-Priority: -1)."

print_status "Refreshing package index (this can take a minute)..."
sudo apt-get update >>"$LOGFILE" 2>&1 || note_fail "apt-get update failed (see $LOGFILE)"
print_status "Applying pending upgrades..."
sudo apt-get -y upgrade >>"$LOGFILE" 2>&1 || print_warning "apt-get upgrade reported problems (see $LOGFILE)"

# Baseline tools this script itself relies on.
apt_install ca-certificates curl wget unzip xz-utils git fontconfig procps

# ===========================================================================
banner "03 - Kernel with 4 KB memory pages (kernel8.img)"
# ===========================================================================

# The Pi 5 boots kernel_2712.img, built with 16 KB pages. Every allocation is
# rounded up to a whole page, so a desktop made of many small processes uses
# noticeably more RAM than on a 4 KB-page kernel (the Zero 2 W's default).
# kernel8.img is the generic arm64 Pi kernel with 4 KB pages and boots the
# Pi 5 fine; the cost is a few percent of CPU speed in some workloads.
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo unknown)"
print_status "Running kernel $(uname -r) with ${PAGE_SIZE}-byte pages."

if [ "$SKIP_KERNEL4K" = "1" ]; then
    print_warning "SKIP_KERNEL4K=1 -> keeping the current kernel."
elif [ "$PAGE_SIZE" = "4096" ]; then
    print_status "Already on 4 KB pages; nothing to change."
elif [ -z "$BOOTCFG" ]; then
    note_fail "config.txt not found; cannot switch to kernel8.img."
else
    if [ ! -f "${BOOTDIR}/kernel8.img" ]; then
        print_warning "${BOOTDIR}/kernel8.img is missing; installing the 4 KB-page kernel package."
        apt_install_first linux-image-rpi-v8
    fi
    if [ -f "${BOOTDIR}/kernel8.img" ]; then
        # Appended under [all] so no earlier [pi5]/[cm5] filter can hide it,
        # and last in the file so it wins over any earlier kernel= line.
        sudo_write_block "$BOOTCFG" "inst-lowmem-kernel4k" "$(printf '%s\n' \
            '# 4 KB-page kernel: less RAM per process than the 16 KB-page kernel_2712.img.' \
            '# Delete this block to go back to the default Pi 5 kernel.' \
            '[all]' \
            'kernel=kernel8.img')"
        print_status "kernel=kernel8.img set in ${BOOTCFG} (takes effect after reboot)."
        if grep -qE '^\s*auto_initramfs=1' "$BOOTCFG" && [ ! -f "${BOOTDIR}/initramfs8" ]; then
            print_warning "auto_initramfs=1 is set but ${BOOTDIR}/initramfs8 is missing;"
            print_warning "the Pi boots without it from SD/USB, but check if you use an encrypted or network root."
        fi
        REBOOT_NEEDED=1
    else
        note_fail "kernel8.img still missing; staying on the 16 KB-page kernel."
    fi
fi

# ===========================================================================
banner "04 - zram compressed swap"
# ===========================================================================

# zram keeps swapped-out pages in RAM, compressed to roughly a third. On a
# 2 GB Pi it is the cheapest way to survive memory spikes (a browser, a
# build) without touching the SD card.
zram_active() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -q zram
}

if [ "$SKIP_ZRAM" = "1" ]; then
    print_warning "SKIP_ZRAM=1 -> leaving swap alone."
elif zram_active; then
    print_status "zram swap is already active:"
    swapon --show 2>/dev/null | sed 's/^/           /'
elif dpkg-query -W -f='${Status}' rpi-swap 2>/dev/null | grep -q 'ok installed'; then
    print_status "rpi-swap is installed and manages swap on this image; leaving it alone."
else
    ZRAM_OK=0
    if pkg_available systemd-zram-generator; then
        if [ -f /etc/systemd/zram-generator.conf ]; then
            print_status "Keeping the existing /etc/systemd/zram-generator.conf."
        else
            # Half of RAM (1 GB on a 2 GB Pi), capped at 2 GB on bigger boards.
            sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
# Generated by inst-lowmem-lxqt-rpi5.sh
[zram0]
zram-size = min(ram / 2, 2048)
compression-algorithm = zstd
swap-priority = 100
EOF
        fi
        if apt_install systemd-zram-generator; then
            sudo systemctl daemon-reload >>"$LOGFILE" 2>&1
            sudo systemctl start systemd-zram-setup@zram0.service >>"$LOGFILE" 2>&1 || true
            ZRAM_OK=1
        fi
    elif pkg_available zram-tools; then
        if apt_install zram-tools; then
            sudo tee /etc/default/zramswap >/dev/null <<'EOF'
# Generated by inst-lowmem-lxqt-rpi5.sh
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
            sudo systemctl restart zramswap.service >>"$LOGFILE" 2>&1 || true
            ZRAM_OK=1
        fi
    else
        note_fail "Neither systemd-zram-generator nor zram-tools is available here."
    fi

    if [ "$ZRAM_OK" = "1" ]; then
        # With swap in RAM, swapping early is cheap; reading one page at a
        # time avoids decompressing neighbours nobody asked for.
        sudo tee /etc/sysctl.d/99-inst-lowmem-zram.conf >/dev/null <<'EOF'
# Generated by inst-lowmem-lxqt-rpi5.sh (tuned for zram swap)
vm.swappiness = 100
vm.page-cluster = 0
EOF
        sudo sysctl -q -p /etc/sysctl.d/99-inst-lowmem-zram.conf >>"$LOGFILE" 2>&1 || true
        if zram_active; then
            print_status "zram swap is active:"
            swapon --show 2>/dev/null | sed 's/^/           /'
        else
            print_warning "zram is configured but not active yet; it will start at the next boot."
            REBOOT_NEEDED=1
        fi
    fi
fi

# ===========================================================================
banner "05 - X11 server (minimal: no display manager, no compositor)"
# ===========================================================================

# xserver-xorg-core carries the 'modesetting' driver used by the Pi's vc4 KMS
# driver, so no separate video driver package is required.
apt_install \
    xserver-xorg-core \
    xserver-xorg-legacy \
    xserver-xorg-input-libinput \
    xinit \
    x11-xserver-utils \
    x11-utils \
    xkb-data \
    libgl1-mesa-dri \
    dbus-x11 \
    xdg-utils \
    xdg-user-dirs \
    shared-mime-info \
    desktop-file-utils \
    hicolor-icon-theme \
    adwaita-icon-theme

# Allow a console user to start X without root privileges (rootless X on KMS).
sudo tee /etc/X11/Xwrapper.config >/dev/null <<'EOF'
allowed_users=anybody
needs_root_rights=no
EOF
print_status "Xwrapper configured for rootless startx."

# ===========================================================================
banner "06 - VC4 / KMS Xorg configuration, glamor off, resolution cap"
# ===========================================================================

# Glamor is Xorg's GPU acceleration. On the Pi 5 it loads the Mesa V3D driver
# into the X server and keeps GPU buffers in system RAM; Raspberry Pi OS
# already turns it off on the Pi 0-3. Without it Xorg draws in software, which
# a panel, terminal and file manager do not notice. OpenGL programs (and
# mpv's default video output) fall back to software rendering.
# The option sits in the OutputClass that already selects the vc4 display
# device: a separate "Device" section can make Xorg pick the Pi 5's
# display-less v3d card instead and come up with no screen.
if [ "$KEEP_GLAMOR" = "1" ]; then
    GLAMOR_LINE=""
    print_warning "KEEP_GLAMOR=1 -> glamor stays on."
else
    GLAMOR_LINE='    Option "AccelMethod" "none"'
fi

sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/99-vc4.conf >/dev/null <<EOF
Section "OutputClass"
    Identifier "vc4"
    MatchDriver "vc4"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
${GLAMOR_LINE}
EndSection
EOF
if [ -n "$GLAMOR_LINE" ]; then
    print_status "Wrote /etc/X11/xorg.conf.d/99-vc4.conf (glamor off)."
else
    print_status "Wrote /etc/X11/xorg.conf.d/99-vc4.conf (glamor on)."
fi

# A hand-made glamor-off "Device" file (the manual recipe) is replaced by the
# option above; two definitions would only get in each other's way.
if [ -f /etc/X11/xorg.conf.d/20-noglamor.conf ]; then
    sudo mv /etc/X11/xorg.conf.d/20-noglamor.conf /etc/X11/xorg.conf.d/20-noglamor.conf.disabled
    print_warning "Moved 20-noglamor.conf aside (now handled in 99-vc4.conf)."
fi

# Resolution cap. Every framebuffer and window buffer scales with the pixel
# count, so a 4K screen costs roughly 4x the memory of 1080p. The helper only
# steps an output DOWN to MAX_RES, and only if the monitor offers that mode,
# so a smaller screen is never touched and a bad value cannot blank it.
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/cap-resolution" <<'CAPEOF'
#!/bin/sh
# cap-resolution WxH - lower any connected output running above WxH to WxH.
# Generated by inst-lowmem-lxqt-rpi5.sh; called from ~/.xinitrc.
MAX_RES="${1:-1920x1080}"
[ "$MAX_RES" = "off" ] && exit 0
command -v xrandr >/dev/null 2>&1 || exit 0
xrandr --query 2>/dev/null | awk -v want="$MAX_RES" '
function flush(   d, w) {
    if (out != "" && cur != "" && has) {
        split(cur, d, "x"); split(want, w, "x")
        if (d[1] * d[2] > w[1] * w[2]) print out
    }
    out = ""; cur = ""; has = 0
}
/^[^ \t]/ { flush(); if ($2 == "connected") out = $1; next }
out != "" { if ($1 == want) has = 1; if ($0 ~ /\*/) cur = $1 }
END { flush() }' | while read -r output; do
    xrandr --output "$output" --mode "$MAX_RES"
done
CAPEOF
chmod +x "$HOME/.local/bin/cap-resolution"
if [ "$MAX_RES" = "off" ]; then
    print_warning "MAX_RES=off -> resolution left at the monitor's default."
else
    print_status "Resolution capped at ${MAX_RES} on login (~/.local/bin/cap-resolution)."
fi

# Make sure the KMS overlay is actually enabled in the firmware config.
if [ -n "$BOOTCFG" ]; then
    if grep -qE '^\s*dtoverlay=vc4-kms-v3d' "$BOOTCFG"; then
        print_status "vc4-kms-v3d overlay already enabled in $BOOTCFG"
    else
        print_warning "Adding dtoverlay=vc4-kms-v3d to $BOOTCFG"
        echo -e "\n# Added by inst-lowmem-lxqt-rpi5.sh\n[all]\ndtoverlay=vc4-kms-v3d" | sudo tee -a "$BOOTCFG" >/dev/null
    fi
else
    print_warning "Could not find config.txt; skipping KMS overlay check."
fi

# ===========================================================================
banner "07 - LXQt core (hand-picked modules, no lxqt-core metapackage)"
# ===========================================================================

# Deliberately NOT installing: lxqt-core, lxqt-powermanagement, lxqt-admin,
# lxqt-about, lxqt-openssh-askpass, screensavers, compositors.
apt_install \
    lxqt-session \
    lxqt-panel \
    lxqt-config \
    lxqt-runner \
    lxqt-globalkeys \
    lxqt-notificationd \
    lxqt-policykit \
    lxqt-qtplugin \
    lxqt-themes

# ===========================================================================
banner "08 - Openbox window manager"
# ===========================================================================

apt_install openbox obconf-qt

# ===========================================================================
banner "09 - Terminal, file manager, text editor"
# ===========================================================================

apt_install rxvt-unicode pcmanfm-qt l3afpad

# ===========================================================================
banner "10 - Media: PDF viewer, image viewer, video player, screen recorder"
# ===========================================================================

# mupdf   : smallest usable PDF viewer (single binary, ~30 MB RSS)
# feh     : tiny X11 image viewer
# mpv     : light video player
# ffmpeg  : backend for the screen recorder wrapper (zero RAM when idle)
apt_install mupdf feh mpv ffmpeg scrot

mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/screenrec" <<'RECEOF'
#!/usr/bin/env bash
# screenrec - toggle a lightweight ffmpeg X11 screen recording.
# First run starts recording, second run stops it. Output: ~/Videos/
set -u
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/screenrec.pid"
OUTDIR="${HOME}/Videos"
mkdir -p "$OUTDIR"

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send -t 2500 "screenrec" "$1"
    echo "screenrec: $1"
}

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill -INT "$(cat "$PIDFILE")" 2>/dev/null
    sleep 1
    rm -f "$PIDFILE"
    notify "Recording stopped."
    exit 0
fi

GEOM="$(xdpyinfo | awk '/dimensions:/{print $2; exit}')"
OUT="${OUTDIR}/screenrec-$(date +%Y%m%d-%H%M%S).mp4"

# ultrafast + zerolatency keeps CPU and RAM use low on the Pi 5.
ffmpeg -loglevel error -y \
    -f x11grab -framerate 25 -video_size "$GEOM" -i "${DISPLAY:-:0}" \
    -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -crf 26 \
    "$OUT" >/dev/null 2>&1 &

echo $! >"$PIDFILE"
notify "Recording to $(basename "$OUT")"
RECEOF
chmod +x "$HOME/.local/bin/screenrec"
print_status "Installed screen recorder: ~/.local/bin/screenrec (run again to stop)"

# ===========================================================================
banner "11 - Ubuntu Nerd Font (system-wide, regular, size ${FONT_SIZE})"
# ===========================================================================

NF_DIR="/usr/local/share/fonts/NerdFonts"
sudo mkdir -p "$NF_DIR"
NF_BASE="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
NF_TMP="$(mktemp -d)"

for z in UbuntuMono Ubuntu; do
    if [ -n "$(sudo find "$NF_DIR" -iname "${z}*Nerd*" -print -quit 2>/dev/null)" ]; then
        print_status "${z} Nerd Font already present, skipping download."
        continue
    fi
    print_status "Downloading ${z} Nerd Font..."
    if curl -fsSL --retry 3 -o "${NF_TMP}/${z}.zip" "${NF_BASE}/${z}.zip"; then
        unzip -qo "${NF_TMP}/${z}.zip" -d "${NF_TMP}/${z}" \
            -x 'LICENSE*' 'README*' '*.md' 2>/dev/null
        sudo find "${NF_TMP}/${z}" -type f \( -iname '*.ttf' -o -iname '*.otf' \) \
            -exec cp -f {} "$NF_DIR"/ \;
        print_status "${z} Nerd Font installed."
    else
        note_fail "Could not download ${z} Nerd Font from GitHub."
    fi
done
rm -rf "$NF_TMP"

sudo chmod 644 "$NF_DIR"/* 2>/dev/null || true
sudo fc-cache -f >>"$LOGFILE" 2>&1
print_status "Font cache rebuilt."

# Resolve the real installed family names (they differ across Nerd Fonts releases).
detect_family() {
    local pat
    for pat in "$@"; do
        local hit
        hit="$(fc-list : family 2>/dev/null | tr ',' '\n' \
               | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u \
               | grep -ixF "$pat" | head -n1)"
        [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
    done
    return 1
}

MONO_FONT="$(detect_family \
    'UbuntuMono Nerd Font Mono' 'UbuntuMono Nerd Font' \
    'UbuntuSansMono Nerd Font Mono' 'UbuntuSansMono Nerd Font' \
    'DejaVu Sans Mono')" || MONO_FONT="monospace"

UI_FONT="$(detect_family \
    'Ubuntu Nerd Font' 'UbuntuSans Nerd Font' \
    'UbuntuMono Nerd Font' 'DejaVu Sans')" || UI_FONT="sans-serif"

print_status "UI font   : ${UI_FONT} ${FONT_SIZE}"
print_status "Mono font : ${MONO_FONT} ${FONT_SIZE}"

# Make the Nerd Fonts the fontconfig default for the whole system.
sudo tee /etc/fonts/local.conf >/dev/null <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias><family>sans-serif</family><prefer><family>${UI_FONT}</family></prefer></alias>
  <alias><family>sans</family><prefer><family>${UI_FONT}</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>${MONO_FONT}</family></prefer></alias>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF
sudo fc-cache -f >>"$LOGFILE" 2>&1
print_status "System-wide font defaults written to /etc/fonts/local.conf"

# ===========================================================================
banner "12 - Icons (circle apps, dark folders) and square Openbox theme"
# ===========================================================================

apt_install numix-icon-theme-circle numix-icon-theme

ICON_THEME="Numix-Circle"
if [ ! -d /usr/share/icons/Numix-Circle ]; then
    print_warning "Numix-Circle not found; falling back to Adwaita icons."
    ICON_THEME="Adwaita"
else
    print_status "Icon theme: Numix-Circle (circular app icons, dark Numix folders)."
fi

# Square, flat, dark Openbox theme matching the requested desktop colour.
OB_THEME="SquareDark"
for base in "$HOME/.local/share/themes" "$HOME/.themes" "$HOME/.config/themes"; do
    mkdir -p "${base}/${OB_THEME}/openbox-3"
    cat >"${base}/${OB_THEME}/openbox-3/themerc" <<EOF
# ${OB_THEME} - flat, square, dark. Generated by inst-lowmem-lxqt-rpi5.sh
border.width: 1
padding.width: 4
padding.height: 3
window.handle.width: 0
window.client.padding.width: 0
window.client.padding.height: 0
menu.overlap: 0
menu.border.width: 1

*.border.color: ${BORDER_COLOR}

window.active.title.bg: flat solid
window.active.title.bg.color: ${BG_COLOR}
window.active.title.separator.color: ${BORDER_COLOR}
window.active.label.bg: parentrelative
window.active.label.text.color: ${FG_COLOR}
window.active.handle.bg: flat solid
window.active.handle.bg.color: ${BG_COLOR}
window.active.grip.bg: flat solid
window.active.grip.bg.color: ${BG_COLOR}
window.active.button.unpressed.bg: flat solid
window.active.button.unpressed.bg.color: ${BG_COLOR}
window.active.button.unpressed.image.color: ${FG_COLOR}
window.active.button.pressed.bg: flat solid
window.active.button.pressed.bg.color: ${BG_LIGHTER}
window.active.button.pressed.image.color: ${FG_COLOR}
window.active.button.hover.bg: flat solid
window.active.button.hover.bg.color: ${BG_LIGHTER}
window.active.button.hover.image.color: ${FG_COLOR}
window.active.button.disabled.bg: flat solid
window.active.button.disabled.bg.color: ${BG_COLOR}
window.active.button.disabled.image.color: #777777

window.inactive.title.bg: flat solid
window.inactive.title.bg.color: ${BG_DARKER}
window.inactive.title.separator.color: ${BORDER_COLOR}
window.inactive.label.bg: parentrelative
window.inactive.label.text.color: #9AA0AE
window.inactive.handle.bg: flat solid
window.inactive.handle.bg.color: ${BG_DARKER}
window.inactive.grip.bg: flat solid
window.inactive.grip.bg.color: ${BG_DARKER}
window.inactive.button.unpressed.bg: flat solid
window.inactive.button.unpressed.bg.color: ${BG_DARKER}
window.inactive.button.unpressed.image.color: #9AA0AE
window.inactive.button.pressed.bg: flat solid
window.inactive.button.pressed.bg.color: ${BG_LIGHTER}
window.inactive.button.pressed.image.color: ${FG_COLOR}
window.inactive.button.hover.bg: flat solid
window.inactive.button.hover.bg.color: ${BG_LIGHTER}
window.inactive.button.hover.image.color: ${FG_COLOR}
window.inactive.button.disabled.bg: flat solid
window.inactive.button.disabled.bg.color: ${BG_DARKER}
window.inactive.button.disabled.image.color: #666666

menu.title.bg: flat solid
menu.title.bg.color: ${BG_COLOR}
menu.title.text.color: ${FG_COLOR}
menu.items.bg: flat solid
menu.items.bg.color: ${BG_DARKER}
menu.items.text.color: #D8DAE0
menu.items.disabled.text.color: #6B7080
menu.items.active.bg: flat solid
menu.items.active.bg.color: ${BG_LIGHTER}
menu.items.active.text.color: #FFFFFF
menu.separator.color: ${BORDER_COLOR}

osd.bg: flat solid
osd.bg.color: ${BG_DARKER}
osd.label.bg: parentrelative
osd.label.text.color: ${FG_COLOR}
osd.hilight.bg: flat solid
osd.hilight.bg.color: ${BG_LIGHTER}
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: ${BG_COLOR}
EOF
done
print_status "Openbox theme '${OB_THEME}' installed (square borders, no rounding)."

# The user-requested config dirs (non-standard, kept as a personal drop point).
mkdir -p "$HOME/.config/icons" "$HOME/.config/themes"
cat >"$HOME/.config/icons/README.txt" <<'EOF'
Drop custom icon themes here for reference.
Note: the paths X11/GTK/Qt actually scan are:
  ~/.local/share/icons/   ~/.icons/   /usr/share/icons/
Symlink or copy a theme into one of those to make it selectable.
EOF
cat >"$HOME/.config/themes/README.txt" <<'EOF'
Drop custom themes here for reference.
Note: the paths Openbox/GTK actually scan are:
  ~/.local/share/themes/  ~/.themes/  /usr/share/themes/
A copy of the SquareDark Openbox theme is kept in all three.
EOF

# ===========================================================================
banner "13 - Development toolchain, Pi utilities and GPIO C libraries"
# ===========================================================================

apt_install gcc g++ make pkg-config libc6-dev

# Raspberry Pi core utilities (vcgencmd, pinctrl, vclog, vcmailbox).
apt_install_first raspi-utils-core libraspberrypi-bin
apt_install raspi-gpio raspi-config

# GPIO for C on the Pi 5: the RP1 southbridge means bcm2835/wiringPi/pigpio
# no longer apply. libgpiod is the supported character-device API; lgpio is
# installed too when the release offers it.
apt_install libgpiod-dev gpiod
apt_install liblgpio-dev liblgpio1

mkdir -p "$HOME/dev"
cat >"$HOME/dev/README-GPIO.md" <<'EOF'
# GPIO in C on the Raspberry Pi 5

The Pi 5 routes GPIO through the RP1 southbridge, so `bcm2835`, `wiringPi`
and `pigpio` (which poke the SoC registers directly) do **not** work.
Use the character-device API instead.

## libgpiod (installed)

Check which major version you have — the API changed between them:

    pkg-config --modversion libgpiod

* 1.6.x (Bookworm) -> `gpiod_chip_open_by_name()`, `gpiod_chip_get_line()`
* 2.x   (Trixie)   -> `gpiod_chip_open()`, `gpiod_request_config_*()`

Build:

    gcc -o blink blink.c $(pkg-config --cflags --libs libgpiod)

The Pi 5's 40-pin header is `gpiochip0` on current kernels (it was
`gpiochip4` on early Pi 5 kernels). Confirm with:

    gpiodetect
    gpioinfo | head -40

Quick command-line test on GPIO 17:

    gpioset -t0 gpiochip0 17=1
    gpioget gpiochip0 17

## lgpio (installed when available)

    gcc -o blink blink.c -llgpio

## pinctrl (from raspi-utils-core)

    pinctrl get 17
    pinctrl set 17 op dh
EOF
print_status "GPIO notes written to ~/dev/README-GPIO.md"

# ===========================================================================
banner "14 - Vimb web browser (apt when packaged, otherwise built from source)"
# ===========================================================================

if command -v vimb >/dev/null 2>&1; then
    print_status "vimb already installed."
elif pkg_available vimb; then
    apt_install vimb
else
    print_warning "vimb is not packaged for this release; building from source."
    # Vimb needs WebKitGTK; 4.1 on Bookworm/Trixie, 4.0 on older releases.
    WK_PKG=""
    for cand in libwebkit2gtk-4.1-dev libwebkit2gtk-4.0-dev; do
        pkg_available "$cand" && { WK_PKG="$cand"; break; }
    done
    if [ -z "$WK_PKG" ]; then
        note_fail "No WebKitGTK dev package found; cannot build vimb."
    else
        apt_install "$WK_PKG" libgtk-3-dev libsoup-3.0-dev libglib2.0-dev
        VIMB_SRC="$HOME/.cache/vimb-src"
        rm -rf "$VIMB_SRC"
        if git clone --depth 1 https://github.com/fanglingsu/vimb.git "$VIMB_SRC" >>"$LOGFILE" 2>&1; then
            # Point the build at whichever WebKitGTK API version is present.
            WK_API="${WK_PKG#libwebkit2gtk-}"; WK_API="webkit2gtk-${WK_API%-dev}"
            # Restrict the rewrite to build files: never touch .git objects.
            grep -rl --exclude-dir=.git --include='Makefile' --include='*.mk' \
                 'webkit2gtk-4\.[01]' "$VIMB_SRC" 2>/dev/null \
                | xargs -r sed -i "s/webkit2gtk-4\.[01]/${WK_API}/g"
            if ( cd "$VIMB_SRC" && make -j"$(nproc)" PREFIX=/usr/local ) >>"$LOGFILE" 2>&1 \
               && ( cd "$VIMB_SRC" && sudo make install PREFIX=/usr/local ) >>"$LOGFILE" 2>&1; then
                print_status "vimb built and installed to /usr/local/bin/vimb"
            else
                note_fail "vimb build failed (see $LOGFILE)."
            fi
        else
            note_fail "Could not clone the vimb repository."
        fi
    fi
fi

# ===========================================================================
banner "15 - fastfetch"
# ===========================================================================

if command -v fastfetch >/dev/null 2>&1; then
    print_status "fastfetch already installed."
elif pkg_available fastfetch; then
    apt_install fastfetch
else
    print_warning "fastfetch is not in this release's repos; fetching the arm64 .deb."
    FF_DEB="$(mktemp -d)/fastfetch.deb"
    FF_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
    if curl -fsSL --retry 3 -o "$FF_DEB" "$FF_URL"; then
        if sudo apt-get install -y "$FF_DEB" >>"$LOGFILE" 2>&1; then
            print_status "fastfetch installed from GitHub release."
        else
            note_fail "Installing the fastfetch .deb failed (see $LOGFILE)."
        fi
    else
        note_fail "Could not download fastfetch."
    fi
    rm -f "$FF_DEB"
fi

# ===========================================================================
banner "16 - Oh My Posh prompt"
# ===========================================================================

if command -v oh-my-posh >/dev/null 2>&1 || [ -x "$HOME/.local/bin/oh-my-posh" ]; then
    print_status "oh-my-posh already installed."
else
    if curl -fsSL https://ohmyposh.dev/install.sh \
        | bash -s -- -d "$HOME/.local/bin" >>"$LOGFILE" 2>&1; then
        print_status "oh-my-posh installed to ~/.local/bin"
    else
        note_fail "oh-my-posh installation failed (see $LOGFILE)."
    fi
fi

# Make sure at least one theme exists locally.
OMP_THEME_DIR="$HOME/.cache/oh-my-posh/themes"
if [ ! -f "${OMP_THEME_DIR}/nu4a.omp.json" ]; then
    mkdir -p "$OMP_THEME_DIR"
    curl -fsSL --retry 2 -o "${OMP_THEME_DIR}/nu4a.omp.json" \
        "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/nu4a.omp.json" \
        >>"$LOGFILE" 2>&1 || print_warning "Could not fetch the 'nu4a' oh-my-posh theme."
fi

# ===========================================================================
banner "17 - User directories (local bin, config dirs, XDG user dirs)"
# ===========================================================================

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.config/icons"
mkdir -p "$HOME/.config/themes"
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons" "$HOME/.config/autostart"
print_status "Created ~/.local/bin, ~/.config/icons, ~/.config/themes"

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update >>"$LOGFILE" 2>&1 || true
fi
# Create the standard XDG user directories explicitly in case the tool is absent.
for d in Desktop Documents Downloads Music Pictures Videos Templates Public; do
    mkdir -p "$HOME/$d"
done
cat >"$HOME/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
EOF
print_status "XDG user directories created."

# ===========================================================================
banner "18 - Shell configuration (~/.bashrc aliases, PATH, prompt)"
# ===========================================================================

# The block keeps its old marker name so re-running over an install made by
# inst-min-lxqt-rpi5.sh replaces that block instead of adding a second one.
write_block "$HOME/.bashrc" "inst-min-lxqt-rpi5" "$(cat <<'EOF'
export PATH=$PATH:$HOME/.local/bin

alias ll='ls -l'
alias la='ls -la'
alias edit='l3afpad'
alias leafpad='l3afpad'
alias hh='history'
alias hl='history 20'

# Oh My Posh prompt (only for interactive shells with a real terminal).
if command -v oh-my-posh >/dev/null 2>&1 && [ -n "${PS1:-}" ]; then
    __omp_theme="$HOME/.cache/oh-my-posh/themes/nu4a.omp.json"
    if [ -f "$__omp_theme" ]; then
        eval "$(oh-my-posh init bash --config "$__omp_theme")"
    else
        eval "$(oh-my-posh init bash)"
    fi
    unset __omp_theme
fi
EOF
)"
print_status "Aliases (ll, la, edit, leafpad), PATH and prompt added to ~/.bashrc"
print_warning "Note: 'leafpad' is aliased to l3afpad (the GTK3 fork actually installed)."

# ===========================================================================
banner "19 - Fonts, colours and themes applied to X11 / Qt / GTK / urxvt"
# ===========================================================================

# --- X resources: urxvt with the Nerd Font, dark palette, no scrollbar ------
cat >"$HOME/.Xresources" <<EOF
! Generated by inst-lowmem-lxqt-rpi5.sh

Xft.antialias:  1
Xft.hinting:    1
Xft.hintstyle:  hintslight
Xft.rgba:       rgb

! --- rxvt-unicode ---------------------------------------------------------
URxvt.font:              xft:${MONO_FONT}:size=${FONT_SIZE}
URxvt.boldFont:          xft:${MONO_FONT}:bold:size=${FONT_SIZE}
URxvt.letterSpace:       0
URxvt.scrollBar:         false
URxvt.saveLines:         4000
URxvt.internalBorder:    4
URxvt.cursorBlink:       false
URxvt.urgentOnBell:      true
URxvt.iso14755:          false
URxvt.iso14755_52:       false
URxvt.perl-ext-common:   default,matcher
URxvt.url-launcher:      xdg-open
URxvt.matcher.button:    1

URxvt.depth:             24
URxvt.background:        ${BG_DARKER}
URxvt.foreground:        ${FG_COLOR}
URxvt.cursorColor:       #C9CCD4
URxvt.color0:            #2B2E38
URxvt.color8:            #4A4F60
URxvt.color1:            #C25B5B
URxvt.color9:            #E07B7B
URxvt.color2:            #7FA86B
URxvt.color10:           #9CC784
URxvt.color3:            #C9A25B
URxvt.color11:           #E3BE79
URxvt.color4:            #5B84C2
URxvt.color12:           #7BA3E0
URxvt.color5:            #9B72C2
URxvt.color13:           #B892E0
URxvt.color6:            #5BA8A8
URxvt.color14:           #7BC7C7
URxvt.color7:            #C9CCD4
URxvt.color15:           #F0F1F4
EOF
print_status "~/.Xresources written (urxvt, ${MONO_FONT} ${FONT_SIZE})."

# --- Qt / LXQt -------------------------------------------------------------
mkdir -p "$HOME/.config/lxqt"
cat >"$HOME/.config/lxqt/lxqt.conf" <<EOF
[General]
__userfile__=true
icon_theme=${ICON_THEME}
theme=frost
single_click_activate=false

[Qt]
font="${UI_FONT},${FONT_SIZE},-1,5,50,0,0,0,0,0"
style=Fusion
doubleClickInterval=400
EOF

cat >"$HOME/.config/lxqt/session.conf" <<'EOF'
[General]
__userfile__=true
window_manager=openbox

[Environment]
QT_QPA_PLATFORMTHEME=lxqt
QT_ENABLE_HIGHDPI_SCALING=0
EOF

# pcmanfm-qt: keep it as a file manager only, and if its desktop is ever
# enabled make sure it paints the requested flat colour and no wallpaper.
# The file manager's view mode and hidden-file filter live in [FolderView]
# under the key "Mode". "ViewMode" in [Window] is not a pcmanfm-qt key at all:
# QSettings preserves it on rewrite, so it looks accepted while doing nothing.
# [Desktop] ShowHidden covers the desktop, [FolderView] ShowHidden the windows.
mkdir -p "$HOME/.config/pcmanfm-qt/lxqt"
cat >"$HOME/.config/pcmanfm-qt/lxqt/settings.conf" <<EOF
[Desktop]
Wallpaper=
WallpaperMode=color
BgColor=${BG_COLOR}
FgColor=${FG_COLOR}
ShowHidden=true
DesktopIconSize=48

[Behavior]
SingleClick=false
ConfirmDelete=true

[Window]
AlwaysShowTabs=false
ShowMenuBar=true

[FolderView]
Mode=detailed
ShowHidden=true
EOF
print_status "LXQt configured (icons: ${ICON_THEME}, font: ${UI_FONT} ${FONT_SIZE})."

# --- GTK 2 / GTK 3 (l3afpad, vimb, feh dialogs) ----------------------------
mkdir -p "$HOME/.config/gtk-3.0"
cat >"$HOME/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=${ICON_THEME}
gtk-font-name=${UI_FONT} ${FONT_SIZE}
gtk-cursor-theme-name=Adwaita
gtk-enable-animations=0
gtk-menu-images=0
gtk-button-images=0
EOF

cat >"$HOME/.gtkrc-2.0" <<EOF
gtk-theme-name="Adwaita"
gtk-icon-theme-name="${ICON_THEME}"
gtk-font-name="${UI_FONT} ${FONT_SIZE}"
gtk-menu-images=0
gtk-button-images=0
EOF
print_status "GTK2/GTK3 font and icon settings written."

# ===========================================================================
banner "20 - Openbox configuration (square windows, menu, keybindings)"
# ===========================================================================

mkdir -p "$HOME/.config/openbox"
if [ -f /etc/xdg/openbox/rc.xml ]; then
    cp -f /etc/xdg/openbox/rc.xml "$HOME/.config/openbox/rc.xml"
    # First <name> element in rc.xml is the theme name.
    sed -i "0,/<name>[^<]*<\/name>/s//<name>${OB_THEME}<\/name>/" "$HOME/.config/openbox/rc.xml"
    # Fonts used for titlebars, menus and OSD.
    sed -i "s|<name>sans</name>|<name>${UI_FONT}</name>|g; \
            s|<name>Sans</name>|<name>${UI_FONT}</name>|g; \
            s|<size>8</size>|<size>${FONT_SIZE}</size>|g; \
            s|<size>9</size>|<size>${FONT_SIZE}</size>|g" "$HOME/.config/openbox/rc.xml"
    # The stock Debian rc.xml points at /var/lib/openbox/debian-menu.xml, which
    # only exists with the 'menu' package installed. Drop it so our own
    # menu.xml is the sole root menu and Openbox stops warning at every start.
    sed -i '\|<file>/var/lib/openbox/debian-menu.xml</file>|d' "$HOME/.config/openbox/rc.xml"
    print_status "Openbox rc.xml customised (theme ${OB_THEME}, font ${UI_FONT} ${FONT_SIZE})."
else
    print_warning "/etc/xdg/openbox/rc.xml not found; Openbox will use built-in defaults."
fi

cat >"$HOME/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Openbox 3">
  <item label="Terminal">      <action name="Execute"><command>urxvt</command></action></item>
  <item label="Web Browser">   <action name="Execute"><command>vimb</command></action></item>
  <item label="Files">         <action name="Execute"><command>pcmanfm-qt</command></action></item>
  <item label="Text Editor">   <action name="Execute"><command>l3afpad</command></action></item>
  <separator/>
  <item label="PDF Viewer">    <action name="Execute"><command>mupdf</command></action></item>
  <item label="Image Viewer">  <action name="Execute"><command>feh</command></action></item>
  <item label="Video Player">  <action name="Execute"><command>mpv</command></action></item>
  <item label="Screen Record (toggle)">
    <action name="Execute"><command>screenrec</command></action></item>
  <separator/>
  <item label="Run...">        <action name="Execute"><command>lxqt-runner</command></action></item>
  <item label="Openbox Config"><action name="Execute"><command>obconf-qt</command></action></item>
  <separator/>
  <item label="Reconfigure">   <action name="Reconfigure"/></item>
  <item label="Log Out">       <action name="Execute"><command>lxqt-leave --logout</command></action></item>
</menu>
</openbox_menu>
EOF

cat >"$HOME/.config/openbox/autostart" <<EOF
# Openbox autostart - kept deliberately small.
xsetroot -solid "${BG_COLOR}" &
EOF
chmod +x "$HOME/.config/openbox/autostart"

# --- Session startup: no display manager, startx straight from tty1 --------
cat >"$HOME/.xinitrc" <<EOF
#!/bin/sh
# Generated by inst-lowmem-lxqt-rpi5.sh
[ -f "\$HOME/.Xresources" ] && xrdb -merge "\$HOME/.Xresources"
xsetroot -solid "${BG_COLOR}"
xset s off -dpms
"\$HOME/.local/bin/cap-resolution" "${MAX_RES}"
exec startlxqt
EOF
chmod +x "$HOME/.xinitrc"

PROFILE_FILE="$HOME/.profile"
[ -f "$HOME/.bash_profile" ] && PROFILE_FILE="$HOME/.bash_profile"
write_block "$PROFILE_FILE" "inst-min-lxqt-rpi5-startx" "$(cat <<'EOF'
# Start the desktop automatically on the first virtual terminal only.
# Deliberately NOT 'exec startx': with console autologin enabled, exec would
# end the login session whenever X dies, and the getty would log straight back
# in and retry - an unbreakable loop with no console to fix it from. Keeping
# the shell costs ~3 MB and always leaves a usable prompt.
if [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = "1" ] && command -v startx >/dev/null 2>&1; then
    if ! startx >"$HOME/.xsession-errors" 2>&1; then
        echo "X failed to start. See ~/.xsession-errors"
    fi
fi
EOF
)"
print_status "Autostart of X on tty1 added to $(basename "$PROFILE_FILE")."

# Console autologin so the desktop comes up unattended after boot.
if command -v raspi-config >/dev/null 2>&1; then
    if sudo raspi-config nonint do_boot_behaviour B2 >>"$LOGFILE" 2>&1; then
        print_status "Console autologin enabled (raspi-config B2)."
    else
        print_warning "Could not set console autologin; do it via 'sudo raspi-config'."
    fi
else
    print_warning "raspi-config not present; enable console autologin manually if wanted."
fi

# --- Trim LXQt session modules that cost memory and are not needed ---------
for mod in lxqt-powermanagement lxqt-desktop pcmanfm-qt-desktop \
           xscreensaver light-locker print-applet at-spi-dbus-bus \
           blueman geoclue-demo-agent; do
    if [ -f "/etc/xdg/autostart/${mod}.desktop" ]; then
        cat >"$HOME/.config/autostart/${mod}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${mod}
Exec=/bin/true
Hidden=true
X-LXQt-Need-Tray=false
EOF
        print_status "Disabled autostart module: ${mod}"
    fi
done

# Desktop entry for the screen recorder so it shows in the LXQt menu.
cat >"$HOME/.local/share/applications/screenrec.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Screen Recorder (toggle)
Comment=Start or stop an ffmpeg screen recording
Exec=screenrec
Icon=media-record
Terminal=false
Categories=AudioVideo;Recorder;
EOF
update-desktop-database "$HOME/.local/share/applications" >>"$LOGFILE" 2>&1 || true

# ===========================================================================
banner "21 - Desktop background: flat colour ${BG_COLOR} (R:56 G:60 B:72), no wallpaper"
# ===========================================================================

cat >"$HOME/.config/autostart/set-desktop-bg.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Desktop background colour
Exec=xsetroot -solid "${BG_COLOR}"
Terminal=false
NoDisplay=true
X-LXQt-Module=false
EOF
print_status "Background set to ${BG_COLOR} via xsetroot (no wallpaper, no desktop process)."

# ===========================================================================
banner "22 - Pi-Apps (64-bit) plus 'Min' and 'Geany Dark Mode'"
# ===========================================================================

if [ "$SKIP_PI_APPS" = "1" ]; then
    print_warning "SKIP_PI_APPS=1 -> skipping Pi-Apps."
else
    if [ -d "$HOME/pi-apps" ]; then
        print_status "Pi-Apps already present at ~/pi-apps"
    else
        print_status "Installing Pi-Apps..."
        if wget -qO- https://raw.githubusercontent.com/Botspot/pi-apps/master/install | bash; then
            print_status "Pi-Apps installed."
        else
            note_fail "Pi-Apps installation failed."
        fi
    fi

    if [ -x "$HOME/pi-apps/manage" ]; then
        print_warning "'Min' is an Electron browser (~250-400 MB RSS when open) - it is the"
        print_warning "heaviest thing in this build. Vimb remains the low-memory browser."

        # 'Geany Dark Mode' only recolours an existing Geany: it writes theme
        # files into Geany's config and does nothing to install the editor, so
        # it fails outright when geany is absent. Install it first, and treat
        # it as an ordered prerequisite rather than a separate feature.
        if command -v geany >/dev/null 2>&1; then
            print_status "geany already present (prerequisite for 'Geany Dark Mode')."
        else
            print_status "Installing geany first - 'Geany Dark Mode' needs it to exist."
            apt_install geany
        fi

        for app in "Min" "Geany Dark Mode"; do
            if [ "$app" = "Geany Dark Mode" ] && ! command -v geany >/dev/null 2>&1; then
                note_fail "Skipped '${app}': geany is missing, so the theme has nothing to apply to."
                continue
            fi
            print_status "Pi-Apps: installing '${app}'..."
            if "$HOME/pi-apps/manage" install "$app" >>"$LOGFILE" 2>&1; then
                print_status "Pi-Apps app installed: ${app}"
            else
                note_fail "Pi-Apps could not install '${app}'. List exact names with: ls ~/pi-apps/apps"
            fi
        done
    else
        print_warning "~/pi-apps/manage not found; skipping the Pi-Apps app installs."
    fi
fi

# ===========================================================================
banner "23 - Disabling the idle triggerhappy hotkey daemon"
# ===========================================================================

if [ "$SKIP_TRIM" = "1" ]; then
    print_warning "SKIP_TRIM=1 -> leaving background services alone."
else
    # triggerhappy (thd) is a global hotkey daemon for console-level key
    # bindings. Raspberry Pi OS enables it with no triggers configured, and
    # under LXQt the hotkeys come from lxqt-globalkeys and Openbox's rc.xml
    # instead, so it is idle on this build.
    if systemctl list-unit-files 2>/dev/null | grep -q '^triggerhappy\.service'; then
        if sudo systemctl disable --now triggerhappy.service >>"$LOGFILE" 2>&1; then
            print_status "Disabled triggerhappy (re-enable with: sudo systemctl enable --now triggerhappy)"
        else
            print_warning "Could not disable triggerhappy."
        fi
    fi
    # triggerhappy is socket-activated as well.
    if systemctl list-unit-files 2>/dev/null | grep -q '^triggerhappy\.socket'; then
        sudo systemctl disable --now triggerhappy.socket >>"$LOGFILE" 2>&1 || true
    fi

    # avahi-daemon is deliberately LEFT RUNNING: it publishes the Pi as
    # <hostname>.local over mDNS. Disabling it would break 'ssh pi@raspberrypi.local'
    # right before step 24 swaps the SSH server out from under you.
    print_status "avahi-daemon left running (keeps <hostname>.local reachable)."
    print_warning "Bluetooth and Wi-Fi services were left untouched on purpose."
fi

sudo apt-get -y autoremove --purge >>"$LOGFILE" 2>&1 || true
sudo apt-get -y clean >>"$LOGFILE" 2>&1 || true

# ===========================================================================
banner "24 - SSH server: dropbear replaces OpenSSH"
# ===========================================================================

# How much this actually saves depends entirely on how OpenSSH is started:
#
#   ssh.service  a listener process is resident from boot (~5-8 MB RSS), and
#                every session forks a privileged monitor plus an unprivileged
#                child (~5-10 MB per connection).
#   ssh.socket   systemd holds the listening socket and NO sshd is resident
#                while idle. The idle saving from dropbear is then close to
#                zero and the only win is the per-connection cost.
#
# Debian moved sshd to socket activation in Trixie; Bookworm still uses the
# traditional service. Rather than assume, the step measures both ends and
# prints the real numbers for this machine.

# Total RSS in kB of all processes whose command matches $1.
rss_of() {
    ps -eo rss,comm --no-headers 2>/dev/null \
        | awk -v pat="$1" '$2 ~ pat { total += $1 } END { print total + 0 }'
}

# True when something can actually start dropbear at boot: a systemd unit or
# a sysvinit script. dropbear-bin alone satisfies neither.
dropbear_service_present() {
    [ -x /etc/init.d/dropbear ] && return 0
    systemctl list-unit-files 2>/dev/null | grep -qE '^dropbear\.(service|socket)' && return 0
    return 1
}

SSHD_RSS_BEFORE="$(rss_of '^sshd$')"
SSH_ACTIVATION="none"
if systemctl is-active ssh.socket >/dev/null 2>&1 || \
   systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    SSH_ACTIVATION="socket"
elif systemctl is-active ssh.service >/dev/null 2>&1 || \
     systemctl is-enabled ssh.service >/dev/null 2>&1; then
    SSH_ACTIVATION="service"
fi

if [ "$SKIP_SSH_SWAP" = "1" ]; then
    print_warning "SKIP_SSH_SWAP=1 -> keeping OpenSSH, dropbear not installed."
else
    case "$SSH_ACTIVATION" in
        service)
            print_status "OpenSSH runs as a resident daemon (ssh.service): ${SSHD_RSS_BEFORE} kB RSS now."
            print_status "Dropbear should take this to roughly 1000-2000 kB."
            ;;
        socket)
            print_status "OpenSSH is socket-activated (ssh.socket): systemd holds the port and"
            print_status "no sshd is resident while idle, so the idle saving here is ~0."
            print_warning "The win is per-connection only: ~5-10 MB per sshd session against"
            print_warning "~1-2 MB per dropbear session. Swap for the per-session cost, or keep"
            print_warning "OpenSSH with SKIP_SSH_SWAP=1 if you would rather have its feature set."
            ;;
        none)
            print_warning "No OpenSSH server unit found; installing dropbear as the SSH server."
            ;;
    esac

    print_warning "About to replace OpenSSH with dropbear on port 22."
    print_warning "If you are connected over SSH right now, your session may drop."
    print_warning "Reconnect afterwards with the same user, password or ~/.ssh/authorized_keys."
    if confirm "Proceed with the OpenSSH -> dropbear swap?"; then

        # The Debian package split changed: dropbear-run was dropped in
        # 2022.83-3, and the 'dropbear' package itself now ships the startup
        # files. dropbear-bin provides /usr/sbin/dropbear and NOTHING that
        # starts it, so probing for the binary is not enough - a machine can
        # end up with the binary present, no init script, and therefore no SSH
        # server after a reboot. Probe for the service instead.
        apt_install dropbear dropbear-bin
        if ! dropbear_service_present; then
            # Older releases keep the startup files in dropbear-run.
            apt_install dropbear-run
        fi

        if [ ! -x /usr/sbin/dropbear ]; then
            note_fail "dropbear binary missing after install; OpenSSH left in place."
        elif ! dropbear_service_present; then
            note_fail "dropbear installed but nothing provides its service or init script."
            print_warning "It would not start at boot, so OpenSSH is being left in place."
        else

            # Used by the dropbear.service path. Under dropbear.socket the port
            # comes from the unit's ListenStream (22 by default) and this file
            # is ignored - harmless either way.
            sudo tee /etc/default/dropbear >/dev/null <<'EOF'
# Generated by inst-lowmem-lxqt-rpi5.sh
NO_START=0
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS=
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF

            # Both activation paths must go, whichever this release uses.
            print_status "Stopping and disabling OpenSSH (service and socket units)..."
            for unit in ssh.socket ssh.service sshd.service sshd.socket; do
                systemctl list-unit-files 2>/dev/null | grep -q "^${unit}" && \
                    sudo systemctl disable --now "$unit" >>"$LOGFILE" 2>&1
            done

            # Debian has shipped dropbear three different ways over time:
            #   dropbear.socket + dropbear@.service  socket-activated
            #   dropbear.service                     native unit
            #   /etc/init.d/dropbear                 sysvinit, systemd-wrapped
            # 'systemctl enable' behaves differently on each - a generated sysv
            # unit can refuse 'enable' while starting perfectly well - so pick
            # whichever exists and judge the result by whether dropbear ends up
            # serving, never by one command's exit status.
            DROPBEAR_UNIT=""
            for unit in dropbear.socket dropbear.service; do
                if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
                    DROPBEAR_UNIT="$unit"
                    break
                fi
            done
            if [ -z "$DROPBEAR_UNIT" ] && [ -x /etc/init.d/dropbear ]; then
                DROPBEAR_UNIT="dropbear"
            fi

            if [ -z "$DROPBEAR_UNIT" ]; then
                print_warning "No dropbear unit or init script found; trying the binary directly."
            else
                print_status "Bringing dropbear up via ${DROPBEAR_UNIT}..."
                # Boot persistence and running-right-now are separate concerns.
                # Attempt each independently; report on them separately below.
                sudo systemctl enable "$DROPBEAR_UNIT" >>"$LOGFILE" 2>&1 \
                    || sudo update-rc.d dropbear defaults >>"$LOGFILE" 2>&1 \
                    || true
                sudo systemctl start "$DROPBEAR_UNIT" >>"$LOGFILE" 2>&1 \
                    || sudo /etc/init.d/dropbear start >>"$LOGFILE" 2>&1 \
                    || true
            fi

            sleep 2

            # Ground truth: who actually holds port 22 right now? Purging
            # OpenSSH is only safe once dropbear owns it. A bare "is anything
            # listening" test passes on a leftover sshd just as happily, and
            # purging then leaves the Pi with no SSH server at all.
            PORT22_LINE="$(sudo ss -ltnp 2>/dev/null | grep ':22 ' | head -n1)"
            DB_SERVING=no
            SSHD_HOLDS=no
            case "$PORT22_LINE" in
                *dropbear*)
                    DB_SERVING=yes ;;                    # classic daemon
                *sshd*)
                    SSHD_HOLDS=yes ;;
                *systemd*)
                    # Socket activation: systemd holds the port, so confirm the
                    # listening socket belongs to dropbear and not to sshd.
                    if systemctl is-active dropbear.socket >/dev/null 2>&1; then
                        DB_SERVING=yes
                    fi ;;
            esac

            if [ "$DB_SERVING" = "yes" ]; then
                print_status "dropbear owns port 22 (verified by listening process)."

                # Running now does not mean running after a reboot. A generated
                # sysv unit often cannot be 'enabled', which would leave a
                # working Pi with no SSH server on the next boot.
                if systemctl is-enabled "${DROPBEAR_UNIT:-dropbear}" >/dev/null 2>&1 \
                   || compgen -G '/etc/rc2.d/S*dropbear*' >/dev/null; then
                    print_status "dropbear is set to start at boot."
                else
                    print_warning "dropbear is running but may NOT start at boot."
                    print_warning "Check with: systemctl is-enabled dropbear"
                    print_warning "Fix with:   sudo update-rc.d dropbear defaults"
                fi

                print_status "Purging openssh-server..."
                if sudo apt-get -y purge openssh-server >>"$LOGFILE" 2>&1; then
                    print_status "openssh-server removed."
                else
                    print_warning "Could not purge openssh-server (see $LOGFILE)."
                fi

                # openssh-client is kept on purpose. It is not a daemon, so it
                # costs no resident memory, and ssh/scp/sftp/ssh-keygen out of
                # the Pi keep working - git, rsync and ansible all invoke
                # /usr/bin/ssh by name and dbclient is not a drop-in for it.
                print_status "openssh-client kept: no resident cost, and ssh/scp out of the Pi still work."

                DROPBEAR_RSS="$(rss_of '^dropbear')"
                SSHD_RSS_AFTER="$(rss_of '^sshd$')"
                print_status " "
                print_status "  Measured on this machine:"
                print_status "    sshd resident before : ${SSHD_RSS_BEFORE} kB"
                print_status "    sshd resident after  : ${SSHD_RSS_AFTER} kB"
                print_status "    dropbear resident    : ${DROPBEAR_RSS} kB"
                if [ "$SSH_ACTIVATION" = "socket" ]; then
                    print_status "    (sshd was socket-activated, so 'before' was already ~0;"
                    print_status "     the saving shows up per connection, not at idle.)"
                fi
                if [ "$DROPBEAR_UNIT" = "dropbear.socket" ]; then
                    print_status "    (dropbear is socket-activated too, so 0 kB here is correct:"
                    print_status "     systemd holds :22 and spawns dropbear only per connection.)"
                fi
                print_status " "
            else
                if [ "$SSHD_HOLDS" = "yes" ]; then
                    note_fail "Port 22 is still held by sshd, not dropbear - NOT purging OpenSSH."
                elif [ -z "$PORT22_LINE" ]; then
                    note_fail "Nothing is listening on port 22 - NOT purging OpenSSH."
                else
                    note_fail "Port 22 is held by something that is not dropbear - NOT purging OpenSSH."
                    print_warning "  ${PORT22_LINE}"
                fi
                for unit in ssh.socket ssh.service; do
                    systemctl list-unit-files 2>/dev/null | grep -q "^${unit}" && \
                        sudo systemctl enable --now "$unit" >>"$LOGFILE" 2>&1
                done
                print_warning "OpenSSH was re-enabled so you are not locked out."
            fi
        fi
    else
        print_warning "Skipped by user; OpenSSH left in place."
    fi
fi

# ===========================================================================
banner "25 - memcheck: one command to measure the result"
# ===========================================================================

cat >"$HOME/.local/bin/memcheck" <<'MCEOF'
#!/bin/sh
# memcheck - show what decides this Pi's desktop memory use.
# Generated by inst-lowmem-lxqt-rpi5.sh. Run it inside the desktop.
ps_="$(getconf PAGESIZE 2>/dev/null)"
echo "Page size   : ${ps_} bytes"
[ "$ps_" = "4096" ] || echo "              ^ not 4 KB: check 'kernel=kernel8.img' in /boot/firmware/config.txt"
echo "Arch/kernel : $(dpkg --print-architecture 2>/dev/null) / $(uname -r)"

if [ -n "${DISPLAY:-}" ] && command -v xrandr >/dev/null 2>&1; then
    echo "Resolution  : $(xrandr --query 2>/dev/null | awk '/\*/{printf "%s ", $1}')"
else
    echo "Resolution  : (run inside the desktop to see it)"
fi

log=""
for f in "$HOME/.local/share/xorg/Xorg.0.log" /var/log/Xorg.0.log; do
    [ -f "$f" ] && { log="$f"; break; }
done
if [ -z "$log" ]; then
    echo "Glamor      : unknown (no Xorg log yet)"
elif grep -q 'glamor initialized' "$log"; then
    echo "Glamor      : ON  ($log)"
else
    echo "Glamor      : off ($log)"
fi

echo
echo "Swap:"
swapon --show 2>/dev/null | sed 's/^/  /'
swapon --show 2>/dev/null | grep -q . || echo "  (none)"
echo
free -h
echo
grep -E '^(AnonPages|Shmem|Slab|SUnreclaim|PageTables|KernelStack):' /proc/meminfo
echo
echo "Largest processes (RSS kB):"
ps -eo rss,comm --sort=-rss | head -15
MCEOF
chmod +x "$HOME/.local/bin/memcheck"
print_status "Installed ~/.local/bin/memcheck (run it after logging in to the desktop)."

# ===========================================================================
banner "26 - Summary"
# ===========================================================================

echo ""
echo "  Desktop      : LXQt session + Openbox (theme ${OB_THEME}, square borders)"
echo "  Background   : ${BG_COLOR}  (R:56 G:60 B:72, no wallpaper, no desktop process)"
echo "  Icons        : ${ICON_THEME}"
echo "  UI font      : ${UI_FONT} ${FONT_SIZE}"
echo "  Mono font    : ${MONO_FONT} ${FONT_SIZE}"
echo "  Terminal     : urxvt          Files  : pcmanfm-qt"
echo "  Editor       : l3afpad        Browser: $(command -v vimb >/dev/null 2>&1 && echo vimb || echo 'vimb (NOT installed)')"
echo "  PDF / Image  : mupdf / feh    Video  : mpv"
echo "  Recorder     : screenrec (toggle, ffmpeg x11grab -> ~/Videos)"
echo "  Dev          : gcc g++ make, libgpiod, raspi-utils-core, git, curl"
echo "  Prompt       : oh-my-posh     Sysinfo: fastfetch"
echo "  Kernel       : $([ "$SKIP_KERNEL4K" = "1" ] && echo "unchanged (SKIP_KERNEL4K=1)" || echo "kernel8.img, 4 KB pages")"
echo "  Glamor       : $([ "$KEEP_GLAMOR" = "1" ] && echo "on (KEEP_GLAMOR=1)" || echo "off")"
echo "  Resolution   : $([ "$MAX_RES" = "off" ] && echo "monitor default" || echo "capped at ${MAX_RES}")"
echo "  Swap         : $(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ' | sed 's/ $//;s/^$/none active yet/')"
echo ""

if [ "${#SKIPPED_PKGS[@]}" -gt 0 ]; then
    print_warning "Packages not offered by this release (skipped, not errors):"
    printf '           %s\n' "${SKIPPED_PKGS[@]}"
    echo ""
fi

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    print_error "${#FAILED_STEPS[@]} step(s) reported a problem:"
    printf '           %s\n' "${FAILED_STEPS[@]}"
    echo ""
    print_warning "Details are in $LOGFILE"
else
    print_status "All steps completed without errors."
fi

print_status " "
if [ "$REBOOT_NEEDED" = "1" ]; then
    print_warning "A REBOOT IS REQUIRED for the 4 KB-page kernel / zram to take effect:"
    print_warning "    sudo reboot"
else
    print_status "Reboot to start the desktop:   sudo reboot"
    print_status "Or start it now from tty1:     startx"
fi
print_status " "
print_status "Once logged in to the desktop, measure with:   memcheck"
print_status "(compare the 'used' column with the 486 MB you had before)"
print_status "After a kernel update, re-run memcheck: page size must still say 4096."
print_status "Setup finished."
